import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'session_select.dart';

const _listHeight = 216.0;

/// `Plan 3 of 3 done` when every step of [plan] is done; null otherwise. The
/// finished plan folds into the work log's summary line with these words.
String? planDoneNote(List<PlanEntry> plan) {
  if (plan.isEmpty || plan.any((e) => e.status != PlanStatus.completed)) return null;
  return 'Plan ${plan.length} of ${plan.length} done';
}

/// Whether the plan takes room above the conversation: it exists AND it still
/// has steps to do, or it changed in the turn that runs ([baseline] is the
/// plan when that turn began; null when it is not known, which counts as
/// changed). A finished plan from an earlier turn has nothing to say, and one
/// that finished in the turn that just ended is a part of that turn's summary.
bool planTakesRoom(List<PlanEntry> plan, {required bool turnActive, List<PlanEntry>? baseline}) {
  if (plan.isEmpty) return false;
  if (plan.any((e) => e.status == PlanStatus.pending || e.status == PlanStatus.inProgress)) return true;
  return turnActive && !identical(plan, baseline);
}

/// The agent's plan above the transcript: one line with its progress ("3 of
/// 7") and the step in progress; tapped, every step. Takes no room without a
/// plan, nor for a plan that is done and was not changed in the turn that runs.
class PlanHeader extends StatefulWidget {
  const PlanHeader({super.key, required this.session});

  final AgentSessionView session;

  @override
  State<PlanHeader> createState() => _PlanHeaderState();
}

class _PlanHeaderState extends State<PlanHeader> {
  bool _active = false;

  /// The plan at the start of the turn that runs; null when the screen opened
  /// in the middle of it.
  List<PlanEntry>? _baseline;
  late List<PlanEntry> _shown = _wanted();

  List<PlanEntry> _wanted() {
    final s = widget.session.state;
    return planTakesRoom(s.plan, turnActive: s.turnActive, baseline: _baseline) ? s.plan : const [];
  }

  @override
  void initState() {
    super.initState();
    _active = widget.session.state.turnActive;
    widget.session.addListener(_onSession);
  }

  @override
  void didUpdateWidget(PlanHeader old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _active = widget.session.state.turnActive;
      _baseline = null;
      _shown = _wanted();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    final s = widget.session.state;
    if (s.turnActive && !_active) _baseline = s.plan;
    _active = s.turnActive;
    final next = _wanted();
    if (identical(next, _shown)) return;
    setState(() => _shown = next);
  }

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('select');
    return _shown.isEmpty ? const SizedBox.shrink() : _Plan(plan: _shown);
  }
}

class _Plan extends StatefulWidget {
  const _Plan({required this.plan});

  final List<PlanEntry> plan;

  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final plan = widget.plan;
    final done = plan.where((e) => e.status == PlanStatus.completed).length;
    final current = plan.where((e) => e.status == PlanStatus.inProgress).firstOrNull;
    // In whatever room the screen gives it (see the screen's layout): a plan
    // that does not fit scrolls there instead of overflowing.
    return SingleChildScrollView(child: Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ds.fill,
          borderRadius: BorderRadius.circular(Radii.panel),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: _open,
              child: PressBuilder(
                onTap: () => setState(() => _open = !_open),
                builder: (context, pressed) => AnimatedContainer(
                  duration: Motion.pressing(pressed),
                  curve: Motion.easeOut,
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  decoration: BoxDecoration(
                    color: pressed ? ds.fillPressed : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.panel),
                  ),
                  child: Row(
                    children: [
                      Icon(LucideIcons.listChecks, size: 16, color: ds.textSecondary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            text: 'Plan',
                            style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600),
                            children: [
                              TextSpan(
                                text: '  $done of ${plan.length}',
                                style: Type.label.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
                              ),
                              if (current != null && !_open)
                                TextSpan(
                                  text: '  ${current.content}',
                                  style: Type.secondary.copyWith(color: ds.textMuted),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: Gap.xs),
                      Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 14, color: ds.textTertiary),
                    ],
                  ),
                ),
              ),
            ),
            if (_open)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _listHeight),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
                  itemCount: plan.length,
                  itemBuilder: (context, i) => _Step(entry: plan[i]),
                ),
              ),
          ],
        ),
      ),
    ));
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.entry});

  final PlanEntry entry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final glyph = switch (entry.status) {
      PlanStatus.pending => const StatusGlyph(status: AgentStatus.idle, size: 14),
      PlanStatus.inProgress => const StatusGlyph(status: AgentStatus.working, size: 14),
      PlanStatus.completed => const StatusGlyph(status: AgentStatus.done, size: 14),
      PlanStatus.cancelled => Icon(LucideIcons.ban, size: 14, color: ds.textTertiary),
    };
    final word = switch (entry.status) {
      PlanStatus.pending => 'pending',
      PlanStatus.inProgress => 'in progress',
      PlanStatus.completed => 'done',
      PlanStatus.cancelled => 'cancelled',
    };
    return Semantics(
      label: '${entry.content}, $word',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: glyph),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.content,
                style: Type.secondary.copyWith(
                  color: entry.status == PlanStatus.inProgress ? ds.text : ds.textSecondary,
                  fontWeight: entry.status == PlanStatus.inProgress ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
