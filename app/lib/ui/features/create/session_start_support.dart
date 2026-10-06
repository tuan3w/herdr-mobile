import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/session_launcher.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/herdr_transport.dart';
import '../../core/toast.dart';

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

class NewSessionError {
  const NewSessionError(this.title, this.message);

  final String title;
  final String message;
}

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

/// What a start that stays on the board says: what started, where, with a way
/// to open it. It replaces a toast still showing from the start before, so
/// launching several in a row never queues them.
void showStartedToast(
  Toaster toaster, {
  required String message,
  required VoidCallback onOpen,
}) =>
    toaster.show(message, kind: ToastKind.success, action: ToastAction('Open', onOpen));
