import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/observed_sessions.dart';
import '../../core/chrome.dart' show SheetAction;
import '../../core/motion.dart';
import '../../core/toast.dart';
import '../agent_session/agent_session_screen.dart';
import '../pane/pane_screen.dart';
import 'agents_grouping.dart';

/// The one way to show an agent: the board, notifications and links, the
/// start forms, Duplicate, past sessions and the agent screens themselves all
/// open agents here.
///
/// One agent per screen. A terminal pane shows its terminal ([PaneScreen]) or,
/// when the app can follow its log, its chat ([AgentSessionScreen] over an
/// observed session); an agent session shows its chat. Inside an agent screen
/// a swipe goes to the next agent in the board's order ([swipeToAgent]) and
/// the menu's view row switches the view ([showAgentView]); both replace the
/// screen, so Back always goes where the person came from (the board).

/// Opens [agent] in [view]; without one, in the view chosen for it in this
/// app run, else as Settings says ("Open agents as"). A pane whose agent has
/// no chat opens its terminal. With [replace] the screen takes the place of
/// the current route (a start form, the chat a session continues from). An
/// agent already in front, in that view, is left as it is.
///
/// [preconnect] is the hold taken when a finger went down on a session's row
/// (`AgentSessions.preconnect`): the screen lets it go once it holds the
/// session itself, and it is let go at once when nothing opens. A session
/// that is no longer listed says so in a toast and opens nothing.
Future<void> openAgent(
  BuildContext context,
  AgentRef agent, {
  AgentView? view,
  bool replace = false,
  Preconnect? preconnect,
}) =>
    _open(context, agent, view: view, replace: replace, entrance: _Entrance.page, preconnect: preconnect);

/// Opens [agent] from a notification or a link: in place of the agent screen
/// in front, if one is (one agent per screen; Back still goes to the board),
/// else over whatever is in front.
Future<void> openAgentFromLink(BuildContext context, AgentRef agent) {
  final top = _topRoute(Navigator.of(context));
  return _open(context, agent, replace: top is _AgentRoute, entrance: _Entrance.page);
}

/// The menu's `Show terminal` / `Show chat` ([agentViewAction]): shows [agent]
/// in [view] in place of the screen in front, with a fade (the same agent, so
/// nothing slides), and remembers the choice for this agent for the app run.
Future<void> showAgentView(BuildContext context, AgentRef agent, AgentView view) {
  context.read<AgentScreens?>()?.choose(agent, view);
  return _open(context, agent, view: view, replace: true, entrance: _Entrance.fade);
}

/// A swipe inside an agent screen: shows the agent [delta] places from
/// [agent] in the board's order (+1 the next one, for a swipe to the left)
/// in place of this screen, sliding in from the side the finger came from.
/// At either end, or for an agent the board does not list, nothing moves and
/// a tick says so.
void swipeToAgent(BuildContext context, AgentRef agent, int delta) {
  final order = agentsInBoardOrder(context);
  final at = order.indexOf(agent);
  final to = at + delta;
  if (at < 0 || to < 0 || to >= order.length) {
    Haptics.tick();
    return;
  }
  unawaited(
    _open(
      context,
      order[to],
      replace: true,
      entrance: delta > 0 ? _Entrance.fromRight : _Entrance.fromLeft,
    ),
  );
}

/// Every agent the board lists, in the board's order: its sections in turn
/// (Needs you and Done in [AttentionSet]'s order: what can be reached first,
/// longest waiting first), terminal panes and sessions as the board mixes
/// them. The board's filter and collapsed sections are a way of looking, not
/// an order, and are not applied.
List<AgentRef> agentsInBoardOrder(BuildContext context) {
  final attention = context.read<AttentionSet?>();
  if (attention == null) return const [];
  final sections = boardSections(
    AgentsOverview.of(context.read<FleetRepository>()).agents,
    context.read<AgentSessions?>()?.sessions ?? const [],
    attention,
  );
  return [
    for (final section in sections)
      for (final item in section.items)
        switch (item) {
          PaneItem(:final row) => PaneAgent(row.machine.profile.id, row.paneId),
          SessionItem(:final session) => SessionAgent(session.key),
        },
  ];
}

/// Puts the agent screen the app was left on back in front at launch: at once
/// and without the slide when it can be shown now, as if the app never
/// closed. A session the phone has not listed yet (or a pane's chat whose log
/// is not known yet) is waited for, up to [patience], while the board is
/// still in front and untouched; it then comes in with the usual page
/// transition. If it never comes, it is forgotten.
Future<void> resumeAgent(
  NavigatorState navigator,
  FrontAgent front, {
  Duration patience = const Duration(seconds: 8),
}) async {
  final context = navigator.context;
  if (_screenFor(context, front.agent, front.view, strict: true) case final screen?) {
    unawaited(navigator.push(_AgentRoute(front.agent, front.view, _Entrance.instant, screen)));
    return;
  }
  final sources = Listenable.merge([
    context.read<FleetRepository>(),
    ?context.read<AgentSessions?>(),
  ]);
  final done = Completer<bool>();
  var touched = false;
  void pointer(PointerEvent e) {
    if (e is PointerDownEvent) touched = true;
    if (touched && !done.isCompleted) done.complete(false);
  }

  void check() {
    if (!done.isCompleted && _screenFor(context, front.agent, front.view, strict: true) != null) {
      done.complete(true);
    }
  }

  final timer = Timer(patience, () {
    if (!done.isCompleted) done.complete(false);
  });
  GestureBinding.instance.pointerRouter.addGlobalRoute(pointer);
  sources.addListener(check);
  final ready = await done.future;
  timer.cancel();
  sources.removeListener(check);
  GestureBinding.instance.pointerRouter.removeGlobalRoute(pointer);
  if (!navigator.mounted || !context.mounted) return;
  final screen = ready ? _screenFor(context, front.agent, front.view, strict: true) : null;
  // The person moved on (touched the board, or something opened meanwhile).
  if (screen == null || !(_topRoute(navigator)?.isFirst ?? false)) {
    context.read<AgentScreens?>()?.forgetResume();
    return;
  }
  unawaited(navigator.push(_AgentRoute(front.agent, front.view, _Entrance.page, screen)));
}

/// Whether a screen being disposed now is being left by the person (the app
/// is in front: Back, a swipe), not torn down with the app (swiped away, the
/// process ending), which keeps it as the screen to put back at launch.
bool leavingInForeground() {
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  return lifecycle == null || lifecycle == AppLifecycleState.resumed || lifecycle == AppLifecycleState.inactive;
}

/// The menu row that swaps an agent's view in place: `Show terminal` from the
/// chat, `Show chat` from the terminal. It lives in the screen's own menu
/// (the session options, the pane options), not in the bar: switching is rare
/// next to reading and answering, and two segments cost 88 dp of a bar that
/// also holds the title. [shown] is the view the screen in front shows.
SheetAction agentViewAction(BuildContext context, AgentRef agent, AgentView shown) {
  final toTerminal = shown == AgentView.chat;
  return SheetAction(
    label: toTerminal ? 'Show terminal' : 'Show chat',
    icon: toTerminal ? LucideIcons.terminal : LucideIcons.messageSquare,
    onTap: () => unawaited(showAgentView(context, agent, toTerminal ? AgentView.terminal : AgentView.chat)),
  );
}

Future<void> _open(
  BuildContext context,
  AgentRef agent, {
  AgentView? view,
  required bool replace,
  required _Entrance entrance,
  Preconnect? preconnect,
}) async {
  final want = view ?? _defaultView(context, agent);
  final navigator = Navigator.of(context);
  final screen = _screenFor(context, agent, want, preconnect: preconnect);
  if (screen == null) {
    preconnect?.cancel();
    showToast(context, 'That session is no longer available.');
    return;
  }
  final shows = switch (screen) {
    PaneScreen() => AgentView.terminal,
    _ => AgentView.chat,
  };
  final top = _topRoute(navigator);
  if (top is _AgentRoute && top.agent == agent && top.view == shows) {
    preconnect?.cancel();
    return;
  }
  final route = _AgentRoute(agent, shows, Motion.reduced(context) && entrance.slides ? _Entrance.fade : entrance, screen);
  if (replace) {
    await navigator.pushReplacement(route);
  } else {
    await navigator.push(route);
  }
}

AgentView _defaultView(BuildContext context, AgentRef agent) {
  if (agent is SessionAgent) return AgentView.chat;
  final chosen = context.read<AgentScreens?>()?.viewOf(agent);
  if (chosen != null) return chosen;
  return context.read<AppSettings?>()?.openAgentsAs == OpenAgentsAs.terminal ? AgentView.terminal : AgentView.chat;
}

/// The screen for [agent] in [view]. A pane's chat needs its log; without one
/// it is the terminal, unless [strict] (then null). Null for a session that is
/// not listed.
Widget? _screenFor(BuildContext context, AgentRef agent, AgentView view, {bool strict = false, Preconnect? preconnect}) {
  switch (agent) {
    case SessionAgent(:final sessionKey):
      final session = context.read<AgentSessions?>()?.byKey(sessionKey);
      return session == null ? null : AgentSessionScreen(session: session, agent: agent, preconnect: preconnect);
    case PaneAgent(:final machineId, :final paneId):
      if (view == AgentView.chat) {
        final machine = context.read<FleetRepository>().connection(machineId);
        final session = machine == null ? null : context.read<ObservedSessions?>()?.forPane(machine, paneId);
        if (session != null) return AgentSessionScreen(session: session, agent: agent);
        if (strict) return null;
      }
      if (strict && context.read<FleetRepository>().connection(machineId) == null) return null;
      return PaneScreen(agent: agent);
  }
}

/// The route in front. `popUntil` with a predicate that holds at once pops
/// nothing; it is the navigator's one way to name its top route.
Route<dynamic>? _topRoute(NavigatorState navigator) {
  Route<dynamic>? top;
  navigator.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

/// How an agent screen comes in.
enum _Entrance {
  /// The app's page transition (from the board, a form, a link).
  page,

  /// A swipe: a short slide from the side the finger came from, with a fade.
  fromRight,
  fromLeft,

  /// The other view of the same agent: a fade, nothing moves.
  fade,

  /// At launch, as if the app never closed.
  instant;

  bool get slides => this == fromRight || this == fromLeft;
}

/// An agent screen's route. It comes in as [_Entrance] says; once in, it is
/// the app's page (Back and the edge swipe as everywhere else).
///
/// A swipe or the toggle replaces the screen in front: that one stays still
/// under the new one (no parallax), which slides a short way and fades in
/// over [Motion.standard], or only fades over [Motion.fade] (the toggle, and
/// reduced motion).
class _AgentRoute extends MaterialPageRoute<void> {
  _AgentRoute(this.agent, this.view, this.entrance, Widget screen) : super(builder: (_) => screen);

  final AgentRef agent;
  final AgentView view;
  final _Entrance entrance;

  /// The entrance has played; from now on it is a page like any other.
  bool _entered = false;

  /// Keeps the page's subtree when the entrance's wrapper goes.
  final _transitionKey = GlobalKey();

  @override
  Duration get transitionDuration => switch (entrance) {
    _Entrance.page => super.transitionDuration,
    _Entrance.fromRight || _Entrance.fromLeft => Motion.standard,
    _Entrance.fade => Motion.fade,
    _Entrance.instant => Duration.zero,
  };

  @override
  TickerFuture didPush() {
    final future = super.didPush();
    if (entrance == _Entrance.page) {
      _entered = true;
    } else {
      future.whenCompleteOrCancel(() => _entered = true);
    }
    return future;
  }

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      !(nextRoute is _AgentRoute && nextRoute.entrance != _Entrance.page) && super.canTransitionTo(nextRoute);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (entrance == _Entrance.page || entrance == _Entrance.instant) {
      return super.buildTransitions(context, animation, secondaryAnimation, child);
    }
    // The page transition sees a page already in place until the entrance
    // has played, then the real animation (Back, the edge swipe).
    final page = KeyedSubtree(
      key: _transitionKey,
      child: super.buildTransitions(
        context,
        _UntilEntered(animation, () => _entered),
        secondaryAnimation,
        child,
      ),
    );
    return _EntranceTransition(
      animation: animation,
      from: switch (entrance) {
        _Entrance.fromRight => const Offset(0.2, 0),
        _Entrance.fromLeft => const Offset(-0.2, 0),
        _ => null,
      },
      child: page,
    );
  }
}

/// [parent] once the route has entered; a page fully in place before.
class _UntilEntered extends Animation<double> with AnimationWithParentMixin<double> {
  _UntilEntered(this.parent, this.entered);

  @override
  final Animation<double> parent;
  final bool Function() entered;

  @override
  double get value => entered() ? parent.value : 1;

  @override
  AnimationStatus get status => entered() ? parent.status : AnimationStatus.completed;
}

/// The entrance: a fade, with a short slide from [from] (a fraction of the
/// width) when it has one. Gone once it has played, so nothing holds an
/// opacity layer at rest.
class _EntranceTransition extends StatefulWidget {
  const _EntranceTransition({required this.animation, required this.from, required this.child});

  final Animation<double> animation;
  final Offset? from;
  final Widget child;

  @override
  State<_EntranceTransition> createState() => _EntranceTransitionState();
}

class _EntranceTransitionState extends State<_EntranceTransition> {
  late final CurvedAnimation _curve = CurvedAnimation(parent: widget.animation, curve: Motion.easeOut);
  late bool _done = widget.animation.isCompleted;

  @override
  void initState() {
    super.initState();
    if (!_done) widget.animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed || status == AnimationStatus.reverse) {
      widget.animation.removeStatusListener(_onStatus);
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final faded = FadeTransition(opacity: _curve, child: widget.child);
    final from = widget.from;
    if (from == null) return faded;
    return SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(_curve), child: faded);
  }
}
