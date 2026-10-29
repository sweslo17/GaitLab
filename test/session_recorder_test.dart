import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';
import 'package:gaitlab/session_recorder.dart';

void main() {
  test(
    'startup cache is retained raw and counted as rejected in summary',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gaitlab-start-cache-',
      );
      addTearDown(() => root.delete(recursive: true));
      final gate = SessionStartGate(startedAtUs: 200000000);
      expect(gate.accept(32000000), isFalse);
      expect(gate.accept(32000000, gyroscope: true), isFalse);
      final recorder = await SessionRecorder.start(
        placement: '後腰中央',
        peakMultiplier: .62,
        rootDirectory: root,
      );
      recorder.addAcceleration(
        const SampleResult(
          vertical: 0,
          filtered: 0,
          stepDetected: false,
          timestampUs: 32000000,
          stepIntervalMs: null,
          accepted: false,
        ),
        1,
        2,
        3,
      );
      recorder.addGyro(32000000, 4, 5, 6);
      await recorder.close();
      await recorder.saveSummary(GaitEngine(), startGate: gate);
      final summary = jsonDecode(
        await File('${recorder.folder.path}/summary.json').readAsString(),
      );
      expect(summary['rejected_accel_samples'], 1);
      expect(summary['acquisition_startup']['stale_gyroscope_timestamps_us'], [
        32000000,
      ]);
      expect(
        (await File(
          '${recorder.folder.path}/accelerometer.csv',
        ).readAsLines()).last.endsWith(',0'),
        isTrue,
      );
      expect(
        (await File(
          '${recorder.folder.path}/gyroscope.csv',
        ).readAsLines()).last.startsWith('32000000,'),
        isTrue,
      );
    },
  );

  test(
    'motion export preserves all seven files and nullable directional data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gaitlab-motion-export-',
      );
      addTearDown(() => root.delete(recursive: true));
      final motion = MotionAnalysis();
      for (var t = 0; t <= 7000000; t += 10000) {
        motion.addAcceleration(t, 0, 9.81, 0, cadence: 0, periodicity: 0);
        motion.addGyroscope(t, 0, 0, 0);
      }
      motion.finish();
      final recorder = await SessionRecorder.start(
        placement: '後腰中央',
        peakMultiplier: .62,
        rootDirectory: root,
        motionParameters: motion.parameters,
      );
      await recorder.close();
      await recorder.saveSummary(GaitEngine(), motion: motion);
      final summary = jsonDecode(
        await File('${recorder.folder.path}/summary.json').readAsString(),
      );
      final metadata = jsonDecode(
        await File('${recorder.folder.path}/metadata.json').readAsString(),
      );
      expect(
        summary['motion_analysis']['bins'].last['forward_rms_m_s2'],
        isNull,
      );
      expect(summary['motion_analysis']['bins'].last['rotation_rms_rad_s'], 0);
      expect(
        metadata['motion_analysis_parameters']['calibration_requested'],
        false,
      );
      expect(recorder.files.length, 7);
      expect(await recorder.files[1].readAsLines(), hasLength(1));
    },
  );

  void writeRows(SessionRecorder recorder, int timestamp) {
    recorder.addAcceleration(
      SampleResult(
        vertical: 1,
        filtered: .5,
        stepDetected: true,
        timestampUs: timestamp,
        stepIntervalMs: 350,
        accepted: true,
      ),
      1,
      2,
      3,
    );
    recorder.addGyro(timestamp, 4, 5, 6);
    recorder.addStep(timestamp, 350, 170);
    recorder.addQuality(timestamp, GaitEngine());
    recorder.addMetric(
      MetricPoint(
        elapsedSeconds: timestamp.toDouble(),
        durationSeconds: 1,
        cadenceSpm: 170,
        intervalCvPercent: 2,
        signalRms: 1,
        periodicity: .9,
        actualHz: 100,
        grade: SignalGrade.usable,
        gap: false,
      ),
    );
  }

  for (final closeDuringFlush in [false, true]) {
    test(
      closeDuringFlush
          ? 'concurrent close drains rows queued during flush exactly once'
          : 'all CSV streams retain writes during an active flush',
      () async {
        final root = await Directory.systemTemp.createTemp('gaitlab-flush-');
        addTearDown(() => root.delete(recursive: true));
        final recorder = await SessionRecorder.start(
          placement: '後腰中央',
          peakMultiplier: .62,
          rootDirectory: root,
        );
        writeRows(recorder, 1);
        final pendingFlush = recorder.flush();
        Object? writeFailure;
        try {
          writeRows(recorder, 2);
        } catch (error) {
          writeFailure = error;
        }
        if (closeDuringFlush) {
          final closing = recorder.close();
          writeRows(recorder, 3);
          await Future.wait([pendingFlush, closing, recorder.close()]);
        } else {
          await Future.wait([pendingFlush, recorder.flush()]);
          await recorder.close();
        }
        expect(writeFailure, isNull);
        for (final name in [
          'accelerometer',
          'gyroscope',
          'steps',
          'quality',
          'metrics',
        ]) {
          final rows = await File('${recorder.folder.path}/$name.csv')
              .readAsLines();
          expect(
            rows.length,
            3,
            reason: '$name must contain its header and two rows',
          );
          expect(rows[1].split(',').first, name == 'metrics' ? '1.00000' : '1');
          expect(rows[2].split(',').first, name == 'metrics' ? '2.00000' : '2');
        }
      },
    );
  }

  test(
    'metric export preserves raw schemas and captures target and absent values',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gaitlab-recorder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final target = CadenceTarget(minSpm: 155, maxSpm: 175);
      final recorder = await SessionRecorder.start(
        placement: '後腰中央',
        peakMultiplier: .62,
        target: target,
        backgroundRecordingEnabled: true,
        rootDirectory: root,
      );
      final engine = GaitEngine();
      final metrics = SessionMetrics(target: target);
      recorder.addMetric(
        MetricPoint(
          elapsedSeconds: 0,
          durationSeconds: 1,
          cadenceSpm: null,
          intervalCvPercent: null,
          signalRms: 0,
          periodicity: 0,
          actualHz: 100,
          grade: SignalGrade.warmingUp,
          gap: false,
        ),
      );
      await recorder.close();
      await recorder.saveSummary(engine, metrics: metrics, recordingSeconds: 2);
      expect(recorder.files.length, 7);
      final metadata = jsonDecode(
        await File('${recorder.folder.path}/metadata.json').readAsString(),
      );
      expect(metadata['app_version'], '0.8.0');
      expect(metadata['cadence_target'], target.toJson());
      expect(metadata['accelerometer_gyroscope_synced'], false);
      expect(metadata['screen_off_recording'], true);
      final summary = jsonDecode(
        await File('${recorder.folder.path}/summary.json').readAsString(),
      );
      expect(summary['schema'], 'gaitlab.summary.v3');
      expect(summary['session_metrics']['target_percent'], isNull);
      expect(summary['session_metrics']['recording_duration_s'], 2);
      expect(
        summary['session_metrics']['trend_comparison']['status'],
        'collecting',
      );
      expect(
        summary['session_metrics']['trend_comparison']['window_seconds'],
        30,
      );
      final metricLines = await File('${recorder.folder.path}/metrics.csv')
          .readAsLines();
      expect(
        metricLines.first,
        'elapsed_s,duration_s,cadence_spm,interval_cv_percent,signal_rms_m_s2,periodicity_proxy,actual_hz,quality_grade,gap',
      );
      final cells = metricLines[1].split(',');
      expect(cells[2], '');
      expect(cells[3], '');
      expect(double.parse(cells[4]), 0);
      expect(
        (await File(
          '${recorder.folder.path}/accelerometer.csv',
        ).readAsLines()).first,
        'event_timestamp_us,ax_m_s2,ay_m_s2,az_m_s2,vertical_m_s2,filtered_m_s2,peak_threshold_m_s2,accepted',
      );
      expect(
        (await File(
          '${recorder.folder.path}/gyroscope.csv',
        ).readAsLines()).first,
        'event_timestamp_us,gx_rad_s,gy_rad_s,gz_rad_s',
      );
      expect(
        (await File('${recorder.folder.path}/steps.csv').readAsLines()).first,
        'event_timestamp_us,interval_ms,estimated_cadence_spm',
      );
      expect(
        (await File('${recorder.folder.path}/quality.csv').readAsLines()).first,
        'event_timestamp_us,actual_hz,signal_rms_m_s2,periodicity_proxy,estimated_loss_pct,recent_loss_pct,sampling_gaps,estimated_missing_samples,quality_grade,quality_reason',
      );
      recorder.addMetric(
        MetricPoint(
          elapsedSeconds: 1,
          durationSeconds: 1,
          cadenceSpm: 170,
          intervalCvPercent: 2,
          signalRms: 1,
          periodicity: .9,
          actualHz: 100,
          grade: SignalGrade.usable,
          gap: false,
        ),
      );
      await recorder.close();
      expect(
        await File('${recorder.folder.path}/metrics.csv').readAsLines(),
        metricLines,
      );
    },
  );

  test(
    'legacy recorder callers retain summary fields without a target',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gaitlab-recorder-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final recorder = await SessionRecorder.start(
        placement: '前腰中央',
        peakMultiplier: .62,
        rootDirectory: root,
      );
      await recorder.flush();
      await recorder.close();
      await recorder.saveSummary(GaitEngine(), stopReason: 'test');
      final metadata = jsonDecode(
        await File('${recorder.folder.path}/metadata.json').readAsString(),
      );
      expect(metadata['cadence_target'], isNull);
      expect(metadata['screen_off_recording'], false);
      final summary = jsonDecode(
        await File('${recorder.folder.path}/summary.json').readAsString(),
      );
      expect(summary['candidate_steps'], 0);
      expect(summary['stop_reason'], 'test');
      expect(summary.containsKey('session_metrics'), false);
    },
  );
}
