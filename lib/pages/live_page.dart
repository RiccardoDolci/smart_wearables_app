import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:smart_wearables_app/connection/ble_protocol.dart';

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
  // How many seconds of waveform to keep on screen.
  static const int _windowSeconds = 5;

  // DC-baseline window, in seconds. MUST be longer than one pulse period: a
  // resting heart beats at ~1 Hz, so a 1 s moving-average baseline would cancel
  // the heartbeat itself and flatten the AC trace. ~3 s passes 0.5–3 Hz pulses
  // while still tracking slow baseline wander.
  static const int _dcSeconds = 3;

  // EMA smoothing factor for the displayed AC value. High enough to keep the
  // pulse, low enough to take the sensor fuzz off the line.
  static const double _acAlpha = 0.4;

  // EMA factor for the Y auto-scale bounds. Small = slow adaptation, so the
  // trace stops jumping/rescaling on every frame.
  static const double _yAlpha = 0.15;

  // IR sample rate (Hz). The authoritative value comes from the board's `I`
  // frame. The firmware streams 25 Hz / 3 ≈ 8.3 Hz and declares 8 in the `I`
  // frame (app_config.h: IR_STREAM_HZ), so default to 8 — matching the firmware
  // — so a dropped/late `I` frame degrades to a near-correct time scale instead
  // of the ~3.6x-too-fast axis a 30 Hz default would produce.
  int _irHz = 8;

  // Sliding-window width in samples (~5 s) and the DC-baseline window (~3 s).
  // Derived from the real rate so the time scale stays correct if the board
  // decimates differently.
  int get _maxPoints => _irHz * _windowSeconds;
  int get _dcWindow => _irHz * _dcSeconds;

  late final StreamSubscription<List<int>> _irSub;
  late final StreamSubscription<Vitals> _vitalsSub;
  late final StreamSubscription<List<int>> _infoSub;

  // Raw IR samples kept for the DC baseline window.
  final Queue<int> _rawWindow = Queue<int>();
  int _rawSum = 0;

  // AC points shown on the chart.
  final List<_IrPoint> _acPoints = [];
  int _sampleCounter = 0;

  // EMA-smoothed AC value for display.
  double _acSmoothed = 0;
  bool _acInit = false;

  // Smoothed Y auto-scale bounds (null until the first batch).
  double? _yLo;
  double? _yHi;

  Vitals? _vitals;

  // --- live arming / retry ---------------------------------------------------
  // The board only streams after it receives `L`. The first `L` after a fresh
  // connect is easily lost — service discovery / notify-enable are still
  // settling, so the reply races an un-subscribed phone. We wait one settle
  // interval before the first `L`, then resend on the same cadence until live
  // data actually arrives.
  Timer? _liveArmTimer;
  int _liveArmAttempts = 0;
  bool _gotLiveData = false;
  static const int _maxLiveArmAttempts = 6;
  static const Duration _liveArmRetry = Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    _irSub = widget.protocol.irSamples.listen((samples) {
      _markLiveData();
      _onIrBatch(samples);
    });
    _vitalsSub = widget.protocol.vitals.listen((v) {
      _markLiveData();
      if (mounted) setState(() => _vitals = v);
    });
    // I,<proto_ver>,<ir_hz>,<vitals_period_s>: adopt the real IR rate so the
    // time window and DC baseline track the board.
    _infoSub = widget.protocol.info.listen((info) {
      _markLiveData();
      if (info.length >= 2 && info[1] > 0 && mounted) {
        setState(() => _irHz = info[1]);
      }
    });
    widget.resetTick.addListener(_onResetTick);
    // Kick off streaming and keep retrying until the board responds.
    _armLive();
  }

  // Re-entering Live: clear the stale waveform and re-arm streaming.
  void _onResetTick() {
    _resetWaveform();
    _armLive();
  }

  // Send `L` and keep resending on a timer until any live frame (I/P/V) lands.
  // The first `L` waits one settle interval so it doesn't race connect-time
  // service discovery / notify-enable.
  void _armLive() {
    _liveArmTimer?.cancel();
    _gotLiveData = false;
    _liveArmAttempts = 0;
    _liveArmTimer = Timer(_liveArmRetry, _trySendLive);
  }

  void _trySendLive() {
    if (!mounted || _gotLiveData) return;
    if (_liveArmAttempts >= _maxLiveArmAttempts) {
      _liveArmTimer?.cancel();
      _liveArmTimer = null;
      debugPrint('Live: no data after $_liveArmAttempts L attempts; giving up.');
      return;
    }
    _liveArmAttempts++;
    widget.protocol.sendLive();
    debugPrint('Live: sent L (attempt $_liveArmAttempts)');
    _liveArmTimer?.cancel();
    _liveArmTimer = Timer(_liveArmRetry, _trySendLive);
  }

  // First live frame after arming: the board heard us, stop resending `L`.
  void _markLiveData() {
    if (_gotLiveData) return;
    _gotLiveData = true;
    _liveArmTimer?.cancel();
    _liveArmTimer = null;
    debugPrint('Live: data flowing after $_liveArmAttempts L attempt(s).');
  }

  void _resetWaveform() {
    setState(() {
      _rawWindow.clear();
      _rawSum = 0;
      _acPoints.clear();
      _sampleCounter = 0;
      _acSmoothed = 0;
      _acInit = false;
      _yLo = null;
      _yHi = null;
      // Drop the last session's vitals too, so the cards show '--' until the
      // first fresh V frame instead of stale numbers for up to 10 s (the
      // firmware's VITALS_PERIOD_S).
      _vitals = null;
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

      // Light EMA so the line isn't fuzzy; alpha is high enough to keep the pulse.
      if (!_acInit) {
        _acSmoothed = ac;
        _acInit = true;
      } else {
        _acSmoothed = _acAlpha * ac + (1 - _acAlpha) * _acSmoothed;
      }

      _acPoints.add(_IrPoint(_sampleCounter++, _acSmoothed));
      if (_acPoints.length > _maxPoints) {
        _acPoints.removeAt(0);
      }
    }
    _updateYBounds();
    if (mounted) setState(() {});
  }

  // Recompute the auto-scale bounds over the most recent ~3 s and ease the
  // smoothed bounds toward them. Doing this here (not in build) keeps build pure
  // and means the viewport adapts slowly instead of snapping every frame.
  void _updateYBounds() {
    if (_acPoints.isEmpty) return;
    final recent = _irHz * 3;
    final start = _acPoints.length > recent ? _acPoints.length - recent : 0;
    var lo = _acPoints[start].y;
    var hi = lo;
    for (var i = start + 1; i < _acPoints.length; i++) {
      final y = _acPoints[i].y;
      if (y < lo) lo = y;
      if (y > hi) hi = y;
    }
    if (_yLo == null || _yHi == null) {
      _yLo = lo;
      _yHi = hi;
    } else {
      _yLo = _yAlpha * lo + (1 - _yAlpha) * _yLo!;
      _yHi = _yAlpha * hi + (1 - _yAlpha) * _yHi!;
    }
  }

  @override
  void dispose() {
    _liveArmTimer?.cancel();
    widget.resetTick.removeListener(_onResetTick);
    _irSub.cancel();
    _vitalsSub.cancel();
    _infoSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _vitals;
    // Fixed-width sliding viewport: newest sample sits at the right edge and the
    // waveform scrolls right-to-left from the very first sample, instead of
    // stretching to fill the width until the buffer is full.
    final double xMax = _sampleCounter.toDouble();
    final double xMin = xMax - _maxPoints;

    // Y bounds are the smoothed recent-amplitude envelope computed per batch in
    // _updateYBounds(), so the trace stays full-height and centred on the
    // current heartbeat without snapping on every frame.
    double? yMin, yMax;
    if (_yLo != null && _yHi != null) {
      final span = _yHi! - _yLo!;
      final pad = span < 1e-6 ? 1.0 : span * 0.12;
      yMin = _yLo! - pad;
      yMax = _yHi! + pad;
    }
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
        const Text('PPG',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 14, 12, 8),
            child: SizedBox(
              height: 220,
              width: double.infinity,
              // Custom-painted so the waveform repaints deterministically on
              // every setState. (Syncfusion's rebuild-diffing would stop
              // repainting the series once a vitals rebuild slipped in.)
              child: CustomPaint(
                painter: _WaveformPainter(
                  points: _acPoints,
                  xMin: xMin,
                  xMax: xMax,
                  yMin: yMin,
                  yMax: yMax,
                  irHz: _irHz,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints the AC IR waveform as a polyline inside a fixed-width sliding window.
/// X maps the sample counter onto [xMin, xMax] (newest at the right edge); Y maps
/// the AC value onto [yMin, yMax] (the most-recent-2 s range computed by the page).
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.points,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.irHz,
    required this.color,
  });

  final List<_IrPoint> points;
  final double xMin;
  final double xMax;
  final double? yMin;
  final double? yMax;
  final int irHz;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || yMin == null || yMax == null) return;
    final xSpan = xMax - xMin;
    if (xSpan <= 0) return;
    final ySpan = (yMax! - yMin!).abs() < 1e-9 ? 1.0 : (yMax! - yMin!);

    // Clip: samples older than the Y window can map off-canvas; keep them
    // inside the chart area instead of overflowing onto neighbouring widgets.
    canvas.clipRect(Offset.zero & size);

    // --- Reference grid: faint vertical line every second + a zero baseline,
    //     so the trace has a sense of time scale and amplitude centre. ---
    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.18)
      ..strokeWidth = 1.0;
    if (irHz > 0) {
      // Align the gridlines to whole-second sample boundaries within the window.
      final firstSecond = (xMin / irHz).ceil();
      for (var s = firstSecond;; s++) {
        final sampleX = s * irHz;
        if (sampleX > xMax) break;
        final dx = (sampleX - xMin) / xSpan * size.width;
        canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), gridPaint);
      }
    }
    // Zero baseline (AC == 0), only if it falls inside the current Y window.
    if (yMin! <= 0 && yMax! >= 0) {
      final dyZero = size.height - (0 - yMin!) / ySpan * size.height;
      final basePaint = Paint()
        ..color = Colors.grey.withValues(alpha: 0.35)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(0, dyZero), Offset(size.width, dyZero), basePaint);
    }

    final path = Path();
    var started = false;
    for (final p in points) {
      final dx = (p.x - xMin) / xSpan * size.width;
      final dy = size.height - (p.y - yMin!) / ySpan * size.height;
      if (!started) {
        path.moveTo(dx, dy);
        started = true;
      } else {
        path.lineTo(dx, dy);
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  // The page rebuilds this painter with fresh data on every setState, so always
  // repaint.
  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
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
