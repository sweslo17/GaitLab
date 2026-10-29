// Offline replay of explicit gravity-inclusive m/s² samples through production code.
import 'dart:convert';
import 'dart:io';

import 'package:gaitlab/gait_engine.dart';

Map<String, dynamic> replayCsv(String csv, Map<String, dynamic> spec) {
  if (spec['gravity_included'] != true) {
    throw const FormatException(
      'Declare gravity-inclusive acceleration in m/s²',
    );
  }
  final reference = spec['reference_count'] as int?;
  if (reference != null && spec['accuracy_eligible'] == false) {
    throw const FormatException('Input is explicitly ineligible for scoring');
  }
  if (reference != null && reference < 0) {
    throw const FormatException('Reference count must be nonnegative');
  }
  final lines = const LineSplitter().convert(csv);
  if (lines.isEmpty || lines.first.trim() != 'timestamp_us,ax,ay,az') {
    throw const FormatException('Expected timestamp_us,ax,ay,az');
  }
  final engine = GaitEngine();
  int? first, last;
  var count = 0;
  final events = <int>[];
  final cadence = <double>[];
  final grades = <String, int>{};
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final cells = line.split(',');
    if (cells.length != 4) throw const FormatException('Malformed sample');
    final t = int.parse(cells[0]);
    final xyz = cells.skip(1).map(double.parse).toList();
    if (xyz.any((x) => !x.isFinite)) {
      throw const FormatException('Non-finite sample');
    }
    if (last != null && t <= last) {
      throw const FormatException('Non-increasing sample time');
    }
    first ??= t;
    last = t;
    final result = engine.process(
      timestampUs: t,
      ax: xyz[0],
      ay: xyz[1],
      az: xyz[2],
    );
    count++;
    final grade = engine.signalStatus.grade.name;
    grades[grade] = (grades[grade] ?? 0) + 1;
    if (result.stepDetected) events.add(result.stepTimestampUs!);
    if (result.stepDetected && engine.cadence > 0) cadence.add(engine.cadence);
  }
  if (count == 0) throw const FormatException('No samples');
  final duration = (last! - first!) / 1e6;
  final start = spec['reference_start_us'] as int?;
  final end = spec['reference_end_us'] as int?;
  if ((start == null) != (end == null) ||
      (start != null && (start > end! || start < first || end > last))) {
    throw const FormatException('Reference window must be inside the trace');
  }
  final windowCount = start == null
      ? engine.stepCount
      : events.where((t) => t >= start && t <= end!).length;
  final error = reference == null ? null : windowCount - reference;
  return {
    'input_samples': count,
    'duration_s': duration,
    'observed_hz': duration > 0 ? (count - 1) / duration : null,
    'candidate_steps': engine.stepCount,
    'candidate_steps_in_reference_window': windowCount,
    'candidate_step_times_us': events,
    'median_candidate_cadence_spm': cadence.isEmpty
        ? null
        : GaitEngine.median(cadence),
    'rejected_samples': engine.rejectedSamples,
    'sampling_gaps': engine.samplingGaps,
    'grade_sample_counts': grades,
    'reference_count': reference,
    'count_error': error,
    'count_error_percent': reference == null || reference == 0
        ? null
        : 100 * error! / reference,
    'validation_level': reference == null
        ? 'signal replay only; no count ground truth'
        : 'reference count comparison',
    'parameters': {
      'peak_multiplier': engine.peakMultiplier,
      'warmup_s': .6,
      'minimum_interval_ms': GaitEngine.minStepMs,
      'maximum_interval_ms': GaitEngine.maxStepMs,
    },
  };
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tools/replay_normalized.dart INPUT_MANIFEST OUTPUT_JSON',
    );
    exitCode = 2;
    return;
  }
  final manifest =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final reports = <Map<String, dynamic>>[];
  if ((manifest['trials'] as List).isEmpty) {
    stderr.writeln('Manifest has no trials');
    exitCode = 2;
    return;
  }
  for (final entry in manifest['trials'] as List) {
    final spec = Map<String, dynamic>.from(entry as Map);
    try {
      final r = replayCsv(
        File(spec['file'] as String).readAsStringSync(),
        spec,
      );
      reports.add({...spec, ...r, 'replay_status': 'PASS'});
    } catch (error) {
      reports.add({
        ...spec,
        'replay_status': 'FAIL',
        'error': error.toString(),
      });
    }
  }
  final report = {
    'schema': 'gaitlab.normalized-replay.v1',
    'input_manifest': args[0],
    'warning': 'Replay PASS does not establish step accuracy; samples are not resampled.',
    'trials': reports,
  };
  final out = File(args[1]);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(
    'Replayed ${reports.length} trials; failures: ${reports.where((r) => r['replay_status'] == 'FAIL').length}',
  );
  if (reports.any((r) => r['replay_status'] == 'FAIL')) exitCode = 1;
}
