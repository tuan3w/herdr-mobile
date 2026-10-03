import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import 'machine_form_screen.dart';
import 'machine_screen.dart';
import 'status_panel.dart';

void openMachineForm(BuildContext context, {MachineProfile? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MachineFormScreen(existing: existing)),
    );

String _plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

class MachinesScreen extends StatelessWidget {
  const MachinesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final fleet = context.watch<FleetRepository>();
    final connections = fleet.connections;
    final count = connections.length;

    return Scaffold(
      backgroundColor: ds.bg,
      body: RefreshIndicator(
        onRefresh: fleet.retryAll,
        color: ds.textSecondary,
        backgroundColor: ds.surface,
        elevation: 0,
        edgeOffset: MediaQuery.paddingOf(context).top + 56,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverLargeTitle(
              title: 'Machines',
              subtitle: Text(
                count == 0 ? 'None yet' : _plural(count, 'machine'),
                style: Type.secondary.copyWith(color: ds.textSecondary),
              ),
              actions: [
                CircleButton(
                  icon: LucideIcons.plus,
                  tooltip: 'Add machine',
                  onPressed: () => openMachineForm(context),
                ),
              ],
            ),
            if (count == 0)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: FloatingTabBar.clearance(context)),
                  child: EmptyState(
                    icon: LucideIcons.server,
                    title: 'No machines yet',
                    message: 'Add a machine that runs herdr. You can connect as many as '
                        'you like and see them all together.',
                    action: AppButton(
                      label: 'Add machine',
                      icon: LucideIcons.plus,
                      onPressed: () => openMachineForm(context),
                    ),
                  ),
                ),
              )
            else ...[
              SliverList.builder(
                itemCount: count,
                itemBuilder: (_, i) => _MachineRow(
                  key: ValueKey(connections[i].profile.id),
                  machine: connections[i],
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: FloatingTabBar.clearance(context))),
            ],
          ],
        ),
      ),
    );
  }
}

/// One machine: a flat row with the same metrics as [ListRow]. It is a local
/// row because the status line needs a [LinkDot] and the problem panel sits
/// under the text, neither of which [ListRow] can express.
class _MachineRow extends StatelessWidget {
  const _MachineRow({super.key, required this.machine});

  final MachineConnection machine;

  static const _tile = 32.0;
  static const _gap = 14.0;
  static const _inset = 8.0;

  void _open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => MachineScreen(machine: machine)),
      );

  Future<void> _remove(BuildContext context, MachineRepository repo) async {
    final p = machine.profile;
    final ok = await showConfirmSheet(
      context,
      title: 'Remove ${p.label}?',
      message: 'The saved connection and its credentials are deleted from this '
          'device. Agents on the machine keep running.',
      confirmLabel: 'Remove',
    );
    if (ok) await repo.remove(p.id);
  }

  void _menu(BuildContext context) {
    final repo = context.read<MachineRepository>();
    final p = machine.profile;
    showActionSheet(
      context,
      title: p.label,
      actions: [
        SheetAction(
          label: 'Edit',
          icon: LucideIcons.pencil,
          onTap: () => openMachineForm(context, existing: p),
        ),
        SheetAction(
          label: p.enabled ? 'Disable' : 'Enable',
          icon: p.enabled ? LucideIcons.powerOff : LucideIcons.power,
          onTap: () => repo.save(p.copyWith(enabled: !p.enabled)),
        ),
        SheetAction(
          label: 'Remove',
          icon: LucideIcons.trash2,
          destructive: true,
          onTap: () => _remove(context, repo),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final p = machine.profile;
    final snap = machine.snapshot;
    final state = machine.state;
    final needYou = snap.agentPanes.where((a) => a.status == AgentStatus.blocked).length;
    final problem = state == LinkState.attention || state == LinkState.reconnecting;
    final approval = machine.approvalUrl;
    final indent = Gap.gutter + _tile + _gap;

    final semantic = [
      p.label,
      state.label,
      if (needYou > 0) '$needYou need you',
    ].join(', ');

    return RepaintBoundary(
      child: Opacity(
        opacity: p.enabled ? 1 : 0.65,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PressBuilder(
              onTap: p.enabled ? () => _open(context) : null,
              onLongPress: () => _menu(context),
              semanticLabel: semantic,
              builder: (context, pressed) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: _inset),
                child: AnimatedContainer(
                  duration: pressed ? Motion.press : Motion.release,
                  curve: Motion.easeOut,
                  decoration: BoxDecoration(
                    color: pressed ? ds.fill : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.fromLTRB(Gap.gutter - _inset, 12, Gap.gutter - _inset - 8, 12),
                  child: Row(
                    children: [
                      const SizedBox(width: _tile, child: Center(child: IconTile(icon: LucideIcons.server))),
                      const SizedBox(width: _gap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              p.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Type.row.copyWith(color: ds.text),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${p.username}@${p.host}${p.port == 22 ? '' : ':${p.port}'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Type.secondary.copyWith(color: ds.textSecondary),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: _StatusLine(machine: machine),
                            ),
                          ],
                        ),
                      ),
                      if (needYou > 0) ...[const SizedBox(width: Gap.sm), _NeedsChip(count: needYou)],
                      const SizedBox(width: Gap.xs),
                      _MoreButton(onPressed: () => _menu(context)),
                    ],
                  ),
                ),
              ),
            ),
            if (problem && machine.error != null)
              Padding(
                padding: EdgeInsets.fromLTRB(indent, 0, Gap.gutter, 12),
                child: StatusPanel(
                  color: state.color(ds),
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
            if (approval != null)
              Padding(
                padding: EdgeInsets.fromLTRB(indent, 0, Gap.gutter, 12),
                child: StatusPanel(
                  color: ds.blocked,
                  message: 'Tailscale needs you to approve this sign-in.',
                  footer: Align(alignment: Alignment.centerLeft, child: ApprovalButton(url: approval)),
                ),
              ),
            Hairline(indent: indent),
          ],
        ),
      ),
    );
  }
}

/// Link dot + one quiet line: the meta line when online, otherwise the state
/// in words.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.machine});

  final MachineConnection machine;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final state = machine.state;
    final snap = machine.snapshot;
    final workspaces = snap.workspaces.length;
    final counts = workspaces == 0
        ? 'No workspaces'
        : '${_plural(workspaces, 'workspace')} · ${_plural(snap.agentPanes.length, 'agent')}';

    final style = Type.secondary.copyWith(color: ds.textTertiary);
    // Amber text on paper is too faint to read, so only the states that need
    // the person are tinted; the dot carries the rest.
    final loud = state == LinkState.attention || state == LinkState.approval;
    final stateStyle = style.copyWith(
      color: loud ? state.color(ds) : ds.textSecondary,
      fontWeight: loud ? FontWeight.w500 : null,
    );

    return Row(
      children: [
        LinkDot(state: state, size: 7),
        const SizedBox(width: 7),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              if (state == LinkState.online) {
                // The version is the first thing to go on a narrow row: a
                // half-cut "herdr 0.…" says nothing.
                final full = snap.version.isEmpty ? counts : '$counts · herdr ${snap.version}';
                final fits = _fits(context, full, style, box.maxWidth);
                return Text(fits ? full : counts, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
              }
              return Text.rich(
                TextSpan(children: [
                  TextSpan(text: state.label, style: stateStyle),
                  if (!machine.profile.enabled) TextSpan(text: ' · not connecting', style: style),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
        ),
      ],
    );
  }
}

bool _fits(BuildContext context, String text, TextStyle style, double width) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final fits = painter.width <= width;
  painter.dispose();
  return fits;
}

/// "Agents need you" count: the blocked glyph and the number, never clipped.
class _NeedsChip extends StatelessWidget {
  const _NeedsChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      height: 24,
      padding: const EdgeInsets.fromLTRB(7, 0, 9, 0),
      decoration: BoxDecoration(
        color: ds.blocked.withValues(alpha: ds.isDark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const StatusGlyph(status: AgentStatus.blocked, size: 13),
          const SizedBox(width: 5),
          Text(
            '$count',
            style: Type.caption.copyWith(
              color: ds.blocked,
              fontWeight: FontWeight.w600,
              fontFeatures: Type.tabular,
            ),
          ),
        ],
      ),
    );
  }
}

/// The ellipsis button: drawn 36 but with a 44 touch target.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: CircleButton(
              icon: LucideIcons.ellipsis,
              tooltip: 'More',
              filled: false,
              size: 36,
              onPressed: onPressed,
            ),
          ),
        ),
      );
}
