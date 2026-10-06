import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One agent, whatever started it: the board lists each once, and an agent
/// screen shows one.
@immutable
sealed class AgentRef {
  const AgentRef();

  /// The board's key for the agent's row (`AttentionItem.key`): a terminal
  /// pane is `<machineId>/<paneId>`, an agent session `session/<sessionKey>`.
  String get key;

  @override
  bool operator ==(Object other) => other is AgentRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'AgentRef($key)';
}

/// An agent in a herdr pane. Pane ids are only unique per machine, so both
/// are the identity. It has a terminal, and a chat too when the app can
/// follow its log (`ObservedSessions.supports`).
final class PaneAgent extends AgentRef {
  const PaneAgent(this.machineId, this.paneId);

  final String machineId;
  final String paneId;

  @override
  String get key => '$machineId/$paneId';
}

/// An agent session (a keeper on the host): chat only.
final class SessionAgent extends AgentRef {
  const SessionAgent(this.sessionKey);

  /// `<machineId>/<keeperId>`.
  final String sessionKey;

  @override
  String get key => 'session/$sessionKey';
}

/// How an agent is shown: its chat (an agent session, or a pane's agent read
/// from its log) or its terminal.
enum AgentView { chat, terminal }

/// The agent screen in front and the view it shows.
@immutable
class FrontAgent {
  const FrontAgent(this.agent, this.view);

  final AgentRef agent;
  final AgentView view;

  String encode() => jsonEncode({
    'v': 1,
    ...switch (agent) {
      PaneAgent(:final machineId, :final paneId) => {'pane': [machineId, paneId]},
      SessionAgent(:final sessionKey) => {'session': sessionKey},
    },
    'view': view.name,
  });

  /// Null for anything that is not what [encode] writes.
  static FrontAgent? decode(String? source) {
    if (source == null) return null;
    try {
      final json = jsonDecode(source);
      if (json is! Map || json['v'] != 1) return null;
      final view = AgentView.values.where((v) => v.name == json['view']).firstOrNull;
      if (view == null) return null;
      final pane = json['pane'];
      final session = json['session'];
      if (pane is List && pane.length == 2) {
        final [machine, id] = pane;
        if (machine is String && id is String && machine.isNotEmpty && id.isNotEmpty) {
          return FrontAgent(PaneAgent(machine, id), view);
        }
      }
      if (session is String && session.isNotEmpty) {
        return FrontAgent(SessionAgent(session), AgentView.chat);
      }
      return null;
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is FrontAgent && other.agent == agent && other.view == view;

  @override
  int get hashCode => Object.hash(agent, view);
}

/// Where the agent screen in front is kept between launches.
abstract interface class AgentScreensStore {
  Future<FrontAgent?> read();

  /// Null: no agent screen is in front (the person went back to the board).
  Future<void> write(FrontAgent? front);
}

class PrefsAgentScreensStore implements AgentScreensStore {
  static const _key = 'frontAgent.v1';

  /// What the tabs this replaced left behind (`{tabs, active, host}`): read
  /// once to carry the tab that was in front over, then deleted.
  static const _tabsKey = 'openTabs.v1';

  @override
  Future<FrontAgent?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_tabsKey);
    if (legacy == null) return FrontAgent.decode(prefs.getString(_key));
    await prefs.remove(_tabsKey);
    if (prefs.containsKey(_key)) return FrontAgent.decode(prefs.getString(_key));
    final front = frontOfTabs(legacy);
    if (front != null) await prefs.setString(_key, front.encode());
    return front;
  }

  @override
  Future<void> write(FrontAgent? front) async {
    final prefs = await SharedPreferences.getInstance();
    if (front == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, front.encode());
    }
  }

  /// The terminal that was in front when the app was left on its tabs, from
  /// what the tabs saved; null when the tab screen was not in front.
  @visibleForTesting
  static FrontAgent? frontOfTabs(String source) {
    try {
      final json = jsonDecode(source);
      if (json is! Map || json['v'] != 1 || json['host'] != true) return null;
      final active = json['active'];
      for (final entry in json['tabs'] as List) {
        if (entry is! List || entry.length != 2) continue;
        final [machine, pane] = entry;
        if (machine is String && pane is String && machine.isNotEmpty && pane.isNotEmpty && active == '$machine|$pane') {
          return FrontAgent(PaneAgent(machine, pane), AgentView.terminal);
        }
      }
      return null;
    } on Object {
      return null;
    }
  }
}

/// What the app keeps about agent screens.
///
/// The screen in front, and its view, is kept between launches (with a
/// store): the app puts it back in front once ([takeResume]) when it was left
/// on it, and going back to the board forgets it. Each agent screen says when
/// it is shown and when it goes ([shown], [left]); with several on the
/// navigator the newest is the one in front.
///
/// For the app run only, per agent: the view the person chose with the
/// Chat | Terminal toggle, and the composer's draft. A swipe replaces the
/// screen, so what is typed must live outside it.
class AgentScreens extends ChangeNotifier {
  AgentScreens([this._store]);

  final AgentScreensStore? _store;
  bool _loaded = false;
  FrontAgent? _saved;
  FrontAgent? _resume;

  /// The agent screens on the navigator, oldest first: who registered, what
  /// it shows.
  final _screens = <(Object, FrontAgent)>[];
  final _views = <AgentRef, AgentView>{};
  final _drafts = <AgentRef, String>{};

  /// Brings back the screen that was in front. Call once, before the first
  /// frame. A store that cannot be read leaves nothing to resume.
  Future<void> load() async {
    final store = _store;
    if (store == null || _loaded) return;
    try {
      _saved = await store.read();
    } on Object {
      _saved = null;
    }
    _loaded = true;
    _resume = _saved;
  }

  /// The screen that was in front when the app was last left, once.
  FrontAgent? takeResume() {
    final resume = _resume;
    _resume = null;
    return resume;
  }

  /// The agent screen in front, if one is.
  FrontAgent? get front => _screens.lastOrNull?.$2;

  /// Screen [owner] shows [agent] in [view]. Screens call it from `initState`.
  void shown(Object owner, AgentRef agent, AgentView view) {
    final before = front;
    _screens
      ..removeWhere((s) => identical(s.$1, owner))
      ..add((owner, FrontAgent(agent, view)));
    _changed(before, persist: true);
  }

  /// Screen [owner] went away. With [leaving] the person left it (Back, a
  /// swipe), and what is in front now is saved; without, the app itself is
  /// being torn down (swiped away, the process ending), and what is saved
  /// stays, so the next launch puts it back. Screens call it from `dispose`.
  void left(Object owner, {required bool leaving}) {
    final before = front;
    _screens.removeWhere((s) => identical(s.$1, owner));
    _changed(before, persist: leaving);
  }

  /// The screen to put back could not be shown (it is gone, or the person
  /// moved on before it was ready): the next launch does not try again.
  void forgetResume() => _persist(front);

  bool _notifying = false;

  void _changed(FrontAgent? before, {required bool persist}) {
    final now = front;
    if (persist) _persist(now);
    if (now == before || _notifying) return;
    // Screens report from initState and dispose, where listeners (the fleet
    // marking what is in front reviewed, and the widgets that follow it) may
    // not rebuild anything: they hear about it right after.
    _notifying = true;
    scheduleMicrotask(() {
      _notifying = false;
      if (!_disposed) notifyListeners();
    });
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _persist(FrontAgent? front) {
    final store = _store;
    if (store == null || !_loaded || front == _saved) return;
    _saved = front;
    unawaited(_write(store, front));
  }

  // A phone that cannot write its preferences still shows its agents.
  Future<void> _write(AgentScreensStore store, FrontAgent? front) async {
    try {
      await store.write(front);
    } on Object {
      // The next change tries again.
      _saved = null;
    }
  }

  /// The view chosen for [agent] in this app run, if one was.
  AgentView? viewOf(AgentRef agent) => _views[agent];

  void choose(AgentRef agent, AgentView view) => _views[agent] = view;

  /// What was typed for [agent] and not sent, in either view.
  String draftOf(AgentRef agent) => _drafts[agent] ?? '';

  void keepDraft(AgentRef agent, String text) {
    if (text.isEmpty) {
      _drafts.remove(agent);
    } else {
      _drafts[agent] = text;
    }
  }
}
