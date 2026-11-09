import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/machine_layout.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../agents/agent_navigation.dart';
import 'machine_actions.dart';
import 'machine_field.dart' show shortPath;
import 'new_agent_session_screen.dart';
import 'rename_sheet.dart';
import 'session_prefill.dart';

/// What can be done to a workspace: a new tab, a new name, closing it. A
/// worktree's workspace also starts a session in its folder, and a linked one
/// can be removed (held, never forced).
Future<void> showWorkspaceActions(BuildContext context, MachineConnection machine, Workspace workspace) {
  final name = workspace.label.isEmpty ? workspace.id : workspace.label;
  final actions = MachineActions(machine);
  final toaster = Toaster.of(context);
  final navigator = Navigator.of(context);

  void toast(String text) => toaster.show(text, kind: ToastKind.failed);

  Future<void> newTab() async {
    final r = await actions.newTab(workspace);
    if (r.error case final error?) return toast(error);
    if (r.paneId case final paneId?) {
      // The navigator outlives the sheet that started this.
      // ignore: use_build_context_synchronously
      await openAgent(navigator.context, PaneAgent(machine.profile.id, paneId));
    }
  }

  Future<void> rename() async {
    final label = await showRenameSheet(
      navigator.context,
      title: 'Rename workspace',
      label: 'Name',
      initial: workspace.label,
    );
    if (label == null || label == workspace.label) return;
    if (await actions.renameWorkspace(workspace.id, label) case final error?) toast(error);
  }

  Future<void> close() async {
    final panes = workspace.paneCount;
    final ok = await showConfirmSheet(
      navigator.context,
      title: 'Close $name?',
      message:
          '${panes <= 1 ? 'What is running in it stops. This can’t be undone.' : 'Its $panes panes and whatever runs in them stop. This can’t be undone.'}'
          '${workspace.worktree?.isLinked == true ? ' The folder stays on disk: remove it from Closed worktrees.' : ''}',
      confirmLabel: 'Close workspace',
    );
    if (!ok) return;
    if (await actions.closeWorkspace(workspace.id) case final error?) toast(error);
    // A closed worktree's folder is still there: the Closed worktrees list shows it.
    if (workspace.worktree != null && machine.isLive) unawaited(machine.loadBranches(every: true));
  }

  void newSessionHere(WorkspaceWorktree worktree) {
    // The navigator outlives the sheet that started this.
    unawaited(
      openNewAgentSession(
        navigator.context,
        machine: machine,
        prefill: SessionPrefill(machineId: machine.profile.id, folder: worktree.checkoutPath),
      ),
    );
  }

  final worktree = workspace.worktree;
  // A primary that still has linked worktrees open cannot be closed alone:
  // herdr refuses (`workspace_group_close_required`) and the phone never sends
  // `close_group`, so the row says what to do first.
  final worktreesOpen =
      worktree != null &&
      !worktree.isLinked &&
      machine.snapshot.workspaces.any(
        (o) =>
            o.id != workspace.id &&
            o.worktree != null &&
            o.worktree!.isLinked &&
            o.worktree!.repoKey == worktree.repoKey,
      );

  return showActionSheet(
    context,
    title: name,
    actions: [
      if (worktree != null)
        SheetAction(label: 'New agent session here', icon: LucideIcons.plus, onTap: () => newSessionHere(worktree)),
      SheetAction(label: 'New tab here', icon: LucideIcons.plus, onTap: newTab),
      SheetAction(label: 'Rename', icon: LucideIcons.pencil, onTap: rename),
      if (worktree != null && worktree.isLinked)
        SheetAction(
          label: 'Remove worktree',
          icon: LucideIcons.gitBranchMinus,
          destructive: true,
          onTap: () => confirmRemoveWorktree(
            navigator.context,
            machine,
            path: worktree.checkoutPath,
            workspaceId: workspace.id,
            name: machine.places.ofWorkspace(workspace.id)?.checkoutName ?? name,
            toaster: toaster,
          ),
        ),
      SheetAction(
        label: 'Close workspace',
        icon: LucideIcons.trash2,
        destructive: true,
        onTap: close,
        unavailable: worktreesOpen ? 'Worktrees are open · close them first' : null,
      ),
    ],
  );
}

/// Asks (with a hold, never forced) and removes the linked worktree at [path]:
/// its folder goes, its branch stays. [workspaceId] is the workspace herdr has
/// open for it; null when herdr has it closed, and then [repoPath] (the repo's
/// main checkout) is how herdr opens it to remove it. [note] is one sentence added to
/// what is lost (the agent screen says this session loses its folder). Says
/// in a toast what happened. [toaster]: one taken before a gap, for a
/// [context] that is the navigator's own.
Future<void> confirmRemoveWorktree(
  BuildContext context,
  MachineConnection machine, {
  required String path,
  String? workspaceId,
  String? repoPath,
  String? name,
  String? note,
  Toaster? toaster,
}) async {
  final toasts = toaster ?? Toaster.of(context);
  final worktreeName =
      name ?? (workspaceId == null ? null : machine.places.ofWorkspace(workspaceId)?.checkoutName) ?? _folderName(path);
  final branch = machine.branchOf(path);
  final lost = workspaceId != null ? _agentsWorkingIn(machine, workspaceId) : _agentsInFolder(machine, path);
  final ok = await showConfirmSheet(
    context,
    title: 'Remove $worktreeName?',
    confirmLabel: 'Remove worktree',
    hold: true,
    message:
        'Deletes the folder ${shortPath(path)} on ${machine.profile.label}. '
        '${branch == null ? 'The branch stays. ' : 'The branch $branch stays. '}'
        '${lost.stop > 0 ? '${countOf(lost.stop, 'agent')} working there will stop. ' : ''}'
        '${lost.lose > 0 ? '${countOf(lost.lose, 'phone session')} running there will lose the folder. ' : ''}'
        '${note == null ? '' : '$note '}'
        'If it has uncommitted changes, git refuses and nothing is deleted.',
  );
  if (!ok) return;
  if (await MachineActions(machine).removeWorktree(path: path, workspaceId: workspaceId, repoPath: repoPath)
      case final error?) {
    toasts.show(error, kind: ToastKind.failed);
    return;
  }
  toasts.show('Removed $worktreeName');
}

/// The last folder of [path]: what the person sees on disk.
String _folderName(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// The agents working or blocked under the checkout [workspaceId] on the
/// machine screen, split by what removing the worktree does to them: agents
/// in the checkout's own workspace stop with it; a phone session keeps running
/// (its keeper is a daemon, the pane is only a viewer, in this workspace or
/// another) and loses its folder.
({int stop, int lose}) _agentsWorkingIn(MachineConnection machine, String workspaceId) {
  final items = machineLayout(machine.snapshot, machine.places, machine.keeperPanes.keys.toSet());
  final List<PaneEntry> panes = [
    for (final item in items)
      ...switch (item) {
        RepoItem() => [
          for (final b in item.blocks)
            if (b.workspace.id == workspaceId) ...b.panes,
        ],
        WorkspaceItem() => item.workspace.id == workspaceId ? item.panes : const <PaneEntry>[],
      },
  ];
  var stop = 0;
  var lose = 0;
  for (final e in panes) {
    final busy = e.pane.agent != null && (e.pane.status == AgentStatus.working || e.pane.status == AgentStatus.blocked);
    if (!busy) continue;
    if (e.pane.workspaceId == workspaceId && !machine.keeperPanes.containsKey(e.pane.id)) {
      stop++;
    } else {
      lose++;
    }
  }
  return (stop: stop, lose: lose);
}

/// The agents working or blocked anywhere on the machine in [path] or below,
/// for a checkout herdr has no workspace for: none of them stops with it (no
/// workspace of the checkout is closed), they all lose the folder.
({int stop, int lose}) _agentsInFolder(MachineConnection machine, String path) {
  final prefix = path.endsWith('/') ? path : '$path/';
  var lose = 0;
  for (final p in machine.snapshot.panes) {
    final cwd = p.cwd;
    final busy = p.agent != null && (p.status == AgentStatus.working || p.status == AgentStatus.blocked);
    if (busy && cwd != null && (cwd == path || cwd.startsWith(prefix))) lose++;
  }
  return (stop: 0, lose: lose);
}

/// Asks before closing [pane] (it stops what runs there, and the last pane
/// takes its workspace along), closes it, and says so when that failed.
/// [toaster]: one taken before a gap, for a [context] that is the navigator's
/// own (above its overlay, so it has none to toast in).
Future<void> confirmClosePane(BuildContext context, MachineConnection machine, Pane pane, {Toaster? toaster}) async {
  final toasts = toaster ?? Toaster.of(context);
  final last = (machine.snapshot.workspace(pane.workspaceId)?.paneCount ?? 2) <= 1;
  final ok = await showConfirmSheet(
    context,
    title: 'Close this pane?',
    message: last
        ? 'It is the last pane in its workspace, so the workspace closes too. '
              'What is running in it stops.'
        : 'What is running in it stops. This can’t be undone.',
    confirmLabel: 'Close pane',
  );
  if (!ok) return;
  if (await MachineActions(machine).closePane(pane.id) case final error?) {
    toasts.show(error, kind: ToastKind.failed);
  }
}

/// What can be done to a pane: a new name, closing it.
Future<void> showPaneActions(BuildContext context, MachineConnection machine, Pane pane, {required String title}) {
  final actions = MachineActions(machine);
  final toaster = Toaster.of(context);
  final navigator = Navigator.of(context);

  void toast(String text) => toaster.show(text, kind: ToastKind.failed);

  Future<void> rename() async {
    final label = await showRenameSheet(
      navigator.context,
      title: 'Rename pane',
      label: 'Name',
      initial: pane.label ?? '',
      helper: 'Leave empty to show the program’s own title',
      allowEmpty: true,
    );
    if (label == null || label == (pane.label ?? '')) return;
    if (await actions.renamePane(pane.id, label) case final error?) toast(error);
  }

  Future<void> close() => confirmClosePane(navigator.context, machine, pane, toaster: toaster);

  return showActionSheet(
    context,
    title: title,
    actions: [
      SheetAction(label: 'Rename', icon: LucideIcons.pencil, onTap: rename),
      SheetAction(label: 'Close pane', icon: LucideIcons.trash2, destructive: true, onTap: close),
    ],
  );
}
