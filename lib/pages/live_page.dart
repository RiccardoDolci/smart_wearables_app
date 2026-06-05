import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:smart_wearables_app/connection/ble_protocol.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

/// Live page: streams raw IR (P) + vitals (V). Shows the DC-removed AC IR
/// waveform and live HR / SpO2 / steps / temperature.
class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    required this.protocol,
    required this.resetTick,
  });

  final BleProtocol protocol;

  /// Incremented by the parent when we re-enter the Live tab, so the stale IR
  /// waveform is cleared and the stream restarts fresh.
  final ValueNotifier<int> resetTick;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _IrPoint {
  _IrPoint(this.x, this.y);
  final int x;
  final double y;
}

class _LivePageState extends State<LivePage> {
  static const int _maxPoints = 150; // ~5 s at 30 Hz
  static const int _dcWindow = 30; // ~1 s moving-average baseline

  late final StreamSubscription<List<int>> _irSub;
  late final StreamSubscription<Vitals> _vitalsSub;

  // Raw IR samples kept for the DC baseline window.
  final Queue<int> _rawWindow = Queue<int>();
  int _rawSum = 0;

  // AC points shown on the chart.
  final List<_IrPoint> _acPoints = [];
  int _sampleCounter = 0;

  Vitals? _vitals;

  @override
  void initState() {
    super.initState();
    _irSub = widget.protocol.irSamples.listen(_onIrBatch);
    _vitalsSub = widget.protocol.vitals.listen((v) {
      if (mounted) setState(() => _vitals = v);
    });
    widget.resetTick.addListener(_resetWaveform);
  }

  void _resetWaveform() {
    setState(() {
      _rawWindow.clear();
      _rawSum = 0;
      _acPoints.clear();
      _sampleCounter = 0;
    });
  }

  void _onIrBatch(List<int> samples) {
    for (final raw in samples) {
      _rawWindow.addLast(raw);
      _rawSum += raw;
      if (_rawWindow.length > _dcWindow) {
        _rawSum -= _rawWindow.removeFirst();
      }
      // AC = raw - moving-average baseline (DC removal).
      final baseline = _rawSum / _rawWindow.length;
      final ac = raw - baseline;

      _acPoints.add(_IrPoint(_sampleCounter++, ac));
      if (_acPoints.length > _maxPoints) {
        _acPoints.removeAt(0);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.resetTick.removeListener(_resetWaveform);
    _irSub.cancel();
    _vitalsSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _vitals;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            _VitalCard(
              label: 'HR',
              value: (v == null || !v.hrValid) ? '--' : '${v.hr}',
              unit: 'bpm',
              icon: Icons.favorite,
              color: Colors.red,
            ),
            _VitalCard(
              label: 'SpO2',
              value: (v == null || !v.spo2Valid)
                  ? '--'
                  : v.spo2.toStringAsFixed(1),
              unit: '%',
              icon: Icons.bloodtype,
              color: Colors.blue,
            ),
            _VitalCard(
              label: 'Passi',
              value: v == null ? '--' : '${v.steps}',
              unit: 'tot',
              icon: Icons.directions_walk,
              color: Colors.green,
            ),
            _VitalCard(
              label: 'Temp',
              value: v == null ? '--' : v.tempC.toStringAsFixed(2),
              unit: '°C',
              icon: Icons.thermostat,
              color: Colors.orange,
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('IR (AC, smussato)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(
          height: 280,
          child: SfCartesianChart(
            primaryXAxis: const NumericAxis(isVisible: false),
            primaryYAxis: const NumericAxis(isVisible: false),
            series: <LineSeries<_IrPoint, int>>[
              LineSeries<_IrPoint, int>(
                dataSource: _acPoints,
                xValueMapper: (p, _) => p.x,
                yValueMapper: (p, _) => p.y,
                color: Colors.deepOrange,
                animationDuration: 0,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VitalCard extends StatelessWidget {
  const _VitalCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.grey)),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(value,
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 4),
                      Text(unit,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
