import 'dart:async';

import 'package:flutter/foundation.dart';

import '../host/host_ports.dart';
import '../models/herdr_models.dart';
import '../models/machine_profile.dart';
import '../models/places.dart';
import '../models/status_time.dart';
import '../models/worktrees.dart';
import '../services/aligned_ticker.dart';
import '../services/auth_notice.dart';
import '../services/herdr_api.dart';
import '../services/herdr_transport.dart';
import '../services/remote_files.dart';
import '../services/snapshot_cache.dart';
import '../words/error_words.dart';
import 'reviewed_state.dart';
import 'screen_waits.dart';
import 'web_preview.dart';

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

/// How long an event stream must stay up (or deliver an event) before the
/// retry delays start over. The longest delay is 30 s: a stream that lives
/// that long was not the failure the delays are there to space out.
const _streamProvenAfter = Duration(seconds: 30);

Duration defaultBackoff(int attempt) => Duration(seconds: const [1, 2, 4, 8, 15, 30][attempt.clamp(0, 5)]);

/// The retry delays in the background profile: nobody is looking, so a machine
/// that does not answer is tried at most every 5 minutes.
Duration defaultBackgroundBackoff(int attempt) => Duration(seconds: const [30, 60, 120, 300][attempt.clamp(0, 3)]);

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
    this.screenWaits = const {},
  });

  final DateTime Function() _clock;

  /// Reads that find an agent waiting on the person while herdr says it is
  /// finished (null: no agent kind has one). Panes it finds show as blocked.
  late final ScreenWaits? _waits = screenWaits.isEmpty
      ? null
      : ScreenWaits(
          readers: screenWaits,
          read: (paneId) async => (await _api.readPane(paneId, lines: 60)).text,
          onChange: _onReviewedChanged,
          clock: _clock,
        );

  /// Per agent label: whether its screen shows a wait herdr does not report as
  /// blocked (omp's plan review). See [ScreenWaits].
  final Map<String, bool Function(String screen)> screenWaits;

  /// An answer was sent to [paneId] by keys: the wait it was for is read again
  /// shortly, so a pane that went on stops showing as waiting at once.
  void answeredByKeys(String paneId) => _waits?.answered(paneId);

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

  /// Status changes applied from events (see [_patchStatus]) that no snapshot
  /// has confirmed yet, and so not yet written to the cache.
  bool _unsaved = false;

  /// Counts the patches; [_patches] holds the last one per pane, and is
  /// emptied whenever no snapshot request is out (see [_keepPatches]).
  int _patchSeq = 0;
  int _refreshing = 0;
  final Map<String, ({int seq, AgentStatus status})> _patches = {};

  /// What the app shows: [_raw], with every finished agent the person has
  /// reviewed shown as idle (see [ReviewedState]).
  Snapshot _snapshot = Snapshot.empty;
  ReviewedState? _reviewed;
  DateTime? _lastSync;

  /// When the machine last said anything: a snapshot answered or an event
  /// arrived. Not a notifier: events come many times a second, and the board
  /// reads it on its own minute step ([heardAgo]).
  DateTime? _lastHeard;
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

  /// Events the stream has delivered, ever. A stream that delivered one, or
  /// stayed up for [_streamProvenAfter], worked: the retry delays start over
  /// after it.
  int _events = 0;

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

  /// Open pages from this machine on the phone: an HTML file from its folder,
  /// or a dev server link on the machine (see [WebPreview]).
  late final WebPreview web = WebPreview(_api.transport, machineName: profile.label);

  /// What listens on this machine and which "made" things are still there, as
  /// the agent helper says ([HostPorts]).
  late final HostPorts ports = HostPorts(_api.transport);

  LinkState get state => _state;
  String? get error => _error;

  /// What the app shows of the machine: herdr's snapshot with the agents the
  /// person has reviewed as idle instead of done, in panes and in the
  /// workspace and tab roll-ups. Every screen reads this, so they agree.
  Snapshot get snapshot => _snapshot;

  /// Where the snapshot's folders live (repo and checkout). Rebuilt only when
  /// the shown snapshot is a new one, since every where-line asks.
  PlaceIndex get places {
    if (!identical(_snapshot, _placesFor)) {
      _places = PlaceIndex.of(_snapshot);
      _placesFor = _snapshot;
    }
    return _places!;
  }

  PlaceIndex? _places;
  Snapshot? _placesFor;

  final Map<String, String> _branches = {};

  /// The branch checked out in [checkoutPath], once read (`loadBranches`,
  /// `noteBranches`). Null while unknown or for a detached checkout: herdr's
  /// snapshot carries no branch, so it is decoration read on demand.
  String? branchOf(String checkoutPath) => _branches[checkoutPath];

  /// Reads the branches of every repo with several open checkouts, one
  /// `worktree.list` per repo, and which of a repo's linked checkouts herdr has
  /// closed (their folders are still on the machine: [closedCheckouts]).
  /// [every] reads every repo herdr knows by its git provenance, a repo down
  /// to one open checkout included (the machine screen asks so: a worktree
  /// closed on its own would otherwise disappear exactly where it can be
  /// removed). A failure leaves what was known: the branches are decoration,
  /// nothing is retried and nothing is shown about it. Only on a live link: a
  /// request on a dead one would start a connection attempt of its own,
  /// outside the link's retry and back-off.
  Future<void> loadBranches({bool every = false}) async {
    final reads = every
        ? [for (final p in places.anchors) (p.repoKey, p.workspaceId)]
        : [for (final g in places.repos) (g.repoKey, g.checkouts.first.id)];
    if (!isLive || reads.isEmpty) return;
    final lists = await Future.wait([
      for (final (_, workspaceId) in reads)
        api
            .listWorktrees(workspaceId: workspaceId)
            .then<List<WorktreeInfo>?>((l) => l)
            .catchError(
              (Object _) => null,
              test: (e) => e is HerdrApiException || e is HerdrTransportException || e is TimeoutException,
            ),
    ]);
    noteBranches([for (final l in lists) ...?l]);
    for (final (i, list) in lists.indexed) {
      if (list != null) _noteClosed(reads[i].$1, list);
    }
  }

  final Map<String, List<WorktreeInfo>> _closed = {};
  final Map<String, String> _repoRoots = {};

  /// The linked checkouts of [repoKey] that herdr has closed, as last read
  /// (their folders are still on the machine). Empty before the first read
  /// and for a repo with none.
  List<WorktreeInfo> closedCheckouts(String repoKey) => _closed[repoKey] ?? const [];

  /// The main checkout of [repoKey], as last read: what herdr needs to open a
  /// closed one of its worktrees ([HerdrApi.openWorktree]).
  String? repoRootOf(String repoKey) => _repoRoots[repoKey];

  void _noteClosed(String repoKey, List<WorktreeInfo> list) {
    final root = list.where((w) => !w.isLinked).firstOrNull?.path;
    if (root != null) _repoRoots[repoKey] = root;
    // `open_workspace_id` is herdr's word; a checkout the snapshot lists as a
    // workspace is open whatever a list says. Without the main checkout (a
    // bare repo) a closed one cannot be opened, so it is not offered.
    final closed = [
      for (final w in list)
        if (root != null && w.isLinked && w.openWorkspaceId == null && !places.isOpenCheckout(w.path)) w,
    ];
    final before = _closed[repoKey] ?? const <WorktreeInfo>[];
    if (listEquals([for (final w in before) w.path], [for (final w in closed) w.path])) return;
    if (closed.isEmpty) {
      _closed.remove(repoKey);
    } else {
      _closed[repoKey] = closed;
    }
    if (!_disposed) notifyListeners();
  }

  bool _branchesAsked = false;

  /// Whether [loadBranchesOnce] has asked already.
  bool get branchesAsked => _branchesAsked;

  /// [loadBranches] at most once for this connection's life (an app run): the
  /// board names a repo's agents by branch without the person opening the
  /// machine, and a board that rebuilds on every event must not ask again.
  /// One `worktree.list` per repo with several open checkouts, the first time
  /// the board shows them; a checkout opened later is named by its folder
  /// until the machine screen or the start form reads it. Not counted as asked
  /// while the link is down or no repo has several checkouts, so it is asked
  /// when they come.
  void loadBranchesOnce() {
    if (_branchesAsked || !isLive || places.repos.isEmpty) return;
    _branchesAsked = true;
    unawaited(loadBranches());
  }

  /// Bumped whenever a branch is learnt or forgotten, so a summary of the
  /// fleet (the board's) can tell that the names it shows changed.
  int get branchesVersion => _branchesVersion;
  int _branchesVersion = 0;

  /// Remembers the branches in [worktrees]; repaints only when one changed.
  void noteBranches(List<WorktreeInfo> worktrees) {
    var changed = false;
    for (final w in worktrees) {
      final branch = w.branch;
      // A checkout that went detached has no branch any more: forget the old
      // one rather than show it as current.
      if (branch == null ? _branches.remove(w.path) != null : _branches[w.path] != branch) {
        if (branch != null) _branches[w.path] = branch;
        changed = true;
      }
    }
    if (changed) _branchesVersion++;
    if (changed && !_disposed) notifyListeners();
  }

  DateTime? get lastSync => _lastSync;

  /// How long ago the machine last said anything, on this connection's own
  /// clock; null before it first has. In the background profile only status
  /// changes and a slow poll arrive, so this can honestly be minutes.
  Duration? heardAgo() => switch (_lastHeard) {
    final at? => _clock().difference(at),
    null => null,
  };
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
  /// agent), each with the key of its session (`AgentSessionView.key`). Set
  /// from each `list` by the agent sessions; see [agentPanes].
  Map<String, String> get keeperPanes => _keeperPanes;
  Map<String, String> _keeperPanes = const {};

  void setKeeperPanes(Map<String, String> panes) {
    if (_disposed || mapEquals(panes, _keeperPanes)) return;
    _keeperPanes = panes;
    notifyListeners();
  }

  /// The terminal agents of [snapshot]: its agent panes but a keeper's view
  /// pane, whose session the board, the counts and the notifications already
  /// carry as an agent session (it would be the same agent twice).
  List<Pane> get agentPanes {
    final all = _snapshot.agentPanes;
    if (_keeperPanes.isEmpty) return all;
    return [
      for (final p in all)
        if (!_keeperPanes.containsKey(p.id)) p,
    ];
  }

  /// Whether input can reach pane [id]: the machine is live and the pane
  /// exists and runs (one herdr could not restore answers no input).
  bool acceptsInput(String id) {
    final pane = paneById(id);
    return isLive && pane != null && pane.restoreError == null;
  }

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
      return p.status == AgentStatus.done && reviewed.review(profile.id, paneId, _completionKey(p));
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

  /// [raw] as the app shows it: reviewed `done` becomes `idle`, a pane the
  /// screen shows waiting on the person ([ScreenWaits]) becomes `blocked`, and
  /// a workspace or tab whose roll-up was one of those is worked out again from
  /// what its panes now show (herdr ranks blocked, done, working, idle).
  Snapshot _present(Snapshot raw) {
    final reviewed = _reviewed;
    final waiting = _waits?.panes ?? const <String>{};
    if (reviewed == null && waiting.isEmpty) return raw;
    List<Pane>? panes;
    final blockedWorkspaces = <String>{};
    final blockedTabs = <String>{};
    for (var i = 0; i < raw.panes.length; i++) {
      final p = raw.panes[i];
      final hideable = p.status == AgentStatus.done || p.status == AgentStatus.idle;
      if (hideable && waiting.contains(p.id)) {
        (panes ??= List.of(raw.panes))[i] = p.withStatus(AgentStatus.blocked);
        blockedWorkspaces.add(p.workspaceId);
        blockedTabs.add(p.tabId);
      } else if (p.status == AgentStatus.done &&
          reviewed != null &&
          reviewed.isReviewed(profile.id, p.id, _completionKey(p))) {
        (panes ??= List.of(raw.panes))[i] = p.withStatus(AgentStatus.idle);
      }
    }
    if (panes == null) return raw;
    AgentStatus rollup(bool Function(Pane) inGroup) {
      var best = AgentStatus.unknown;
      for (final p in panes!) {
        if (inGroup(p) && p.status.rollupRank > best.rollupRank) best = p.status;
      }
      return best;
    }

    return Snapshot(
      version: raw.version,
      workspaces: [
        for (final w in raw.workspaces)
          w.status == AgentStatus.done || blockedWorkspaces.contains(w.id)
              ? w.withStatus(rollup((p) => p.workspaceId == w.id))
              : w,
      ],
      tabs: [
        for (final t in raw.tabs)
          t.status == AgentStatus.done || blockedTabs.contains(t.id) ? t.withStatus(rollup((p) => p.tabId == t.id)) : t,
      ],
      panes: panes,
    );
  }

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
          _set(attempt == 0 && _lastSync == null ? LinkState.connecting : LinkState.reconnecting, error: _error);
          await _refresh();
          if (!alive()) return;
          _set(LinkState.online);
          final liveAt = _clock();
          final eventsBefore = _events;
          try {
            await _watch();
            while (alive() && _resubscribing) {
              _resubscribing = false;
              await _watch(gap: true);
            }
          } finally {
            // A good snapshot proves nothing: a stream that dies at once
            // would retry every second for ever. The delays start over only
            // once the stream has lived or delivered something.
            if (_events != eventsBefore || _clock().difference(liveAt) >= _streamProvenAfter) {
              attempt = 0;
            }
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
          error = describeError(e, machine: profile.label);
        } on HerdrApiException catch (e) {
          if (!alive()) return;
          // The status-only subscription named a pane that closed after the
          // snapshot: take the snapshot again, at once (twice at most).
          if (e.code == 'pane_not_found' && _background && raced++ < 2) {
            continue;
          }
          error = describeError(e, machine: profile.label);
        } on Object catch (e) {
          // A reply this app cannot read (a field of another type, a shape it
          // does not know): the same as a failed attempt. Left alone it would
          // end the loop with the link still shown as online or connecting,
          // and nothing would ever retry.
          if (!alive()) return;
          error = describeError(e, machine: profile.label);
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
    final startSeq = _patchSeq;
    _refreshing++;
    final Snapshot answered;
    try {
      answered = await _api.snapshot();
    } finally {
      _refreshing--;
    }
    if (_disposed) return;
    // Patches made while the request was out are newer than its answer; they
    // are put back on it. The log is emptied once no request is out: every
    // later one started after the last patch.
    final s = _patchSeq == startSeq ? answered : _keepPatches(answered, startSeq);
    if (_refreshing == 0) _patches.clear();
    final now = _clock();
    _lastSync = now;
    _lastHeard = now;
    final unsaved = _unsaved;
    _unsaved = false;
    final rawChanged = s != _raw;
    _trackStatuses(s, now);
    _raw = s;
    _checkSubscription();
    _endStaleReviews(s);
    _waits?.update(s.panes);
    final quietChanged = _evaluateQuiet(s, now);
    final shown = _present(s);
    final shownChanged = shown != _snapshot;
    if (!rawChanged && !shownChanged && !quietChanged) {
      // Nothing to show, but the time the panes were last seen moved on.
      final written = _lastPersistAt;
      if (unsaved || written == null || now.difference(written) >= seenWriteInterval) _persist();
      return;
    }
    _snapshot = shown;
    if (rawChanged || unsaved) _persist();
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
    } else if ((live && identical(watch, _seenWatch)) || now.difference(seen) <= observationGap) {
      changed = StatusTime.exact(now);
    } else {
      changed = StatusTime.after(seen);
    }
    final next = <String, ObservedStatus>{};
    for (final p in s.panes) {
      final known = _statusSince[p.id];
      next[p.id] = known != null && known.status == p.status ? known : (status: p.status, since: changed);
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
    final sub = _api
        .changes(statusPanes: panes)
        .listen(
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
      final ticker = AlignedTicker(backgroundPollInterval, _clock, () => refresher.schedule(urgent: true));
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
  ///  * status or agent changed (e.g. working -> blocked)    -> shown now when
  ///    the event carries all of it ([_patchStatus]), and refresh now;
  ///  * anything else (title, cwd)                            -> throttled.
  void _onEvent(Map<String, dynamic> event, _RefreshScheduler refresher) {
    if (event['event'] == subscriptionStartedEvent) {
      // herdr streams only what happens after it accepts the subscription,
      // and the snapshot was taken before that: one refresh closes the gap,
      // instead of a "needs you" waiting for the safety poll. Not counted as
      // an event: a stream that acks and then dies proves nothing (see `_run`).
      _lastHeard = _clock();
      refresher.schedule(urgent: true);
      return;
    }
    _events++;
    _lastHeard = _clock();
    if (event['event'] == 'workspace_metadata_updated') {
      // Token text answers none of the attention questions: it shares the
      // churn throttle with `pane_updated`, and only while the app is in front.
      if (!_background) refresher.schedule(urgent: false);
      return;
    }
    if (event['event'] == 'pane_agent_status_changed') {
      // The background profile's one carrier of a status change, and the only
      // one that arrives as `data: {pane_id, agent_status, ...}` (no `pane`).
      final data = event['data'];
      if (data is Map) _patchFromEvent(data['pane_id'], data['agent_status'], data);
      refresher.schedule(urgent: true);
      return;
    }
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
      _waits?.touch(id);
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
      if (known != null &&
          known.agent == updated.agent &&
          known.workspaceId == updated.workspaceId &&
          known.tabId == updated.tabId) {
        _patchStatus(known, updated.status);
      }
      refresher.schedule(urgent: true);
    } else if (known != updated.withCompletionSeq(known.completionSeq)) {
      refresher.schedule(urgent: false);
    }
  }

  /// Applies a `pane_agent_status_changed` payload: `pane_id`, `agent_status`
  /// and, when herdr sends them, `agent` and `workspace_id`, which must agree
  /// with what is known (an event that disagrees is not one to patch from).
  void _patchFromEvent(Object? paneId, Object? status, Map<Object?, Object?> data) {
    if (paneId is! String || status is! String) return;
    final known = _raw.panes.where((p) => p.id == paneId).firstOrNull;
    if (known == null) return;
    if (data.containsKey('agent') && data['agent'] != known.agent) return;
    if (data.containsKey('workspace_id') && data['workspace_id'] != known.workspaceId) return;
    _patchStatus(known, AgentStatus.parse(status));
  }

  /// Shows a status change the moment its event arrives, before the snapshot
  /// that confirms it has made its round trip. The caller schedules that
  /// refresh as always (urgent, no extra delay), so a patch that was wrong
  /// (a stale or reordered event) lives for one round trip, and the
  /// notifier sees the same transitions it would see from the snapshot (one
  /// episode, ended and withdrawn when the refresh disagrees).
  ///
  /// Only moves between `working`, `blocked` and `idle` are patched, and
  /// only of a pane that is already known to run an agent, in the same
  /// workspace and tab: all of it is carried by the event itself. Everything
  /// an event does not carry keeps today's path (a refresh, nothing shown
  /// before it):
  ///  * `done`, in or out: what `done` means to the person (finished and not
  ///    yet looked at) rests on `completion_seq`, which events lack, and a
  ///    wrong "done" would be announced as news and marked as reviewed
  ///    against the wrong finish;
  ///  * `unknown`: herdr's word for "cannot tell", not a state to show first;
  ///  * an agent appearing, vanishing or changing, a pane, tab or workspace
  ///    created, moved or closed: structure.
  /// Returns whether [known] was patched.
  bool _patchStatus(Pane known, AgentStatus status) {
    if (_disposed || _lastSync == null) return false;
    if (!known.isAgent || known.status == status) return false;
    if (!_patchable(known.status) || !_patchable(status)) return false;
    final now = _clock();
    _raw = _withStatus(_raw, known.id, status);
    // Found the moment herdr said it, which is more exact than the refresh
    // that follows (it keeps this one, its status agrees).
    _statusSince[known.id] = (status: status, since: StatusTime.exact(now));
    _patches[known.id] = (seq: ++_patchSeq, status: status);
    _unsaved = true;
    final shown = _present(_raw);
    if (shown != _snapshot) {
      _snapshot = shown;
      notifyListeners();
    }
    return true;
  }

  static bool _patchable(AgentStatus s) =>
      s == AgentStatus.working || s == AgentStatus.blocked || s == AgentStatus.idle;

  /// [s] with pane [id] in [status], and its tab and workspace worked out
  /// again from their panes (herdr ranks blocked, done, working, idle).
  static Snapshot _withStatus(Snapshot s, String id, AgentStatus status) {
    final i = s.panes.indexWhere((p) => p.id == id);
    if (i < 0 || s.panes[i].status == status) return s;
    final panes = List.of(s.panes);
    final pane = panes[i] = panes[i].withStatus(status);
    AgentStatus rollup(bool Function(Pane) inGroup) {
      var best = AgentStatus.unknown;
      for (final p in panes) {
        if (inGroup(p) && p.status.rollupRank > best.rollupRank) best = p.status;
      }
      return best;
    }

    return Snapshot(
      version: s.version,
      workspaces: [
        for (final w in s.workspaces) w.id == pane.workspaceId ? w.withStatus(rollup((p) => p.workspaceId == w.id)) : w,
      ],
      tabs: [for (final t in s.tabs) t.id == pane.tabId ? t.withStatus(rollup((p) => p.tabId == t.id)) : t],
      panes: panes,
    );
  }

  /// A snapshot answered after an event was applied to what is shown was
  /// taken before herdr said it (the event is not in it, or it would have
  /// changed nothing): showing it would take the change back for the round
  /// trip the next snapshot needs. Panes patched since [sinceSeq] keep the
  /// patched status; that next snapshot (the patch always schedules one)
  /// has the last word.
  Snapshot _keepPatches(Snapshot s, int sinceSeq) {
    var out = s;
    for (final MapEntry(:key, :value) in _patches.entries) {
      if (value.seq <= sinceSeq) continue;
      final pane = out.panes.where((p) => p.id == key).firstOrNull;
      if (pane == null || !pane.isAgent || !_patchable(pane.status)) continue;
      out = _withStatus(out, key, value.status);
    }
    return out;
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
    return seen == null ? null : ObservedStatuses(seenAt: seen, panes: Map.of(_statusSince));
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
    _waits?.dispose();
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
