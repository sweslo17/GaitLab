import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'gait_engine.dart';

/// Separate streams: accel and gyro are NOT falsely joined by row number.
class SessionRecorder {
  SessionRecorder._(
    this.folder,
    this.accelerometer,
    this.gyroscope,
    this.steps,
    this.quality,
    this.metrics,
    this.startedAt,
    this.placement,
    this.peakMultiplier,
  );

  final Directory folder;
  final IOSink accelerometer;
  final IOSink gyroscope;
  final IOSink steps;
  final IOSink quality;
  final IOSink metrics;
  final DateTime startedAt;
  final String placement;
  final double peakMultiplier;
  bool _closed = false;
  Future<void>? _pendingFlush;
  Future<void>? _pendingClose;
  final Map<IOSink, List<String>> _bufferedLines = {};
  Object? _ioFailure;
  StackTrace? _ioFailureStack;

  void _writeln(IOSink sink, String line) {
    if (_closed) return;
    if (_pendingFlush != null) {
      (_bufferedLines[sink] ??= []).add(line);
    } else {
      sink.writeln(line);
    }
  }

  void _drainBufferedLines() {
    for (final entry in _bufferedLines.entries) {
      for (final line in entry.value) {
        entry.key.writeln(line);
      }
    }
    _bufferedLines.clear();
  }

  void _rememberFailure(Object error, StackTrace stack) {
    _ioFailure ??= error;
    _ioFailureStack ??= stack;
  }

  List<IOSink> get _sinks => [
    accelerometer,
    gyroscope,
    steps,
    quality,
    metrics,
  ];

  static Future<SessionRecorder> start({
    required String placement,
    required double peakMultiplier,
    CadenceTarget? target,
    bool backgroundRecordingEnabled = false,
    Map<String, dynamic>? motionParameters,
    Directory? rootDirectory,
  }) async {
    final root = rootDirectory ?? await getApplicationDocumentsDirectory();
    final now = DateTime.now().toUtc();
    final label = now.toIso8601String().replaceAll(':', '-');
    final folder = await Directory('${root.path}/GaitLab/$label')
        .create(recursive: true);
    // Write metadata before opening streams, so initialization errors cannot
    // strand open IOSinks.
    await File('${folder.path}/metadata.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 'gaitlab.session.v3',
        'app_version': '0.8.0',
        'motion_analysis_parameters': ?motionParameters,
        'started_at_utc': now.toIso8601String(),
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'placement': placement,
        'requested_sampling_hz': 100,
        'peak_multiplier': peakMultiplier,
        'detector_warmup_ms': GaitEngine.warmupUs ~/ 1000,
        'loss_quality_window_seconds': 5,
        'event_timestamp_source': 'sensors_plus event.timestamp',
        'startup_cache_policy': 'Initial events at or before the prior session native watermark are excluded; first subscriptions use session start minus100ms. Raw events remain; stale gyro timestamps are listed in summary acquisition_startup.',
        'accelerometer_gyroscope_synced': false,
        'research_use_only': true,
        'screen_off_recording': backgroundRecordingEnabled,
        'recording_mode': backgroundRecordingEnabled
            ? 'android_health_foreground_service_with_cpu_wake_lock'
            : 'foreground_only',
        'cadence_target': target?.toJson(),
        'session_metrics_version': 1,
        'metric_definitions': {
          'timeline': 'One-second native sensor-time bins; gaps retain unavailable values.',
          'target_percent': 'Time in the selected cadence range divided by usable-quality cadence time; null if no target or denominator.',
          'usable_time': 'Time-weighted signal-quality grade usable, with no credit for gaps over 70 ms; not step accuracy.',
          'interval_cv_percent': 'Experimental candidate-event interval variability; unavailable until six intervals and usable quality.',
          'signal_rms_m_s2': 'Filtered gravity-direction acceleration RMS; not impact force or body displacement.',
          'periodicity_proxy': 'Waveform repetition proxy; not accuracy or a running-form score.',
          'validation': 'Metrics are experimental; belt-mounted running accuracy remains unverified.',
          'trend_comparison': 'First and latest disjoint 30s windows, each with at least24s usable cadence; cadence change above5% withholds motion comparison. Same cadence does not establish matched speed or slope.',
        },
        'not_measured': [
          'ground_contact_time',
          'foot_strike_type',
          'left_right_foot_identity',
          'injury_risk',
          'absolute_vertical_oscillation',
        ],
      }),
      flush: true,
    );
    final accel = File('${folder.path}/accelerometer.csv').openWrite();
    final gyro = File('${folder.path}/gyroscope.csv').openWrite();
    final steps = File('${folder.path}/steps.csv').openWrite();
    final quality = File('${folder.path}/quality.csv').openWrite();
    final metrics = File('${folder.path}/metrics.csv').openWrite();
    accel.writeln(
      'event_timestamp_us,ax_m_s2,ay_m_s2,az_m_s2,'
      'vertical_m_s2,filtered_m_s2,peak_threshold_m_s2,accepted',
    );
    gyro.writeln('event_timestamp_us,gx_rad_s,gy_rad_s,gz_rad_s');
    steps.writeln('event_timestamp_us,interval_ms,estimated_cadence_spm');
    quality.writeln(
      'event_timestamp_us,actual_hz,signal_rms_m_s2,'
      'periodicity_proxy,estimated_loss_pct,recent_loss_pct,sampling_gaps,'
      'estimated_missing_samples,quality_grade,quality_reason',
    );
    metrics.writeln(
      'elapsed_s,duration_s,cadence_spm,interval_cv_percent,'
      'signal_rms_m_s2,periodicity_proxy,actual_hz,quality_grade,gap',
    );
    final recorder = SessionRecorder._(
      folder,
      accel,
      gyro,
      steps,
      quality,
      metrics,
      now,
      placement,
      peakMultiplier,
    );
    try {
      await recorder.flush();
      return recorder;
    } catch (_) {
      try {
        await recorder.close();
      } catch (_) {
        // Preserve the startup failure.
      }
      rethrow;
    }
  }

  void addAcceleration(SampleResult result, double x, double y, double z) {
    if (_closed) return;
    _writeln(
      accelerometer,
      '${result.timestampUs},${x.toStringAsFixed(5)},'
      '${y.toStringAsFixed(5)},${z.toStringAsFixed(5)},'
      '${result.vertical.toStringAsFixed(5)},'
      '${result.filtered.toStringAsFixed(5)},'
      '${result.threshold.toStringAsFixed(5)},'
      '${result.accepted ? 1 : 0}',
    );
  }

  void addGyro(int timestampUs, double x, double y, double z) {
    if (_closed) return;
    _writeln(
      gyroscope,
      '$timestampUs,${x.toStringAsFixed(5)},'
      '${y.toStringAsFixed(5)},${z.toStringAsFixed(5)}',
    );
  }

  void addStep(int timestampUs, double? intervalMs, double spm) {
    if (_closed) return;
    _writeln(
      steps,
      '$timestampUs,${intervalMs?.toStringAsFixed(2) ?? ''},'
      '${spm > 0 ? spm.toStringAsFixed(2) : ''}',
    );
  }

  void addQuality(int timestampUs, GaitEngine engine) {
    if (_closed) return;
    final status = engine.signalStatus;
    _writeln(
      quality,
      '$timestampUs,${engine.actualHz.toStringAsFixed(2)},'
      '${engine.signalRms.toStringAsFixed(3)},'
      '${engine.periodicity.toStringAsFixed(3)},'
      '${engine.estimatedLossPercent.toStringAsFixed(2)},'
      '${engine.recentLossPercent.toStringAsFixed(2)},'
      '${engine.samplingGaps},${engine.estimatedMissingSamples},'
      '${status.grade.name},${status.explanation}',
    );
  }

  void addMetric(MetricPoint point) {
    if (_closed) return;
    String number(double? value) => value?.toStringAsFixed(5) ?? '';
    _writeln(
      metrics,
      '${number(point.elapsedSeconds)},'
      '${number(point.durationSeconds)},${number(point.cadenceSpm)},'
      '${number(point.intervalCvPercent)},${number(point.signalRms)},'
      '${number(point.periodicity)},${number(point.actualHz)},'
      '${point.grade.name},${point.gap ? 1 : 0}',
    );
  }

  Future<void> saveSummary(
    GaitEngine engine, {
    String? stopReason,
    SessionMetrics? metrics,
    double? recordingSeconds,
    MotionAnalysis? motion,
    SessionStartGate? startGate,
  }) async {
    await File('${folder.path}/summary.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 'gaitlab.summary.v3',
        'started_at_utc': startedAt.toIso8601String(),
        'ended_at_utc': DateTime.now().toUtc().toIso8601String(),
        'stop_reason': stopReason ?? 'user',
        'placement': placement,
        'candidate_steps': engine.stepCount,
        'cadence_spm_last_window': engine.cadence,
        'step_time_ms_last_window': engine.stepTimeMs,
        'cv_percent_last_window': engine.cvPercent,
        'accepted_accel_samples': engine.acceptedSamples,
        'rejected_accel_samples':
            engine.rejectedSamples +
            (startGate?.rejectedAccelerationSamples ?? 0),
        if (startGate != null) 'acquisition_startup': startGate.summary(),
        'sampling_gaps': engine.samplingGaps,
        'estimated_missing_samples': engine.estimatedMissingSamples,
        'estimated_loss_percent': engine.estimatedLossPercent,
        'recent_loss_percent_last_window': engine.recentLossPercent,
        'quality_grade_last_window': engine.signalStatus.grade.name,
        'periodicity_proxy_last_window': engine.periodicity,
        'warning': 'Candidate step events only. No clinical validation.',
        if (motion != null) 'motion_analysis': motion.summary(),
        if (metrics != null)
          'session_metrics': metrics.summary(
            recordingSeconds: recordingSeconds,
          ),
      }),
      flush: true,
    );
  }

  Future<void> flush() {
    if (_pendingClose != null) return _pendingClose!;
    return _pendingFlush ??= _flushSinks().whenComplete(() {
      _pendingFlush = null;
    });
  }

  Future<void> _flushSinks() async {
    try {
      await Future.wait(
        _sinks.map((sink) => Future<void>.sync(() async => sink.flush())),
      );
      // IOSink rejects writes until its flush future completes.
      _drainBufferedLines();
    } catch (error, stack) {
      _rememberFailure(error, stack);
      rethrow;
    }
  }

  Future<void> close() {
    _closed = true;
    return _pendingClose ??= _closeSinks();
  }

  Future<void> _closeSinks() async {
    try {
      await _pendingFlush;
    } catch (error, stack) {
      _rememberFailure(error, stack);
    }
    try {
      // Drain accepted rows even when close starts during a periodic flush.
      _drainBufferedLines();
      await _flushSinks();
    } catch (error, stack) {
      _rememberFailure(error, stack);
    } finally {
      try {
        await Future.wait(
          _sinks.map((sink) => Future<void>.sync(() async => sink.close())),
        );
      } catch (error, stack) {
        _rememberFailure(error, stack);
      }
    }
    if (_ioFailure != null) {
      Error.throwWithStackTrace(_ioFailure!, _ioFailureStack!);
    }
  }

  List<File> get files => [
    File('${folder.path}/metadata.json'),
    File('${folder.path}/accelerometer.csv'),
    File('${folder.path}/gyroscope.csv'),
    File('${folder.path}/steps.csv'),
    File('${folder.path}/quality.csv'),
    File('${folder.path}/summary.json'),
    File('${folder.path}/metrics.csv'),
  ];
}
