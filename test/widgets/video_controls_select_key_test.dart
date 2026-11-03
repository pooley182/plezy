import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/keyboard_shortcuts_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/skip_marker_button.dart';
import 'package:plezy/focus/dpad_navigator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';
import '../test_helpers/android_player_noops.dart';

/// Pressing Enter on the player surface used to raise the chrome *and* drop
/// focus onto Play/Pause, while the global input-mode tracker separately
/// switched the whole app into keyboard mode — even with "Video Player
/// Navigation" off. Enter activates whatever already has focus; it is not a
/// request to start navigating, so it must leave focus where the viewer left it
/// while still doing its job. Tab and a remote's OK remain the deliberate ways
/// into the OSD.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TogglePlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late ValueNotifier<bool> hasFirstFrame;
  late SettingsService settings;
  late FocusNode screenFocusNode;
  var toggles = 0;

  /// What the player screen would have done with each Back that escaped the
  /// controls. The harness cannot run the real staged chain, so it records the
  /// disposition the screen would have resolved: an empty list means the
  /// controls answered the press themselves.
  final screenBackDispositions = <PlayerBackDisposition>[];

  /// Back key-downs that reached the screen node. A stage that claims the press
  /// consumes the down as well as the up, so this separates "the controls
  /// declined the press" from "a later guard handed it back".
  var screenBackKeyDowns = 0;

  Future<void> setNavigationEnabled(bool value) => settings.write(SettingsService.videoPlayerNavigationEnabled, value);

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    // The shortcuts singleton binds to whichever SettingsService exists when it
    // is first created; a fresh one per test makes binding writes reach it.
    final shortcuts = await KeyboardShortcutsService.getInstance();
    addTearDown(shortcuts.dispose);

    // Desktop with a pointer: the configuration the report came from.
    TvDetectionService.debugSetTvOverride(false);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _TogglePlayer();
    chrome = PlayerChromeController(initiallyVisible: false);
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    hasFirstFrame = ValueNotifier<bool>(true);
    screenFocusNode = FocusNode(debugLabel: 'VideoPlayerScreen');
    toggles = 0;
    screenBackDispositions.clear();
    screenBackKeyDowns = 0;
  });

  tearDown(() async {
    TvDetectionService.debugSetTvOverride(null);
    TvDetectionService.setForceTVSync(false);
    hasFirstFrame.dispose();
    screenFocusNode.dispose();
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await player.close();
    await database.close();
  });

  /// Mirrors the production tree: the screen-level node autofocuses during the
  /// loading phase and already holds the remote by the time the controls mount,
  /// so the controls' own `autofocus` cannot win it back. Without that, the
  /// surface would take focus by default and the startup claim would look
  /// correct even when it is not.
  Widget shell(Widget child, {TargetPlatform platform = TargetPlatform.windows}) => InputModeTracker(
    child: MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: database),
        ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
        ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: platform, extensions: const [testMonoTokens]),
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child: Focus(
              focusNode: screenFocusNode,
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent && event.logicalKey.isBackKey) screenBackKeyDowns++;
                if (event is KeyUpEvent && event.logicalKey.isBackKey) {
                  screenBackDispositions.add(
                    resolvePlayerBackDisposition(
                      navigationKey: classifyPlayerNavigationKey(event),
                      contentStripVisible: chrome.contentStripVisible,
                      controlsVisible: chrome.controlsVisible,
                    ),
                  );
                }
                return KeyEventResult.ignored;
              },
              child: child,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPlayer(
    WidgetTester tester, {
    List<MediaMarker>? markers,
    TargetPlatform platform = TargetPlatform.windows,
    bool canControl = true,
    bool playbackPromptOpen = false,
  }) async {
    await tester.pumpWidget(shell(const SizedBox.expand(), platform: platform));
    await tester.pump();
    expect(screenFocusNode.hasPrimaryFocus, isTrue, reason: 'precondition: the screen node owns the remote');

    await tester.pumpWidget(
      shell(
        platform: platform,
        PlexVideoControls(
          player: player,
          volumeController: volume,
          metadata: testMediaItem(id: 'select-key'),
          initialMarkers: markers,
          toastController: toast,
          chromeController: chrome,
          hasFirstFrame: hasFirstFrame,
          canNavigateMediaItems: false,
          canControl: canControl,
          playbackPromptOpen: playbackPromptOpen,
          onPlayPauseRequested: (_) async => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(key);
    await tester.pump();
    await tester.sendKeyUpEvent(key);
    await tester.pumpAndSettle();
  }

  String? focusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  /// Mounts the player, runs [body], then unmounts and disarms the auto-hide
  /// timer so the harness's pending-timer check stays honest.
  void playerTest(
    String description,
    Future<void> Function(WidgetTester tester) body, {
    List<MediaMarker>? markers,
    TargetPlatform platform = TargetPlatform.windows,
    bool canControl = true,
    bool playbackPromptOpen = false,
  }) {
    testWidgets(description, (tester) async {
      await pumpPlayer(
        tester,
        markers: markers,
        platform: platform,
        canControl: canControl,
        playbackPromptOpen: playbackPromptOpen,
      );
      await body(tester);
      chrome.cancelAutoHide();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  playerTest('hiding in the frame gap after show cannot strand controlsPresented', (tester) async {
    chrome.show(restartAutoHide: false);
    // One pump: the subtree mounts at opacity 0 and the post-frame callback
    // flips the fade-in target on — but the fade-in build has not run yet.
    await tester.pump();

    // A pointer exit landing in that gap must not trust an opaque flag the
    // renderer never realized: hide() retires presentation immediately, and
    // the never-started fade-in cannot strand the flag behind a fade-out
    // whose onEnd will never fire.
    expect(chrome.hide(), isTrue);
    await tester.pump();

    expect(chrome.controlsVisible, isFalse);
    expect(chrome.controlsPresented, isFalse, reason: 'back must resolve to the route pop, not hide-the-chrome');
  });

  group('startup on a television', () {
    setUp(() async {
      TvDetectionService.debugSetTvOverride(true);
      await setNavigationEnabled(true);
    });

    // A TV route opens with the chrome down, navigation on and keyboard mode
    // already active — the exact combination that used to skip the claim.
    playerTest('the surface owns the remote even though the chrome starts down', (tester) async {
      expect(chrome.controlsVisible, isFalse);
      expect(focusLabel(), 'PlayerSurface');
    });
  });

  // Android TV is the platform the report came from, and it is materially
  // different: the marker autofocuses the button, so the key is dispatched
  // from the button's node upward rather than from the surface. The forced-TV
  // override is the only way to get a non-Apple TV, since the Apple override
  // sets both isTV and isAppleTV.
  group('declining a skip prompt on Android TV', () {
    setUp(() async {
      TvDetectionService.debugSetTvOverride(null);
      await TvDetectionService.getInstance(forceTv: true);
      TvDetectionService.setForceTVSync(true);
      await setNavigationEnabled(true);
    });

    playerTest(
      'Back declines the focused prompt and hands the remote back',
      markers: [MediaMarker(id: 1, type: 'intro', startTimeOffset: 10000, endTimeOffset: 45000)],
      (tester) async {
        InputModeTracker.reportNonPointerInput();
        player.emitPosition(const Duration(seconds: 15));
        await tester.pumpAndSettle();
        expect(focusLabel(), 'SkipMarkerButton', reason: 'precondition: TV autofocuses the sole affordance');

        await press(tester, LogicalKeyboardKey.gameButtonB);

        expect(find.byType(SkipMarkerButton), findsNothing);
        expect(player.state.position, const Duration(seconds: 15), reason: 'declining must not skip');
        expect(focusLabel(), 'PlayerSurface', reason: 'the vanished button must hand the remote back');
        expect(screenBackKeyDowns, 0, reason: 'the prompt answered the press');
        expect(screenBackDispositions, isEmpty);
      },
    );
  });

  group('skip intro on a television', () {
    setUp(() async {
      TvDetectionService.debugSetTvOverride(true);
      await setNavigationEnabled(true);
    });

    // Selecting Skip Intro removes the focused button from the tree. The
    // remote must land back on the player surface — otherwise focus falls out
    // of the controls subtree, the screen node reclaims it, and its self-heal
    // turns the next Select into a chrome-raise, so pausing takes two presses
    // (#1890).
    playerTest(
      'Select toggles playback on the first press after skipping the intro',
      markers: [MediaMarker(id: 1, type: 'intro', startTimeOffset: 10000, endTimeOffset: 45000)],
      (tester) async {
        // A remote is non-pointer input, so the app is already in keyboard
        // mode when the marker appears — the combination that autofocuses the
        // skip button on TV.
        InputModeTracker.reportNonPointerInput();
        player.emitPosition(const Duration(seconds: 15));
        await tester.pumpAndSettle();
        expect(focusLabel(), 'SkipMarkerButton', reason: 'precondition: TV autofocuses the sole affordance');

        await press(tester, LogicalKeyboardKey.select);

        expect(player.state.position, const Duration(seconds: 45), reason: 'Select activated the skip');
        expect(focusLabel(), 'PlayerSurface', reason: 'the vanished button must hand the remote back');

        await press(tester, LogicalKeyboardKey.select);

        expect(toggles, 1, reason: 'one press must toggle playback, not merely raise the chrome');
      },
    );
  });
}

/// Minimal [Player] reporting steady playback; transport is routed to the
/// widget's `onPlayPauseRequested` callback so the test can count toggles.
class _TogglePlayer with AndroidPlayerNoops implements Player {
  Duration _position = const Duration(minutes: 5);
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();

  /// Moves the playhead and announces it on the position stream, the way a
  /// real player drives marker detection.
  void emitPosition(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  Future<void> close() => _positionController.close();

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state =>
      PlayerState(playing: true, position: _position, duration: const Duration(minutes: 45), seekable: true);

  /// A real player announces the new playhead right after a seek; marker
  /// detection (and its focus handling) rides on that event.
  @override
  Future<void> seek(Duration position) async => emitPosition(position);

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
