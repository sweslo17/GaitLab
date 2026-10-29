import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';

MetricPoint point(
  double start,
  double duration, {
  double? cadence = 160,
  double? rms = 2,
  double? cv = 2,
  double? periodicity = .8,
  SignalGrade grade = SignalGrade.usable,
  bool gap = false,
}) => MetricPoint(
  elapsedSeconds: start,
  durationSeconds: duration,
  cadenceSpm: cadence,
  intervalCvPercent: cv,
  signalRms: rms,
  periodicity: periodicity,
  actualHz: 100,
  grade: grade,
  gap: gap,
);

Map<String, dynamic>? metric(Map<String, dynamic> result, String key) =>
    (result['metrics'] as Map<String, dynamic>)[key] as Map<String, dynamic>?;

void main() {
  test('empty input collects without fabricated measurements', () {
    final result = compareSessionTrends([]);
    expect(result['status'], 'collecting');
    expect(result['baseline_start_s'], isNull);
    expect(result['recent_end_s'], isNull);
    expect(metric(result, 'cadence'), isNull);
    expect(SessionMetrics().summary()['trend_comparison'], result);
  });

  test('clips disjoint windows and weights different durations', () {
    final result = compareSessionTrends([
      point(0, 3, grade: SignalGrade.warmingUp),
      point(3, 10, rms: 1),
      point(13, 25, rms: 4),
      point(38, 10, rms: 6),
      point(48, 15, rms: 3),
    ]);
    expect(result['status'], 'ready');
    expect(result['baseline_start_s'], 3);
    expect(result['baseline_end_s'], 33);
    expect(result['recent_start_s'], 33);
    expect(result['recent_end_s'], 63);
    expect(result['baseline_usable_s'], 30);
    expect(result['recent_usable_s'], 30);
    expect(metric(result, 'rms')!['baseline'], closeTo(3, 1e-10));
    expect(metric(result, 'rms')!['recent'], closeTo(125 / 30, 1e-10));
  });

  test(
    'overlapping windows remain collecting even with enough usable time',
    () {
      expect(compareSessionTrends([point(0, 59)])['status'], 'collecting');
    },
  );

  test('guard permits five percent and withholds above five percent', () {
    final boundary = compareSessionTrends([
      point(0, 30),
      point(30, 30, cadence: 168),
    ]);
    expect(boundary['status'], 'ready');
    expect(metric(boundary, 'rms'), isNotNull);
    for (final cadence in [168.01, 151.99]) {
      final result = compareSessionTrends([
        point(0, 30),
        point(30, 30, cadence: cadence),
      ]);
      expect(result['status'], 'cadence_changed');
      expect(metric(result, 'cadence'), isNotNull);
      for (final key in ['rms', 'interval_cv', 'periodicity']) {
        expect(metric(result, key), isNull);
      }
    }
  });

  test('early window does not collect scattered later usable samples', () {
    final result = compareSessionTrends([
      point(0, 10),
      point(10, 30, gap: true),
      point(40, 60),
    ]);
    expect(result['status'], 'insufficient_quality');
    expect(result['baseline_start_s'], 0);
    expect(result['baseline_usable_s'], 10);
    expect(metric(result, 'cadence'), isNull);
  });

  test('latest gap moves recent window and withholds stale comparison', () {
    final result = compareSessionTrends([
      point(0, 60),
      point(60, 20, gap: true),
    ]);
    expect(result['recent_end_s'], 80);
    expect(result['recent_start_s'], 50);
    expect(result['recent_usable_s'], 10);
    expect(result['status'], 'insufficient_quality');
  });

  test('zero RMS baseline has an absolute delta and no relative percent', () {
    final result = compareSessionTrends([
      point(0, 30, rms: 0),
      point(30, 30, rms: 2),
    ]);
    expect(metric(result, 'rms')!['delta'], 2);
    expect(metric(result, 'rms')!['relative_percent'], isNull);
  });

  test('CV delta uses percentage points and periodicity raw coefficient', () {
    final result = compareSessionTrends([
      point(0, 30, cv: 2, periodicity: .8),
      point(30, 30, cv: 3, periodicity: .7),
    ]);
    expect(metric(result, 'interval_cv')!['delta'], 1);
    expect(metric(result, 'periodicity')!['delta'], closeTo(-.1, 1e-10));
  });

  test('each metric needs 24 seconds of valid eligible coverage', () {
    final result = compareSessionTrends([
      point(0, 30, cv: null),
      point(30, 23, periodicity: double.nan),
      point(53, 7, rms: double.infinity),
    ]);
    expect(result['status'], 'ready');
    expect(metric(result, 'cadence'), isNotNull);
    expect(metric(result, 'interval_cv'), isNull);
    expect(metric(result, 'rms'), isNull);
    expect(metric(result, 'periodicity'), isNull);
    expect(() => jsonEncode(result), returnsNormally);
  });

  test(
    '24 seconds meets coverage while unavailable cadence earns no credit',
    () {
      final result = compareSessionTrends([
        point(0, 24),
        point(24, 6, cadence: 0),
        point(30, 24),
        point(54, 6, cadence: double.nan),
      ]);
      expect(result['status'], 'ready');
      expect(result['baseline_usable_s'], 24);
      expect(result['recent_usable_s'], 24);
    },
  );

  test('long session with no eligible data reports insufficient quality', () {
    final result = compareSessionTrends([
      point(0, 90, cadence: null, grade: SignalGrade.stationary),
    ]);
    expect(result['status'], 'insufficient_quality');
    expect(result['baseline_start_s'], isNull);
    expect(result['recent_end_s'], 90);
  });
}
