import 'package:flutter/material.dart';

/// A single preference for decorative motion; system accessibility wins.
class MotionScope extends InheritedWidget {
  const MotionScope({super.key, required this.enabled, required super.child});
  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      !MediaQuery.disableAnimationsOf(context) &&
      (context.dependOnInheritedWidgetOfExactType<MotionScope>()?.enabled ??
          true);

  @override
  bool updateShouldNotify(MotionScope oldWidget) =>
      enabled != oldWidget.enabled;
}

class MotionResize extends StatelessWidget {
  const MotionResize({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => MotionScope.enabledOf(context)
      ? AnimatedSize(
          duration: const Duration(milliseconds: 300),
          alignment: Alignment.topCenter,
          curve: Curves.easeOutCubic,
          child: child,
        )
      : child;
}

/// One finite, interruptible entrance. Contents remain available to focus.
class MotionReveal extends StatefulWidget {
  const MotionReveal({
    super.key,
    required this.child,
    this.delay = 0,
    this.distance = 18,
  });
  final Widget child;
  final int delay;
  final double distance;

  @override
  State<MotionReveal> createState() => _MotionRevealState();
}

class _MotionRevealState extends State<MotionReveal>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 620 + widget.delay),
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      widget.delay / (620 + widget.delay),
      1,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MotionScope.enabledOf(context)) {
      if (!_controller.isCompleted) _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    child: widget.child,
    builder: (context, child) => Opacity(
      opacity: _curve.value,
      child: Transform.translate(
        offset: Offset(0, widget.distance * (1 - _curve.value)),
        child: child,
      ),
    ),
  );
}

/// Changes only the current subtree, so forms never share a GlobalKey.
class MotionSwap extends StatefulWidget {
  const MotionSwap({super.key, required this.identity, required this.child});
  final Object identity;
  final Widget child;

  @override
  State<MotionSwap> createState() => _MotionSwapState();
}

class _MotionSwapState extends State<MotionSwap>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 320),
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(MotionSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity != oldWidget.identity) {
      if (MotionScope.enabledOf(context)) {
        _controller.forward(from: 0);
      } else {
        _controller.value = 1;
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MotionScope.enabledOf(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, .025),
        end: Offset.zero,
      ).animate(_curve),
      child: widget.child,
    ),
  );
}

/// Adds tactile feedback without changing layout or owning the tap gesture.
class MotionHover extends StatefulWidget {
  const MotionHover({
    super.key,
    required this.child,
    this.enabled = true,
    this.lift = 2,
  });
  final Widget child;
  final bool enabled;
  final double lift;

  @override
  State<MotionHover> createState() => _MotionHoverState();
}

class _MotionHoverState extends State<MotionHover> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && MotionScope.enabledOf(context);
    final duration = enabled
        ? const Duration(milliseconds: 180)
        : Duration.zero;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedSlide(
          offset: Offset(
            0,
            enabled && _hovered && !_pressed ? -.008 * widget.lift : 0,
          ),
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: enabled && _pressed ? .985 : 1,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Isolates decorative ticking to its own small repaint boundary.
class AmbientMotion extends StatefulWidget {
  const AmbientMotion({
    super.key,
    required this.builder,
    this.duration = const Duration(seconds: 8),
  });
  final Widget Function(BuildContext, double) builder;
  final Duration duration;

  @override
  State<AmbientMotion> createState() => _AmbientMotionState();
}

class _AmbientMotionState extends State<AmbientMotion>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MotionScope.enabledOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => widget.builder(context, _controller.value),
    ),
  );
}

Future<T?> showLineDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool? animate,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.black.withValues(alpha: .38),
  transitionDuration: (animate ?? MotionScope.enabledOf(context))
      ? const Duration(milliseconds: 280)
      : Duration.zero,
  pageBuilder: (context, _, _) => builder(context),
  transitionBuilder: (context, animation, _, child) {
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween(begin: .96, end: 1.0).animate(curve),
        child: child,
      ),
    );
  },
);
