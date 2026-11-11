import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/dpad_reorder_mixin.dart';
import '../focus/focus_theme.dart';
import '../focus/input_mode_tracker.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_library.dart';
import '../media/media_server_client.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../profiles/active_profile_provider.dart';
import '../utils/app_logger.dart';
import '../utils/content_utils.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'app_menu.dart';
import 'bottom_sheet_page_scaffold.dart';
import 'media_context_menu.dart' show isAdminActionAllowedForMediaItem;
import 'overlay_sheet.dart';

class ContextMenuItem {
  final String value;
  final IconData icon;
  final String label;
  final bool requiresConfirmation;
  final String? confirmationTitle;
  final String? confirmationMessage;
  final bool isDestructive;

  const ContextMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.requiresConfirmation = false,
    this.confirmationTitle,
    this.confirmationMessage,
    this.isDestructive = false,
  });
}

/// Shows the manage/reorder-libraries sheet (dialog on TV, overlay sheet
/// otherwise). Reorder and hide/unhide are provider-backed, so any screen can
/// open it.
///
/// [onOrderChanged] runs after the new order is written to
/// [LibrariesProvider] (the libraries screen uses it to poke MainScreen's
/// side nav). [onToggleVisibility] overrides the default plain hide/unhide
/// (the libraries screen adds "re-select first visible library" logic).
///
/// A library's admin actions (scan, refresh metadata, ...) are offered only
/// to an owner or administrator of its server; [canAdministerLibrary]
/// replaces that check in tests.
Future<void> showLibraryManagementSheet(
  BuildContext context, {
  VoidCallback? onOrderChanged,
  Future<void> Function(MediaLibrary library)? onToggleVisibility,
  @visibleForTesting bool Function(MediaLibrary library)? canAdministerLibrary,
}) {
  final librariesProvider = context.read<LibrariesProvider>();
  final hiddenLibrariesProvider = context.read<HiddenLibrariesProvider>();
  final serverManager = Provider.of<MultiServerProvider?>(context, listen: false)?.serverManager;
  final activeProfile = Provider.of<ActiveProfileProvider?>(context, listen: false)?.active;

  // Same gate as the media context menu's admin entries: the server's owner or
  // administrator flag, narrowed by a non-admin Plex Home profile.
  bool defaultCanAdministerLibrary(MediaLibrary library) {
    final serverId = serverIdOrNull(library.serverId);
    return serverId != null &&
        isAdminActionAllowedForMediaItem(
          isOwnerOrAdmin: serverManager?.isOwnerOrAdmin(serverId) ?? false,
          itemBackend: library.backend,
          activeProfile: activeProfile,
        );
  }

  final canAdminister = canAdministerLibrary ?? defaultCanAdministerLibrary;

  Future<void> defaultToggleVisibility(MediaLibrary library) async {
    final isHidden = hiddenLibrariesProvider.hiddenLibraryKeys.contains(library.globalKey);
    if (isHidden) {
      await hiddenLibrariesProvider.unhideLibrary(library.globalKey);
    } else {
      await hiddenLibrariesProvider.hideLibrary(library.globalKey);
    }
  }

  Widget buildSheet({required bool isDialog}) => _LibraryManagementSheet(
    isDialog: isDialog,
    librariesProvider: librariesProvider,
    hiddenLibraryKeys: hiddenLibrariesProvider.hiddenLibraryKeys,
    onReorder: (reorderedLibraries) {
      librariesProvider.updateLibraryOrder(reconcileLibraryOrder(reorderedLibraries, librariesProvider.libraries));
      onOrderChanged?.call();
    },
    onToggleVisibility: onToggleVisibility ?? defaultToggleVisibility,
    getLibraryMenuItems: (library) => canAdminister(library) ? _getLibraryMenuItems(library) : const [],
    onLibraryMenuAction: (action, library) => _handleLibraryMenuAction(context, action, library),
  );

  if (PlatformDetector.isTV()) {
    return showScopedDialog<void>(context: context, builder: (context) => buildSheet(isDialog: true));
  }
  // Use the host supplied by the calling screen when available while keeping
  // this reusable entry point safe for routes without one. isScrollControlled
  // keeps that modal fallback from capping the sheet at ~9/16 of the screen.
  return OverlaySheetController.showAdaptive<void>(
    context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => buildSheet(isDialog: false),
  );
}

/// [sheetOrder] as the sheet shows it, applied to the provider's [current]
/// libraries: rows keep the sheet's order, libraries loaded since the sheet
/// last synced follow in their current order, and libraries that have gone
/// are dropped. A reorder therefore never saves a stale snapshot, which would
/// drop newly loaded libraries or bring back removed ones.
@visibleForTesting
List<MediaLibrary> reconcileLibraryOrder(List<MediaLibrary> sheetOrder, List<MediaLibrary> current) {
  final remaining = {for (final library in current) library.globalKey: library};
  return [for (final library in sheetOrder) ?remaining.remove(library.globalKey), ...remaining.values];
}

List<ContextMenuItem> _getLibraryMenuItems(MediaLibrary library) {
  // Scan and refresh metadata are the admin actions every backend supports —
  // Plex hits `/library/sections/{id}/refresh` (with `force=1` to refresh);
  // MediaBrowser servers post to `/Items/{id}/Refresh` (the library view is
  // itself an item) with `Default` or `FullRefresh` modes.
  final scan = ContextMenuItem(
    value: 'scan',
    icon: Symbols.refresh_rounded,
    label: t.libraries.scanLibraryFiles,
    requiresConfirmation: true,
    confirmationTitle: t.libraries.scanLibrary,
    confirmationMessage: t.libraries.scanLibraryConfirm(title: library.title),
  );
  final refresh = ContextMenuItem(
    value: 'refresh',
    icon: Symbols.sync_rounded,
    label: t.libraries.refreshMetadata,
    requiresConfirmation: true,
    confirmationTitle: t.libraries.refreshMetadata,
    confirmationMessage: t.libraries.refreshMetadataConfirm(title: library.title),
    isDestructive: true,
  );
  // Analyze / empty trash hit Plex-only endpoints, so backend capability
  // gating keeps them out of MediaBrowser menus. The library-qualified
  // resolver independently requires the exact owning Plex server.
  if (library.backend != MediaBackend.plex) return [scan, refresh];
  return [
    scan,
    ContextMenuItem(
      value: 'analyze',
      icon: Symbols.analytics_rounded,
      label: t.libraries.analyze,
      requiresConfirmation: true,
      confirmationTitle: t.libraries.analyzeLibrary,
      confirmationMessage: t.libraries.analyzeLibraryConfirm(title: library.title),
    ),
    refresh,
    ContextMenuItem(
      value: 'empty_trash',
      icon: Symbols.delete_outline_rounded,
      label: t.libraries.emptyTrash,
      requiresConfirmation: true,
      confirmationTitle: t.libraries.emptyTrash,
      confirmationMessage: t.libraries.emptyTrashConfirm(title: library.title),
      isDestructive: true,
    ),
  ];
}

Future<void> _handleLibraryMenuAction(BuildContext context, String action, MediaLibrary library) async {
  // Find the menu item for confirmation details
  final menuItems = _getLibraryMenuItems(library);
  final item = menuItems.where((i) => i.value == action).firstOrNull;
  if (item == null) return;

  if (item.requiresConfirmation) {
    final confirmed = await showConfirmDialog(
      context,
      title: item.confirmationTitle ?? t.dialog.confirmAction,
      message: item.confirmationMessage ?? t.libraries.confirmActionMessage,
      confirmText: t.common.confirm,
      isDestructive: item.isDestructive,
    );
    if (!confirmed || !context.mounted) return;
  }

  switch (action) {
    case 'scan':
      unawaited(_scanLibrary(context, library));
      break;
    case 'analyze':
      unawaited(_analyzeLibrary(context, library));
      break;
    case 'refresh':
      unawaited(_refreshLibraryMetadata(context, library));
      break;
    case 'empty_trash':
      unawaited(_emptyLibraryTrash(context, library));
      break;
  }
}

/// Runs a library admin action, wrapping it in progress/success/failure
/// snackbars.
///
/// [resolveClient] picks the client flavour: `getPlexClientForLibrary` for the
/// Plex-only endpoints (analyze / empty trash), `getMediaClientForLibrary`
/// for ops on the backend-neutral [MediaServerClient] interface (scan and
/// refresh metadata). Both resolvers require the library's exact owning
/// server and throw the same error when it isn't available.
Future<void> _performLibraryAction<T extends MediaServerClient>(
  BuildContext context, {
  required T Function(BuildContext context) resolveClient,
  required Future<void> Function(T client) action,
  required String progressMessage,
  required String successMessage,
  required String Function(Object error) failureMessage,
}) async {
  try {
    final client = resolveClient(context);

    if (context.mounted) {
      showAppSnackBar(context, progressMessage, duration: const Duration(seconds: 2));
    }

    await action(client);

    if (context.mounted) {
      showSuccessSnackBar(context, successMessage);
    }
  } catch (e) {
    appLogger.e('Library action failed', error: e);
    if (context.mounted) {
      showErrorSnackBar(context, failureMessage(e));
    }
  }
}

Future<void> _scanLibrary(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getMediaClientForLibrary(library),
    action: (client) => client.scanLibrary(library.id),
    progressMessage: t.messages.libraryScanning(title: library.title),
    successMessage: t.messages.libraryScanStarted(title: library.title),
    failureMessage: (error) => t.messages.libraryScanFailed(error: error.toString()),
  );
}

Future<void> _refreshLibraryMetadata(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getMediaClientForLibrary(library),
    action: (client) => client.refreshLibraryMetadata(library.id),
    progressMessage: t.messages.metadataRefreshing(title: library.title),
    successMessage: t.messages.metadataRefreshStarted(title: library.title),
    failureMessage: (error) => t.messages.metadataRefreshFailed(error: error.toString()),
  );
}

Future<void> _emptyLibraryTrash(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getPlexClientForLibrary(library),
    action: (client) => client.emptyLibraryTrash(library.id),
    progressMessage: t.libraries.emptyingTrash(title: library.title),
    successMessage: t.libraries.trashEmptied(title: library.title),
    failureMessage: (error) => t.libraries.failedToEmptyTrash(error: error),
  );
}

Future<void> _analyzeLibrary(BuildContext context, MediaLibrary library) {
  return _performLibraryAction(
    context,
    resolveClient: (ctx) => ctx.getPlexClientForLibrary(library),
    action: (client) => client.analyzeLibrary(library.id),
    progressMessage: t.libraries.analyzing(title: library.title),
    successMessage: t.libraries.analysisStarted(title: library.title),
    failureMessage: (error) => t.libraries.failedToAnalyze(error: error),
  );
}

/// A sheet row: a server heading when [library] is null, otherwise one of that
/// server's libraries.
typedef _SheetRow = ({String serverKey, String title, MediaLibrary? library});

String _serverKeyOf(MediaLibrary library) => library.serverId ?? '';

/// [libraries] per server, servers in order of first appearance and each
/// server's libraries in their relative order.
Map<String, List<MediaLibrary>> _groupByServer(Iterable<MediaLibrary> libraries) {
  final groups = <String, List<MediaLibrary>>{};
  for (final library in libraries) {
    (groups[_serverKeyOf(library)] ??= []).add(library);
  }
  return groups;
}

/// Whether every library row still sits under its own server's heading.
bool _isGroupedByServer(List<_SheetRow> rows) {
  String? currentServer;
  for (final row in rows) {
    if (row.library == null) {
      currentServer = row.serverKey;
    } else if (row.serverKey != currentServer) {
      return false;
    }
  }
  return true;
}

class _LibraryManagementSheet extends StatefulWidget {
  final bool isDialog;
  final LibrariesProvider librariesProvider;
  final Set<String> hiddenLibraryKeys;
  final Function(List<MediaLibrary>) onReorder;
  final Future<void> Function(MediaLibrary) onToggleVisibility;
  final List<ContextMenuItem> Function(MediaLibrary) getLibraryMenuItems;
  final void Function(String action, MediaLibrary library) onLibraryMenuAction;

  const _LibraryManagementSheet({
    this.isDialog = false,
    required this.librariesProvider,
    required this.hiddenLibraryKeys,
    required this.onReorder,
    required this.onToggleVisibility,
    required this.getLibraryMenuItems,
    required this.onLibraryMenuAction,
  });

  @override
  State<_LibraryManagementSheet> createState() => _LibraryManagementSheetState();
}

class _LibraryManagementSheetState extends State<_LibraryManagementSheet>
    with DpadReorderListMixin<_SheetRow, _LibraryManagementSheet> {
  /// Every library, grouped by server: the order the sheet saves.
  late List<MediaLibrary> _libraries;

  /// What the list shows: each server's heading, followed by its libraries
  /// unless it is collapsed. Rebuilt from [_libraries] by [_rebuildRows].
  late List<_SheetRow> _rows;

  // ponytail: collapsed servers last only while the sheet is open; persist
  // them if users want them remembered.
  Set<String> _collapsedServers = {};

  /// While servers are being reordered: the collapsed servers to restore
  /// afterwards. Every server is collapsed in the meantime.
  Set<String>? _collapsedBeforeServerReorder;

  final FocusNode _listFocusNode = FocusNode();
  final ScrollController _dialogScrollController = ScrollController();
  final ScrollController _sheetScrollController = ScrollController();

  bool get _isReorderingServers => _collapsedBeforeServerReorder != null;

  @override
  List<_SheetRow> get reorderItems => _rows;

  @override
  set reorderItems(List<_SheetRow> value) => _rows = value;

  /// Headings have visibility and options columns; library rows add the
  /// options button (column 2) only when they have admin actions.
  @override
  int get lastReorderColumn {
    if (focusedIndex >= _rows.length) return 1;
    final library = _rows[focusedIndex].library;
    return library == null || _hasLibraryMenu(library) ? 2 : 1;
  }

  bool _hasLibraryMenu(MediaLibrary library) => widget.getLibraryMenuItems(library).isNotEmpty;

  /// Both layouts scroll the focused row into view: the TV dialog is the D-pad
  /// surface, and the sheet still shows the same cursor to a keyboard user.
  @override
  ScrollController? get reorderScrollController => widget.isDialog ? _dialogScrollController : _sheetScrollController;

  /// A heading is not moved in place: SELECT on it starts [_startServerReorder],
  /// which collapses every server first.
  @override
  bool canMoveReorderItem(int index) => _rows[index].library != null;

  /// A library moves only among its own server's libraries; a heading only
  /// past other headings.
  @override
  bool canSwapReorderItems(int from, int to) {
    if (_rows[from].library == null) return _rows[to].library == null;
    return _rows[to].library != null && _rows[to].serverKey == _rows[from].serverKey;
  }

  @override
  void onReorderMoveConfirmed() {
    _libraries = _orderFromRows(_rows);
    widget.onReorder(_libraries);
    _finishServerReorder();
  }

  @override
  void onReorderMoveCancelled() => _finishServerReorder();

  @override
  void onReorderColumnActivated(int column, int index) {
    final row = _rows[index];
    final library = row.library;
    if (library == null) {
      switch (column) {
        case 0:
          _startServerReorder(row.serverKey);
        case 1:
          unawaited(_toggleServerVisibility(row.serverKey));
        case 2:
          _toggleCollapsed(row.serverKey);
      }
    } else if (column == 1) {
      widget.onToggleVisibility(library);
    } else if (column == 2 && _hasLibraryMenu(library)) {
      _showLibraryMenuBottomSheet(context, library);
    }
  }

  @override
  void initState() {
    super.initState();
    _libraries = _groupByServer(widget.librariesProvider.libraries).values.expand((l) => l).toList();
    _rebuildRows();
    widget.librariesProvider.addListener(_onLibrariesChanged);
  }

  void _rebuildRows() {
    _rows = [
      for (final MapEntry(key: serverKey, value: libraries) in _groupByServer(_libraries).entries) ...[
        (serverKey: serverKey, title: libraries.first.serverName ?? serverKey, library: null),
        if (!_collapsedServers.contains(serverKey))
          for (final library in libraries) (serverKey: serverKey, title: library.title, library: library),
      ],
    ];
  }

  /// The full library order for [rows]: servers in the rows' heading order,
  /// shown libraries in the rows' order, a collapsed server's libraries as
  /// they were.
  List<MediaLibrary> _orderFromRows(List<_SheetRow> rows) {
    final previous = _groupByServer(_libraries);
    final shown = _groupByServer([for (final row in rows) ?row.library]);
    return [
      for (final heading in rows.where((row) => row.library == null))
        ...?shown[heading.serverKey] ?? previous[heading.serverKey],
    ];
  }

  /// Rebuilds the rows and keeps the cursor on [serverKey]'s heading.
  void _rebuildRowsFocusingServer(String serverKey) {
    _rebuildRows();
    focusedIndex = _rows.indexWhere((row) => row.library == null && row.serverKey == serverKey);
  }

  /// Follows library loads and changes made while the sheet is open, keeping
  /// the order shown. A move in progress keeps its rows; its confirm is
  /// reconciled against the provider when it is saved.
  void _onLibrariesChanged() {
    if (!mounted || movingIndex != null) return;
    setState(() {
      _libraries = _groupByServer(
        reconcileLibraryOrder(_libraries, widget.librariesProvider.libraries),
      ).values.expand((l) => l).toList();
      if (_isReorderingServers) _collapsedServers = _groupByServer(_libraries).keys.toSet();
      _rebuildRows();
      if (focusedIndex >= _rows.length) {
        focusedIndex = _rows.isEmpty ? 0 : _rows.length - 1;
        focusedColumn = 0;
      }
    });
  }

  @override
  void dispose() {
    widget.librariesProvider.removeListener(_onLibrariesChanged);
    _listFocusNode.dispose();
    _dialogScrollController.dispose();
    _sheetScrollController.dispose();
    super.dispose();
  }

  /// Pointer drag. A drop that would carry a library out of its server is
  /// ignored and the row snaps back.
  void _reorderRows(int oldIndex, int newIndex) {
    final candidate = List.of(_rows);
    candidate.insert(newIndex, candidate.removeAt(oldIndex));
    if (!_isGroupedByServer(candidate)) return;
    setState(() {
      _libraries = _orderFromRows(candidate);
      _rebuildRows();
    });
    widget.onReorder(_libraries);
  }

  void _toggleCollapsed(String serverKey) {
    setState(() {
      if (!_collapsedServers.remove(serverKey)) _collapsedServers.add(serverKey);
      _rebuildRowsFocusingServer(serverKey);
    });
  }

  /// Collapses every server and picks up [serverKey]'s heading. Confirming or
  /// cancelling the move restores each server's collapsed state.
  void _startServerReorder(String serverKey) {
    setState(() {
      _collapsedBeforeServerReorder = _collapsedServers;
      _collapsedServers = _groupByServer(_libraries).keys.toSet();
      _rebuildRowsFocusingServer(serverKey);
    });
    startReorderMove(focusedIndex);
  }

  void _finishServerReorder() {
    final collapsedBefore = _collapsedBeforeServerReorder;
    if (collapsedBefore == null) return;
    final movedServer = _rows[focusedIndex].serverKey;
    setState(() {
      _collapsedBeforeServerReorder = null;
      _collapsedServers = collapsedBefore;
      _rebuildRowsFocusingServer(movedServer);
    });
    ensureFocusedVisible();
  }

  /// Hides every library on the server, or shows them all when they are all
  /// hidden already. Goes library by library so a caller's
  /// [_LibraryManagementSheet.onToggleVisibility] override still runs.
  Future<void> _toggleServerVisibility(String serverKey) async {
    final hidden = context.read<HiddenLibrariesProvider>().hiddenLibraryKeys;
    final serverLibraries = _groupByServer(_libraries)[serverKey] ?? const [];
    final hide = !serverLibraries.every((library) => hidden.contains(library.globalKey));
    for (final library in serverLibraries) {
      if (hidden.contains(library.globalKey) != hide) await widget.onToggleVisibility(library);
    }
  }

  void _showLibraryMenuBottomSheet(BuildContext outerContext, MediaLibrary library) {
    final menuItems = widget.getLibraryMenuItems(library);
    OverlaySheetController.pushAdaptive<String>(
      outerContext,
      builder: (context) => AppMenuSheet<String>(
        title: library.title,
        entries: [
          for (final item in menuItems)
            AppMenuItem<String>(value: item.value, icon: item.icon, label: item.label, destructive: item.isDestructive),
        ],
        onSelected: (value) => widget.onLibraryMenuAction(value, library),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch provider to rebuild when hidden libraries change
    final hiddenLibrariesProvider = context.watch<HiddenLibrariesProvider>();
    final hiddenLibraryKeys = hiddenLibrariesProvider.hiddenLibraryKeys;

    if (widget.isDialog) {
      return Dialog(
        child: PopScope(
          canPop: false, // Prevent system back from double-popping; handled by handleReorderKeyEvent
          // ignore: no-empty-block - required callback, blocks system back on Android TV
          onPopInvokedWithResult: (didPop, result) {},
          child: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  const AppIcon(Symbols.edit_rounded, fill: 1),
                  const SizedBox(width: 12),
                  Text(t.libraries.manageLibraries),
                ],
              ),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const AppIcon(Symbols.close_rounded, fill: 1),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            body: Focus(
              focusNode: _listFocusNode,
              descendantsAreFocusable: false,
              autofocus: InputModeTracker.isKeyboardMode(context),
              onKeyEvent: handleReorderKeyEvent,
              child: _buildRowList(_dialogScrollController, hiddenLibraryKeys, shrinkWrap: false),
            ),
          ),
        ),
      );
    }

    return BottomSheetPageScaffold(
      title: t.libraries.manageLibraries,
      icon: Symbols.edit_rounded,
      child: Focus(
        focusNode: _listFocusNode,
        descendantsAreFocusable: false,
        autofocus: InputModeTracker.isKeyboardMode(context),
        onKeyEvent: handleReorderKeyEvent,
        child: _buildRowList(_sheetScrollController, hiddenLibraryKeys, shrinkWrap: true),
      ),
    );
  }

  /// Server headings with their libraries below. Each layout passes its own
  /// controller, which is also what [reorderScrollController] scrolls when the
  /// keyboard cursor moves.
  Widget _buildRowList(ScrollController scrollController, Set<String> hiddenLibraryKeys, {required bool shrinkWrap}) {
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);

    return ReorderableListView.builder(
      scrollController: scrollController,
      shrinkWrap: shrinkWrap,
      onReorderItem: _reorderRows,
      itemCount: _rows.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      buildDefaultDragHandles: false,
      itemBuilder: (context, index) {
        final row = _rows[index];
        final library = row.library;
        final isFocused = isKeyboardMode && index == focusedIndex;
        final focusedColumn = isFocused ? this.focusedColumn : null;
        if (library == null) {
          return _buildServerHeader(
            row,
            hiddenLibraryKeys,
            isMoving: index == movingIndex,
            focusedColumn: focusedColumn,
          );
        }
        return _buildLibraryTile(
          library,
          index,
          hiddenLibraryKeys,
          isMoving: index == movingIndex,
          focusedColumn: focusedColumn,
        );
      },
    );
  }

  /// A server heading: SELECT reorders servers, the eye hides or shows all of
  /// the server's libraries, and the last button collapses or expands it.
  /// [focusedColumn] is null unless the D-pad cursor is on this row.
  Widget _buildServerHeader(_SheetRow row, Set<String> hiddenLibraryKeys, {bool isMoving = false, int? focusedColumn}) {
    final allHidden = (_groupByServer(_libraries)[row.serverKey] ?? const <MediaLibrary>[]).every(
      (library) => hiddenLibraryKeys.contains(library.globalKey),
    );
    final isCollapsed = _collapsedServers.contains(row.serverKey);
    final theme = Theme.of(context);

    Color? tileColor;
    if (isMoving) {
      tileColor = theme.colorScheme.primaryContainer;
    } else if (focusedColumn != null) {
      tileColor = theme.focusColor;
    }

    return Opacity(
      key: ValueKey('server:${row.serverKey}'),
      opacity: allHidden ? 0.5 : 1.0,
      child: ListTile(
        tileColor: tileColor,
        leading: Row(
          mainAxisSize: .min,
          children: [
            AppIcon(
              isMoving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
              fill: 1,
              color: isMoving ? theme.colorScheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 8),
            const AppIcon(Symbols.dns_rounded, fill: 1),
          ],
        ),
        title: Text(row.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        trailing: Row(
          mainAxisSize: .min,
          children: [
            Container(
              decoration: FocusTheme.focusBackgroundDecoration(
                context,
                isFocused: focusedColumn == 1,
                borderRadius: 20,
              ),
              child: IconButton(
                icon: AppIcon(allHidden ? Symbols.visibility_off_rounded : Symbols.visibility_rounded, fill: 1),
                tooltip: allHidden ? t.libraries.showServer : t.libraries.hideServer,
                onPressed: () => _toggleServerVisibility(row.serverKey),
              ),
            ),
            Container(
              decoration: FocusTheme.focusBackgroundDecoration(
                context,
                isFocused: focusedColumn == 2,
                borderRadius: 20,
              ),
              child: IconButton(
                icon: AppIcon(isCollapsed ? Symbols.expand_more_rounded : Symbols.expand_less_rounded, fill: 1),
                tooltip: isCollapsed ? t.libraries.expandServer : t.libraries.collapseServer,
                onPressed: () => _toggleCollapsed(row.serverKey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A library row, indented under its server heading. [focusedColumn] is null
  /// unless the D-pad cursor is on this row.
  Widget _buildLibraryTile(
    MediaLibrary library,
    int index,
    Set<String> hiddenLibraryKeys, {
    bool isMoving = false,
    int? focusedColumn,
  }) {
    final isHidden = hiddenLibraryKeys.contains(library.globalKey);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    Color? tileColor;
    if (isMoving) {
      tileColor = colorScheme.primaryContainer;
    } else if (focusedColumn != null) {
      tileColor = theme.focusColor;
    }

    return Opacity(
      key: ValueKey(library.globalKey),
      opacity: isHidden ? 0.5 : 1.0,
      child: ListTile(
        tileColor: tileColor,
        contentPadding: const EdgeInsetsDirectional.only(start: 32, end: 16),
        leading: Row(
          mainAxisSize: .min,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: AppIcon(
                isMoving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
                fill: 1,
                color: isMoving ? colorScheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 8),
            AppIcon(ContentTypeHelper.getLibraryIcon(library.kind.id), fill: 1),
          ],
        ),
        title: Text(library.title),
        trailing: Row(
          mainAxisSize: .min,
          children: [
            Container(
              decoration: FocusTheme.focusBackgroundDecoration(
                context,
                isFocused: focusedColumn == 1,
                borderRadius: 20,
              ),
              child: IconButton(
                icon: AppIcon(isHidden ? Symbols.visibility_off_rounded : Symbols.visibility_rounded, fill: 1),
                tooltip: isHidden ? t.libraries.showLibrary : t.libraries.hideLibrary,
                onPressed: () => widget.onToggleVisibility(library),
              ),
            ),
            if (_hasLibraryMenu(library))
              Container(
                decoration: FocusTheme.focusBackgroundDecoration(
                  context,
                  isFocused: focusedColumn == 2,
                  borderRadius: 20,
                ),
                child: IconButton(
                  icon: const AppIcon(Symbols.more_vert_rounded, fill: 1),
                  tooltip: t.libraries.libraryOptions,
                  onPressed: () => _showLibraryMenuBottomSheet(context, library),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
