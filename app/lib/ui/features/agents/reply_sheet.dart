import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../pane/pane_navigation.dart';
import 'agent_card.dart';
import 'agents_grouping.dart';
import 'quick_reply_controller.dart';
import 'reply_chips.dart';

/// Opens the reply sheet for one agent: a live look at its terminal, the
/// prompt's one-tap answers, a one-line composer and the keys a prompt needs,
/// so it can be answered without leaving the board.
Future<void> showReplySheet(BuildContext context, {required String key}) =>
    showAppSheet<void>(context, builder: (_) => ReplySheet(startKey: key, triage: false));

/// Walks the agents that are blocked, one after another. Answering moves on to
/// the next; prev/next jump around ("2 of 3"). Closes itself when none is left.
Future<void> showTriageSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const ReplySheet(startKey: null, triage: true));

/// The sheet's body. Public for tests.
class ReplySheet extends StatefulWidget {
  const ReplySheet({super.key, required this.startKey, required this.triage});

  /// Agent to start on (its `AgentRowData.key`); null = the first blocked one.
  final String? startKey;
  final bool triage;

  @override
  State<ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends State<ReplySheet> {
  String? _key;

  // Blocked agents in the order they were last seen, so that after one is
  // answered "next" means the one that followed it, not the first again.
  List<String> _order = const [];
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _key = widget.startKey;
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  void _go(int delta, List<AgentRowData> blocked) {
    if (blocked.isEmpty) return;
    final at = blocked.indexWhere((a) => a.key == _key);
    final next = blocked[((at < 0 ? 0 : at) + delta) % blocked.length];
    setState(() => _key = next.key);
  }

  /// The agent after the current one among those still blocked.
  void _advance(List<AgentRowData> blocked) {
    final others = [for (final a in blocked) if (a.key != _key) a];
    if (others.isEmpty) return;
    final from = _order.indexOf(_key ?? '');
    for (var i = 1; i <= _order.length; i++) {
      final k = _order[(from + i) % _order.length];
      final match = others.where((a) => a.key == k);
      if (match.isNotEmpty) {
        setState(() => _key = match.first.key);
        return;
      }
    }
    setState(() => _key = others.first.key);
  }

  @override
  Widget build(BuildContext context) {
    final overview = context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    final blocked = blockedAgents(overview.agents);
    AgentRowData? current;
    for (final a in overview.agents) {
      if (a.key == _key) current = a;
    }

    if (widget.triage) {
      // The agent in view was answered (or went away): move to the next one
      // that still waits; nobody left means the work is done.
      if (current == null || !blocked.any((a) => a.key == current!.key)) {
        final fallback = _fallback(blocked);
        if (fallback == null) {
          _close();
          return const SizedBox(height: 120);
        }
        current = fallback;
        _key = fallback.key;
      }
      _order = [for (final a in blocked) a.key];
    } else if (current == null) {
      _close();
      return const SizedBox(height: 120);
    }

    final index = blocked.indexWhere((a) => a.key == current!.key);
    return _SheetFrame(
      triage: widget.triage && blocked.isNotEmpty
          ? _TriageBar(
              index: math.max(index, 0),
              total: blocked.length,
              onPrev: blocked.length > 1 ? () => _go(-1, blocked) : null,
              onNext: blocked.length > 1 ? () => _go(1, blocked) : null,
            )
          : null,
      child: AgentReply(
        key: ValueKey(current.key),
        agent: current,
        onAnswered: widget.triage ? () => _advance(blocked) : null,
      ),
    );
  }

  AgentRowData? _fallback(List<AgentRowData> blocked) {
    if (blocked.isEmpty) return null;
    final from = _order.indexOf(_key ?? '');
    for (var i = 1; i <= _order.length; i++) {
      final k = _order[(from + i) % _order.length];
      for (final a in blocked) {
        if (a.key == k) return a;
      }
    }
    return blocked.first;
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
  const AgentReply({super.key, required this.agent, this.onAnswered});

  final AgentRowData agent;

  /// Called a moment after an answer went out (triage moves on).
  final VoidCallback? onAnswered;

  @override
  State<AgentReply> createState() => _AgentReplyState();
}

class _AgentReplyState extends State<AgentReply> {
  late final QuickReplyController _reply =
      QuickReplyController(machine: widget.agent.machine, paneId: widget.agent.paneId);
  late final PreviewHandle _handle;
  final _input = TextEditingController();
  Timer? _advance;

  @override
  void initState() {
    super.initState();
    _handle = context.read<PanePreviews>().watch(widget.agent.machine.profile.id, widget.agent.paneId);
  }

  @override
  void dispose() {
    _advance?.cancel();
    _handle.release();
    _reply.dispose();
    _input.dispose();
    super.dispose();
  }

  void _answered(bool sent) {
    if (!sent || widget.onAnswered == null) return;
    _advance?.cancel();
    // Long enough to read "Sent: 1. Yes".
    _advance = Timer(const Duration(milliseconds: 700), () {
      if (mounted) widget.onAnswered!();
    });
  }

  Future<void> _submit() async {
    final text = _input.text;
    final sent = await _reply.sendLine(text);
    if (sent && mounted && _input.text == text) _input.clear();
    _answered(sent);
  }

  Future<void> _choose(QuickReply r) async => _answered(await _reply.choose(r));

  void _openFull() {
    final a = widget.agent;
    tapFeedback();
    Navigator.of(context).pop();
    openPaneTab(context, a.machine, a.paneId);
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
          builder: (context, preview, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetPreview(lines: preview?.lines, dim: !live),
              if (a.status == AgentStatus.blocked && live && preview?.prompt != null) ...[
                const SizedBox(height: Gap.md),
                _SheetQuestion(question: preview!.prompt!.question),
                const SizedBox(height: Gap.sm),
                ReplyChips(
                  prompt: preview.prompt!,
                  controller: _reply,
                  onChoose: _choose,
                  onMore: null,
                  fixedHeight: false,
                ),
              ],
            ],
          ),
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
            final enabled = live && !_reply.busy;
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
                        onPressed: enabled ? () async => _answered(await _reply.sendKey('esc')) : null,
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
                            enabled ? () async => _answered(await _reply.sendKey('enter')) : null,
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
            final own = _reply.subject == null;
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
  const _SheetQuestion({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ds.blocked.withValues(alpha: ds.isDark ? 0.12 : 0.09),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        question,
        style: Type.body.copyWith(fontSize: 14.5, height: 1.35, color: ds.text, fontWeight: FontWeight.w500),
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
