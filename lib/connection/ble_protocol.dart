import 'dart:async';

/// Live vitals summary (V frame). `steps` here is the SESSION CUMULATIVE total.
/// `hr == 0` or `spo2x10 == 0` mean "no valid reading".
class Vitals {
  Vitals({
    required this.ts,
    required this.hr,
    required this.spo2x10,
    required this.steps,
    required this.tempC100,
  });

  final int ts;
  final int hr;
  final int spo2x10;
  final int steps;
  final int tempC100;

  double get tempC => tempC100 / 100.0;
  double get spo2 => spo2x10 / 10.0;
  bool get hrValid => hr > 0;
  bool get spo2Valid => spo2x10 > 0;
}

/// One stored history record (R frame). `steps` is the DELTA for that interval.
class HistoryRecord {
  HistoryRecord({
    required this.ts,
    required this.tempC100,
    required this.hr,
    required this.spo2x10,
    required this.steps,
  });

  final int ts;
  final int tempC100;
  final int hr;
  final int spo2x10;
  final int steps;

  double get tempC => tempC100 / 100.0;
  double get spo2 => spo2x10 / 10.0;
  bool get hrValid => hr > 0;
  bool get spo2Valid => spo2x10 > 0;

  /// §7: timestamps below year-2001 are boot-relative (unsynced).
  bool get synced => ts >= 1000000000;

  Map<String, dynamic> toJson() => {
        'ts': ts,
        'temp_c100': tempC100,
        'hr': hr,
        'spo2_x10': spo2x10,
        'steps': steps,
      };

  factory HistoryRecord.fromJson(Map<String, dynamic> j) => HistoryRecord(
        ts: j['ts'] as int,
        tempC100: j['temp_c100'] as int,
        hr: j['hr'] as int,
        spo2x10: j['spo2_x10'] as int,
        steps: j['steps'] as int,
      );
}

/// A completed history dump (everything between HBEGIN and HEND).
/// [complete] is false when the dump was salvaged on timeout or count mismatch.
class HistoryDump {
  HistoryDump({
    required this.records,
    required this.declaredCount,
    required this.complete,
  });

  final List<HistoryRecord> records;
  final int declaredCount;
  final bool complete;
}

/// Parses the line-based ASCII BLE protocol (see ble_protocol.md) and exposes
/// typed event streams. Feed raw notification chunks into [ingest].
class BleProtocol {
  /// How long to wait after the last history line before salvaging a dump
  /// that never received its HEND.
  static const Duration historyTimeout = Duration(seconds: 10);

  final _irController = StreamController<List<int>>.broadcast();
  final _vitalsController = StreamController<Vitals>.broadcast();
  final _historyController = StreamController<HistoryDump>.broadcast();
  final _ackController = StreamController<String>.broadcast(); // C,OK / T,OK / E,...
  final _infoController = StreamController<List<int>>.broadcast(); // I frame: [ver, irHz, vitalsS]

  /// Raw outgoing command bytes, listened to by the BLE write layer.
  final _sendController = StreamController<List<int>>.broadcast();

  /// Live raw IR sample batches (P frames).
  Stream<List<int>> get irSamples => _irController.stream;

  /// Live vitals (V frames).
  Stream<Vitals> get vitals => _vitalsController.stream;

  /// Completed history dumps (HBEGIN..R..HEND).
  Stream<HistoryDump> get history => _historyController.stream;

  /// Acknowledgements / errors: `C,OK`, `T,OK`, `E,<text>`.
  Stream<String> get acks => _ackController.stream;

  /// Hello frame after L: [proto_ver, ir_hz, vitals_period_s].
  Stream<List<int>> get info => _infoController.stream;

  /// Bytes to write to the TX characteristic.
  Stream<List<int>> get outgoing => _sendController.stream;

  // --- receive line assembly ---
  final StringBuffer _rxBuffer = StringBuffer();

  // --- in-progress history dump ---
  List<HistoryRecord>? _historyRecords;
  int _historyDeclared = 0;
  Timer? _historyTimer;

  /// Feed every incoming BLE notification chunk here. Lines may be split or
  /// merged across chunks; we buffer and cut on '\n'.
  void ingest(List<int> chunk) {
    for (final b in chunk) {
      if (b == 0x0D) continue; // ignore \r
      if (b == 0x0A) {
        _handleLine(_rxBuffer.toString());
        _rxBuffer.clear();
      } else {
        _rxBuffer.writeCharCode(b);
      }
    }
  }

  void _handleLine(String line) {
    line = line.trim();
    if (line.isEmpty) return;
    final f = line.split(',');
    final tag = f[0];

    switch (tag) {
      case 'I':
        // I,proto_ver,ir_hz,vitals_period_s
        _infoController.add([
          _i(f, 1),
          _i(f, 2, fallback: 30),
          _i(f, 3, fallback: 15),
        ]);
      case 'P':
        // P,ir1,...,irN
        final samples = <int>[];
        for (var i = 1; i < f.length; i++) {
          final v = int.tryParse(f[i]);
          if (v != null) samples.add(v);
        }
        if (samples.isNotEmpty) _irController.add(samples);
      case 'V':
        // V,ts,hr,spo2_x10,steps,temp_c100
        if (f.length >= 6) {
          _vitalsController.add(Vitals(
            ts: _i(f, 1),
            hr: _i(f, 2),
            spo2x10: _i(f, 3),
            steps: _i(f, 4),
            tempC100: _i(f, 5),
          ));
        }
      case 'HBEGIN':
        _historyDeclared = _i(f, 1);
        _historyRecords = [];
        _armHistoryTimer();
      case 'R':
        // R,ts,temp_c100,hr,spo2_x10,steps
        if (_historyRecords != null && f.length >= 6) {
          _historyRecords!.add(HistoryRecord(
            ts: _i(f, 1),
            tempC100: _i(f, 2),
            hr: _i(f, 3),
            spo2x10: _i(f, 4),
            steps: _i(f, 5),
          ));
          _armHistoryTimer();
        }
      case 'HEND':
        _commitHistory(complete: true);
      case 'C':
      case 'T':
        _ackController.add(line); // e.g. "C,OK" / "T,OK"
      case 'E':
        _ackController.add(line); // "E,<text>"
    }
  }

  void _armHistoryTimer() {
    _historyTimer?.cancel();
    _historyTimer = Timer(historyTimeout, () => _commitHistory(complete: false));
  }

  void _commitHistory({required bool complete}) {
    _historyTimer?.cancel();
    _historyTimer = null;
    final recs = _historyRecords;
    if (recs == null) return;
    _historyRecords = null;
    final ok = complete && recs.length == _historyDeclared;
    _historyController.add(HistoryDump(
      records: recs,
      declaredCount: _historyDeclared,
      complete: ok,
    ));
  }

  int _i(List<String> f, int idx, {int fallback = 0}) {
    if (idx >= f.length) return fallback;
    return int.tryParse(f[idx]) ?? fallback;
  }

  // --- commands (App -> Board) ---

  void _send(String line) {
    _sendController.add(line.codeUnits);
  }

  void sendLive() => _send('L\n');
  void sendHistory() => _send('H\n');
  void sendClear() => _send('C\n');
  void sendSetTime([int? epochSeconds]) {
    final e = epochSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _send('T,$e\n');
  }

  void dispose() {
    _historyTimer?.cancel();
    _irController.close();
    _vitalsController.close();
    _historyController.close();
    _ackController.close();
    _infoController.close();
    _sendController.close();
  }
}
