import 'package:flutter/widgets.dart';

import '../core/motion.dart';

/// One haptic when another agent starts waiting for the person: a key entered
/// [needsYou] (reachable agents that need an answer, terminal panes and
/// sessions; `AttentionSet.needsYouKeys`) while the app is in front. The
/// board's wash plays on a card that is often off screen, and the badge is a
/// number; this is the part you feel.
///
/// By key, not by count: a Wi-Fi to mobile handover empties the set and fills
/// it again with the same agents, and that is not news. An agent that went
/// out of reach stays in [waiting] (every agent last known to wait), so its
/// return is quiet; only a key the cue has not seen waiting is felt. An
/// agent that stops waiting and later waits again is new again.
///
/// Quiet on purpose: not at start-up or after the app came back (the set
/// filling while the first snapshot arrives is the fleet catching up, not
/// news), and at most one per [spacing], so a burst of agents blocking is one
/// tap on the shoulder. Nothing for an agent that stops waiting. A local
/// notification still covers the app being away (`AttentionNotifier`).
class ArrivalCue extends StatefulWidget {
  const ArrivalCue({
    super.key,
    required this.needsYou,
    this.waiting = const {},
    required this.child,
    this.calm = const Duration(seconds: 3),
    this.spacing = const Duration(seconds: 2),
    this.now = DateTime.now,
  });

  /// The keys of the agents that need an answer and can be given one.
  final Set<String> needsYou;

  /// The keys of every agent last known to wait, reachable or not.
  final Set<String> waiting;
  final Widget child;

  /// How long after start-up and after resuming a rise is not news.
  final Duration calm;

  /// The shortest time between two cues.
  final Duration spacing;
  final DateTime Function() now;

  @override
  State<ArrivalCue> createState() => _ArrivalCueState();
}

class _ArrivalCueState extends State<ArrivalCue> with WidgetsBindingObserver {
  late DateTime _calmUntil;
  DateTime? _lastCue;

  /// Every key seen waiting and not yet seen to stop.
  late Set<String> _known;

  @override
  void initState() {
    super.initState();
    _calmUntil = widget.now().add(widget.calm);
    _known = {...widget.waiting, ...widget.needsYou};
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _calmUntil = widget.now().add(widget.calm);
  }

  @override
  void didUpdateWidget(ArrivalCue old) {
    super.didUpdateWidget(old);
    if (identical(widget.needsYou, old.needsYou) && identical(widget.waiting, old.waiting)) return;
    final fresh = widget.needsYou.any((k) => !_known.contains(k));
    _known = {...widget.waiting, ...widget.needsYou};
    if (!fresh) return;
    final now = widget.now();
    final state = WidgetsBinding.instance.lifecycleState;
    final front = state == null || state == AppLifecycleState.resumed;
    final last = _lastCue;
    if (!front || now.isBefore(_calmUntil)) return;
    if (last != null && now.difference(last) < widget.spacing) return;
    _lastCue = now;
    Haptics.armed();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
