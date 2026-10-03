import 'dart:async';

import '../models/herdr_models.dart';
import 'machine_connection.dart';

/// Quotes [value] as one shell word.
String quoteShell(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Whether [folder] is the home directory or inside it (`~`, `~/code`).
bool isHomeFolder(String folder) => folder == '~' || folder.startsWith('~/');

/// The shell line that goes to the folder [folder] (see [isHomeFolder]).
///
/// herdr does not expand `~`, so the shell does, with `$HOME` outside the
/// quotes and the rest of the path quoted: a folder name with a space, a quote
/// or a `$(...)` is data here, never code.
String cdLine(String folder) {
  final rest = folder.length > 2 ? folder.substring(2) : '';
  return rest.isEmpty ? r'cd -- "$HOME"' : 'cd -- "\$HOME"/${quoteShell(rest)}';
}

/// What to start: a workspace in [folder] named [label], optionally running
/// [command], and then [prompt] once the agent it starts is up.
class LaunchRequest {
  const LaunchRequest({
    required this.folder,
    this.label,
    this.command,
    this.prompt,
  });

  /// An absolute path, or `~` / `~/...`.
  final String folder;
  final String? label;

  /// One line typed into the new shell. Null for a plain shell.
  final String? command;
  final String? prompt;
}

enum PromptOutcome {
  sent,

  /// No agent showed up in time; the prompt was not sent.
  timedOut,

  /// The pane was closed while waiting.
  gone,

  /// The agent was up but the machine refused the input.
  failed,
}

class LaunchedSession {
  const LaunchedSession({
    required this.workspaceId,
    required this.paneId,
    this.commandError,
    this.prompt,
  });

  final String workspaceId;
  final String paneId;

  /// Why the command could not be sent, when the workspace exists anyway.
  final Object? commandError;

  /// Completes when the first prompt has been sent, or given up on. Null when
  /// there was no prompt to send.
  final Future<PromptOutcome>? prompt;
}

/// herdr opened the workspace in [actual], not [folder]: it falls back to the
/// home directory when the folder does not exist.
class FolderNotFoundException implements Exception {
  const FolderNotFoundException(this.folder, this.actual);

  final String folder;
  final String actual;

  @override
  String toString() => '$folder does not exist';
}

/// Starts a workspace and what runs in it, with only calls every herdr
/// version has: `workspace.create`, then typing into the new pane. (herdr's
/// own `agent.start` is newer and would tie this to one version.)
class SessionLauncher {
  SessionLauncher(
    this.machine, {
    this.promptTimeout = const Duration(seconds: 20),
    this.pollInterval = const Duration(seconds: 1),
  });

  final MachineConnection machine;

  /// How long to wait for the agent before giving up on the first prompt.
  final Duration promptTimeout;

  /// Safety-net refresh while waiting; the connection's own events usually
  /// get there first.
  final Duration pollInterval;

  /// Throws what [HerdrApi.createWorkspace] throws when nothing was created,
  /// and [FolderNotFoundException] (after removing the workspace again) when
  /// the folder is missing. Failing to type the command is reported in the
  /// result instead, because the workspace then exists and is worth opening.
  Future<LaunchedSession> launch(LaunchRequest request) async {
    final api = machine.api;
    final home = isHomeFolder(request.folder);
    final created = await api.createWorkspace(
      cwd: home ? null : request.folder,
      label: request.label,
      focus: false,
    );

    final actual = created.cwd;
    if (!home && actual != null && _trimSlash(actual) != _trimSlash(request.folder)) {
      try {
        await api.closeWorkspace(created.workspaceId);
      } on Exception {
        // Left behind, it is an empty shell the person can close.
      }
      await _refresh();
      throw FolderNotFoundException(request.folder, actual);
    }

    final command = request.command;
    final line = home
        ? (command == null ? cdLine(request.folder) : '${cdLine(request.folder)} && $command')
        : command;
    Object? commandError;
    if (line != null) {
      try {
        await api.sendLine(created.rootPaneId, line);
      } on Exception catch (e) {
        commandError = e;
      }
    }
    await _refresh();

    final prompt = request.prompt;
    return LaunchedSession(
      workspaceId: created.workspaceId,
      paneId: created.rootPaneId,
      commandError: commandError,
      prompt: commandError == null && command != null && prompt != null && prompt.isNotEmpty
          ? _deliverPrompt(created.rootPaneId, prompt)
          : null,
    );
  }

  static String _trimSlash(String path) =>
      path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// Best effort: the list refreshes by itself soon enough if this fails.
  Future<void> _refresh() async {
    try {
      await machine.refresh().timeout(const Duration(seconds: 5));
    } on Exception {
      // Offline or slow; events and the poll bring the snapshot up to date.
    }
  }

  Future<PromptOutcome> _deliverPrompt(String paneId, String prompt) async {
    final waited = await _waitForAgent(paneId);
    if (waited != null) return waited;
    try {
      await machine.api.sendLine(paneId, prompt);
      return PromptOutcome.sent;
    } on Exception {
      return PromptOutcome.failed;
    }
  }

  /// Null once the pane reports an agent (or any status but unknown); else why
  /// it never did. Driven by the connection's change notifications, plus a
  /// poll as a safety net.
  Future<PromptOutcome?> _waitForAgent(String paneId) {
    final done = Completer<PromptOutcome?>();
    var seen = false;

    void check() {
      if (done.isCompleted) return;
      Pane? pane;
      for (final p in machine.snapshot.panes) {
        if (p.id == paneId) pane = p;
      }
      if (pane == null) {
        // Not in the snapshot yet is normal right after creating it; gone
        // after having been there means somebody closed it.
        if (seen) done.complete(PromptOutcome.gone);
        return;
      }
      seen = true;
      if (pane.agent != null || pane.status != AgentStatus.unknown) done.complete(null);
    }

    try {
      machine.addListener(check);
    } on Object {
      return Future.value(PromptOutcome.gone); // the machine was removed
    }
    final poll = Timer.periodic(pollInterval, (_) {
      check();
      unawaited(machine.refresh().catchError((Object _) {}));
    });
    final timeout = Timer(promptTimeout, () {
      if (!done.isCompleted) done.complete(PromptOutcome.timedOut);
    });
    check();
    return done.future.whenComplete(() {
      poll.cancel();
      timeout.cancel();
      try {
        machine.removeListener(check);
      } on Object {
        // Disposed meanwhile: nothing left to unhook.
      }
    });
  }
}
