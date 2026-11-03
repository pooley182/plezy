import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_file_info.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/audio_channel_limit.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/subtitle_styling_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/sleep_timer_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/sheets/video_settings_sheet.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/player_streams.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';
import '../test_helpers/android_player_noops.dart';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.ru);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    SleepTimerService().cancelTimer();
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  tearDown(() {
    SleepTimerService().cancelTimer();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('keeps audio passthrough out of the in-player sheet', (tester) async {
    // It configures the audio output route, not this playback, and applying it
    // mid-stream bounces the audio renderer and re-decides video tunneling. Settings >
    // Video Playback owns it, alongside Tunneled Playback.
    await _pumpSheet(tester);

    // Positive control: land on the audio block that used to hold the toggle. Without
    // it, findsNothing below would also pass for an unbuilt or off-screen region, which
    // is what a bare scroll-then-assert silently degrades into. scrollUntilVisible
    // throws when the block is missing entirely, so the guard fails loudly instead.
    await tester.scrollUntilVisible(find.text('Normalize Loudness'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Audio Channels'), findsOneWidget);

    expect(find.text('Audio Passthrough'), findsNothing);
  });

  testWidgets('localizes Off, Normal, and Active video setting values', (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.ru);

    await _pumpSheet(tester, canControl: true);
    expect(find.text('Обычная'), findsOneWidget);
    expect(find.text('Выкл.'), findsOneWidget);

    final sleepTimer = SleepTimerService();
    sleepTimer.startTimer(const Duration(hours: 1));
    try {
      await tester.pump();
      expect(find.textContaining('Активен ('), findsOneWidget);
    } finally {
      sleepTimer.cancelTimer();
    }
  });

  testWidgets('offers requested playback speeds through 8x and persists the selection', (tester) async {
    final appliedRates = <double>[];
    final player = _FakeSettingsPlayer(
      onSetRate: (rate) async {
        appliedRates.add(rate);
      },
    );
    await _pumpSheetViaOverlayRoute(tester, player);

    await tester.tap(find.text('Playback Speed'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).last;
    for (final label in ['3.5x', '4x', '4.5x', '5x', '6x', '7x', '8x']) {
      await tester.scrollUntilVisible(find.text(label), 200, scrollable: scrollable);
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('8x'));
    await tester.pumpAndSettle();

    expect(appliedRates, [8.0]);
    expect(SettingsService.instance.read(SettingsService.defaultPlaybackSpeed), 8.0);
  });

  testWidgets('applies a picked audio channel limit to the player and stores it', (tester) async {
    await SettingsService.instance.write(SettingsService.downmixCenterBoost, 4);
    await SettingsService.instance.write(SettingsService.audioDownmixNormalize, false);
    final applied = <(AudioChannelLimit, int, bool)>[];
    final player = _FakeSettingsPlayer(
      onSetAudioChannelLimit: (limit, centerBoostDb, normalize) async {
        applied.add((limit, centerBoostDb, normalize));
      },
    );
    await _pumpSheetViaOverlayRoute(tester, player);

    await tester.scrollUntilVisible(find.text('Audio Channels'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Audio Channels'));
    await tester.pumpAndSettle();
    for (final label in ['Original', 'Up to 5.1', 'Stereo']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(_tickOn('Original'), findsOneWidget);

    await tester.tap(find.text('Up to 5.1'));
    await tester.pumpAndSettle();

    expect(applied, [(AudioChannelLimit.surround51, 4, false)]);
    expect(SettingsService.instance.read(SettingsService.audioChannelLimit), AudioChannelLimit.surround51);
    expect(find.byType(VideoSettingsSheet), findsNothing);
  });

  // #2744: the pick has to outlive this player, or every new video starts back
  // on "Autoselect device". The Audio Output row is a TV control.
  testWidgets('remembers a picked audio output for later players', (tester) async {
    TvDetectionService.debugSetTvOverride(true);
    addTearDown(() => TvDetectionService.debugSetTvOverride(null));
    final applied = <String>[];
    final player = _FakeSettingsPlayer(
      state: const PlayerState(
        audioDevices: [
          AudioDevice(name: 'auto', description: 'Autoselect device'),
          AudioDevice(name: 'alsa', description: 'Default (alsa)'),
        ],
      ),
      onSetAudioDevice: (device) async => applied.add(device.name),
    );
    await _pumpSheetViaOverlayRoute(tester, player);

    await tester.scrollUntilVisible(find.text('Audio Output'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Audio Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default (alsa)'));
    await tester.pumpAndSettle();

    expect(applied, ['alsa']);
    expect(SettingsService.instance.read(SettingsService.audioOutputDevice), 'alsa');
    expect(find.byType(VideoSettingsSheet), findsNothing);
  });

  testWidgets('keeps the remembered audio output when the player refuses the pick', (tester) async {
    TvDetectionService.debugSetTvOverride(true);
    addTearDown(() => TvDetectionService.debugSetTvOverride(null));
    await SettingsService.instance.write(SettingsService.audioOutputDevice, 'pipewire');
    final player = _FakeSettingsPlayer(
      state: const PlayerState(
        audioDevices: [AudioDevice(name: 'alsa', description: 'Default (alsa)')],
      ),
      onSetAudioDevice: (_) async => throw StateError('rejected'),
    );
    await _pumpSheetViaOverlayRoute(tester, player);

    await tester.scrollUntilVisible(find.text('Audio Output'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Audio Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default (alsa)'));
    await tester.pumpAndSettle();

    expect(SettingsService.instance.read(SettingsService.audioOutputDevice), 'pipewire');
  });

  testWidgets('localizes every ASS subtitle override enum label', (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.ru);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokensAnimated]),
        home: const SubtitleStylingScreen(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Переопределение ASS'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    for (final label in ['Нет', 'Да', 'Масштаб', 'Принудительно', 'Удалить стили']) {
      expect(find.descendant(of: dialog, matching: find.text(label)), findsOneWidget);
    }
  });

  // The switch springing back on its own reads as a lost tap. This message is
  // what tells the user the surface itself cannot carry HDR and no retry will
  // change that, so it has to survive any rework of the write path.

  testWidgets('hides the HDR controls when the host declares the surface cannot carry HDR', (tester) async {
    await _pumpSheet(tester);

    // Scroll past where the HDR rows would sit. Without a following anchor the
    // absence would also be satisfied by the ListView simply not having built
    // that far yet, which is not the contract under test.
    await tester.scrollUntilVisible(find.text('Auto-Play Next'), 500, scrollable: find.byType(Scrollable).first);

    expect(find.text('HDR'), findsNothing);
    expect(find.text('HDR Tone Mapping'), findsNothing);
  });

  group('File Info', () {
    testWidgets('opens the playing item as a nested page whose back button returns to the menu', (tester) async {
      final client = _FileInfoClient();
      final item = testMediaItem(title: 'Inception', serverId: client.serverId.value);
      await _pumpFileInfoSheet(tester, client, TrackControlsState(metadata: item, serverId: item.serverId));

      await tester.tap(find.text(t.mediaMenu.fileInfo));
      await tester.pump();
      expect(client.requested, [item]);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      client.response.complete(const MediaFileInfo(versions: [MediaFileVersion(container: 'mkv')]));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Inception'), findsOneWidget);
      expect(find.text('MKV'), findsWidgets);

      await tester.tapAt(tester.getCenter(find.byIcon(Symbols.arrow_back_rounded)));
      await tester.pumpAndSettle();
      expect(find.text('MKV'), findsNothing);
      expect(find.text(t.videoSettings.performanceOverlay), findsOneWidget);
    });

    testWidgets('says so when the server has no file info for the item', (tester) async {
      final client = _FileInfoClient();
      final item = testMediaItem(serverId: client.serverId.value);
      await _pumpFileInfoSheet(tester, client, TrackControlsState(metadata: item, serverId: item.serverId));

      await tester.tap(find.text(t.mediaMenu.fileInfo));
      client.response.complete(null);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(t.messages.fileInfoNotAvailable), findsOneWidget);
    });

    testWidgets('is not offered for live TV, which has no file', (tester) async {
      final client = _FileInfoClient();
      final item = testMediaItem(serverId: client.serverId.value);
      await _pumpFileInfoSheet(
        tester,
        client,
        TrackControlsState(metadata: item, serverId: item.serverId, isLive: true),
      );

      expect(find.text(t.videoSettings.performanceOverlay), findsOneWidget);
      expect(find.text(t.mediaMenu.fileInfo), findsNothing);
    });
  });
}

/// The tick marking the selected option in one of the sheet's picker views.
Finder _tickOn(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)).first,
  matching: find.byIcon(Symbols.check_rounded),
);

/// Opens the settings sheet through a real host, as the player does, with
/// [client] registered for the playing item's server.
Future<void> _pumpFileInfoSheet(WidgetTester tester, _FileInfoClient client, TrackControlsState state) async {
  // Tall enough that the lazy menu builds every row.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final provider = testMultiServerProvider(manager);
  addTearDown(() {
    provider.dispose();
    manager.dispose();
  });

  await tester.pumpWidget(
    ChangeNotifierProvider<MultiServerProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokensAnimated]),
        home: OverlaySheetHost(
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  OverlaySheetController.of(context).show<void>(
                    builder: (_) => VideoSettingsSheet(player: _FakeSettingsPlayer(), trackControlsState: state),
                  ),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open settings'));
  await tester.pumpAndSettle();
}

class _FileInfoClient implements MediaServerClient {
  final response = Completer<MediaFileInfo?>();
  final requested = <MediaItem>[];

  @override
  ServerId get serverId => ServerId('file-info-server');

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) {
    requested.add(item);
    return response.future;
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  bool canControl = false,
  Player? player,
  // Explicitly false by default so the sheet does not consult the platform.
  // Pass null to exercise the capability probe instead.

  // Option views that dismiss themselves on selection reach
  // OverlaySheetController.of(), which asserts without a host above it.
  bool withSheetHost = false,
  // The default is short enough that the ListView is lazy: callers that need a
  // row present without dragging to it pass a taller sheet, which builds all of
  // them.
  double height = 700,
}) async {
  final sheet = SizedBox(
    width: 900,
    height: height,
    child: VideoSettingsSheet(
      player: player ?? _FakeSettingsPlayer(),
      trackControlsState: TrackControlsState(canControl: canControl),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [testMonoTokensAnimated]),
      home: Scaffold(body: withSheetHost ? OverlaySheetHost(child: sheet) : sheet),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSheetViaOverlayRoute(WidgetTester tester, Player player) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [testMonoTokensAnimated]),
      home: OverlaySheetHost(
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                OverlaySheetController.of(context).show<void>(
                  builder: (_) => VideoSettingsSheet(
                    player: player,
                    trackControlsState: const TrackControlsState(canControl: true),
                  ),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open settings'));
  await tester.pumpAndSettle();
}

class _FakeSettingsPlayer with AndroidPlayerNoops implements Player {
  _FakeSettingsPlayer({
    this.onSetRate,
    this.onSetAudioChannelLimit,
    this.onSetAudioDevice,
    this.state = const PlayerState(),
  }) : onSetProperty = null;

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}

  late final PlayerStreams _streams = emptyPlayerStreams();

  final Future<void> Function(String name, String value)? onSetProperty;
  final Future<void> Function(double rate)? onSetRate;
  final Future<void> Function(AudioChannelLimit limit, int centerBoostDb, bool normalize)? onSetAudioChannelLimit;
  final Future<void> Function(AudioDevice device)? onSetAudioDevice;

  @override
  final PlayerState state;

  @override
  PlayerStreams get streams => _streams;

  @override
  String get playerType => 'mpv';

  @override
  Future<void> setAudioPassthrough(bool enabled) async {}

  @override
  Future<void> setProperty(String name, String value) {
    return onSetProperty?.call(name, value) ?? Future<void>.value();
  }

  @override
  Future<void> setRate(double rate) {
    return onSetRate?.call(rate) ?? Future<void>.value();
  }

  @override
  Future<void> setAudioChannelLimit(AudioChannelLimit limit, {required int centerBoostDb, required bool normalize}) {
    return onSetAudioChannelLimit?.call(limit, centerBoostDb, normalize) ?? Future<void>.value();
  }

  @override
  Future<void> setAudioDevice(AudioDevice device) {
    return onSetAudioDevice?.call(device) ?? Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
