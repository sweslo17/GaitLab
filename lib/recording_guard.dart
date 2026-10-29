import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class RecordingGuardResult {
  const RecordingGuardResult({
    required this.backgroundSupported,
    required this.notificationsAllowed,
  });
  final bool backgroundSupported;
  final bool notificationsAllowed;
}

/// Android keeps the CPU awake, not the display. Other platforms stay foreground-only.
class RecordingSessionGuard {
  RecordingSessionGuard({
    bool? isAndroid,
    MethodChannel? channel,
    this.onStopRequested,
  }) : supportsBackground = isAndroid ?? Platform.isAndroid,
       _channel = channel ?? const MethodChannel('gaitlab/recording') {
    if (supportsBackground) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stopRequested') {
          onStopRequested?.call();
          return null;
        }
        throw MissingPluginException('Unknown recording callback');
      });
    }
  }
  final bool supportsBackground;
  final MethodChannel _channel;
  final VoidCallback? onStopRequested;
  void detach() {
    if (supportsBackground) _channel.setMethodCallHandler(null);
  }

  bool _active = false;
  int _generation = 0;
  Future<RecordingGuardResult>? _pending;
  RecordingGuardResult? _lastResult;
  bool get active => _active;

  Future<RecordingGuardResult> start() {
    if (!supportsBackground) {
      return Future.value(
        const RecordingGuardResult(
          backgroundSupported: false,
          notificationsAllowed: true,
        ),
      );
    }
    if (_active) return Future.value(_lastResult!);
    return _pending ??= _startNative().whenComplete(() => _pending = null);
  }

  Future<RecordingGuardResult> _startNative() async {
    final generation = _generation;
    try {
      // Native allows time to read the notification permission dialog, then
      // separately bounds service promotion. Cancellation also stops late starts.
      final result = await _channel
          .invokeMapMethod<String, dynamic>('start')
          .timeout(const Duration(seconds: 75));
      if (generation != _generation || result?['active'] != true) {
        throw StateError('Android recording service did not become active');
      }
      _lastResult = RecordingGuardResult(
        backgroundSupported: true,
        notificationsAllowed: result?['notifications_allowed'] == true,
      );
      _active = true;
      return _lastResult!;
    } catch (_) {
      _active = false;
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {
        /* Preserve startup failure. */
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!supportsBackground || (!_active && _pending == null)) return;
    _generation++;
    await _channel.invokeMethod<void>('stop');
    _active = false;
  }
}

bool shouldStopRecordingForLifecycle(
  AppLifecycleState state, {
  required bool backgroundActive,
}) =>
    state == AppLifecycleState.detached ||
    (!backgroundActive &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused));
