import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/machine_layout.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/agent_names.dart';
import '../../../data/words/where_line.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../agents/agent_navigation.dart';
import '../create/management_sheets.dart';

/// Past this many panes a workspace or checkout lists the first ones and offers
/// the rest behind "Show all": one with a hundred panes would otherwise build a
/// hundred rows at once (its rows are not in a lazy list).
const machinePaneCap = 30;

/// Moves a section's ⋯ right so its dots line up with the row chevrons.
const machineDotsNudge = 10.0;

/// The rows of one list of panes, cut at [machinePaneCap] unless [showAll] and
/// closed by the "Show all" row when something is cut. [folderOf] is the
/// folder part of a pane's second line: what the section above does not
/// already say.
List<RowSpec> machinePaneRows({
  required MachineConnection machine,
  required List<PaneEntry> entries,
  required bool showAll,
  required VoidCallback onShowAll,
  required String Function(Pane pane) folderOf,
}) {
  final live = machine.isLive;
  final rows = <RowSpec>[];
  for (final entry in entries) {
    if (!showAll && rows.length >= machinePaneCap) break;
    rows.add(
      CustomRow(
        id: entry.pane.id,
        dividerIndent: ListRow.textIndent(leadingExtent: MachinePaneRow.leadingExtent),
        child: RepaintBoundary(
          child: MachinePaneRow(
            machine: machine,
            pane: entry.pane,
            tabLabel: entry.tab,
            folder: folderOf(entry.pane),
            dim: !live,
          ),
        ),
      ),
    );
  }
  if (entries.length > rows.length) {
    rows.add(
      CustomRow(
        id: 'show-all',
        child: _ShowAllRow(total: entries.length, onTap: onShowAll),
      ),
    );
  }
  return rows;
}

/// "Show all 120 panes": the quiet row that ends a capped list.
class _ShowAllRow extends StatelessWidget {
  const _ShowAllRow({required this.total, required this.onTap});

  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PressRow(
    onTap: onTap,
    minHeight: _minHeight,
    // Aligned with the pane titles above.
    padding: EdgeInsetsDirectional.only(
      start: ListRow.textIndent(leadingExtent: MachinePaneRow.leadingExtent) - PressRow.inset,
      end: Gap.gutter - PressRow.inset,
    ),
    child: Text(
      context.l10n.messageShowAllPanes('$total'),
      style: Type.labelStrong.copyWith(color: context.ds.accentText),
    ),
  );

  /// A quiet closing row, lower than a pane row.
  static const _minHeight = 48.0;
}

class MachinePaneRow extends StatelessWidget {
  const MachinePaneRow({
    super.key,
    required this.machine,
    required this.pane,
    required this.tabLabel,
    required this.folder,
    required this.dim,
  });

  final MachineConnection machine;
  final Pane pane;
  final String? tabLabel;

  /// The folder part of the second line; empty when the section says it.
  final String folder;
  final bool dim;

  /// Leading column: the terminal tile is 28, so the glyphs share that width.
  static const leadingExtent = 28.0;

  @override
  Widget build(BuildContext context) {
    final agent = pane.agent;
    final name = agentName(agent);
    final title = pane.title.isNotEmpty ? pane.title : name;
    // whereLine's drop rules for the agent and the folder; the tab sits
    // between them, since a workspace with several tabs needs it as well as
    // the folder.
    final subtitle = [
      whereLine(agent: agent != null ? name : null, title: title),
      ?tabLabel,
      whereLine(folder: folder, title: title),
    ].where((s) => s.isNotEmpty).join(' · ');

    return ListRow(
      leading: agent != null
          ? StatusGlyph(status: pane.status, size: IconSize.lead)
          : const IconTile(icon: LucideIcons.squareTerminal, size: leadingExtent),
      leadingExtent: leadingExtent,
      title: title,
      titleMaxLines: 2,
      subtitle: subtitle,
      dim: dim,
      onLongPress: dim
          ? null
          : () {
              Haptics.hold();
              showPaneActions(context, machine, pane, title: title);
            },
      onTap: () {
        Haptics.tick();
        // A keeper's view pane is the agent session as text: the chat shows
        // the same session whole, with the dock, photos and files.
        final session = machine.keeperPanes[pane.id];
        unawaited(openAgent(context, session != null ? SessionAgent(session) : PaneAgent(machine.profile.id, pane.id)));
      },
    );
  }
}
