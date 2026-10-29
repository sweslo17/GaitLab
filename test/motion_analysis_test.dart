import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';

void feed(
  MotionAnalysis a,
  int from,
  int to, {
  bool moving = false,
  bool gyro = true,
  double rotation = 0,
  bool gyroFirst = false,
  double gravityY = 9.81,
  double gravityZ = 0,
}) {
  for (var t = from; t <= to; t += 10000) {
    final s = math.sin(t / 1e6 * 4 * math.pi);
    void g() => a.addGyroscope(t, 0, rotation, 0);
    if (gyro && gyroFirst) g();
    a.addAcceleration(
      t,
      moving ? .8 * s : 0,
      gravityY + (moving ? 2.4 * s : 0),
      gravityZ + (moving ? 1.6 * s : 0),
      cadence: moving ? 170 : 0,
      periodicity: moving ? .8 : 0,
    );
    if (gyro && !gyroFirst) g();
  }
}

void main() {
  test('quiet duration uses measured time and finish is idempotent', () {
    final a = MotionAnalysis();
    feed(a, 0, 10000000);
    a.finish();
    final first = a.summary();
    a.finish();
    expect(a.summary(), first);
    expect(a.bins.where((b) => b.state == MotionState.quiet), isNotEmpty);
    expect(
      a.bins.fold<double>(0, (s, b) => s + b.durationSeconds),
      closeTo(10, 1e-8),
    );
    expect(a.bins.last.accelerationRms, closeTo(0, 1e-8));
    expect(a.bins.last.rotationRms, closeTo(0, 1e-8));
    expect(a.bins.last.forwardRms, isNull);
  });
  test(
    'fixed rear mount calibration preserves projected energy and ratios',
    () {
      final a = MotionAnalysis(calibrate: true);
      feed(a, 0, 16000000);
      expect(a.calibrationStatus, 'ready');
      feed(a, 16010000, 24000000, moving: true);
      a.finish();
      final b = a.bins.last;
      expect(b.state, MotionState.rhythmic);
      expect(b.forwardRms, isNotNull);
      final sum =
          b.forwardRms! * b.forwardRms! +
          b.lateralRms! * b.lateralRms! +
          b.verticalRms! * b.verticalRms!;
      expect(sum, closeTo(b.accelerationRms! * b.accelerationRms!, 1e-8));
      expect(b.forwardRms! / b.lateralRms!, closeTo(2, .02));
      expect(b.verticalRms! / b.lateralRms!, closeTo(3, .02));
      expect(
        a.bins
            .where((x) => x.startSeconds < 15)
            .every((x) => x.forwardRms == null),
        isTrue,
      );
    },
  );
  test('rotation RMS has rad/s units and sensor callback order does not change bins', () {
    final first = MotionAnalysis(calibrate: true),
        second = MotionAnalysis(calibrate: true);
    feed(first, 0, 16000000);
    feed(second, 0, 16000000, gyroFirst: true);
    feed(first, 16010000, 21000000, rotation: .5);
    feed(second, 16010000, 21000000, rotation: .5, gyroFirst: true);
    first.finish();
    second.finish();
    expect(first.bins.last.rotationRms, closeTo(.5, 1e-8));
    expect(first.bins.last.verticalMeanRate, closeTo(.5, 1e-8));
    expect(first.bins.last.state, MotionState.rotation);
    expect(
      first.bins.map((b) => b.toJson()).toList(),
      second.bins.map((b) => b.toJson()).toList(),
    );
  });
  test(
    'stale or missing gyro never reports zero or carries prior rotation',
    () {
      final a = MotionAnalysis();
      feed(a, 0, 7000000, rotation: 1);
      feed(a, 7010000, 11000000, gyro: false);
      a.finish();
      expect(a.bins.last.gyroCoverage, 0);
      expect(a.bins.last.rotationRms, isNull);
      expect(a.bins.last.state, MotionState.unavailable);
    },
  );
  test('gaps have no measured credit and reset filter warmup', () {
    final a = MotionAnalysis();
    feed(a, 0, 6000000);
    feed(a, 8000000, 10000000);
    a.finish();
    final gap = a.bins.firstWhere(
      (b) => b.startSeconds <= 7 && b.startSeconds + b.durationSeconds > 7,
    );
    expect(gap.accelCoverage, 0);
    expect(gap.accelerationRms, isNull);
    expect(a.bins.last.state, MotionState.unavailable);
  });
  test('bad and nearly horizontal calibration does not guess body axes', () {
    final horizontal = MotionAnalysis(calibrate: true);
    feed(horizontal, 0, 18000000, gravityY: 0, gravityZ: 9.81);
    expect(horizontal.calibrationStatus, 'failed');
    expect(horizontal.calibrationReason, isNotEmpty);
    final moving = MotionAnalysis(calibrate: true);
    feed(moving, 0, 18000000, moving: true);
    expect(moving.calibrationStatus, 'failed');
    expect(moving.bins.every((b) => b.forwardRms == null), isTrue);
  });
  test(
    'tilt invalidation retains historical bins but suppresses new body axes',
    () {
      final a = MotionAnalysis(calibrate: true);
      feed(a, 0, 17000000);
      feed(a, 17010000, 23000000, gravityY: 0, gravityZ: 9.81);
      a.finish();
      expect(a.calibrationStatus, 'invalidated');
      expect(
        a.bins.firstWhere((b) => b.startSeconds == 16).forwardRms,
        isNotNull,
      );
      expect(a.bins.last.forwardRms, isNull);
    },
  );
  test(
    'gyro beyond acceleration watermark cannot pollute the final partial bin',
    () {
      final a = MotionAnalysis();
      feed(a, 0, 6250000, gyro: false);
      for (var t = 0; t <= 6250000; t += 10000) {
        a.addGyroscope(t, 0, 0, 0);
      }
      for (var t = 6260000; t <= 7000000; t += 10000) {
        a.addGyroscope(t, 100, 0, 0);
      }
      a.finish();
      expect(a.bins.last.rotationRms, closeTo(0, 1e-8));
    },
  );
  test(
    'long missing intervals stay compact and zero energy has no percentages',
    () {
      final a = MotionAnalysis(calibrate: true);
      feed(a, 0, 16000000);
      expect(a.bins.last.toJson()['direction_energy_percent'], isNull);
      feed(a, 86400000000, 86401000000);
      a.finish();
      expect(a.bins.length, lessThan(30));
      expect(
        a.bins.fold<double>(0, (t, b) => t + b.durationSeconds),
        closeTo(86401, 1e-6),
      );
    },
  );
  test('late gyro uses calibration validity timestamps and never backfills earlier bins', () {
    final a = MotionAnalysis(calibrate: true);
    feed(a, 0, 17000000, gyro: false);
    for (var t = 0; t <= 17000000; t += 10000) {
      a.addGyroscope(t, 0, 1, 0);
    }
    a.finish();
    expect(
      a.bins
          .where((b) => b.startSeconds < 15)
          .every((b) => b.verticalMeanRate == null),
      isTrue,
    );
    expect(a.bins.last.verticalMeanRate, closeTo(1, 1e-8));
  });
  test(
    'stopping before calibration completes stores a final failure reason',
    () {
      for (final end in [3000000, 12000000]) {
        final a = MotionAnalysis(calibrate: true);
        feed(a, 0, end);
        a.finish();
        expect(a.calibrationStatus, 'failed');
        expect(a.calibrationReason, contains('結束'));
      }
    },
  );
  test('finite components whose magnitude overflows are rejected safely', () {
    final a = MotionAnalysis();
    feed(a, 0, 7000000);
    a.addAcceleration(7010000, 1e300, 1e300, 0, cadence: 0, periodicity: 0);
    a.addGyroscope(7010000, 1e300, 0, 0);
    a.finish();
    expect(a.summary()['rejected_accel_samples'], 1);
    expect(a.summary()['rejected_gyro_samples'], 1);
    expect(a.bins.last.accelerationRms, closeTo(0, 1e-8));
  });
  test(
    '50Hz calibration keeps time coverage and honors screen-facing choice',
    () {
      final a = MotionAnalysis(calibrate: true, screenFacesBody: false);
      for (var t = 0; t <= 18000000; t += 20000) {
        a.addAcceleration(t, 0, 9.81, 0, cadence: 0, periodicity: 0);
        a.addGyroscope(t, 0, 0, 0);
      }
      a.finish();
      expect(a.calibrationStatus, 'ready');
      expect(a.bins.last.accelCoverage, closeTo(1, 1e-10));
      expect(a.bins.last.gyroCoverage, closeTo(1, 1e-10));
      final axes = a.summary()['calibration_axes'] as Map;
      expect(axes['forward'], [0.0, 0.0, -1.0]);
    },
  );
  test(
    'calibration stays invalid after phone returns to its former position',
    () {
      final a = MotionAnalysis(calibrate: true);
      feed(a, 0, 17000000);
      feed(a, 17010000, 23000000, gravityY: 0, gravityZ: 9.81);
      feed(a, 23010000, 30000000);
      a.finish();
      expect(a.calibrationStatus, 'invalidated');
      expect(a.bins.last.forwardRms, isNull);
    },
  );
  test('nonfinite and reversed timestamps do not enter metrics or poison calibration', () {
    final a = MotionAnalysis();
    feed(a, 0, 7000000);
    a.addAcceleration(1, double.nan, 0, 0, cadence: 0, periodicity: 0);
    a.addGyroscope(1, 0, double.infinity, 0);
    a.finish();
    expect(a.summary()['rejected_accel_samples'], 1);
    expect(a.summary()['rejected_gyro_samples'], 1);
    expect(a.bins.last.accelerationRms, closeTo(0, 1e-8));
  });
}
