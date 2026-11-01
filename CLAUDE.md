# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a fork of Plezy (a Flutter client for Plex, Jellyfin, and Emby) being cut down to an **Android TV-only** Plex client. Playback uses mpv and ExoPlayer.

**Migration in progress (branch `android-tv-only`).** The iOS, macOS, Windows, Linux, and tvOS platform folders and their CI/packaging are gone, but `lib/` still has iOS/desktop/phone code paths (`Platform.isIOS`, `isAppleTV`, `isDesktopOS`, `isMobile`, …) and `pubspec.yaml` still lists desktop/Apple-only dependencies. Treat any such branch as dead code to fold into the Android TV path, not as something to keep working. Planned order: desktop/Apple deps and Dart branches → phone/tablet code (the app always runs as a TV) → Jellyfin/Emby removal.

## Commands

```bash
flutter pub get
scripts/codegen.sh                 # all codegen: data tables, relay protocol, slang, build_runner
scripts/codegen.sh --check         # fails if generated files are stale (CI runs this)
dart run slang                     # translations only, after editing lib/i18n/*.i18n.json

scripts/run_tests.sh                               # flutter test with -j = core count
scripts/run_tests.sh test/widgets/some_test.dart   # one file (args forwarded to flutter test)
scripts/run_tests.sh test/foo_test.dart --name 'pattern'  # one test

scripts/ci_checks.sh               # full local CI gate (same as the pre-commit hook)
scripts/setup_hooks.sh             # install pre-commit hook (bypass: SKIP_HOOKS=1)
dart format .                      # page width 120
scripts/format_native.sh --fix     # Kotlin, C/C++
dart run scripts/checks/check_analyzer.dart   # analyzer as CI runs it (flutter analyze locally)

(cd server && go test ./...)       # Go relay server; full CI: scripts/ci_server_checks.sh
python3 scripts/maestro/run_maestro.py basic   # Android E2E (emulator + Dockerized Jellyfin)
```

## What `scripts/ci_checks.sh` enforces

Beyond format/analyze/codegen freshness, these custom checks commonly fail new code:

- **No hardcoded UI strings** (`scripts/checks/check_hardcoded_strings.py`): user-facing text goes through slang (`t.section.key`), added to `lib/i18n/en.i18n.json` (base locale; others fall back to English).
- **Translation hygiene** (`clean_translations.py --check --strict`): no unused keys; locale files normalized.
- **No raw exception text in user-facing messages** (`check_user_facing_errors.py`), e.g. snackbars.
- **Icons** (`check_icon_consistency.dart`): production icons use `AppIcon` and rounded Material Symbols.
- **No unused code or files** (`dart_code_linter check-unused-code/-files lib`): delete what you stop using.
- Lints of note: `unawaited_futures`, `prefer_final_locals`, `avoid_print` (use `appLogger`).

Generated files (`*.g.dart`, `*.freezed.dart`, `lib/i18n/strings*.g.dart`, most of `lib/data/`) are committed; regenerate rather than hand-edit. Freezed/json_serializable models are configured in `build.yaml`.

## Architecture

- **Backend-neutral media layer** (`lib/media/`): `MediaServerClient` is the interface the UI and providers use; neutral types (`MediaItem`, `MediaLibrary`, `MediaHub`, …) carry a `MediaBackend` discriminator. Concrete clients are `PlexClient` (`lib/services/plex_client*`) and `JellyfinClient` (`lib/services/jellyfin_client*`), which also serves Emby via `MediaBrowserDialect`. Backend-specific features (DVR, match, metadata edit) live on concrete clients, not the interface; capability flags are in `server_capabilities.dart`.
- **Connections and servers**: `ConnectionRegistry` (`lib/connection/`) persists user-added accounts/servers in the Drift DB; `MultiServerManager` builds and owns live per-server clients from those records and handles endpoint racing/relays. `MultiServerProvider` exposes it to the UI.
- **Profiles** (`lib/profiles/`): app-level profiles (including Plex Home users) scope connections, downloads, watch state, and settings. `ActiveProfileProvider`/`ActiveProfileBinder` drive re-binding when the profile changes; many providers in `lib/main.dart` are `ProxyProvider`s on the active profile.
- **State**: `provider` package. The full dependency graph is assembled in the `MultiProvider` in `lib/main.dart`; start there to see what depends on what.
- **Persistence**: Drift DB in `lib/database/` (`tables.dart`, `app_database.dart`; bump `schemaVersion` and add a migration step when changing tables). `SettingsService` and friends wrap SharedPreferences; secrets go through `credential_vault.dart`/`sensitive_prefs.dart`.
- **Playback**: `lib/mpv/player/player.dart` is the abstract `Player`; the Android impl is `platform/player_android.dart` (the Linux/Windows/Apple impls are pending removal). Native code lives in `android/app/src/main/kotlin/com/edde746/plezy/{mpv,exoplayer}`. libmpv comes from the pinned `mpv-build` pipeline (`mpv-build.lock.json`). Playback orchestration (source resolution, track selection, progress reporting) is in `lib/services/playback_*.dart`.
- **Focus/TV input** (`lib/focus/`): D-pad, keyboard, and gamepad navigation is custom; new interactive widgets should use the focusable mixins/wrappers there so they work on TV.
- **Watch Together** (`lib/watch_together/`) talks to the Go relay in `server/`; the wire protocol is defined once in `relay_protocol.json` and generated into both Dart and `server/relay_protocol_gen.go` by `scripts/codegen/generate_relay_protocol.py`.
- **Agent controls**: debug/profile builds run with `--dart-define=PLEZY_AGENT_CONTROL=true` expose a VM-service extension driven by `bun scripts/agent.mjs` (settings, media lookup, playback). See CONTRIBUTING.md "Agent controls".
- **Vendored/forked deps**: `packages/` holds patched plugins, and several git deps in `pubspec.yaml` are pinned forks with comments explaining each fix. Read those comments before upgrading.
- `website/` is upstream's SvelteKit site (bun); `scripts/release/deploy.py` is upstream's store-release pipeline tied to its accounts.

## Conventions

- Commits use Conventional Commits with scopes, e.g. `fix(player): …`, `fix(ui): …`, `build: …`.
- AI-assisted PRs must state the model(s) used in the PR description.
- Container images in `server/` are pinned by multi-platform index digest; never switch to a mutable tag (process in CONTRIBUTING.md).
