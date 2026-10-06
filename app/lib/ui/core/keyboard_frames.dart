import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Keeps a frame coming at every vsync while the on-screen keyboard moves.
///
/// Android reports the keyboard's position once per vsync during its animation
/// (17 times when it opens on the phone this was measured on), each a moment
/// before the vsync. A frame asked for when an update arrives misses that
/// vsync and lands on the next one, which draws the newest position and skips
/// the one before: half the positions were never drawn, the layout stepped at
/// 30 Hz under a keyboard (a system surface) that moves at 60 Hz, and the
/// composer trailed it and for a few frames hid behind it.
///
/// A ticker that is running when an update arrives has the vsync armed
/// already. It runs only while the inset changes and for [_quiet] after the
/// last change, so it ends with the keyboard's own animation: it is not a
/// looping animation, and nothing is built or painted for it beyond what the
/// new inset needs.
class KeyboardFrames extends StatefulWidget {
  const KeyboardFrames({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardFrames> createState() => _KeyboardFramesState();
}

/// How long the ticker outlives the last change of the inset: a few frames of
/// the platform's update interval, so it never stops in the middle of the
/// animation.
const _quiet = Duration(milliseconds: 120);

class _KeyboardFramesState extends State<KeyboardFrames>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  double _inset = 0;

  /// Ticker time of the latest tick, and of the latest change of the inset.
  Duration _now = Duration.zero;
  Duration _movedAt = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final inset = View.of(context).viewInsets.bottom;
    if (inset == _inset) return;
    _inset = inset;
    if (!_ticker.isActive) {
      _now = Duration.zero;
      unawaited(_ticker.start());
    }
    _movedAt = _now;
  }

  void _tick(Duration elapsed) {
    _now = elapsed;
    if (elapsed - _movedAt > _quiet) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
