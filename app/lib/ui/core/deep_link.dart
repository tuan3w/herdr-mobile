import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/machine_profile.dart';
import '../../data/repositories/agent_screens.dart';
import '../../data/repositories/fleet_repository.dart';
import '../../data/repositories/machine_connection.dart';
import '../../data/repositories/agent_session.dart' show AgentSessions;
import '../../data/repositories/machine_repository.dart';
import 'home_tabs.dart';
import 'motion.dart';
import 'toast.dart';

/// The shape of the link a host alert carries (the optional ntfy plugin, see
/// docs/ALERTS.md); the app's own notifications use [parseAgentLink]'s too.
const agentLinkFormat = 'herdr://agent/<machine>/<pane-id>';

/// `herdr://agent/<machine>/<pane-id>`: one agent on one saved machine. Both
/// parts are percent-encoded in the link (a pane id like `w1:p2` travels as
/// `w1%3Ap2`) and decoded here.
class AgentLink {
  const AgentLink(this.machine, this.paneId);

  final String machine;
  final String paneId;

  @override
  bool operator ==(Object other) =>
      other is AgentLink && other.machine == machine && other.paneId == paneId;

  @override
  int get hashCode => Object.hash(machine, paneId);

  @override
  String toString() => 'AgentLink($machine, $paneId)';
}

final _brokenEscape = RegExp('%(?![0-9A-Fa-f]{2})');

/// Reads an agent link, or null for anything else: another scheme or host,
/// the wrong number of parts, an empty part, malformed escapes. The scheme and
/// host are case-insensitive; the machine and pane id keep their case. A query,
/// a fragment and one trailing slash are ignored.
AgentLink? parseAgentLink(String? link) {
  final parts = _parts(link, 'agent');
  return parts == null ? null : AgentLink(parts.$1, parts.$2);
}

/// [parseAgentLink] for an already parsed [uri].
AgentLink? parseAgentUri(Uri uri) {
  final parts = _partsOf(uri, 'agent');
  return parts == null ? null : AgentLink(parts.$1, parts.$2);
}

/// `herdr://session/<machine>/<keeper-id>`: one agent session (the chat) on one
/// saved machine, written like [AgentLink].
class SessionLink {
  const SessionLink(this.machine, this.keeperId);

  final String machine;
  final String keeperId;

  @override
  bool operator ==(Object other) =>
      other is SessionLink && other.machine == machine && other.keeperId == keeperId;

  @override
  int get hashCode => Object.hash(machine, keeperId);

  @override
  String toString() => 'SessionLink($machine, $keeperId)';
}

/// Reads a session link, or null for anything else (same rules as
/// [parseAgentLink]).
SessionLink? parseSessionLink(String? link) {
  final parts = _parts(link, 'session');
  return parts == null ? null : SessionLink(parts.$1, parts.$2);
}

/// Whether [link] is `herdr://agents`, the link of the one notification that
/// stands for several agents: it opens the app on its board and nothing else
/// (scheme and host in any case, nothing after).
bool isBoardLink(String? link) {
  if (link == null) return false;
  final uri = Uri.tryParse(link.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'herdr' || uri.host.toLowerCase() != 'agents') return false;
  if (uri.hasPort || uri.userInfo.isNotEmpty) return false;
  final path = uri.path;
  return path.isEmpty || path == '/';
}

(String, String)? _parts(String? link, String host) {
  if (link == null) return null;
  // Dart's Uri turns a stray `%` into `%25` and decodes it back to a literal,
  // so a broken escape has to be caught on the text as it came in.
  if (_brokenEscape.hasMatch(link)) return null;
  final uri = Uri.tryParse(link.trim());
  return uri == null ? null : _partsOf(uri, host);
}

(String, String)? _partsOf(Uri uri, String host) {
  if (uri.scheme.toLowerCase() != 'herdr') return null;
  if (uri.host.toLowerCase() != host || uri.hasPort || uri.userInfo.isNotEmpty) return null;
  final List<String> parts;
  try {
    parts = uri.pathSegments;
  } on FormatException {
    return null; // an escape that is not UTF-8, e.g. %FF
  }
  final segments = parts.isNotEmpty && parts.last.isEmpty ? parts.sublist(0, parts.length - 1) : parts;
  if (segments.length != 2) return null;
  final first = segments[0].trim();
  final second = segments[1].trim();
  if (first.isEmpty || second.isEmpty) return null;
  return (first, second);
}

/// The saved machine a link's `<machine>` names: by label first (any case),
/// then by host (any case), then by id. With the same label twice, the first
/// saved wins.
MachineProfile? matchMachine(Iterable<MachineProfile> machines, String name) {
  final wanted = name.trim().toLowerCase();
  if (wanted.isEmpty) return null;
  for (final m in machines) {
    if (m.label.trim().toLowerCase() == wanted) return m;
  }
  for (final m in machines) {
    if (m.host.trim().toLowerCase() == wanted) return m;
  }
  for (final m in machines) {
    if (m.id == name.trim()) return m;
  }
  return null;
}

/// Shows [agent] (the app passes `openAgentFromLink`: in place of the agent
/// screen in front, if one is).
typedef OpenAgentScreen = Future<void> Function(BuildContext context, AgentRef agent);

/// Opens what a `herdr://agent/...` or `herdr://session/...` link names, or the
/// board for `herdr://agents`. Android hands such a link
/// to Flutter twice over: as the initial route when the link started the app,
/// and as route information while it runs. Both land here, and a tap on one of
/// the app's own notifications comes in through [follow].
///
/// It must be registered before the app widget builds (the app's state does it
/// in `initState`): observers are asked in registration order and the first to
/// answer true wins, and the navigator's own handler would push the link as a
/// named route, which this app does not have.
///
/// Give [navigatorKey] to the `MaterialApp`. The board link selects the Agents
/// tab and goes back to it. A link that cannot be followed (an unknown
/// machine, pane or session, a machine that does not answer) leaves the
/// person where they are and says why in a toast whose button opens the tab
/// where the next step is: Machines for a machine to add, switch on or retry,
/// Agents for an agent that is gone. Going back never closes a screen that
/// asks first (a form with unsaved input): its own guard asks, as Back does.
/// Session links need [sessions]; without them they are not links this app
/// can open.
class DeepLinks with WidgetsBindingObserver {
  DeepLinks({
    required this.machines,
    required this.fleet,
    required this.open,
    this.tabs,
    this.sessions,
    this._initialRoute,
    this.patience = const Duration(seconds: 8),
    this.coldStartFrames = 3,
  });

  final MachineRepository machines;
  final FleetRepository fleet;
  final OpenAgentScreen open;
  final AgentSessions? sessions;

  /// Turns the home screen to the tab a link means (null in tests without a
  /// home screen).
  final HomeTabs? tabs;

  /// How long to wait for a machine that is still connecting to say whether the
  /// pane exists.
  final Duration patience;

  /// Frames to let the first screens settle before a cold-start link is
  /// followed: the app may be putting the agent screen it was left on back
  /// at that moment, and the link's agent takes its place.
  final int coldStartFrames;

  final navigatorKey = GlobalKey<NavigatorState>();
  final String? _initialRoute;
  bool _attached = false;
  int _generation = 0;

  /// Starts listening and follows the link the app was started with, if any.
  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    final route = _initialRoute ?? WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (_isLink(route)) unawaited(_follow(route, cold: true));
  }

  void dispose() {
    _generation++;
    if (_attached) WidgetsBinding.instance.removeObserver(this);
    _attached = false;
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    // Nothing else in this app is a named route, so a route that is not ours
    // is swallowed instead of reaching the navigator's handler.
    final link = routeInformation.uri.toString();
    if (_isLink(link)) unawaited(_follow(link, cold: false));
    return Future.value(true);
  }

  /// Follows [link] as a tap on a notification does: [cold] when that tap
  /// started the app. Anything that is not a `herdr:` link is ignored.
  Future<void> follow(String link, {bool cold = false}) =>
      _isLink(link) ? _follow(link, cold: cold) : Future.value();

  static bool _isLink(String route) => route.toLowerCase().startsWith('herdr:');

  Future<void> _follow(String route, {required bool cold}) async {
    final generation = ++_generation;
    bool stale() => generation != _generation;

    if (!await _navigatorReady(frames: cold ? coldStartFrames : 0) || stale()) return;
    if (isBoardLink(route)) {
      unawaited(_show(HomeTab.agents));
      return;
    }
    final pane = parseAgentLink(route);
    final chat = pane == null ? parseSessionLink(route) : null;
    final machineName = pane?.machine ?? chat?.machine;
    if (machineName == null) {
      _say("That link isn't one herdr can open.", next: HomeTab.agents);
      return;
    }
    final profile = matchMachine(machines.machines, machineName);
    if (profile == null) {
      _say('No machine named "$machineName" on this phone.', next: HomeTab.machines);
      return;
    }
    if (!profile.enabled) {
      _say('${profile.label} is switched off.', next: HomeTab.machines);
      return;
    }
    // A machine saved a moment ago has no connection until the fleet caught up.
    if (fleet.connection(profile.id) == null) await fleet.settled();
    final connection = fleet.connection(profile.id);
    if (stale()) return;
    if (connection == null || connection.state == LinkState.disabled) {
      _say('${profile.label} is switched off.', next: HomeTab.machines);
      return;
    }

    final _Pane found;
    String? sessionKey;
    if (pane != null) {
      found = await _present(connection, () => connection.paneById(pane.paneId) != null);
    } else {
      final key = sessionKey = '${profile.id}/${chat!.keeperId}';
      final list = sessions;
      if (list == null) {
        _say("That link isn't one herdr can open.", next: HomeTab.agents);
        return;
      }
      var first = await _present(connection, () => list.byKey(key) != null);
      // A session this phone has not listed yet (the app was just started) is
      // looked for on the host before it is called gone.
      if (first == _Pane.gone && !stale()) {
        await list.refresh();
        if (list.byKey(key) != null) first = _Pane.here;
      }
      found = first;
    }
    if (stale()) return;
    switch (found) {
      case _Pane.here:
        final context = _context;
        if (context == null || !context.mounted) return;
        if (pane != null) {
          await open(context, PaneAgent(profile.id, pane.paneId));
        } else {
          await open(context, SessionAgent(sessionKey!));
        }
      case _Pane.gone:
        _say('That agent is no longer on ${profile.label}.', next: HomeTab.agents);
      case _Pane.unreachable:
        _say("Couldn't reach ${profile.label} to open that agent.", next: HomeTab.machines);
    }
  }

  /// Brings [tab] of the home screen to the front: the tab first (under
  /// whatever is in front), then back down to the home screen the way Back
  /// goes. A screen that asks before it closes (a form with unsaved input) is
  /// not closed: its own guard asks, and if the person keeps it, it stays, with
  /// [tab] waiting under it.
  Future<void> _show(HomeTab tab) async {
    tabs?.select(tab);
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    while (nav.mounted) {
      final top = _top(nav);
      if (top == null || top.isFirst) return;
      final asks = top.popDisposition == RoutePopDisposition.doNotPop;
      await nav.maybePop();
      // Asked (its guard now has the person's attention) or refused to go.
      if (asks || !nav.mounted || identical(_top(nav), top)) return;
    }
  }

  /// The route in front. `popUntil` with a predicate that holds at once
  /// pops nothing; it is the navigator's one way to name its top route.
  static Route<dynamic>? _top(NavigatorState nav) {
    Route<dynamic>? top;
    nav.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  /// Whether [tab] of the home screen is what the person sees now.
  bool _showing(HomeTab tab) {
    final nav = navigatorKey.currentState;
    return nav != null && (_top(nav)?.isFirst ?? false) && (tabs == null || tabs!.current == tab);
  }

  /// A context under the navigator (and so under the app's providers), once
  /// the first screen exists.
  BuildContext? get _context {
    final overlay = navigatorKey.currentState?.overlay;
    return overlay != null && overlay.mounted ? overlay.context : null;
  }

  /// Waits for the first screen (after [frames] more frames). False if it
  /// never comes, or when the app is gone.
  Future<bool> _navigatorReady({required int frames}) async {
    for (var i = 0; i < frames; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    for (var i = 0; i < 300; i++) {
      if (!_attached) return false;
      if (_context != null) return true;
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  /// Whether the thing a link names ([have]) is on [connection]. A pane in the
  /// last snapshot counts at once, even a cached one: the pane screen shows
  /// what is reachable. A live snapshot without it means it is gone. While the
  /// machine is still connecting the answer is awaited, for [patience].
  Future<_Pane> _present(MachineConnection connection, bool Function() have) {
    _Pane? decide() {
      if (have()) return _Pane.here;
      return switch (connection.state) {
        LinkState.online => _Pane.gone,
        LinkState.connecting || LinkState.reconnecting || LinkState.approval => null,
        LinkState.attention || LinkState.offline || LinkState.disabled => _Pane.unreachable,
      };
    }

    final now = decide();
    if (now != null) return Future.value(now);

    final done = Completer<_Pane>();
    late final Timer timer;
    void check() {
      final answer = decide();
      if (answer == null || done.isCompleted) return;
      timer.cancel();
      connection.removeListener(check);
      done.complete(answer);
    }

    timer = Timer(patience, () {
      connection.removeListener(check);
      if (!done.isCompleted) done.complete(_Pane.unreachable);
    });
    connection.addListener(check);
    return done.future;
  }

  /// Says why a link did nothing, over whatever is in front: a form being
  /// filled in stays as it is. The toast's button opens [next], the tab where
  /// the step that can succeed is, unless the person is already looking at it.
  void _say(String message, {required HomeTab next}) {
    final context = _context;
    if (context == null) return;
    Haptics.tick();
    Toaster(navigatorKey.currentState!.overlay!).show(
      message,
      action: _showing(next)
          ? null
          : ToastAction(switch (next) {
              HomeTab.agents => 'Open Agents',
              HomeTab.machines => 'Open Machines',
              HomeTab.settings => 'Open Settings',
            }, () => unawaited(_show(next))),
    );
  }
}

enum _Pane { here, gone, unreachable }
