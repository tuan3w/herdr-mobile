import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import '../../core/status_panel.dart';
import '../agents/agent_navigation.dart';
import '../create/management_sheets.dart';
import '../create/new_agent_session_screen.dart';
import '../files/files_navigation.dart';

/// Everything running on one machine: workspaces (herdr's order) → tabs
/// (newest first) → panes.
class MachineScreen extends StatelessWidget {
  const MachineScreen({super.key, required this.machine});

  final MachineConnection machine;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: machine,
        child: const _MachineView(),
      );
}

class _MachineView extends StatefulWidget {
  const _MachineView();

  @override
  State<_MachineView> createState() => _MachineViewState();
}

class _MachineViewState extends State<_MachineView> {
  /// Workspaces the person opened or closed by hand. Kept here, not in the
  /// list items, because a virtualized list drops off-screen item state.
  final _toggled = <String, bool>{};

  /// Workspaces whose pane list was lifted past the cap.
  final _showAll = <String>{};

  bool _isOpen(MachineConnection machine, Workspace w) =>
      _toggled[w.id] ??
      (machine.snapshot.workspaces.length <= 4 ||
          w.status == AgentStatus.blocked ||
          w.status == AgentStatus.done);

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final machine = context.watch<MachineConnection>();
    final snap = machine.snapshot;
    final state = machine.state;
    final approval = machine.approvalUrl;

    final loud = state == LinkState.attention || state == LinkState.approval;
    final subtitle = Row(
      children: [
        LinkDot(state: state),
        const SizedBox(width: 7),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: state.label,
                style: TextStyle(color: loud ? ds.blockedText : ds.textSecondary),
              ),
              if (snap.version.isNotEmpty)
                TextSpan(text: ' · herdr ${snap.version}', style: TextStyle(color: ds.textMuted)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Type.secondary,
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: ds.bg,
      body: AppRefresh(
        onRefresh: () async {
          if (machine.isLive) {
            await machine.refresh();
          } else {
            machine.retry();
          }
        },
        edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverLargeTitle(
              title: machine.profile.label,
              subtitle: subtitle,
              leading: CircleButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              actions: [
                if (machineSupportsFiles(machine))
                  CircleButton(
                    icon: LucideIcons.folderOpen,
                    tooltip: 'Browse files',
                    onPressed: () => openFileBrowser(context, machine),
                  ),
                CircleButton(
                  icon: LucideIcons.plus,
                  tooltip: 'New agent session',
                  onPressed: machine.isLive ? () => unawaited(openNewAgentSession(context, machine: machine)) : null,
                ),
              ],
            ),
            if (machine.error != null && !machine.isLive)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
                  child: StatusPanel(
                    color: state.color(ds),
                    icon: LucideIcons.cloudOff,
                    message: machine.error,
                    messageMaxLines: 3,
                    trailing: AppButton(
                      label: 'Retry',
                      kind: AppButtonKind.secondary,
                      compact: true,
                      onPressed: machine.retry,
                    ),
                  ),
                ),
              ),
            if (approval != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
                  child: StatusPanel(
                    color: ds.blocked,
                    icon: LucideIcons.shieldCheck,
                    title: 'Approve this sign-in',
                    message: 'Tailscale needs you to approve this sign-in.',
                    footer: Align(alignment: Alignment.centerLeft, child: ApprovalButton(url: approval)),
                  ),
                ),
              ),
            if (snap.workspaces.isEmpty && machine.isLive)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: LucideIcons.layoutDashboard,
                  title: 'No workspaces',
                  message: 'Create a workspace in herdr and it will show up here.',
                ),
              )
            else
              SliverList.builder(
                itemCount: snap.workspaces.length,
                itemBuilder: (_, i) {
                  final w = snap.workspaces[i];
                  final open = _isOpen(machine, w);
                  return _WorkspaceSection(
                    key: ValueKey(w.id),
                    machine: machine,
                    workspace: w,
                    open: open,
                    showAll: _showAll.contains(w.id),
                    onToggle: () => setState(() => _toggled[w.id] = !open),
                    onShowAll: () => setState(() => _showAll.add(w.id)),
                  );
                },
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: Gap.xxl + MediaQuery.paddingOf(context).bottom),
            ),
          ],
        ),
      ),
    );
  }
}

/// Past this many panes a workspace lists the first ones and offers the rest
/// behind "Show all": a workspace with a hundred panes would otherwise build a
/// hundred rows at once (its rows are not in a lazy list).
const _paneCap = 30;

class _WorkspaceSection extends StatelessWidget {
  const _WorkspaceSection({
    super.key,
    required this.machine,
    required this.workspace,
    required this.open,
    required this.showAll,
    required this.onToggle,
    required this.onShowAll,
  });

  final MachineConnection machine;
  final Workspace workspace;
  final bool open;
  final bool showAll;
  final VoidCallback onToggle;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final snap = machine.snapshot;
    // Newest tab first: herdr opens a tab at the end of its workspace, so in
    // its order a session just started from the phone, and the ones still
    // working, sat at the bottom under every finished one. Panes keep their
    // order within a tab (splits of one place).
    final tabs = [...snap.tabsOf(workspace.id)]..sort((a, b) => b.number.compareTo(a.number));
    final multiTab = tabs.length > 1;
    final live = machine.isLive;

    // A tab label only matters when there is more than one.
    // These are widget descriptions only: [Collapse] builds nothing for a
    // workspace that is closed.
    final rows = <Widget>[];
    var total = 0;
    for (final tab in tabs) {
      final label = tab.label.isEmpty ? 'Tab ${tab.number}' : tab.label;
      for (final pane in snap.panesOf(tab.id)) {
        total++;
        if (!showAll && total > _paneCap) continue;
        rows.add(RepaintBoundary(
          key: ValueKey(pane.id),
          child: _PaneRow(
            machine: machine,
            pane: pane,
            tabLabel: multiTab ? label : null,
            dim: !live,
          ),
        ));
      }
    }
    if (total > rows.length) rows.add(_ShowAllRow(total: total, onTap: onShowAll));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          label: workspace.label.isEmpty ? workspace.id : workspace.label,
          count: workspace.paneCount,
          expanded: open,
          onTap: onToggle,
          leading: StatusGlyph(status: workspace.status, size: 14, dim: !live),
          // Nudged right so the dots line up with the chevrons of the rows below;
          // the hit box moves with them.
          trailing: Transform.translate(
            offset: const Offset(10, 0),
            child: CircleButton(
              icon: LucideIcons.ellipsis,
              tooltip: 'Workspace actions',
              filled: false,
              size: 36,
              onPressed: live ? () => showWorkspaceActions(context, machine, workspace) : null,
            ),
          ),
        ),
        Collapse(
          open: open,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      ],
    );
  }
}

/// "Show all 120 panes": the quiet row that ends a capped workspace.
class _ShowAllRow extends StatelessWidget {
  const _ShowAllRow({required this.total, required this.onTap});

  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      builder: (context, pressed) => Container(
        constraints: const BoxConstraints(minHeight: 48),
        alignment: Alignment.centerLeft,
        // Aligned with the pane titles above (gutter + leadingExtent 28 + gap).
        padding: const EdgeInsets.only(left: Gap.gutter + 28 + Gap.md, right: Gap.gutter),
        color: pressed ? ds.fill : Colors.transparent,
        child: Text(
          'Show all $total panes',
          style: Type.label.copyWith(color: ds.accentText, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _PaneRow extends StatelessWidget {
  const _PaneRow({
    required this.machine,
    required this.pane,
    required this.tabLabel,
    required this.dim,
  });

  final MachineConnection machine;
  final Pane pane;
  final String? tabLabel;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final agent = pane.agent;
    final title = pane.title.isNotEmpty ? pane.title : (agent ?? 'Shell');
    final subtitle = [
      if (agent != null && agent != title) agent,
      ?tabLabel,
      if (cwdTail(pane.cwd).isNotEmpty) cwdTail(pane.cwd),
    ].join(' · ');

    return ListRow(
      leading: agent != null
          ? StatusGlyph(status: pane.status, size: 20)
          : const IconTile(icon: LucideIcons.squareTerminal, size: 28),
      leadingExtent: 28,
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
