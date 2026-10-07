import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart';
import '../models/machine_profile.dart';
import '../models/status_time.dart';
import '../services/aligned_ticker.dart';
import '../services/auth_notice.dart';
import '../services/herdr_api.dart';
import '../services/herdr_transport.dart';
import '../services/remote_files.dart';
import '../services/snapshot_cache.dart';
import 'reviewed_state.dart';

enum LinkState {
  /// First connection attempt in flight.
  connecting,

  /// Snapshot fresh, event stream live.
  online,

  /// Lost; retrying with backoff. Last snapshot is stale.
  reconnecting,

  /// Needs user action (bad credentials, changed host key, no bridge).
  attention,

  disabled,

  /// The device has no network. Not retrying until it returns.
  offline,

  /// The server wants a person to approve this sign-in at a link (Tailscale
  /// SSH check mode). The connection is waiting, not failing.
  approval,
}

Duration defaultBackoff(int attempt) =>
    Duration(seconds: const [1, 2, 4, 8, 15, 30][attempt.clamp(0, 5)]);

/// The retry delays in the background profile: nobody is looking, so a machine
/// that does not answer is tried at most every 5 minutes.
Duration defaultBackgroundBackoff(int attempt) =>
    Duration(seconds: const [30, 60, 120, 300][attempt.clamp(0, 3)]);

/// Live state of one herdr machine: keeps a snapshot fresh from the event
/// stream, reconnecting independently of every other machine.
///
/// Listeners are notified only when something observable changed: the link
/// state, the error, or a snapshot that differs from the previous one.
class MachineConnection extends ChangeNotifier {
  MachineConnection({
    required this.profile,
    required this._api,
    this._cache,
    this.backoff = defaultBackoff,
    this.pollInterval = const Duration(seconds: 20),
    this.backgroundPollInterval = const Duration(minutes: 4),
    this.backgroundBackoff = defaultBackgroundBackoff,
    this.structuralDelay = const Duration(milliseconds: 150),
    this.churnInterval = const Duration(milliseconds: 1500),
    this.cacheWriteInterval = const Duration(seconds: 5),
    this.observationGap = const Duration(minutes: 1),
    this.quietAfter = const Duration(minutes: 5),
    this.seenWriteInterval = const Duration(minutes: 2),
    this._clock = DateTime.now,
  });

  final DateTime Function() _clock;

  final MachineProfile profile;
  final HerdrApi _api;
  final SnapshotCache? _cache;
  final Duration Function(int attempt) backoff;

  /// Safety net in case an event is ever missed.
  final Duration pollInterval;

  /// The safety-net poll's spacing while the app is in the background.
  final Duration backgroundPollInterval;

  /// Retry delays while the app is in the background and the connection is
  /// kept alive; the longer of this and [backoff] applies.
  final Duration Function(int attempt) backgroundBackoff;

  /// Delay before refreshing after a structural or status event.
  final Duration structuralDelay;

  /// Minimum spacing of refreshes caused only by `pane_updated` (title and
  /// spinner churn from busy agents, which never stops).
  final Duration churnInterval;

  /// Minimum spacing of snapshot cache writes.
  final Duration cacheWriteInterval;

  /// A status change found this long after the previous snapshot, without the
  /// event stream having been live in between, is dated as a bound (`≤ 25m`)
  /// instead of as having just happened.
  final Duration observationGap;

  /// A working agent with no `pane_updated` for this long is quiet.
  final Duration quietAfter;

  /// Minimum spacing of cache writes that only refresh the time the panes were
  /// last seen (nothing else changed).
  final Duration seenWriteInterval;

  LinkState _state = LinkState.connecting;
  String? _approvalUrl;
  String? _error;

  /// What herdr last said, untouched: what the cache stores and what status
  /// changes are dated against.
  Snapshot _raw = Snapshot.empty;

  /// What the app shows: [_raw], with every finished agent the person has
  /// reviewed shown as idle (see [ReviewedState]).
  Snapshot _snapshot = Snapshot.empty;
  ReviewedState? _reviewed;
  DateTime? _lastSync;
  bool _disposed = false;
  bool _forgotten = false;
  bool _seeding = false;

  /// Identifies the connect loop that may touch state. Bumped whenever the
  /// loop is stopped or replaced, so a loop still unwinding (awaiting a
  /// cancel, a request) can never act alongside its successor.
  int _epoch = 0;
  bool _looping = false;
  Completer<void>? _wake;
  Completer<void>? _watchEnd;

  Timer? _persistTimer;
  bool _persistDirty = false;

  /// Per pane: its status and what is known of when it began.
  final Map<String, ObservedStatus> _statusSince = {};

  /// When the panes were last seen (a live snapshot, or the cache record this
  /// connection started from), and the event stream that was live then.
  DateTime? _seenAt;
  Completer<void>? _seenWatch;
  DateTime? _lastPersistAt;

  /// Last `pane_updated` per pane since the event stream went live. A plain
  /// map write per event: nobody is notified, the board reads the result at
  /// its next refresh.
  final Map<String, DateTime> _lastEvent = {};

  /// When the current event stream went live; null while there is none (before
  /// the first connect, while reconnecting, offline, suspended). An agent can
  /// only be called quiet for a time somebody was listening: nothing is quiet
  /// until the stream has been live for [quietAfter].
  DateTime? _streamLiveAt;

  /// Whole minutes of quiet per working pane, as of the last refresh and only
  /// for panes quiet for [quietAfter] or more.
  Map<String, int> _quiet = const {};

  final _activity = StreamController<String>.broadcast();

  /// Emits a pane id whenever herdr reports activity (`pane_updated`) on it.
  /// Broadcast; lets a pane view re-read on change instead of blind polling.
  Stream<String> get paneActivity => _activity.stream;

  HerdrApi get api => _api;

  /// Browse and read this machine's files (SFTP over the same connection).
  RemoteFiles get files => _api.files;
  LinkState get state => _state;
  String? get error => _error;

  /// What the app shows of the machine: herdr's snapshot with the agents the
  /// person has reviewed as idle instead of done, in panes and in the
  /// workspace and tab roll-ups. Every screen reads this, so they agree.
  Snapshot get snapshot => _snapshot;
  DateTime? get lastSync => _lastSync;
  bool get isLive => _state == LinkState.online;

  bool _background = false;

  /// The panes the live subscription names for their status (the background
  /// profile), or null when it is the full one.
  Set<String>? _subscribedPanes;
  bool _resubscribing = false;

  /// The app is in the background with the connection kept alive (someone is
  /// watching for agents): the event subscription becomes status-only (no
  /// `pane.updated`, one `pane.agent_status_changed` per agent pane), the
  /// transport relaxes its heartbeats, the safety-net poll runs every
  /// [backgroundPollInterval] and a failing connection retries on
  /// [backgroundBackoff]. The fleet sets it on backgrounding and clears it on
  /// resume; either way the stream is replaced and one refresh follows.
  void setBackground(bool value) {
    if (_background == value) return;
    _background = value;
    _api.setBackground(value);
    _resubscribe();
  }

  /// The wait before retry number [attempt]: the ordinary back-off, or in the
  /// background the longer one, so a machine that sleeps is not tried every
  /// 30 s all night.
  Duration _retryDelay(int attempt) {
    final normal = backoff(attempt);
    if (!_background) return normal;
    final slow = backgroundBackoff(attempt);
    return slow > normal ? slow : normal;
  }

  /// [id] in the last snapshot, if herdr still has it.
  Pane? paneById(String id) {
    for (final pane in _snapshot.panes) {
      if (pane.id == id) return pane;
    }
    return null;
  }

  /// The panes in which a keeper of this machine shows its agent session on
  /// the computer (the keeper's `view`, which reports itself to herdr as an
  /// agent). Set from each `list` by the agent sessions; see [agentPanes].
  Set<String> get keeperPanes => _keeperPanes;
  Set<String> _keeperPanes = const {};

  void setKeeperPanes(Set<String> panes) {
    if (_disposed || setEquals(panes, _keeperPanes)) return;
    _keeperPanes = panes;
    notifyListeners();
  }

  /// The terminal agents of [snapshot]: its agent panes but a keeper's view
  /// pane, whose session the board, the counts and the notifications already
  /// carry as an agent session (it would be the same agent twice).
  List<Pane> get agentPanes {
    final all = _snapshot.agentPanes;
    if (_keeperPanes.isEmpty) return all;
    return [for (final p in all) if (!_keeperPanes.contains(p.id)) p];
  }

  /// Whether input can reach pane [id]: the machine is live and the pane exists.
  bool acceptsInput(String id) => isLive && paneById(id) != null;

  /// Uses [reviewed] to show finished agents the person has looked at as idle.
  void attachReviewed(ReviewedState? reviewed) {
    if (identical(reviewed, _reviewed)) return;
    _reviewed?.removeListener(_onReviewedChanged);
    _reviewed = reviewed?..addListener(_onReviewedChanged);
    _onReviewedChanged();
  }

  /// The person looked at (opened, answered) [paneId]: if herdr says it is
  /// done, that finished state is reviewed and shows as idle from now on.
  /// herdr is not told. Returns whether anything changed.
  bool markReviewed(String paneId) {
    final reviewed = _reviewed;
    if (reviewed == null) return false;
    for (final p in _raw.panes) {
      if (p.id != paneId) continue;
      return p.status == AgentStatus.done &&
          reviewed.review(profile.id, paneId, _completionKey(p));
    }
    return false;
  }

  /// Takes back [markReviewed]: the pane's current finished state shows as done
  /// again. Does nothing (false) unless that very state is the reviewed one: a
  /// pane that has since left `done` or finished anew keeps whatever it has.
  bool unmarkReviewed(String paneId) {
    final reviewed = _reviewed;
    if (reviewed == null) return false;
    for (final p in _raw.panes) {
      if (p.id != paneId) continue;
      if (p.status != AgentStatus.done || !reviewed.isReviewed(profile.id, paneId, _completionKey(p))) {
        return false;
      }
      reviewed.unmark(profile.id, paneId);
      _onReviewedChanged();
      return true;
    }
    return false;
  }

  void _onReviewedChanged() {
    if (_disposed) return;
    final shown = _present(_raw);
    if (shown == _snapshot) return;
    _snapshot = shown;
    notifyListeners();
  }

  /// Names the finished state [p] is in: herdr's `completion_seq`, else when
  /// the state was observed to begin, else a per-pane marker (a pane already
  /// done when first seen, with a herdr that sends no sequence).
  String _completionKey(Pane p) {
    if (p.completionSeq case final seq?) return 'seq:$seq';
    if (_statusSince[p.id]?.since case final since?) {
      return 't:${since.at.millisecondsSinceEpoch}';
    }
    return 'pane';
  }

  /// [raw] as the app shows it: reviewed `done` becomes `idle`, and a
  /// workspace or tab whose roll-up was that `done` is worked out again from
  /// what its panes now show (herdr ranks blocked, done, working, idle).
  Snapshot _present(Snapshot raw) {
    final reviewed = _reviewed;
    if (reviewed == null) return raw;
    List<Pane>? panes;
    for (var i = 0; i < raw.panes.length; i++) {
      final p = raw.panes[i];
      if (p.status == AgentStatus.done &&
          reviewed.isReviewed(profile.id, p.id, _completionKey(p))) {
        (panes ??= List.of(raw.panes))[i] = p.withStatus(AgentStatus.idle);
      }
    }
    if (panes == null) return raw;
    AgentStatus rollup(bool Function(Pane) inGroup) {
      var best = AgentStatus.unknown;
      for (final p in panes!) {
        if (inGroup(p) && _rollupRank(p.status) > _rollupRank(best)) best = p.status;
      }
      return best;
    }

    return Snapshot(
      version: raw.version,
      workspaces: [
        for (final w in raw.workspaces)
          w.status == AgentStatus.done
              ? w.withStatus(rollup((p) => p.workspaceId == w.id))
              : w,
      ],
      tabs: [
        for (final t in raw.tabs)
          t.status == AgentStatus.done ? t.withStatus(rollup((p) => p.tabId == t.id)) : t,
      ],
      panes: panes,
    );
  }

  static int _rollupRank(AgentStatus s) => switch (s) {
        AgentStatus.blocked => 4,
        AgentStatus.done => 3,
        AgentStatus.working => 2,
        AgentStatus.idle => 1,
        AgentStatus.unknown => 0,
      };

  /// The `https` link to approve a sign-in at, while [state] is
  /// [LinkState.approval]; null otherwise.
  String? get approvalUrl => _state == LinkState.approval ? _approvalUrl : null;

  void start() {
    if (_disposed) return;
    if (!profile.enabled) {
      _set(LinkState.disabled);
      return;
    }
    _seedFromCache();
    _startLoop();
  }

  /// Retry now (skip backoff, or leave `attention`).
  void retry() {
    if (_disposed) return;
    if (_looping) {
      _wakeUp();
    } else {
      start();
    }
  }

  /// Re-fetch the snapshot immediately (pull to refresh).
  Future<void> refresh() => _refresh();

  /// The device lost its network: stop retrying, keep the stale snapshot.
  /// `attention` stays, since the network is not what needs fixing.
  void goOffline() {
    if (_disposed) return;
    if (!profile.enabled) {
      _set(LinkState.disabled);
      return;
    }
    if (_state == LinkState.attention) return;
    _seedFromCache();
    _stopLoop();
    _set(LinkState.offline);
  }

  /// The socket is presumed dead (network switched, app was suspended): drop
  /// it now and reconnect immediately, without waiting out a backoff.
  void reconnect() {
    if (_disposed || _state == LinkState.attention) return;
    _stopLoop();
    _api.reset();
    start();
  }

  /// Tears the connection down without retrying (long time in background);
  /// [reconnect] or [retry] brings it back.
  void suspend() {
    if (_disposed) return;
    if (_state case LinkState.attention || LinkState.disabled || LinkState.offline) {
      return;
    }
    _stopLoop();
    _api.reset();
    _set(LinkState.reconnecting, error: _error);
  }

  /// The machine was removed: drop its cached snapshot for good.
  void forget() {
    _forgotten = true;
    _reviewed?.forgetMachine(profile.id);
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistDirty = false;
    final cache = _cache;
    if (cache != null) {
      unawaited(cache.delete(profile.id).catchError((Object _) {}));
    }
  }

  void _startLoop() {
    if (_looping) return;
    _looping = true;
    unawaited(_run(++_epoch));
  }

  void _stopLoop() {
    _epoch++;
    _looping = false;
    _resubscribing = false;
    _dropStream();
    _wakeUp();
    final end = _watchEnd;
    if (end != null && !end.isCompleted) end.complete();
  }

  /// There is no live event stream (any more): nothing seen before counts
  /// towards quiet, and none is claimed until a new stream has proven itself.
  void _dropStream() {
    _streamLiveAt = null;
    _lastEvent.clear();
  }

  void _wakeUp() {
    if (_wake case final wake? when !wake.isCompleted) wake.complete();
  }

  Future<void> _run(int epoch) async {
    bool alive() => !_disposed && epoch == _epoch;
    var attempt = 0;
    var raced = 0;
    try {
      while (alive()) {
        String? error;
        try {
          _dropStream();
          _set(
            attempt == 0 && _lastSync == null
                ? LinkState.connecting
                : LinkState.reconnecting,
            error: _error,
          );
          await _refresh();
          if (!alive()) return;
          _set(LinkState.online);
          attempt = 0;
          await _watch();
          while (alive() && _resubscribing) {
            _resubscribing = false;
            await _watch(gap: true);
          }
          raced = 0;
          if (!alive()) return;
          error = 'Connection closed';
        } on HerdrTransportException catch (e) {
          if (!alive()) return;
          if (e.fatal) {
            _set(LinkState.attention, error: e.message);
            return;
          }
          error = e.message;
        } on HerdrApiException catch (e) {
          if (!alive()) return;
          // The status-only subscription named a pane that closed after the
          // snapshot: take the snapshot again, at once (twice at most).
          if (e.code == 'pane_not_found' && _background && raced++ < 2) {
            continue;
          }
          error = e.toString();
        }
        _set(LinkState.reconnecting, error: error);
        await _sleep(_retryDelay(attempt++));
      }
    } finally {
      if (epoch == _epoch) _looping = false;
    }
  }

  Future<void> _sleep(Duration d) async {
    final wake = _wake = Completer<void>();
    final timer = Timer(d, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    if (identical(_wake, wake)) _wake = null;
  }

  Future<void> _refresh() async {
    final s = await _api.snapshot();
    if (_disposed) return;
    _lastSync = DateTime.now();
    final now = _clock();
    final rawChanged = s != _raw;
    _trackStatuses(s, now);
    _raw = s;
    _checkSubscription();
    _endStaleReviews(s);
    final quietChanged = _evaluateQuiet(s, now);
    final shown = _present(s);
    final shownChanged = shown != _snapshot;
    if (!rawChanged && !shownChanged && !quietChanged) {
      // Nothing to show, but the time the panes were last seen moved on.
      final written = _lastPersistAt;
      if (written == null || now.difference(written) >= seenWriteInterval) _persist();
      return;
    }
    _snapshot = shown;
    if (rawChanged) _persist();
    notifyListeners();
  }

  /// What a live snapshot (never the cache seed) says about reviews: a pane
  /// herdr no longer has loses its mark, and so does a pane seen in any status
  /// but done. A review names one finished state; once the pane has left it,
  /// the mark must not be able to match a later one (herdr's `completion_seq`
  /// starts again at 0 whenever its server restarts, and a pane with no
  /// sequence has nothing else to tell its finishes apart).
  void _endStaleReviews(Snapshot live) {
    final reviewed = _reviewed;
    if (reviewed == null) return;
    reviewed.prune(profile.id, {for (final p in live.panes) p.id});
    for (final p in live.panes) {
      if (p.status != AgentStatus.done) reviewed.unmark(profile.id, p.id);
    }
  }

  /// Remembers when each pane was first seen in its current status. Runs on
  /// every live snapshot, even an unchanged one (the first live snapshot
  /// often equals the cached one).
  ///
  /// A change is dated by how it was found. Seen with the event stream live
  /// since the previous snapshot (or within [observationGap] of it): it
  /// happened just now ([StatusTime.exact]). Found after a longer gap
  /// (suspended, offline, restarted): it happened some time after the pane
  /// was last seen, and that is all that is known ([StatusTime.after]).
  /// Panes already there at the very first sight (no cache either) have no
  /// known start. A pane whose status did not change keeps what it had,
  /// including across a restart (the cache record seeds it).
  void _trackStatuses(Snapshot s, DateTime now) {
    final seen = _seenAt;
    final watch = _watchEnd;
    final live = watch != null && !watch.isCompleted;
    final StatusTime? changed;
    if (seen == null) {
      changed = null;
    } else if ((live && identical(watch, _seenWatch)) ||
        now.difference(seen) <= observationGap) {
      changed = StatusTime.exact(now);
    } else {
      changed = StatusTime.after(seen);
    }
    final next = <String, ObservedStatus>{};
    for (final p in s.panes) {
      final known = _statusSince[p.id];
      next[p.id] = known != null && known.status == p.status
          ? known
          : (status: p.status, since: changed);
    }
    _statusSince
      ..clear()
      ..addAll(next);
    _seenAt = now;
    _seenWatch = live ? watch : null;
  }

  /// Works out which working panes have gone quiet, as whole minutes. Runs
  /// with every refresh (status changes and the poll) and nowhere else, so the
  /// board's order cannot move because of an event. Returns whether the
  /// answer differs from the last one.
  bool _evaluateQuiet(Snapshot s, DateTime now) {
    final ids = {for (final p in s.panes) p.id};
    _lastEvent.removeWhere((id, _) => !ids.contains(id));
    final next = <String, int>{};
    for (final p in s.panes) {
      if (p.status != AgentStatus.working) continue;
      final active = lastActivity(p.id);
      if (active == null) continue;
      final quiet = now.difference(active);
      if (quiet >= quietAfter) next[p.id] = quiet.inMinutes;
    }
    final changed = !mapEquals(next, _quiet);
    _quiet = next;
    return changed;
  }

  /// Whole minutes [paneId] has been quiet as of the last refresh; 0 unless it
  /// is working and has been quiet for [quietAfter] or more.
  int quietMinutes(String paneId) => _quiet[paneId] ?? 0;

  /// The last time [paneId] was seen doing something while the event stream
  /// was live: the latest of its last `pane_updated`, the stream going live,
  /// and its working state being seen to begin. Null while there is no live
  /// stream (an agent cannot be called quiet for a time nobody was listening,
  /// so nothing from before a (re)connect counts).
  DateTime? lastActivity(String paneId) {
    var latest = _streamLiveAt;
    if (latest == null) return null;
    final since = _statusSince[paneId]?.since;
    for (final at in [_lastEvent[paneId], if (since != null && since.exact) since.at]) {
      if (at != null && at.isAfter(latest!)) latest = at;
    }
    return latest;
  }

  /// When this app learned [paneId] entered its current status, and whether
  /// that is exact or only a bound; null if nothing is known (the pane was
  /// already in it at the first connection, or is unknown).
  StatusTime? statusTime(String paneId) => _statusSince[paneId]?.since;

  /// [statusTime]'s moment: the start, or for a bound the earliest it can be.
  DateTime? statusSince(String paneId) => statusTime(paneId)?.at;

  /// How long [paneId] has been in its current status, as observed (for a
  /// bound, since it was last seen otherwise); null when [statusTime] is.
  Duration? timeInStatus(String paneId) => statusTime(paneId)?.since(_clock());

  /// Watches the event stream until it ends. With [gap] the stream was just
  /// replaced (the profile changed, or the panes to name changed): whatever
  /// happened between the two subscriptions is caught by one refresh.
  Future<void> _watch({bool gap = false}) async {
    final end = _watchEnd = Completer<void>();
    // `_watch` follows a successful snapshot with nothing in between: the
    // stream is live from that snapshot on.
    _streamLiveAt = _clock();
    _lastEvent.clear();
    if (_seenAt != null) _seenWatch = end;
    void fail(Object e) {
      if (!end.isCompleted) end.completeError(e);
    }

    final refresher = _RefreshScheduler(
      urgentDelay: structuralDelay,
      churnDelay: churnInterval,
      refresh: _refresh,
      onError: fail,
    );
    // In the background only structure and status changes are asked for (see
    // [HerdrApi.changes]); the panes named come from the snapshot just taken.
    final panes = _background ? _agentPaneIds(_raw) : null;
    _subscribedPanes = panes;
    final sub = _api.changes(statusPanes: panes).listen(
          (event) => _onEvent(event, refresher),
          onError: fail,
          onDone: () {
            if (!end.isCompleted) end.complete();
          },
        );
    if (gap) refresher.schedule(urgent: true);
    // In the background the poll falls on the grid every machine and the agent
    // sessions share (see [AlignedTicker]): one radio wake-up for all of them.
    final void Function() stopPoll;
    if (_background) {
      final ticker = AlignedTicker(
        backgroundPollInterval,
        _clock,
        () => refresher.schedule(urgent: true),
      );
      stopPoll = ticker.cancel;
    } else {
      final timer = Timer.periodic(pollInterval, (_) => refresher.schedule(urgent: true));
      stopPoll = timer.cancel;
    }
    try {
      await end.future;
    } finally {
      stopPoll();
      refresher.close();
      if (identical(_watchEnd, end)) {
        _watchEnd = null;
        _subscribedPanes = null;
        _dropStream();
      }
      await sub.cancel();
    }
  }

  static Set<String> _agentPaneIds(Snapshot s) => {for (final p in s.agentPanes) p.id};

  /// The panes the status-only subscription names no longer match the panes
  /// that have an agent: subscribe again (herdr takes the list once, and it
  /// rejects a pane that is gone).
  void _checkSubscription() {
    final named = _subscribedPanes;
    if (named == null || !_background) return;
    final wanted = _agentPaneIds(_raw);
    if (named.length == wanted.length && named.containsAll(wanted)) return;
    _resubscribe();
  }

  /// Ends the watch without an error; [_run] watches again at once.
  void _resubscribe() {
    final end = _watchEnd;
    if (end == null || end.isCompleted) return;
    _resubscribing = true;
    end.complete();
  }

  /// Structure, agent detection and worktree events always warrant a quick
  /// refresh. `pane_updated` fires continuously for busy agents (spinner
  /// frames, every keystroke) but carries the whole pane, so it is compared
  /// with what we already know instead of blindly refetching:
  ///
  ///  * identical once normalised (spinner/revision churn) -> nothing to do;
  ///  * status or agent changed (e.g. working -> blocked)    -> refresh now;
  ///  * anything else (title, cwd)                            -> throttled.
  void _onEvent(Map<String, dynamic> event, _RefreshScheduler refresher) {
    if (event['event'] != 'pane_updated') {
      refresher.schedule(urgent: true);
      return;
    }
    // The background profile does not ask for `pane_updated`: one that still
    // arrives (a subscription being replaced) is churn, and never wakes a
    // refresh. A change of status comes as its own event.
    if (_background) return;

    final raw = switch (event) {
      {'data': {'pane': final Map<String, dynamic> pane}} => pane,
      _ => null,
    };
    // Activity first: an open pane view needs the signal even when the rest
    // of the payload is not something we can interpret.
    if (raw?['pane_id'] case final String id) {
      _lastEvent[id] = _clock();
      if (!_activity.isClosed) _activity.add(id);
    }

    final updated = _parsePane(raw);
    if (updated == null) {
      refresher.schedule(urgent: false);
      return;
    }
    // Against what herdr said, not what is shown (a reviewed done is idle
    // there). An event pane has no completion sequence of its own.
    final known = _raw.panes.where((p) => p.id == updated.id).firstOrNull;
    if (known == null || known.status != updated.status || known.agent != updated.agent) {
      refresher.schedule(urgent: true);
    } else if (known != updated.withCompletionSeq(known.completionSeq)) {
      refresher.schedule(urgent: false);
    }
  }

  static Pane? _parsePane(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    try {
      return Pane.fromJson(raw);
    } on Object {
      return null;
    }
  }

  /// Shows the last known snapshot while the first connection is still
  /// being made. Never overrides a fresh one.
  void _seedFromCache() {
    final cache = _cache;
    if (cache == null || _seeding) return;
    _seeding = true;
    unawaited(() async {
      final CachedSnapshot? cached;
      try {
        cached = await cache.read(profile.id);
      } on Object {
        return;
      }
      if (cached == null || _disposed || _forgotten || _lastSync != null) return;
      _raw = cached.snapshot;
      // What the panes were doing, and since when, as of the last time this
      // machine was seen: a state that is unchanged keeps its time.
      if (cached.observed case final observed? when _seenAt == null) {
        _statusSince.addAll(observed.panes);
        _seenAt = observed.seenAt;
      }
      _snapshot = _present(_raw);
      notifyListeners();
    }());
  }

  /// At most one write per [cacheWriteInterval]: the first goes out at once,
  /// later changes are coalesced into one trailing write.
  void _persist() {
    final cache = _cache;
    if (cache == null || _forgotten) return;
    if (_persistTimer != null) {
      _persistDirty = true;
      return;
    }
    _persistDirty = false;
    _lastPersistAt = _clock();
    unawaited(cache.write(profile.id, _raw, observed: _observed()).catchError((Object _) {}));
    _persistTimer = Timer(cacheWriteInterval, () {
      _persistTimer = null;
      if (_persistDirty) _persist();
    });
  }

  /// What the cache keeps beside the snapshot; null before the first sight.
  ObservedStatuses? _observed() {
    final seen = _seenAt;
    return seen == null
        ? null
        : ObservedStatuses(seenAt: seen, panes: Map.of(_statusSince));
  }

  void _set(LinkState s, {String? error}) {
    if (_disposed || (_state == s && _error == error)) return;
    if (s != LinkState.approval) _approvalUrl = null;
    _state = s;
    _error = error;
    notifyListeners();
  }

  /// The server showed a login banner while connecting. If it carries a
  /// sign-in link (Tailscale SSH check mode), the connection waits for a person:
  /// surface the link so the UI can send them to approve it.
  void onAuthNotice(String banner) {
    if (_disposed) return;
    final url = approvalUrlFrom(banner);
    if (url == null) return;
    final changed = url != _approvalUrl;
    _approvalUrl = url;
    if (_state == LinkState.approval) {
      if (changed) notifyListeners();
      return;
    }
    _set(LinkState.approval);
  }

  @override
  void dispose() {
    _disposed = true;
    _stopLoop();
    _persistTimer?.cancel();
    final cache = _cache;
    if (cache != null && _persistDirty && !_forgotten) {
      unawaited(cache.write(profile.id, _raw, observed: _observed()).catchError((Object _) {}));
    }
    _reviewed?.removeListener(_onReviewedChanged);
    unawaited(_activity.close());
    unawaited(_api.close());
    super.dispose();
  }
}

/// Throttles snapshot refreshes (never a debounce: busy agents emit events
/// continuously, and a timer reset per event would starve the refresh).
///
/// Urgent events refresh after [urgentDelay]; non-urgent ones are spaced
/// [churnDelay] apart, but an urgent event pulls a pending churn refresh
/// forward. Events arriving during a refresh yield one trailing refresh.
class _RefreshScheduler {
  _RefreshScheduler({
    required this.urgentDelay,
    required this.churnDelay,
    required this.refresh,
    required this.onError,
  });

  final Duration urgentDelay;
  final Duration churnDelay;
  final Future<void> Function() refresh;
  final void Function(Object) onError;

  Timer? _timer;
  bool _timerUrgent = false;
  bool _inFlight = false;
  bool _pending = false;
  bool _pendingUrgent = false;
  bool _closed = false;

  void schedule({required bool urgent}) {
    if (_closed) return;
    if (_inFlight) {
      _pending = true;
      _pendingUrgent = _pendingUrgent || urgent;
      return;
    }
    if (_timer case final timer?) {
      if (!urgent || _timerUrgent) return;
      timer.cancel();
    }
    _timerUrgent = urgent;
    _timer = Timer(urgent ? urgentDelay : churnDelay, _run);
  }

  Future<void> _run() async {
    _timer = null;
    _inFlight = true;
    try {
      await refresh();
    } on Object catch (e) {
      if (!_closed) onError(e);
      return;
    } finally {
      _inFlight = false;
    }
    if (_closed || !_pending) return;
    final urgent = _pendingUrgent;
    _pending = _pendingUrgent = false;
    schedule(urgent: urgent);
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
