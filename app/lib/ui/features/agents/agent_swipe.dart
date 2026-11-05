import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../../data/repositories/agent_screens.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../photos/photo_math.dart' show rubberBand;
import 'agent_navigation.dart';
import 'agent_peek.dart';

/// An agent screen's content (the terminal panel, the chat's transcript)
/// with the swipe along the triage walk (`agent_navigation.dart`): a swipe
/// left shows the next agent that wants the person coming in from the right,
/// a swipe right the one before it in the walk from the left, and letting go
/// far enough goes there ([AgentSwipeDetector]). The same steps are the
/// screen's `Next agent` and `Previous agent` accessibility actions: every
/// gesture has one.
class AgentSwipe extends StatelessWidget {
  const AgentSwipe({super.key, required this.agent, required this.child});

  final AgentRef agent;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    customSemanticsActions: {
      _next: () => swipeToAgent(context, agent, 1),
      _previous: () => swipeToAgent(context, agent, -1),
    },
    child: AgentSwipeDetector(peek: (step) => _peek(context, step), child: child),
  );

  /// Looked up once, when the swipe is recognised: letting go goes to the
  /// agent the card showed.
  SwipePeek _peek(BuildContext context, int step) {
    final to = neighbourOf(context, agent, step);
    if (to == null) {
      return SwipePeek(
        card: AgentPeekEnd(next: step > 0, working: agentsWorking(context)),
      );
    }
    return SwipePeek(
      card: AgentPeekCard(item: to.item, fromLeft: step < 0, position: to.position, count: to.count),
      go: () => stepToAgent(context, to.item.agent, step),
    );
  }

  static const _next = CustomSemanticsAction(label: 'Next agent');
  static const _previous = CustomSemanticsAction(label: 'Previous agent');
}

/// What a recognised swipe shows ([card]), and what letting go past the
/// commit distance does ([go], true if it opens something). No [go]: there is
/// nothing that way (either end of the order), and [card] says so.
class SwipePeek {
  const SwipePeek({required this.card, this.go});

  final Widget card;
  final bool Function()? go;
}

/// Turns a clearly horizontal one-finger drag into a peek at the neighbouring
/// agent (+1 = next, for a swipe to the left) that follows the finger, and
/// into a step there if it is let go far enough.
///
/// It listens to raw pointer events and never joins the gesture arena, so it
/// can sit over a terminal or a transcript without taking anything from it:
/// vertical scrolling, taps on links, long-press selection and pinch zoom all
/// behave as before. It only decides, from the finger's own path, whether to
/// ALSO peek:
///
/// * one finger the whole time (a second finger is a pinch: cancelled);
/// * horizontal travel of at least [intent] within [window] of touching down
///   (selection starts at 500 ms, so a selection drag is never a swipe), past
///   the touch slop, so that anything under the finger that scrolls has
///   claimed the drag first;
/// * vertical travel under 40% of the horizontal one; a finger that has gone
///   clearly vertical ([_vertical]) first is a scroll for the rest of the touch;
/// * not starting within [edge] of the screen's sides (the back gestures);
/// * nothing under the finger scrolled during the touch: sideways (a code
///   block, a table, a terminal wider than the screen), that swipe is theirs;
///   vertically (a slanted drag the transcript or the terminal took as a
///   scroll), it is a scroll, not a swipe.
///   The peek waits for the end of the pointer event that recognised it, so a
///   scroll claimed by that same event still wins.
///
/// Once recognised there is no time limit: the finger drives the card, which
/// is fully in by 1.5x [commit] (an end card, with nothing that way, comes
/// with resistance). Turning vertical, a second finger or anything under the
/// finger scrolling takes it back and nothing happens.
/// Letting go steps if the travel, with the fling's momentum projected
/// ([Springs.projectSheet]), reaches [commit]; else, or if the step opens
/// nothing, the card springs back.
/// Crossing [commit] while dragging ticks, either way.
class AgentSwipeDetector extends StatefulWidget {
  const AgentSwipeDetector({
    super.key,
    required this.peek,
    required this.child,
    this.commit = 64,
    this.intent = kTouchSlop + Gap.xs,
    this.window = Dwell.swipeIntent,
    this.edge = 24,
  });

  /// What a swipe recognised towards [step] shows and leads to; asked once
  /// per swipe.
  final SwipePeek Function(int step) peek;
  final Widget child;
  final double commit;
  final double intent;
  final Duration window;
  final double edge;

  @override
  State<AgentSwipeDetector> createState() => _AgentSwipeDetectorState();
}

class _AgentSwipeDetectorState extends State<AgentSwipeDetector> with TickerProviderStateMixin {
  int? _pointer;
  Offset _start = Offset.zero;
  Duration _startedAt = Duration.zero;
  VelocityTracker? _tracker;

  /// The latest horizontal travel of this touch.
  double _dx = 0;

  /// This touch can no longer be or drive a swipe (second finger, vertical,
  /// too slow, started at an edge, something scrolled sideways, let go).
  bool _dead = true;

  /// Something under the finger scrolled during this touch.
  bool _scrolled = false;

  /// Recognised on this event; shown once the event is through.
  bool _pending = false;

  /// This touch was recognised as a swipe and drives the card.
  bool _recognised = false;

  /// The recognised swipe's direction (+1 next) and what it shows; the card
  /// stays while it springs back or fades after the finger is gone.
  int _step = 0;
  SwipePeek? _target;
  bool _armed = false;

  /// Bumped per recognised swipe, so an old spring-back's end does not take
  /// a newer peek away.
  int _generation = 0;

  /// How far the card has come in, in dp (its offset from just outside the
  /// edge). The finger drives it; a spring only after the finger is gone.
  /// Made on the first swipe: most agent screens are left without one.
  AnimationController? _travelController;
  AnimationController get _travel => _travelController ??= AnimationController.unbounded(vsync: this);

  /// 1 while the card is there; to 0 as the next agent's screen comes in.
  AnimationController? _fadeController;
  AnimationController get _fade => _fadeController ??= AnimationController(vsync: this, value: 1);

  @override
  void dispose() {
    _travelController?.dispose();
    _fadeController?.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
    if (_pointer != null) {
      _dead = true;
      _retract(0);
      return;
    }
    _pointer = e.pointer;
    _start = e.position;
    _startedAt = e.timeStamp;
    _dx = 0;
    _scrolled = false;
    _recognised = false;
    _tracker = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.position);
    final width = MediaQuery.sizeOf(context).width;
    _dead = _start.dx < widget.edge || _start.dx > width - widget.edge;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer || _dead) return;
    _tracker?.addPosition(e.timeStamp, e.position);
    final dx = e.position.dx - _start.dx;
    final dy = e.position.dy - _start.dy;
    _dx = dx;
    if (!_recognised) {
      if (e.timeStamp - _startedAt > widget.window) {
        _dead = true;
        return;
      }
      if (dy.abs() > _vertical && dy.abs() > dx.abs()) {
        _dead = true;
        return;
      }
      if (!_pending && dx.abs() >= widget.intent && dy.abs() <= dx.abs() * _slant) {
        _pending = true;
        final step = dx < 0 ? 1 : -1;
        // The gesture arena sees this event after this listener: a scrollable
        // that claims the drag on it says so before the microtask runs.
        scheduleMicrotask(() {
          _pending = false;
          if (mounted && !_dead && !_scrolled && _pointer != null) _recognise(step);
        });
      }
      return;
    }
    if (dy.abs() > kTouchSlop && dy.abs() > dx.abs() * _slant) {
      _dead = true;
      _retract(0);
      return;
    }
    _follow();
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) {
      if (_pointer == null) _dead = true;
      return;
    }
    _tracker?.addPosition(e.timeStamp, e.position);
    _dx = e.position.dx - _start.dx;
    final live = !_dead && _recognised;
    final velocity = _tracker?.getVelocity().pixelsPerSecond.dx ?? 0;
    _pointer = null;
    _dead = true;
    if (live) _release(velocity);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) {
      if (_pointer == null) _dead = true;
      return;
    }
    _pointer = null;
    _dead = true;
    _retract(0);
  }

  /// A sideways scroll at any point of the touch, or a vertical one the
  /// finger drags, means the content took this touch: no swipe.
  bool _onScroll(ScrollNotification n) {
    if (_pointer == null || _scrolled) return false;
    final taken = switch (n) {
      ScrollEndNotification() => false,
      _ when n.metrics.axis == Axis.horizontal => true,
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (taken) {
      _scrolled = true;
      _dead = true;
      _retract(0);
    }
    return false;
  }

  void _recognise(int step) {
    _generation++;
    _travel.stop();
    _fade.value = 1;
    _recognised = true;
    setState(() {
      _step = step;
      _target = widget.peek(step);
      _armed = false;
    });
    _follow();
  }

  /// Travel towards the swipe's side (negative: back past the start).
  double _along(double dx) => _step > 0 ? -dx : dx;

  bool get _hasTarget => _target?.go != null;

  /// The card's width, a share of the screen's; the end card hugs its words.
  double get _cardWidth => math.min(MediaQuery.sizeOf(context).width * _cardShare, FloatingBar.maxWidth);

  /// How far the card has come in for [along] of finger travel: it reveals
  /// faster than the finger ([_revealAt]) until it is fully in, then barely
  /// gives; the end card resists all the way.
  double _shown(double along) {
    if (along <= 0) return 0;
    if (!_hasTarget) return rubberBand(along, _endReach, constant: _endGive);
    final full = _cardWidth + Gap.md;
    final reveal = widget.commit * _revealAt;
    return along <= reveal ? along * full / reveal : full + rubberBand(along - reveal, Gap.md);
  }

  void _follow() {
    final along = _along(_dx);
    _travel.value = _shown(along);
    if (!_hasTarget) return;
    final armed = along >= widget.commit;
    if (armed != _armed) {
      _armed = armed;
      Haptics.tick();
    }
  }

  void _release(double velocity) {
    final along = _along(_dx);
    final speed = _along(velocity);
    final go = _target?.go;
    if (go != null && along + speed * Springs.projectSheet >= widget.commit) {
      _armed = true;
      if (!go()) {
        _retract(0);
        return;
      }
      final generation = _generation;
      _fade.animateTo(0, duration: Motion.of(context, Motion.standard), curve: Motion.easeOut).whenCompleteOrCancel(() {
        if (mounted && generation == _generation) _clear();
      });
      return;
    }
    if (go == null) Haptics.tick();
    _retract((_shown(along + 1) - _shown(along)) * speed);
  }

  /// Takes the card back out from where it is, at [velocity] (dp/s inward).
  void _retract(double velocity) {
    if (_target == null) return;
    _armed = false;
    final generation = _generation;
    _travel
        .animateWith(SpringSimulation(Springs.settle, _travel.value, 0, velocity, tolerance: Springs.swipe))
        .whenCompleteOrCancel(() {
          if (mounted && generation == _generation) _clear();
        });
  }

  void _clear() {
    _travel.stop();
    setState(() {
      _target = null;
      _step = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        // One structure with or without a card, so the content keeps its state.
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (target != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: RepaintBoundary(
                      child: _PeekLayer(
                        travel: _travel,
                        fade: _fade,
                        fromLeft: _step < 0,
                        end: target.go == null,
                        armAt: _shown(widget.commit),
                        width: _cardWidth,
                        reduced: Motion.reduced(context),
                        child: target.card,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Vertical travel allowed per horizontal dp.
  static const _slant = 0.4;

  /// Vertical travel (dp) past which a finger that has gone more vertical
  /// than sideways is a scroll for the rest of the touch.
  static const _vertical = 24.0;

  /// The card's share of the screen's width (at most [FloatingBar.maxWidth]).
  static const _cardShare = 0.72;

  /// The card is fully in once the finger has gone this many times the
  /// commit distance. The card is a reveal at the screen's edge, not an
  /// object under the finger, so it need not move 1:1: the finger still
  /// drives it continuously, and at the commit distance two thirds of it
  /// (the glyph and most of the title) already show. 1:1, a thumb from mid
  /// screen could never bring it fully in.
  static const _revealAt = 1.5;
}

/// The end card: how much of the finger's travel it follows at first, and
/// how far it can be pulled at most.
const _endGive = 0.3;
const _endReach = Motion.travel * 3;

/// The card, where [travel] puts it: coming in from the side the swipe goes
/// to, centred on the content's height. The end card waits [Motion.travel]
/// outside its place and is pulled in against resistance, fading in. Under
/// reduced motion nothing slides: each card sits at its place and fades in
/// with the finger's travel.
class _PeekLayer extends StatelessWidget {
  const _PeekLayer({
    required this.travel,
    required this.fade,
    required this.fromLeft,
    required this.end,
    required this.armAt,
    required this.width,
    required this.reduced,
    required this.child,
  });

  final Animation<double> travel;
  final Animation<double> fade;
  final bool fromLeft;
  final bool end;

  /// Where [travel] is when the finger is at the commit distance.
  final double armAt;
  final double width;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: kBarTextScale,
    child: LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: Listenable.merge([travel, fade]),
        child: child,
        builder: (context, child) {
          final t = travel.value;
          final armed = !end && t >= armAt - Springs.pixel.distance;
          final full = armAt;
          var opacity = fade.value;
          if (reduced || end) opacity *= (t / full).clamp(0.0, 1.0);
          final card = PeekFrame(armed: armed, child: child!);
          Widget placed;
          if (end) {
            final out = reduced ? 0.0 : Motion.travel - t;
            placed = Align(
              alignment: fromLeft ? Alignment.centerLeft : Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Transform.translate(offset: Offset(fromLeft ? -out : out, 0), child: card),
              ),
            );
          } else {
            final rest = width + Gap.md;
            final inside = reduced ? rest : t;
            placed = Stack(
              children: [
                Positioned(
                  left: fromLeft ? inside - width : box.maxWidth - inside,
                  width: width,
                  top: 0,
                  bottom: 0,
                  child: Center(child: card),
                ),
              ],
            );
          }
          if (opacity >= 1) return placed;
          return Opacity(opacity: opacity.clamp(0.0, 1.0), child: placed);
        },
      ),
    ),
  );
}
