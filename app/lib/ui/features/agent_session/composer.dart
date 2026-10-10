import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/prompt_queue.dart' show SendDelivery;
import '../../../data/acp/session_state.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attach_target.dart' show AttachMode;
import '../../core/tap_guard.dart';
import '../composer/composer_frame.dart';
import '../dictation/dictation_language_sheet.dart';
import '../dictation/dictation_session.dart';
import '../pane/quick_phrases_row.dart';
import 'attach_chips.dart';
import 'attach_model.dart';
import 'attach_sheet.dart';
import 'queued_hint.dart';
import 'queued_messages.dart';
import 'session_chips_row.dart';
import 'session_select.dart';

/// Why the composer cannot send, in the words of its hint; null when it can.
String? composerReason(AgentLink link) => switch (link) {
  AgentLink.live => null,
  AgentLink.connecting => 'Connecting…',
  AgentLink.reconnecting => 'Reconnecting… you can write when it is back',
  AgentLink.ended => 'Session ended · read only',
  AgentLink.failed => 'Not connected',
};

/// Rounded multi-line input (grows to five lines) between an attach button at
/// its left and the round buttons at its right: send, and while the agent
/// works, stop.
///
/// While the agent works the same field takes the next message: the send
/// button becomes Queue (or Send, for an agent that takes input into the
/// running turn), a quiet line above the field says which ([DeliveryHint]),
/// and what waits shows above it ([QueuedMessages]). Send never moves: Stop is
/// its own round button to its left, drawn when a turn runs and deaf for
/// [tapGuard] after it appears, so the tap that sent a message cannot land on
/// it. An observed session (an agent in a terminal) has no queue: Stop takes
/// the place of Send.
///
/// Pictures and files wait as chips above the field ([AttachmentChips]) and
/// go out with the text; the message cannot be sent while one is still being
/// prepared. The compact layout has no room for the chips: the paperclip
/// carries a count instead.
///
/// Disabled with the reason as its hint unless the link is live. It reads
/// nothing from the window insets and is built once by the screen, so the
/// keyboard's animation re-lays it out and rebuilds nothing. The keyboard is
/// asked for on pointer-down, as in the pane's composer.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.session,
    required this.controller,
    required this.focusNode,
    required this.attachments,
    required this.onSubmit,
    this.onStop,
    this.dictation,
  });

  final AgentSessionView session;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Pictures and files that go out with the draft.
  final ComposerAttachments attachments;

  /// Send the draft (the keyboard's send key and the button).
  final VoidCallback onSubmit;

  /// The person tapped Stop (called before the session is told to cancel).
  final VoidCallback? onStop;

  /// Dictation into the field; the mic takes Send's place while the field is
  /// empty. Null without a speech service (tests).
  final DictationSession? dictation;

  @override
  Widget build(BuildContext context) =>
      SessionSelect<(AgentLink, AgentPhase, bool, String?, String?, SendDelivery, bool)>(
    session: session,
    select: (s) => (s.link, s.phase, s.state.cancelRequested, s.sendBlocked, s.relayNote, s.delivery, s.waitingOnBackground),
    builder: (context, snapshot) {
      final (link, phase, stopping, blocked, relay, delivery, waiting) = snapshot;
      final live = link == AgentLink.live;
      final typing = live && blocked == null;
      final reason = composerReason(link);
      // Waiting on background work the turn is over: Send, not Stop (Stop
      // would end nothing, and an agent in a terminal still says `working`).
      final working = live && phase != AgentPhase.idle && relay == null && !waiting;
      final observed = session.isObserved;
      final attaches = session.attachMode != AttachMode.none;
      final queuing = working && !observed;
      final hint = reason ?? blocked ?? (relay != null ? '$relay…' : 'Message ${session.agentLabel}…');
      final field = ComposerFrame(
        // A subagent's run takes no attachments. In the compact layout the
        // chips are gone, and the paperclip says how many go along.
        leading: !attaches
            ? null
            : ListenableBuilder(
                listenable: attachments,
                builder: (context, _) {
                  void open() =>
                      unawaited(showAttachSheet(context, target: session, attachments: attachments));
                  return HideWhenCompact(
                    compact: ComposerAttachButton(enabled: typing, count: attachments.items.length, onPressed: open, onWarm: attachments.warm),
                    child: ComposerAttachButton(enabled: typing, onPressed: open, onWarm: attachments.warm),
                  );
                },
              ),
        field: ListenableBuilder(
          // The hint says why Send waits while a picture or a file is still
          // on its way.
          listenable: attachments,
          builder: (context, _) => ComposerField(
            controller: controller,
            focusNode: focusNode,
            enabled: typing,
            keyboardOnPointerDown: live,
            keyboardType: TextInputType.multiline,
            hint: reason ?? blocked ?? attachments.waitingReason ?? hint,
            onSubmit: onSubmit,
            hasLeading: attaches,
          ),
        ),
        trailing: ListenableBuilder(
          listenable: Listenable.merge([controller, attachments, ?dictation]),
          builder: (context, _) {
            final hasContent = controller.text.trim().isNotEmpty || !attachments.isEmpty;
            final (sendLabel, sendIcon) = switch (delivery) {
              SendDelivery.queued => ('Queue', LucideIcons.listPlus),
              SendDelivery.steered => ('Send to the running turn', LucideIcons.arrowUp),
              SendDelivery.now => ('Send', LucideIcons.arrowUp),
            };
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (working)
                  _StopButton(
                    key: const ValueKey('stop'),
                    stopping: stopping,
                    onPressed: () {
                      onStop?.call();
                      session.cancel();
                    },
                    // Beside Send it is the secondary action; alone (a
                    // terminal agent) it is the only one.
                    quiet: queuing,
                  ),
                if (!working || queuing)
                  if (dictation case final dictate? when typing && (dictate.listening || !hasContent))
                    // The mic is Send's place while there is nothing to send;
                    // a long press picks the language.
                    ComposerRoundButton(
                      key: const ValueKey('mic'),
                      label: dictate.listening ? 'Stop dictating' : 'Dictate',
                      icon: LucideIcons.mic,
                      iconSize: 18,
                      ready: true,
                      quiet: !dictate.listening,
                      onPressed: () => unawaited(dictate.toggle()),
                      onLongPress: dictate.listening
                          ? null
                          : () => unawaited(showDictationLanguageSheet(context, dictate.dictation)),
                    )
                  else
                    ComposerRoundButton(
                      key: const ValueKey('send'),
                      label: sendLabel,
                      icon: sendIcon,
                      iconSize: 18,
                      ready: typing && hasContent && attachments.canSend,
                      onPressed: onSubmit,
                    ),
              ],
            );
          },
        ),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Mode, model and the switches, then the quick phrases and what
          // waits to be sent: all go in the compact layout.
          HideWhenCompact(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SessionChipsRow(session: session, focus: focusNode),
                if (live) QuickPhrasesRow(input: controller, focus: focusNode),
                if (live) _QueueShare(child: QueuedMessages(session: session)),
              ],
            ),
          ),
          // What goes out with the draft, above the field; the quiet line
          // about its delivery under it, once the person engages the field
          // (focus or a draft): a turn ending must not shrink the composer
          // under an answer that is being read.
          HideWhenCompact(child: AttachmentChips(attachments: attachments)),
          HideWhenCompact(
            child: ListenableBuilder(
              listenable: Listenable.merge([focusNode, controller]),
              builder: (context, _) => DeliveryHint(
                delivery: queuing && typing && (focusNode.hasFocus || controller.text.isNotEmpty) ? delivery : null,
              ),
            ),
          ),
          field,
        ],
      );
    },
  );
}

/// Takes [child] out of the layout in the compact layout (landscape with the
/// keyboard up), where the composer needs all the room, as the pane does for
/// its slash palette; [compact] stands in its place when given.
///
/// The session screen sits inside a `Scaffold`, which hides the keyboard inset
/// from what it holds, and nothing here may rebuild for a keyboard frame. So
/// the window is read directly and the answer only rebuilds this widget when
/// it flips, a few times per rotation or keyboard opening, never per frame.
class HideWhenCompact extends StatefulWidget {
  const HideWhenCompact({super.key, required this.child, this.compact = const SizedBox.shrink()});

  final Widget child;
  final Widget compact;

  @override
  State<HideWhenCompact> createState() => _HideWhenCompactState();
}

class _HideWhenCompactState extends State<HideWhenCompact> with WidgetsBindingObserver {
  late FlutterView _view;
  bool _compact = false;

  bool _read() => _view.physicalSize.width > _view.physicalSize.height && _view.viewInsets.bottom > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _compact = _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final next = _read();
    if (next != _compact) setState(() => _compact = next);
  }

  @override
  Widget build(BuildContext context) => _compact ? widget.compact : widget.child;
}

/// Stop is its own button, left of Send (or alone, in Send's place, for an
/// agent in a terminal). It takes no tap for [tapGuard] after it appears: the
/// tap that started the turn, or its second half, must not cancel it. Beside
/// Send (`quiet`) it is a neutral button; alone it is the primary one.
class _StopButton extends StatefulWidget {
  const _StopButton({super.key, required this.stopping, required this.onPressed, this.quiet = false});

  final bool stopping;
  final VoidCallback onPressed;
  final bool quiet;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton> with TapGuardState<_StopButton> {
  @override
  Widget build(BuildContext context) => ComposerRoundButton(
        label: 'Stop',
        icon: LucideIcons.square,
        iconSize: 14,
        busy: widget.stopping,
        ready: settled && !widget.stopping,
        quiet: widget.quiet,
        onPressed: widget.onPressed,
      );
}

/// The queue never takes more than this share of the window; past it, the
/// rows scroll. The composer is not flexible in the screen's bottom region
/// (it always stays in reach), so something here must give at a large text
/// size on a small phone. The window's height, not the room left: the room
/// changes with every frame of the keyboard.
class _QueueShare extends StatelessWidget {
  const _QueueShare({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.28),
    child: SingleChildScrollView(child: child),
  );
}
