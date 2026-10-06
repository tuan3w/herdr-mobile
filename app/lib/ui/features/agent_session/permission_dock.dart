import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/subagents/subagent_run.dart' show SubagentOrigin;
import '../../../data/decision/permission_evidence.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/command_risk.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/hold_confirm.dart';
import '../../core/motion.dart';
import '../../core/tap_guard.dart';
import '../../core/theme.dart';
import 'agent_md_scope.dart';
import 'permission_evidence_view.dart';
import 'permission_subject.dart';
import 'question_form.dart';
import 'session_select.dart';
import 'tool_rows.dart';
import 'visible_text.dart';

/// The agent's request that waits for the person, docked above the composer:
/// the first permission (they come before questions), else the first
/// question, with "N more waiting" when others queue behind it. Takes no room
/// when nothing waits.
///
/// It is built once by the screen and selects `state.pending` itself, so a
/// streaming answer or the keyboard moving rebuilds nothing here. A panel is
/// keyed by its request: a new request gets a new panel, which ignores taps
/// for [tapGuard] (see [PermissionPanel]). What the person has put into a
/// question is kept outside its panel ([QuestionDraft], per request), so a
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

  /// The unsent answers to this session's questions, by request id. They
  /// belong to the session, not to a panel or to this dock: a permission that
  /// arrives takes the dock and the question's panel goes, and the person may
  /// leave the screen or open the subagent that asked; wherever the question
  /// shows again, its answers are where they were.
  static final _drafts = Expando<Map<Object, QuestionDraft>>('question drafts');

  /// Drops the drafts of requests the live session no longer waits on
  /// (answered, here or elsewhere, or withdrawn). A saved copy or a dropped
  /// link says nothing about what waits, so it drops none.
  Map<Object, QuestionDraft> _draftsFor(List<PendingRequest> all) {
    final drafts = _drafts[session] ??= <Object, QuestionDraft>{};
    if (session.link == AgentLink.live && session.cachedAsOf == null) {
      drafts.removeWhere((id, _) => !all.any((p) => p.id == id));
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
        final pending = forRun == null ? all : [for (final p in all) if (p.origin?.id == forRun) p];
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
              draft: drafts.putIfAbsent(question.id, QuestionDraft.new),
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
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 6),
      child: Row(
        children: [
          Icon(LucideIcons.bot, size: 14, color: ds.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'From subagent: ${visibleText(origin.label)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w500),
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
  if (_allows(option)) return risk ?? proseRisk(name);
  return null;
}

/// How long a primed option waits for its second activation (or a hold).
const confirmWindow = Duration(seconds: 4);

/// Why an allow waits for a hold while the command box has not been read to
/// its end.
const unreadReason = 'long command, read it all';

/// A permission request: what it will run or touch, why to look closely, and
/// its answers.
///
/// Nothing here answers for the person. An answer is ignored for [tapGuard]
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
  void initState() {
    super.initState();
    // A request is news: it is the thing the person is here for.
    Haptics.armed();
  }

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
          return Padding(
            padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xl, Gap.gutter, Gap.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(header: true, child: Text('Everything it will run', style: Type.title.copyWith(color: ds.text))),
                const SizedBox(height: Gap.md),
                SelectableText(_info.subject, style: dockMono(ds)),
              ],
            ),
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

  /// Primes [option] for a second activation or a hold, for [confirmWindow].
  void _prime(PermissionOption option, String reason) {
    _timer?.cancel();
    setState(() {
      _confirming = option.optionId;
      _confirmReason = reason;
    });
    _timer = Timer(confirmWindow, () {
      if (mounted) setState(() => _confirming = null);
    });
  }

  void _send(PermissionOption option) {
    _timer?.cancel();
    Haptics.sent();
    setState(() {
      _sent = option.optionId;
      _confirming = null;
    });
    widget.onAnswer(PermissionSelected(option.optionId));
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
    Haptics.sent();
    setState(() {
      _sent = _cancelled;
      _confirming = null;
    });
    widget.onAnswer(const PermissionCancelled());
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
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: ds.blockedWash,
                borderRadius: BorderRadius.circular(Radii.chip),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(toolIcon(kind), size: 16, color: ds.blockedText),
                        ),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              header,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Type.prompt.copyWith(fontWeight: FontWeight.w600, color: ds.text),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_evidence.intent case final said?) EvidenceIntent(text: said),
                    const SizedBox(height: 6),
                    if (_evidence.planMarkdown case final plan?) ...[
                      PlanEvidence(markdown: plan),
                      const SizedBox(height: 6),
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
                            style: dockMono(ds),
                          ),
                        ),
                      ),
                      if (_overflows)
                        ReadAllCue(
                          text: _atEnd ? null : 'More below · $lines lines',
                          onOpen: _openFull,
                        ),
                    ],
                    if (_evidence.diffs.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      DiffEvidence(evidence: _evidence),
                    ],
                    if (_paths.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _Paths(paths: _paths, style: dockMono(ds, size: 12)),
                    ],
                    if (info.risk != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(LucideIcons.triangleAlert, size: 14, color: ds.dangerText),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Look closely: ${info.risk}',
                              style: Type.secondary.copyWith(color: ds.dangerText, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            for (final option in request.options) ...[
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  if (!settled && !locked) Haptics.tick();
                },
                child: _OptionChip(
                  // A hold belongs to this option of this request (the panel is
                  // keyed by request): anything else under the finger drops it.
                  key: ValueKey(option.optionId),
                  label: visibleText(option.name),
                  gate: _gate(option),
                  confirming: _confirming == option.optionId,
                  confirmReason: _confirmReason,
                  sending: _sent == option.optionId,
                  enabled: live,
                  onTap: () => _choose(option),
                  onHold: () => _held(option),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              mainAxisAlignment: widget.more > 0 ? MainAxisAlignment.spaceBetween : MainAxisAlignment.end,
              children: [
                if (widget.more > 0)
                  Flexible(
                    child: Text(
                      '${widget.more} more waiting',
                      style: Type.label.copyWith(color: ds.blockedText, fontWeight: FontWeight.w600),
                    ),
                  ),
                Flexible(
                  child: PressBuilder(
                    onTap: live ? _cancel : null,
                    button: true,
                    builder: (context, pressed) => Container(
                      constraints: const BoxConstraints(minHeight: kMinTap),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                      alignment: Alignment.center,
                      child: Text(
                        'Cancel request',
                        textAlign: TextAlign.end,
                        style: Type.label.copyWith(
                          color: live ? (pressed ? ds.text : ds.textSecondary) : ds.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ds.hairline),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height < 700 ? _shortHeight : _maxHeight),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: overflows,
          child: SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(LucideIcons.file, size: 13, color: ds.textSecondary),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(p, style: style)),
              ],
            ),
          ),
        if (paths.length > _shown)
          Text('+${paths.length - _shown} more files', style: Type.caption.copyWith(color: ds.textSecondary)),
      ],
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    super.key,
    required this.label,
    required this.gate,
    required this.confirming,
    required this.confirmReason,
    required this.sending,
    required this.enabled,
    required this.onTap,
    required this.onHold,
  });

  final String label;
  final String? gate;
  final bool confirming;
  final String confirmReason;
  final bool sending;
  final bool enabled;

  /// A tap on an option with no gate; for a gated one, the assistive
  /// activation (the two-step flow).
  final VoidCallback onTap;

  /// A hold of a gated option reached its end.
  final VoidCallback onHold;

  /// A primed option stays held until its window ends, even when its gate went
  /// away (the command was read meanwhile): a finger that is already on it
  /// must not send by lifting.
  bool get _gated => !sending && (gate != null || confirming);

  String? get _semantic => confirming
      ? 'Confirm: $label, $confirmReason'
      : (gate == null ? null : '$label, needs holding or a second activation: $gate');

  @override
  Widget build(BuildContext context) {
    if (!_gated) {
      return PressBuilder(
        onTap: enabled ? onTap : null,
        scale: 0.985,
        button: true,
        semanticLabel: _semantic,
        builder: (context, pressed) => _body(context, pressed: pressed),
      );
    }
    return HoldToConfirm(
      enabled: enabled,
      semanticLabel: _semantic,
      onActivate: onTap,
      onConfirmed: onHold,
      builder: (context, hold) => _body(context, pressed: hold.holding, hold: hold),
    );
  }

  Widget _body(BuildContext context, {required bool pressed, HoldState? hold}) {
    final ds = context.ds;
    final (bg, pressedBg, fg, border) = confirming
        ? (ds.danger.withValues(alpha: 0.14), ds.danger.withValues(alpha: 0.24), ds.dangerText, ds.danger.withValues(alpha: 0.55))
        : (ds.fill, ds.fillPressed, ds.text, null as Color?);
    final reason = gate ?? (confirming ? confirmReason : null);
    final shown = (hold?.showsHold ?? false)
        ? (reason == null ? 'Hold to send' : 'Hold to send · $reason')
        : confirming
            ? 'Hold or tap again · $confirmReason'
            : label;
    final row = Row(
      children: [
        if (sending) ...[
          const BusySpinner(size: 14),
          const SizedBox(width: 10),
        ] else if (confirming) ...[
          Icon(LucideIcons.triangleAlert, size: 16, color: fg),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            shown,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Type.answer.copyWith(
              // Dimmed while the panel ignores taps (just appeared, or an
              // answer is on its way): a static state, no animation.
              color: enabled || sending ? fg : ds.textMuted,
            ),
          ),
        ),
        if (gate != null && !confirming && !sending) Icon(LucideIcons.triangleAlert, size: 15, color: ds.textSecondary),
      ],
    );
    // The padding sits on the content, not the chip: the fill, a layer between
    // the chip's colour and its words, covers the whole chip.
    final content = Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), child: row);
    return AnimatedContainer(
      duration: Motion.pressing(pressed),
      curve: Motion.easeOut,
      constraints: const BoxConstraints(minHeight: kMinTap),
      decoration: BoxDecoration(
        color: pressed && enabled ? pressedBg : bg,
        borderRadius: BorderRadius.circular(Radii.chip),
        border: border == null ? null : Border.all(color: border),
      ),
      child: hold == null ? content : Stack(fit: StackFit.passthrough, children: [hold.fill, content]),
    );
  }
}
