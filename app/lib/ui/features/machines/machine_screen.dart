import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import '../pane/pane_screen.dart';
import 'status_panel.dart';

/// Everything running on one machine: workspaces → tabs → panes.
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
    final top = MediaQuery.paddingOf(context).top;

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
                style: TextStyle(color: loud ? state.color(ds) : ds.textSecondary),
              ),
              if (snap.version.isNotEmpty)
                TextSpan(text: ' · herdr ${snap.version}', style: TextStyle(color: ds.textTertiary)),
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
      body: RefreshIndicator(
        onRefresh: () async {
          if (machine.isLive) {
            await machine.refresh();
          } else {
            machine.retry();
          }
        },
        color: ds.textSecondary,
        backgroundColor: ds.surface,
        elevation: 0,
        edgeOffset: top + 56,
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
                    onToggle: () => setState(() => _toggled[w.id] = !open),
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

class _WorkspaceSection extends StatelessWidget {
  const _WorkspaceSection({
    super.key,
    required this.machine,
    required this.workspace,
    required this.open,
    required this.onToggle,
  });

  final MachineConnection machine;
  final Workspace workspace;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final snap = machine.snapshot;
    final tabs = snap.tabsOf(workspace.id);
    final multiTab = tabs.length > 1;
    final live = machine.isLive;

    // Panes in tab order; a tab label only matters when there is more than one.
    final rows = <Widget>[];
    for (final tab in tabs) {
      final label = tab.label.isEmpty ? 'Tab ${tab.number}' : tab.label;
      for (final pane in snap.panesOf(tab.id)) {
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          label: workspace.label.isEmpty ? workspace.id : workspace.label,
          count: workspace.paneCount,
          expanded: open,
          onTap: onToggle,
          leading: StatusGlyph(status: workspace.status, size: 14, dim: !live),
        ),
        Collapse(
          open: open,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      ],
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
    final ds = context.ds;
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
      subtitle: subtitle,
      dim: dim,
      trailing: Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PaneScreen(machine: machine, paneId: pane.id),
        ));
      },
    );
  }
}
