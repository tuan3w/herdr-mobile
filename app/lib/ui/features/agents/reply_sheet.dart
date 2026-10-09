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
import '../../../data/repositories/pane_previews.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/draw_check.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/tap_guard.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'agent_navigation.dart';
import 'agent_card.dart';
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
  static const _allClearHold = Duration(milliseconds: 900);

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
    final others = [for (final k in waiting) if (k != _key) k];
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
        return const SizedBox(height: 120);
      }
      return _SheetFrame(triage: null, child: AgentReply(key: ValueKey(agent.key), agent: agent));
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
          return const SizedBox(height: 120);
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
      _ => const SizedBox(height: 120),
    };
    return _lastWalk = _SheetFrame(
      triage: total > 0
          ? _TriageBar(
              index: math.max(index, 0),
              total: total,
              onPrev: total > 1 && !holding ? () => _go(-1, waiting) : null,
              onNext: total > 1 && !holding ? () => _go(1, waiting) : null,
            )
          : null,
      child: child,
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
              padding: EdgeInsets.only(top: 2),
              child: StatusGlyph(status: AgentStatus.blocked, size: 20, dim: false),
            ),
            const SizedBox(width: 10),
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
            padding: const EdgeInsets.only(left: 30, top: 2),
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ),
        if (blockedSummary(session) case final summary?) ...[
          const SizedBox(height: Gap.md),
          _SheetQuestion(question: summary, subject: ''),
        ],
        const SizedBox(height: Gap.md),
        AppButton(
          label: 'Answer in the session',
          icon: LucideIcons.messageSquare,
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
      height: 120,
      child: Semantics(
        liveRegion: true,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DrawCheck(color: ds.done, size: 22),
            const SizedBox(width: 10),
            Text('All clear', style: Type.row.copyWith(color: ds.text)),
          ],
        ),
      ),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.triage, required this.child});

  final Widget? triage;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        // Lifts the sheet over the keyboard.
        padding: EdgeInsets.fromLTRB(
          Gap.gutter,
          Gap.sm,
          Gap.gutter,
          Gap.md + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?triage,
            child,
          ],
        ),
      );
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
        CircleButton(
          icon: LucideIcons.chevronLeft,
          tooltip: 'Previous agent',
          onPressed: onPrev,
          filled: false,
        ),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(
              '${index + 1} of $total need you',
              textAlign: TextAlign.center,
              style: Type.label.copyWith(
                color: ds.blockedText,
                fontWeight: FontWeight.w600,
                fontFeatures: Type.tabular,
              ),
            ),
          ),
        ),
        CircleButton(
          icon: LucideIcons.chevronRight,
          tooltip: 'Next agent',
          onPressed: onNext,
          filled: false,
        ),
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

class _AgentReplyState extends State<AgentReply> with TapGuardState<AgentReply> {
  late final QuickReplyController _reply;
  late final PreviewHandle _handle;
  final _input = TextEditingController();
  Timer? _advance;

  /// The question the chips were last drawn for: a different one arms the
  /// guard again, so a tap meant for the old chips cannot answer the new ones.
  PromptInfo? _shown;

  @override
  void initState() {
    super.initState();
    final previews = context.read<PanePreviews>();
    _handle = previews.watch(widget.agent.machine.profile.id, widget.agent.paneId);
    _reply = QuickReplyController(machine: widget.agent.machine, paneId: widget.agent.paneId, previews: previews);
    _shown = _handle.preview.value?.prompt;
    _handle.preview.addListener(_onPreview);
  }

  void _onPreview() {
    final prompt = _handle.preview.value?.prompt;
    if (prompt == _shown) return;
    _shown = prompt;
    if (prompt != null) rearmGuard();
  }

  @override
  void dispose() {
    _advance?.cancel();
    _handle.preview.removeListener(_onPreview);
    _handle.release();
    _reply.dispose();
    _input.dispose();
    super.dispose();
  }

  void _answered(bool sent) {
    if (!sent || widget.onAnswered == null) return;
    widget.onSent?.call();
    _advance?.cancel();
    // Long enough to read "Sent: 1. Yes".
    _advance = Timer(const Duration(milliseconds: 700), () {
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
        Haptics.tick();
        showToast(context, 'Pick an answer above');
        return;
      }
    }
    final sent = await _reply.sendLine(text);
    if (sent && mounted && _input.text == text) _input.clear();
    _answered(sent);
  }

  Future<void> _choose(PromptInfo asked, QuickReply r) async => _answered(await _reply.choose(r, asked: asked));

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
              padding: const EdgeInsets.only(top: 2),
              child: StatusGlyph(status: a.status, size: 20, dim: false),
            ),
            const SizedBox(width: 10),
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
            const SizedBox(width: 8),
            StateTime(agent: a),
          ],
        ),
        if (a.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 30, top: 2),
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
                  _SheetQuestion(question: prompt.question, subject: prompt.subject),
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
        _SheetComposer(
          controller: _input,
          agent: a.title,
          enabled: live,
          sending: _reply,
          onSubmit: _submit,
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
                      _KeyButton(
                        label: 'esc',
                        // Moving through a menu is not an answer: it never
                        // moves the walk on to another agent.
                        onPressed: enabled ? () => _reply.sendKey('esc') : null,
                      ),
                      _KeyButton(
                        icon: LucideIcons.arrowUp,
                        semantic: 'Up',
                        onPressed: enabled ? () => _reply.sendKey('up') : null,
                      ),
                      _KeyButton(
                        icon: LucideIcons.arrowDown,
                        semantic: 'Down',
                        onPressed: enabled ? () => _reply.sendKey('down') : null,
                      ),
                      _KeyButton(
                        icon: LucideIcons.cornerDownLeft,
                        semantic: 'Enter',
                        onPressed:
                            enabled ? () => _reply.sendKey('enter') : null,
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
            final own = _reply.subject == null ||
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
              duration: Motion.reduced(context) ? Duration.zero : Motion.standard,
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
                          style: Type.secondary.copyWith(
                            color: failed ? ds.dangerText : ds.textSecondary,
                          ),
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

class _SheetQuestion extends StatelessWidget {
  const _SheetQuestion({required this.question, required this.subject});

  final String question;

  /// What the question is about, in full (up to 6 rows); empty when none.
  final String subject;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ds.blockedWash,
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: Type.prompt.copyWith(color: ds.text),
          ),
          if (subject.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subject, style: promptSubjectStyle.copyWith(color: ds.text)),
          ],
        ],
      ),
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
    final line = scaler.scale(previewFontSize) * previewHeightFactor;
    final tail = lines;
    final style = previewTextStyle.copyWith(fontSize: previewFontSize + 0.5);
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
    final panel = Container(
      height: rows * line * 1.04 + 20,
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(10)),
      child: content,
    );
    return Semantics(
      label: tail == null || tail.isEmpty ? 'Terminal preview' : 'Terminal preview: ${tail.last.text}',
      excludeSemantics: true,
      child: dim ? Opacity(opacity: 0.55, child: panel) : panel,
    );
  }
}

class _SheetComposer extends StatelessWidget {
  const _SheetComposer({
    required this.controller,
    required this.agent,
    required this.enabled,
    required this.sending,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String agent;
  final bool enabled;
  final QuickReplyController sending;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    const none = InputBorder.none;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: ds.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onEditingComplete: onSubmit,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: monoFamily,
                fontSize: 14,
                height: 1.5,
                color: enabled ? ds.text : ds.textTertiary,
              ),
              cursorColor: ds.accent,
              decoration: InputDecoration(
                hintText: enabled ? 'Message the agent…' : 'Offline',
                hintStyle: Type.body.copyWith(height: 1.4, color: ds.textMuted),
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.fromLTRB(Gap.lg, 12.5, Gap.sm, 12.5),
                border: none,
                enabledBorder: none,
                focusedBorder: none,
                disabledBorder: none,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(1),
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, sending]),
              builder: (context, _) {
                final busy = sending.busy;
                final ready = enabled && !busy && controller.text.trim().isNotEmpty;
                return PressBuilder(
                  onTap: ready ? onSubmit : null,
                  scale: 0.92,
                  semanticLabel: 'Send',
                  builder: (context, pressed) => SizedBox.square(
                    dimension: 46,
                    child: Center(
                      child: AnimatedContainer(
                        duration: Motion.standard,
                        curve: Motion.easeOut,
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: ready
                              ? (pressed
                                  ? Color.alphaBlend(Colors.black.withValues(alpha: 0.12), ds.accent)
                                  : ds.accent)
                              : ds.fill,
                        ),
                        alignment: Alignment.center,
                        child: busy
                            ? const BusySpinner()
                            : Icon(
                                LucideIcons.arrowUp,
                                size: 18,
                                color: ready ? ds.onAccent : ds.textTertiary,
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({this.label, this.icon, this.semantic, required this.onPressed});

  final String? label;
  final IconData? icon;
  final String? semantic;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final color = onPressed == null ? ds.textTertiary : ds.text;
    return PressBuilder(
      onTap: onPressed,
      scale: 0.96,
      button: true,
      minTapSize: kMinTap,
      semanticLabel: icon != null ? semantic : null,
      builder: (context, pressed) => AnimatedContainer(
        duration: pressed ? Motion.press : Motion.release,
        curve: Motion.easeOut,
        height: 36,
        constraints: const BoxConstraints(minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : ds.fill,
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        // widthFactor: shrink-wrap, so a Wrap gives it its own width, not all.
        child: Center(
          widthFactor: 1,
          child: icon != null
              ? Icon(icon, size: 16, color: color)
              : Text(
                  label!,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
        ),
      ),
    );
  }
}
