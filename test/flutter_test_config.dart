import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/player_base.dart';

/// Android-only fire-and-forget channels the app calls unawaited. Tests that
/// care install their own handler over these.
const _silentChannels = ['com.plezy/theme', 'com.edde746.os_media_controls/methods', 'com.plezy/pip'];

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // In setUp, not here: a file's main() may install its own binding first.
  setUp(() {
    // Screens create a real player before a test swaps its fake in, and that
    // player is never disposed; don't let it gate the next test's player.
    PlayerBase.debugResetNativeOwnership();
    // Never create a binding here: the test binding stubs HttpClient with 400s,
    // which breaks pure-Dart tests that talk to real local sockets.
    final TestDefaultBinaryMessengerBinding binding;
    try {
      binding = TestDefaultBinaryMessengerBinding.instance;
    } catch (_) {
      return;
    }
    final messenger = binding.defaultBinaryMessenger;
    for (final name in _silentChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // TV detection asks the native side first; answer "not a TV" so it never
    // falls through to device_info. Tests opt into TV via debugSetTvOverride.
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.plezy/device'),
      (call) async => call.method == 'getTvDetection' ? <String, Object>{'isTv': false} : null,
    );
  });
  await testMain();
}
