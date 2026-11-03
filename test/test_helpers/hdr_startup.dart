import 'package:plezy/services/settings_service.dart';

import 'prefs.dart';

/// Shared setup for the one-test-per-file video player startup cases.
///
/// Each lives in its own file with one test, because a second `VideoPlayerScreen`
/// in the same isolate never reaches `initialize`: `PlayerBase` keeps one
/// event-channel owner at a time, and a successor built before the
/// predecessor's release settles inherits that future, so `PlayerBase.invoke`
/// awaits it and returns null on timeout rather than calling.
Future<void> installHdrStartupHarness() async {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  await SettingsService.getInstance();
  // Non-zero so the startup sync-offset write actually happens.
  await SettingsService.instance.write(SettingsService.audioSyncOffset, 250);
}
