import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';

/// Marks the finished state of [paneId] reviewed and says so with an Undo
/// toast. False (and quiet) when there was nothing to review: the pane is not
/// done any more, or was already reviewed. Several reviews in a row share one
/// toast ("Marked 3 reviewed") whose Undo takes all of them back.
bool markReviewedWithUndo(BuildContext context, MachineConnection machine, String paneId) {
  final toaster = Toaster.maybeOf(context);
  if (!machine.markReviewed(paneId)) return false;
  toaster?.show(
    'Marked reviewed',
    action: ToastAction('Undo', () {
      if (machine.unmarkReviewed(paneId)) Haptics.tick();
    }),
    groupKey: _reviewGroup,
    groupMessage: _reviewedMessage,
  );
  return true;
}

/// [markReviewedWithUndo] for an agent session: its finished turn is marked
/// seen without opening it. False (and quiet) when there is nothing to review.
/// Shares the terminal agents' toast and its Undo. [onUndo] runs as Undo is
/// tapped, before the review is taken back: a screen that shows the session
/// (and reviews what it shows) leaves it unreviewed instead of marking it
/// again at once.
bool markSessionReviewedWithUndo(BuildContext context, AgentSessionView session, {VoidCallback? onUndo}) {
  final toaster = Toaster.maybeOf(context);
  if (!session.unseenDone) return false;
  session.markSeen();
  if (session.unseenDone) return false;
  toaster?.show(
    'Marked reviewed',
    action: ToastAction('Undo', () {
      onUndo?.call();
      if (session.unmarkSeen()) Haptics.tick();
    }),
    groupKey: _reviewGroup,
    groupMessage: _reviewedMessage,
  );
  return true;
}

/// Marks every one of [panes] (terminal agents) and [sessions] reviewed that
/// still has something to review, and says so once: "Marked 4 reviewed", whose
/// Undo restores all of them (and any swipes still sharing the toast). Returns
/// how many changed; quiet when none did.
int markAllReviewedWithUndo(
  BuildContext context, {
  required Iterable<({MachineConnection machine, String paneId})> panes,
  required Iterable<AgentSessionView> sessions,
}) {
  final toaster = Toaster.maybeOf(context);
  final undo = <bool Function()>[];
  for (final (:machine, :paneId) in panes) {
    if (machine.markReviewed(paneId)) undo.add(() => machine.unmarkReviewed(paneId));
  }
  for (final session in sessions) {
    if (!session.unseenDone) continue;
    session.markSeen();
    if (!session.unseenDone) undo.add(session.unmarkSeen);
  }
  if (undo.isEmpty) return 0;
  toaster?.show(
    _reviewedMessage(undo.length),
    action: ToastAction('Undo', () {
      var restored = false;
      for (final back in undo) {
        restored |= back();
      }
      if (restored) Haptics.tick();
    }),
    groupKey: _reviewGroup,
    groupMessage: _reviewedMessage,
    count: undo.length,
  );
  return undo.length;
}

const _reviewGroup = 'review.mark';

String _reviewedMessage(int count) => count == 1 ? 'Marked reviewed' : 'Marked $count reviewed';

/// A horizontal swipe to the left on a finished agent: the row follows the
/// finger 1:1 and a quiet "Reviewed" (a check and the word, no fill) is
/// uncovered behind it. Letting go past [threshold], or with a flick that
/// would carry it there, slides the row out, closes its gap and calls
/// [onReviewed]; letting go earlier springs it back with the speed it had.
///
/// * Past the threshold the row gives way rubber-band style, and towards the
///   wrong side it barely moves, so a drag the row does not want says so.
/// * Crossing the threshold ticks once; the commit is a [Haptics.sent].
/// * It joins the gesture arena as a horizontal drag, so the list's vertical
///   scroll, a tap and a long press keep working: whichever the finger commits
///   to first wins. A second finger puts the row back and ends the gesture.
/// * With reduced motion nothing slides: the review happens on release.
/// * Screen readers get a "Mark reviewed" action instead of the gesture
///   ([ReviewAction], on the row's one semantics node).
///
/// [onReviewed] returns whether it did something. If it did not (the agent
/// moved on in the meantime) the row slides back in. A row that was reviewed
/// is reset in place, since the board then moves it to another section.
///
/// The widget is built (and cheap) for every row, enabled or not, so that a
/// row's state survives its status changing.
class SwipeToReview extends StatefulWidget {
  const SwipeToReview({
    super.key,
    required this.enabled,
    required this.onReviewed,
    required this.child,
    this.inset = 0,
  });

  /// False while the row is not finished, offline, or the board is picking.
  final bool enabled;

  /// Does the review (and shows its toast). True when it changed anything.
  final bool Function() onReviewed;
  final Widget child;

  /// Space between the row's edge and the "Reviewed" label, for rows without
  /// a margin of their own.
  final double inset;

  /// How far the finger must carry the row for a plain release to commit, for
  /// a row [width] wide.
  static double threshold(double width) => (width * 0.3).clamp(88.0, 128.0);

  /// A release this slow or slower never commits by speed alone; the speed adds
  /// its [projection] seconds of travel to where the finger stopped.
  static const projection = 0.12;

  /// Least travel a flick needs, so a twitch of the thumb is not a review.
  static const minFlickTravel = 16.0;

  @override
  State<SwipeToReview> createState() => _SwipeToReviewState();
}

class _SwipeToReviewState extends State<SwipeToReview> with SingleTickerProviderStateMixin {
  static final _back = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 380),
    bounce: 0.1,
  );
  static final _out = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 260),
  );

  /// The row's offset to the left, in px. Driven by the finger while dragging,
  /// by a spring after.
  late final AnimationController _offset = AnimationController.unbounded(vsync: this)..addListener(_onTick);
  final _pointers = <int>{};

  double _width = 0;

  /// Finger travel, unclamped and unrubbered (negative: towards the wrong side).
  double _travel = 0;
  bool _dragging = false;
  bool _armed = false;

  /// A second finger came down: this touch is over.
  bool _cancelled = false;

  /// Committed: the row is leaving. Pointer input and drags are off.
  bool _leaving = false;

  double get _threshold => SwipeToReview.threshold(_width);

  @override
  void didUpdateWidget(SwipeToReview old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && old.enabled && !_leaving && _offset.value != 0) {
      // Picking started or the agent moved on mid-drag: put the row back.
      _dragging = false;
      _springBack(0);
    }
  }

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  // Past the threshold the row slows down; to the wrong side it hardly moves.
  double _shown(double travel) {
    if (travel <= 0) return -_rubber(-travel, 36);
    final t = _threshold;
    return travel <= t ? travel : t + _rubber(travel - t, _width * 0.5);
  }

  static double _rubber(double x, double limit) => (1 - 1 / (x * 0.55 / limit + 1)) * limit;

  void _down(PointerDownEvent e) {
    _pointers.add(e.pointer);
    if (_pointers.length > 1 && _dragging && !_cancelled) {
      _cancelled = true;
      _dragging = false;
      _springBack(0);
    } else if (_pointers.length > 1) {
      _cancelled = true;
    }
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) _cancelled = false;
  }

  void _start(DragStartDetails d) {
    if (_leaving || _cancelled || _pointers.length > 1) {
      _cancelled = true;
      return;
    }
    _width = context.size?.width ?? 0;
    if (_width <= 0) return;
    // Grabbing a row that is still springing back continues from where it is.
    _offset.stop();
    _travel = _offset.value;
    _armed = _travel >= _threshold;
    _dragging = true;
  }

  void _update(DragUpdateDetails d) {
    if (!_dragging) return;
    _travel -= d.delta.dx;
    _offset.value = _shown(_travel);
    final armed = _travel >= _threshold;
    if (armed && !_armed) Haptics.tick();
    _armed = armed;
  }

  void _end(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    // Leftwards px/s of the finger, and of the row (slower inside the rubber).
    final speed = (-d.velocity.pixelsPerSecond.dx).clamp(-6000.0, 6000.0);
    final slope = _shown(_travel + 1) - _shown(_travel);
    final carried = _travel + math.max(0.0, speed) * SwipeToReview.projection;
    final commit = _travel >= _threshold ||
        (_travel >= SwipeToReview.minFlickTravel && carried >= _threshold);
    if (!commit) {
      _springBack(speed * slope);
      return;
    }
    Haptics.sent();
    if (Motion.reduced(context)) {
      _offset.value = 0;
      widget.onReviewed();
      return;
    }
    setState(() => _leaving = true);
    _offset.animateWith(_spring(_out, _offset.value, _width, math.max(0.0, speed * slope)));
  }

  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    _springBack(0);
  }

  void _springBack(double velocity) {
    if (Motion.reduced(context)) {
      _offset.value = 0;
      return;
    }
    _offset.animateWith(_spring(_back, _offset.value, 0, velocity));
  }

  void _onTick() {
    if (_leaving && _offset.value >= _width - 1) _finish();
  }

  // A spring that rests within a fifth of a pixel is done, and lands exactly:
  // a still row must not keep a sub-pixel offset.
  static SpringSimulation _spring(SpringDescription spring, double from, double to, double velocity) =>
      SpringSimulation(spring, from, to, velocity,
          snapToEnd: true, tolerance: const Tolerance(distance: 0.2, velocity: 8));

  void _finish() {
    _offset.stop();
    final did = widget.onReviewed();
    if (did) {
      // The board moves the row to another section: nothing of this slide is
      // left to undo, and a restored row (Undo) must start in place.
      _offset.value = 0;
      setState(() => _leaving = false);
    } else {
      setState(() => _leaving = false);
      _offset.animateWith(_spring(_back, _offset.value, 0, 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_leaving;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        onHorizontalDragStart: enabled ? _start : null,
        onHorizontalDragUpdate: enabled ? _update : null,
        onHorizontalDragEnd: enabled ? _end : null,
        onHorizontalDragCancel: enabled ? _cancel : null,
        child: AnimatedBuilder(
          animation: _offset,
          builder: _frame,
          child: IgnorePointer(ignoring: _leaving, child: widget.child),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, Widget? child) {
    final d = _offset.value;
    // A leaving row closes its gap once it is mostly out of the way.
    final open = _leaving && _width > 0 ? 1 - ((d / _width - 0.5) / 0.5).clamp(0.0, 1.0) : 1.0;
    return ClipRect(
      clipBehavior: _leaving ? Clip.hardEdge : Clip.none,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: open,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            d > 0.5 ? _revealed(context, d) : const SizedBox.shrink(),
            Transform.translate(offset: Offset(-d, 0), child: child),
          ],
        ),
      ),
    );
  }

  /// What the row uncovers: a check and a word, quiet until the threshold is
  /// reached, then at full strength. No fill, no colour of its own.
  Widget _revealed(BuildContext context, double d) {
    final ds = context.ds;
    final color = d >= _threshold - 0.5 ? ds.text : ds.textSecondary;
    final fade = (d / (_threshold * 0.55)).clamp(0.0, 1.0);
    Widget label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.check, size: 18, color: color),
        const SizedBox(width: Gap.sm),
        Text('Reviewed', maxLines: 1, softWrap: false, style: Type.label.copyWith(color: color)),
      ],
    );
    if (fade < 1) label = Opacity(opacity: fade, child: label);
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: d,
      child: ExcludeSemantics(
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Padding(padding: EdgeInsets.only(left: widget.inset), child: label),
          ),
        ),
      ),
    );
  }
}

/// The screen-reader route to what the swipe does: a "Mark reviewed" custom
/// action on the node of [child] (the row's button), with no slide. It merges
/// into that one node, so the row still reads as one button, and it is there
/// only while [enabled]; the same wrapper stays around the row whatever its
/// status, so the row's state survives the status changing.
class ReviewAction extends StatelessWidget {
  const ReviewAction({super.key, required this.enabled, required this.onReviewed, required this.child});

  final bool enabled;
  final bool Function() onReviewed;
  final Widget child;

  void _review() {
    if (!enabled) return;
    Haptics.sent();
    onReviewed();
  }

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Semantics(
          customSemanticsActions: enabled ? {const CustomSemanticsAction(label: 'Mark reviewed'): _review} : null,
          child: child,
        ),
      );
}
