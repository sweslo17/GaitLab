import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';

void main() {
  test(
    'resubscribe uses prior native watermarks after a wall clock change',
    () {
      final gate = SessionStartGate(
        startedAtUs: 210000000,
        previousAccelerationTimestampUs: 200000000,
        previousGyroscopeTimestampUs: 199999000,
      );
      expect(gate.accept(200000000), isFalse);
      expect(gate.accept(200010000), isTrue);
      expect(gate.accept(199999000, gyroscope: true), isFalse);
      expect(gate.accept(200009000, gyroscope: true), isTrue);
      expect(gate.lastAccelerationTimestampUs, 200010000);
      expect(gate.lastGyroscopeTimestampUs, 200009000);
    },
  );

  test(
    'cached events before recording do not anchor a new session timeline',
    () {
      final gate = SessionStartGate(startedAtUs: 200000000);
      final engine = GaitEngine(), metrics = SessionMetrics();
      for (final t in [32000000, 200010000, 200020000]) {
        if (!gate.accept(t)) continue;
        final sample = engine.process(timestampUs: t, ax: 0, ay: 9.81, az: 0);
        metrics.observe(timestampUs: t, engine: engine, sample: sample);
      }
      metrics.finish();
      expect(metrics.summary()['sensor_duration_s'], .01);
      expect(engine.acceptedSamples, 2);
      expect(gate.rejectedAccelerationSamples, 1);
      expect(gate.summary()['stale_accelerometer_timestamps_us'], [32000000]);
    },
  );
  test('independent streams each reject startup cache and accept a small clock offset', () {
    final gate = SessionStartGate(startedAtUs: 200000000);
    expect(gate.accept(199950000), isTrue);
    expect(gate.accept(100000000, gyroscope: true), isFalse);
    expect(gate.accept(200010000, gyroscope: true), isTrue);
    expect(gate.summary()['stale_gyroscope_timestamps_us'], [100000000]);
    expect(gate.summary()['tolerance_us'], 100000);
  });
  test('epoch comparison applies only during startup; later ordering remains engine-owned', () {
    final gate = SessionStartGate(startedAtUs: 200000000);
    expect(gate.accept(200010000), isTrue);
    expect(gate.accept(199000000), isTrue);
    expect(gate.rejectedAccelerationSamples, 0);
  });
}
