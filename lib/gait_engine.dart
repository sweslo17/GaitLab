import 'dart:collection';
import 'dart:math' as math;

/// Sensor-derived *candidate* step, not a validated foot-contact event.
/// No contact time, foot identity, stride length or injury inference is made.
class SampleResult {
  const SampleResult({
    required this.vertical,
    required this.filtered,
    required this.stepDetected,
    required this.timestampUs,
    required this.stepIntervalMs,
    required this.accepted,
    this.stepTimestampUs,
    this.threshold = 0,
  });

  final double vertical;
  final double filtered;
  final bool stepDetected;
  final int timestampUs;
  final int? stepTimestampUs;
  final double? stepIntervalMs;
  final bool accepted;
  final double threshold;
}

enum SignalGrade { warmingUp, stationary, unreliable, review, usable }

class SignalStatus {
  const SignalStatus(this.grade, this.explanation);
  final SignalGrade grade;
  final String explanation;
}

/// Pure Dart analysis; no dependency on Flutter or sensor SDK.
///
/// Calculations are EXPERIMENTAL. The periodicity score is an autocorrelation
/// *sanity check* (not a probability, classifier or clinical confidence).
class GaitEngine {
  GaitEngine({this.peakMultiplier = 0.62});

  final double peakMultiplier;
  static const double minStepMs = 270;
  static const double maxStepMs = 900;

  final ListQueue<double> _intervalsMs = ListQueue<double>();
  final ListQueue<double> _waveform = ListQueue<double>();
  final ListQueue<double> _rmsWindow = ListQueue<double>();
  final ListQueue<double> _periodWindow = ListQueue<double>();
  final ListQueue<int> _sampleTimes = ListQueue<int>();
  final ListQueue<int> _normalDts = ListQueue<int>();
  final ListQueue<({int timeUs, int missing})> _recentGaps =
      ListQueue<({int timeUs, int missing})>();

  double _gravityX = 0, _gravityY = 0, _gravityZ = 9.81;
  double _filtered = 0, _previous = 0, _beforePrevious = 0;
  double _rmsSum = 0;
  int? _lastTs, _previousSignalTs, _lastCandidateTs, _firstTs;
  int _periodUpdate = 0;
  static const int warmupUs = 600000;
  bool _initialized = false;

  int stepCount = 0;
  int acceptedSamples = 0;
  int rejectedSamples = 0;
  int samplingGaps = 0;
  int estimatedMissingSamples = 0;
  double periodicity = 0;
  double peakThreshold = 0;

  List<double> get waveform => _waveform.toList(growable: false);
  List<double> get intervalsMs => _intervalsMs.toList(growable: false);

  double get cadence {
    if (_intervalsMs.length < 3) return 0;
    final m = median(_intervalsMs.toList());
    return m > 0 ? 60000 / m : 0;
  }

  double get stepTimeMs =>
      _intervalsMs.isEmpty ? 0 : median(_intervalsMs.toList());

  double get cvPercent {
    if (_intervalsMs.length < 6) return 0;
    final list = _intervalsMs.toList();
    final avg = list.reduce((a, b) => a + b) / list.length;
    final variance = list.fold<double>(0.0, (v, x) =>
        v + (x - avg) * (x - avg)) / list.length;
    return avg == 0 ? 0 : 100 * math.sqrt(variance) / avg;
  }

  double get signalRms => _rmsWindow.isEmpty
      ? 0
      : math.sqrt(math.max(0, _rmsSum / _rmsWindow.length));

  /// Measured event frequency, not the requested sensor period.
  double get actualHz {
    if (_sampleTimes.length < 3) return 0;
    final sec = (_sampleTimes.last - _sampleTimes.first) / 1e6;
    return sec > 0 ? (_sampleTimes.length - 1) / sec : 0;
  }

  /// Approximate missed samples in the trailing five seconds, instead of
  /// letting a long session average conceal a recent sensor interruption.
  double get recentLossPercent {
    if (_lastTs == null) return 0;
    final sinceUs = _lastTs! - 5000000;
    var lost = 0;
    for (final gap in _recentGaps) {
      if (gap.timeUs >= sinceUs) lost += gap.missing;
    }
    var samples = 0;
    for (final t in _sampleTimes) {
      if (t >= sinceUs) samples++;
    }
    final total = samples + lost;
    return total == 0 ? 0 : lost * 100 / total;
  }

  double get estimatedLossPercent {
    final total = acceptedSamples + estimatedMissingSamples;
    return total <= 0 ? 0 : 100 * estimatedMissingSamples / total;
  }

  SignalStatus get signalStatus {
    if (acceptedSamples < 220) {
      return const SignalStatus(SignalGrade.warmingUp, '暖機中：尚未收集足夠樣本');
    }
    if (signalRms < 0.42) {
      return const SignalStatus(SignalGrade.stationary, '動作訊號偏弱，可能停止或腰帶過鬆');
    }
    if (actualHz < 45 || recentLossPercent > 5 ||
        (acceptedSamples > 100 && rejectedSamples / acceptedSamples > .01)) {
      return const SignalStatus(SignalGrade.unreliable, '取樣偏慢／不連續，請確認省電設定');
    }
    if (actualHz < 65) {
      return const SignalStatus(SignalGrade.review,
          '取樣頻率較低；步頻僅供初步參考，請對照人工計數');
    }
    if (periodicity < 0.35 || _intervalsMs.length < 4) {
      return const SignalStatus(SignalGrade.review, '週期性不足，步數可能有誤');
    }
    return const SignalStatus(SignalGrade.usable, '訊號可供初步比較（非醫療驗證）');
  }

  static double median(List<double> values) {
    if (values.isEmpty) return 0;
    values.sort();
    final middle = values.length ~/ 2;
    return values.length.isOdd
        ? values[middle]
        : (values[middle - 1] + values[middle]) / 2;
  }

  /// Normalized autocorrelation, searching 0.27–0.90 s for periodic gait.
  /// A half-stride and full-stride peak can compete; this is *not* a step counter.
  void _updatePeriodicity() {
    if (_periodWindow.length < 180 || actualHz < 45) {
      periodicity = 0;
      return;
    }
    final samples = _periodWindow.toList(growable: false);
    final hz = actualHz.clamp(45.0, 220.0);
    final minLag = (hz * .27).round();
    final maxLag = math.min(samples.length ~/ 2, (hz * .90).round());
    double best = 0;
    for (var lag = minLag; lag <= maxLag; lag += 1) {
      double a = 0, b = 0;
      final n = samples.length - lag;
      for (var j = 0; j < n; j++) {
        a += samples[j];
        b += samples[j + lag];
      }
      a /= n;
      b /= n;
      double dot = 0, aa = 0, bb = 0;
      for (var j = 0; j < n; j++) {
        final x = samples[j] - a;
        final y = samples[j + lag] - b;
        dot += x * y;
        aa += x * x;
        bb += y * y;
      }
      final r = aa * bb > 1e-8 ? dot / math.sqrt(aa * bb) : 0.0;
      if (r > best) best = r;
    }
    periodicity = best.clamp(0.0, 1.0).toDouble();
  }

  void _clearStepTracking() {
    _intervalsMs.clear();
    _lastCandidateTs = null;
    _beforePrevious = 0;
    _previous = 0;
    _previousSignalTs = null;
    _periodWindow.clear();
    periodicity = 0;
    _periodUpdate = 0;
  }

  SampleResult process({
    required int timestampUs,
    required double ax,
    required double ay,
    required double az,
  }) {
    if (!ax.isFinite || !ay.isFinite || !az.isFinite ||
        (_lastTs != null && timestampUs <= _lastTs!)) {
      rejectedSamples++;
      return SampleResult(
        vertical: 0, filtered: _filtered, stepDetected: false,
        timestampUs: timestampUs, stepIntervalMs: null, accepted: false,
        threshold: peakThreshold,
      );
    }
    _firstTs ??= timestampUs;
    if (!_initialized) {
      _gravityX = ax;
      _gravityY = ay;
      _gravityZ = az;
      _initialized = true;
    }
    final previousTs = _lastTs;
    final dtUs = previousTs == null ? 10000 : timestampUs - previousTs;
    final dt = dtUs / 1e6;
    // Use the median of normal intervals as the reference; do not include
    // large gaps in the baseline or they will conceal subsequent loss.
    final baselineReady = _normalDts.length >= 5;
    final expectedUs = baselineReady
        ? median(_normalDts.map((v) => v.toDouble()).toList())
        : dtUs.toDouble();
    if (previousTs != null) {
      final isGap = baselineReady && dtUs > 1.8 * expectedUs;
      if (isGap) {
        samplingGaps++;
        final missing = math.min(10000,
            math.max(0, (dtUs / expectedUs).round() - 1));
        estimatedMissingSamples += missing;
        _recentGaps.addLast((timeUs: timestampUs, missing: missing));
      } else if (dtUs >= 1000 && dtUs <= 60000) {
        _normalDts.addLast(dtUs);
        while (_normalDts.length > 180) { _normalDts.removeFirst(); }
      }
      // A 70–160 ms pause may skip several peaks even though it is smaller
      // than the old 160 ms reset threshold. Break interval continuity.
      if (dtUs > 70000) {
        _clearStepTracking();
        _rmsWindow.clear();
        _rmsSum = 0;
        _filtered = 0;
        _gravityX = ax;
        _gravityY = ay;
        _gravityZ = az;
      }
      while (_recentGaps.isNotEmpty &&
          _recentGaps.first.timeUs < timestampUs - 5000000) {
        _recentGaps.removeFirst();
      }
    }
    _lastTs = timestampUs;
    acceptedSamples++;
    _sampleTimes.addLast(timestampUs);
    // A time-based window is comparable at 50, 100 and 200 Hz.
    while (_sampleTimes.isNotEmpty &&
        _sampleTimes.first < timestampUs - 5000000) {
      _sampleTimes.removeFirst();
    }

    final effectiveDt = dt.clamp(0.001, 0.05);
    final alphaG = math.exp(-effectiveDt / 0.65);
    _gravityX = alphaG * _gravityX + (1 - alphaG) * ax;
    _gravityY = alphaG * _gravityY + (1 - alphaG) * ay;
    _gravityZ = alphaG * _gravityZ + (1 - alphaG) * az;
    final gNorm = math.sqrt(_gravityX * _gravityX +
        _gravityY * _gravityY + _gravityZ * _gravityZ);
    final vertical = gNorm > 1e-6
        ? ((ax - _gravityX) * _gravityX +
            (ay - _gravityY) * _gravityY +
            (az - _gravityZ) * _gravityZ) / gNorm
        : 0.0;

    final alphaF = math.exp(-effectiveDt / 0.035);
    _filtered = alphaF * _filtered + (1 - alphaF) * vertical;
    _rmsWindow.addLast(_filtered);
    _rmsSum += _filtered * _filtered;
    while (_rmsWindow.length > 250) {
      final old = _rmsWindow.removeFirst();
      _rmsSum -= old * old;
    }
    _periodWindow.addLast(_filtered);
    while (_periodWindow.length > 400) { _periodWindow.removeFirst(); }
    _periodUpdate++;
    if (_periodUpdate >= 100) {
      _updatePeriodicity();
      _periodUpdate = 0;
    }

    peakThreshold = math.max(0.85, signalRms * peakMultiplier);
    bool isStep = false;
    double? stepInterval;
    int? stepTimestamp;
    final candidate = _previousSignalTs;
    if (candidate != null &&
        _previous > _beforePrevious && _previous >= _filtered &&
        _previous > peakThreshold && signalRms > .48 &&
        timestampUs - _firstTs! >= warmupUs &&
        (_lastCandidateTs == null || candidate - _lastCandidateTs! >= 270000)) {
      if (_lastCandidateTs != null) {
        final interval = (candidate - _lastCandidateTs!) / 1000;
        if (interval >= minStepMs && interval <= maxStepMs) {
          _intervalsMs.addLast(interval);
          while (_intervalsMs.length > 24) { _intervalsMs.removeFirst(); }
          stepInterval = interval;
        } else {
          _intervalsMs.clear();
        }
      }
      _lastCandidateTs = candidate;
      stepCount++;
      isStep = true;
      stepTimestamp = candidate;
    }
    // Reset stale cadence on a pause, not just on a large timestamp gap.
    if (_lastCandidateTs != null && timestampUs - _lastCandidateTs! > 1800000) {
      _intervalsMs.clear();
      _lastCandidateTs = null;
    }
    _beforePrevious = _previous;
    _previous = _filtered;
    _previousSignalTs = timestampUs;
    _waveform.addLast(_filtered);
    while (_waveform.length > 250) { _waveform.removeFirst(); }

    return SampleResult(
      vertical: vertical, filtered: _filtered, stepDetected: isStep,
      timestampUs: timestampUs, stepTimestampUs: stepTimestamp,
      stepIntervalMs: stepInterval, accepted: true,
      threshold: peakThreshold,
    );
  }
}

/// An optional personal cadence range, not a recommended physiological target.
class CadenceTarget {
  CadenceTarget({required this.minSpm, required this.maxSpm}) {
    if (!minSpm.isFinite ||
        !maxSpm.isFinite ||
        minSpm < 60 ||
        maxSpm > 240 ||
        minSpm >= maxSpm) {
      throw ArgumentError('Cadence range must satisfy 60 <= min < max <= 240');
    }
  }
  final double minSpm;
  final double maxSpm;
  bool contains(double cadence) =>
      cadence.isFinite && cadence >= minSpm && cadence <= maxSpm;
  Map<String, dynamic> toJson() => {'min_spm': minSpm, 'max_spm': maxSpm};
}

/// One native-time bin. Null values mean unavailable, never a perfect score.
/// [elapsedSeconds] marks its start, relative to the first accepted sample.
/// Values are duration-weighted means of existing rolling engine estimates.
class MetricPoint {
  const MetricPoint({
    required this.elapsedSeconds,
    required this.durationSeconds,
    required this.cadenceSpm,
    required this.intervalCvPercent,
    required this.signalRms,
    required this.periodicity,
    required this.actualHz,
    required this.grade,
    required this.gap,
  });
  final double elapsedSeconds;
  final double durationSeconds;
  final double? cadenceSpm;
  final double? intervalCvPercent;
  final double? signalRms;
  final double? periodicity;
  final double? actualHz;
  final SignalGrade grade;
  final bool gap;
  Map<String, dynamic> toJson() => {
    'elapsed_seconds': elapsedSeconds,
    'duration_seconds': durationSeconds,
    'candidate_cadence_spm': cadenceSpm,
    'candidate_interval_cv_percent': intervalCvPercent,
    'filtered_signal_rms_m_s2': signalRms,
    'periodicity_proxy': periodicity,
    'actual_hz': actualHz,
    'quality_grade': grade.name,
    'gap': gap,
  };
}

/// Compare fixed, disjoint windows within one recording at fixed phone placement.
/// Cadence matching is an exploratory guard, not evidence of matched speed.
Map<String, dynamic> compareSessionTrends(List<MetricPoint> points) {
  const windowSeconds = 30.0;
  const minUsableSeconds = 24.0;
  const cadenceGuard = .05;
  bool measured(MetricPoint p) =>
      p.elapsedSeconds.isFinite &&
      p.elapsedSeconds >= 0 &&
      p.durationSeconds.isFinite &&
      p.durationSeconds > 0 &&
      (p.elapsedSeconds + p.durationSeconds).isFinite;
  bool eligible(MetricPoint p) =>
      p.grade == SignalGrade.usable &&
      !p.gap &&
      p.cadenceSpm != null &&
      p.cadenceSpm!.isFinite &&
      p.cadenceSpm! > 0;
  final measuredPoints = points.where(measured).toList()
    ..sort((a, b) => a.elapsedSeconds.compareTo(b.elapsedSeconds));
  final usablePoints = measuredPoints.where(eligible).toList();
  final baselineStart = usablePoints.isEmpty
      ? null
      : usablePoints.first.elapsedSeconds;
  final baselineEnd = baselineStart == null
      ? null
      : baselineStart + windowSeconds;
  final recentEnd = measuredPoints.isEmpty
      ? null
      : measuredPoints
            .map((p) => p.elapsedSeconds + p.durationSeconds)
            .reduce(math.max);
  final recentStart = recentEnd != null && recentEnd >= windowSeconds
      ? recentEnd - windowSeconds
      : null;
  double overlap(MetricPoint p, double start, double end) => math.max(
    0,
    math.min(end, p.elapsedSeconds + p.durationSeconds) -
        math.max(start, p.elapsedSeconds),
  );
  double coverage(double? start, double? end) => start == null || end == null
      ? 0
      : usablePoints.fold(0.0, (sum, p) => sum + overlap(p, start, end));
  final baselineUsable = coverage(baselineStart, baselineEnd);
  final recentUsable = coverage(recentStart, recentEnd);
  final metrics = <String, dynamic>{
    'cadence': null,
    'rms': null,
    'interval_cv': null,
    'periodicity': null,
  };
  final result = <String, dynamic>{
    'status': 'collecting',
    'window_seconds': windowSeconds,
    'min_usable_seconds': minUsableSeconds,
    'cadence_guard_relative': cadenceGuard,
    'baseline_start_s': baselineStart,
    'baseline_end_s': baselineEnd,
    'recent_start_s': recentStart,
    'recent_end_s': recentEnd,
    'baseline_usable_s': baselineUsable,
    'recent_usable_s': recentUsable,
    'metrics': metrics,
    'cadence_guard_exploratory': true,
    'cadence_guard_validated': false,
    'comparison_limitations':
        'Fixed phone placement is assumed. Similar cadence does not establish '
        'matched speed or terrain. The 5% guard is not a validated threshold. '
        'Changes are experimental signal trends, not improvement or harm.',
  };
  if (baselineStart == null) {
    if (measuredPoints.isNotEmpty &&
        recentEnd! - measuredPoints.first.elapsedSeconds >= 2 * windowSeconds) {
      result['status'] = 'insufficient_quality';
    }
    return result;
  }
  if (recentStart == null || recentStart < baselineEnd!) return result;
  if (baselineUsable < minUsableSeconds || recentUsable < minUsableSeconds) {
    result['status'] = 'insufficient_quality';
    return result;
  }
  double? mean(double start, double end, double? Function(MetricPoint) select) {
    var seconds = 0.0;
    var sum = 0.0;
    for (final p in usablePoints) {
      final value = select(p);
      if (value == null || !value.isFinite) continue;
      final duration = overlap(p, start, end);
      seconds += duration;
      sum += value * duration;
    }
    if (seconds < minUsableSeconds) return null;
    final value = sum / seconds;
    return value.isFinite ? value : null;
  }

  Map<String, dynamic>? compare(double? Function(MetricPoint) select) {
    final baseline = mean(baselineStart, baselineEnd, select);
    final recent = mean(recentStart, recentEnd!, select);
    if (baseline == null || recent == null) return null;
    final delta = recent - baseline;
    if (!delta.isFinite) return null;
    final relative = baseline > 0 ? 100 * delta / baseline : null;
    return {
      'baseline': baseline,
      'recent': recent,
      'delta': delta,
      'relative_percent': relative != null && relative.isFinite
          ? relative
          : null,
    };
  }

  final cadence = compare((p) => p.cadenceSpm);
  metrics['cadence'] = cadence;
  if (cadence == null) {
    result['status'] = 'insufficient_quality';
    return result;
  }
  if ((cadence['delta'] as double).abs() / (cadence['baseline'] as double) >
      cadenceGuard) {
    result['status'] = 'cadence_changed';
    return result;
  }
  double? nonnegative(double? value) =>
      value != null && value >= 0 ? value : null;
  metrics['rms'] = compare((p) => nonnegative(p.signalRms));
  metrics['interval_cv'] = compare((p) => nonnegative(p.intervalCvPercent));
  metrics['periodicity'] = compare((p) => p.periodicity);
  result['status'] = 'ready';
  return result;
}

/// Pure Dart session summaries, separate from the unchanged peak detector.
///
/// Each interval uses the preceding accepted sample's state. Intervals over
/// 70 ms are wholly missing and earn no quality or cadence-time credit.
/// Only usable-quality, positive cadence contributes to cadence/target time.
/// No estimate extends beyond the last native sample. A longer wall duration
/// adds missing time to the denominator, not fabricated sensor measurements.
class SessionMetrics {
  SessionMetrics({this.target});
  final CadenceTarget? target;
  final List<MetricPoint> _trends = [];
  final Map<String, int> _gradeUs = {
    for (final grade in SignalGrade.values) grade.name: 0,
    'missing': 0,
  };
  int? _firstUs, _lastUs;
  _MetricObservation? _previousObservation;
  int _observedSamples = 0, _ignoredSamples = 0;
  int _cadenceUs = 0, _targetUs = 0;
  double _cadenceIntegral = 0;
  _MetricBin _bin = _MetricBin(0);
  bool _finished = false;

  /// Complete one-second bins, plus the final partial bin after [finish].
  List<MetricPoint> get trends => List.unmodifiable(_trends);

  void observe({
    required int timestampUs,
    required GaitEngine engine,
    required SampleResult sample,
  }) {
    if (_finished) return;
    if (!sample.accepted || (_lastUs != null && timestampUs <= _lastUs!)) {
      _ignoredSamples++;
      return;
    }
    final previousUs = _lastUs;
    _firstUs ??= timestampUs;
    if (previousUs != null) {
      final delta = timestampUs - previousUs;
      final observation = delta > 70000 ? null : _previousObservation;
      if (observation == null) {
        _gradeUs['missing'] = _gradeUs['missing']! + delta;
      } else {
        _gradeUs[observation.grade.name] =
            _gradeUs[observation.grade.name]! + delta;
        if (observation.cadence != null) {
          _cadenceUs += delta;
          _cadenceIntegral += observation.cadence! * delta;
          if (target?.contains(observation.cadence!) ?? false) {
            _targetUs += delta;
          }
        }
      }
      var cursor = previousUs - _firstUs!;
      final stop = timestampUs - _firstUs!;
      while (cursor < stop) {
        final end = math.min(stop, _bin.startUs + 1000000);
        _bin.add(end - cursor, observation);
        cursor = end;
        if (cursor == _bin.startUs + 1000000) {
          _trends.add(_bin.point());
          _bin = _MetricBin(cursor);
        }
      }
    }
    _lastUs = timestampUs;
    _observedSamples++;
    _previousObservation = _MetricObservation.fromEngine(engine);
  }

  /// Flush only measured duration. Calling this twice cannot duplicate a bin.
  void finish() {
    if (_finished) return;
    if (_bin.durationUs > 0) _trends.add(_bin.point());
    _finished = true;
  }

  Map<String, dynamic> summary({double? recordingSeconds}) {
    if (recordingSeconds != null &&
        (!recordingSeconds.isFinite || recordingSeconds < 0)) {
      throw ArgumentError('Recording duration must be finite and nonnegative');
    }
    final sensorSeconds = _firstUs == null ? 0.0 : (_lastUs! - _firstUs!) / 1e6;
    final total = math.max(sensorSeconds, recordingSeconds ?? sensorSeconds);
    final usable = _gradeUs[SignalGrade.usable.name]! / 1e6;
    final grades = {
      for (final entry in _gradeUs.entries) entry.key: entry.value / 1e6,
    };
    grades['missing'] = grades['missing']! + (total - sensorSeconds);
    return {
      'schema': 'gaitlab.session-metrics.v1',
      'sensor_duration_s': sensorSeconds,
      'recording_duration_s': total,
      'usable_seconds': usable,
      'usable_percent': total > 0 ? 100 * usable / total : null,
      'cadence_available_seconds': _cadenceUs / 1e6,
      'cadence_spm_time_weighted_mean': _cadenceUs > 0
          ? _cadenceIntegral / _cadenceUs
          : null,
      'target': target?.toJson(),
      'target_seconds': target == null ? null : _targetUs / 1e6,
      'target_percent': target != null && _cadenceUs > 0
          ? 100 * _targetUs / _cadenceUs
          : null,
      'grade_seconds': grades,
      'observed_samples': _observedSamples,
      'ignored_samples': _ignoredSamples,
      'trend_comparison': compareSessionTrends(_trends),
      'trend_bin_seconds': 1,
      'gap_threshold_ms': 70,
      'time_credit_rule': 'Previous accepted state; gaps over 70 ms wholly missing; usable-quality positive cadence only for target denominator',
      'warning': 'Experimental candidate events and signal trends; quality coverage is not step accuracy.',
    };
  }
}

class _MetricObservation {
  const _MetricObservation(
    this.grade,
    this.cadence,
    this.cv,
    this.rms,
    this.periodicity,
    this.hz,
  );
  factory _MetricObservation.fromEngine(GaitEngine engine) {
    final grade = engine.signalStatus.grade;
    final available = grade == SignalGrade.usable;
    double? finite(double value) => value.isFinite ? value : null;
    final cadence = engine.cadence;
    return _MetricObservation(
      grade,
      available && cadence > 0 ? finite(cadence) : null,
      available && engine.intervalsMs.length >= 6
          ? finite(engine.cvPercent)
          : null,
      grade == SignalGrade.warmingUp ? null : finite(engine.signalRms),
      grade == SignalGrade.warmingUp ? null : finite(engine.periodicity),
      engine.actualHz > 0 ? finite(engine.actualHz) : null,
    );
  }
  final SignalGrade grade;
  final double? cadence, cv, rms, periodicity, hz;
}

class _MetricMean {
  double sum = 0;
  int duration = 0;
  void add(double? value, int us) {
    if (value == null) return;
    sum += value * us;
    duration += us;
  }

  double? get value => duration > 0 ? sum / duration : null;
}

class _MetricBin {
  _MetricBin(this.startUs);
  final int startUs;
  int durationUs = 0;
  bool gap = false;
  final Set<SignalGrade> _grades = {};
  final _cadence = _MetricMean(),
      _cv = _MetricMean(),
      _rms = _MetricMean(),
      _periodicity = _MetricMean(),
      _hz = _MetricMean();
  void add(int duration, _MetricObservation? observation) {
    durationUs += duration;
    if (observation == null) {
      gap = true;
      return;
    }
    _grades.add(observation.grade);
    _cadence.add(observation.cadence, duration);
    _cv.add(observation.cv, duration);
    _rms.add(observation.rms, duration);
    _periodicity.add(observation.periodicity, duration);
    _hz.add(observation.hz, duration);
  }

  MetricPoint point() {
    // A conservative bin grade never hides a brief unreliable state.
    final grade = gap || _grades.contains(SignalGrade.unreliable)
        ? SignalGrade.unreliable
        : _grades.contains(SignalGrade.warmingUp)
        ? SignalGrade.warmingUp
        : _grades.contains(SignalGrade.stationary)
        ? SignalGrade.stationary
        : _grades.contains(SignalGrade.review)
        ? SignalGrade.review
        : SignalGrade.usable;
    return MetricPoint(
      elapsedSeconds: startUs / 1e6,
      durationSeconds: durationUs / 1e6,
      cadenceSpm: grade == SignalGrade.usable ? _cadence.value : null,
      intervalCvPercent: grade == SignalGrade.usable ? _cv.value : null,
      signalRms: gap ? null : _rms.value,
      periodicity: gap ? null : _periodicity.value,
      actualHz: gap ? null : _hz.value,
      grade: grade,
      gap: gap,
    );
  }
}

/// Exploratory signal states. These do not identify walking, running or foot contacts.
enum MotionState { unavailable, rotation, quiet, rhythmic, other }

class MotionBin {
  const MotionBin({
    required this.startSeconds,
    required this.durationSeconds,
    required this.accelCoverage,
    required this.gyroCoverage,
    required this.state,
    this.accelerationRms,
    this.rotationRms,
    this.forwardRms,
    this.lateralRms,
    this.verticalRms,
    this.verticalMeanRate,
  });
  final double startSeconds, durationSeconds, accelCoverage, gyroCoverage;
  final MotionState state;
  final double? accelerationRms,
      rotationRms,
      forwardRms,
      lateralRms,
      verticalRms,
      verticalMeanRate;
  Map<String, dynamic> toJson() {
    final energy = forwardRms == null
        ? 0.0
        : forwardRms! * forwardRms! +
              lateralRms! * lateralRms! +
              verticalRms! * verticalRms!;
    return {
      'start_s': startSeconds,
      'duration_s': durationSeconds,
      'accel_coverage': accelCoverage,
      'gyro_coverage': gyroCoverage,
      'state': state.name,
      'acceleration_rms_m_s2': accelerationRms,
      'rotation_rms_rad_s': rotationRms,
      'forward_rms_m_s2': forwardRms,
      'lateral_rms_m_s2': lateralRms,
      'vertical_rms_m_s2': verticalRms,
      'vertical_mean_rate_rad_s': verticalMeanRate,
      'direction_energy_percent': energy > 1e-8
          ? {
              'forward': 100 * forwardRms! * forwardRms! / energy,
              'lateral': 100 * lateralRms! * lateralRms! / energy,
              'vertical': 100 * verticalRms! * verticalRms! / energy,
            }
          : null,
    };
  }
}

class _MotionVector {
  const _MotionVector(this.x, this.y, this.z);
  final double x, y, z;
  double dot(_MotionVector b) => x * b.x + y * b.y + z * b.z;
  _MotionVector operator +(_MotionVector b) =>
      _MotionVector(x + b.x, y + b.y, z + b.z);
  _MotionVector operator -(_MotionVector b) =>
      _MotionVector(x - b.x, y - b.y, z - b.z);
  _MotionVector operator *(double k) => _MotionVector(x * k, y * k, z * k);
  double get length => math.sqrt(dot(this));
  _MotionVector get unit => this * (1 / length);
  _MotionVector cross(_MotionVector b) =>
      _MotionVector(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x);
  List<double> get values => [x, y, z];
}

/// Time integrals retain independent sensor coverage and callback order.
class _MotionIntegral {
  int us = 0;
  double xx = 0, yy = 0, zz = 0, xy = 0, xz = 0, yz = 0, sx = 0, sy = 0, sz = 0;
  double rhythmicUs = 0;
  void add(_MotionVector v, int dt, {bool rhythmic = false}) {
    us += dt;
    xx += v.x * v.x * dt;
    yy += v.y * v.y * dt;
    zz += v.z * v.z * dt;
    xy += v.x * v.y * dt;
    xz += v.x * v.z * dt;
    yz += v.y * v.z * dt;
    sx += v.x * dt;
    sy += v.y * dt;
    sz += v.z * dt;
    if (rhythmic) rhythmicUs += dt;
  }

  double get rms => math.sqrt(math.max(0, (xx + yy + zz) / us));
  double projectedRms(_MotionVector a) => math.sqrt(
    math.max(
      0,
      (a.x * a.x * xx +
              a.y * a.y * yy +
              a.z * a.z * zz +
              2 * a.x * a.y * xy +
              2 * a.x * a.z * xz +
              2 * a.y * a.z * yz) /
          us,
    ),
  );
  double projectedMean(_MotionVector a) =>
      (sx * a.x + sy * a.y + sz * a.z) / us;
}

/// Phone-mounted local frame, not an earth-fixed trajectory or pelvis angle.
class MotionAnalysis {
  MotionAnalysis({this.calibrate = false, this.screenFacesBody = true});
  final bool calibrate, screenFacesBody;
  final Map<int, _MotionIntegral> _acc = {}, _gyro = {};
  final Queue<({int start, int end, _MotionVector value})> _pendingGyro =
      Queue();
  int? _origin,
      _lastAcc,
      _lastGyro,
      _filterStart,
      _calibratedAt,
      _invalidatedAt;
  _MotionVector? _gravity,
      _previousAcceleration,
      _previousGyro,
      _up,
      _forward,
      _lateral;
  bool _previousRhythmic = false, _finished = false, _calibrationGap = false;
  int _calibrationCount = 0, _rejectedAcc = 0, _rejectedGyro = 0;
  _MotionVector _calibrationSum = const _MotionVector(0, 0, 0);
  double _calibrationSquares = 0;
  String? _failure;
  String get calibrationStatus {
    if (!calibrate) return 'disabled';
    if (_invalidatedAt != null) return 'invalidated';
    if (_failure != null) return 'failed';
    if (_calibratedAt != null) return 'ready';
    final elapsed = _origin == null ? 0 : (_lastAcc! - _origin!) / 1e6;
    return elapsed < 10 ? 'preparing' : 'collecting';
  }

  String? get calibrationReason => _failure;
  Map<String, dynamic> get parameters => {
    'version': 1,
    'numeric_input_vector_norm_limit': 1e6,
    'calibration_requested': calibrate,
    'screen_faces_body': screenFacesBody,
    'mount': 'rear_center_waist_screen_normal_defines_forward',
    'prepare_seconds': 10,
    'calibration_seconds': 5,
    'min_calibration_samples': 200,
    'max_calibration_vector_sd_m_s2': .2,
    'gravity_norm_range_m_s2': [8.5, 11],
    'min_horizontal_screen_normal': .5,
    'max_tilt_change_degrees': 35,
    'gravity_low_pass_tau_s': .5,
    'filter_warmup_s': 5,
    'gap_threshold_ms': 70,
    'bin_seconds': 1,
    'min_coverage': .8,
    'quiet_accel_rms_m_s2': .2,
    'quiet_gyro_rms_rad_s': .15,
    'rotation_mean_rate_rad_s': .35,
    'rhythmic_periodicity_min': .55,
    'rhythmic_cadence_min_exclusive': 0,
    'frame': 'fixed_to_assumed_body_mount_at_calibration_not_earth_frame',
    'time_alignment': 'native_timestamp_bins_approximate_cross_sensor_alignment_not_verified_sync',
    'validation':
        'engineering_tests_only_not_validated_activity_or_biomechanics',
  };

  void _integrate(
    Map<int, _MotionIntegral> target,
    int start,
    int end,
    _MotionVector value, {
    bool rhythmic = false,
  }) {
    if (_origin == null) return;
    var cursor = math.max(start, _origin!);
    while (cursor < end) {
      final key = (cursor - _origin!) ~/ 1000000;
      final stop = math.min(end, _origin! + (key + 1) * 1000000);
      (target[key] ??= _MotionIntegral()).add(
        value,
        stop - cursor,
        rhythmic: rhythmic,
      );
      cursor = stop;
    }
  }

  void _updateCalibration(int timestamp, _MotionVector value, int? previous) {
    if (!calibrate || _failure != null || _calibratedAt != null) return;
    final elapsed = timestamp - _origin!;
    if (previous != null &&
        timestamp - previous > 70000 &&
        elapsed >= 10000000 &&
        previous - _origin! < 15000000) {
      _calibrationGap = true;
    }
    if (elapsed >= 10000000 && elapsed < 15000000) {
      _calibrationCount++;
      _calibrationSum = _calibrationSum + value;
      _calibrationSquares += value.dot(value);
    }
    if (elapsed < 15000000) return;
    if (_calibrationCount < 200 || _calibrationGap) {
      _failure = '校正資料不足或中斷，請重新紀錄並直立不動。';
      return;
    }
    final mean = _calibrationSum * (1 / _calibrationCount);
    final sd = math.sqrt(
      math.max(0, _calibrationSquares / _calibrationCount - mean.dot(mean)),
    );
    if (mean.length < 8.5 || mean.length > 11 || sd > .2) {
      _failure = '校正時手機有移動，請固定後重新紀錄。';
      return;
    }
    final up = mean.unit;
    final normal = const _MotionVector(0, 0, 1) * (screenFacesBody ? 1 : -1);
    final horizontal = normal - up * normal.dot(up);
    if (horizontal.length < .5) {
      _failure = '手機螢幕太接近水平，請直立固定在後腰中央再校正。';
      return;
    }
    _up = up;
    _forward = horizontal.unit;
    _lateral = up.cross(_forward!);
    _calibratedAt = timestamp;
  }

  void addAcceleration(
    int timestampUs,
    double x,
    double y,
    double z, {
    required double cadence,
    required double periodicity,
  }) {
    if (_finished) return;
    if (!x.isFinite ||
        !y.isFinite ||
        !z.isFinite ||
        !_MotionVector(x, y, z).length.isFinite ||
        _MotionVector(x, y, z).length > 1e6 ||
        (_lastAcc != null && timestampUs <= _lastAcc!)) {
      _rejectedAcc++;
      _previousAcceleration = null;
      if (calibrate && _calibratedAt == null) _calibrationGap = true;
      return;
    }
    final value = _MotionVector(x, y, z);
    _origin ??= timestampUs;
    final previous = _lastAcc;
    final gap = previous == null || timestampUs - previous > 70000;
    if (gap) {
      _gravity = value;
      _filterStart = timestampUs;
      _previousAcceleration = null;
    } else {
      final dt = (timestampUs - previous) / 1e6;
      _gravity = _gravity! + (value - _gravity!) * (1 - math.exp(-dt / .5));
    }
    _updateCalibration(timestampUs, value, previous);
    if (_up != null &&
        _invalidatedAt == null &&
        _gravity!.length > 1 &&
        _gravity!.unit.dot(_up!) < math.cos(35 * math.pi / 180)) {
      _invalidatedAt = timestampUs;
      _failure = '手機方向偏離校正，三向結果暫停；請重新固定並開始校正。';
    }
    if (!gap && _previousAcceleration != null) {
      _integrate(
        _acc,
        previous,
        timestampUs,
        _previousAcceleration!,
        rhythmic: _previousRhythmic,
      );
    }
    final warmed = timestampUs - _filterStart! >= 5000000;
    final calibrationDone = !calibrate || timestampUs - _origin! >= 15000000;
    _previousAcceleration = warmed && calibrationDone
        ? value - _gravity!
        : null;
    _previousRhythmic =
        cadence.isFinite &&
        cadence > 0 &&
        periodicity.isFinite &&
        periodicity >= .55;
    _lastAcc = timestampUs;
    _drainGyro();
  }

  void _drainGyro() {
    if (_origin == null || _lastAcc == null) return;
    while (_pendingGyro.isNotEmpty) {
      final segment = _pendingGyro.first;
      if (segment.start >= _lastAcc!) break;
      _pendingGyro.removeFirst();
      final end = math.min(segment.end, _lastAcc!);
      _integrate(_gyro, segment.start, end, segment.value);
      if (segment.end > end) {
        _pendingGyro.addFirst((
          start: end,
          end: segment.end,
          value: segment.value,
        ));
        break;
      }
    }
  }

  void addGyroscope(int timestampUs, double x, double y, double z) {
    if (_finished) return;
    if (!x.isFinite ||
        !y.isFinite ||
        !z.isFinite ||
        !_MotionVector(x, y, z).length.isFinite ||
        _MotionVector(x, y, z).length > 1e6 ||
        (_lastGyro != null && timestampUs <= _lastGyro!)) {
      _rejectedGyro++;
      _previousGyro = null;
      return;
    }
    final previous = _lastGyro;
    if (previous != null &&
        timestampUs - previous <= 70000 &&
        _previousGyro != null) {
      _pendingGyro.add((
        start: previous,
        end: timestampUs,
        value: _previousGyro!,
      ));
    }
    _lastGyro = timestampUs;
    _previousGyro = _MotionVector(x, y, z);
    _drainGyro();
  }

  List<MotionBin> get bins {
    if (_origin == null || _lastAcc == _origin) return const [];
    final span = (_lastAcc! - _origin!) / 1e6;
    final end = _finished ? span : span.floorToDouble();
    if (end <= 0) return const [];
    final keys = {..._acc.keys, ..._gyro.keys}.where((k) => k < end).toList()
      ..sort();
    final result = <MotionBin>[];
    double cursor = 0;
    void missing(double start, double duration) {
      if (duration > 0) {
        result.add(
          MotionBin(
            startSeconds: start,
            durationSeconds: duration,
            accelCoverage: 0,
            gyroCoverage: 0,
            state: MotionState.unavailable,
          ),
        );
      }
    }

    for (final key in keys) {
      final start = key.toDouble(), duration = math.min(1.0, end - start);
      missing(cursor, start - cursor);
      final a = _acc[key] ?? _MotionIntegral(), g = _gyro[key];
      final ac = math.min(1.0, a.us / (duration * 1e6));
      final gc = g == null ? 0.0 : math.min(1.0, g.us / (duration * 1e6));
      final ar = ac >= .8 ? a.rms : null, gr = gc >= .8 ? g!.rms : null;
      // Whole bins must lie inside the calibrated interval. No history backfill.
      final framed =
          _calibratedAt != null &&
          _origin! + key * 1000000 >= _calibratedAt! &&
          (_invalidatedAt == null ||
              _origin! + (start + duration) * 1e6 <= _invalidatedAt!);
      final vr = framed && gc >= .8 ? g!.projectedMean(_up!) : null;
      final state = ar == null
          ? MotionState.unavailable
          : vr != null && vr.abs() >= .35
          ? MotionState.rotation
          : ar < .2
          ? (gr == null
                ? MotionState.unavailable
                : gr < .15
                ? MotionState.quiet
                : MotionState.other)
          : a.rhythmicUs / a.us >= .8
          ? MotionState.rhythmic
          : MotionState.other;
      result.add(
        MotionBin(
          startSeconds: start,
          durationSeconds: duration,
          accelCoverage: ac,
          gyroCoverage: gc,
          state: state,
          accelerationRms: ar,
          rotationRms: gr,
          forwardRms: framed && ar != null ? a.projectedRms(_forward!) : null,
          lateralRms: framed && ar != null ? a.projectedRms(_lateral!) : null,
          verticalRms: framed && ar != null ? a.projectedRms(_up!) : null,
          verticalMeanRate: vr,
        ),
      );
      cursor = start + duration;
    }
    missing(cursor, end - cursor);
    return List.unmodifiable(result);
  }

  void finish() {
    if (_finished) return;
    _drainGyro();
    _pendingGyro.clear();
    if (calibrate && _calibratedAt == null && _failure == null) {
      _failure = '紀錄已結束，未完成方向校正；下次請等待校正完成。';
    }
    _finished = true;
  }

  Map<String, dynamic> summary() {
    final points = bins;
    return {
      'schema': 'gaitlab.motion-analysis.v1',
      'parameters': parameters,
      'calibration_status': calibrationStatus,
      'calibration_reason': calibrationReason,
      'calibrated_at_sensor_us': _calibratedAt,
      'invalidated_at_sensor_us': _invalidatedAt,
      'calibration_axes': _up == null
          ? null
          : {
              'up': _up!.values,
              'forward': _forward!.values,
              'lateral': _lateral!.values,
            },
      'rejected_accel_samples': _rejectedAcc,
      'rejected_gyro_samples': _rejectedGyro,
      'state_seconds': {
        for (final s in MotionState.values)
          s.name: points
              .where((b) => b.state == s)
              .fold<double>(0, (t, b) => t + b.durationSeconds),
      },
      'bins': points.map((b) => b.toJson()).toList(),
      'limitations': 'Exploratory signal states, not walking/running labels. Fixed phone mounting assumed. No force, displacement, pelvis angle, fatigue or symmetry estimate. Cross-sensor alignment is approximate. Yaw-only belt slip is undetectable. Independent human validation NOT RUN.',
    };
  }
}

/// Reject initial cached events while preserving each stream's native clock.
class SessionStartGate {
  SessionStartGate({
    required this.startedAtUs,
    this.previousAccelerationTimestampUs,
    this.previousGyroscopeTimestampUs,
  }) : lastAccelerationTimestampUs = previousAccelerationTimestampUs,
       lastGyroscopeTimestampUs = previousGyroscopeTimestampUs;
  final int startedAtUs;
  final int? previousAccelerationTimestampUs, previousGyroscopeTimestampUs;
  int? lastAccelerationTimestampUs, lastGyroscopeTimestampUs;
  static const toleranceUs = 100000;
  bool _accelerationReady = false, _gyroscopeReady = false;
  final List<int> _staleAcceleration = [], _staleGyroscope = [];
  int get rejectedAccelerationSamples => _staleAcceleration.length;
  bool accept(int timestampUs, {bool gyroscope = false}) {
    final ready = gyroscope ? _gyroscopeReady : _accelerationReady;
    final watermark = gyroscope
        ? previousGyroscopeTimestampUs
        : previousAccelerationTimestampUs;
    final stale = watermark != null
        ? timestampUs <= watermark
        : timestampUs < startedAtUs - toleranceUs;
    if (!ready && stale) {
      (gyroscope ? _staleGyroscope : _staleAcceleration).add(timestampUs);
      return false;
    }
    if (gyroscope) {
      _gyroscopeReady = true;
      lastGyroscopeTimestampUs = math.max(
        lastGyroscopeTimestampUs ?? timestampUs,
        timestampUs,
      );
    } else {
      _accelerationReady = true;
      lastAccelerationTimestampUs = math.max(
        lastAccelerationTimestampUs ?? timestampUs,
        timestampUs,
      );
    }
    return true;
  }

  Map<String, dynamic> summary() => {
    'policy': 'native_previous_session_watermark_else_initial_epoch_start_minus_tolerance',
    'started_at_epoch_us': startedAtUs,
    'tolerance_us': toleranceUs,
    'previous_accelerometer_timestamp_us': previousAccelerationTimestampUs,
    'previous_gyroscope_timestamp_us': previousGyroscopeTimestampUs,
    'epoch_comparison': 'first_stream_subscription_only_assumes_plugin_epoch_within100ms; later sessions use prior native watermark',
    'stale_accelerometer_timestamps_us': List<int>.of(_staleAcceleration),
    'stale_gyroscope_timestamps_us': List<int>.of(_staleGyroscope),
    'raw_preservation': 'stale_acceleration_has_accepted0_stale_gyro_is_retained_and_listed_here',
  };
}
