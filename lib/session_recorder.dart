import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'gait_engine.dart';

/// Separate streams: accel and gyro are NOT falsely joined by row number.
class SessionRecorder {
  SessionRecorder._(this.folder, this.accelerometer, this.gyroscope,
      this.steps, this.quality, this.startedAt, this.placement,
      this.peakMultiplier);

  final Directory folder;
  final IOSink accelerometer;
  final IOSink gyroscope;
  final IOSink steps;
  final IOSink quality;
  final DateTime startedAt;
  final String placement;
  final double peakMultiplier;
  bool _closed = false;

  static Future<SessionRecorder> start({
    required String placement,
    required double peakMultiplier,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final now = DateTime.now().toUtc();
    final label = now.toIso8601String().replaceAll(':', '-');
    final folder = await Directory('${root.path}/GaitLab/$label')
        .create(recursive: true);
    // Write metadata before opening streams, so initialization errors cannot
    // strand four open IOSinks.
    await File('${folder.path}/metadata.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 'gaitlab.session.v3',
        'app_version': '0.3.0',
        'started_at_utc': now.toIso8601String(),
        'platform': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'placement': placement,
        'requested_sampling_hz': 100,
        'peak_multiplier': peakMultiplier,
        'detector_warmup_ms': GaitEngine.warmupUs ~/ 1000,
        'loss_quality_window_seconds': 5,
        'event_timestamp_source': 'sensors_plus event.timestamp',
        'accelerometer_gyroscope_synced': false,
        'research_use_only': true,
        'not_measured': [
          'ground_contact_time', 'foot_strike_type', 'left_right_foot_identity',
          'injury_risk', 'absolute_vertical_oscillation'
        ],
      }),
      flush: true,
    );
    final accel = File('${folder.path}/accelerometer.csv').openWrite();
    final gyro = File('${folder.path}/gyroscope.csv').openWrite();
    final steps = File('${folder.path}/steps.csv').openWrite();
    final quality = File('${folder.path}/quality.csv').openWrite();
    accel.writeln('event_timestamp_us,ax_m_s2,ay_m_s2,az_m_s2,'
        'vertical_m_s2,filtered_m_s2,peak_threshold_m_s2,accepted');
    gyro.writeln('event_timestamp_us,gx_rad_s,gy_rad_s,gz_rad_s');
    steps.writeln('event_timestamp_us,interval_ms,estimated_cadence_spm');
    quality.writeln('event_timestamp_us,actual_hz,signal_rms_m_s2,'
        'periodicity_proxy,estimated_loss_pct,recent_loss_pct,sampling_gaps,'
        'estimated_missing_samples,quality_grade,quality_reason');
    return SessionRecorder._(
        folder, accel, gyro, steps, quality, now, placement, peakMultiplier);
  }

  void addAcceleration(SampleResult result, double x, double y, double z) {
    if (_closed) return;
    accelerometer.writeln('${result.timestampUs},${x.toStringAsFixed(5)},'
        '${y.toStringAsFixed(5)},${z.toStringAsFixed(5)},'
        '${result.vertical.toStringAsFixed(5)},'
        '${result.filtered.toStringAsFixed(5)},'
        '${result.threshold.toStringAsFixed(5)},'
        '${result.accepted ? 1 : 0}');
  }

  void addGyro(int timestampUs, double x, double y, double z) {
    if (_closed) return;
    gyroscope.writeln('$timestampUs,${x.toStringAsFixed(5)},'
        '${y.toStringAsFixed(5)},${z.toStringAsFixed(5)}');
  }

  void addStep(int timestampUs, double? intervalMs, double spm) {
    if (_closed) return;
    steps.writeln('$timestampUs,${intervalMs?.toStringAsFixed(2) ?? ''},'
        '${spm > 0 ? spm.toStringAsFixed(2) : ''}');
  }

  void addQuality(int timestampUs, GaitEngine engine) {
    if (_closed) return;
    final status = engine.signalStatus;
    quality.writeln('$timestampUs,${engine.actualHz.toStringAsFixed(2)},'
        '${engine.signalRms.toStringAsFixed(3)},'
        '${engine.periodicity.toStringAsFixed(3)},'
        '${engine.estimatedLossPercent.toStringAsFixed(2)},'
        '${engine.recentLossPercent.toStringAsFixed(2)},'
        '${engine.samplingGaps},${engine.estimatedMissingSamples},'
        '${status.grade.name},${status.explanation}');
  }

  Future<void> saveSummary(GaitEngine engine, {String? stopReason}) async {
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
        'rejected_accel_samples': engine.rejectedSamples,
        'sampling_gaps': engine.samplingGaps,
        'estimated_missing_samples': engine.estimatedMissingSamples,
        'estimated_loss_percent': engine.estimatedLossPercent,
        'recent_loss_percent_last_window': engine.recentLossPercent,
        'quality_grade_last_window': engine.signalStatus.grade.name,
        'periodicity_proxy_last_window': engine.periodicity,
        'warning': 'Candidate step events only. No clinical validation.',
      }),
      flush: true,
    );
  }

  Future<void> flush() async {
    if (_closed) return;
    await Future.wait([
      accelerometer.flush(), gyroscope.flush(), steps.flush(), quality.flush()
    ]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? flushFailure;
    try {
      await Future.wait([
        accelerometer.flush(), gyroscope.flush(), steps.flush(), quality.flush()
      ]);
    } catch (error) {
      flushFailure = error;
    } finally {
      // Always close even if flush fails. Do not leave OS file handles open.
      await Future.wait([
        accelerometer.close(), gyroscope.close(), steps.close(), quality.close()
      ]);
    }
    if (flushFailure != null) throw StateError('CSV flush failed: $flushFailure');
  }

  List<File> get files => [
    File('${folder.path}/metadata.json'),
    File('${folder.path}/accelerometer.csv'),
    File('${folder.path}/gyroscope.csv'),
    File('${folder.path}/steps.csv'),
    File('${folder.path}/quality.csv'),
    File('${folder.path}/summary.json'),
  ];
}
