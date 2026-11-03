import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'player/player.dart';

/// Video widget for displaying player output.
///
/// This widget displays the video output from a [Player] instance
/// and optionally overlays custom controls.
///
/// Example usage:
/// ```dart
/// final player = Player();
///
/// Video(
///   player: player,
///   controls: (context) => MyCustomControls(),
/// )
/// ```
class Video extends StatefulWidget {
  final Player player;
  final Widget Function(BuildContext context)? controls;
  final Color backgroundColor;
  final ValueListenable<bool>? hasFirstFrame;

  const Video({
    super.key,
    required this.player,
    this.controls,
    this.backgroundColor = Colors.black,
    this.hasFirstFrame,
  });

  @override
  State<Video> createState() => _VideoState();
}

class _VideoState extends State<Video> {
  bool _hasFirstFrame = false;
  StreamSubscription<void>? _playbackRestartSubscription;

  @override
  void initState() {
    super.initState();
    _hasFirstFrame = widget.hasFirstFrame?.value ?? false;
    widget.hasFirstFrame?.addListener(_syncExternalFirstFrame);
    _listenForPlaybackRestart();
  }

  @override
  void didUpdateWidget(covariant Video oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hasFirstFrame != widget.hasFirstFrame) {
      oldWidget.hasFirstFrame?.removeListener(_syncExternalFirstFrame);
      widget.hasFirstFrame?.addListener(_syncExternalFirstFrame);
      _listenForPlaybackRestart();
      _syncExternalFirstFrame();
    }
    if (oldWidget.player != widget.player) {
      _listenForPlaybackRestart();
      _syncExternalFirstFrame();
    }
  }

  @override
  void dispose() {
    widget.hasFirstFrame?.removeListener(_syncExternalFirstFrame);
    _playbackRestartSubscription?.cancel();
    super.dispose();
  }

  /// Without an external notifier the first playback-restart reveals the
  /// surface. With one, the owner decides: the player screen holds the first
  /// frame behind its loading UI while it negotiates the display mode from
  /// that frame, and revealing on the restart would show the frame frozen
  /// through the HDMI blank.
  void _listenForPlaybackRestart() {
    _playbackRestartSubscription?.cancel();
    _playbackRestartSubscription = null;
    if (widget.hasFirstFrame != null) return;
    _playbackRestartSubscription = widget.player.streams.playbackRestart.listen((_) {
      _setHasFirstFrame(true);
    });
  }

  void _syncExternalFirstFrame() {
    final external = widget.hasFirstFrame;
    if (external == null) return;
    _setHasFirstFrame(external.value);
  }

  void _setHasFirstFrame(bool value) {
    if (_hasFirstFrame == value || !mounted) return;
    setState(() => _hasFirstFrame = value);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _hasFirstFrame ? Colors.transparent : widget.backgroundColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The native video surface sits behind this transparent box.
          const SizedBox.expand(),

          // Controls overlay
          if (widget.controls != null) widget.controls!(context),
        ],
      ),
    );
  }
}
