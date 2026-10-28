// Replays unchanged AZI350 trial CSV through the EXACT production GaitEngine.
// Usage: dart run tools/replay_public.dart --file data/public/azi350/running_pants.csv --activity running
// Labels contain activity only, NOT reference steps/ground contacts.
import 'dart:convert';
import 'dart:io';

import '../lib/gait_engine.dart';

void main(List<String> args) {
  String? file, activity, out;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--file' && i + 1 < args.length) file = args[++i];
    else if (args[i] == '--activity' && i + 1 < args.length) activity = args[++i];
    else if (args[i] == '--out' && i + 1 < args.length) out = args[++i];
  }
  if (file == null || activity == null || !{'running', 'sitting'}.contains(activity)) {
    stderr.writeln('Usage: dart run tools/replay_public.dart --file FILE --activity running|sitting [--out FILE]');
    exitCode = 2;
    return;
  }
  final input = File(file);
  if (!input.existsSync()) {
    stderr.writeln('Missing public CSV: $file');
    exitCode = 2;
    return;
  }
  final lines = input.readAsLinesSync();
  if (lines.length < 3) {
    stderr.writeln('Empty trial'); exitCode = 2; return;
  }
  final columns = lines.first.trim().split(',');
  int index(String name) {
    final index = columns.indexOf(name);
    if (index < 0) throw FormatException('Missing column $name');
    return index;
  }
  final tIdx = index('elapsedMillis');
  final xIdx = index('accelerometerAccelerationX');
  final yIdx = index('accelerometerAccelerationY');
  final zIdx = index('accelerometerAccelerationZ');
  final labelIdx = index('actionKeyword');
  final e = GaitEngine();
  var samples = 0;
  var zeroPaddingRows = 0;
  var rejected = 0;
  final acceptedEventTimes = <int>[];
  final detectedStepTimes = <int>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final cells = line.split(',');
    if (cells.length != columns.length) throw FormatException('Malformed row ${samples + 2}');
    if (cells[labelIdx].trim().toLowerCase() != activity) {
      throw FormatException('Unexpected activity at row ${samples + 2}');
    }
    final milliseconds = double.parse(cells[tIdx]);
    final ax = double.parse(cells[xIdx]);
    final ay = double.parse(cells[yIdx]);
    final az = double.parse(cells[zIdx]);
    if (!milliseconds.isFinite || !ax.isFinite || !ay.isFinite || !az.isFinite) {
      throw FormatException('Non-finite measurement at row ${samples + 2}');
    }
    if (ax == 0 && ay == 0 && az == 0) {
      zeroPaddingRows++;
      continue;  // Dataset begins with an invalid all-zero placeholder.
    }
    final us = (milliseconds * 1000).round();
    final result = e.process(timestampUs: us, ax: ax, ay: ay, az: az);
    samples++;
    if (!result.accepted) rejected++;
    else acceptedEventTimes.add(us);
    if (result.stepDetected && result.stepTimestampUs != null) {
      detectedStepTimes.add(result.stepTimestampUs!);
    }
  }
  final duration = acceptedEventTimes.length >= 2
      ? (acceptedEventTimes.last - acceptedEventTimes.first) / 1e6 : 0.0;
  final report = <String, dynamic>{
    'schema': 'gaitlab.public-replay.v1',
    'dataset': 'AZI350 Smartphone IMU Three Positions',
    'activity': activity,
    'file': input.path,
    'input_samples': samples,
    'zero_padding_rows_skipped': zeroPaddingRows,
    'rejected_samples': rejected,
    'duration_s': duration,
    'observed_hz_last_5s': e.actualHz,
    'sampling_gaps': e.samplingGaps,
    'candidate_steps': e.stepCount,
    'candidate_step_times_ms': detectedStepTimes.map((t) => t / 1000).toList(),
    'median_candidate_cadence_spm': e.cadence,
    'periodicity_score': e.periodicity,
    'signal_grade': e.signalStatus.grade.name,
    'has_per_step_ground_truth': false,
    'verification_level': 'replay/activity negative control ONLY, not step accuracy',
  };
  final jsonText = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(jsonText);
  if (out != null) {
    final outputFile = File(out);
    outputFile.parent.createSync(recursive: true);
    outputFile.writeAsStringSync('$jsonText\n');
  }
  // Conservative automated smoke criterion, not a gait accuracy pass.
  final plausiblyRunning = e.stepCount >= 8 && e.stepCount <= duration * 5;
  final staticControl = e.stepCount <= 2;
  final samplingOk = e.actualHz >= 40 && e.actualHz < 120;
  if (!samplingOk || rejected > 0 ||
      (activity == 'running' && !plausiblyRunning) ||
      (activity == 'sitting' && !staticControl)) {
    stderr.writeln('PUBLIC-REPLAY-SMOKE FAILED; do not infer reference accuracy.');
    exitCode = 1;
  }
}
