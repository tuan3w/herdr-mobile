import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/chrome.dart';
import '../pane/pane_navigation.dart';
import 'machine_actions.dart';
import 'rename_sheet.dart';

/// What can be done to a workspace: a new tab, a new name, closing it.
Future<void> showWorkspaceActions(
  BuildContext context,
  MachineConnection machine,
  Workspace workspace,
) {
  final name = workspace.label.isEmpty ? workspace.id : workspace.label;
  final actions = MachineActions(machine);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  void toast(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

  Future<void> newTab() async {
    final r = await actions.newTab(workspace);
    if (r.error case final error?) return toast(error);
    if (r.paneId case final paneId?) {
      // The navigator outlives the sheet that started this.
      // ignore: use_build_context_synchronously
      await openPaneTab(navigator.context, machine, paneId);
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
      message: panes <= 1
          ? 'What is running in it stops. This cannot be undone.'
          : 'Its $panes panes and whatever runs in them stop. This cannot be undone.',
      confirmLabel: 'Close workspace',
    );
    if (!ok) return;
    if (await actions.closeWorkspace(workspace.id) case final error?) toast(error);
  }

  return showActionSheet(
    context,
    title: name,
    actions: [
      SheetAction(label: 'New tab here', icon: LucideIcons.plus, onTap: newTab),
      SheetAction(label: 'Rename', icon: LucideIcons.pencil, onTap: rename),
      SheetAction(
        label: 'Close workspace',
        icon: LucideIcons.trash2,
        destructive: true,
        onTap: close,
      ),
    ],
  );
}

/// What can be done to a pane: a new name, closing it.
Future<void> showPaneActions(
  BuildContext context,
  MachineConnection machine,
  Pane pane, {
  required String title,
}) {
  final actions = MachineActions(machine);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  void toast(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

  Future<void> rename() async {
    final label = await showRenameSheet(
      navigator.context,
      title: 'Rename pane',
      label: 'Name',
      initial: pane.label ?? '',
      helper: "Leave empty to show the program's own title",
      allowEmpty: true,
    );
    if (label == null || label == (pane.label ?? '')) return;
    if (await actions.renamePane(pane.id, label) case final error?) toast(error);
  }

  Future<void> close() async {
    final last = (machine.snapshot.workspace(pane.workspaceId)?.paneCount ?? 2) <= 1;
    final ok = await showConfirmSheet(
      navigator.context,
      title: 'Close this pane?',
      message: last
          ? 'It is the last pane in its workspace, so the workspace closes too. '
              'What is running in it stops.'
          : 'What is running in it stops. This cannot be undone.',
      confirmLabel: 'Close pane',
    );
    if (!ok) return;
    if (await actions.closePane(pane.id) case final error?) toast(error);
  }

  return showActionSheet(
    context,
    title: title,
    actions: [
      SheetAction(label: 'Rename', icon: LucideIcons.pencil, onTap: rename),
      SheetAction(
        label: 'Close pane',
        icon: LucideIcons.trash2,
        destructive: true,
        onTap: close,
      ),
    ],
  );
}
