import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';

class MetricEngine extends GaitEngine {
  SignalGrade grade = SignalGrade.usable;
  double spm = 170;
  int intervalCount = 8;
  @override
  SignalStatus get signalStatus => SignalStatus(grade, 'test');
  @override
  double get cadence => spm;
  @override
  List<double> get intervalsMs => List.filled(intervalCount, 350);
  @override
  double get cvPercent => 2;
  @override
  double get signalRms => 1.5;
  @override
  double get periodicity => .8;
  @override
  double get actualHz => 100;
}

void observe(
  SessionMetrics metrics,
  MetricEngine engine,
  int time, {
  bool accepted = true,
}) {
  metrics.observe(
    timestampUs: time,
    engine: engine,
    sample: SampleResult(
      vertical: 0,
      filtered: 0,
      stepDetected: false,
      timestampUs: time,
      stepIntervalMs: null,
      accepted: accepted,
    ),
  );
}

void main() {
  test('target requires a finite ordered range within supported UI limits', () {
    expect(CadenceTarget(minSpm: 160, maxSpm: 180).contains(170), isTrue);
    for (final range in [
      (59.0, 180.0),
      (160.0, 241.0),
      (170.0, 170.0),
      (double.nan, 180.0),
    ]) {
      expect(
        () => CadenceTarget(minSpm: range.$1, maxSpm: range.$2),
        throwsArgumentError,
      );
    }
  });
  test(
    'no data and absent target never produce a perfect zero-valued metric',
    () {
      final metrics = SessionMetrics();
      expect(metrics.summary()['target_percent'], isNull);
      expect(metrics.summary()['usable_percent'], isNull);
      expect(metrics.trends, isEmpty);
      metrics.finish();
      metrics.finish();
      expect(metrics.trends, isEmpty);
    },
  );
  test('target ratio uses elapsed usable cadence time, not sample count', () {
    final metrics = SessionMetrics(
      target: CadenceTarget(minSpm: 160, maxSpm: 180),
    );
    final engine = MetricEngine();
    observe(metrics, engine, 0);
    for (var time = 10000; time <= 1000000; time += 10000) {
      observe(metrics, engine, time);
    }
    engine.spm = 150;
    observe(metrics, engine, 1010000);
    for (var time = 1030000; time <= 2010000; time += 20000) {
      observe(metrics, engine, time);
    }
    final summary = metrics.summary();
    expect(summary['target_seconds'], closeTo(1.01, 1e-8));
    expect(summary['cadence_available_seconds'], closeTo(2.01, 1e-8));
    expect(summary['target_percent'], closeTo(100 * 1.01 / 2.01, 1e-8));
  });
  test('gaps have no usable credit and cannot bridge chart points', () {
    final metrics = SessionMetrics(
      target: CadenceTarget(minSpm: 160, maxSpm: 180),
    );
    final engine = MetricEngine();
    observe(metrics, engine, 0);
    observe(metrics, engine, 10000);
    observe(metrics, engine, 3010000);
    observe(metrics, engine, 3020000);
    metrics.finish();
    final summary = metrics.summary(recordingSeconds: 4);
    expect(summary['usable_seconds'], closeTo(.02, 1e-9));
    expect(summary['recording_duration_s'], 4);
    expect((summary['grade_seconds'] as Map)['missing'], closeTo(3.98, 1e-9));
    expect(metrics.trends.where((p) => p.gap), isNotEmpty);
    for (final point in metrics.trends.where((p) => p.gap)) {
      expect(point.cadenceSpm, isNull);
      expect(point.signalRms, isNull);
    }
  });
  test('rejected and duplicate native timestamps do not add time', () {
    final metrics = SessionMetrics();
    final engine = MetricEngine();
    observe(metrics, engine, 0);
    observe(metrics, engine, 10000);
    observe(metrics, engine, 10000);
    observe(metrics, engine, 5000);
    observe(metrics, engine, 100000, accepted: false);
    expect(metrics.summary()['sensor_duration_s'], .01);
    expect(metrics.summary()['observed_samples'], 2);
    expect(metrics.summary()['ignored_samples'], 3);
  });
  test('review, unavailable cadence, and insufficient CV stay unavailable', () {
    final metrics = SessionMetrics(
      target: CadenceTarget(minSpm: 160, maxSpm: 180),
    );
    final engine = MetricEngine()..grade = SignalGrade.review;
    for (var t = 0; t <= 1000000; t += 10000) {
      observe(metrics, engine, t);
    }
    expect(metrics.summary()['target_percent'], isNull);
    expect(metrics.trends.single.cadenceSpm, isNull);
    expect(metrics.trends.single.intervalCvPercent, isNull);
    final second = SessionMetrics();
    engine.grade = SignalGrade.usable;
    engine.intervalCount = 3;
    for (var t = 0; t <= 1000000; t += 10000) {
      observe(second, engine, t);
    }
    expect(second.trends.single.intervalCvPercent, isNull);
  });
  test('partial bins flush once, preserve duration, and a new session resets totals', () {
    final metrics = SessionMetrics();
    final engine = MetricEngine();
    for (var t = 0; t <= 1250000; t += 10000) {
      observe(metrics, engine, t);
    }
    expect(metrics.trends.length, 1);
    metrics.finish();
    metrics.finish();
    expect(metrics.trends.length, 2);
    expect(metrics.trends.last.elapsedSeconds, 1);
    expect(metrics.trends.last.durationSeconds, .25);
    expect(() => metrics.trends.clear(), throwsUnsupportedError);
    expect(SessionMetrics().summary()['sensor_duration_s'], 0);
  });
  test('a mixed-quality bin does not plot cadence as fully usable', () {
    final metrics = SessionMetrics();
    final engine = MetricEngine();
    for (var t = 0; t <= 500000; t += 10000) {
      observe(metrics, engine, t);
    }
    engine.grade = SignalGrade.review;
    for (var t = 510000; t <= 1000000; t += 10000) {
      observe(metrics, engine, t);
    }
    expect(metrics.summary()['usable_seconds'], closeTo(.51, 1e-9));
    expect(metrics.trends.single.grade, SignalGrade.review);
    expect(metrics.trends.single.cadenceSpm, isNull);
    expect(metrics.trends.single.intervalCvPercent, isNull);
  });
  test('70 ms credits time while a longer gap is entirely missing', () {
    final metrics = SessionMetrics();
    final engine = MetricEngine();
    observe(metrics, engine, 0);
    observe(metrics, engine, 70000);
    observe(metrics, engine, 141000);
    expect(metrics.summary()['usable_seconds'], .07);
    expect((metrics.summary()['grade_seconds'] as Map)['missing'], .071);
  });
  test(
    'real engine synthetic samples yield experimental time-binned metrics',
    () {
      final engine = GaitEngine();
      final metrics = SessionMetrics();
      for (var i = 0; i <= 800; i++) {
        final result = engine.process(
          timestampUs: i * 10000,
          ax: 0,
          ay: 0,
          az: 9.81 + 3 * math.cos(2 * math.pi * 3 * i / 100),
        );
        metrics.observe(
          timestampUs: result.timestampUs,
          engine: engine,
          sample: result,
        );
      }
      metrics.finish();
      expect(metrics.summary()['sensor_duration_s'], 8);
      expect(metrics.summary()['usable_seconds'], greaterThan(0));
      expect(metrics.summary()['usable_seconds'], lessThan(8));
      expect(metrics.trends.where((p) => p.cadenceSpm != null), isNotEmpty);
      expect(metrics.trends.last.cadenceSpm, closeTo(180, 5));
    },
  );
}
