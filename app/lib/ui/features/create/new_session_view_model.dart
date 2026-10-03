import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/new_session_settings.dart';
import '../../../data/repositories/session_launcher.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/herdr_transport.dart';

/// Agent kinds offered when the machine's herdr cannot list its own.
const fallbackAgentKinds = ['claude', 'codex', 'omp', 'opencode', 'gemini', 'cursor', 'amp', 'aider'];

/// Most working directories offered as one-tap suggestions.
const maxRecentFolders = 8;

final _control = RegExp(r'[\x00-\x1f\x7f]');

/// Null when [folder] is something herdr can open: an absolute path, `~`, or
/// `~/...`. No control characters: `~` paths are typed into a shell.
String? folderError(String? folder) {
  final v = folder?.trim() ?? '';
  if (v.isEmpty) return 'Choose a folder';
  if (_control.hasMatch(v)) return 'No line breaks or control characters';
  if (!v.startsWith('/') && !isHomeFolder(v)) return 'Start with / or ~';
  return null;
}

/// Null when [command] is a line that can be typed into a shell.
String? commandError(String? command) {
  final v = command?.trim() ?? '';
  if (v.isEmpty) return 'Enter the command that starts it';
  if (v.contains('\n') || v.contains('\r')) return 'One line only';
  if (_control.hasMatch(v)) return 'No control characters';
  return null;
}

/// The workspace name used when none is typed: the folder's own name.
String defaultWorkspaceName(String folder) {
  var v = folder.trim();
  while (v.length > 1 && v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  if (v == '~') return 'home';
  if (v == '/' || v.isEmpty) return 'root';
  return v.substring(v.lastIndexOf('/') + 1);
}

/// Working directories already in use on the machine, for one-tap reuse:
/// distinct absolute paths, those of agents first.
List<String> recentFolders(Snapshot snapshot, {int max = maxRecentFolders}) {
  final seen = <String>{};
  final out = <String>[];
  void add(Pane p) {
    final cwd = p.cwd;
    if (cwd == null || !cwd.startsWith('/') || cwd == '/' || _control.hasMatch(cwd)) return;
    if (out.length < max && seen.add(cwd)) out.add(cwd);
  }

  for (final p in snapshot.panes) {
    if (p.isAgent) add(p);
  }
  for (final p in snapshot.panes) {
    if (!p.isAgent) add(p);
  }
  return out;
}

/// What the person typed. Everything is raw: the view model trims and checks.
class NewSessionValues {
  const NewSessionValues({
    required this.folder,
    this.name = '',
    this.command = '',
    this.prompt = '',
  });

  final String folder;
  final String name;
  final String command;
  final String prompt;
}

class NewSessionError {
  const NewSessionError(this.title, this.message);

  final String title;
  final String message;
}

/// A started session, ready to be opened.
class NewSessionLaunch {
  const NewSessionLaunch({
    required this.machine,
    required this.paneId,
    this.notice,
    this.prompt,
  });

  final MachineConnection machine;
  final String paneId;

  /// A problem that does not stop the session from being opened.
  final String? notice;

  /// Completes when the first prompt was sent or given up on.
  final Future<PromptOutcome>? prompt;
}

/// What to tell the person about the first prompt, or null when it went out.
String? promptNotice(PromptOutcome outcome, String agent) => switch (outcome) {
      PromptOutcome.sent => null,
      PromptOutcome.timedOut => '$agent did not start, so the first message was not sent.',
      PromptOutcome.gone => 'The pane was closed before the first message was sent.',
      PromptOutcome.failed => 'The first message could not be sent.',
    };

/// Where a launch went wrong, in words for the person.
NewSessionError describeLaunchFailure(Object error, MachineConnection machine, String folder) {
  final name = machine.profile.label;
  return switch (error) {
    HerdrUnsupportedException() => NewSessionError(
        'Not supported by this herdr',
        'herdr${machine.snapshot.version.isEmpty ? '' : ' ${machine.snapshot.version}'} on $name '
            "can't create workspaces from here. Update herdr on that machine to start sessions from your phone.",
      ),
    FolderNotFoundException() => NewSessionError(
        'Folder not found',
        "$folder doesn't exist on $name. Pick a folder that does.",
      ),
    HerdrApiException(:final message) => NewSessionError("Couldn't start the session", message),
    HerdrTransportException(:final message) => NewSessionError("Couldn't start the session", message),
    TimeoutException() => const NewSessionError(
        "Couldn't start the session",
        'The machine did not answer in time.',
      ),
    _ => NewSessionError("Couldn't start the session", '$error'),
  };
}

/// State of the new-session form: which machine, what to launch, and the
/// launch itself. The text fields are owned by the screen and handed to
/// [start].
class NewSessionViewModel extends ChangeNotifier {
  NewSessionViewModel({
    required this._fleet,
    required this._settings,
    String? machineId,
    SessionLauncher Function(MachineConnection machine)? launcherFor,
    this.manifestTimeout = const Duration(seconds: 4),
  }) : _launcherFor = launcherFor ?? SessionLauncher.new {
    _machineId = _initialMachine(machineId);
    _kind = _rememberedKind();
    _fleet.addListener(_onFleet);
    _signature = _signatureNow();
    _loadKinds();
  }

  final FleetRepository _fleet;
  final NewSessionSettings _settings;
  final SessionLauncher Function(MachineConnection machine) _launcherFor;

  /// `server.agent_manifests` can hang on a herdr that predates it (the
  /// unknown-method error carries no request id and is never matched), so it
  /// gets a short leash.
  final Duration manifestTimeout;

  String? _machineId;
  String? _kind;
  bool _busy = false;
  bool _disposed = false;
  NewSessionError? _error;
  String _signature = '';
  final _manifests = <String, List<String>>{};
  final _loading = <String>{};

  /// Machines that can take a session now, in saved order.
  List<MachineConnection> get machines => [
        for (final c in _fleet.connections)
          if (c.isLive) c,
      ];

  /// The chosen machine, or null when none is online (or the chosen one
  /// went offline).
  MachineConnection? get machine {
    final id = _machineId;
    for (final c in machines) {
      if (c.profile.id == id) return c;
    }
    return null;
  }

  /// The chosen machine was online and is not any more.
  bool get machineLost => _machineId != null && machine == null && machines.isNotEmpty;

  /// The agent being started; null for a plain shell.
  String? get kind => _kind;

  bool get busy => _busy;
  NewSessionError? get error => _error;

  /// Whether the machine's agent list is still being fetched (the fallback
  /// list is shown meanwhile).
  bool get loadingKinds => _machineId != null && _loading.contains(_machineId);

  /// Agent kinds to offer, plus the chosen one if herdr does not list it.
  List<String> get kinds {
    final listed = _manifests[_machineId] ?? fallbackAgentKinds;
    return [...listed, if (_kind != null && !listed.contains(_kind)) _kind!];
  }

  List<String> get recent {
    final m = machine;
    return m == null ? const [] : recentFolders(m.snapshot);
  }

  /// The command for [kind] on the chosen machine: what the person last
  /// typed for it there, else its own name.
  String commandFor(String kind) {
    final id = _machineId;
    return (id == null ? null : _settings.commandFor(id, kind)) ?? kind;
  }

  void selectMachine(String id) {
    if (id == _machineId) return;
    _machineId = id;
    _kind = _rememberedKind();
    _error = null;
    _loadKinds();
    _changed();
  }

  void selectKind(String? kind) {
    if (kind == _kind) return;
    _kind = kind;
    _error = null;
    _changed();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Starts the session. Null when it did not start; [error] says why. The
  /// caller opens the returned pane.
  Future<NewSessionLaunch?> start(NewSessionValues values) async {
    if (_busy) return null;
    final m = machine;
    final folder = values.folder.trim();
    if (m == null) {
      return _fail(const NewSessionError('No machine online', 'Pick a machine that is online.'));
    }
    final kind = _kind;
    final command = values.command.trim();
    final problem = folderError(folder) ?? (kind == null ? null : commandError(command));
    if (problem != null) return _fail(NewSessionError('Check the form', problem));

    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final name = values.name.trim();
      final prompt = values.prompt.trim();
      final launched = await _launcherFor(m).launch(LaunchRequest(
        folder: folder,
        label: name.isEmpty ? defaultWorkspaceName(folder) : name,
        command: kind == null ? null : command,
        prompt: kind == null || prompt.isEmpty ? null : prompt,
      ));
      unawaited(_settings.remember(
        machineId: m.profile.id,
        kind: kind ?? '',
        command: kind == null ? null : command,
      ));
      final failure = launched.commandError;
      return NewSessionLaunch(
        machine: m,
        paneId: launched.paneId,
        notice: failure == null
            ? null
            : 'The workspace was created, but its command could not be sent '
                '(${_say(failure)}). Type it in the terminal.',
        prompt: launched.prompt,
      );
    } on Exception catch (e) {
      return _fail(describeLaunchFailure(e, m, folder));
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  static String _say(Object e) => switch (e) {
        HerdrApiException(:final message) => message,
        HerdrTransportException(:final message) => message,
        _ => '$e',
      };

  NewSessionLaunch? _fail(NewSessionError error) {
    _error = error;
    if (!_disposed) notifyListeners();
    return null;
  }

  String? _initialMachine(String? preferred) {
    final online = machines;
    for (final id in [preferred, _settings.lastMachineId]) {
      if (id != null && online.any((c) => c.profile.id == id)) return id;
    }
    return online.firstOrNull?.profile.id;
  }

  String? _rememberedKind() {
    final id = _machineId;
    final saved = id == null ? null : _settings.kindFor(id);
    return saved == null || saved.isEmpty ? null : saved;
  }

  Future<void> _loadKinds() async {
    final m = machine;
    if (m == null) return;
    final id = m.profile.id;
    if (_manifests.containsKey(id) || !_loading.add(id)) return;
    List<String> kinds;
    try {
      kinds = await m.api.agentManifests().timeout(manifestTimeout);
    } on Object {
      kinds = const [];
    }
    _loading.remove(id);
    // Only what herdr itself lists is worth replacing the fallback with.
    _manifests[id] = kinds.isEmpty ? fallbackAgentKinds : kinds.toSet().toList();
    _changed();
  }

  /// The machines that can be picked, the one chosen, and what the form shows
  /// from its snapshot. A fleet that changes only in unrelated ways (an agent
  /// elsewhere changing status) must not rebuild the form.
  String _signatureNow() =>
      '${machines.map((c) => c.profile.id).join(',')}|$_machineId|${recent.join(',')}';

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
