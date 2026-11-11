import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../screens/profile/profile_switch_screen.dart';
import '../screens/profile/profile_teardown.dart';
import '../utils/dialogs.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_menu.dart';
import '../widgets/profile_switching_overlay.dart';
import 'active_profile_provider.dart';
import 'profile_activation.dart';
import 'profile_avatar.dart';

const _manageProfiles = 'manage_profiles';
const _logout = 'logout';
const _profilePrefix = 'profile:';

/// The side rail's profile menu: switch to another profile, open the profile
/// picker, or log out.
Future<void> showProfileMenu(BuildContext context) async {
  final activeProvider = context.read<ActiveProfileProvider>();
  final theme = Theme.of(context);
  final switchable = activeProvider.profiles.where((p) => p.id != activeProvider.activeId).toList();

  final value = await showAdaptiveAppMenu<String>(
    context,
    title: activeProvider.active?.displayName,
    focusFirstItem: true,
    entries: [
      for (final p in switchable)
        AppMenuItem<String>(
          value: '$_profilePrefix${p.id}',
          leading: ProfileAvatar(profile: p, size: 24, avatarUrl: activeProvider.avatarUrlFor(p.id)),
          label: p.displayName,
          trailing: p.isPinProtected
              ? AppIcon(Symbols.lock_rounded, fill: 1, size: 14, color: theme.colorScheme.onSurfaceVariant)
              : null,
        ),
      if (switchable.isNotEmpty) const AppMenuDivider(),
      AppMenuItem<String>(value: _manageProfiles, icon: Symbols.group_rounded, label: t.profiles.sectionTitle),
      AppMenuItem<String>(value: _logout, icon: Symbols.logout_rounded, label: t.common.logout),
    ],
  );
  if (value == null || !context.mounted) return;

  switch (value) {
    case _manageProfiles:
      await Navigator.of(
        context,
        rootNavigator: true,
      ).push(MaterialPageRoute<void>(builder: (_) => const ProfileSwitchScreen()));
    case _logout:
      final confirm = await showConfirmDialog(
        context,
        title: t.common.logout,
        message: t.messages.logoutConfirm,
        confirmText: t.common.logout,
        isDestructive: true,
      );
      if (confirm && context.mounted) await logoutAllProfiles(context);
    default:
      final id = value.substring(_profilePrefix.length);
      final target = activeProvider.profiles.where((p) => p.id == id).firstOrNull;
      if (target == null) return;
      // Covers the whole app while the profile rebinds; the switch rebuilds
      // most of the tree, so the overlay lives on the root overlay.
      final overlay = OverlayEntry(builder: (_) => const ProfileSwitchingOverlay());
      Overlay.of(context, rootOverlay: true).insert(overlay);
      try {
        await switchProfileFromUi(context, target);
      } finally {
        overlay.remove();
        overlay.dispose();
      }
  }
}
