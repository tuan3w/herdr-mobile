import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:herdr_mobile/ui/core/kit.dart' show Dwell;

import '../../../data/acp/agent_host.dart';
import '../../../data/models/herdr_models.dart';
import '../../../data/models/worktrees.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_session_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/herdr_transport.dart';
import 'session_prefill.dart';
import 'session_start_support.dart' show NewSessionError, folderError, recentFolders;

/// Null when [folder] can be the working directory of an ACP session: the
/// agent gets it as `cwd`, and ACP wants an absolute path (a `~` would reach
/// the agent unexpanded).
String? agentFolderError(String? folder) {
  final problem = folderError(folder);
  if (problem != null) return problem;
  return folder!.trim().startsWith('/') ? null : 'An absolute path, starting with /';
}

/// Where the session runs, within the repo of the typed folder.
sealed class CheckoutChoice {
  const CheckoutChoice();
}

/// The typed folder itself. The default: creating things is never implicit.
final class ThisFolder extends CheckoutChoice {
  const ThisFolder();
}

/// A checkout that already exists, by path.
final class ExistingCheckout extends CheckoutChoice {
  const ExistingCheckout(this.path);

  final String path;

  @override
  bool operator ==(Object other) => other is ExistingCheckout && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A worktree herdr makes when the session starts.
final class NewWorktree extends CheckoutChoice {
  const NewWorktree();
}

/// State of the new-agent-session form: which machine and agent, what the
/// machine can run, and the start itself. The folder field is owned by the
/// screen and handed to [start].
class NewAgentSessionViewModel extends ChangeNotifier {
  NewAgentSessionViewModel({
    required this._fleet,
    required this._sessions,
    required this._settings,
    String? machineId,
    this.prefill,
    Random? random,
  }) : _random = random ?? Random() {
    // A duplicate keeps its machine even when it is offline: the form then
    // says so, rather than starting the folder somewhere else.
    _machineId = prefill?.machineId ?? _initialMachine(machineId);
    final copied = prefill?.agent;
    _agent = copied != null && agentRouteById(copied) != null ? copied : _rememberedAgent();
    _fleet.addListener(_onFleet);
    _signature = _signatureNow();
    unawaited(_probe());
  }

  /// What a duplicate starts from; null for a form opened empty.
  final SessionPrefill? prefill;
  final Random _random;

  final FleetRepository _fleet;
  final AgentSessions _sessions;
  final AgentSessionSettings _settings;

  String? _machineId;
  late String _agent;
  bool _busy = false;
  bool _disposed = false;
  NewSessionError? _error;
  String _signature = '';

  // What each machine can run, by machine id; a machine that has not answered
  // (or answered with a failure) has no entry.
  final _installed = <String, Set<String>>{};
  final _probing = <String>{};
  final _probeFailure = <String, String>{};

  /// Machines that can take a session now, in saved order.
  List<MachineConnection> get machines => [
    for (final c in _fleet.connections)
      if (c.isLive) c,
  ];

  /// The chosen machine, or null when none is online (or the chosen one went
  /// offline).
  MachineConnection? get machine {
    final id = _machineId;
    for (final c in machines) {
      if (c.profile.id == id) return c;
    }
    return null;
  }

  /// The chosen machine was online and is not any more.
  bool get machineLost => _machineId != null && machine == null && machines.isNotEmpty;

  /// The chosen route id.
  String get agent => _agent;

  bool get busy => _busy;
  NewSessionError? get error => _error;

  /// Whether the chosen machine is still being asked what it can run.
  bool get checking => _machineId != null && _probing.contains(_machineId);

  /// Why the chosen machine could not say what it can run; null when it did
  /// (or has not been asked yet).
  String? get probeFailure => _machineId == null ? null : _probeFailure[_machineId];

  /// Whether the chosen machine can run [routeId]: null while that is not
  /// known (the machine is being asked, or did not answer).
  bool? isAvailable(String routeId) => _installed[_machineId]?.contains(routeId);

  /// One line on why [route] cannot be chosen; null when it can.
  String? unavailableReason(AgentRoute route) {
    final m = machine;
    if (m == null || isAvailable(route.id) != false) return null;
    return 'Not installed on ${m.profile.label}';
  }

  /// The chosen agent can be started (as far as is known).
  bool get canStart => machine != null && isAvailable(_agent) != false;

  List<String> get recent {
    final m = machine;
    return m == null ? const [] : recentFolders(m.snapshot);
  }

  /// The folder used last on the chosen machine; empty when none.
  String get rememberedFolder {
    final id = _machineId;
    return (id == null ? null : _settings.folderFor(id)) ?? '';
  }

  void selectMachine(String id) {
    if (id == _machineId) return;
    _machineId = id;
    _agent = _rememberedAgent();
    _error = null;
    _forgetCheckouts();
    unawaited(_probe());
    _changed();
  }

  void selectAgent(String routeId) {
    if (routeId == _agent || isAvailable(routeId) == false) return;
    _agent = routeId;
    _error = null;
    _changed();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// The checkouts of the repo the typed folder is in, null while unknown or
  /// when the folder is no git repo: the form then has no checkout to offer.
  List<WorktreeInfo>? get checkouts => _checkouts;

  /// Where the session runs. Applies to the folder the checkouts were read
  /// for; a folder typed since says [ThisFolder].
  CheckoutChoice get choice => _choice;

  List<WorktreeInfo>? _checkouts;
  CheckoutChoice _choice = const ThisFolder();

  // The folder [_checkouts] and [_choice] are about (set when its lookup
  // starts, cleared when it failed so a re-pick asks again), and a counter so
  // only the latest lookup's answer is kept.
  String? _lookedFor;
  int _lookup = 0;

  /// Reads the checkouts of the repo [folder] is in. Never an error: a folder
  /// that is no git repo, a repo herdr does not trust, a herdr without
  /// worktrees and a machine that does not answer all leave the form without
  /// a `Checkout` row.
  Future<void> lookUp(String folder) async {
    final path = folder.trim();
    final m = machine;
    if (m == null || agentFolderError(path) != null) return _forgetCheckouts();
    if (path == _lookedFor) return;
    _forgetCheckouts();
    final mine = _lookup;
    _lookedFor = path;
    final List<WorktreeInfo> found;
    try {
      found = await m.api.listWorktrees(cwd: path);
    } on Exception catch (e) {
      debugPrint('herdr: no checkouts for $path on ${m.profile.id}: $e');
      if (mine == _lookup) _lookedFor = null;
      return;
    }
    if (mine != _lookup || _disposed || found.isEmpty) return;
    _checkouts = found;
    m.noteBranches(found);
    notifyListeners();
  }

  /// Drops what a lookup found and ignores any answer still on its way.
  void _forgetCheckouts() {
    _lookup++;
    _lookedFor = null;
    if (_checkouts == null && _choice is ThisFolder) return;
    _checkouts = null;
    _choice = const ThisFolder();
    if (!_disposed) notifyListeners();
  }

  void chooseCheckout(CheckoutChoice choice) {
    if (choice == _choice) return;
    _choice = choice;
    _error = null;
    notifyListeners();
  }

  /// A branch name to start the `Branch` field with, in herdr's own shape
  /// (`worktree/brave-meadow-45e8`) and not the branch of any checkout the
  /// lookup found. Why: a field left empty hides the name until the worktree
  /// exists; shown, it can be read, changed and recognised later on the desk.
  String suggestBranch() {
    final taken = {for (final c in _checkouts ?? const <WorktreeInfo>[]) ?c.branch};
    while (true) {
      final tag = _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
      final name =
          'worktree/${_adjectives[_random.nextInt(_adjectives.length)]}-'
          '${_nouns[_random.nextInt(_nouns.length)]}-$tag';
      if (!taken.contains(name)) return name;
    }
  }

  static const _adjectives = [
    'brave',
    'calm',
    'bright',
    'quiet',
    'lucky',
    'swift',
    'gentle',
    'bold',
    'sunny',
    'misty',
    'amber',
    'cosmic',
    'keen',
    'merry',
    'noble',
    'witty',
  ];
  static const _nouns = [
    'meadow',
    'river',
    'stone',
    'cloud',
    'forest',
    'harbor',
    'lantern',
    'maple',
    'comet',
    'canyon',
    'falcon',
    'garden',
    'island',
    'orchard',
    'summit',
    'willow',
  ];

  /// Why [branch] cannot name a new branch; null when it can (or is empty:
  /// herdr names it). Whether git takes the name is left to git.
  String? branchError(String? branch) {
    final b = branch?.trim() ?? '';
    if (b.isEmpty) return null;
    if (_unfit.hasMatch(b)) return 'No spaces or control characters';
    if (b.startsWith('-')) return 'Can’t start with -';
    return null;
  }

  static final _unfit = RegExp(r'[\s\x00-\x1f\x7f]');

  /// Agents working or waiting for an answer in [checkoutPath] or below, on the
  /// chosen machine (the sessions the phone started are panes there too).
  int agentsWorking(String checkoutPath) {
    final m = machine;
    if (m == null) return 0;
    var base = checkoutPath;
    if (base.length > 1 && base.endsWith('/')) base = base.substring(0, base.length - 1);
    var n = 0;
    for (final p in m.snapshot.panes) {
      final cwd = p.cwd;
      if (p.agent == null || cwd == null) continue;
      if (p.status != AgentStatus.working && p.status != AgentStatus.blocked) continue;
      if (cwd == base || cwd.startsWith(base == '/' ? '/' : '$base/')) n++;
    }
    return n;
  }

  /// The choice that applies to [folder]: none made yet for a folder whose
  /// lookup has not started.
  CheckoutChoice _choiceFor(String folder) => folder == _lookedFor ? _choice : const ThisFolder();

  /// Starts the session in [folder], or in the checkout [choice] names within
  /// its repo; [branch] names the branch of a new worktree (empty: herdr
  /// names it). Null when it did not start; [error] says why. The caller
  /// opens the returned session.
  Future<AgentSessionView?> start(String folder, {String branch = ''}) async {
    if (_busy) return null;
    final m = machine;
    final path = folder.trim();
    if (m == null) {
      return _fail(const NewSessionError('No machine online', 'Pick a machine that is online.'));
    }
    final problem = agentFolderError(path);
    if (problem != null) return _fail(NewSessionError('Check the form', problem));
    final choice = _choiceFor(path);
    if (choice is NewWorktree) {
      final bad = branchError(branch);
      if (bad != null) return _fail(NewSessionError('Check the form', bad));
    }
    final agentId = _agent;

    _busy = true;
    _error = null;
    notifyListeners();
    WorktreeInfo? made;
    try {
      var cwd = path;
      switch (choice) {
        case ThisFolder():
          break;
        case ExistingCheckout(path: final there):
          cwd = there;
        case NewWorktree():
          final CreatedWorktree created;
          try {
            created = await m.api.createWorktree(cwd: path, branch: branch.trim());
          } on HerdrUnsupportedException {
            final v = m.snapshot.version;
            return _fail(
              NewSessionError(
                'Worktrees aren’t supported',
                'herdr${v.isEmpty ? '' : ' $v'} on ${m.profile.label} can’t create worktrees. '
                    'Update herdr on that machine, or choose This folder.',
              ),
            );
          } on HerdrApiException catch (e) {
            return _fail(NewSessionError('Couldn’t create the worktree', e.message));
          } on HerdrTransportException catch (e) {
            return _fail(await _createUnanswered(m, path, e.message));
          } on TimeoutException {
            return _fail(await _createUnanswered(m, path, 'The machine didn’t answer in time.'));
          }
          final worktree = created.worktree;
          made = worktree;
          try {
            // So the toast names the new checkout by its repo.
            await m.refresh().timeout(Dwell.refreshTimeout);
          } on Exception {
            // Offline or slow: events bring the lists up to date later.
          }
          m.noteBranches([worktree]);
          cwd = worktree.path;
          // Before the session starts: a start that fails and is retried must
          // reuse this worktree, not make a second.
          _adopt(path, worktree);
      }
      final session = await _sessions.start(machine: m, agent: agentId, cwd: cwd);
      unawaited(_settings.remember(machineId: m.profile.id, agent: agentId, folder: path));
      return session;
    } on AgentHostException catch (e) {
      final w = made;
      return _fail(
        NewSessionError(
          'Couldn’t start the session',
          w == null ? e.message : '${e.message} The worktree ${w.name} was created; Start again to use it.',
        ),
      );
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Makes [made] the chosen checkout of the repo [folder] is in.
  void _adopt(String folder, WorktreeInfo made) {
    if (_lookedFor != folder) return;
    final known = _checkouts;
    if (known != null && !known.any((c) => c.path == made.path)) _checkouts = [...known, made];
    _choice = ExistingCheckout(made.path);
  }

  /// A create whose answer was lost (timeout, dropped link): herdr may have made
  /// the worktree anyway, since its hooks can outlast the request. Looks again;
  /// a single new linked checkout is adopted so Start again uses it instead of
  /// making a second. Otherwise says it may exist.
  Future<NewSessionError> _createUnanswered(MachineConnection m, String folder, String why) async {
    final before = {for (final c in _checkouts ?? const <WorktreeInfo>[]) c.path};
    try {
      final now = await m.api.listWorktrees(cwd: folder).timeout(Dwell.refreshTimeout);
      final fresh = [
        for (final w in now)
          if (w.isLinked && !before.contains(w.path)) w,
      ];
      if (before.isNotEmpty && fresh.length == 1 && !_disposed) {
        _checkouts = now;
        m.noteBranches(now);
        _adopt(folder, fresh.single);
        return NewSessionError(
          'The worktree was created',
          '${fresh.single.name} exists, but the machine answered late. Start again to use it.',
        );
      }
    } on Exception {
      // Still not answering: say so below.
    }
    return NewSessionError(
      'Couldn’t create the worktree',
      '$why It may still have been created: check Checkout before trying again.',
    );
  }

  AgentSessionView? _fail(NewSessionError error) {
    _error = error;
    if (!_disposed) notifyListeners();
    return null;
  }

  Future<void> _probe() async {
    final m = machine;
    if (m == null) return;
    final id = m.profile.id;
    if (_installed.containsKey(id)) {
      _settleAgent();
      return;
    }
    if (!_probing.add(id)) return;
    _probeFailure.remove(id);
    try {
      _installed[id] = await _sessions.available(m);
    } on AgentHostException catch (e) {
      _probeFailure[id] = e.message;
    } finally {
      _probing.remove(id);
    }
    if (_disposed) return;
    if (id == _machineId) _settleAgent();
    _changed();
  }

  // The remembered agent may not exist on this machine: move to one that does.
  void _settleAgent() {
    if (isAvailable(_agent) != false) return;
    for (final r in agentRoutes) {
      if (isAvailable(r.id) == true) {
        _agent = r.id;
        return;
      }
    }
  }

  String? _initialMachine(String? preferred) {
    final online = machines;
    for (final id in [preferred, _settings.lastMachineId]) {
      if (id != null && online.any((c) => c.profile.id == id)) return id;
    }
    return online.firstOrNull?.profile.id;
  }

  String _rememberedAgent() {
    final id = _machineId;
    final saved = id == null ? null : _settings.agentFor(id);
    return saved != null && agentRouteById(saved) != null ? saved : agentRoutes.first.id;
  }

  /// The machines that can be picked, the one chosen, and what the form shows
  /// from its snapshot. A fleet that changes only in unrelated ways must not
  /// rebuild the form.
  String _signatureNow() => '${machines.map((c) => c.profile.id).join(',')}|$_machineId|${recent.join(',')}';

  void _onFleet() {
    final next = _signatureNow();
    if (next == _signature) return;
    _signature = next;
    notifyListeners();
  }

  void _changed() {
    _signature = _signatureNow();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _fleet.removeListener(_onFleet);
    super.dispose();
  }
}
