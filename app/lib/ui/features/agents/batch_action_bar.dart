import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/batch_actions.dart';
import '../../../data/repositories/fleet_repository.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

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
    final selection = context.read<BoardSelection?>();
    if (selection == null) return const SizedBox.shrink();
    final ds = context.ds;
    // It comes and goes with a fade, as the batch bar does below.
    return BottomStackTransition(
      visible: state.active,
      slide: false,
      builder: (context) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: kBarTextScale,
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
                          child: RollText(
                            text: '${state.count} selected',
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
      ),
    );
  }
}

/// The actions on the picked agents, in a floating pill at the bottom while
/// the board is picking: the one bar home ever has there, within the thumb's
/// reach. `Reviewed` marks the picked finished agents reviewed at once, with
/// one toast and its Undo and no sheet (cheap, and undone in one tap); Stop,
/// Message and Close go through a confirm sheet. An action is enabled when it
/// would touch at least one of them (a message also when the only candidates
/// are agents waiting for an answer, which the confirm sheet offers to type
/// into on the person's say so). While a batch runs the bar says so with a
/// spinner.
class BatchActionBar extends StatelessWidget {
  const BatchActionBar({super.key, required this.onAction, required this.onReview});

  final ValueChanged<BatchAction> onAction;

  /// Marks the picked agents that are to review ([toReviewRefs]) reviewed.
  final ValueChanged<Set<String>> onReview;

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<BoardSelection?>();
    if (selection == null) return const SizedBox.shrink();
    final clearance = FloatingBar.clearance(context);
    // Toasts stand above it. The bar brings its own scrim, so rows fade out
    // above it. It comes and goes with a fade, no slide.
    return BottomStackTransition(
      visible: selection.active,
      slide: false,
      builder: (context) => ToastShelf(
        lift: clearance,
        child: SizedBox(
          height: clearance,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const FloatingBarScrim(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: FloatingBarSlot(child: FloatingBarPill(child: _content(context, selection))),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, BoardSelection selection) {
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
      return plan.run.isNotEmpty || (a == BatchAction.message && plan.waiting.any((s) => s.canSendAnyway));
    }

    final attention = context.watch<AttentionSet?>();
    final reviewable = attention == null ? const <String>{} : toReviewRefs(attention).intersection(selection.refs);

    final busy = selection.busy;
    if (busy != null) {
      return LoadingRow('$busy…', padding: EdgeInsets.zero, center: true, maxLines: 1);
    }
    return Row(
      children: [
        _BarAction(
          label: 'Reviewed',
          icon: HerdrIcons.reviewed,
          onTap: reviewable.isNotEmpty ? () => onReview(reviewable) : null,
        ),
        _BarAction(
          label: 'Stop',
          icon: HerdrIcons.stop,
          onTap: can(BatchAction.stop) ? () => onAction(BatchAction.stop) : null,
        ),
        _BarAction(
          label: 'Message',
          icon: HerdrIcons.message,
          onTap: can(BatchAction.message) ? () => onAction(BatchAction.message) : null,
        ),
        _BarAction(
          label: 'Close',
          icon: HerdrIcons.close,
          danger: true,
          onTap: can(BatchAction.close) ? () => onAction(BatchAction.close) : null,
        ),
      ],
    );
  }
}

/// One action as a cell: an icon over a name, its height and
/// its capsule for the press (`fillPressed`: `fill` on the pill's surface is
/// about 1.1:1 and vanishes in dark).
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
          height: FloatingBar.cell,
          decoration: BoxDecoration(
            color: pressed ? ds.fillPressed : Colors.transparent,
            borderRadius: BorderRadius.circular(FloatingBar.cell / 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: IconSize.nav, color: enabled ? fg : ds.textTertiary),
              const SizedBox(height: Gap.hair),
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
