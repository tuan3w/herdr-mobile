import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import '../acp/session_state.dart' show AgentPhase;
import '../models/herdr_models.dart' show AgentStatus;
import '../models/pane_preview.dart' show PromptInfo;
import '../services/notifier.dart';
import 'pane_answerer.dart';
import 'agent_session.dart';
import 'attention_set.dart';
import 'fleet_repository.dart';
import 'machine_connection.dart' show LinkState, MachineConnection;
import 'notification_settings.dart';

/// `herdr://agent/<machine>/<pane>`, both parts percent-encoded (a pane id
/// like `w1:p2` travels as `w1%3Ap2`); `DeepLinks` reads it back.
String agentLinkFor(String machineId, String paneId) =>
    'herdr://agent/${Uri.encodeComponent(machineId)}/${Uri.encodeComponent(paneId)}';

/// `herdr://session/<machine>/<keeper>`: an agent session's chat.
String sessionLinkFor(String machineId, String keeperId) =>
    'herdr://session/${Uri.encodeComponent(machineId)}/${Uri.encodeComponent(keeperId)}';

/// The link of the summary notifications: the app, on its board.
const agentsBoardLink = 'herdr://agents';

/// How many agents get a notification of their own in one burst; the rest are
/// summarised.
const notifyBurstLimit = 3;

/// Transitions this close to the first of a burst belong to it.
const notifyBurstWindow = Duration(seconds: 5);

/// An agent that was announced is announced again no sooner than this.
const notifyFlapWindow = Duration(minutes: 1);

/// The quiet "watching" notice is told about a new count at most this often.
const watchingDebounce = Duration(seconds: 2);

/// A title is cut to this many characters.
const notifyTitleLength = 60;

/// A command or path longer than this is not offered for approval from a
/// notification (it would not be shown whole): the buttons are left off.
const notifyShownSubjectLength = 640;

/// An answer button's text is cut to this many characters.
const notifyButtonLength = 22;

/// What the quiet "Watching" notice says: agents watched, and how many of them
/// wait for the person.
typedef _Glance = ({int count, int blocked});

const _Glance _noGlance = (count: 0, blocked: 0);

final _summaryIds = {
  NotifyKind.needsYou: notificationIdFor('summary'),
  NotifyKind.finished: notificationIdFor('summary/finished'),
};

/// Tells the person, with local notifications, when an agent starts needing
/// them while the app is in the background, and keeps the connections alive
/// for as long as there is something to watch.
///
/// Transitions, not states: an agent is announced when it *becomes* blocked
/// and reachable (or, with [NotificationSettings.alsoDone], done and not yet
/// reviewed). What was already so when the app went to the background, as last
/// known (reachable or not), is taken as seen. One notification per agent per
/// episode. An episode ends when the agent is seen to leave the state (answered
/// elsewhere, finished, pane closed, reviewed), and then its notification is
/// cancelled; it does NOT end when the machine blips out of reach (a Wi-Fi to
/// mobile handover, a reconnect): the notification stays, and when the machine
/// is back and the agent still waits, that is the same episode. Likewise an
/// agent session that is attaching again says nothing about its request. Every
/// notification is cancelled the moment the app is active again. Nothing is
/// posted or cancelled while the setting is off.
///
/// "Blocked and reachable" and "done and not reviewed" are the
/// [AttentionSet]'s rules, the same as the badge, the board and the triage:
/// [FleetAgent.needsYou] for a pane; for an agent session a blocked phase with
/// its machine and its link live ([AttentionSet.sessionReachable]). The
/// notice's "need you" number is that set's count, not one of its own.
///
/// Watching: while enabled, permitted and at least one reachable agent is
/// working or blocked, [Notifier.setWatching] keeps a foreground notice up
/// and [FleetRepository.keepAliveInBackground] (with
/// [AgentSessions.keepAliveInBackground]) is on, so the connections and the
/// sessions are not let go 90 s after the app left. The notice is a status
/// line ("Watching 5 agents", "2 need you · 3 working"); the numbers reach the
/// notifier at most once per [watchingDebounce], and only when they changed. A
/// refused start is not retried until the next lifecycle change.
///
/// While the app is in front only those numbers are kept up to date (it must
/// be running before the app leaves: Android does not start such a notice from
/// the background); the agents themselves are read when the app goes away.
///
/// Answers: with a [PaneAnswerer], the notification of a terminal agent that
/// is announced is posted again, silently, once its question has been read: the
/// question and the command in the text, and up to [maxNotificationAnswers]
/// buttons for options that need no second tap. Pressing one sends it only if
/// the pane still asks that very question ([PaneAnswerer.answer]); otherwise
/// the person is told that nothing was sent. Sessions have no buttons.
class AttentionNotifier {
  AttentionNotifier({
    required this._fleet,
    this._sessions,
    required this._attention,
    required this._settings,
    required this._notifier,
    PaneAnswerer? answerer,
    String Function(String)? visibleText,
    this._clock = DateTime.now,
  }) : _answerer = answerer,
       _visibleText = visibleText,
       assert(
         (answerer == null) == (visibleText == null),
         'answers from notifications need the text sanitiser that shows what they approve',
       ) {
    _enabled = _settings.enabled;
    _alsoDone = _settings.alsoDone;
    _fleet.addListener(_evaluate);
    _sessions?.addListener(_evaluate);
    _settings.addListener(_onSettings);
    if (answerer != null) _notifier.onAnswer(_answered);
    if (_enabled) {
      unawaited(_refreshPermission());
      // The app is in front at its start. What an earlier life of the process
      // left behind (notifications after a swipe-away or a kill, a "Watching"
      // notice of a destroyed engine) is stale; the first real count replaces
      // the notice.
      unawaited(_safe(_notifier.cancelAll));
      unawaited(_safe(() => _notifier.setWatching(0)));
    }
  }

  final FleetRepository _fleet;
  final AgentSessions? _sessions;

  /// What needs the person (built before this, so it has heard of a change
  /// by the time this runs): the notice's "need you" count.
  final AttentionSet _attention;
  final NotificationSettings _settings;
  final Notifier _notifier;
  final DateTime Function() _clock;
  final PaneAnswerer? _answerer;

  /// Makes hidden and direction-changing characters of a command visible (the
  /// UI's `visibleText`); everything a notification shows of a pane passes it.
  final String Function(String)? _visibleText;

  /// Numbers the posted answer buttons; with the clock it makes each
  /// notification's buttons unique.
  int _nonce = 0;

  bool _disposed = false;
  bool _enabled = false;
  bool _alsoDone = false;

  /// Android lets the app post. False until read.
  bool _granted = false;

  /// The app is hidden or paused (not merely inactive).
  bool _away = false;

  /// The agents the person has been told about, or counts as having seen
  /// (what was so when the app went away), by key.
  final Map<String, _Track> _tracks = {};

  /// When each agent was last announced, per kind of news, for the flap window.
  final Map<String, DateTime> _announcedAt = {};
  DateTime? _burstStart;
  int _burstPosted = 0;
  final Map<NotifyKind, int?> _summaryShown = {};
  Timer? _flapTimer;

  // Watching.
  _Glance _desired = _noGlance;
  _Glance _applied = _noGlance;
  bool _refused = false;
  bool _calling = false;
  DateTime? _lastWatchCall;
  Timer? _watchTimer;

  bool get _canPost => _enabled && _granted && _away;

  /// Feed from the app's lifecycle hook.
  void onLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _refused = false; // a lifecycle change is the one retry of a refused start
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (!_away) {
          _away = true;
          if (_enabled) _baseline();
        }
      case AppLifecycleState.resumed:
        _away = false;
        if (_enabled) {
          _clear();
          unawaited(_refreshPermission());
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
    _evaluate();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _fleet.removeListener(_evaluate);
    _sessions?.removeListener(_evaluate);
    _settings.removeListener(_onSettings);
    _flapTimer?.cancel();
    _watchTimer?.cancel();
    _keepAlive(false);
    if (_applied.count > 0 || _calling) await _safe(() => _notifier.setWatching(0));
  }

  // -- settings and permission --------------------------------------------------

  void _onSettings() {
    if (_disposed) return;
    final enabled = _settings.enabled;
    final alsoDone = _settings.alsoDone;
    final wasEnabled = _enabled;
    final wasAlsoDone = _alsoDone;
    _enabled = enabled;
    _alsoDone = alsoDone;
    if (wasEnabled && !enabled) {
      _clear();
      unawaited(_safe(_notifier.cancelAll));
      _desired = _noGlance;
      _syncWatching(immediate: true);
      return;
    }
    if (!wasEnabled && enabled) {
      _refused = false;
      if (_away) _baseline();
      unawaited(_refreshPermission());
    } else if (enabled && alsoDone && !wasAlsoDone && _away) {
      _baseline(); // what is done already is not news
    }
    _evaluate();
  }

  Future<void> _refreshPermission() async {
    var granted = false;
    try {
      granted = await _notifier.permission() == NotifyPermission.granted;
    } on Object {
      granted = false;
    }
    if (_disposed) return;
    final changed = granted != _granted;
    _granted = granted;
    if (changed) _evaluate();
  }

  // -- what is going on ------------------------------------------------------------

  /// Runs on every change of the fleet or the sessions. Off, it does nothing
  /// at all; in front it only counts what is watched (cheap, no allocation
  /// per agent); away it also follows the agents' episodes.
  void _evaluate() {
    if (_disposed || !_enabled) return;
    _desired = _granted ? _countWatching() : _noGlance;
    if (_away) _follow(_collect());
    _syncWatching();
  }

  /// A machine whose link is up, or is being brought back by itself (a
  /// handover, a tunnel, a host that rebooted): what it ran when last seen is
  /// still being watched. Counting only live links ended the watch for good at
  /// the first blip in the background: with no agent counted the keep-alive
  /// went off, the fleet suspended, and nothing reconnected when the network
  /// came back. A machine that needs the person (`attention`), is disabled or
  /// waits for a sign-in is not coming back by itself.
  static bool _recoverable(MachineConnection c) => switch (c.state) {
        LinkState.online || LinkState.connecting || LinkState.reconnecting || LinkState.offline => true,
        LinkState.attention || LinkState.disabled || LinkState.approval => false,
      };

  /// Agents to watch (working or blocked, terminal and session, on a machine
  /// whose link is up or coming back; a session reconnecting there is still
  /// worth keeping the connection for), and how many need the person: the [AttentionSet]'s
  /// count, the number the badge and the pill show.
  _Glance _countWatching() {
    var n = 0;
    for (final c in _fleet.connections) {
      if (!_recoverable(c)) continue;
      for (final p in c.snapshot.panes) {
        if (p.isAgent && (p.status == AgentStatus.blocked || p.status == AgentStatus.working)) n++;
      }
    }
    for (final s in _sessions?.sessions ?? const <AgentSessionView>[]) {
      if (_recoverable(s.machine) && s.phase != AgentPhase.idle) n++;
    }
    return (count: n, blocked: _attention.needsYou.length);
  }

  /// The agents in a state worth telling about, and the keys of those whose
  /// state is not known right now (a session that is attaching again).
  ({List<_Item> items, Set<String> unknown}) _collect() {
    final items = <_Item>[];
    final unknown = <String>{};
    for (final a in _fleet.agents) {
      final pane = a.pane;
      final machine = a.machine.profile;
      final key = '${machine.id}/${pane.id}';
      if (pane.status == AgentStatus.blocked) {
        items.add(_Item(
          key,
          NotifyKind.needsYou,
          reachable: !a.stale,
          id: () => notificationIdFor(key),
          title: () => _title(a.betterTitle ?? pane.title, _folder(pane.cwd), pane.agent ?? 'terminal'),
          body: () => 'needs you · ${pane.agent ?? 'terminal'} · ${machine.label}',
          link: () => agentLinkFor(machine.id, pane.id),
          pane: (machineId: machine.id, paneId: pane.id),
        ));
      } else if (a.toReview && _alsoDone) {
        items.add(_Item(
          key,
          NotifyKind.finished,
          reachable: !a.stale,
          id: () => notificationIdFor(key),
          title: () => _title(a.betterTitle ?? pane.title, _folder(pane.cwd), pane.agent ?? 'terminal'),
          body: () => 'done · ${pane.agent ?? 'terminal'} · ${machine.label}',
          link: () => agentLinkFor(machine.id, pane.id),
        ));
      }
    }
    for (final s in _sessions?.sessions ?? const <AgentSessionView>[]) {
      final reachable = AttentionSet.sessionReachable(s);
      final machine = s.machine.profile;
      final key = 'session/${s.key}';
      if (AttentionSet.sessionBlocked(s)) {
        items.add(_Item(
          key,
          NotifyKind.needsYou,
          reachable: reachable,
          id: () => notificationIdFor(key),
          title: () => _title(s.title, '', s.agentLabel),
          body: () => 'needs you · ${s.agentLabel} · ${machine.label}',
          link: () => _sessionLink(s),
        ));
      } else if (s.link == AgentLink.connecting || s.link == AgentLink.reconnecting) {
        // Attaching (again): what it shows says nothing about whether the
        // request is still there. Only a live state, or an ended or failed
        // session, is a verdict.
        unknown.add(key);
      } else if (AttentionSet.sessionToReview(s) && _alsoDone) {
        items.add(_Item(
          key,
          NotifyKind.finished,
          reachable: reachable,
          id: () => notificationIdFor(key),
          title: () => _title(s.title, '', s.agentLabel),
          body: () => 'done · ${s.agentLabel} · ${machine.label}',
          link: () => _sessionLink(s),
        ));
      }
    }
    return (items: items, unknown: unknown);
  }

  static String _sessionLink(AgentSessionView s) {
    final machineId = s.machine.profile.id;
    final prefix = '$machineId/';
    final keeper = s.key.startsWith(prefix) ? s.key.substring(prefix.length) : s.key;
    return sessionLinkFor(machineId, keeper);
  }

  static String _folder(String? cwd) {
    if (cwd == null) return '';
    final parts = cwd.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '' : parts.last;
  }

  /// The first non-empty of [title], [folder] and [agent], on one line and cut
  /// to [notifyTitleLength] characters.
  static String _title(String title, String folder, String agent) {
    for (final candidate in [title, folder, agent]) {
      final line = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      final runes = line.runes.toList();
      if (runes.length <= notifyTitleLength) return line;
      return '${String.fromCharCodes(runes.take(notifyTitleLength - 1))}…';
    }
    return 'agent';
  }

  // -- transitions ---------------------------------------------------------------

  /// The app went away: everything in a state worth telling about, as last
  /// known (an unreachable machine's too), is taken as seen, without a
  /// notification.
  void _baseline() {
    for (final item in _collect().items) {
      _tracks.putIfAbsent(item.key, () => _Track(item.kind, item.id()));
    }
  }

  /// The app is active: nothing is pending, nothing is shown.
  void _clear() {
    _tracks.clear();
    _announcedAt.clear();
    _burstStart = null;
    _burstPosted = 0;
    _summaryShown.clear();
    _flapTimer?.cancel();
    _flapTimer = null;
    unawaited(_safe(_notifier.cancelAll));
  }

  void _follow(({List<_Item> items, Set<String> unknown}) seen) {
    final now = _clock();
    final items = seen.items;
    final byKey = {for (final i in items) i.key: i};

    // Episodes that ended: the agent is seen in another state, or gone. One
    // that is merely out of reach, or not known right now, goes on.
    for (final entry in _tracks.entries.toList()) {
      final track = entry.value;
      final item = byKey[entry.key];
      if (item != null && item.kind == track.kind) continue;
      if (item == null && seen.unknown.contains(entry.key)) continue;
      _tracks.remove(entry.key);
      if (track.posted) unawaited(_safe(() => _notifier.cancel(track.id)));
    }

    _announcedAt.removeWhere((_, at) => now.difference(at) >= notifyFlapWindow);

    // A flapping agent whose minute is up.
    for (final entry in _tracks.entries) {
      final due = entry.value.due;
      if (due != null && !now.isBefore(due)) {
        entry.value.due = null;
        final item = byKey[entry.key]!;
        // Out of reach at the minute: nothing to announce, nothing to retry.
        if (item.reachable) _announce(entry.value, item, now);
      }
    }

    // New episodes: what needs the person first, and only what can be reached
    // (news from a link that is down is not news yet).
    final fresh = [
      for (final i in items)
        if (i.kind == NotifyKind.needsYou && i.reachable && !_tracks.containsKey(i.key)) i,
      for (final i in items)
        if (i.kind == NotifyKind.finished && i.reachable && !_tracks.containsKey(i.key)) i,
    ];
    for (final item in fresh) {
      final track = _tracks[item.key] = _Track(item.kind, item.id());
      if (!_canPost) continue;
      final last = _announcedAt['${item.key}|${item.kind.name}'];
      if (last != null && now.difference(last) < notifyFlapWindow) {
        track.due = last.add(notifyFlapWindow);
      } else {
        _announce(track, item, now);
      }
    }

    _updateSummaries();
    _armFlapTimer(now);
  }

  void _announce(_Track track, _Item item, DateTime now) {
    final start = _burstStart;
    if (start == null || now.difference(start) >= notifyBurstWindow) {
      _burstStart = now;
      _burstPosted = 0;
    }
    _announcedAt['${item.key}|${item.kind.name}'] = now;
    if (_burstPosted < notifyBurstLimit) {
      _burstPosted++;
      track.posted = true;
      final notification = AgentNotification(
        id: track.id,
        kind: item.kind,
        title: item.title(),
        body: item.body(),
        link: item.link(),
      );
      unawaited(_safe(() => _notifier.show(notification)));
      if (item.pane != null && item.kind == NotifyKind.needsYou) unawaited(_offerAnswers(track, item));
    } else {
      track.summarized = true;
    }
  }

  /// Reads the question of a terminal agent that was just announced and, if the
  /// app understands it, posts the notification again (same id, silently) with
  /// the question and what it is about in it, and buttons for its one-tap
  /// answers. The announcement itself does not wait for the read.
  Future<void> _offerAnswers(_Track track, _Item item) async {
    final answerer = _answerer;
    final visible = _visibleText;
    final pane = item.pane;
    if (answerer == null || visible == null || pane == null) return;
    PromptInfo? prompt;
    try {
      prompt = await answerer.promptOf(pane.machineId, pane.paneId);
    } on Object {
      return;
    }
    // Not for an episode that ended, or a notification the person has dealt
    // with (the app is open again) while the screen was being read.
    if (prompt == null || _disposed || !_canPost || !track.posted || _tracks[item.key] != track) return;
    final notification = _withQuestion(track, item, prompt, pane, visible);
    unawaited(_safe(() => _notifier.show(notification)));
  }

  AgentNotification _withQuestion(
    _Track track,
    _Item item,
    PromptInfo prompt,
    ({String machineId, String paneId}) pane,
    String Function(String) visible,
  ) {
    final question = visible(prompt.question);
    final subject = visible(prompt.subject);
    final subjectRows = subject.isEmpty ? const <String>[] : subject.split('\n');
    final buttons = <NotificationAnswer>[];
    // A command too long to be shown whole is not one to approve from here.
    if (subject.length <= notifyShownSubjectLength) {
      final nonce = '${_clock().microsecondsSinceEpoch.toRadixString(36)}-${_nonce++}';
      for (final (i, reply) in prompt.replies.indexed) {
        if (buttons.length == maxNotificationAnswers) break;
        if (!answerableFromNotification(reply)) continue;
        buttons.add(NotificationAnswer(
          machineId: pane.machineId,
          paneId: pane.paneId,
          digest: promptDigest(prompt),
          index: i,
          nonce: nonce,
          label: _cut(visible(reply.label), notifyButtonLength),
        ));
      }
    }
    return AgentNotification(
      id: track.id,
      kind: NotifyKind.needsYou,
      title: item.title(),
      body: [question, ?(subject.isEmpty ? null : subject), item.body()].join('\n'),
      collapsed: subjectRows.isEmpty
          ? question.split('\n').first
          : '${subjectRows.first}${subjectRows.length > 1 ? ' …' : ''}',
      link: item.link(),
      answers: buttons,
    );
  }

  /// A button was pressed (the notification is already gone). The answer is sent
  /// only if the pane still shows the question the button was made for; else
  /// the person is told that nothing was sent.
  Future<void> _answered(NotificationAnswer answer, int notificationId) async {
    final answerer = _answerer;
    if (_disposed || answerer == null) return;
    final outcome = await answerer.answer(answer);
    if (_disposed) return;
    switch (outcome) {
      case AnswerOutcome.duplicate:
        return;
      case AnswerOutcome.sent:
        // It is answered: the next question of this agent is news at once.
        _announcedAt.remove('${answer.machineId}/${answer.paneId}|${NotifyKind.needsYou.name}');
        unawaited(_safe(() => _notifier.cancel(notificationId)));
      case AnswerOutcome.changed || AnswerOutcome.unreachable:
        final machine = _fleet.connection(answer.machineId)?.profile.label;
        final notification = AgentNotification(
          id: notificationId,
          kind: NotifyKind.needsYou,
          title: answerNotSentTitle,
          body: outcome == AnswerOutcome.changed
              ? 'The question changed, so nothing was sent. Tap to see it.'
              : 'Could not reach ${machine ?? 'the machine'}, so nothing was sent. Tap to open the agent.',
          link: agentLinkFor(answer.machineId, answer.paneId),
        );
        unawaited(_safe(() => _notifier.show(notification)));
    }
  }

  /// [s] cut to [max] characters, with an ellipsis.
  static String _cut(String s, int max) {
    final runes = s.runes.toList();
    return runes.length <= max ? s : '${String.fromCharCodes(runes.take(max - 1))}…';
  }

  /// One summary per kind for the agents the burst limit held back ("N agents
  /// need you", "N agents finished"): how many there are now (those with a
  /// notification of their own too), replaced as that changes, gone when none
  /// of the held-back ones is left. No episode is dropped silently.
  void _updateSummaries() {
    for (final kind in NotifyKind.values) {
      var held = false;
      var count = 0;
      for (final t in _tracks.values) {
        if (t.kind != kind) continue;
        if (t.summarized) held = true;
        if (t.summarized || t.posted) count++;
      }
      final want = held ? count : null;
      if (want == _summaryShown[kind]) continue;
      _summaryShown[kind] = want;
      final id = _summaryIds[kind]!;
      if (want == null) {
        unawaited(_safe(() => _notifier.cancel(id)));
        continue;
      }
      final notification = AgentNotification(
        id: id,
        kind: kind,
        title: switch (kind) {
          NotifyKind.needsYou => '$want agents need you',
          NotifyKind.finished => '$want agents finished',
        },
        body: 'Open herdr to see which',
        link: agentsBoardLink,
      );
      unawaited(_safe(() => _notifier.show(notification)));
    }
  }

  void _armFlapTimer(DateTime now) {
    DateTime? next;
    for (final t in _tracks.values) {
      final due = t.due;
      if (due != null && (next == null || due.isBefore(next))) next = due;
    }
    _flapTimer?.cancel();
    _flapTimer = null;
    if (next == null) return;
    _flapTimer = Timer(next.difference(now), () {
      _flapTimer = null;
      _evaluate();
    });
  }

  // -- watching ------------------------------------------------------------------

  void _syncWatching({bool immediate = false}) {
    if (_desired.count == 0) _keepAlive(false);
    _pushWatching(immediate: immediate);
  }

  void _pushWatching({bool immediate = false}) {
    if (_calling) return; // asks again when the call is done
    if (_desired == _applied) {
      _keepAlive(_applied.count > 0);
      return;
    }
    if (_refused) {
      if (_desired.count == 0) {
        // Nothing was started, so there is nothing to stop.
        _refused = false;
        _applied = _noGlance;
      }
      return;
    }
    final last = _lastWatchCall;
    if (!immediate && last != null) {
      final wait = watchingDebounce - _clock().difference(last);
      if (wait > Duration.zero) {
        _watchTimer ??= Timer(wait, () {
          _watchTimer = null;
          _pushWatching();
        });
        return;
      }
    }
    unawaited(_applyWatching(_desired));
  }

  Future<void> _applyWatching(_Glance glance) async {
    _calling = true;
    _watchTimer?.cancel();
    _watchTimer = null;
    _lastWatchCall = _clock();
    var ok = false;
    try {
      ok = await _notifier.setWatching(glance.count, blocked: glance.blocked);
    } on Object {
      ok = false;
    }
    _calling = false;
    if (_disposed) return;
    if (glance.count == 0) {
      _applied = _noGlance; // a stop returns false by contract: it is not a refusal
    } else if (ok) {
      _applied = glance;
      _refused = false;
    } else {
      _applied = _noGlance;
      _refused = true;
    }
    _keepAlive(_desired.count > 0 && _applied.count > 0);
    _pushWatching();
  }

  /// The connections and the sessions are kept (or let go) together.
  void _keepAlive(bool on) {
    _fleet.keepAliveInBackground = on;
    _sessions?.keepAliveInBackground = on;
  }

  Future<void> _safe(Future<void> Function() call) async {
    try {
      await call();
    } on Object {
      // A notification that cannot be posted or cancelled is not worth a crash.
    }
  }
}

/// One agent in a state worth telling about, as of one look at the fleet.
class _Item {
  _Item(
    this.key,
    this.kind, {
    required this.reachable,
    required this.id,
    required this.title,
    required this.body,
    required this.link,
    this.pane,
  });

  final String key;
  final NotifyKind kind;

  /// On a machine that can be reached now. News from one that cannot is not
  /// news yet (and cannot be answered from here).
  final bool reachable;
  final int Function() id;
  final String Function() title;
  final String Function() body;
  final String Function() link;

  /// The pane of a terminal agent, whose question can be read and answered
  /// from here. Null for a session and for a finished agent.
  final ({String machineId, String paneId})? pane;
}

/// What is known of one agent's episode in a state: told about, taken as seen,
/// held back by the burst limit or by the flap window.
class _Track {
  _Track(this.kind, this.id);

  final NotifyKind kind;
  final int id;

  /// A notification of its own is showing.
  bool posted = false;

  /// Held back by the burst limit: counted in the summary.
  bool summarized = false;

  /// A flapping agent is announced at this time, if it is still in the state.
  DateTime? due;
}
