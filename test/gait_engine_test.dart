import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';

const sampleUs = 10000;
const startUs = 1782700000000000;

void simulate(GaitEngine engine, {
  double hz = 2.85,
  int count = 3000,
  int start = startUs,
  double amplitude = 3.1,
  double gravityX = 0,
  double gravityZ = 9.81,
}) {
  final norm = math.sqrt(gravityX * gravityX + gravityZ * gravityZ);
  for (var i = 0; i < count; i++) {
    final t = i / 100.0;
    final oscillation = amplitude * math.cos(2 * math.pi * hz * t);
    engine.process(
      timestampUs: start + i * sampleUs,
      ax: gravityX + oscillation * gravityX / norm,
      ay: 0,
      az: gravityZ + oscillation * gravityZ / norm,
    );
  }
}

void main() {
  test('stationary phone has no candidate steps or cadence', () {
    final e = GaitEngine();
    for (var i = 0; i < 2500; i++) {
      e.process(timestampUs: startUs + i * sampleUs,
          ax: 0, ay: 0, az: 9.81);
    }
    expect(e.stepCount, 0);
    expect(e.cadence, 0);
    expect(e.signalStatus.grade, SignalGrade.stationary);
  });

  test('periodic synthetic motion yields approximate cadence and periodicity', () {
    final e = GaitEngine();
    simulate(e);
    expect(e.stepCount, inInclusiveRange(70, 90));
    expect(e.cadence, closeTo(171, 8));
    expect(e.actualHz, closeTo(100, 1));
    expect(e.periodicity, greaterThan(.6));
    expect(e.signalStatus.grade, SignalGrade.usable);
    expect(e.cvPercent, lessThan(4));
  });

  test('flipped and tilted phone does not depend on device Z direction', () {
    final upright = GaitEngine();
    final upsideDown = GaitEngine();
    final tilt = GaitEngine();
    simulate(upright);
    simulate(upsideDown, gravityZ: -9.81);
    simulate(tilt, gravityX: 6.9, gravityZ: 6.9);
    expect(upsideDown.cadence, closeTo(upright.cadence, 4));
    expect(tilt.cadence, closeTo(upright.cadence, 4));
  });

  test('duplicate / backward event timestamps are rejected', () {
    final e = GaitEngine();
    e.process(timestampUs: startUs, ax: 0, ay: 0, az: 9.81);
    final duplicate = e.process(
        timestampUs: startUs, ax: 0, ay: 0, az: 9.81);
    final backward = e.process(
        timestampUs: startUs - 1, ax: 0, ay: 0, az: 9.81);
    expect(duplicate.accepted, isFalse);
    expect(backward.accepted, isFalse);
    expect(e.rejectedSamples, 2);
    expect(e.acceptedSamples, 1);
  });

  test('sensor timestamp discontinuity clears stale cadence and counts loss', () {
    final e = GaitEngine();
    simulate(e, count: 1800);
    expect(e.cadence, greaterThan(100));
    e.process(timestampUs: startUs + 18300000, ax: 0, ay: 0, az: 9.81);
    expect(e.samplingGaps, greaterThan(0));
    expect(e.estimatedMissingSamples, greaterThan(0));
    expect(e.cadence, 0);
  });

  test('candidate timestamp equals peak time, not following sample', () {
    final e = GaitEngine();
    int? peakTs;
    for (var i = 0; i < 500; i++) {
      final t = i / 100.0;
      final r = e.process(
        timestampUs: startUs + i * sampleUs,
        ax: 0, ay: 0,
        az: 9.81 + 3 * math.cos(2 * math.pi * 3 * t),
      );
      if (r.stepDetected) {
        peakTs = r.stepTimestampUs;
        expect(peakTs, lessThan(r.timestampUs));
        break;
      }
    }
    expect(peakTs, isNotNull);
  });

  test('low-amplitude movement cannot inflate the step counter', () {
    final e = GaitEngine();
    simulate(e, amplitude: 0.08);
    expect(e.stepCount, 0);
  });

  test('after stopping movement, live cadence becomes unavailable', () {
    final e = GaitEngine();
    simulate(e, count: 1200);
    expect(e.cadence, greaterThan(100));
    for (var i = 1200; i < 1700; i++) {
      e.process(timestampUs: startUs + i * sampleUs,
        ax: 0, ay: 0, az: 9.81);
    }
    expect(e.cadence, 0);
  });

  test('120 ms interruption is counted and breaks interval continuity', () {
    final e = GaitEngine();
    simulate(e, count: 1400);
    expect(e.cadence, greaterThan(100));
    final next = startUs + 14000000 + 120000;
    e.process(timestampUs: next, ax: 0, ay: 0, az: 9.81);
    expect(e.samplingGaps, greaterThan(0));
    expect(e.estimatedMissingSamples, greaterThanOrEqualTo(11));
    expect(e.recentLossPercent, greaterThan(1));
    expect(e.cadence, 0);
  });

  test('50 Hz stream has no artificial loss and is marked for review', () {
    final e = GaitEngine();
    for (var i = 0; i < 800; i++) {
      final t = i / 50.0;
      e.process(timestampUs: startUs + i * 20000,
          ax: 0, ay: 0, az: 9.81 + 3.1 * math.cos(2 * math.pi * 2.7 * t));
    }
    expect(e.actualHz, closeTo(50, 1));
    expect(e.samplingGaps, 0);
    expect(e.estimatedMissingSamples, 0);
    expect(e.signalStatus.grade, SignalGrade.review);
  });

  test('recent dropouts recover after five seconds of clean samples', () {
    final e = GaitEngine();
    simulate(e, count: 1000);
    final afterGap = startUs + 10120000;
    e.process(timestampUs: afterGap, ax: 0, ay: 0, az: 9.81);
    expect(e.recentLossPercent, greaterThan(1));
    for (var i = 1; i <= 650; i++) {
      e.process(timestampUs: afterGap + i * 10000, ax: 0, ay: 0, az: 9.81);
    }
    expect(e.recentLossPercent, 0);
  });

  test('steady 200 Hz signal has no false dropout estimation', () {
    final e = GaitEngine();
    for (var i = 0; i < 1800; i++) {
      final t = i / 200.0;
      e.process(timestampUs: startUs + i * 5000,
          ax: 0, ay: 0, az: 9.81 + 2.9 * math.cos(2 * math.pi * 3 * t));
    }
    expect(e.actualHz, closeTo(200, 1));
    expect(e.samplingGaps, 0);
    expect(e.cadence, closeTo(180, 10));
  });

}
