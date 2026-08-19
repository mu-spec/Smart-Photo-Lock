import 'package:flutter/material.dart';

/// Horizontal shake feedback for PIN-entry screens (mismatch / wrong PIN).
///
/// Shared by the setup and unlock screens so both react identically to
/// failed attempts.
///
/// Usage:
/// ```dart
/// class _State extends State<Foo> with SingleTickerProviderStateMixin, EntryShakeMixin {
///   @override
///   void initState() { super.initState(); initShake(); }
///
///   @override
///   void dispose() { disposeShake(); super.dispose(); }
///
///   // trigger:   shake();
///   // wrap:      shakeWrap(child)
/// }
/// ```
mixin EntryShakeMixin<T extends StatefulWidget>
    on SingleTickerProviderStateMixin<T> {
  late final AnimationController _controller;
  late final Animation<Offset> _animation;

  void initShake() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _animation = TweenSequence<Offset>(<TweenSequenceItem<Offset>>[
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: Offset.zero, end: const Offset(0.06, 0)),
        weight: 1,
      ),
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: const Offset(0.06, 0), end: const Offset(-0.06, 0)),
        weight: 1,
      ),
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: const Offset(-0.06, 0), end: const Offset(0.04, 0)),
        weight: 1,
      ),
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: const Offset(0.04, 0), end: const Offset(-0.03, 0)),
        weight: 1,
      ),
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: const Offset(-0.03, 0), end: Offset.zero),
        weight: 1,
      ),
    ]).animate(_controller);
  }

  /// Replays the shake from the start.
  void shake() => _controller.forward(from: 0);

  /// Wraps [child] in the shake animation.
  Widget shakeWrap(Widget child) =>
      SlideTransition(position: _animation, child: child);

  void disposeShake() => _controller.dispose();
}
