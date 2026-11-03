import 'package:flutter/material.dart';

/// InheritedWidget to indicate that a side navigation is present in the widget tree.
class SideNavigationScope extends InheritedWidget {
  const SideNavigationScope({super.key, required super.child});

  static bool isPresent(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SideNavigationScope>() != null;
  }

  @override
  bool updateShouldNotify(SideNavigationScope oldWidget) => false;
}

/// Helper class for adjusting app bar widgets.
class DesktopAppBarHelper {
  /// Right padding that keeps app bar actions off the screen edge.
  static const double _actionsRightPadding = 6.0;

  /// Appends trailing padding to an app bar's actions.
  static List<Widget> buildAdjustedActions(List<Widget>? actions) {
    return [...?actions, const SizedBox(width: _actionsRightPadding)];
  }
}
