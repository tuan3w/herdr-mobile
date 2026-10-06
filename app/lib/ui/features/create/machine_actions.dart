import 'dart:async';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/herdr_transport.dart';

/// Renames and closes things on one machine. Every method returns null when it
/// worked and a sentence for the person when it did not, and refreshes the
/// machine either way so the lists show what is really there.
class MachineActions {
  MachineActions(this.machine);

  final MachineConnection machine;

  Future<String?> renameWorkspace(String workspaceId, String label) =>
      _run(() => machine.api.renameWorkspace(workspaceId, label));

  Future<String?> renamePane(String paneId, String label) =>
      _run(() => machine.api.renamePane(paneId, label));

  /// Already gone counts as closed: that is what the person wanted.
  Future<String?> closeWorkspace(String workspaceId) =>
      _run(() => machine.api.closeWorkspace(workspaceId), goneIsFine: true);

  Future<String?> closePane(String paneId) =>
      _run(() => machine.api.closePane(paneId), goneIsFine: true);

  /// Adds a tab to [workspace], in the folder its first pane is in.
  Future<({String? error, String? paneId})> newTab(Workspace workspace) async {
    String? paneId;
    final error = await _run(() async {
      paneId = (await machine.api.createTab(
        workspaceId: workspace.id,
        cwd: _folderOf(workspace),
      ))
          .rootPaneId;
    });
    return (error: error, paneId: error == null ? paneId : null);
  }

  /// Where the workspace is working: the cwd of its first pane that has one.
  String? _folderOf(Workspace workspace) {
    final snap = machine.snapshot;
    for (final tab in snap.tabsOf(workspace.id)) {
      for (final pane in snap.panesOf(tab.id)) {
        final cwd = pane.cwd;
        if (cwd != null && cwd.startsWith('/')) return cwd;
      }
    }
    return null;
  }

  Future<String?> _run(Future<void> Function() call, {bool goneIsFine = false}) async {
    String? problem;
    try {
      await call();
    } on HerdrUnsupportedException {
      final v = machine.snapshot.version;
      problem = "herdr${v.isEmpty ? '' : ' $v'} on ${machine.profile.label} can't do this. "
          'Update herdr on that machine.';
    } on HerdrApiException catch (e) {
      if (e.isNotFound) {
        problem = goneIsFine ? null : 'It was already closed on the machine.';
      } else {
        problem = e.message;
      }
    } on HerdrTransportException catch (e) {
      problem = e.message;
    } on TimeoutException {
      problem = 'The machine did not answer in time.';
    }
    try {
      await machine.refresh().timeout(const Duration(seconds: 5));
    } on Exception {
      // Offline or slow: events bring the lists up to date when it returns.
    }
    return problem;
  }
}
