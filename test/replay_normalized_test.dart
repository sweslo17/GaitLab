import 'package:flutter_test/flutter_test.dart';

import 'dart:math' as math;

import '../tools/replay_normalized.dart';

void main() {
  test('scores reference window while retaining the full trace for warmup', () {
    final csv = StringBuffer('timestamp_us,ax,ay,az\n');
    for (var i = 0; i < 600; i++) {
      csv.writeln(
        '${i * 10000},0,0,${9.81 + 4 * math.sin(2 * math.pi * 3 * i / 100)}',
      );
    }
    final base = replayCsv(csv.toString(), {'gravity_included': true});
    final events = base['candidate_step_times_us'] as List<int>;
    expect(events.length, greaterThan(5));
    final t = events[3];
    final scored = replayCsv(csv.toString(), {
      'gravity_included': true,
      'reference_count': 1,
      'reference_start_us': t - 1,
      'reference_end_us': t + 1,
    });
    expect(scored['candidate_steps_in_reference_window'], 1);
    expect(scored['candidate_steps'], events.length);
    expect(scored['count_error'], 0);
  });
  test(
    'rejects missing gravity declaration instead of scoring incompatible input',
    () {
      expect(
        () => replayCsv('timestamp_us,ax,ay,az\n0,0,0,9.81\n', {}),
        throwsFormatException,
      );
    },
  );
  test(
    'preserves sample times and reports zero reference counts without division',
    () {
      final r = replayCsv(
        'timestamp_us,ax,ay,az\n0,0,0,9.81\n10000,0,0,9.81\n20000,0,0,9.81\n',
        {'gravity_included': true, 'reference_count': 0},
      );
      expect(r['input_samples'], 3);
      expect(r['candidate_steps'], 0);
      expect(r['count_error'], 0);
      expect(r['count_error_percent'], isNull);
      expect(r['duration_s'], .02);
    },
  );
  test('rejects negative reference count', () {
    expect(
      () => replayCsv('timestamp_us,ax,ay,az\n0,0,0,9.81\n', {
        'gravity_included': true,
        'reference_count': -1,
      }),
      throwsFormatException,
    );
  });
  test('refuses scoring explicitly ineligible input', () {
    expect(
      () => replayCsv('timestamp_us,ax,ay,az\n0,0,0,9.81\n', {
        'gravity_included': true,
        'reference_count': 2,
        'accuracy_eligible': false,
      }),
      throwsFormatException,
    );
  });
  test('refuses malformed or nonfinite samples', () {
    expect(
      () => replayCsv('timestamp_us,ax,ay,az\n0,NaN,0,9.81\n', {
        'gravity_included': true,
      }),
      throwsFormatException,
    );
  });
}
