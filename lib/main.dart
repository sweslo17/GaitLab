import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'gait_engine.dart';
import 'session_recorder.dart';
import 'recording_guard.dart';

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
        seedColor: const Color(0xff6be0c3),
        brightness: Brightness.dark,
      ),
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

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  Timer? _refreshTimer;
  SessionRecorder? _recorder;
  late final RecordingSessionGuard _recordingGuard;
  Future<void>? _pendingFlush;
  GaitEngine _engine = GaitEngine();
  SessionMetrics _metrics = SessionMetrics();
  MotionAnalysis _motion = MotionAnalysis();
  SessionStartGate? _startGate;
  bool _calibrateDirections = false, _screenFacesBody = true;
  String _lastCalibrationStatus = 'disabled';
  int _exportedMetricPoints = 0;
  bool _targetEnabled = false;
  RangeValues _targetRange = const RangeValues(160, 180);

  CadenceTarget? get _configuredTarget => _targetEnabled
      ? CadenceTarget(minSpm: _targetRange.start, maxSpm: _targetRange.end)
      : null;

  void _recordMetricPoints() {
    final points = _metrics.trends;
    while (_exportedMetricPoints < points.length) {
      _recorder?.addMetric(points[_exportedMetricPoints++]);
    }
  }

  void _finishMetrics() {
    _motion.finish();
    _metrics.finish();
    _recordMetricPoints();
  }

  bool _running = false;
  bool _busy = false;
  bool _disposing = false;
  bool _wakelockEnabled = false;
  String? _pendingStopReason;
  DateTime? _lastAccelerometerArrival;
  final Stopwatch _sessionWatch = Stopwatch();
  String _message = '固定手機後開始紀錄；位置與目標可在「紀錄設定」調整。';
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
    _recordingGuard = RecordingSessionGuard(
      onStopRequested: () {
        if (_disposing || !mounted) return;
        const reason = '已由通知停止並儲存。';
        if (_busy) {
          _pendingStopReason = reason;
        } else if (_running) {
          unawaited(_stop(reason: reason));
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (shouldStopRecordingForLifecycle(
      state,
      backgroundActive: _recordingGuard.active,
    )) {
      const reason = '此平台無法繼續背景錄製，已停止並儲存。';
      if (_running && !_busy) {
        unawaited(_stop(reason: reason));
      } else if (_busy) {
        _pendingStopReason = reason;
      }
    }
  }

  void _queueFlush() {
    final recorder = _recorder;
    if (recorder == null || _pendingFlush != null) return;
    _pendingFlush = recorder
        .flush()
        .catchError((Object error) {
          if (_running && !_busy) unawaited(_stop(reason: '寫入失敗：$error'));
        })
        .whenComplete(() => _pendingFlush = null);
  }

  Future<void> _start() async {
    if (_busy || _running || _disposing) return;
    _pendingStopReason = null;
    setState(() {
      _busy = true;
      _message = '初始化感測器…';
    });
    try {
      final guardResult = await _recordingGuard.start();
      final motion = MotionAnalysis(
        calibrate: _calibrateDirections && _placement == '後腰中央',
        screenFacesBody: _screenFacesBody,
      );
      final recorder = await SessionRecorder.start(
        placement: _placement,
        peakMultiplier: 0.62,
        target: _configuredTarget,
        backgroundRecordingEnabled: _recordingGuard.active,
        motionParameters: motion.parameters,
      );
      _engine = GaitEngine(peakMultiplier: 0.62);
      _metrics = SessionMetrics(target: _configuredTarget);
      _motion = motion;
      _startGate = SessionStartGate(
        startedAtUs: recorder.startedAt.microsecondsSinceEpoch,
        previousAccelerationTimestampUs:
            _startGate?.lastAccelerationTimestampUs,
        previousGyroscopeTimestampUs: _startGate?.lastGyroscopeTimestampUs,
      );
      _lastCalibrationStatus = _motion.calibrationStatus;
      _exportedMetricPoints = 0;
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
      _accelSubscription =
          accelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 10),
          ).listen(
            (e) {
              final timestamp = e.timestamp.microsecondsSinceEpoch;
              if (!_startGate!.accept(timestamp)) {
                final rejected = SampleResult(
                  vertical: 0,
                  filtered: 0,
                  stepDetected: false,
                  timestampUs: timestamp,
                  stepIntervalMs: null,
                  accepted: false,
                );
                _recorder?.addAcceleration(rejected, e.x, e.y, e.z);
                _metrics.observe(
                  timestampUs: timestamp,
                  engine: _engine,
                  sample: rejected,
                );
                return;
              }
              final r = _engine.process(
                timestampUs: e.timestamp.microsecondsSinceEpoch,
                ax: e.x,
                ay: e.y,
                az: e.z,
              );
              if (r.accepted) _lastSensorTs = r.timestampUs;
              _motion.addAcceleration(
                r.timestampUs,
                e.x,
                e.y,
                e.z,
                cadence: _engine.cadence,
                periodicity: _engine.periodicity,
              );
              _metrics.observe(
                timestampUs: r.timestampUs,
                engine: _engine,
                sample: r,
              );
              _lastAccelerometerArrival = DateTime.now();
              _recorder?.addAcceleration(r, e.x, e.y, e.z);
              if (r.stepDetected && r.stepTimestampUs != null) {
                _recorder?.addStep(
                  r.stepTimestampUs!,
                  r.stepIntervalMs,
                  _engine.cadence,
                );
              }
            },
            onError: (Object error) {
              final reason = '加速度計錯誤：$error';
              _pendingStopReason = reason;
              if (mounted && !_disposing && _running && !_busy) {
                unawaited(_stop(reason: reason));
              }
            },
            cancelOnError: true,
          );
      _gyroSubscription =
          gyroscopeEventStream(
            samplingPeriod: const Duration(milliseconds: 10),
          ).listen(
            (e) {
              _gyroSamples++;
              if (_startGate!.accept(
                e.timestamp.microsecondsSinceEpoch,
                gyroscope: true,
              )) {
                _motion.addGyroscope(
                  e.timestamp.microsecondsSinceEpoch,
                  e.x,
                  e.y,
                  e.z,
                );
              }
              _recorder?.addGyro(
                e.timestamp.microsecondsSinceEpoch,
                e.x,
                e.y,
                e.z,
              );
            },
            onError: (Object error) {
              _gyroUnavailable = true;
              if (mounted) setState(() => _message = '陀螺儀不可用：$error（仍可計算步頻）');
            },
            cancelOnError: true,
          );
      String? wakeWarning;
      try {
        if (!_recordingGuard.active) {
          await WakelockPlus.enable();
          _wakelockEnabled = true;
        }
      } catch (error) {
        wakeWarning = '無法保持螢幕常亮：$error；請手動避免鎖定螢幕。';
      }
      if (_disposing || !mounted) {
        await _accelSubscription?.cancel();
        await _gyroSubscription?.cancel();
        await _recorder?.close();
        if (_wakelockEnabled) await WakelockPlus.disable();
        _wakelockEnabled = false;
        await _recordingGuard.stop();
        _sessionWatch.stop();
        _recorder = null;
        return;
      }
      setState(() {
        _running = true;
        _message =
            wakeWarning ??
            (_gyroUnavailable
                ? '陀螺儀不可用；加速度計仍可進行候選步頻分析。'
                : _recordingGuard.active
                ? guardResult.notificationsAllowed
                      ? '收集中，可關閉螢幕；通知列可返回 App。'
                      : '收集中，可關閉螢幕；通知未獲允許，請從 App 停止。'
                : '收集中。此平台請保持畫面開啟。');
      });
      _refreshTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || !_running || _busy) return;
        final lastArrival = _lastAccelerometerArrival ?? _startedAt!;
        if (DateTime.now().difference(lastArrival) >
            const Duration(seconds: 5)) {
          unawaited(_stop(reason: '感測器超過 5 秒沒有新資料，已停止並儲存。'));
          return;
        }
        _elapsed = _sessionWatch.elapsed;
        final second = _elapsed.inSeconds;
        if (second != _lastQualitySecond && _lastSensorTs != null) {
          _lastQualitySecond = second;
          _recorder?.addQuality(_lastSensorTs!, _engine);
          _queueFlush();
        }
        _recordMetricPoints();
        final calibrationStatus = _motion.calibrationStatus;
        if (calibrationStatus != _lastCalibrationStatus) {
          _lastCalibrationStatus = calibrationStatus;
          if (WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) {
            unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
          }
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
      try {
        await _recorder?.close();
      } catch (_) {
        /* Keep primary error. */
      }
      _recorder = null;
      if (_wakelockEnabled) {
        try {
          await WakelockPlus.disable();
        } catch (_) {
          /* Best effort. */
        }
        _wakelockEnabled = false;
      }
      try {
        await _recordingGuard.stop();
      } catch (_) {
        /* Keep primary failure. */
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
    setState(() {
      _busy = true;
      _running = false;
    });
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _sessionWatch.stop();
    _elapsed = _sessionWatch.elapsed;
    Object? failure;
    try {
      await _accelSubscription?.cancel();
    } catch (error) {
      failure = error;
    }
    try {
      await _gyroSubscription?.cancel();
    } catch (error) {
      failure ??= error;
    }
    _accelSubscription = null;
    _gyroSubscription = null;
    try {
      await _pendingFlush;
      if (_lastSensorTs != null) {
        _recorder?.addQuality(_lastSensorTs!, _engine);
      }
      _finishMetrics();
      await _recorder?.close();
      await _recorder?.saveSummary(
        _engine,
        stopReason: reason ?? 'user',
        metrics: _metrics,
        motion: _motion,
        startGate: _startGate,
        recordingSeconds: _elapsed.inMicroseconds / 1e6,
      );
    } catch (error) {
      failure ??= error;
      try {
        await _recorder?.close();
      } catch (_) {
        /* Preserve the first failure. */
      }
    }
    try {
      await _recordingGuard.stop();
    } catch (error) {
      failure ??= error;
    }
    if (_wakelockEnabled) {
      try {
        await WakelockPlus.disable();
      } catch (error) {
        failure ??= error;
      }
      _wakelockEnabled = false;
    }
    if (mounted) {
      setState(() {
        _trace = _engine.waveform;
        _message = failure != null
            ? '儲存未完全成功：$failure（請檢查匯出的檔案）'
            : reason ?? '紀錄已儲存。可匯出 7 份原始資料、趨勢及摘要檔案。';
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
      await SharePlus.instance.share(
        ShareParams(
          text: 'GaitLab 跑步步態原始資料',
          files: recorder.files.map((f) => XFile(f.path)).toList(),
          sharePositionOrigin: rect,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _message = '匯出失敗：$error');
    }
  }

  Future<void> _disposeActiveSession() async {
    try {
      await _accelSubscription?.cancel();
      await _gyroSubscription?.cancel();
      if (_running) {
        _elapsed = _sessionWatch.elapsed;
        await _pendingFlush;
        _finishMetrics();
        await _recorder?.close();
        await _recorder?.saveSummary(
          _engine,
          stopReason: 'widget_disposed',
          metrics: _metrics,
          motion: _motion,
          startGate: _startGate,
          recordingSeconds: _elapsed.inMicroseconds / 1e6,
        );
      }
    } catch (_) {
      // Disposing cannot show an error, but files remain in app documents.
    } finally {
      try {
        await _recorder?.close();
      } catch (_) {
        /* Always attempt file cleanup. */
      }
      try {
        await _recordingGuard.stop();
      } catch (_) {
        /* Best effort during disposal. */
      }
      if (_wakelockEnabled) {
        try {
          await WakelockPlus.disable();
        } catch (_) {
          /* Best effort. */
        }
        _wakelockEnabled = false;
      }
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _recordingGuard.detach();
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
    final summary = _metrics.summary(
      recordingSeconds: _elapsed.inMicroseconds / 1e6,
    );
    final points = _metrics.trends;
    final comparison = summary['trend_comparison'] as Map<String, dynamic>;
    final hasTime = _elapsed > Duration.zero;
    final coverage = summary['usable_percent'] as num?;
    final targetPercent = summary['target_percent'] as num?;
    final usableSeconds = (summary['usable_seconds'] as num?)?.toDouble() ?? 0;
    final cadenceSeconds =
        (summary['cadence_available_seconds'] as num?)?.toDouble() ?? 0;
    final status = _engine.signalStatus;
    final experimentalCv =
        _engine.intervalsMs.length >= 6 && status.grade == SignalGrade.usable
        ? _engine.cvPercent.toStringAsFixed(1)
        : '—';
    return Scaffold(
      appBar: AppBar(
        title: const Text('GaitLab'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(
              child: Text(
                'v0.8',
                style: TextStyle(color: Color(0xffa9b9c1), fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text(
              '腰帶固定 · 即時步態分析',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '固定位置，觀察自己前後段的變化。',
              style: TextStyle(color: Color(0xffa9b9c1), fontSize: 13),
            ),
            const SizedBox(height: 14),
            _panel(
              Row(
                children: [
                  Icon(
                    _running ? Icons.fiber_manual_record : Icons.info_outline,
                    color: _running ? mint : Colors.amberAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _message,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: ExpansionTile(
                key: const ValueKey('recording-settings'),
                title: const Text('紀錄設定', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  '$_placement · ${_targetEnabled ? "目標 ${_targetRange.start.round()}–${_targetRange.end.round()} spm" : "未開啟目標"}',
                  style: const TextStyle(fontSize: 12),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  Row(
                    children: [
                      const Text('手機位置  ', style: TextStyle(fontSize: 13)),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _placement,
                          underline: const SizedBox.shrink(),
                          onChanged: (_running || _busy)
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setState(() {
                                      _placement = value;
                                      if (value != '後腰中央') {
                                        _calibrateDirections = false;
                                      }
                                    });
                                  }
                                },
                          items: const ['後腰中央', '前腰中央', '側腰（較不建議）']
                              .map(
                                (v) =>
                                    DropdownMenuItem(value: v, child: Text(v)),
                              )
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile.adaptive(
                    key: const ValueKey('motion-calibration-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('三向動作校正'),
                    subtitle: Text(
                      _placement == '後腰中央'
                          ? '開始後 10 秒內直立固定手機，再站直不動 5 秒。僅依下方固定方式估計方向。'
                          : '只支援後腰中央；其他位置仍可看整體動作與旋轉。',
                    ),
                    value: _calibrateDirections,
                    onChanged: (_running || _busy || _placement != '後腰中央')
                        ? null
                        : (v) => setState(() => _calibrateDirections = v),
                  ),
                  if (_calibrateDirections)
                    DropdownButtonFormField<bool>(
                      initialValue: _screenFacesBody,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '固定後的螢幕朝向'),
                      items: const [
                        DropdownMenuItem(value: true, child: Text('螢幕朝向身體')),
                        DropdownMenuItem(value: false, child: Text('螢幕背向身體')),
                      ],
                      onChanged: (_running || _busy)
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => _screenFacesBody = v);
                              }
                            },
                    ),
                  SwitchListTile.adaptive(
                    key: const ValueKey('cadence-target-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('個人節奏目標', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      '自行設定範圍，沒有通用的理想步頻。',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: _targetEnabled,
                    onChanged: (_running || _busy)
                        ? null
                        : (value) => setState(() => _targetEnabled = value),
                  ),
                  if (_targetEnabled) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${_targetRange.start.round()}–${_targetRange.end.round()} spm · 套用於下一次紀錄',
                        style: const TextStyle(color: mint, fontSize: 13),
                      ),
                    ),
                    RangeSlider(
                      key: const ValueKey('cadence-target-range'),
                      min: 60,
                      max: 240,
                      divisions: 36,
                      values: _targetRange,
                      labels: RangeLabels(
                        '${_targetRange.start.round()}',
                        '${_targetRange.end.round()}',
                      ),
                      onChanged: (_running || _busy)
                          ? null
                          : (value) {
                              if (value.end - value.start >= 5) {
                                setState(() => _targetRange = value);
                              }
                            },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            if (_running) {
                              unawaited(_stop());
                            } else {
                              unawaited(_start());
                            }
                          },
                    icon: Icon(
                      _running ? Icons.stop_circle_outlined : Icons.play_arrow,
                    ),
                    label: Text(_running ? '停止並儲存' : '開始紀錄'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  _elapsedLabel,
                  style: const TextStyle(
                    fontSize: 22,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _metric(
                  '步頻',
                  _engine.cadence > 0
                      ? _engine.cadence.toStringAsFixed(0)
                      : '—',
                  'spm',
                  mint,
                ),
                const SizedBox(width: 10),
                _metric(
                  '候選步數',
                  _engine.acceptedSamples > 0 ? '${_engine.stepCount}' : '—',
                  '步',
                  Colors.white,
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '由候選事件估計；品質良好也不代表計步準確。',
              style: TextStyle(fontSize: 11, color: Color(0xffa9b9c1)),
            ),
            const SizedBox(height: 16),
            MotionResults(
              analysis: _motion,
              elapsedSeconds: _elapsed.inMicroseconds / 1e6,
            ),
            const SizedBox(height: 12),
            SessionTrendResults(comparison: comparison),
            const SizedBox(height: 12),
            _panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '步頻時間圖',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '最近 120 秒 · 中斷區段不連線',
                    style: TextStyle(fontSize: 11, color: Color(0xffa9b9c1)),
                  ),
                  const SizedBox(height: 10),
                  MetricTrendChart(
                    points: points,
                    series: MetricSeries.cadence,
                    target: _metrics.target,
                  ),
                  const SizedBox(height: 8),
                  const Wrap(
                    spacing: 14,
                    runSpacing: 5,
                    children: [
                      _QualityLegend('可參考', mint),
                      _QualityLegend('待檢查', Colors.amberAccent),
                      _QualityLegend('訊號偏弱', Color(0xff81929c)),
                      _QualityLegend('中斷／不連續', Color(0xffff8a80)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '這次紀錄',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  _summaryRow(
                    '品質達標時間',
                    hasTime ? _durationText(usableSeconds) : '—',
                  ),
                  _summaryRow(
                    '占錄製時間',
                    hasTime && coverage != null
                        ? '${coverage.toStringAsFixed(1)}%'
                        : '—',
                  ),
                  _summaryRow(
                    '目標範圍內',
                    _metrics.target == null
                        ? '未設定'
                        : targetPercent == null
                        ? '—'
                        : '${targetPercent.toStringAsFixed(1)}%',
                  ),
                  if (_metrics.target != null)
                    Text(
                      '本次目標 ${_metrics.target!.minSpm.round()}–${_metrics.target!.maxSpm.round()} spm；'
                      '分母為品質達標且有步頻的 ${_durationText(cadenceSeconds)}。',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xffa9b9c1),
                        height: 1.5,
                      ),
                    ),
                  const SizedBox(height: 6),
                  const Text(
                    '品質達標依取樣連續性與訊號條件判定，不是準確度保證。',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xffa9b9c1),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.insights,
                        color: _gradeColor(status.grade),
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '紀錄品質',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        _gradeLabel(status.grade),
                        style: TextStyle(
                          color: _gradeColor(status.grade),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status.explanation,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '實際取樣 ${_engine.actualHz.toStringAsFixed(0)} Hz'
                    ' · 近 5 秒估計缺樣 ${_engine.recentLossPercent.toStringAsFixed(1)}%'
                    ' · 中斷 ${_engine.samplingGaps} 次',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffa9b9c1),
                      height: 1.5,
                    ),
                  ),
                  Text(
                    _gyroUnavailable ? '陀螺儀不可用' : '陀螺儀樣本 $_gyroSamples',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffa9b9c1),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ExpansionTile(
                title: const Text('詳細數值與圖表', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '實驗性指標 · 同人、同裝置、同固定方式比較',
                  style: TextStyle(fontSize: 11),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _trendDetail(
                    '候選步間隔變異',
                    '$experimentalCv %',
                    'CV 是候選間隔的標準差／平均值。漏步、多算或被排除的間隔會影響結果；不是左右不對稱。',
                    MetricSeries.intervalCv,
                    points,
                  ),
                  _trendDetail(
                    '腰部訊號幅度',
                    _engine.acceptedSamples >= 220
                        ? '${_engine.signalRms.toStringAsFixed(2)} m/s²'
                        : '—',
                    '濾波後加速度的 RMS；只比較相近條件的訊號變化，不是衝擊力或人體重心位移。',
                    MetricSeries.rms,
                    points,
                  ),
                  _trendDetail(
                    '訊號規律性',
                    _engine.acceptedSamples >= 220
                        ? _engine.periodicity.toStringAsFixed(2)
                        : '—',
                    '波形重複程度，範圍 0–1。高值可能來自腰帶振動，不是跑姿分數或準確率。',
                    MetricSeries.periodicity,
                    points,
                  ),
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('即時濾波加速度', style: TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 120,
                    width: double.infinity,
                    child: CustomPaint(painter: _WaveformPainter(_trace, mint)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: !_running && !_busy && _recorder != null
                  ? _export
                  : null,
              icon: const Icon(Icons.ios_share),
              label: const Text('匯出原始資料、趨勢與摘要'),
            ),
            const SizedBox(height: 12),
            const ExpansionTile(
              leading: Icon(Icons.fact_check_outlined),
              title: Text('跑步腰帶測試流程', style: TextStyle(fontSize: 14)),
              childrenPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Text(
                  '後腰中央固定手機 → 站立 10 秒 → 走路 30 秒 → '
                  '平地慢跑 2–3 分鐘 → 停止 → 匯出。用人工計步或同步錄影比較候選步數；'
                  '每次保持腰帶鬆緊與手機位置一致。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '研究用途，尚未驗證實際跑步準確度。不提供接地時間、左右腳受力或受傷風險。'
              'Android 開始後可關閉螢幕；結束時回 App 停止並儲存。iOS 目前須保持前景。',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xffa9b9c1),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel(Widget child) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  Widget _summaryRow(String title, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  Widget _trendDetail(
    String title,
    String value,
    String explanation,
    MetricSeries series,
    List<MetricPoint> points,
  ) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title · $value',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        MetricTrendChart(points: points, series: series, height: 115),
        Text(
          explanation,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xffa9b9c1),
            height: 1.5,
          ),
        ),
      ],
    ),
  );

  Widget _metric(String label, String value, String unit, Color highlight) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xff1b2932),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 13, color: Color(0xffa9b9c1)),
              ),
              const SizedBox(height: 8),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 31,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        color: highlight,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(unit, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

String _durationText(double seconds) {
  final total = seconds.floor();
  return '${total ~/ 60} 分 ${total % 60} 秒';
}

String _gradeLabel(SignalGrade grade) => switch (grade) {
  SignalGrade.warmingUp => '暖機中',
  SignalGrade.stationary => '訊號偏弱',
  SignalGrade.unreliable => '不連續',
  SignalGrade.review => '待檢查',
  SignalGrade.usable => '可參考',
};

Color _gradeColor(SignalGrade grade) => switch (grade) {
  SignalGrade.usable => const Color(0xff6be0c3),
  SignalGrade.review => Colors.amberAccent,
  SignalGrade.unreliable => const Color(0xffff8a80),
  _ => const Color(0xff81929c),
};

class _QualityLegend extends StatelessWidget {
  const _QualityLegend(this.label, this.color);
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(
        label,
        style: const TextStyle(fontSize: 10, color: Color(0xffa9b9c1)),
      ),
    ],
  );
}

enum MetricSeries { cadence, intervalCv, rms, periodicity }

double? _metricValue(MetricPoint point, MetricSeries series) =>
    switch (series) {
      MetricSeries.cadence => point.cadenceSpm,
      MetricSeries.intervalCv => point.intervalCvPercent,
      MetricSeries.rms => point.signalRms,
      MetricSeries.periodicity => point.periodicity,
    };

class MetricTrendChart extends StatelessWidget {
  const MetricTrendChart({
    super.key,
    required this.points,
    required this.series,
    this.target,
    this.height = 170,
  });
  final List<MetricPoint> points;
  final MetricSeries series;
  final CadenceTarget? target;
  final double height;

  @override
  Widget build(BuildContext context) {
    final end = points.isEmpty
        ? 0.0
        : points.last.elapsedSeconds + points.last.durationSeconds;
    final start = math.max(0.0, end - 120);
    final visible = points
        .where((p) => p.elapsedSeconds + p.durationSeconds >= start)
        .toList();
    final hasValues = visible.any(
      (p) => !p.gap && _metricValue(p, series) != null,
    );
    final label = switch (series) {
      MetricSeries.cadence => '等待符合品質條件的步頻',
      MetricSeries.intervalCv => '等待足夠且符合品質條件的候選間隔',
      _ => '等待感測資料完成暖機',
    };
    return Semantics(
      excludeSemantics: true,
      label: hasValues ? '最近 120 秒的${_seriesLabel(series)}趨勢' : label,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _MetricTrendPainter(
                  visible,
                  series,
                  start,
                  math.max(start + 10, end),
                  target,
                ),
              ),
            ),
            if (!hasValues)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffa9b9c1),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricTrendPainter extends CustomPainter {
  _MetricTrendPainter(
    this.points,
    this.series,
    this.start,
    this.end,
    this.target,
  );
  final List<MetricPoint> points;
  final MetricSeries series;
  final double start, end;
  final CadenceTarget? target;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(
      32,
      10,
      math.max(33, size.width - 6),
      math.max(11, size.height - 32),
    );
    final values = points
        .where((p) => !p.gap)
        .map((p) => _metricValue(p, series))
        .whereType<double>()
        .toList();
    final upper = switch (series) {
      MetricSeries.cadence => 240.0,
      MetricSeries.periodicity => 1.0,
      MetricSeries.intervalCv => math.max(
        10.0,
        values.isEmpty ? 10.0 : values.reduce(math.max) * 1.2,
      ),
      MetricSeries.rms => math.max(
        2.0,
        values.isEmpty ? 2.0 : values.reduce(math.max) * 1.2,
      ),
    };
    final lower = series == MetricSeries.cadence ? 60.0 : 0.0;
    double x(double t) =>
        area.left + ((t - start) / (end - start)).clamp(0, 1) * area.width;
    double y(double value) =>
        area.bottom -
        ((value - lower) / (upper - lower)).clamp(0, 1) * area.height;
    if (series == MetricSeries.cadence && target != null) {
      canvas.drawRect(
        Rect.fromLTRB(
          area.left,
          y(target!.maxSpm),
          area.right,
          y(target!.minSpm),
        ),
        Paint()..color = const Color(0xff6be0c3).withValues(alpha: .10),
      );
    }
    for (var i = 0; i < 3; i++) {
      final value = lower + (upper - lower) * i / 2;
      canvas.drawLine(
        Offset(area.left, y(value)),
        Offset(area.right, y(value)),
        Paint()
          ..color = const Color(0xff526775).withValues(alpha: .35)
          ..strokeWidth = .7,
      );
      _text(
        canvas,
        value.toStringAsFixed(
          series == MetricSeries.periodicity || series == MetricSeries.rms
              ? 1
              : 0,
        ),
        Offset(0, y(value) - 6),
      );
    }
    final path = Path();
    var connected = false;
    double? previousEnd;
    for (final point in points) {
      final value = _metricValue(point, series);
      final xx = x(point.elapsedSeconds + point.durationSeconds / 2);
      canvas.drawRect(
        Rect.fromLTRB(
          x(point.elapsedSeconds),
          area.bottom + 5,
          x(point.elapsedSeconds + point.durationSeconds),
          area.bottom + 9,
        ),
        Paint()
          ..color = point.gap
              ? const Color(0xffff8a80)
              : _gradeColor(point.grade),
      );
      if (point.gap || value == null || !value.isFinite) {
        connected = false;
        previousEnd = null;
        continue;
      }
      if (previousEnd != null && point.elapsedSeconds - previousEnd > .05) {
        connected = false;
      }
      if (connected) {
        path.lineTo(xx, y(value));
      } else {
        path.moveTo(xx, y(value));
      }
      canvas.drawCircle(
        Offset(xx, y(value)),
        1.6,
        Paint()..color = const Color(0xff6be0c3),
      );
      connected = true;
      previousEnd = point.elapsedSeconds + point.durationSeconds;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff6be0c3)
        ..strokeWidth = 1.7
        ..style = PaintingStyle.stroke,
    );
    _text(canvas, _axisTime(start), Offset(area.left, size.height - 15));
    final rightLabel = _axisTime(end);
    _text(
      canvas,
      rightLabel,
      Offset(math.max(area.left, area.right - 34), size.height - 15),
    );
  }

  String _axisTime(double seconds) =>
      '${seconds.floor() ~/ 60}:${(seconds.floor() % 60).toString().padLeft(2, '0')}';
  void _text(Canvas canvas, String value, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: const TextStyle(fontSize: 9, color: Color(0xffa9b9c1)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _MetricTrendPainter oldDelegate) => true;
}

String _seriesLabel(MetricSeries series) => switch (series) {
  MetricSeries.cadence => '候選步頻',
  MetricSeries.intervalCv => '候選間隔變異',
  MetricSeries.rms => '腰部訊號幅度',
  MetricSeries.periodicity => '訊號規律性',
};

/// Plain-language comparison; direction never means better or worse gait.
class SessionTrendResults extends StatelessWidget {
  const SessionTrendResults({super.key, required this.comparison});
  final Map<String, dynamic> comparison;

  @override
  Widget build(BuildContext context) {
    final status = comparison['status'] as String? ?? 'collecting';
    final metrics = (comparison['metrics'] as Map?) ?? {};
    final ready = status == 'ready';
    final cadenceChanged = status == 'cadence_changed';
    final title = switch (status) {
      'ready' => '與前段相比',
      'cadence_changed' => '步頻改變，動作比較暫停',
      'insufficient_quality' => '可用資料不足，暫時無法比較',
      _ => '還沒有兩段可比較的資料',
    };
    final hint = switch (status) {
      'ready' => '增減描述訊號變化，不代表變好或變差。',
      'cadence_changed' => '兩段候選步頻差異超過 5%。先確認節奏與活動是否相近，再比較動作訊號。',
      'insufficient_quality' => '每段需要至少 24 秒符合品質條件。請固定手機並檢查中斷或訊號偏弱區段。',
      _ => '需要前後兩段各 30 秒的資料。固定手機後持續走跑；資料足夠時會顯示比較。',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(hint, style: const TextStyle(fontSize: 13, height: 1.5)),
            if (ready || cadenceChanged) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    '前段 ${_window("baseline")}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffa9b9c1),
                    ),
                  ),
                  Text(
                    '最近 ${_window("recent")}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffa9b9c1),
                    ),
                  ),
                ],
              ),
              if (ready) ...[
                _result('訊號幅度', metrics['rms'], 'm/s²', 2, relative: true),
                _result('訊號規律性', metrics['periodicity'], '', 2),
                _result(
                  '候選間隔變異',
                  metrics['interval_cv'],
                  '%',
                  1,
                  percentagePoints: true,
                ),
              ],
              _result('候選步頻', metrics['cadence'], 'spm', 0),
              const SizedBox(height: 8),
              const Text(
                '手機位置固定才適合比較。步頻接近仍不代表配速或坡度相同。',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xffa9b9c1),
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _window(String prefix) {
    String time(Object? value) {
      if (value is! num) return '—';
      final seconds = value.floor();
      return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    }

    return '${time(comparison['${prefix}_start_s'])}–${time(comparison['${prefix}_end_s'])}';
  }

  Widget _result(
    String name,
    Object? raw,
    String unit,
    int digits, {
    bool relative = false,
    bool percentagePoints = false,
  }) {
    final metric = raw is Map ? raw : null;
    final before = metric?['baseline'] as num?;
    final after = metric?['recent'] as num?;
    final delta = metric?['delta'] as num?;
    final percent = metric?['relative_percent'] as num?;
    String change = '資料不足';
    if (delta != null) {
      final amount = relative ? percent : delta;
      if (amount == null) {
        change = '基準為零，不計算變化比例';
      } else {
        final precision = relative || percentagePoints ? 1 : digits;
        final rounded = double.parse(amount.toStringAsFixed(precision));
        final direction = rounded > 0
            ? (percentagePoints || relative ? '增加' : '上升')
            : rounded < 0
            ? (percentagePoints || relative ? '減少' : '下降')
            : '顯示精度內無變化';
        final suffix = relative
            ? '%'
            : percentagePoints
            ? ' 百分點'
            : unit.isEmpty
            ? ''
            : ' $unit';
        change = rounded == 0
            ? direction
            : '$direction ${rounded.abs().toStringAsFixed(precision)}$suffix';
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: const TextStyle(fontSize: 14, color: Color(0xffa9b9c1)),
          ),
          const SizedBox(height: 3),
          Text(
            change,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          if (before != null && after != null)
            Text(
              '前段 ${before.toStringAsFixed(digits)} → 最近 ${after.toStringAsFixed(digits)}${unit.isEmpty ? '' : ' $unit'}',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xffa9b9c1),
                height: 1.5,
              ),
            ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter(this.points, this.color);
  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xff526775).withValues(alpha: 0.35)
      ..strokeWidth = 0.8;
    for (var i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset.zero.translate(0, y), Offset(size.width, y), grid);
    }
    if (points.length < 3) return;
    final maxAbs = math.max(
      3.0,
      points.map((v) => v.abs()).reduce(math.max) * 1.15,
    );
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i * size.width / (points.length - 1);
      final y = size.height / 2 - points[i] * (size.height * .43 / maxAbs);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}

String _motionStateLabel(MotionState state) => switch (state) {
  MotionState.quiet => '靜止訊號',
  MotionState.rhythmic => '規律移動',
  MotionState.other => '其他移動',
  MotionState.rotation => '明顯轉動',
  MotionState.unavailable => '尚不可判讀',
};
Color _motionStateColor(MotionState state) => switch (state) {
  MotionState.quiet => const Color(0xff81929c),
  MotionState.rhythmic => const Color(0xff6be0c3),
  MotionState.other => Colors.amberAccent,
  MotionState.rotation => const Color(0xffc6adff),
  MotionState.unavailable => const Color(0xffb66f6a),
};

class MotionResults extends StatelessWidget {
  const MotionResults({
    super.key,
    required this.analysis,
    required this.elapsedSeconds,
  });
  final MotionAnalysis analysis;
  final double elapsedSeconds;
  @override
  Widget build(BuildContext context) {
    final bins = analysis.bins;
    final latest = bins.isEmpty ? null : bins.last;
    final state = analysis.calibrationStatus;
    final calibrationText = switch (state) {
      'disabled' => '三向分布尚未啟用。在「紀錄設定」開啟方向校正；僅支援後腰中央固定。',
      'preparing' =>
        '準備校正 · ${math.max(0, 10 - elapsedSeconds).ceil()} 秒後開始。將手機直立固定在後腰中央，接著保持直立不動 5 秒。',
      'collecting' =>
        '正在校正 · 請直立不動，約 ${math.max(0, 15 - elapsedSeconds).ceil()} 秒。',
      'ready' => '方向校正完成 · 依固定方式估計身體方向；位置變動後請重新紀錄校正。',
      _ => analysis.calibrationReason ?? '校正尚未完成，三向結果不可用。',
    };
    final direction =
        latest?.toJson()['direction_energy_percent'] as Map<String, dynamic>?;
    String value(double? v, String unit) =>
        v == null ? '尚無資料' : '${v.toStringAsFixed(2)} $unit';
    final stateTimes = {
      for (final s in MotionState.values)
        s: bins
            .where((b) => b.state == s)
            .fold<double>(0, (t, b) => t + b.durationSeconds),
    };
    List<MetricPoint> chart(bool rotation) => bins
        .map(
          (b) => MetricPoint(
            elapsedSeconds: b.startSeconds,
            durationSeconds: b.durationSeconds,
            cadenceSpm: null,
            intervalCvPercent: null,
            signalRms: rotation ? b.rotationRms : b.accelerationRms,
            periodicity: null,
            actualHz: null,
            grade: SignalGrade.review,
            gap: (rotation ? b.rotationRms : b.accelerationRms) == null,
          ),
        )
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '動作概況',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              latest == null ||
                      !bins.any((b) => b.state != MotionState.unavailable)
                  ? '尚無可判讀區段'
                  : latest.state == MotionState.unavailable
                  ? '最近區段尚不可判讀'
                  : '最近區段：${_motionStateLabel(latest.state)}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              '以下是實驗性訊號分類；規律移動不區分走或跑，明顯轉動也不等於路線轉彎。',
              style: TextStyle(fontSize: 12, color: Color(0xffa9b9c1)),
            ),
            const SizedBox(height: 12),
            _MotionStateTimeline(bins: bins),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final s in MotionState.values)
                  Chip(
                    avatar: Icon(
                      Icons.circle,
                      size: 10,
                      color: _motionStateColor(s),
                    ),
                    label: Text(
                      '${_motionStateLabel(s)} ${stateTimes[s]!.toStringAsFixed(0)} 秒',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            const Divider(height: 28),
            Wrap(
              spacing: 24,
              runSpacing: 14,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('整體動作幅度'),
                    Text(
                      value(latest?.accelerationRms, 'm/s²'),
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('旋轉強度'),
                    Text(
                      value(latest?.rotationRms, 'rad/s'),
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '每秒均方根（RMS）；是手機的加速度與角速度，不是衝擊力或骨盆角度。',
              style: TextStyle(fontSize: 12, color: Color(0xffa9b9c1)),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看動作與旋轉趨勢'),
              subtitle: const Text('最近 120 秒 · 缺值不連線'),
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('整體動作幅度 · m/s²'),
                ),
                Semantics(
                  excludeSemantics: true,
                  label: '最近120秒整體動作幅度，單位公尺每秒平方',
                  child: MetricTrendChart(
                    points: chart(false),
                    series: MetricSeries.rms,
                    height: 130,
                  ),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('旋轉強度 · rad/s'),
                ),
                Semantics(
                  excludeSemantics: true,
                  label: '最近120秒旋轉強度，單位弧度每秒',
                  child: MetricTrendChart(
                    points: chart(true),
                    series: MetricSeries.rms,
                    height: 130,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text(
              '三向動作分布',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(calibrationText, style: const TextStyle(fontSize: 13)),
            if (state == 'ready' && latest?.forwardRms != null) ...[
              const SizedBox(height: 10),
              if (direction == null)
                const Text('幅度過小，暫不計算三向比例。')
              else ...[
                for (final item in [
                  ('前後', 'forward'),
                  ('左右', 'lateral'),
                  ('上下', 'vertical'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item.$1} ${(direction[item.$2] as num).toStringAsFixed(0)}%',
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: (direction[item.$2] as num).toDouble() / 100,
                          minHeight: 6,
                          semanticsLabel: '${item.$1}平方幅度占比',
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 6),
              Text(
                '方向幅度：前後 ${latest!.forwardRms!.toStringAsFixed(2)}、左右 ${latest.lateralRms!.toStringAsFixed(2)}、上下 ${latest.verticalRms!.toStringAsFixed(2)} m/s²。',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            const SizedBox(height: 6),
            const Text(
              '比例是平方幅度占比，依固定方式估計；只適合在相同位置與條件下看變化，不代表位移或效率。',
              style: TextStyle(fontSize: 12, color: Color(0xffa9b9c1)),
            ),
          ],
        ),
      ),
    );
  }
}

class _MotionStateTimeline extends StatelessWidget {
  const _MotionStateTimeline({required this.bins});
  final List<MotionBin> bins;
  @override
  Widget build(BuildContext context) {
    final end = bins.isEmpty
        ? 0.0
        : bins.last.startSeconds + bins.last.durationSeconds;
    final start = math.max(0.0, end - 120), span = math.max(1.0, end - start);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('狀態時間軸 · 最近 120 秒', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        SizedBox(
          height: 20,
          child: LayoutBuilder(
            builder: (context, size) => Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: const Color(0xff34434d)),
                ),
                for (final b in bins.where(
                  (b) => b.startSeconds + b.durationSeconds > start,
                ))
                  Positioned(
                    left:
                        (math.max(start, b.startSeconds) - start) /
                        span *
                        size.maxWidth,
                    width:
                        (math.min(end, b.startSeconds + b.durationSeconds) -
                            math.max(start, b.startSeconds)) /
                        span *
                        size.maxWidth,
                    top: 0,
                    bottom: 0,
                    child: Semantics(
                      label:
                          '${b.startSeconds.toStringAsFixed(0)} 秒起，${_motionStateLabel(b.state)}，${b.durationSeconds.toStringAsFixed(1)} 秒',
                      child: ColoredBox(color: _motionStateColor(b.state)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
