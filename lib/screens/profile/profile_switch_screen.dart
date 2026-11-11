import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/mounted_set_state_mixin.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_activation.dart';
import '../../profiles/profile_avatar.dart';
import '../../profiles/profile_connection.dart';
import '../../profiles/profile_merge.dart';
import '../../services/app_exit_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/initials_palette.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focusable_popup_menu_button.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/profile_switching_overlay.dart';
import '../../widgets/deep_link_dialog.dart';
import '../libraries/state_messages.dart';
import 'add_local_profile_screen.dart';
import 'pin_entry_dialog.dart';
import 'profile_teardown.dart';
import 'profile_detail_screen.dart';

/// TV picker showing every [Profile] in the system (Plex Home users
/// auto-surfaced from connected accounts, plus user-created locals) as a row
/// of cards, followed by an Add card.
///
/// Each card shows avatar, name, a check badge on the current profile, and
/// the connections bound to the profile (parent Plex account + any borrowed
/// connections for Plex Home users).
class ProfileSwitchScreen extends StatefulWidget {
  final bool requireSelection;

  const ProfileSwitchScreen({super.key, this.requireSelection = false});

  @override
  State<ProfileSwitchScreen> createState() => _ProfileSwitchScreenState();
}

class _ProfileSwitchScreenState extends State<ProfileSwitchScreen> with MountedSetStateMixin {
  bool _allowPop = false;
  final Map<String, FocusNode> _profileFocusNodes = {};
  final Map<String, FocusNode> _profileMenuFocusNodes = {};
  final Map<String, GlobalKey<AppMenuButtonState<_TileAction>>> _profileMenuKeys = {};
  bool _switching = false;

  @override
  void dispose() {
    for (final node in _profileFocusNodes.values) {
      node.dispose();
    }
    for (final node in _profileMenuFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch the whole provider: with the view stream gone it is this
    // screen's only rebuild source, so the old stream+select double-rebuild
    // concern no longer applies.
    final activeProvider = context.watch<ActiveProfileProvider>();
    // Gate on initialization: rendering the not-yet-loaded profile list as
    // real data flashes the "No profiles available" error state on open.
    final loading = !activeProvider.isInitialized;
    final profiles = activeProvider.profiles;
    _pruneProfileFocusResources(profiles.map((p) => p.id).toSet());
    final activeId = activeProvider.activeId;
    return PopScope(
      canPop: !widget.requireSelection || _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.requireSelection) {
          unawaited(AppExitService.requestExit());
        }
      },
      child: Stack(
        children: [
          FocusedScrollScaffold(
            title: Text(t.screens.switchProfile),
            automaticallyImplyLeading: !widget.requireSelection,
            onBackPressed: widget.requireSelection ? () => unawaited(AppExitService.requestExit()) : null,
            slivers: [
              if (profiles.isEmpty)
                SliverFillRemaining(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : EmptyStateWidget(
                          message: t.messages.noProfilesAvailable,
                          subtitle: t.messages.contactAdminForProfiles,
                          icon: Symbols.person_off_rounded,
                        ),
                ),
              SliverToBoxAdapter(child: _buildCarousel(activeProvider, activeId)),
            ],
          ),
          if (_switching) const ProfileSwitchingOverlay(),
        ],
      ),
    );
  }

  FocusNode _profileFocusNode(Profile profile) {
    return _profileFocusNodes.putIfAbsent(profile.id, () => FocusNode(debugLabel: 'ProfileTile:${profile.id}'));
  }

  FocusNode _profileMenuFocusNode(Profile profile) {
    return _profileMenuFocusNodes.putIfAbsent(profile.id, () => FocusNode(debugLabel: 'ProfileActions:${profile.id}'));
  }

  GlobalKey<AppMenuButtonState<_TileAction>> _profileMenuKey(Profile profile) {
    return _profileMenuKeys.putIfAbsent(profile.id, () => GlobalKey<AppMenuButtonState<_TileAction>>());
  }

  void _pruneProfileFocusResources(Set<String> activeIds) {
    // Runs during build. Detach the map entries
    // synchronously so tiles never receive a stale node, but defer the
    // actual dispose to after the frame: on TV the pruned tile's node is
    // often the one holding primary focus (the profile just signed out /
    // deleted), and disposing the focused node mid-build wedges the focus
    // system on DPAD-only devices.
    final removed = <FocusNode>[];
    for (final id in _profileFocusNodes.keys.toList()) {
      if (!activeIds.contains(id)) {
        final node = _profileFocusNodes.remove(id);
        if (node != null) removed.add(node);
      }
    }
    for (final id in _profileMenuFocusNodes.keys.toList()) {
      if (!activeIds.contains(id)) {
        final node = _profileMenuFocusNodes.remove(id);
        if (node != null) removed.add(node);
      }
    }
    for (final id in _profileMenuKeys.keys.toList()) {
      if (!activeIds.contains(id)) {
        _profileMenuKeys.remove(id);
      }
    }
    if (removed.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in removed) {
          node.dispose();
        }
      });
    }
  }

  void _openProfileMenu(Profile profile) {
    _profileMenuKeys[profile.id]?.currentState?.showButtonMenu();
  }

  /// One card per profile plus an Add card, in a horizontal row like the
  /// Plex TV user picker. Each card's actions menu sits below it (D-pad down).
  Widget _buildCarousel(ActiveProfileProvider activeProvider, String? activeId) {
    final profiles = activeProvider.profiles;
    // ponytail: a plain Row builds every card; fine for a household of profiles.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(48, 24, 48, 24),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          for (final (index, profile) in profiles.indexed)
            // Keyed so a re-sorted list moves each card with its focus node
            // instead of rebinding nodes by position (#1792).
            Padding(
              key: ValueKey(profile.id),
              padding: const EdgeInsetsDirectional.only(end: _cardGap),
              child: _buildProfileCard(profile, activeProvider, activeId, autofocus: index == 0),
            ),
          _AddProfileCard(onSelect: _switching ? null : _addLocalProfile, autofocus: profiles.isEmpty),
        ],
      ),
    );
  }

  Widget _buildProfileCard(
    Profile profile,
    ActiveProfileProvider activeProvider,
    String? activeId, {
    required bool autofocus,
  }) {
    final isActive = profile.id == activeId && !widget.requireSelection;
    final profileFocusNode = _profileFocusNode(profile);
    final menuFocusNode = _profileMenuFocusNode(profile);
    // All tile actions are disabled while a switch is binding: the overlay's
    // barrier blocks pointers but not DPAD key events, and a Manage/Delete
    // flow racing the in-flight switch corrupts state (e.g. a delete
    // confirmation left open when the switch settles).
    final actionsEnabled = !widget.requireSelection && !_switching;
    // Manage is available for any profile (borrowed connections can be edited
    // on plex_home too); Delete stays local-only (Plex owns Home users).
    final actions = [
      if (actionsEnabled) _TileAction.manage,
      if (actionsEnabled) _TileAction.showLink,
      if (actionsEnabled && profile.isLocal) _TileAction.delete,
      if (actionsEnabled && profile.isPlexHome && profile.parentConnectionId != null) _TileAction.signOut,
    ];
    final hasMenu = actions.isNotEmpty;
    final connections = _chipsFor(profile, activeProvider);

    return Column(
      mainAxisSize: .min,
      children: [
        _ProfileCard(
          profile: profile,
          avatarUrl: activeProvider.avatarUrlFor(profile.id),
          isActive: isActive,
          chips: connections.chips,
          hasConnections: connections.hasConnections,
          focusNode: profileFocusNode,
          autofocus: autofocus,
          onSelect: _switching || isActive ? null : () => _switchTo(profile),
          onLongPress: hasMenu ? () => _openProfileMenu(profile) : null,
          onNavigateDown: hasMenu ? () => menuFocusNode.requestFocus() : null,
        ),
        const SizedBox(height: 8),
        // Fixed slot so cards line up whether or not they have a menu.
        SizedBox(
          height: 48,
          child: hasMenu
              ? FocusablePopupMenuButton<_TileAction>(
                  menuKey: _profileMenuKey(profile),
                  focusNode: menuFocusNode,
                  semanticLabel: t.profiles.manage,
                  onNavigateUp: () => profileFocusNode.requestFocus(),
                  icon: const AppIcon(Symbols.more_horiz_rounded, fill: 1),
                  tooltip: t.profiles.manage,
                  onSelected: (action) => _handleAction(profile, action),
                  itemBuilder: (_) => [for (final action in actions) AppMenuItem(value: action, label: action.label)],
                )
              : null,
        ),
      ],
    );
  }

  void _handleAction(Profile profile, _TileAction action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (action) {
        case _TileAction.manage:
          unawaited(_manageProfile(profile));
        case _TileAction.showLink:
          unawaited(_showProfileLink(profile));
        case _TileAction.delete:
          unawaited(_deleteProfile(profile));
        case _TileAction.signOut:
          unawaited(_signOutPlexAccount(profile));
      }
    });
  }

  /// Gate Manage/Delete on a non-active, PIN-protected local profile behind
  /// its PIN: without this the picker menu bypasses the lock entirely
  /// ([ProfileDetailScreen] exposes rename, PIN removal, and connection
  /// edits). The active profile already proved its PIN at switch time, and
  /// Plex Home profiles keep their server-side PIN flow. Loops on wrong
  /// entries with the same shake-on-error pattern as activation — see
  /// [showPinEntryDialog].
  Future<bool> _verifyPinForProfileAction(Profile profile) async {
    if (!profile.isLocal || !profile.isPinProtected) return true;
    if (profile.id == context.read<ActiveProfileProvider>().activeId) return true;
    String? errorMessage;
    while (true) {
      if (!mounted) return false;
      final pin = await showPinEntryDialog(context, profile.displayName, errorMessage: errorMessage);
      if (!mounted || pin == null) return false;
      if (verifyProfilePin(profile, pin)) return true;
      errorMessage = t.profiles.incorrectPinTryAgain;
    }
  }

  Future<void> _manageProfile(Profile profile) async {
    if (!await _verifyPinForProfileAction(profile)) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileDetailScreen(profile: profile)));
  }

  /// Not behind [_verifyPinForProfileAction]: opening the link still asks
  /// for a protected profile's PIN.
  Future<void> _showProfileLink(Profile profile) => showProfileLinkDialog(context, profile);

  /// Drop the parent Plex account [profile] hangs off — same effect as
  /// "Forget account" elsewhere in Plex apps. The shared teardown flow
  /// removes the account, its virtual Plex Home profiles, and their
  /// borrowed connections, then routes to auth when nothing selectable
  /// remains (#1423).
  Future<void> _signOutPlexAccount(Profile profile) async {
    final parentId = profile.parentConnectionId;
    if (parentId == null) return;
    await confirmAndSignOutPlexAccount(context, accountConnectionId: parentId);
  }

  Future<void> _deleteProfile(Profile profile) async {
    if (!await _verifyPinForProfileAction(profile)) return;
    if (!mounted) return;
    await confirmAndDeleteProfile(
      context,
      profile: profile,
      title: t.profiles.deleteThisProfileTitle,
      message: t.profiles.deleteThisProfileMessage(displayName: profile.displayName),
    );
  }

  /// The chips under [profile]'s name. `hasConnections` is false only when the
  /// profile reaches no connection at all; `chips` can be empty without it
  /// when the only chip would repeat the tile's own name.
  ({List<_ChipData> chips, bool hasConnections}) _chipsFor(Profile profile, ActiveProfileProvider activeProvider) {
    final chips = <_ChipData>[];
    var hasConnections = false;
    // With a single Plex account on the device, naming it under every tile
    // tells no two profiles apart and reads as if each were that account's
    // owner (#2590).
    final namesAccount = activeProvider.connectionsById.values.whereType<PlexAccountConnection>().length > 1;
    // Plex Home profiles implicitly own their parent Plex connection (no
    // join-table row), so prepend it before any borrowed connections. The
    // profile *is* the Home user there, so its own name identifies the user
    // half of the label — and without the account half the chip would only
    // repeat the tile's title.
    if (profile.isPlexHome) {
      final parentId = profile.parentConnectionId;
      if (parentId != null) {
        final conn = activeProvider.connectionsById[parentId];
        if (conn != null) {
          hasConnections = true;
          if (namesAccount) chips.add(_chipFor(conn, user: profile.displayName, namesAccount: true));
        }
      }
    }
    final pcs = visibleProfileConnections(
      profile,
      activeProvider.connectionsByProfile[profile.id] ?? const <ProfileConnection>[],
    );
    for (final pc in pcs) {
      final conn = activeProvider.connectionsById[pc.connectionId];
      if (conn == null) continue;
      hasConnections = true;
      chips.add(
        _chipFor(conn, user: _plexHomeUserName(activeProvider, conn, pc.userIdentifier), namesAccount: namesAccount),
      );
    }
    return (chips: chips, hasConnections: hasConnections);
  }

  /// A Plex account connection labels itself with the account owner's name,
  /// which under a profile tile reads as the profile being signed in as that
  /// person — wrong for a Plex Home user, and wrong again for a local profile
  /// that borrowed a Home user out of someone else's account.
  ///
  /// Both halves of that relation go through a single translated string so a
  /// locale can order them itself; several put the account first (`ja`, `ko`,
  /// `tr`, `zh`). [namesAccount] false drops the account half and leaves the
  /// user. [user] is null only when the Home cache cannot resolve the
  /// connection's uuid yet, which falls back to naming the account alone.
  _ChipData _chipFor(Connection conn, {required String? user, required bool namesAccount}) {
    return _ChipData(
      label: switch (conn) {
        PlexAccountConnection() when user != null && !namesAccount => user,
        PlexAccountConnection(:final accountLabel) when user != null => t.profiles.plexAccountUserChip(
          user: user,
          account: accountLabel,
        ),
        PlexAccountConnection(:final accountLabel) => t.profiles.plexAccountChip(account: accountLabel),
        _ => conn.displayLabel,
      },
    );
  }

  /// Home user behind a borrowed Plex connection, or null when the live cache
  /// has no match for [userIdentifier] (not loaded yet, or the row predates
  /// the account's current Home membership).
  String? _plexHomeUserName(ActiveProfileProvider activeProvider, Connection conn, String userIdentifier) {
    if (conn is! PlexAccountConnection || userIdentifier.isEmpty) return null;
    final users = activeProvider.plexHomeByConnectionId[conn.id];
    if (users == null) return null;
    for (final user in users) {
      if (user.uuid == userIdentifier) return user.displayName;
    }
    return null;
  }

  Future<void> _addLocalProfile() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const AddLocalProfileScreen()));
  }

  Future<void> _switchTo(Profile profile) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context, rootNavigator: true);
      final switched = await switchProfileFromUi(context, profile);
      if (!mounted || !switched) return;
      if (widget.requireSelection) {
        setState(() => _allowPop = true);
      }
      // Pop only when this screen is still the top route. A blind
      // `navigator.pop(true)` after the unbounded switch-await pops
      // whatever is topmost — it can dismiss a confirmation dialog WITH
      // `true` (auto-confirming a delete) or close the wrong screen.
      if (route != null && route.isCurrent) {
        navigator.pop(true);
      }
    } finally {
      setStateIfMounted(() => _switching = false);
    }
  }
}

extension _TileActionLabel on _TileAction {
  String get label {
    return switch (this) {
      _TileAction.manage => t.profiles.manage,
      _TileAction.showLink => t.deepLinks.showProfileLink,
      _TileAction.delete => t.profiles.delete,
      _TileAction.signOut => t.profiles.signOut,
    };
  }
}

enum _TileAction { manage, showLink, delete, signOut }

const double _cardWidth = 200;
const double _cardHeight = 260;
const double _cardGap = 32;
const double _cardBandHeight = 76;
final BorderRadius _cardRadius = BorderRadius.circular(8);

/// Shared card chrome: a tinted upper half holding [art] over a darker band
/// holding [label]. Focus scales the card and draws the theme's focus border.
class _CardFrame extends StatelessWidget {
  final Color tint;
  final Widget art;
  final Widget label;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;
  final VoidCallback? onNavigateDown;
  final String? semanticLabel;

  const _CardFrame({
    required this.tint,
    required this.art,
    required this.label,
    this.focusNode,
    this.autofocus = false,
    this.onSelect,
    this.onLongPress,
    this.onNavigateDown,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHigh;
    return FocusableWrapper(
      focusNode: focusNode,
      autofocus: autofocus,
      borderRadii: _cardRadius,
      // FocusableWrapper's auto-scroll is vertical-only; a horizontal row
      // brings the focused card into view itself.
      autoScroll: false,
      onFocusChange: (focused) {
        if (focused) unawaited(Scrollable.ensureVisible(context, alignment: 0.5, duration: _scrollDuration));
      },
      enableLongPress: onLongPress != null,
      onLongPress: onLongPress,
      onNavigateDown: onNavigateDown,
      onSelect: onSelect,
      semanticLabel: semanticLabel,
      child: Material(
        color: Color.alphaBlend(tint.withValues(alpha: 0.3), surface),
        borderRadius: _cardRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          canRequestFocus: false,
          onTap: onSelect,
          onLongPress: onLongPress,
          child: SizedBox(
            width: _cardWidth,
            height: _cardHeight,
            child: Column(
              children: [
                Expanded(child: Center(child: art)),
                Container(
                  height: _cardBandHeight,
                  width: double.infinity,
                  color: Colors.black.withValues(alpha: 0.35),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: .center,
                  child: label,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const Duration _scrollDuration = Duration(milliseconds: 200);

class _ProfileCard extends StatelessWidget {
  final Profile profile;
  final String? avatarUrl;
  final bool isActive;
  final List<_ChipData> chips;

  /// False only when the profile reaches no connection at all, which the card
  /// reports as an error. Otherwise empty [chips] leave the name on its own.
  final bool hasConnections;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;
  final VoidCallback? onNavigateDown;

  const _ProfileCard({
    required this.profile,
    required this.avatarUrl,
    required this.isActive,
    required this.chips,
    required this.hasConnections,
    required this.focusNode,
    required this.autofocus,
    this.onSelect,
    this.onLongPress,
    this.onNavigateDown,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = tokens(context).textMuted;
    final subtitle = !hasConnections
        ? Text(
            t.profiles.noConnections,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.error),
            maxLines: 1,
            overflow: .ellipsis,
          )
        : chips.isNotEmpty
        ? Text(
            chips.map((c) => c.label).join(' · '),
            style: theme.textTheme.labelMedium?.copyWith(color: muted),
            maxLines: 1,
            overflow: .ellipsis,
            textAlign: .center,
          )
        : null;

    return _CardFrame(
      tint: colorForName(profile.displayName, theme),
      focusNode: focusNode,
      autofocus: autofocus,
      onSelect: onSelect,
      onLongPress: onLongPress,
      onNavigateDown: onNavigateDown,
      art: Stack(
        clipBehavior: Clip.none,
        children: [
          _AvatarRing(
            child: ProfileAvatar(profile: profile, size: 128, avatarUrl: avatarUrl),
          ),
          if (isActive)
            Positioned(
              right: 0,
              bottom: 4,
              child: Tooltip(
                message: t.profiles.active,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle),
                  child: AppIcon(Symbols.check_circle_rounded, fill: 1, size: 22, color: theme.colorScheme.primary),
                ),
              ),
            ),
        ],
      ),
      label: Column(
        mainAxisSize: .min,
        children: [
          Text(
            profile.displayName,
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: .ellipsis,
            textAlign: .center,
          ),
          if (subtitle != null) ...[const SizedBox(height: 2), subtitle],
        ],
      ),
    );
  }
}

class _AddProfileCard extends StatelessWidget {
  final VoidCallback? onSelect;
  final bool autofocus;

  const _AddProfileCard({required this.onSelect, required this.autofocus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CardFrame(
      tint: Colors.transparent,
      autofocus: autofocus,
      onSelect: onSelect,
      semanticLabel: t.profiles.addPlezyProfile,
      art: _AvatarRing(
        child: SizedBox.square(
          dimension: 128,
          child: Center(child: AppIcon(Symbols.add_rounded, size: 80, color: theme.colorScheme.primary)),
        ),
      ),
      label: Text(
        t.profiles.addPlezyProfile,
        style: theme.textTheme.titleMedium,
        maxLines: 2,
        overflow: .ellipsis,
        textAlign: .center,
      ),
    );
  }
}

/// The translucent ring Plex draws around each avatar.
class _AvatarRing extends StatelessWidget {
  final Widget child;

  const _AvatarRing({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), shape: BoxShape.circle),
      child: child,
    );
  }
}

class _ChipData {
  final String label;
  const _ChipData({required this.label});
}
