import 'package:plezy/mpv/mpv.dart';

/// No-op answers for the display, surface, and audio-focus calls the player
/// screen makes on Android, so `noSuchMethod` fakes need not stub each one.
/// A fake's own overrides still win.
mixin AndroidPlayerNoops implements Player {
  @override
  Future<bool> setVisible(bool visible, {bool restoreOnWindowVisible = false}) async => true;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<bool> setVideoFrameRate(
    double fps,
    int durationMs, {
    int extraDelayMs = 0,
    int videoWidth = 0,
    int videoHeight = 0,
    bool matchResolution = false,
  }) async => false;

  @override
  Future<void> clearVideoFrameRate() async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> abandonAudioFocus() async {}
}
