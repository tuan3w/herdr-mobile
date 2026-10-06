import 'package:flutter/foundation.dart';

import '../acp/session_state.dart' show AgentPhase;
import '../models/herdr_models.dart' show AgentStatus;
import 'agent_session.dart';
import 'fleet_repository.dart';
import 'machine_connection.dart';

/// One agent that wants the person: a terminal pane or an agent session.
sealed class AttentionItem {
  const AttentionItem();

  /// `<machine>/<pane>` for a pane (the board row's key), `session/<key>` for
  /// an agent session: stable, and never the same for a pane and a session.
  String get key;

  MachineConnection get machine;

  /// When it began to wait (or finished), by this phone's clock; for a pane
  /// whose change was found after a gap, the earliest it can have been. Null
  /// when not known.
  DateTime? get since;
}

/// A terminal pane that waits for the person or finished.
final class PaneAttention extends AttentionItem {
  const PaneAttention(this.agent);

  final FleetAgent agent;

  @override
  String get key => '${agent.machine.profile.id}/${agent.pane.id}';

  @override
  MachineConnection get machine => agent.machine;

  @override
  DateTime? get since => agent.machine.statusSince(agent.pane.id);
}

/// An agent session that waits for the person or finished.
final class SessionAttention extends AttentionItem {
  const SessionAttention(this.session);

  final AgentSessionView session;

  @override
  String get key => 'session/${session.key}';

  @override
  MachineConnection get machine => session.machine;

  @override
  DateTime? get since => session.phaseSince;
}

/// The one answer to "does anything need me?", for every surface: the Agents
/// tab badge, the triage pill and sheet, the board's sections and filter
/// chips, the Machines tab, the arrival haptic and the notifier's counts.
/// Before it, each surface counted for itself and they disagreed (a badge of
/// 3 beside a pill saying 1, a sheet saying `All clear` while a session
/// waited).
///
/// - [needsYou]: terminal panes blocked on the person ([FleetAgent.needsYou])
///   and agent sessions blocked on a permission or a question, reachable
///   only: a pane on a live machine; a session whose machine is live and whose
///   link is live. What cannot be answered from here is not counted.
/// - [toReview]: finished and not yet reviewed, with the same reachability
///   rule (what cannot be reached cannot be marked reviewed either).
/// - [offlineNeedsYou] and [offlineToReview]: the same, last known, for what
///   is out of reach. Not counted; the surfaces that list them say "offline".
///
/// Each list runs longest waiting first, panes and sessions mixed, then by
/// machine and key so that equal times keep a stable order.
///
/// Computed once per change of the fleet or the sessions, not per reader:
/// listeners hear of it only when a key or the order changed. Build it before
/// anything else that listens to the same fleet and sessions (the notifier),
/// so it is up to date when they read it.
class AttentionSet extends ChangeNotifier {
  AttentionSet({required this._fleet, this._sessions}) {
    _fleet.addListener(_update);
    _sessions?.addListener(_update);
    _compute();
  }

  final FleetRepository _fleet;
  final AgentSessions? _sessions;
  bool _disposed = false;

  List<AttentionItem> _needsYou = const [];
  List<AttentionItem> _offlineNeedsYou = const [];
  List<AttentionItem> _toReview = const [];
  List<AttentionItem> _offlineToReview = const [];
  Map<String, int> _perMachine = const {};
  Set<String> _needsYouKeys = const {};
  Set<String> _waitingKeys = const {};

  /// Reachable agents that wait for an answer, longest waiting first.
  List<AttentionItem> get needsYou => _needsYou;

  /// Agents that waited when last seen, now out of reach (not counted).
  List<AttentionItem> get offlineNeedsYou => _offlineNeedsYou;

  /// Reachable finished agents not yet reviewed, longest waiting first.
  List<AttentionItem> get toReview => _toReview;

  /// Finished agents not yet reviewed, now out of reach (not counted).
  List<AttentionItem> get offlineToReview => _offlineToReview;

  /// The keys of [needsYou]. The same object until the set changes.
  Set<String> get needsYouKeys => _needsYouKeys;

  /// The keys of every agent last known to wait, reachable or not: one that
  /// went out of reach (a Wi-Fi to mobile handover) and comes back is the
  /// same wait, not a new one. The same object until the set changes.
  Set<String> get waitingKeys => _waitingKeys;

  /// How many of [needsYou] run on machine [machineId].
  int needsYouOn(String machineId) => _perMachine[machineId] ?? 0;

  /// An agent session that waits for a permission or an answer.
  static bool sessionBlocked(AgentSessionView s) =>
      s.phase == AgentPhase.blockedOnPermission || s.phase == AgentPhase.blockedOnQuestion;

  /// An agent session whose turn finished and nobody has looked.
  static bool sessionToReview(AgentSessionView s) => s.phase == AgentPhase.idle && s.unseenDone;

  /// An agent session that can be acted on now: its machine and its link are
  /// up. One that is reconnecting or ended shows what it last knew.
  static bool sessionReachable(AgentSessionView s) => s.machine.isLive && s.link == AgentLink.live;

  void _update() {
    if (_disposed) return;
    if (_compute()) notifyListeners();
  }

  /// Rebuilds the lists; true when a key or the order changed.
  bool _compute() {
    final needs = <AttentionItem>[];
    final needsOff = <AttentionItem>[];
    final review = <AttentionItem>[];
    final reviewOff = <AttentionItem>[];
    for (final c in _fleet.connections) {
      for (final p in c.snapshot.agentPanes) {
        if (p.status != AgentStatus.blocked && p.status != AgentStatus.done) continue;
        final a = FleetAgent(machine: c, pane: p, workspace: c.snapshot.workspace(p.workspaceId));
        final item = PaneAttention(a);
        if (a.needsYou) {
          needs.add(item);
        } else if (p.status == AgentStatus.blocked) {
          needsOff.add(item);
        } else if (a.toReview) {
          (a.stale ? reviewOff : review).add(item);
        }
      }
    }
    for (final s in _sessions?.sessions ?? const <AgentSessionView>[]) {
      final reachable = sessionReachable(s);
      if (sessionBlocked(s)) {
        (reachable ? needs : needsOff).add(SessionAttention(s));
      } else if (sessionToReview(s)) {
        (reachable ? review : reviewOff).add(SessionAttention(s));
      }
    }
    for (final list in [needs, needsOff, review, reviewOff]) {
      list.sort(_longestWaiting);
    }
    final changed = !_sameKeys(needs, _needsYou) ||
        !_sameKeys(needsOff, _offlineNeedsYou) ||
        !_sameKeys(review, _toReview) ||
        !_sameKeys(reviewOff, _offlineToReview);
    // Fresh items every time (a reader gets the latest pane and session);
    // listeners only hear of a change they can see.
    _needsYou = List.unmodifiable(needs);
    _offlineNeedsYou = List.unmodifiable(needsOff);
    _toReview = List.unmodifiable(review);
    _offlineToReview = List.unmodifiable(reviewOff);
    if (changed) {
      final perMachine = <String, int>{};
      for (final i in needs) {
        perMachine.update(i.machine.profile.id, (n) => n + 1, ifAbsent: () => 1);
      }
      _perMachine = perMachine;
      _needsYouKeys = Set.unmodifiable({for (final i in needs) i.key});
      _waitingKeys = Set.unmodifiable({..._needsYouKeys, for (final i in needsOff) i.key});
    }
    return changed;
  }

  static bool _sameKeys(List<AttentionItem> a, List<AttentionItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key) return false;
    }
    return true;
  }

  static int _longestWaiting(AttentionItem a, AttentionItem b) {
    final x = a.since;
    final y = b.since;
    if (x != null && y != null) {
      final byAge = x.compareTo(y);
      if (byAge != 0) return byAge;
    } else if (x != null || y != null) {
      return x != null ? -1 : 1;
    }
    final byMachine = a.machine.profile.label.compareTo(b.machine.profile.label);
    return byMachine != 0 ? byMachine : a.key.compareTo(b.key);
  }

  @override
  void dispose() {
    _disposed = true;
    _fleet.removeListener(_update);
    _sessions?.removeListener(_update);
    super.dispose();
  }
}
