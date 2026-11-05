import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/agent_screens.dart' show PaneAgent;
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/agent_names.dart';
import '../../../data/words/where_line.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../agents/agent_switcher.dart' show AgentSwitchMark, othersNeedingYou, showAgentSwitcher, switchAgentLabel;
import '../files/files_navigation.dart';
import 'pane_view_model.dart';

/// What the bar says about the pane: its task (the agent, then the pane id,
/// when it has none), where it runs (`agent · machine`, the agent left out
/// when it is the title), its status (null: the pane is gone) and whether its
/// machine is online. A record, so an equal one means nothing visible changed.
typedef PaneTitle = ({String title, String where, AgentStatus? status, bool live});

/// The pane as [machine]'s snapshot shows it now. [known] is what it said
/// last, used when the pane (or its whole machine) has vanished, so the bar
/// keeps its name. [named] is the name read from the agent's session log for a
/// pane whose own title says nothing (`FleetAgent.betterTitle`): the board
/// calls it the same.
PaneTitle paneTitle(MachineConnection? machine, String machineId, String paneId, {PaneTitle? known, String? named}) {
  final pane = machine?.paneById(paneId);
  if (pane == null) {
    return (
      title: known?.title ?? paneId,
      where: known?.where ?? machine?.profile.label ?? machineId,
      status: null,
      // A machine that answers and has no such pane is not "stale", it is
      // closed; a machine that does not answer cannot say.
      live: machine?.isLive ?? false,
    );
  }
  final task = named ?? pane.title.trim();
  final agent = agentName(pane.agent);
  final title = task.isNotEmpty ? task : agent;
  return (
    title: title,
    where: whereLine(agent: agent, machine: machine!.profile.label, title: title),
    status: pane.status,
    live: machine.isLive,
  );
}

/// The one bar above the pane ([AppTopBar]): back, the status glyph beside
/// the task title over where it lives, a button for the machine's files and
/// the options (the other view, Duplicate, wrap lines, copy the title or the
/// pane id). The title is the agent switcher, as in the chat's bar: a
/// chevron, the count of other agents that need the person, and a tap that
/// lists them ([showAgentSwitcher]). No bottom border: the terminal panel
/// below anchors it. The raw pane id is not shown (the options have it).
class PaneTopBar extends StatelessWidget {
  const PaneTopBar({
    super.key,
    required this.agent,
    required this.title,
    required this.viewModel,
    required this.machine,
    required this.onOpenFiles,
    required this.onMore,
  });

  /// The pane this bar is for: the switcher's `Here`.
  final PaneAgent agent;
  final ValueListenable<PaneTitle?> title;
  final PaneViewModel? viewModel;
  final MachineConnection? machine;
  final VoidCallback? onOpenFiles;

  /// The pane's options sheet: the one place for everything that is not
  /// needed on every visit.
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final machine = this.machine;
    final files = machine != null && machineSupportsFiles(machine) && onOpenFiles != null;
    final actions = [
      if (files) CircleButton(icon: HerdrIcons.folder, tooltip: 'Browse files', onPressed: onOpenFiles),
      CircleButton(icon: LucideIcons.ellipsis, tooltip: 'Pane options', onPressed: onMore),
    ];
    // Rebuilds the bar only when the count changes.
    final others = othersNeedingYou(context, agent);
    return ValueListenableBuilder<PaneTitle?>(
      valueListenable: title,
      builder: (context, info, _) {
        final status = info?.status;
        return AppTopBar(
          title: info?.title ?? '',
          onTitleTap: () => unawaited(showAgentSwitcher(context, agent)),
          titleTapLabel: switchAgentLabel,
          titleTrailing: AgentSwitchMark(othersNeedYou: others),
          subtitle: info?.where,
          // The glyph names the status for screen readers; no text repeats it.
          glyph: info == null
              ? null
              : status == null
              ? Icon(LucideIcons.squareX, size: IconSize.row, color: ds.textTertiary)
              : _TitleGlyph(status: status, live: info.live, viewModel: viewModel),
          actions: actions,
        );
      },
    );
  }
}

/// The status glyph beside the title: dimmed while the machine is down or the
/// last read failed.
class _TitleGlyph extends StatelessWidget {
  const _TitleGlyph({required this.status, required this.live, required this.viewModel});

  final AgentStatus status;
  final bool live;
  final PaneViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final vm = viewModel;
    if (vm == null) return StatusGlyph(status: status, size: IconSize.row, dim: !live);
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) => StatusGlyph(status: status, size: IconSize.row, dim: !live || vm.isStale),
    );
  }
}
