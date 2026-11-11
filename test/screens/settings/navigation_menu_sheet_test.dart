import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/navigation_menu_sheet.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/overlay_sheet.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<void> pressKeys(WidgetTester tester, List<LogicalKeyboardKey> keys) async {
    for (final key in keys) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the D-pad reorders and hides items, saving each change', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: OverlaySheetHost(
              child: Scaffold(
                body: Builder(
                  builder: (context) => ElevatedButton(
                    autofocus: true,
                    onPressed: () =>
                        OverlaySheetController.showAdaptive<void>(context, builder: (_) => const NavigationMenuSheet()),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const down = LogicalKeyboardKey.arrowDown;
    const right = LogicalKeyboardKey.arrowRight;
    const select = LogicalKeyboardKey.enter;
    final settings = SettingsService.instance;

    // Keyboard mode, then open the sheet; the cursor starts on Libraries.
    await pressKeys(tester, [down, select]);
    expect(find.text(t.settings.navigationMenu), findsOneWidget);

    // Move Libraries below Live TV.
    await pressKeys(tester, [select, down, select]);
    expect(settings.read(SettingsService.navItemOrderFor(null)), [
      'liveTv',
      'libraries',
      'explore',
      'search',
      'downloads',
    ]);

    // The cursor followed Libraries: its eye hides it.
    await pressKeys(tester, [right, select]);
    expect(settings.read(SettingsService.hiddenNavItemsFor(null)), ['libraries']);
    expect(find.byTooltip(t.settings.showNavItem), findsOneWidget);

    // Explore hides the same way as the rest.
    await pressKeys(tester, [down, select]);
    expect(settings.read(SettingsService.hiddenNavItemsFor(null)), ['libraries', 'explore']);
  });
}
