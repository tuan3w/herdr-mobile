import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../../data/words/agent_names.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/tap_guard.dart';
import '../composer/composer_frame.dart';
import 'agent_navigation.dart';
import 'agent_card.dart';
import 'answer_surface.dart';
import 'agent_session_rows.dart';
import 'agents_grouping.dart';
import 'quick_reply_controller.dart';
import 'reply_chips.dart';

/// Opens the reply sheet for one agent: a live look at its terminal, the
/// prompt's one-tap answers, a one-line composer and the keys a prompt needs,
/// so it can be answered without leaving the board.
Future<void> showReplySheet(BuildContext context, {required String key}) =>
    showAppSheet<void>(context, builder: (_) => ReplySheet(startKey: key, triage: false));

/// Walks what needs the person ([AttentionSet.needsYou]: terminal agents and
/// agent sessions, longest waiting first, the order the board's Needs you
/// section shows), one after another. Answering moves on to the next;
/// prev/next jump around ("2 of 3"). A session is answered in the session:
/// the sheet shows what it asks and opens it, and walks on when it is back.
/// `All clear` only when nothing is left; closes itself then.
Future<void> showTriageSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const ReplySheet(startKey: null, triage: true));

/// The sheet's body. Public for tests.
class ReplySheet extends StatefulWidget {
  const ReplySheet({super.key, required this.startKey, required this.triage});

  /// Agent to start on (its `AgentRowData.key`); null = the first that waits.
  final String? startKey;
  final bool triage;

  @override
  State<ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends State<ReplySheet> {
  String? _key;

  // The keys that waited, in the order they were last seen, so that after one
  // is answered "next" means the one that followed it, not the first again.
  List<String> _order = const [];

  /// What the walk showed last, kept while a session opened from it is on top.
  Widget? _lastWalk;

  /// The agent whose answer just went out. It stays in view, with its "Sent",
  /// until the sheet moves on: an agent that stops waiting must not be
  /// replaced by the next one, under the same thumb, in the same frame.
  String? _held;
  bool _answeredAny = false;
  bool _closing = false;
  Timer? _closeTimer;

  /// How long "All clear" shows before the sheet leaves.
  static const _allClearHold = Dwell.allClear;

  @override
  void initState() {
    super.initState();
    _key = widget.startKey;
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  void _close({Duration after = Duration.zero}) {
    if (_closing) return;
    _closing = true;
    void pop() {
      if (mounted) Navigator.of(context).maybePop();
    }

    if (after == Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) => pop());
    } else {
      _closeTimer = Timer(after, pop);
    }
  }

  void _go(int delta, List<String> waiting) {
    if (waiting.isEmpty) return;
    final at = waiting.indexOf(_key ?? '');
    final next = waiting[((at < 0 ? 0 : at) + delta) % waiting.length];
    setState(() {
      _held = null;
      _key = next;
    });
  }

  /// The answer for the agent in view went out: keep showing it.
  void _sent() {
    _answeredAny = true;
    setState(() => _held = _key);
  }

  /// A session in view was opened: whatever is left when the person comes
  /// back is the walk's to show, and none left is `All clear`.
  void _opened() => _answeredAny = true;

  /// The agent after the current one among those still waiting. Nobody else
  /// waiting ends the walk: the build shows "All clear".
  void _advance(List<String> waiting) {
    final others = [
      for (final k in waiting)
        if (k != _key) k,
    ];
    String? next;
    if (others.isNotEmpty) {
      final from = _order.indexOf(_key ?? '');
      for (var i = 1; i <= _order.length && next == null; i++) {
        final k = _order[(from + i) % _order.length];
        if (others.contains(k)) next = k;
      }
      next ??= others.first;
    }
    setState(() {
      _held = null;
      if (next != null) _key = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final overview = context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    AgentRowData? row(String? key) {
      for (final a in overview.agents) {
        if (a.key == key) return a;
      }
      return null;
    }

    if (!widget.triage) {
      final agent = row(_key);
      if (agent == null) {
        _close();
        return const SizedBox(height: _frameHeight);
      }
      return SheetScaffold(
        kind: SheetKind.form,
        child: AgentReply(key: ValueKey(agent.key), agent: agent),
      );
    }

    // A session opened from the walk is on top: leave the walk as it is. It
    // moves on (or says `All clear` and closes) when the person is back, and
    // never pops the session screen they are answering in.
    if (ModalRoute.of(context)?.isCurrent == false) {
      if (_lastWalk case final last?) return last;
    }
    final needsYou = context.watch<AttentionSet>().needsYou;
    final waiting = [for (final i in needsYou) i.key];
    // The agent in view was answered (or went away): move to the next one
    // that still waits; nobody left means the work is done. An answer that
    // just went out holds its place first, so "Sent" can be read.
    final shown = _key;
    final waits = shown != null && waiting.contains(shown);
    final holding = shown != null && !waits && _held == shown && row(shown) != null;
    if (!waits && !holding) {
      final fallback = _fallback(waiting);
      if (fallback == null) {
        if (!_answeredAny) {
          _close();
          return const SizedBox(height: _frameHeight);
        }
        _close(after: _allClearHold);
        return const _AllClear();
      }
      _key = fallback;
    }
    if (!holding) _order = waiting;

    final key = _key!;
    final index = holding ? _order.indexOf(key) : waiting.indexOf(key);
    final total = holding ? _order.length : waiting.length;
    final item = needsYou.where((i) => i.key == key).firstOrNull;
    final agent = row(key);
    final Widget child = switch (item) {
      SessionAttention(:final session) => _SessionAsk(key: ValueKey(key), session: session, onOpen: _opened),
      _ when agent != null => AgentReply(
        key: ValueKey(agent.key),
        agent: agent,
        onSent: _sent,
        onAnswered: () => _advance(waiting),
      ),
      // A pane the set lists and the board has not built yet: a frame.
      _ => const SizedBox(height: _frameHeight),
    };
    return _lastWalk = SheetScaffold(
      kind: SheetKind.form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (total > 0)
            _TriageBar(
              index: math.max(index, 0),
              total: total,
              onPrev: total > 1 && !holding ? () => _go(-1, waiting) : null,
              onNext: total > 1 && !holding ? () => _go(1, waiting) : null,
            ),
          child,
        ],
      ),
    );
  }

  String? _fallback(List<String> waiting) {
    if (waiting.isEmpty) return null;
    final from = _order.indexOf(_key ?? '');
    for (var i = 1; i <= _order.length; i++) {
      final k = _order[(from + i) % _order.length];
      if (waiting.contains(k)) return k;
    }
    return waiting.first;
  }
}

/// An agent session in the walk: what it waits for, in one place, and the way
/// to answer it (in the session; the board's answers are for terminal agents
/// for now).
class _SessionAsk extends StatelessWidget {
  const _SessionAsk({super.key, required this.session, required this.onOpen});

  final AgentSessionView session;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final meta = sessionMeta(session);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Gap.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: Gap.hair),
              child: StatusGlyph(status: AgentStatus.blocked, size: IconSize.lead, dim: false),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  session.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Type.row.copyWith(color: ds.text),
                ),
              ),
            ),
          ],
        ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: IconSize.lead + Gap.md, top: Gap.hair),
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ),
        if (blockedSummary(session) case final summary?) ...[
          const SizedBox(height: Gap.md),
          QuestionWash(question: summary, size: QuestionWashSize.full),
        ],
        const SizedBox(height: Gap.md),
        AppButton(
          label: 'Answer in the session',
          icon: HerdrIcons.message,
          onPressed: () {
            onOpen();
            unawaited(openAgent(context, SessionAgent(session.key)));
          },
        ),
      ],
    );
  }
}

/// Shown for a moment when the last waiting agent was answered: the walk is
/// over, and the sheet says so instead of vanishing under the thumb.
class _AllClear extends StatelessWidget {
  const _AllClear();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SizedBox(
      height: _frameHeight,
      child: Semantics(
        liveRegion: true,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DrawCheck(color: ds.done, size: IconSize.lead),
            const SizedBox(width: Gap.md),
            Text('All clear', style: Type.row.copyWith(color: ds.text)),
          ],
        ),
      ),
    );
  }
}

class _TriageBar extends StatelessWidget {
  const _TriageBar({required this.index, required this.total, this.onPrev, this.onNext});

  final int index;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Row(
      children: [
        CircleButton(icon: LucideIcons.chevronLeft, tooltip: 'Previous agent', onPressed: onPrev, filled: false),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(
              '${index + 1} of ${needYou(total)}',
              textAlign: TextAlign.center,
              style: Type.labelStrong.copyWith(color: ds.blockedText, fontFeatures: Type.tabular),
            ),
          ),
        ),
        CircleButton(icon: LucideIcons.chevronRight, tooltip: 'Next agent', onPressed: onNext, filled: false),
      ],
    );
  }
}

/// One agent inside the sheet. Owns its preview watch and its send state, so
/// moving to another agent (a new key) starts clean and releases the old pane.
class AgentReply extends StatefulWidget {
  const AgentReply({super.key, required this.agent, this.onSent, this.onAnswered});

  final AgentRowData agent;

  /// Called the moment an answer went out (triage keeps this agent in view).
  final VoidCallback? onSent;

  /// Called a moment after an answer went out (triage moves on).
  final VoidCallback? onAnswered;

  @override
  State<AgentReply> createState() => _AgentReplyState();
}

class _AgentReplyState extends State<AgentReply> with TapGuardState<AgentReply>, AnswerSurfaceMixin<AgentReply> {
  late final PanePreviews _previews = context.read<PanePreviews>();
  final _input = TextEditingController();
  Timer? _advance;

  @override
  MachineConnection get answerMachine => widget.agent.machine;
  @override
  String get answerPaneId => widget.agent.paneId;
  @override
  PanePreviews get answerPreviews => _previews;

  /// The sheet walks on after an answer instead of showing the next question
  /// in place.
  @override
  bool get resetsOnNewQuestion => false;

  QuickReplyController get _reply => answerController;
  PreviewHandle get _handle => answerHandle!;

  @override
  void initState() {
    super.initState();
    watchAnswers();
    // The guard is already armed: the sheet, and its answers, just appeared.
    shownPrompt = _handle.preview.value?.prompt;
  }

  @override
  void dispose() {
    _advance?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _answered(bool sent) {
    if (!sent || widget.onAnswered == null) return;
    widget.onSent?.call();
    _advance?.cancel();
    // Long enough to read "Sent: 1. Yes".
    _advance = Timer(Dwell.sentRead, () {
      if (mounted) widget.onAnswered!();
    });
  }

  /// Whether the question's chips are on screen (what the build draws them for).
  bool get _asking =>
      widget.agent.status == AgentStatus.blocked && !widget.agent.stale && _handle.preview.value?.prompt != null;

  /// The keyboard's Send. On an empty field it is a bare Enter, and a bare
  /// Enter while a question is shown would choose whatever the agent has
  /// highlighted, past the chips' hold and guard: it is refused with a toast
  /// (as the pane screen does), and otherwise waits for the guard and a free
  /// controller like the Enter key button does. Typed text is deliberate, and
  /// is not a tap on something that moved: it only needs a live agent.
  Future<void> _submit() async {
    if (widget.agent.stale || _reply.busy) return;
    final text = _input.text;
    if (text.trim().isEmpty) {
      if (!settled) return;
      if (_asking) {
        Haptics.failed();
        showToast(context, 'Pick an answer above');
        return;
      }
    }
    final sent = await _reply.sendLine(text);
    if (sent && mounted && _input.text == text) _input.clear();
    _answered(sent);
  }

  Future<void> _choose(PromptInfo asked, QuickReply r) async => _answered(await chooseAnswer(asked, r));

  void _openFull() {
    final a = widget.agent;
    Haptics.tick();
    Navigator.of(context).pop();
    openAgent(context, PaneAgent(a.machine.profile.id, a.paneId));
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final a = widget.agent;
    final live = !a.stale;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Gap.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Gap.hair),
              child: StatusGlyph(status: a.status, size: IconSize.lead, dim: false),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  a.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Type.row.copyWith(color: ds.text),
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            StateTime(agent: a),
          ],
        ),
        if (a.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: IconSize.lead + Gap.md, top: Gap.hair),
            child: Text(
              a.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ),
        const SizedBox(height: Gap.md),
        ValueListenableBuilder<PanePreview?>(
          valueListenable: _handle.preview,
          builder: (context, preview, _) {
            final prompt = preview?.prompt;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetPreview(lines: preview?.lines, dim: !live),
                if (a.status == AgentStatus.blocked && live && prompt != null) ...[
                  const SizedBox(height: Gap.md),
                  QuestionWash(question: prompt.question, subject: prompt.subject, size: QuestionWashSize.full),
                  const SizedBox(height: Gap.sm),
                  ReplyChips(
                    prompt: prompt,
                    controller: _reply,
                    // What is sent is checked against exactly the question
                    // these chips were drawn from.
                    onChoose: (r) => _choose(prompt, r),
                    onMore: null,
                    fixedHeight: false,
                    guarded: !settled,
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: Gap.md),
        ComposerFrame(
          field: ComposerField(
            controller: _input,
            enabled: live,
            hint: composerHint(agentName(a.machine.paneById(a.paneId)?.agent), linkWord: live ? null : 'Offline'),
            onSubmit: _submit,
            // A line for the agent's prompt, in the terminal's font.
            mono: true,
            maxLines: 1,
            autocorrect: false,
            enableSuggestions: false,
            hasLeading: false,
          ),
          trailing: ListenableBuilder(
            listenable: Listenable.merge([_input, _reply]),
            builder: (context, _) {
              final busy = _reply.busy;
              return ComposerRoundButton(
                label: 'Send',
                icon: LucideIcons.arrowUp,
                iconSize: IconSize.bar,
                ready: live && !busy && _input.text.trim().isNotEmpty,
                busy: busy,
                onPressed: _submit,
              );
            },
          ),
        ),
        const SizedBox(height: Gap.sm),
        ListenableBuilder(
          listenable: _reply,
          builder: (context, _) {
            final enabled = live && settled && !_reply.busy;
            return Row(
              children: [
                // Wraps, so large text or a narrow phone never overflows.
                Expanded(
                  child: Wrap(
                    spacing: Gap.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      KeyCap(
                        label: 'esc',
                        // Moving through a menu is not an answer: it never
                        // moves the walk on to another agent.
                        onTap: enabled ? () => _reply.sendKey('esc') : null,
                      ),
                      KeyCap(
                        icon: LucideIcons.arrowUp,
                        semanticLabel: 'Up',
                        onTap: enabled ? () => _reply.sendKey('up') : null,
                      ),
                      KeyCap(
                        icon: LucideIcons.arrowDown,
                        semanticLabel: 'Down',
                        onTap: enabled ? () => _reply.sendKey('down') : null,
                      ),
                      KeyCap(
                        icon: LucideIcons.cornerDownLeft,
                        semanticLabel: 'Enter',
                        onTap: enabled ? () => _reply.sendKey('enter') : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Gap.sm),
                AppButton(
                  label: 'Open full',
                  icon: LucideIcons.maximize2,
                  kind: AppButtonKind.ghost,
                  compact: true,
                  onPressed: _openFull,
                ),
              ],
            );
          },
        ),
        // Typed text and single keys have no chip to carry their outcome: it
        // shows here, so a failure is never silent.
        ListenableBuilder(
          listenable: _reply,
          builder: (context, _) {
            // The answer's chip carries its outcome while the chips are on
            // screen; once they are gone (the agent moved on) it shows here.
            final own =
                _reply.subject == null ||
                !(a.status == AgentStatus.blocked && live && _handle.preview.value?.prompt != null);
            final text = !own
                ? null
                : switch (_reply.phase) {
                    ReplyPhase.failed => 'Couldn’t send: ${_reply.error ?? 'unknown error'}',
                    ReplyPhase.sent => 'Sent: ${_reply.sentLabel}',
                    _ => null,
                  };
            final failed = _reply.phase == ReplyPhase.failed;
            return AnimatedSize(
              duration: Motion.of(context, Motion.standard),
              curve: Motion.easeOut,
              alignment: Alignment.topCenter,
              child: text == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: Gap.sm),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Type.secondary.copyWith(color: failed ? ds.dangerText : ds.textSecondary),
                        ),
                      ),
                    ),
            );
          },
        ),
      ],
    );
  }
}

/// The terminal tail: [rows] rows in view, up to everything the preview kept
/// (8) by scrolling up; nothing wraps, a long line (a command about to run)
/// scrolls sideways instead of being cut off.
class _SheetPreview extends StatelessWidget {
  const _SheetPreview({required this.lines, required this.dim});

  final List<PreviewLine>? lines;
  final bool dim;

  static const rows = 6;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15);
    const style = Mono.small;
    final line = scaler.scale(style.fontSize!) * style.height!;
    final tail = lines;
    Widget content;
    if (tail == null) {
      content = Align(
        alignment: Alignment.bottomLeft,
        child: Text('Loading…', style: style.copyWith(color: ds.textMuted)),
      );
    } else if (tail.isEmpty) {
      content = Align(
        alignment: Alignment.bottomLeft,
        child: Text('No output yet', style: style.copyWith(color: ds.textMuted)),
      );
    } else {
      content = SingleChildScrollView(
        // Anchored to the newest line.
        reverse: true,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, l) in tail.indexed)
                Text(
                  l.text,
                  softWrap: false,
                  textScaler: scaler,
                  style: style.copyWith(color: i == tail.length - 1 ? ds.text : ds.textSecondary),
                ),
            ],
          ),
        ),
      );
    }
    final panel = SizedBox(
      height: rows * line * 1.04 + 2 * (Gap.sm + Gap.hair),
      child: Panel(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm + Gap.hair),
        child: Align(alignment: Alignment.bottomLeft, child: content),
      ),
    );
    return Semantics(
      label: tail == null || tail.isEmpty ? 'Terminal preview' : 'Terminal preview: ${tail.last.text}',
      excludeSemantics: true,
      child: dim ? Opacity(opacity: 0.55, child: panel) : panel,
    );
  }
}

/// A sheet's height while it has nothing to show yet, or `All clear`.
const _frameHeight = 120.0;
