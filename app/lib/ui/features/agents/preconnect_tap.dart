import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_session.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Starts the work of opening an agent the moment a finger goes DOWN on its
/// row or card, ~100 ms before the tap completes and the route is pushed: a
/// session's attach (`AgentSessions.preconnect`, by [sessionKey]), a pane
/// chat's log follow (`preconnectObservedChat`) or a terminal's first read, by
/// [start].
///
/// The hold is let go when the finger slides away (past the touch slop, which
/// is also what a scroll or a swipe does), when the pointer is cancelled, and
/// shortly after it lifts without the row having opened (a long press that
/// started a selection). A tap hands the hold on with `take`: the opened
/// screen lets it go once it has taken its own hold, so the attach is never
/// dropped and restarted in between. Hover starts nothing (only a pointer
/// that is down does). Raw pointer events: no gesture is claimed, the row's
/// own tap, long press and swipe are untouched.
class PreconnectTap extends StatefulWidget {
  const PreconnectTap({super.key, this.sessionKey, this.start, required this.builder, this.enabled = true})
    : assert(sessionKey != null || start != null, 'a hold needs a session key or a way to start one');

  /// The agent session whose attach the hold starts (`AgentSessions.preconnect`).
  final String? sessionKey;

  /// Starts the hold some other way (a pane's observed chat, its terminal's
  /// first read): called with a finger down, it returns the hold or null.
  /// Wins over [sessionKey].
  final Preconnect? Function(BuildContext context)? start;

  /// Off while the row is not a tap target (a selection is under way).
  final bool enabled;

  /// [take] gives the hold to whatever opens the session (null when none was
  /// taken).
  final Widget Function(BuildContext context, Preconnect? Function() take) builder;

  @override
  State<PreconnectTap> createState() => _PreconnectTapState();
}

class _PreconnectTapState extends State<PreconnectTap> {
  Preconnect? _hold;
  int? _pointer;
  Offset _origin = Offset.zero;
  Timer? _grace;

  /// How long a hold outlives a finger that lifted without opening.
  static const _lingers = Dwell.preconnectLinger;

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null) return;
    _release();
    _pointer = e.pointer;
    _origin = e.position;
    final start = widget.start;
    final key = widget.sessionKey;
    _hold = start != null ? start(context) : context.read<AgentSessions?>()?.preconnect(key!);
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if ((e.position - _origin).distance > kTouchSlop) _release();
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _grace?.cancel();
    _grace = Timer(_lingers, _release);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer == _pointer) _release();
  }

  Preconnect? _take() {
    _grace?.cancel();
    _grace = null;
    final hold = _hold;
    _hold = null;
    _pointer = null;
    return hold;
  }

  void _release() {
    _grace?.cancel();
    _grace = null;
    _pointer = null;
    _hold?.cancel();
    _hold = null;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _cancel,
    child: widget.builder(context, _take),
  );
}
