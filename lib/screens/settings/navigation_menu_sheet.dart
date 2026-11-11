import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_reorder_mixin.dart';
import '../../focus/focus_theme.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../navigation/navigation_tabs.dart';
import '../../profiles/active_profile_provider.dart';
import '../../services/settings_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_page_scaffold.dart';

/// Reorders and hides the side-rail items between Home and Settings
/// ([customizableNavItems]) for the active profile. Each change is saved as
/// it is made.
class NavigationMenuSheet extends StatefulWidget {
  const NavigationMenuSheet({super.key});

  @override
  State<NavigationMenuSheet> createState() => _NavigationMenuSheetState();
}

class _NavigationMenuSheetState extends State<NavigationMenuSheet>
    with DpadReorderListMixin<NavigationTabId, NavigationMenuSheet> {
  static SettingsService get _settings => SettingsService.instance;

  // Bound to the profile active when the sheet opened.
  late final String? _profileId = context.read<ActiveProfileProvider?>()?.activeId;
  late final StringListPref _orderPref = SettingsService.navItemOrderFor(_profileId);
  late final StringListPref _hiddenPref = SettingsService.hiddenNavItemsFor(_profileId);

  late List<NavigationTabId> _items = resolveNavItemOrder(_settings.read(_orderPref));

  final FocusNode _listFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  // Column 0 = the row (SELECT moves it), column 1 = the visibility button.
  @override
  List<NavigationTabId> get reorderItems => _items;

  @override
  set reorderItems(List<NavigationTabId> value) => _items = value;

  @override
  int get lastReorderColumn => 1;

  @override
  ScrollController? get reorderScrollController => _scrollController;

  @override
  void onReorderMoveConfirmed() => _saveOrder();

  @override
  void onReorderColumnActivated(int column, int index) {
    if (column == 1) unawaited(_toggleHidden(_items[index]));
  }

  @override
  void dispose() {
    _listFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _saveOrder() => unawaited(_settings.write(_orderPref, [for (final id in _items) id.name]));

  /// Pointer drag.
  void _onReorder(int oldIndex, int newIndex) {
    setState(() => _items.insert(newIndex, _items.removeAt(oldIndex)));
    _saveOrder();
  }

  bool _isHidden(NavigationTabId id) => _settings.read(_hiddenPref).contains(id.name);

  Future<void> _toggleHidden(NavigationTabId id) {
    final hidden = Set.of(_settings.read(_hiddenPref));
    if (!hidden.remove(id.name)) hidden.add(id.name);
    return _settings.write(_hiddenPref, hidden.toList());
  }

  @override
  Widget build(BuildContext context) {
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);

    return BottomSheetPageScaffold(
      title: t.settings.navigationMenu,
      icon: Symbols.menu_rounded,
      child: Focus(
        focusNode: _listFocusNode,
        descendantsAreFocusable: false,
        autofocus: isKeyboardMode,
        onKeyEvent: handleReorderKeyEvent,
        child: ListenableBuilder(
          listenable: _settings.listenable(_hiddenPref),
          builder: (context, _) => ReorderableListView.builder(
            shrinkWrap: true,
            scrollController: _scrollController,
            onReorderItem: _onReorder,
            itemCount: _items.length,
            padding: const EdgeInsets.symmetric(vertical: 8),
            buildDefaultDragHandles: false,
            itemBuilder: (context, index) {
              final isFocused = isKeyboardMode && index == focusedIndex;
              return _buildRow(index, isMoving: index == movingIndex, focusedColumn: isFocused ? focusedColumn : null);
            },
          ),
        ),
      ),
    );
  }

  /// [focusedColumn] is null unless the D-pad cursor is on this row.
  Widget _buildRow(int index, {required bool isMoving, int? focusedColumn}) {
    final id = _items[index];
    final tab = allNavigationTabs.firstWhere((tab) => tab.id == id);
    final isHidden = _isHidden(id);
    final theme = Theme.of(context);

    Color? tileColor;
    if (isMoving) {
      tileColor = theme.colorScheme.primaryContainer;
    } else if (focusedColumn != null) {
      tileColor = theme.focusColor;
    }

    return Opacity(
      key: ValueKey(id),
      opacity: isHidden ? 0.5 : 1.0,
      child: ListTile(
        tileColor: tileColor,
        leading: Row(
          mainAxisSize: .min,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: AppIcon(
                isMoving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
                fill: 1,
                color: isMoving ? theme.colorScheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 8),
            AppIcon(tab.icon, fill: 1),
          ],
        ),
        title: Text(tab.getLabel()),
        trailing: Container(
          decoration: FocusTheme.focusBackgroundDecoration(context, isFocused: focusedColumn == 1, borderRadius: 20),
          child: IconButton(
            icon: AppIcon(isHidden ? Symbols.visibility_off_rounded : Symbols.visibility_rounded, fill: 1),
            tooltip: isHidden ? t.settings.showNavItem : t.settings.hideNavItem,
            onPressed: () => _toggleHidden(id),
          ),
        ),
      ),
    );
  }
}
