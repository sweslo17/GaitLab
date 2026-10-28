import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'gait_engine.dart';
import 'session_recorder.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GaitLabApp());
}

class GaitLabApp extends StatelessWidget {
  const GaitLabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'GaitLab',
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff6be0c3), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xff101820),
      cardTheme: const CardThemeData(color: Color(0xff1b2932)),
    ),
    home: const SessionScreen(),
  );
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> with WidgetsBindingObserver {
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  Timer? _refreshTimer;
  SessionRecorder? _recorder;
  GaitEngine _engine = GaitEngine();
  bool _running = false;
  bool _busy = false;
  bool _disposing = false;
  bool _wakelockEnabled = false;
  String? _pendingStopReason;
  DateTime? _lastAccelerometerArrival;
  final Stopwatch _sessionWatch = Stopwatch();
  String _message = '先選擇腰帶位置，將手機固定，再按開始。';
  String _placement = '後腰中央';
  int? _lastSensorTs;
  int _lastQualitySecond = -1;
  int _gyroSamples = 0;
  bool _gyroUnavailable = false;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  List<double> _trace = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // If the lifecycle changes DURING start-up, do not lose the stop request.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      const reason = 'App 已進入背景，本次紀錄自動結束，避免資料斷裂。';
      if (_running && !_busy) {
        unawaited(_stop(reason: reason));
      } else if (_busy) {
        _pendingStopReason = reason;
      }
    }
  }

  Future<void> _start() async {
    if (_busy || _running || _disposing) return;
    _pendingStopReason = null;
    setState(() { _busy = true; _message = '初始化感測器…'; });
    try {
      final recorder = await SessionRecorder.start(
        placement: _placement, peakMultiplier: 0.62);
      _engine = GaitEngine(peakMultiplier: 0.62);
      _lastSensorTs = null;
      _lastAccelerometerArrival = null;
      _lastQualitySecond = -1;
      _gyroSamples = 0;
      _gyroUnavailable = false;
      _recorder = recorder;
      _startedAt = DateTime.now();
      _sessionWatch
        ..reset()
        ..start();
      _elapsed = Duration.zero;
      _trace = [];
      // Requested ~100Hz, actual device rate is shown in the dashboard.
      _accelSubscription = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 10),
      ).listen((e) {
        final r = _engine.process(
          timestampUs: e.timestamp.microsecondsSinceEpoch,
          ax: e.x, ay: e.y, az: e.z,
        );
        if (r.accepted) _lastSensorTs = r.timestampUs;
        _lastAccelerometerArrival = DateTime.now();
        _recorder?.addAcceleration(r, e.x, e.y, e.z);
        if (r.stepDetected && r.stepTimestampUs != null) {
          _recorder?.addStep(
            r.stepTimestampUs!, r.stepIntervalMs, _engine.cadence);
        }
      }, onError: (Object error) {
        final reason = '加速度計錯誤：$error';
        _pendingStopReason = reason;
        if (mounted && !_disposing && _running && !_busy) {
          unawaited(_stop(reason: reason));
        }
      }, cancelOnError: true);
      _gyroSubscription = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: 10),
      ).listen((e) {
        _gyroSamples++;
        _recorder?.addGyro(e.timestamp.microsecondsSinceEpoch, e.x, e.y, e.z);
      }, onError: (Object error) {
        _gyroUnavailable = true;
        if (mounted) setState(() => _message = '陀螺儀不可用：$error（仍可計算步頻）');
      }, cancelOnError: true);
      String? wakeWarning;
      try {
        await WakelockPlus.enable();
        _wakelockEnabled = true;
      } catch (error) {
        wakeWarning = '無法保持螢幕常亮：$error；請手動避免鎖定螢幕。';
      }
      if (_disposing || !mounted) {
        await _accelSubscription?.cancel();
        await _gyroSubscription?.cancel();
        await _recorder?.close();
        if (_wakelockEnabled) await WakelockPlus.disable();
        _wakelockEnabled = false;
        _sessionWatch.stop();
        _recorder = null;
        return;
      }
      setState(() {
        _running = true;
        _message = wakeWarning ?? (_gyroUnavailable
            ? '陀螺儀不可用；加速度計仍可進行候選步頻分析。'
            : '收集中。請保持畫面開啟；數據是研究用途估計值。');
      });
      _refreshTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || !_running || _busy) return;
        final lastArrival = _lastAccelerometerArrival ?? _startedAt!;
        if (DateTime.now().difference(lastArrival) > const Duration(seconds: 5)) {
          unawaited(_stop(reason: '感測器超過 5 秒沒有新資料，已停止並儲存。'));
          return;
        }
        _elapsed = _sessionWatch.elapsed;
        final second = _elapsed.inSeconds;
        if (second != _lastQualitySecond && _lastSensorTs != null) {
          _lastQualitySecond = second;
          _recorder?.addQuality(_lastSensorTs!, _engine);
        }
        setState(() => _trace = _engine.waveform);
      });
    } catch (error) {
      await _accelSubscription?.cancel();
      await _gyroSubscription?.cancel();
      _accelSubscription = null;
      _gyroSubscription = null;
      _refreshTimer?.cancel();
      _refreshTimer = null;
      _sessionWatch.stop();
      try { await _recorder?.close(); } catch (_) { /* Keep primary error. */ }
      _recorder = null;
      if (_wakelockEnabled) {
        try { await WakelockPlus.disable(); } catch (_) { /* Best effort. */ }
        _wakelockEnabled = false;
      }
      if (mounted) setState(() => _message = '啟動失敗：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (_pendingStopReason != null && _running && mounted) {
        final reason = _pendingStopReason!;
        _pendingStopReason = null;
        unawaited(_stop(reason: reason));
      }
    }
  }

  Future<void> _stop({String? reason}) async {
    if (_busy || !_running || _disposing || !mounted) return;
    setState(() { _busy = true; _running = false; });
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _sessionWatch.stop();
    _elapsed = _sessionWatch.elapsed;
    Object? failure;
    try { await _accelSubscription?.cancel(); } catch (error) { failure = error; }
    try { await _gyroSubscription?.cancel(); } catch (error) { failure ??= error; }
    _accelSubscription = null;
    _gyroSubscription = null;
    try {
      if (_lastSensorTs != null) {
        _recorder?.addQuality(_lastSensorTs!, _engine);
      }
      await _recorder?.close();
      await _recorder?.saveSummary(_engine, stopReason: reason ?? 'user');
    } catch (error) {
      failure ??= error;
    }
    if (_wakelockEnabled) {
      try { await WakelockPlus.disable(); } catch (error) { failure ??= error; }
      _wakelockEnabled = false;
    }
    if (mounted) {
      setState(() {
        _trace = _engine.waveform;
        _message = failure != null
            ? '儲存未完全成功：$failure（請檢查匯出的檔案）'
            : reason ?? '紀錄已儲存。可匯出 6 份測量及診斷檔案。';
        _busy = false;
      });
    }
  }

  Future<void> _export() async {
    final recorder = _recorder;
    if (recorder == null || _running || _busy) return;
    final render = context.findRenderObject();
    final rect = render is RenderBox
        ? render.localToGlobal(Offset.zero) & render.size
        : null;
    try {
      await SharePlus.instance.share(ShareParams(
        text: 'GaitLab 跑步步態原始資料',
        files: recorder.files.map((f) => XFile(f.path)).toList(),
        sharePositionOrigin: rect,
      ));
    } catch (error) {
      if (mounted) setState(() => _message = '匯出失敗：$error');
    }
  }

  Future<void> _disposeActiveSession() async {
    try {
      await _accelSubscription?.cancel();
      await _gyroSubscription?.cancel();
      if (_running) {
        await _recorder?.close();
        await _recorder?.saveSummary(_engine, stopReason: 'widget_disposed');
      }
    } catch (_) {
      // Disposing cannot show an error, but files remain in app documents.
    } finally {
      if (_wakelockEnabled) {
        try { await WakelockPlus.disable(); } catch (_) { /* Best effort. */ }
        _wakelockEnabled = false;
      }
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _sessionWatch.stop();
    // A concurrent _stop or _start already owns cleanup when _busy is true.
    if (!_busy) unawaited(_disposeActiveSession());
    super.dispose();
  }

  String get _elapsedLabel {
    final m = _elapsed.inMinutes;
    final s = _elapsed.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    const mint = Color(0xff6be0c3);
    return Scaffold(
      appBar: AppBar(title: const Text('GaitLab'),
          actions: [Padding(padding: const EdgeInsets.only(right: 18),
            child: Center(child: Text('v0.3', style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant))))]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(18), children: [
        Text('RUNNING GAIT TELEMETRY', style: TextStyle(
          color: mint.withValues(alpha: 0.9), fontSize: 11, letterSpacing: 2.2,
          fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        const Text('腰帶固定 · 即時步態分析',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child:
          Row(children: [
            Icon(_running ? Icons.fiber_manual_record : Icons.info_outline,
              color: _running ? mint : Colors.amberAccent),
            const SizedBox(width: 12),
            Expanded(child: Text(_message, style: const TextStyle(height: 1.4))),
          ]))),
        const SizedBox(height: 10),
        Card(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(children: [
            const Text('手機位置  ', style: TextStyle(fontSize: 13)),
            Expanded(child: DropdownButton<String>(
              isExpanded: true, value: _placement,
              underline: const SizedBox.shrink(),
              onChanged: (_running || _busy) ? null : (value) {
                if (value != null) setState(() => _placement = value);
              },
              items: const ['後腰中央', '前腰中央', '側腰（較不建議）']
                .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                .toList(),
            )),
          ]))),
        const SizedBox(height: 12),
        Row(children: [
          _metric('步頻', _engine.cadence > 0 ? _engine.cadence.toStringAsFixed(0) : '—',
              'spm', mint),
          const SizedBox(width: 10),
          _metric('步伐時間', _engine.stepTimeMs > 0
              ? _engine.stepTimeMs.toStringAsFixed(0) : '—', 'ms', Colors.white),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _metric('步伐 CV', _engine.intervalsMs.length >= 6
              ? _engine.cvPercent.toStringAsFixed(1) : '—', '%', Colors.white),
          const SizedBox(width: 10),
          _metric('實際取樣率', _engine.actualHz > 0
              ? _engine.actualHz.toStringAsFixed(0) : '—', 'Hz', Colors.white),
        ]),
        const SizedBox(height: 13),
        Card(child: Padding(padding: const EdgeInsets.all(15), child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.insights,
                color: _engine.signalStatus.grade == SignalGrade.usable
                    ? mint : Colors.amberAccent, size: 19),
              const SizedBox(width: 8),
              const Expanded(child: Text('訊號品質 / QA',
                style: TextStyle(fontWeight: FontWeight.w700))),
              Text(_engine.signalStatus.grade.name.toUpperCase(),
                style: const TextStyle(fontSize: 11, letterSpacing: 1)),
            ]),
            const SizedBox(height: 8),
            Text(_engine.signalStatus.explanation,
              style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Text('週期相關 ${_engine.periodicity.toStringAsFixed(2)}（不是準確率）'
                 '  · 近5秒掉樣 ${_engine.recentLossPercent.toStringAsFixed(1)}%'
                 '  · 中斷 ${_engine.samplingGaps} 次',
              style: const TextStyle(fontSize: 12, color: Color(0xffb3bec4))),
            const SizedBox(height: 4),
            Text(_gyroUnavailable ? '陀螺儀不可用' : '陀螺儀樣本 $_gyroSamples',
              style: const TextStyle(fontSize: 12, color: Color(0xffb3bec4))),
          ]))),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('動態垂直加速度', style: TextStyle(fontSize: 16,
              fontWeight: FontWeight.w700)),
          Text(_elapsedLabel, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        const SizedBox(height: 10),
        Container(height: 174, decoration: BoxDecoration(
          color: const Color(0xff1b2932), borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.all(12),
          child: CustomPaint(painter: _WaveformPainter(_trace, mint),
             child: const SizedBox.expand())),
        const SizedBox(height: 10),
        Text('偵測步數 ${_engine.stepCount} · 每次固定手機位置，才能比較歷次數據。',
          style: const TextStyle(fontSize: 12, color: Color(0xffb3bec4))),
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: _busy ? null : () {
          if (_running) { unawaited(_stop()); } else { unawaited(_start()); }
        },
          icon: Icon(_running ? Icons.stop_circle_outlined : Icons.play_arrow),
          label: Text(_running ? '停止並儲存' : '開始紀錄'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: !_running && !_busy && _recorder != null ? _export : null,
          icon: const Icon(Icons.ios_share), label: const Text('匯出 CSV、品質紀錄與摘要')),
        const SizedBox(height: 12),
        const ExpansionTile(
          leading: Icon(Icons.fact_check_outlined),
          title: Text('跑步腰帶測試流程', style: TextStyle(fontSize: 14)),
          childrenPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [Text('後腰中央固定手機 → 站立 10 秒 → 走路 30 秒 → '
              '平地慢跑 2–3 分鐘 → 停止 → 匯出。'
              '用人工計步或同步錄影比較候選步數；'
              '每次保持腰帶鬆緊與手機位置一致。',
              style: TextStyle(fontSize: 12, height: 1.6))],
        ),
        const SizedBox(height: 12),
        const Text('v0.3：自適應峰值 + 週期性交叉檢查，計算的是候選步伐事件。'
          '不提供觸地時間、左右腳受力或傷害診斷。'
          'App 退至背景時將停止紀錄。為避免遺失感測資料，錄製時螢幕會保持亮起。',
          style: TextStyle(fontSize: 12, color: Color(0xffb3bec4), height: 1.5)),
      ])),
    );
  }

  Widget _metric(String label, String value, String unit, Color highlight) =>
    Expanded(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 18),
      decoration: BoxDecoration(color: const Color(0xff1b2932),
        borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 13, color: Color(0xffa9b9c1))),
        const SizedBox(height: 8),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value, style: TextStyle(fontSize: 31, height: 1.0,
              fontWeight: FontWeight.w800, color: highlight)),
            const SizedBox(width: 5),
            Padding(padding: const EdgeInsets.only(bottom: 3),
              child: Text(unit, style: const TextStyle(fontSize: 12))),
          ])),
      ])));
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter(this.points, this.color);
  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xff526775).withValues(alpha: 0.35)
      ..strokeWidth = 0.8;
    for (var i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset.zero.translate(0, y), Offset(size.width, y), grid);
    }
    if (points.length < 3) return;
    final maxAbs = math.max(3.0,
        points.map((v) => v.abs()).reduce(math.max) * 1.15);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i * size.width / (points.length - 1);
      final y = size.height / 2 - points[i] * (size.height * .43 / maxAbs);
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    canvas.drawPath(path, Paint()..color = color..strokeWidth = 1.8
      ..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}
