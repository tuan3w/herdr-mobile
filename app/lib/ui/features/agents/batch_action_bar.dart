import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/batch_actions.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import 'agents_grouping.dart' show AgentsOverview;
import 'board_selection.dart';

/// The top of the board while it is picking: `N selected`, All, Cancel. It
/// covers the title bar (the large title and the filter chips stay below it,
/// so All still means "this filter"). Absent when the board is not picking.
class SelectionHeader extends StatelessWidget {
  const SelectionHeader({super.key, required this.onAll});

  /// Picks every agent the board shows in its current filter.
  final VoidCallback onAll;

  static const _bar = 56.0;

  @override
  Widget build(BuildContext context) {
    final state = context.select<BoardSelection?, ({bool active, int count, bool busy})>(
      (s) => (active: s?.active ?? false, count: s?.count ?? 0, busy: s?.busy != null),
    );
    if (!state.active) return const SizedBox.shrink();
    final ds = context.ds;
    final selection = context.read<BoardSelection>();
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Container(
        color: ds.bg,
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _bar,
              child: Padding(
                padding: const EdgeInsets.only(left: Gap.gutter, right: Gap.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          '${state.count} selected',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Type.barTitle.copyWith(color: ds.text, fontFeatures: Type.tabular),
                        ),
                      ),
                    ),
                    AppButton(
                      label: 'All',
                      kind: AppButtonKind.ghost,
                      compact: true,
                      onPressed: state.busy ? null : onAll,
                    ),
                    AppButton(
                      label: 'Cancel',
                      kind: AppButtonKind.ghost,
                      compact: true,
                      onPressed: state.busy ? null : selection.cancel,
                    ),
                  ],
                ),
              ),
            ),
            const Hairline(),
          ],
        ),
      ),
    );
  }
}

/// The three actions on the picked agents, docked above the system inset
/// while the board is picking. An action is enabled when it would touch at
/// least one of them (a message also when the only candidates are agents
/// waiting for an answer, which the confirm sheet offers to type into on the
/// person's say so). While a batch runs the bar says so with a spinner.
class BatchActionBar extends StatelessWidget {
  const BatchActionBar({super.key, required this.onAction});

  final ValueChanged<BatchAction> onAction;

  static const _height = 56.0;

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<BoardSelection?>();
    if (selection == null || !selection.active) return const SizedBox.shrink();
    // Toasts stand above it, as above the tab bar it replaces.
    return ToastShelf(child: _bar(context, selection));
  }

  Widget _bar(BuildContext context, BoardSelection selection) {
    // Rebuilds with the fleet and the sessions, so the enablement follows the
    // statuses of what is picked.
    context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    final sessions = context.watch<AgentSessions?>();
    final targets = resolveBatchTargets(
      refs: selection.refs,
      fleet: context.read<FleetRepository>(),
      sessions: sessions,
    );
    bool can(BatchAction a) {
      final plan = BatchPlan.of(a, targets);
      return plan.run.isNotEmpty ||
          (a == BatchAction.message && plan.waiting.any((s) => s.canSendAnyway));
    }

    final ds = context.ds;
    final busy = selection.busy;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Container(
        padding: EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm + MediaQuery.paddingOf(context).bottom),
        decoration: BoxDecoration(
          color: ds.surface,
          border: Border(top: BorderSide(color: ds.hairline)),
        ),
        child: SizedBox(
          height: _height,
          child: busy != null
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const BusySpinner(),
                    const SizedBox(width: Gap.md),
                    Flexible(
                      child: Text(
                        '$busy…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.label.copyWith(color: ds.textSecondary, fontSize: 14),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    _BarAction(
                      label: 'Interrupt',
                      icon: LucideIcons.circleStop,
                      onTap: can(BatchAction.interrupt) ? () => onAction(BatchAction.interrupt) : null,
                    ),
                    _BarAction(
                      label: 'Message',
                      icon: LucideIcons.messageSquare,
                      onTap: can(BatchAction.message) ? () => onAction(BatchAction.message) : null,
                    ),
                    _BarAction(
                      label: 'Close',
                      icon: LucideIcons.x,
                      danger: true,
                      onTap: can(BatchAction.close) ? () => onAction(BatchAction.close) : null,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({required this.label, required this.icon, required this.onTap, this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final enabled = onTap != null;
    final fg = !enabled ? ds.textMuted : (danger ? ds.dangerText : ds.text);
    return Expanded(
      child: PressBuilder(
        onTap: onTap,
        haptic: true,
        button: true,
        minTapSize: kMinTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          height: 56,
          decoration: BoxDecoration(
            color: pressed ? ds.fill : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: enabled ? fg : ds.textTertiary),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.caption.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
