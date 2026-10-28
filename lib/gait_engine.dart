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
