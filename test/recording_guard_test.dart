import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/recording_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gaitlab/test-recording');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'Android only promises screen-off after native service is active',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'start'
            ? {'active': true, 'notifications_allowed': true}
            : null;
      });
      final guard = RecordingSessionGuard(isAndroid: true, channel: channel);
      expect(guard.active, false);
      final result = await guard.start();
      expect(guard.active, true);
      expect(result.notificationsAllowed, true);
      await guard.stop();
      await guard.stop();
      expect(guard.active, false);
      expect(calls, ['start', 'stop']);
    },
  );

  test(
    'failed native promotion cannot silently fall back to background recording',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'start' ? {'active': false} : null;
      });
      final guard = RecordingSessionGuard(isAndroid: true, channel: channel);
      await expectLater(guard.start(), throwsStateError);
      expect(guard.active, false);
      expect(calls, ['start', 'stop']);
    },
  );

  test(
    'notification denial remains explicit while active foreground service runs',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'active': true, 'notifications_allowed': false},
      );
      final guard = RecordingSessionGuard(isAndroid: true, channel: channel);
      expect((await guard.start()).notificationsAllowed, false);
      expect(guard.active, true);
    },
  );

  test('stop during startup rejects a late native success', () async {
    final started = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        started.complete();
        return response.future;
      }
      return null;
    });
    final guard = RecordingSessionGuard(isAndroid: true, channel: channel);
    final start = guard.start();
    await started.future;
    await guard.stop();
    response.complete({'active': true, 'notifications_allowed': true});
    await expectLater(start, throwsStateError);
    expect(guard.active, false);
  });

  test('lifecycle policy preserves Android screen-off but stops unsupported platforms', () {
    for (final state in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
      expect(
        shouldStopRecordingForLifecycle(state, backgroundActive: true),
        false,
      );
      expect(
        shouldStopRecordingForLifecycle(state, backgroundActive: false),
        true,
      );
    }
    expect(
      shouldStopRecordingForLifecycle(
        AppLifecycleState.detached,
        backgroundActive: true,
      ),
      true,
    );
    expect(
      shouldStopRecordingForLifecycle(
        AppLifecycleState.inactive,
        backgroundActive: false,
      ),
      false,
    );
    expect(
      shouldStopRecordingForLifecycle(
        AppLifecycleState.resumed,
        backgroundActive: false,
      ),
      false,
    );
  });

  test('unsupported platforms never call Android native bridge', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw StateError('must not call'),
    );
    final guard = RecordingSessionGuard(isAndroid: false, channel: channel);
    expect((await guard.start()).backgroundSupported, false);
    await guard.stop();
    expect(guard.active, false);
  });
  test(
    'notification stop request reaches the session owner and can detach',
    () async {
      var requests = 0;
      final guard = RecordingSessionGuard(
        isAndroid: true,
        channel: channel,
        onStopRequested: () => requests++,
      );
      final handled = Completer<void>();
      ServicesBinding.instance.channelBuffers.push(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('stopRequested'),
        ),
        (_) => handled.complete(),
      );
      await handled.future;
      expect(requests, 1);
      guard.detach();
    },
  );
}
