import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../core/tap_guard.dart';
import '../../core/theme.dart';
import '../agents/agent_card.dart' show promptSubjectStyle;
import '../agents/quick_reply_controller.dart';
import '../agents/reply_chips.dart';
import '../agents/reply_sheet.dart';

/// Most chips the dock draws: three answers and, when there are more options
/// than that, an `N more…` chip that opens the reply sheet.
const dockChipLimit = 4;

/// The question a blocked agent is waiting on, with its answers (a tap, or a
/// hold for a risky one), in a strip directly above the key row of the pane it
/// belongs to.
///
/// Shown only while the pane's agent is blocked, its machine is live and the
/// prompt is one the app understands ([PanePreview.prompt]); otherwise it
/// takes no room at all. It watches the pane's preview only in that case, and
/// only while its screen is the one in front (a screen covered by another runs
/// with tickers off, see `TickerMode`): the watch is released when another
/// screen covers it, the pane stops being blocked, or the page goes.
///
/// Its height is the question (one line when there is a subject, else two), the
/// subject (at most two lines of mono: what the answer approves, always next to
/// the thumb that approves it) and [ReplyChips.heightFor] the chip count. It
/// reads nothing from the window insets, and the page builds it once, so the
/// keyboard animation never rebuilds it.
///
/// Its answers come up under a thumb that was typing or pressing keys, so they
/// take no tap and are dimmed for `tapGuard` each time the dock appears and
/// each time its question changes (`TapGuardState`).
class AnswerDock extends StatefulWidget {
  const AnswerDock({super.key, required this.paneId, required this.asking});

  final String paneId;

  /// True while the dock shows a question, false otherwise (and once it is
  /// gone). The page reads it when a bare Enter is pressed; nothing listens,
  /// so the dock may set it from any lifecycle callback.
  final ValueNotifier<bool> asking;

  @override
  State<AnswerDock> createState() => _AnswerDockState();
}

class _AnswerDockState extends State<AnswerDock> with TapGuardState<AnswerDock> {
  late final MachineConnection _machine = context.read<MachineConnection>();
  late final PanePreviews _previews = context.read<PanePreviews>();
  PreviewHandle? _handle;
  QuickReplyController? _reply;
  PromptInfo? _sentFor;

  /// The question the dock shows, null while it shows none: a different one
  /// arms the guard again.
  PromptInfo? _shown;
  bool _onScreen = true;

  @override
  void initState() {
    super.initState();
    _machine.addListener(_onMachine);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onScreen = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void dispose() {
    _machine.removeListener(_onMachine);
    _release();
    _reply?.dispose();
    super.dispose();
  }

  bool get _wantsWatch =>
      _onScreen &&
      _machine.isLive &&
      _machine.paneById(widget.paneId)?.status == AgentStatus.blocked;

  void _onMachine() {
    if (!mounted) return;
    final before = _handle;
    _sync();
    if ((before == null) != (_handle == null)) setState(() {});
  }

  /// Makes the watch match [_wantsWatch]. Never rebuilds: callers do.
  void _sync() {
    if (_wantsWatch) {
      if (_handle != null) return;
      final handle = _previews.watch(
        _machine.profile.id,
        widget.paneId,
      );
      handle.preview.addListener(_onPreview);
      _handle = handle;
      _onPreview();
    } else {
      _release();
    }
  }

  void _release() {
    final handle = _handle;
    if (handle == null) return;
    handle.preview.removeListener(_onPreview);
    handle.release();
    _handle = null;
    _shown = null;
    widget.asking.value = false;
  }

  void _onPreview() {
    final prompt = _handle?.preview.value?.prompt;
    // The dock appeared, or its question changed under the thumb: the rebuild
    // this preview brings draws the answers dimmed and deaf.
    if (prompt != _shown) {
      _shown = prompt;
      widget.asking.value = prompt != null;
      if (prompt != null) rearmGuard();
    }
    // A new question while "Sent" is showing: the answer did something and the
    // agent asked again, so show the new chips now instead of after the hold.
    final reply = _reply;
    if (reply == null || reply.phase != ReplyPhase.sent) return;
    if (prompt != _sentFor) reply.reset();
  }

  QuickReplyController get _controller => _reply ??= QuickReplyController(
    machine: _machine,
    paneId: widget.paneId,
    previews: _previews,
  );

  /// The chips are deaf while unsettled; this refuses too, so no path to an
  /// answer skips the guard. [asked] is the question the chips were drawn for.
  Future<void> _choose(PromptInfo asked, QuickReply reply) async {
    if (!settled) return;
    _sentFor = asked;
    await _controller.choose(reply, asked: asked);
  }

  void _openSheet() {
    if (!settled) return;
    unawaited(showReplySheet(context, key: '${_machine.profile.id}/${widget.paneId}'));
  }

  @override
  Widget build(BuildContext context) {
    final handle = _handle;
    if (handle == null) return const SizedBox.shrink();
    return ValueListenableBuilder<PanePreview?>(
      valueListenable: handle.preview,
      builder: (context, preview, _) {
        final prompt = preview?.prompt;
        if (prompt == null) return const SizedBox.shrink();
        return _Dock(
          prompt: prompt,
          controller: _controller,
          onChoose: (r) => _choose(prompt, r),
          onMore: _openSheet,
          guarded: !settled,
        );
      },
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock({
    required this.prompt,
    required this.controller,
    required this.onChoose,
    required this.onMore,
    required this.guarded,
  });

  final PromptInfo prompt;
  final QuickReplyController controller;
  final Future<void> Function(QuickReply reply) onChoose;
  final VoidCallback onMore;
  final bool guarded;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final chips = ReplyChips.count(prompt, limit: dockChipLimit);
    return Padding(
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prompt.question,
                    maxLines: prompt.subject.isEmpty ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.prompt.copyWith(color: ds.text),
                  ),
                  if (prompt.subject.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      prompt.subject,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: promptSubjectStyle.copyWith(color: ds.text),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: ReplyChips.heightFor(chips),
            child: ReplyChips(
              prompt: prompt,
              controller: controller,
              onChoose: onChoose,
              onMore: onMore,
              limit: dockChipLimit,
              guarded: guarded,
            ),
          ),
        ],
      ),
    );
  }
}
