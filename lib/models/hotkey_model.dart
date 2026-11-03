import 'package:flutter/services.dart';

import '../data/hid_key_labels.dart';

/// Modifier keys that can be combined with a primary key to form a hotkey.
///
/// Each value holds the physical keys that correspond to it (e.g. shift maps
/// to both shiftLeft and shiftRight). The [name] strings are used for
/// serialization and must stay stable across versions.
enum HotKeyModifier {
  alt([PhysicalKeyboardKey.altLeft, PhysicalKeyboardKey.altRight]),
  capsLock([PhysicalKeyboardKey.capsLock]),
  control([PhysicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlRight]),
  fn([PhysicalKeyboardKey.fn]),
  meta([PhysicalKeyboardKey.metaLeft, PhysicalKeyboardKey.metaRight]),
  shift([PhysicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftRight]);

  const HotKeyModifier(this.physicalKeys);

  final List<PhysicalKeyboardKey> physicalKeys;
}

/// A keyboard shortcut consisting of a primary [key] and optional [modifiers].
class HotKey {
  const HotKey({required this.key, this.modifiers});

  final PhysicalKeyboardKey key;
  final List<HotKeyModifier>? modifiers;
}

/// Human-readable label for a [PhysicalKeyboardKey].
///
/// Keyed by [PhysicalKeyboardKey.usbHidUsage] (an int) so maps can be const.
String physicalKeyLabel(PhysicalKeyboardKey key) {
  return hidKeyLabels[key.usbHidUsage] ?? 'Key 0x${key.usbHidUsage.toRadixString(16).padLeft(8, '0')}';
}
