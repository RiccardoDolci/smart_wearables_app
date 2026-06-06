import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:smart_wearables_app/connection/ble_protocol.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:smart_wearables_app/connected_scaffold.dart';

// --- BLE Service and Characteristic UUIDs (RN4871 Transparent UART) ---
// See ble_protocol.md section 1.
Uuid serviceUuid = Uuid.parse("49535343-FE7D-4AE5-8FA9-9FAFD205E455");
Uuid characteristicUuid =
    Uuid.parse("49535343-1E4D-4BD9-BA61-23C647249616"); // Board -> App (notify)
Uuid characteristicUuidTX =
    Uuid.parse("49535343-8841-43F4-A8D4-ECBE34729BB3"); // App -> Board (write)

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, required this.title});
  final String title;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  // Only show BLE devices whose name contains this.
  final String bleDeviceNameFilter = "BLE_SW";

  final flutterReactiveBle = FlutterReactiveBle();

  late StreamSubscription<DiscoveredDevice> scanStream;
  late Stream<ConnectionStateUpdate> currentConnectionStream;
  StreamSubscription<ConnectionStateUpdate>? connection;

  // Watchdog for a connect attempt that never resolves. flutter_reactive_ble
  // can sit in "connecting" forever without emitting connected/disconnected; if
  // that happens we must clear `connecting` ourselves, otherwise the spinner
  // sticks and the device-tap guard (`if (!connecting)`) locks the user out.
  Timer? _connectWatchdog;
  static const Duration _connectTimeout = Duration(seconds: 10);

  QualifiedCharacteristic? _rxCharacteristic;
  QualifiedCharacteristic? _txCharacteristic;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _outgoingSub;

  List<DiscoveredDevice> foundBleDevices = [];
  List<DiscoveredDevice> foundBleDevicesFiltered = [];

  bool permGranted = false;
  bool scanning = false;
  bool connecting = false;
  bool connected = false;

  // The protocol/data layer for the active connection.
  BleProtocol? _protocol;

  // RTC time-sync state (ble_protocol.md §6/§7). We resend `T` until the board
  // confirms with `T,OK`, so the clock is set even if the first write races
  // service discovery — otherwise every stored record stays boot-relative and
  // the Storico graphs hide them all.
  StreamSubscription<String>? _ackSub;
  Timer? _timeSyncTimer;
  int _timeSyncAttempts = 0;
  bool _timeSynced = false;
  static const int _maxTimeSyncAttempts = 5;

  void refreshScreen() {
    if (mounted) setState(() {});
  }

  // --- Permission Handling ---

  Future<void> _showNoPermissionDialog() async => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Permissions Missing'),
          content: const SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('You have not granted the required permissions.'),
                Text(
                    'Location and Bluetooth permissions are mandatory for BLE to work.'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Acknowledge'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  void _askPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
      Permission.bluetoothConnect
    ].request();

    if (statuses[Permission.bluetoothScan] == PermissionStatus.granted &&
        statuses[Permission.bluetoothConnect] == PermissionStatus.granted &&
        statuses[Permission.locationWhenInUse] == PermissionStatus.granted) {
      permGranted = true;
      if (!scanning) _startScan();
    } else {
      permGranted = false;
    }
  }

  // --- Scan Logic ---

  void _stopScan() async {
    await scanStream.cancel();
    scanning = false;
    refreshScreen();
  }

  void _startScan() async {
    if (scanning) _stopScan();

    if (permGranted) {
      foundBleDevices = [];
      foundBleDevicesFiltered = [];
      scanning = true;
      refreshScreen();

      scanStream =
          flutterReactiveBle.scanForDevices(withServices: []).listen((device) {
        if (foundBleDevices.every((element) => element.id != device.id)) {
          foundBleDevices.add(device);
          if (device.name.contains(bleDeviceNameFilter)) {
            foundBleDevicesFiltered.add(device);
          }
          refreshScreen();
        }
      }, onError: (Object error) {
        debugPrint("ERROR during scan: $error \n");
        refreshScreen();
      });

      Future.delayed(const Duration(seconds: 10), () {
        if (scanning) _stopScan();
      });
    } else {
      await _showNoPermissionDialog();
    }
  }

  // --- Connection Logic ---

  void _startConnection(int index) async {
    if (scanning) {
      await scanStream.cancel();
      scanning = false;
    }

    // Re-entrancy guard: a second tap while already connecting/connected would
    // start a parallel connect and leak the first subscription.
    if (connected || connecting) return;

    setState(() => connecting = true);

    final deviceId = foundBleDevicesFiltered[index].id;

    // Drop any leaked subscription from a previous attempt before starting a new
    // one. A lingering connectToDevice subscription keeps the OS BLE stack in
    // "connecting", which is a common cause of the next attempt hanging.
    await connection?.cancel();
    connection = null;

    // Arm the watchdog so a never-resolving connect still clears the spinner.
    _armConnectWatchdog();

    try {
      currentConnectionStream = flutterReactiveBle.connectToDevice(
        id: deviceId,
        connectionTimeout: const Duration(seconds: 5),
      );

      connection = currentConnectionStream.listen((event) {
        switch (event.connectionState) {
          case DeviceConnectionState.connecting:
            connectingProcedure(event.deviceId);
          case DeviceConnectionState.connected:
            connectionProcedure(event.deviceId, event);
          case DeviceConnectionState.disconnected:
            disconnectionProcedure(event.deviceId);
          default:
        }
        refreshScreen();
      }, onError: (Object error) {
        _failConnection("Connection failed!", error);
      });
    } catch (e) {
      // connectToDevice itself threw synchronously (e.g. invalid id / adapter
      // off) — recover instead of leaving the spinner stuck.
      _failConnection("Connection failed!", e);
    }
  }

  // Note: MTU negotiation used to run here, BEFORE the device was connected,
  // which made the connect hang. It now runs in [connectionProcedure], after the
  // `connected` event, and is non-fatal.
  void _armConnectWatchdog() {
    _connectWatchdog?.cancel();
    _connectWatchdog = Timer(_connectTimeout, () {
      if (connected) return;
      debugPrint(
          "Connect watchdog: no connection within ${_connectTimeout.inSeconds}s");
      _failConnection("Connection timed out. Tap to retry.", "watchdog");
    });
  }

  // Single recovery path for any failed/stuck connect: clear the watchdog and
  // subscription, reset the flags (so the tap-guard releases), tell the user,
  // and go back to scanning so a retry is one tap away.
  void _failConnection(String message, Object error) {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
    connection?.cancel();
    connection = null;
    connecting = false;
    connected = false;
    debugPrint("Connection failure ($error)");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
    _startScan();
    refreshScreen();
  }

  void connectingProcedure(String id) {
    connected = false;
    connecting = true;
    debugPrint("Connecting to $id...\n");
  }

  void connectionProcedure(String id, ConnectionStateUpdate event) {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
    connected = true;
    connecting = false;
    debugPrint("Connected to $id\n");

    // Larger MTU helps batched IR lines arrive in one notification. This MUST
    // happen after the device is connected; requesting it before connect is what
    // made the connect hang. Fire-and-forget and non-fatal — a failed/declined
    // MTU just means smaller notifications, not a broken link.
    flutterReactiveBle
        .requestMtu(deviceId: event.deviceId, mtu: 512)
        .then((mtu) => debugPrint("MTU negotiated: $mtu"))
        .catchError((Object e) {
      debugPrint("requestMtu failed (non-fatal): $e");
    });

    final protocol = BleProtocol();
    _protocol = protocol;

    // --- 0. Discover services (also dumps them for debugging). Only once
    //         discovery completes do we set the clock, so the `T` write can't
    //         race service discovery and silently fail. ---
    _dumpServices(event.deviceId).then((_) {
      if (_protocol == protocol) _startTimeSync(protocol);
    });

    // --- 1. RECEIVE (notify): feed raw chunks into the line parser. ---
    _rxCharacteristic = QualifiedCharacteristic(
      serviceId: serviceUuid,
      characteristicId: characteristicUuid,
      deviceId: event.deviceId,
    );
    _notifySub = flutterReactiveBle
        .subscribeToCharacteristic(_rxCharacteristic!)
        .listen(protocol.ingest, onError: (Object error) {
      debugPrint("ERROR during RX listen: $error\n");
    });

    // --- 2. TRANSMIT (write): forward outgoing command bytes. ---
    _txCharacteristic = QualifiedCharacteristic(
      serviceId: serviceUuid,
      characteristicId: characteristicUuidTX,
      deviceId: event.deviceId,
    );
    _outgoingSub = protocol.outgoing.listen((bytes) async {
      // RN4871 transparent UART: prefer write-WITH-response (confirms the
      // command actually reached the module). Fall back to without-response.
      try {
        await flutterReactiveBle.writeCharacteristicWithResponse(
          _txCharacteristic!,
          value: bytes,
        );
        debugPrint("TX ok (with response): $bytes");
      } catch (e) {
        debugPrint("TX with-response FAILED: $e -> retry without response");
        try {
          await flutterReactiveBle.writeCharacteristicWithoutResponse(
            _txCharacteristic!,
            value: bytes,
          );
          debugPrint("TX ok (without response): $bytes");
        } catch (e2) {
          debugPrint("TX without-response ALSO FAILED: $e2");
        }
      }
    });

    // --- 3. Watch for the board's `T,OK` so the resend loop can stop once the
    //         clock is confirmed set. ---
    _ackSub = protocol.acks.listen((ack) {
      if (ack.startsWith('T,OK')) {
        _timeSynced = true;
        _timeSyncTimer?.cancel();
        _timeSyncTimer = null;
        debugPrint("RTC set confirmed: $ack");
      }
    });
    // Time-sync itself (§0 above) is kicked off once service discovery resolves.

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Connected!")),
    );

    // --- 4. Go to the connected scaffold (Live + Storico). ---
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConnectedScaffold(protocol: protocol),
      ),
    ).whenComplete(forceDisconnection);
  }

  // --- RTC time sync ---

  // Send `T,<epoch>` and keep resending until the board answers `T,OK`. The
  // first attempt happens after service discovery so the write doesn't race it;
  // each retry covers a dropped write or a board that wasn't ready yet.
  void _startTimeSync(BleProtocol protocol) {
    _timeSynced = false;
    _timeSyncAttempts = 0;
    _trySetTime(protocol);
  }

  void _trySetTime(BleProtocol protocol) {
    // Bail out if we disconnected or a newer connection replaced this protocol.
    if (_protocol != protocol || _timeSynced) return;
    if (_timeSyncAttempts >= _maxTimeSyncAttempts) {
      debugPrint("RTC set: no T,OK after $_timeSyncAttempts attempts; giving "
          "up (T was still sent each time).");
      return;
    }
    _timeSyncAttempts++;
    protocol.sendSetTime(); // T,<current epoch seconds>
    debugPrint("RTC set: sent T (attempt $_timeSyncAttempts)");
    _timeSyncTimer?.cancel();
    _timeSyncTimer = Timer(
      const Duration(milliseconds: 1500),
      () => _trySetTime(protocol),
    );
  }

  // DEBUG: discover and print every service + characteristic and its
  // properties, so we can confirm which characteristic actually notifies.
  Future<void> _dumpServices(String deviceId) async {
    try {
      await flutterReactiveBle.discoverAllServices(deviceId);
      final services = await flutterReactiveBle.getDiscoveredServices(deviceId);
      debugPrint("=== GATT dump: ${services.length} services ===");
      for (final s in services) {
        debugPrint("Service ${s.id}");
        for (final c in s.characteristics) {
          debugPrint("  Char ${c.id} "
              "notify=${c.isNotifiable} indicate=${c.isIndicatable} "
              "write=${c.isWritableWithResponse} "
              "writeNR=${c.isWritableWithoutResponse} read=${c.isReadable}");
        }
      }
      debugPrint("=== end GATT dump ===");
    } catch (e) {
      debugPrint("GATT discovery FAILED: $e");
    }
  }

  void disconnectionProcedure(String id) {
    if (connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Disconnected!")),
      );
    }
    _teardownConnection();
    connected = false;
    connecting = false;
    debugPrint("Disconnected from $id\n");

    Navigator.popUntil(context, (route) => route.isFirst);
  }

  void _teardownConnection() {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
    _timeSyncTimer?.cancel();
    _timeSyncTimer = null;
    _ackSub?.cancel();
    _ackSub = null;
    _notifySub?.cancel();
    _notifySub = null;
    _outgoingSub?.cancel();
    _outgoingSub = null;
    _protocol?.dispose();
    _protocol = null;
  }

  @override
  void initState() {
    super.initState();
    _askPermissions();
  }

  void forceDisconnection() async {
    if (connected) {
      await connection?.cancel();
      connection = null;
      _teardownConnection();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Disconnected!")),
        );
      }
      _startScan();
      setState(() {
        connected = false;
        connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            title: Text(widget.title),
          ),
          body: RefreshIndicator(
            onRefresh: () async => _startScan(),
            child: foundBleDevicesFiltered.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 80),
                      Center(
                        child: Text(scanning
                            ? 'Scanning for "$bleDeviceNameFilter" devices...'
                            : 'No devices found. Pull to rescan.'),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: foundBleDevicesFiltered.length,
                    itemBuilder: (context, index) => Card(
                      child: ListTile(
                        dense: true,
                        onTap: () {
                          if (!connecting) _startConnection(index);
                        },
                        subtitle: Text(foundBleDevicesFiltered[index].id),
                        title: Text(
                            "$index: ${foundBleDevicesFiltered[index].name}"),
                      ),
                    ),
                  ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: scanning ? null : _startScan,
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(scanning ? 'Scanning…' : 'Connetti'),
          ),
        ),
        if (connecting)
          const Opacity(
            opacity: 0.5,
            child: ModalBarrier(dismissible: false, color: Colors.black),
          ),
        if (connecting) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
