import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/theme.dart';
import '../files/files_navigation.dart';
import 'pane_screen.dart' show shortScreen;
import 'pane_view_model.dart';

/// The bar's height (below the status bar): two text lines in a 44dp-high
/// title target, and 44dp buttons. A short screen ([shortScreen]) gets less.
const _barHeight = 56.0;
const _shortBarHeight = 52.0;

/// What the bar says about the pane: its task (the agent, then the pane id,
/// when it has none), where it runs (`agent · machine`, the agent left out
/// when it is the title), its status (null: the pane is gone) and whether its
/// machine is online. A record, so an equal one means nothing visible changed.
typedef PaneTitle = ({String title, String where, AgentStatus? status, bool live});

/// The pane as [machine]'s snapshot shows it now. [known] is what it said
/// last, used when the pane (or its whole machine) has vanished, so the bar
/// keeps its name.
PaneTitle paneTitle(MachineConnection? machine, String machineId, String paneId, {PaneTitle? known}) {
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
  final task = pane.title.trim();
  final title = task.isNotEmpty ? task : (pane.agent ?? paneId);
  final agent = pane.agent;
  return (
    title: title,
    where: [if (agent != null && agent != title) agent, machine!.profile.label].join(' · '),
    status: pane.status,
    live: machine.isLive,
  );
}

/// The one bar above the pane: back, the status glyph beside the task title
/// over where it lives, a button for the machine's files, the wrap toggle and
/// the options (`PaneBarActions`: the other view, Duplicate, copy the title or
/// the pane id). The title is not a button: the options have one way in.
/// No bottom border: the terminal panel below anchors it.
///
/// About 56dp high (52 on a short screen); the raw pane id is not shown (the
/// options have it).
class PaneTopBar extends StatelessWidget {
  const PaneTopBar({super.key, required this.title, required this.viewModel, required this.actions});

  final ValueListenable<PaneTitle?> title;
  final PaneViewModel? viewModel;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final secondary = Type.secondary.copyWith(color: ds.textSecondary);
    final height = MediaQuery.sizeOf(context).height < shortScreen ? _shortBarHeight : _barHeight;
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Row(
          children: [
            CircleButton(
              icon: LucideIcons.chevronLeft,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: ValueListenableBuilder<PaneTitle?>(
                valueListenable: title,
                builder: (context, info, _) {
                  if (info == null) return const SizedBox.shrink();
                  final status = info.status;
                  // One node: a header that reads status, task and place once.
                  return MergeSemantics(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: height),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                        child: Row(
                          children: [
                            // The glyph names the status for screen
                            // readers; no text repeats it.
                            if (status == null)
                              Icon(LucideIcons.squareX, size: 16, color: ds.textTertiary)
                            else
                              _TitleGlyph(status: status, live: info.live, viewModel: viewModel),
                            const SizedBox(width: Gap.sm),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Semantics(
                                    header: true,
                                    child: Text(
                                      info.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Type.barTitle.copyWith(color: ds.text),
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(info.where, maxLines: 1, overflow: TextOverflow.ellipsis, style: secondary),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            actions,
          ],
        ),
      ),
    );
  }
}

/// The machine's files and the wrap toggle, as the bar shows them.
class PaneBarActions extends StatelessWidget {
  const PaneBarActions({
    super.key,
    required this.machine,
    required this.onToggleWrap,
    required this.onOpenFiles,
    required this.onMore,
  });

  final MachineConnection? machine;
  final VoidCallback? onToggleWrap;
  final VoidCallback? onOpenFiles;

  /// The pane's options sheet: the one place for everything that is not
  /// needed on every visit (the other view, Duplicate, copying the title).
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final files = machine != null && machineSupportsFiles(machine!) && onOpenFiles != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (files) CircleButton(icon: LucideIcons.folderOpen, tooltip: 'Browse files', onPressed: onOpenFiles),
        CircleButton(
          icon: LucideIcons.wrapText,
          tooltip: wrap ? 'Show exact terminal layout' : 'Wrap lines to screen',
          active: wrap,
          onPressed: onToggleWrap,
        ),
        CircleButton(icon: LucideIcons.ellipsis, tooltip: 'Pane options', onPressed: onMore),
      ],
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
    if (vm == null) return StatusGlyph(status: status, size: 16, dim: !live);
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) => StatusGlyph(status: status, size: 16, dim: !live || vm.isStale),
    );
  }
}
