import 'package:herdr_mobile/l10n/l10n_context.dart';

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
      title: context.l10n.uiRenameWorkspace,
      label: context.l10n.uiName,
      initial: workspace.label,
    );
    if (label == null || label == workspace.label) return;
    if (await actions.renameWorkspace(workspace.id, label) case final error?) toast(error);
  }

  Future<void> close() async {
    final panes = workspace.paneCount;
    final ok = await showConfirmSheet(
      navigator.context,
      title: context.l10n.messageClose(name),
      message: panes <= 1
          ? context.l10n.uiWhatIsRunningInItStopsThisCanT
          : context.l10n.messageItsPanesAndWhateverRunsInThemStop('$panes'),
      confirmLabel: context.l10n.uiCloseWorkspace,
    );
    if (!ok) return;
    if (await actions.closeWorkspace(workspace.id) case final error?) toast(error);
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

  Future<void> removeWorktree(WorkspaceWorktree worktree) async {
    final words = context.l10n;
    final folder = worktree.checkoutPath;
    final worktreeName = machine.places.ofWorkspace(workspace.id)?.checkoutName ?? name;
    final branch = machine.branchOf(folder);
    final working = _agentsWorkingIn(machine, workspace.id);
    final ok = await showConfirmSheet(
      navigator.context,
      title: context.l10n.messageRemove53(worktreeName),
      confirmLabel: context.l10n.uiRemoveWorktree,
      hold: true,
      message: context.l10n.messageDeletesTheFolderOnIfItHasUncommitted(
        shortPath(folder),
        machine.profile.label,
        branch == null ? context.l10n.uiTheBranchStays : context.l10n.messageTheBranchStays(branch),
        working.stop > 0 ? context.l10n.messageWorkingThereWillStop(countOf(working.stop, 'agent')) : '',
        working.lose > 0
            ? context.l10n.messageRunningThereWillLoseTheFolder(countOf(working.lose, 'phone session'))
            : '',
      ),
    );
    if (!ok) return;
    if (await actions.removeWorktree(workspace) case final error?) return toast(error);
    toaster.show(words.messageRemoved(worktreeName));
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
        SheetAction(
          label: context.l10n.uiNewAgentSessionHere,
          icon: LucideIcons.plus,
          onTap: () => newSessionHere(worktree),
        ),
      SheetAction(label: context.l10n.uiNewTabHere, icon: LucideIcons.plus, onTap: newTab),
      SheetAction(label: context.l10n.uiRename, icon: LucideIcons.pencil, onTap: rename),
      if (worktree != null && worktree.isLinked)
        SheetAction(
          label: context.l10n.uiRemoveWorktree,
          icon: LucideIcons.gitBranchMinus,
          destructive: true,
          onTap: () => removeWorktree(worktree),
        ),
      SheetAction(
        label: context.l10n.uiCloseWorkspace,
        icon: LucideIcons.trash2,
        destructive: true,
        onTap: close,
        unavailable: worktreesOpen ? 'Worktrees are open · close them first' : null,
      ),
    ],
  );
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

/// What can be done to a pane: a new name, closing it.
Future<void> showPaneActions(BuildContext context, MachineConnection machine, Pane pane, {required String title}) {
  final actions = MachineActions(machine);
  final toaster = Toaster.of(context);
  final navigator = Navigator.of(context);

  void toast(String text) => toaster.show(text, kind: ToastKind.failed);

  Future<void> rename() async {
    final label = await showRenameSheet(
      navigator.context,
      title: context.l10n.uiRenamePane,
      label: context.l10n.uiName,
      initial: pane.label ?? '',
      helper: 'Leave empty to show the program’s own title',
      allowEmpty: true,
    );
    if (label == null || label == (pane.label ?? '')) return;
    if (await actions.renamePane(pane.id, label) case final error?) toast(error);
  }

  Future<void> close() async {
    final last = (machine.snapshot.workspace(pane.workspaceId)?.paneCount ?? 2) <= 1;
    final ok = await showConfirmSheet(
      navigator.context,
      title: context.l10n.uiCloseThisPane,
      message: last ? context.l10n.uiItIsTheLastPaneInItsWorkspaceSo : context.l10n.uiWhatIsRunningInItStopsThisCanT,
      confirmLabel: context.l10n.uiClosePane,
    );
    if (!ok) return;
    if (await actions.closePane(pane.id) case final error?) toast(error);
  }

  return showActionSheet(
    context,
    title: title,
    actions: [
      SheetAction(label: context.l10n.uiRename, icon: LucideIcons.pencil, onTap: rename),
      SheetAction(label: context.l10n.uiClosePane, icon: LucideIcons.trash2, destructive: true, onTap: close),
    ],
  );
}
