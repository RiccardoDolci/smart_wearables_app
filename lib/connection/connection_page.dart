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
  late StreamSubscription<ConnectionStateUpdate> connection;

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
      scanStream.cancel();
      scanning = false;
    }

    if (!connected) {
      setState(() => connecting = true);

      final deviceId = foundBleDevicesFiltered[index].id;

      // Larger MTU helps batched IR lines arrive in one notification.
      await flutterReactiveBle.requestMtu(deviceId: deviceId, mtu: 512);

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
        connecting = false;
        connected = false;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Connection failed!")),
          );
        }
        debugPrint("ERROR during connection: $error \n");
        _startScan();
        refreshScreen();
      });
    }
  }

  void connectingProcedure(String id) {
    connected = false;
    connecting = true;
    debugPrint("Connecting to $id...\n");
  }

  void connectionProcedure(String id, ConnectionStateUpdate event) {
    connected = true;
    connecting = false;
    debugPrint("Connected to $id\n");

    final protocol = BleProtocol();
    _protocol = protocol;

    // --- 0. DEBUG: enumerate the real GATT services/characteristics. ---
    _dumpServices(event.deviceId);

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

    // --- 3. Set time on connect (ble_protocol.md §6/§7). Small delay so
    //         service discovery + notify subscription settle first. ---
    Future.delayed(const Duration(milliseconds: 600), protocol.sendSetTime);

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

  // DEBUG: discover and print every service + characteristic and its
  // properties, so we can confirm which characteristic actually notifies.
  void _dumpServices(String deviceId) async {
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
      connection.cancel();
      _teardownConnection();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Disconnected!")),
      );
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
