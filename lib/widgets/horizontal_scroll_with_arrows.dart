import 'package:flutter/widgets.dart';

/// Owns the [ScrollController] for a horizontal row (unless [controller] is
/// passed) and hands it to [builder].
// ponytail: the desktop hover arrows are gone; inline at the four call sites
// and rename when touching them.
class HorizontalScrollWithArrows extends StatefulWidget {
  final Widget Function(ScrollController) builder;
  final ScrollController? controller;

  const HorizontalScrollWithArrows({super.key, required this.builder, this.controller});

  @override
  State<HorizontalScrollWithArrows> createState() => _HorizontalScrollWithArrowsState();
}

class _HorizontalScrollWithArrowsState extends State<HorizontalScrollWithArrows> {
  ScrollController? _ownedController;

  ScrollController get _controller => widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void didUpdateWidget(covariant HorizontalScrollWithArrows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && _ownedController != null) {
      _ownedController!.dispose();
      _ownedController = null;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}
