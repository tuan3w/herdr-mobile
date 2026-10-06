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

/// What to start: a plain shell in [folder] named [label].
class LaunchRequest {
  const LaunchRequest({required this.folder, this.label});

  /// An absolute path, or `~` / `~/...`.
  final String folder;
  final String? label;
}

class LaunchedSession {
  const LaunchedSession({required this.workspaceId, required this.paneId});

  final String workspaceId;
  final String paneId;
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

/// Starts a workspace with a plain shell, with only calls every herdr version
/// has: `workspace.create`, then typing into the new pane. (herdr's own
/// `agent.start` is newer and would tie this to one version.)
class SessionLauncher {
  SessionLauncher(this.machine);

  final MachineConnection machine;

  /// Throws what [HerdrApi.createWorkspace] throws when nothing was created,
  /// and [FolderNotFoundException] (after removing the workspace again) when
  /// the folder is missing. A home folder (`~`) is reached by typing a `cd`
  /// into the new shell; if that fails the error is thrown and the workspace
  /// stays, an empty shell the person can close.
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

    if (home) await api.sendLine(created.rootPaneId, cdLine(request.folder));
    await _refresh();
    return LaunchedSession(workspaceId: created.workspaceId, paneId: created.rootPaneId);
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
}
