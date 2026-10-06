import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/batch_actions.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/rows.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import '../settings/app_switch.dart';
import 'agents_grouping.dart' show AgentsOverview;
import 'board_selection.dart';

/// What the person confirmed: the plan as the sheet showed it, and the text.
class BatchRequest {
  const BatchRequest(this.plan, this.text);

  final BatchPlan plan;
  final String text;
}

/// "3 agents", "1 agent".
String agentCount(int n) => '$n agent${n == 1 ? '' : 's'}';

/// One button of the action bar, start to finish: the confirm sheet, the run
/// (the bar shows a spinner while it lasts), the result line, and the end of
/// selection mode.
Future<void> performBatchAction(BuildContext context, BatchAction action, BoardSelection selection) async {
  final toaster = Toaster.of(context);
  final request = await showAppSheet<BatchRequest>(
    context,
    builder: (_) => BatchSheet(action: action, refs: selection.refs),
  );
  if (request == null) return;
  final verb = switch (action) {
    BatchAction.interrupt => 'Interrupting',
    BatchAction.message => 'Messaging',
    BatchAction.close => 'Closing',
  };
  selection.begin('$verb ${agentCount(request.plan.run.length)}');
  final BatchResult result;
  try {
    result = await runBatch(request.plan, text: request.text);
  } finally {
    selection.finish();
  }
  toaster.show(
    result.summary,
    kind: result.failed.isEmpty ? ToastKind.success : ToastKind.failed,
    duration: const Duration(seconds: 6),
  );
}

/// The confirm sheet of one batch action. It lists the targets from live data
/// and stays current while it is open: an agent that starts waiting for an
/// answer moves to the skipped group before the button can be tapped. Public
/// for tests.
class BatchSheet extends StatefulWidget {
  const BatchSheet({super.key, required this.action, required this.refs});

  final BatchAction action;

  /// What the board had selected when the sheet opened.
  final Set<String> refs;

  @override
  State<BatchSheet> createState() => _BatchSheetState();
}

class _BatchSheetState extends State<BatchSheet> {
  final _text = TextEditingController();

  /// "Send anyway" is on for exactly these waiting terminal agents: one that
  /// starts waiting later is skipped, and the switch turns itself off.
  Set<String>? _anyway;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  BatchAction get _action => widget.action;

  void _confirm(BatchPlan plan) =>
      Navigator.of(context).pop(BatchRequest(plan, _action == BatchAction.message ? _text.text : ''));

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // Rebuilds when a status, a title or a machine's state changes.
    context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    final sessions = context.watch<AgentSessions?>();
    final targets = resolveBatchTargets(
      refs: widget.refs,
      fleet: context.read<FleetRepository>(),
      sessions: sessions,
    );
    final message = _action == BatchAction.message;
    final waitingTerminals = {
      for (final t in targets)
        if (message && t.kind == BatchKind.terminal && t.unreachable == null && t.status == AgentStatus.blocked) t.key,
    };
    final anyway = _anyway;
    if (anyway != null && !anyway.containsAll(waitingTerminals)) _anyway = null;
    final sendAnyway = _anyway != null;
    final plan = BatchPlan.of(_action, targets, sendAnyway: sendAnyway);
    final n = plan.run.length;
    final canConfirm = n > 0 && (!message || _text.text.trim().isNotEmpty);

    final (title, about, runHeader, verb) = switch (_action) {
      BatchAction.interrupt => (
          'Interrupt agents',
          'Sends Esc to each terminal agent and stops the turn of each agent session.',
          'Will be interrupted',
          'Interrupt',
        ),
      BatchAction.message => (
          'Message agents',
          null,
          'Will get the message',
          'Message',
        ),
      BatchAction.close => (
          'Close agents',
          'This closes these terminal panes and ends these agent sessions. '
              'Whatever runs in them stops, and it cannot be undone.',
          'Will be closed',
          'Close',
        ),
    };

    final viewport = MediaQuery.sizeOf(context).height;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    // The list scrolls inside a share of the screen, so the buttons under it
    // stay in reach: less of it with the keyboard up or at large text, where
    // the title, the sentence and the buttons already take most of the height.
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final share = keyboard ? 0.18 : (large ? 0.16 : 0.36);
    final waiting = plan.waiting;
    // A message has its own group for the agents that wait for an answer.
    final skipped = message ? plan.others : plan.skipped;

    return Padding(
      // Lifts the sheet over the keyboard.
      padding: EdgeInsets.only(top: Gap.xl, bottom: Gap.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
            child: Semantics(
              header: true,
              child: Text(title, style: Type.title.copyWith(color: ds.text)),
            ),
          ),
          if (about != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0),
              child: Text(about, style: Type.compact.copyWith(color: ds.textSecondary)),
            ),
          if (message)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, 0),
              child: LabeledField(
                label: 'Message',
                controller: _text,
                hint: 'One message for every agent below',
                helper: 'Typed into each agent, then Enter.',
                minLines: 2,
                maxLines: 6,
                autofocus: true,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: viewport * share),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionLabel(label: runHeader, count: n),
                  for (final t in plan.run)
                    _TargetRow(
                      target: t,
                      note: sendAnyway && t.status == AgentStatus.blocked && t.kind == BatchKind.terminal
                          ? 'Will be typed into its question'
                          : null,
                      noteColor: ds.blockedText,
                    ),
                  if (message && (waiting.isNotEmpty || waitingTerminals.isNotEmpty)) ...[
                    SectionLabel(
                      label: waiting.isEmpty ? 'Waiting for an answer' : 'Waiting for an answer (skipped)',
                      count: waiting.length,
                    ),
                    if (waitingTerminals.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
                        child: SwitchRow(
                          title: 'Send anyway',
                          subtitle: 'They show a question. The text would be typed into it.',
                          value: sendAnyway,
                          onChanged: (on) => setState(() => _anyway = on ? waitingTerminals : null),
                        ),
                      ),
                    for (final s in waiting) _TargetRow(target: s.target, note: _sentence(s.reason), noteColor: ds.blockedText),
                  ],
                  if (skipped.isNotEmpty) ...[
                    SectionLabel(label: 'Skipped', count: skipped.length),
                    for (final s in skipped)
                      _TargetRow(
                        target: s.target,
                        note: _sentence(s.reason),
                        noteColor: s.kind == SkipKind.waiting ? ds.blockedText : ds.textMuted,
                      ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, 0),
            child: AppButton(
              label: '$verb ${agentCount(n)}',
              kind: _action == BatchAction.close ? AppButtonKind.danger : AppButtonKind.primary,
              expand: true,
              onPressed: canConfirm ? () => _confirm(plan) : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0),
            child: AppButton(
              label: 'Cancel',
              kind: AppButtonKind.secondary,
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }

  static String _sentence(String reason) => '${reason[0].toUpperCase()}${reason.substring(1)}';
}

/// One target in the sheet: status shape, title, `agent · machine`, the
/// status in words, and (skipped) why. Read as one line of speech.
class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.target, required this.noteColor, this.note});

  final BatchTarget target;
  final String? note;
  final Color noteColor;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final status = target.status;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ExcludeSemantics(child: StatusGlyph(status: status, size: 18)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.row.copyWith(color: ds.text),
                  ),
                  Text(
                    target.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                  if (note != null)
                    Text(
                      note!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondary.copyWith(color: noteColor),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Gap.sm),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                status.label,
                maxLines: 1,
                style: Type.caption.copyWith(color: status.textColor(ds)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
