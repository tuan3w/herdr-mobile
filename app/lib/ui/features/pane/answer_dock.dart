import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../support/tap_guard.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../agents/answer_surface.dart';
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
/// Its height is the question and its subject ([QuestionWash], compact: at
/// most two lines of question and three of subject, `Read all` opens the
/// reply sheet when either is cut) and [ReplyChips.heightFor] its chips. It
/// reads nothing from the window insets, and the page builds it once, so the
/// keyboard animation never rebuilds it.
///
/// Its answers come up under a thumb that was typing or pressing keys, so they
/// take no tap and are dimmed for `Dwell.tapGuard` each time the dock appears and
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

class _AnswerDockState extends State<AnswerDock> with TapGuardState<AnswerDock>, AnswerSurfaceMixin<AnswerDock> {
  late final MachineConnection _machine = context.read<MachineConnection>();
  late final PanePreviews _previews = context.read<PanePreviews>();
  bool _onScreen = true;

  @override
  MachineConnection get answerMachine => _machine;
  @override
  String get answerPaneId => widget.paneId;
  @override
  PanePreviews get answerPreviews => _previews;

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
    super.dispose();
  }

  bool get _wantsWatch =>
      _onScreen && _machine.isLive && _machine.paneById(widget.paneId)?.status == AgentStatus.blocked;

  void _onMachine() {
    if (!mounted) return;
    final before = answerHandle;
    _sync();
    if ((before == null) != (answerHandle == null)) setState(() {});
  }

  /// Makes the watch match [_wantsWatch]. Never rebuilds: callers do.
  void _sync() => _wantsWatch ? watchAnswers(notify: true) : releaseAnswers();

  /// The dock appeared, or its question changed under the thumb: the rebuild
  /// this preview brings draws the answers dimmed and deaf.
  @override
  void onShownChanged(PromptInfo? prompt) => widget.asking.value = prompt != null;

  /// The chips are deaf while unsettled; this refuses too, so no path to an
  /// answer skips the guard. [asked] is the question the chips were drawn for.
  Future<void> _choose(PromptInfo asked, QuickReply reply) async {
    if (!settled) return;
    await chooseAnswer(asked, reply);
  }

  void _openSheet() {
    if (!settled) return;
    unawaited(showReplySheet(context, key: '${_machine.profile.id}/${widget.paneId}'));
  }

  @override
  Widget build(BuildContext context) {
    final handle = answerHandle;
    if (handle == null) return const SizedBox.shrink();
    return ValueListenableBuilder<PanePreview?>(
      valueListenable: handle.preview,
      builder: (context, preview, _) {
        final prompt = preview?.prompt;
        if (prompt == null) return const SizedBox.shrink();
        return _Dock(
          prompt: prompt,
          controller: answerController,
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
    return Padding(
      padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          QuestionWash(question: prompt.question, subject: prompt.subject, onReadAll: onMore),
          const SizedBox(height: Gap.sm),
          SizedBox(
            height: ReplyChips.heightFor(prompt, limit: dockChipLimit),
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
