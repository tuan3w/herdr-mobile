import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_session.dart';

/// Starts attaching to a session the moment a finger goes DOWN on its row,
/// ~100 ms before the tap completes and the route is pushed
/// (`AgentSessions.preconnect`).
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
  const PreconnectTap({super.key, required this.sessionKey, required this.builder, this.enabled = true});

  final String sessionKey;

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
  static const _lingers = Duration(milliseconds: 400);

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null) return;
    _release();
    _pointer = e.pointer;
    _origin = e.position;
    _hold = context.read<AgentSessions?>()?.preconnect(widget.sessionKey);
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
