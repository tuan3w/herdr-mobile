import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/prompt_queue.dart' show SendDelivery;
import '../../../data/acp/session_state.dart';
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/tap_guard.dart';
import '../../core/theme.dart';
import '../pane/quick_phrases_row.dart';
import 'attach_chips.dart';
import 'attach_model.dart';
import 'attach_sheet.dart';
import 'queued_hint.dart';
import 'queued_messages.dart';
import 'session_chips_row.dart';
import 'session_select.dart';

const _minHeight = 48.0;
const _buttonSize = 36.0;
const _buttonHit = 44.0;

/// The text of the field. The line is fixed (a strut), so the field's one-line
/// height is known at any text size and the round buttons can be centred on it.
const _fontSize = 15.5;
const _lineHeight = 1.4;

/// Asks for the keyboard now. Focus brings it up; a field that kept its focus
/// while the keyboard was dismissed needs the explicit request.
void _showKeyboard(FocusNode focus) {
  if (focus.hasFocus) {
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  } else {
    focus.requestFocus();
  }
}

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
/// it. An observed session (an agent in a terminal) has no queue and no
/// attachments: Stop takes the place of Send.
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

  @override
  Widget build(BuildContext context) =>
      SessionSelect<(AgentLink, AgentPhase, bool, String?, String?, SendDelivery, bool)>(
    session: session,
    select: (s) => (s.link, s.phase, s.state.cancelRequested, s.sendBlocked, s.relayNote, s.delivery, s.waitingOnBackground),
    builder: (context, snapshot) {
      final (link, phase, stopping, blocked, relay, delivery, waiting) = snapshot;
      final ds = context.ds;
      final live = link == AgentLink.live;
      final typing = live && blocked == null;
      final reason = composerReason(link);
      // Waiting on background work the turn is over: Send, not Stop (Stop
      // would end nothing, and an agent in a terminal still says `working`).
      final working = live && phase != AgentPhase.idle && relay == null && !waiting;
      final observed = session.isObserved;
      final queuing = working && !observed;
      final hint = reason ?? blocked ?? (relay != null ? '$relay…' : 'Message ${session.agentLabel}…');
      const none = InputBorder.none;
      // One line of the field is `inner` tall at any text size (the strut
      // below fixes the line). The field is a stadium of that height and the
      // round buttons sit the same distance from every edge, so its corner is
      // concentric with them (radius = disc radius + that distance).
      final line = MediaQuery.textScalerOf(context).scale(_fontSize) * _lineHeight;
      final inner = math.max(_minHeight - 2, 2 * 12.5 + line);
      final vpad = (inner - line) / 2;
      final vb = (inner - _buttonHit) / 2;
      final radius = (inner + 2) / 2;
      final inset = (inner + 2 - _buttonSize) / 2;
      final side = math.max(0.0, inset - 1 - (_buttonHit - _buttonSize) / 2);
      final field = Container(
        constraints: const BoxConstraints(minHeight: _minHeight),
        decoration: BoxDecoration(
          color: ds.surface,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: ds.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // An agent in a terminal takes text only. In the compact layout
            // the chips are gone, and the paperclip says how many go along.
            if (!observed)
              Padding(
                padding: EdgeInsets.fromLTRB(side, vb, side, vb),
                child: ListenableBuilder(
                  listenable: attachments,
                  builder: (context, _) {
                    void open() =>
                        unawaited(showAttachSheet(context, session: session, attachments: attachments));
                    return HideWhenCompact(
                      compact: _AttachButton(enabled: typing, count: attachments.items.length, onPressed: open, onWarm: attachments.warm),
                      child: _AttachButton(enabled: typing, onPressed: open, onWarm: attachments.warm),
                    );
                  },
                ),
              ),
            Expanded(
              // The keyboard takes ~300 ms to start moving once it is asked
              // for: ask when the finger lands, not when it lifts.
              child: Listener(
                onPointerDown: live ? (_) => _showKeyboard(focusNode) : null,
                child: ListenableBuilder(
                  // The hint says why Send waits while a picture or a file is
                  // still on its way.
                  listenable: attachments,
                  builder: (context, _) => TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: typing,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  keyboardType: TextInputType.multiline,
                  // Not onSubmitted: a send action given only that unfocuses
                  // the field and drops the keyboard after every message.
                  onEditingComplete: onSubmit,
                  strutStyle: const StrutStyle(fontSize: _fontSize, height: _lineHeight, forceStrutHeight: true),
                  style: Type.body.copyWith(fontSize: _fontSize, height: _lineHeight, color: live ? ds.text : ds.textMuted),
                  cursorColor: ds.accent,
                  decoration: InputDecoration(
                    hintText: reason ?? blocked ?? attachments.waitingReason ?? hint,
                    hintStyle: Type.body.copyWith(height: 1.4, color: ds.textMuted),
                    hintMaxLines: 1,
                    filled: false,
                    isDense: true,
                    // The strut fixes the line, so the field's one-line height is
                    // exactly `inner` at any text size and the buttons beside it
                    // are centred on it.
                    contentPadding: EdgeInsets.fromLTRB(observed ? Gap.lg : Gap.xs, vpad, Gap.sm, vpad),
                    border: none,
                    enabledBorder: none,
                    focusedBorder: none,
                    disabledBorder: none,
                    errorBorder: none,
                    focusedErrorBorder: none,
                  ),
                ),
                ),
              ),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([controller, attachments]),
              builder: (context, _) {
                final hasContent = controller.text.trim().isNotEmpty || !attachments.isEmpty;
                final (sendLabel, sendIcon) = switch (delivery) {
                  SendDelivery.queued => ('Queue', LucideIcons.listPlus),
                  SendDelivery.steered => ('Send to the running turn', LucideIcons.arrowUp),
                  SendDelivery.now => ('Send', LucideIcons.arrowUp),
                };
                return Padding(
                  padding: EdgeInsets.fromLTRB(side, vb, side, vb),
                  child: Row(
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
                        _RoundButton(
                          key: const ValueKey('send'),
                          label: sendLabel,
                          icon: sendIcon,
                          iconSize: 18,
                          ready: typing && hasContent && attachments.canSend,
                          onPressed: onSubmit,
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
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
                SessionChipsRow(session: session),
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
  Widget build(BuildContext context) => _RoundButton(
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

/// The paperclip at the field's left: the same soft disc as the round buttons
/// at its right, so both ends of the field weigh the same and sit the same 6 dp
/// inside the edge; 44 dp to touch. With [count] (the compact layout, which has
/// no chips) a small round badge says how many pictures and files go along.
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.enabled, required this.onPressed, this.onWarm, this.count = 0});

  final bool enabled;
  final VoidCallback onPressed;
  final VoidCallback? onWarm;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Listener(
      // A finger landing starts the library query and the first thumbnails, so
      // the sheet that opens a moment later finds them.
      onPointerDown: enabled ? (_) => onWarm?.call() : null,
      child: PressBuilder(
        onTap: enabled ? onPressed : null,
        scale: 0.92,
        semanticLabel: count == 0 ? 'Attach' : 'Attach, $count attached',
        builder: (context, pressed) => SizedBox.square(
          dimension: _buttonHit,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: Motion.standard,
                curve: Motion.easeOut,
                width: _buttonSize,
                height: _buttonSize,
                decoration: BoxDecoration(shape: BoxShape.circle, color: enabled && pressed ? ds.fillPressed : ds.fill),
                alignment: Alignment.center,
                // The clip's ink is heavier at its lower left, so a centred
                // glyph reads low; lift it a hair.
                child: Transform.translate(
                  offset: const Offset(0.5, -1),
                  child: Icon(
                    LucideIcons.paperclip,
                    size: 18,
                    color: !enabled ? ds.textTertiary : (pressed ? ds.text : ds.textSecondary),
                  ),
                ),
              ),
              if (count > 0)
                Positioned(
                  top: 2,
                  right: 0,
                  child: ExcludeSemantics(
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: ds.accent, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        '$count',
                        style: Type.caption.copyWith(color: ds.onAccent, fontSize: 10, height: 1.2, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.iconSize,
    required this.ready,
    required this.onPressed,
    this.busy = false,
    this.quiet = false,
  });

  final String label;
  final IconData icon;
  final double iconSize;
  final bool ready;
  final bool busy;

  /// A neutral fill instead of the accent: a secondary action beside the
  /// primary one.
  final bool quiet;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: ready ? onPressed : null,
      scale: 0.92,
      semanticLabel: label,
      builder: (context, pressed) => SizedBox.square(
        dimension: _buttonHit,
        child: Center(
          child: AnimatedContainer(
            duration: Motion.standard,
            curve: Motion.easeOut,
            width: _buttonSize,
            height: _buttonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ready
                  ? (quiet
                        ? (pressed ? ds.fillPressed : ds.fill)
                        : (pressed ? Color.alphaBlend(Colors.black.withValues(alpha: 0.12), ds.accent) : ds.accent))
                  : ds.fill,
            ),
            alignment: Alignment.center,
            child: busy
                ? const BusySpinner()
                : Icon(icon, size: iconSize, color: ready ? (quiet ? ds.text : ds.onAccent) : ds.textTertiary),
          ),
        ),
      ),
    );
  }
}
