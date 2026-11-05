import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_client.dart' show AcpClient;
import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/subagents/subagent_run.dart' show SubagentOrigin;
import '../../../data/decision/permission_evidence.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/command_risk.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/tap_guard.dart';
import 'agent_md_scope.dart';
import 'permission_evidence_view.dart';
import 'permission_subject.dart';
import 'question_form.dart';
import 'session_select.dart';
import 'tool_rows.dart';
import '../../render/visible_text.dart';

/// The agent's request that waits for the person, docked above the composer:
/// the first permission (they come before questions), else the first
/// question, with "N more waiting" when others queue behind it. Takes no room
/// when nothing waits.
///
/// It is built once by the screen and selects `state.pending` itself, so a
/// streaming answer or the keyboard moving rebuilds nothing here. A panel is
/// keyed by its request: a new request gets a new panel, which ignores taps
/// for [Dwell.tapGuard] (see [PermissionPanel]). What the person has put into a
/// question is kept outside its panel ([QuestionDraft], per question), so a
/// permission that takes the dock in the middle of it costs nothing.
class PromptDock extends StatelessWidget {
  const PromptDock({super.key, required this.session, this.forRun});

  final AgentSessionView session;

  /// Only the requests of this subagent (its own screen); null shows the
  /// first request of the session, whoever asked.
  final String? forRun;

  /// What the agent said before it asked: the subagent's own transcript for
  /// its request, so its last sentence is not taken from the main agent's.
  List<TranscriptItem> _itemsOf(PendingRequest request) {
    final origin = request.origin;
    if (origin == null) return session.state.items;
    return session.subagentRun(origin.id)?.items ?? const [];
  }

  /// The unsent answers to this session's questions, by [PendingQuestion.draftId]
  /// (the question, not the request: a question the terminal refused comes
  /// back under a new request id and must find its answers). They belong to
  /// the session, not to a panel or to this dock: a permission that arrives
  /// takes the dock and the question's panel goes, and the person may leave
  /// the screen or open the subagent that asked; wherever the question shows
  /// again, its answers are where they were.
  static final _drafts = Expando<Map<Object, QuestionDraft>>('question drafts');

  /// Drops the drafts of questions the live session no longer waits on
  /// (answered, here or elsewhere, or withdrawn). A saved copy or a dropped
  /// link says nothing about what waits, so it drops none.
  Map<Object, QuestionDraft> _draftsFor(List<PendingRequest> all) {
    final drafts = _drafts[session] ??= <Object, QuestionDraft>{};
    if (session.link == AgentLink.live && session.cachedAsOf == null) {
      drafts.removeWhere((key, _) => !all.any((p) => p is PendingQuestion && p.draftId == key));
    }
    return drafts;
  }

  @override
  Widget build(BuildContext context) => AgentMdScope(
    session: session,
    child: SessionSelect<List<PendingRequest>>(
      session: session,
      // A saved copy of the transcript (cachedAsOf) asks nothing of the person:
      // only the keeper's live attach says that a request still waits.
      select: (s) => s.cachedAsOf != null ? const <PendingRequest>[] : s.state.pending,
      same: identical,
      builder: (context, all) {
        final pending = forRun == null
            ? all
            : [
                for (final p in all)
                  if (p.origin?.id == forRun) p,
              ];
        final drafts = _draftsFor(all);
        final permission = pending.whereType<PendingPermission>().firstOrNull;
        if (permission != null) {
          return _fromSubagent(
            permission.origin,
            PermissionPanel(
              key: ValueKey(permission.id),
              request: permission.request,
              // What the agent said before it asked: read once, when the panel
              // is made (it is keyed by the request).
              items: _itemsOf(permission),
              more: pending.length - 1,
              onAnswer: (outcome) => session.answerPermission(permission.id, outcome),
            ),
          );
        }
        final question = pending.whereType<PendingQuestion>().firstOrNull;
        if (question != null) {
          return _fromSubagent(
            question.origin,
            QuestionPanel(
              key: ValueKey(question.id),
              request: question.request,
              items: _itemsOf(question),
              receivedAt: question.receivedAt,
              draft: drafts.putIfAbsent(question.draftId, QuestionDraft.new),
              more: pending.length - 1,
              onAnswer: (response) => session.answerQuestion(question.id, response),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    ),
  );

  /// [panel] under one quiet line, `From subagent: Explore`, when a subagent
  /// asked; as it is otherwise.
  static Widget _fromSubagent(SubagentOrigin? origin, Widget panel) {
    if (origin == null) return panel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OriginLine(origin: origin),
        Flexible(child: panel),
      ],
    );
  }
}

/// `From subagent: Explore`: who asked, above the question. Quiet text in the
/// supporting colour; the hold rules and the evidence below it are unchanged.
class OriginLine extends StatelessWidget {
  const OriginLine({super.key, required this.origin});

  final SubagentOrigin origin;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
      child: Row(
        children: [
          Icon(HerdrIcons.agents, size: IconSize.inline, color: ds.textSecondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              'From subagent: ${visibleText(origin.label)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: ds.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether an answer to a request allows something (an unknown kind is never
/// assumed to be a refusal).
bool _allows(PermissionOption option) => option.kind.isAllow || option.kind == PermissionOptionKind.other;

/// Why [option] needs a hold (a second activation for assistive technology),
/// or null when one tap is enough. A standing grant (by kind or by its words)
/// always does; so does an option that allows something the request's [risk]
/// flags, or whose own words are risky. The gate is a hint: the command is on
/// screen either way.
String? optionGate(PermissionOption option, String? risk) {
  final name = visibleText(option.name);
  if (option.kind == PermissionOptionKind.rejectAlways) return 'refuses from now on';
  if (option.kind.isStanding || grantsStandingPermission(name)) return standingPermission;
  if (_allows(option)) return risk ?? option.gate ?? proseRisk(name);
  return null;
}

/// Why an allow waits for a hold while the command box has not been read to
/// its end.
const unreadReason = 'long command, read it all';

/// The toast that tells why a request left the dock: another client of the
/// keeper answered it first (`Allowed once in Terminal on mac-mini`).
String answeredElsewhereText(AnsweredElsewhere a) {
  final by = visibleText(a.by).trim();
  final where = by.isEmpty
      ? 'elsewhere'
      : by == AcpClient.herdrMobile.title
      ? 'on another phone'
      : 'in $by';
  final verb = a.question
      ? switch (a.answer) {
          'accept' => 'Answered',
          'decline' => 'Declined',
          'cancel' => 'Cancelled',
          _ => null,
        }
      : switch (a.kind) {
          PermissionOptionKind.allowOnce => 'Allowed once',
          PermissionOptionKind.allowAlways => 'Always allowed',
          PermissionOptionKind.rejectOnce => 'Refused',
          PermissionOptionKind.rejectAlways => 'Always refused',
          PermissionOptionKind.other || null => null,
        };
  if (verb != null) return '$verb $where';
  final answer = visibleText(a.answer).trim();
  return answer.isEmpty ? 'Answered $where' : 'Answered $where \u00b7 $answer';
}

/// A permission request: what it will run or touch, why to look closely, and
/// its answers.
///
/// Nothing here answers for the person. An answer is ignored for [Dwell.tapGuard]
/// after the panel appears. A standing, risky or unread allow is held, not
/// tapped (a tap only says so): the chip fills while the finger stays down and
/// sends at the end. Holding an allow on a command longer than its box scrolls
/// the box to its end and does NOT send; the next hold sends. Assistive
/// technology cannot hold: its activation is a two-step flow (the first
/// primes the option and says why, the second sends; an unread command is
/// shown to its end by the first). Once an answer is sent the panel takes no
/// other.
class PermissionPanel extends StatefulWidget {
  const PermissionPanel({
    super.key,
    required this.request,
    required this.more,
    required this.onAnswer,
    this.items = const [],
  });

  final PermissionRequest request;

  /// The transcript the request belongs to: what the agent said just before
  /// it asked is read from it, once.
  final List<TranscriptItem> items;

  /// Other requests waiting behind this one.
  final int more;
  final ValueChanged<PermissionOutcome> onAnswer;

  @override
  State<PermissionPanel> createState() => _PermissionPanelState();
}

class _PermissionPanelState extends State<PermissionPanel> with TapGuardState<PermissionPanel> {
  /// What lets the person judge the request (the plan, the edits, the agent's
  /// last sentence), worked out once for this request, never per frame.
  late final PermissionEvidence _evidence = permissionEvidence(widget.request, items: widget.items);
  late final PermissionInfo _info = describePermission(widget.request, dropPlan: _evidence.hasPlan);

  /// A request that carries its plan shows it as Markdown instead of the
  /// mono copy of the `plan` field; what is left of the input (other fields)
  /// still shows as the command box. The command is never hidden.
  late final bool _showSubject = !_evidence.hasPlan || _info.subject != _info.title;

  /// The files the call names, less the ones the diff already heads.
  late final List<String> _paths = () {
    final diffed = {for (final d in _evidence.diffs) visibleText(d.path)};
    return [
      for (final p in _info.paths)
        if (!diffed.contains(p)) p,
    ];
  }();
  final _scroll = ScrollController();

  String? _confirming;
  String _confirmReason = '';
  Timer? _timer;

  /// What was sent: an option id, or [_cancelled]. Once set, nothing else
  /// can be sent for this request.
  String? _sent;
  static const _cancelled = '\u0000cancel';

  /// The command box is shorter than its text, and whether its end has been
  /// in view. Guessed from the text until the box is laid out (which is
  /// before the panel takes taps): a short command must not flash warnings.
  late bool _overflows = _showSubject && (_info.subject.length > 250 || '\n'.allMatches(_info.subject).length >= 4);
  bool _atEnd = false;
  bool _opened = false;

  bool get _unread => _overflows && !_atEnd && !_opened;

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _measure(ScrollMetrics m) {
    final over = m.maxScrollExtent > 1;
    final end = m.extentAfter <= 2;
    if (over == _overflows && (!end || _atEnd)) return;
    setState(() {
      _overflows = over;
      // Once seen, the end stays seen: scrolling back up to check is not a
      // reason to ask again.
      _atEnd = _atEnd || end;
    });
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0) _measure(n.metrics);
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) _measure(n.metrics);
    return false;
  }

  void _showEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    _measure(_scroll.position);
  }

  void _openFull() {
    setState(() => _opened = true);
    unawaited(
      showAppSheet<void>(
        context,
        builder: (ctx) {
          final ds = ctx.ds;
          return SheetScaffold(
            title: 'Everything it will run',
            kind: SheetKind.message,
            child: SelectableText(_info.subject, style: Mono.input.copyWith(color: ds.text)),
          );
        },
      ),
    );
  }

  /// The reason [option] waits for a hold, or null.
  String? _gate(PermissionOption option) {
    if (_allows(option) && _unread) return unreadReason;
    return optionGate(option, _info.risk);
  }

  /// Primes [option] for a second activation or a hold, for [Dwell.confirm].
  void _prime(PermissionOption option, String reason) {
    _timer?.cancel();
    setState(() {
      _confirming = option.optionId;
      _confirmReason = reason;
    });
    _timer = Timer(Dwell.confirm, () {
      if (mounted) setState(() => _confirming = null);
    });
  }

  void _send(PermissionOption option) {
    _timer?.cancel();
    setState(() {
      _sent = option.optionId;
      _confirming = null;
    });
    widget.onAnswer(PermissionSelected(option.optionId));
    // Handed to the session: the answer is out.
    Haptics.sent();
  }

  /// Assistive activation (and a tap on an option that has no gate): a gated
  /// option takes two.
  void _choose(PermissionOption option) {
    if (_sent != null || !settled) return;
    final gate = _gate(option);
    if (gate != null && _confirming != option.optionId) {
      Haptics.armed();
      // An unread command is shown to its end by the first activation.
      if (gate == unreadReason) _showEnd();
      _prime(option, gate);
      return;
    }
    _send(option);
  }

  /// A hold reached its end. It is the confirmation, except for a command that
  /// was never read to its end: that hold scrolls to the end and primes the
  /// option, and the next one sends.
  void _held(PermissionOption option) {
    if (_sent != null || !settled) return;
    if (_gate(option) == unreadReason) {
      _showEnd();
      _prime(option, unreadReason);
      return;
    }
    _send(option);
  }

  void _cancel() {
    if (_sent != null || !settled) return;
    _timer?.cancel();
    setState(() {
      _sent = _cancelled;
      _confirming = null;
    });
    widget.onAnswer(const PermissionCancelled());
    Haptics.sent();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final request = widget.request;
    final info = _info;
    final kind = request.toolCall.kind ?? ToolKind.other;
    final locked = _sent != null;
    final live = settled && !locked;
    // When the command is all there is to say, the title would repeat it. A
    // plan shown as Markdown has no command box: its title ("Approve Plan")
    // is then the only thing that names the request.
    final header = _showSubject && info.title == info.subject ? toolKindLabel(kind) : info.title;
    final lines = '\n'.allMatches(info.subject).length + 1;
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            QuestionWash(
              question: header,
              size: QuestionWashSize.full,
              questionIsHeader: true,
              leading: Icon(toolIcon(kind), size: IconSize.row, color: ds.blockedText),
              details: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_evidence.intent case final said?) EvidenceIntent(text: said),
                  const SizedBox(height: Gap.sm),
                  if (_evidence.planMarkdown case final plan?) ...[
                    PlanEvidence(markdown: plan),
                    const SizedBox(height: Gap.sm),
                  ],
                  if (_showSubject) ...[
                    NotificationListener<ScrollMetricsNotification>(
                      onNotification: _onMetrics,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: _SubjectBox(
                          text: info.subject,
                          controller: _scroll,
                          overflows: _overflows,
                          // The thing approved is the largest text here, as on the board card.
                          style: Mono.input.copyWith(color: ds.text),
                        ),
                      ),
                    ),
                    if (_overflows) ReadAllCue(text: _atEnd ? null : 'More below · $lines lines', onOpen: _openFull),
                  ],
                  if (_evidence.diffs.isNotEmpty) ...[
                    const SizedBox(height: Gap.sm),
                    DiffEvidence(evidence: _evidence),
                  ],
                  if (_paths.isNotEmpty) ...[
                    const SizedBox(height: Gap.sm),
                    _Paths(
                      paths: _paths,
                      style: Mono.base.copyWith(color: ds.text),
                    ),
                  ],
                  if (info.risk != null) ...[
                    const SizedBox(height: Gap.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.hair),
                          child: Icon(LucideIcons.triangleAlert, size: IconSize.inline, color: ds.dangerText),
                        ),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text(
                            'Look closely: ${info.risk}',
                            style: Type.secondaryStrong.copyWith(color: ds.dangerText),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Gap.sm),
            for (final option in request.options) ...[
              AnswerChip(
                // A hold belongs to this option of this request (the panel is
                // keyed by request): anything else under the finger drops it.
                key: ValueKey(option.optionId),
                label: visibleText(option.name),
                reason: _confirming == option.optionId ? _confirmReason : _gate(option),
                risk: _gate(option) == null ? AnswerRisk.none : AnswerRisk.gate,
                state: _sent == option.optionId
                    ? AnswerChipState.sending
                    : _confirming == option.optionId
                    ? AnswerChipState.primed
                    : AnswerChipState.rest,
                // A primed option stays held until its window ends, even when
                // its gate went away (the command was read meanwhile): a finger
                // that is already on it must not send by lifting.
                hold: _gate(option) != null || _confirming == option.optionId,
                enabled: live,
                onTap: () => _choose(option),
                onHeld: () => _held(option),
              ),
              const SizedBox(height: Gap.sm),
            ],
            // Side by side while both fit; at a large text size Cancel goes
            // under the count rather than lose its words.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: widget.more > 0 ? WrapAlignment.spaceBetween : WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (widget.more > 0)
                    Text('${widget.more} more waiting', style: Type.labelStrong.copyWith(color: ds.blockedText)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                    child: TextAction(
                      label: 'Cancel request',
                      tone: TextActionTone.quiet,
                      // The answer's own haptic fires once it is handed over.
                      haptic: false,
                      enabled: live,
                      onTap: _cancel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The command or input in mono, in a box of a few lines that scrolls. A
/// scrollbar shows whenever the text is longer than the box.
class _SubjectBox extends StatelessWidget {
  const _SubjectBox({required this.text, required this.controller, required this.overflows, required this.style});

  final String text;
  final ScrollController controller;
  final bool overflows;
  final TextStyle style;

  static const _maxHeight = 132.0;

  /// On a short screen the answers below must stay in reach.
  static const _shortHeight = 88.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: ds.hairline),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height < 700 ? _shortHeight : _maxHeight),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: overflows,
          child: SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            child: SizedBox(
              width: double.infinity,
              child: Text(text, style: style),
            ),
          ),
        ),
      ),
    );
  }
}

/// The files the call names, in mono, so a write is judged by where it lands.
class _Paths extends StatelessWidget {
  const _Paths({required this.paths, required this.style});

  final List<String> paths;
  final TextStyle style;

  static const _shown = 6;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in paths.take(_shown))
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.hair),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Gap.hair),
                  child: Icon(LucideIcons.file, size: IconSize.inline, color: ds.textSecondary),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(p, style: style)),
              ],
            ),
          ),
        if (paths.length > _shown)
          Text(countOf(paths.length - _shown, 'more file'), style: Type.caption.copyWith(color: ds.textSecondary)),
      ],
    );
  }
}
