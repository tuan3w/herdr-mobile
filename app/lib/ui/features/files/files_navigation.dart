import 'package:flutter/material.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import 'file_browser_screen.dart';
import 'file_viewer_screen.dart';

/// Whether the transport can do file operations at all (false for fakes
/// without a file system, so callers hide their file actions).
bool machineSupportsFiles(MachineConnection machine) => machine.files.supported;

/// Resolves [path] (absolute, `~/...`, or relative to [cwd]), strips a trailing
/// `:line:col`, stats it, and pushes the file viewer, or the browser for a
/// directory. A failure (not found, permission, no SFTP, ...) is a quiet toast.
Future<void> openRemoteFile(
  BuildContext context,
  MachineConnection machine,
  String path, {
  String? cwd,
  int? line,
}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void toast(String message) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  if (!machineSupportsFiles(machine)) {
    toast('Files are not available on this machine.');
    return;
  }
  final loc = RemotePath.splitLocation(path);
  try {
    var abs = await machine.files.resolve(loc.path, cwd: cwd);
    var at = line ?? loc.line;
    RemoteStat stat;
    try {
      stat = await machine.files.stat(abs);
    } on RemoteFileException catch (e) {
      // `notes:2024` may really be the file's name.
      if (e.kind != RemoteFileErrorKind.notFound || loc.path == path.trim()) rethrow;
      abs = await machine.files.resolve(path, cwd: cwd);
      stat = await machine.files.stat(abs);
      at = line;
    }
    if (!navigator.mounted) return;
    final target = abs;
    final shown = at;
    if (stat.isDirectory) {
      await navigator.push(MaterialPageRoute<void>(
        builder: (_) => FileBrowserScreen(machine: machine, path: target),
      ));
    } else {
      await navigator.push(MaterialPageRoute<void>(
        builder: (_) => FileViewerScreen(machine: machine, stat: stat, line: shown),
      ));
    }
  } on RemoteFileException catch (e) {
    toast(_toastMessage(e, path));
  }
}

/// Pushes the directory browser, starting at [startDir] (the login directory
/// when null).
Future<void> openFileBrowser(
  BuildContext context,
  MachineConnection machine, {
  String? startDir,
}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  if (!machineSupportsFiles(machine)) {
    messenger.showSnackBar(const SnackBar(content: Text('Files are not available on this machine.')));
    return;
  }
  final start = await _startDirectory(machine, startDir);
  if (!navigator.mounted) return;
  await navigator.push(MaterialPageRoute<void>(
    builder: (_) => FileBrowserScreen(machine: machine, path: start),
  ));
}

/// Directory picker for forms: returns the chosen absolute path, or null when
/// dismissed.
Future<String?> pickRemoteDirectory(
  BuildContext context,
  MachineConnection machine, {
  String? startDir,
}) async {
  final navigator = Navigator.of(context);
  if (!machineSupportsFiles(machine)) return null;
  final start = await _startDirectory(machine, startDir);
  if (!navigator.mounted) return null;
  return navigator.push<String>(MaterialPageRoute<String>(
    builder: (_) => FileBrowserScreen(
      machine: machine,
      path: start,
      mode: FileBrowserMode.pickDirectory,
    ),
  ));
}

/// [startDir] resolved to an absolute path, else home, else `/`. A start path
/// that cannot be resolved does not stop the browser from opening: it shows
/// its own error for that folder.
Future<String> _startDirectory(MachineConnection machine, String? startDir) async {
  try {
    if (startDir != null && startDir.trim().isNotEmpty) {
      return await machine.files.resolve(startDir);
    }
    return await machine.files.home();
  } on RemoteFileException {
    return startDir != null && RemotePath.isAbsolute(startDir) ? startDir : '/';
  }
}

String _toastMessage(RemoteFileException e, String path) {
  final name = RemotePath.basename(RemotePath.splitLocation(path).path);
  return switch (e.kind) {
    RemoteFileErrorKind.notFound => "$name doesn't exist on this machine.",
    RemoteFileErrorKind.permission => "You don't have permission to open $name.",
    RemoteFileErrorKind.tooLarge => '$name is too large to open.',
    RemoteFileErrorKind.unsupported => e.message,
    RemoteFileErrorKind.notAFile || RemoteFileErrorKind.notADirectory => e.message,
    RemoteFileErrorKind.network || RemoteFileErrorKind.failed => "Couldn't reach the machine: ${e.message}",
  };
}
