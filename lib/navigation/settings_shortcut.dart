import 'package:flutter/material.dart';

import '../screens/settings/settings_screen.dart';

/// Route name of a pushed [SettingsScreen].
const String kSettingsRouteName = '/settings';

/// The route every settings push site uses, so a pushed settings screen is
/// identifiable by [kSettingsRouteName].
MaterialPageRoute<void> buildSettingsRoute() {
  return MaterialPageRoute<void>(
    settings: const RouteSettings(name: kSettingsRouteName),
    builder: (_) => const SettingsScreen(),
  );
}
