import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:smart_wearables_app/connection/ble_protocol.dart';
import 'package:smart_wearables_app/storage/history_store.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

/// Storico page: pulls history (H), de-duplicates by ts, persists, and shows
/// HR, SpO2, steps-per-half-hour and temperature charts. Supports refresh,
/// clear (board + local) and CSV export to the phone.
class StoricoPage extends StatefulWidget {
  const StoricoPage({super.key, required this.protocol, required this.store});

  final BleProtocol protocol;
  final HistoryStore store;

  @override
  State<StoricoPage> createState() => _StoricoPageState();
}

class _TimePoint {
  _TimePoint(this.time, this.value);
  final DateTime time;
  final double value;
}

class _StoricoPageState extends State<StoricoPage> {
  static const int _binSeconds = 1800; // 30-minute bins

  late final StreamSubscription<HistoryDump> _historySub;
  late final StreamSubscription<String> _ackSub;

  bool _loadingDump = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _historySub = widget.protocol.history.listen(_onDump);
    _ackSub = widget.protocol.acks.listen(_onAck);
  }

  Future<void> _onDump(HistoryDump dump) async {
    final added = await widget.store.merge(dump.records);
    if (!mounted) return;
    setState(() => _loadingDump = false);
    final msg = dump.complete
        ? 'Aggiornato: $added nuovi record (${dump.records.length} ricevuti).'
        : 'Dump incompleto (attesi ${dump.declaredCount}, ricevuti '
            '${dump.records.length}): $added nuovi record salvati.';
    _snack(msg);
  }

  void _onAck(String ack) {
    if (ack.startsWith('C,OK')) {
      // Board flash cleared -> also wipe local copy.
      widget.store.clear().then((_) {
        if (!mounted) return;
        setState(() => _clearing = false);
        _snack('Dati cancellati (board + telefono).');
      });
    } else if (ack.startsWith('E,')) {
      _snack('Board: $ack');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  void _refresh() {
    setState(() => _loadingDump = true);
    widget.protocol.sendHistory();
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancellare tutti i dati?'),
        content: const Text(
            'Sei sicuro di voler cancellare tutti i dati storici, sia sulla '
            'board che sul telefono? Operazione irreversibile.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancella'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _clearing = true);
      widget.protocol.sendClear(); // wait for C,OK in _onAck
    }
  }

  Future<void> _save() async {
    if (widget.store.isEmpty) {
      _snack('Nessun dato da salvare.');
      return;
    }
    final file = await widget.store.exportCsv();
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'Smart Wearables - dati storici',
    );
  }

  // --- bucketing helpers ---

  /// Sum of step deltas per 30-min bin.
  List<_TimePoint> _stepsPerBin(List<HistoryRecord> recs) {
    final map = <int, int>{};
    for (final r in recs) {
      final key = (r.ts ~/ _binSeconds) * _binSeconds;
      map[key] = (map[key] ?? 0) + r.steps;
    }
    final keys = map.keys.toList()..sort();
    return keys
        .map((k) => _TimePoint(
            DateTime.fromMillisecondsSinceEpoch(k * 1000), map[k]!.toDouble()))
        .toList();
  }

  /// Mean temperature (°C) per 30-min bin.
  List<_TimePoint> _tempPerBin(List<HistoryRecord> recs) {
    final sum = <int, int>{};
    final count = <int, int>{};
    for (final r in recs) {
      final key = (r.ts ~/ _binSeconds) * _binSeconds;
      sum[key] = (sum[key] ?? 0) + r.tempC100;
      count[key] = (count[key] ?? 0) + 1;
    }
    final keys = sum.keys.toList()..sort();
    return keys
        .map((k) => _TimePoint(
              DateTime.fromMillisecondsSinceEpoch(k * 1000),
              (sum[k]! / count[k]!) / 100.0,
            ))
        .toList();
  }

  @override
  void dispose() {
    _historySub.cancel();
    _ackSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final synced = widget.store.syncedRecords;
    final hrPoints = synced
        .where((r) => r.hrValid)
        .map((r) => _TimePoint(
            DateTime.fromMillisecondsSinceEpoch(r.ts * 1000),
            r.hr.toDouble()))
        .toList();
    final spo2Points = synced
        .where((r) => r.spo2Valid)
        .map((r) => _TimePoint(
            DateTime.fromMillisecondsSinceEpoch(r.ts * 1000), r.spo2))
        .toList();
    final stepPoints = _stepsPerBin(synced);
    final tempPoints = _tempPerBin(synced);
    final unsynced = widget.store.unsyncedCount;

    return Column(
      children: [
        _buildToolbar(),
        if (unsynced > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '$unsynced record con timestamp non sincronizzato nascosti dai grafici.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        Expanded(
          child: widget.store.isEmpty
              ? const Center(
                  child: Text('Nessun dato. Premi Aggiorna per scaricare.'))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _lineChart('HR (bpm)', hrPoints, Colors.red),
                    _lineChart('SpO2 (%)', spo2Points, Colors.blue),
                    _barChart('Passi per mezz\'ora', stepPoints, Colors.green),
                    _barChart('Temperatura media per mezz\'ora (°C)',
                        tempPoints, Colors.orange),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: (_loadingDump || _clearing) ? null : _refresh,
              icon: _loadingDump
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('Aggiorna'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: (_loadingDump || _clearing) ? null : _save,
              icon: const Icon(Icons.save_alt),
              label: const Text('Salva'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: (_loadingDump || _clearing) ? null : _clear,
              icon: _clearing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline),
              label: const Text('Cancella'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineChart(String title, List<_TimePoint> data, Color color) {
    return SizedBox(
      height: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: SfCartesianChart(
              primaryXAxis: const DateTimeAxis(),
              series: <LineSeries<_TimePoint, DateTime>>[
                LineSeries<_TimePoint, DateTime>(
                  dataSource: data,
                  xValueMapper: (p, _) => p.time,
                  yValueMapper: (p, _) => p.value,
                  color: color,
                  markerSettings: const MarkerSettings(isVisible: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _barChart(String title, List<_TimePoint> data, Color color) {
    return SizedBox(
      height: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: SfCartesianChart(
              primaryXAxis: const DateTimeAxis(),
              series: <ColumnSeries<_TimePoint, DateTime>>[
                ColumnSeries<_TimePoint, DateTime>(
                  dataSource: data,
                  xValueMapper: (p, _) => p.time,
                  yValueMapper: (p, _) => p.value,
                  color: color,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
