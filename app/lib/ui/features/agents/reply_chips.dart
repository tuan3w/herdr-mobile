import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/pane_preview.dart';
import '../../core/controls.dart';
import '../../core/hold_confirm.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'quick_reply_controller.dart';

/// The one-tap answers to a blocked agent's prompt, full-width and 44 high,
/// each labelled with its own option text.
///
/// Feedback lives ON the chip you pressed, so the block never changes size:
/// a risky option (`needsConfirm`) is held, not tapped: the chip fills left to
/// right while the finger stays down ("Hold to send · pushes to a remote", its
/// `risk`; "Hold to send" when none is known) and sends when the fill ends; a
/// tap or an early release sends nothing and says how to send. Assistive
/// technology cannot hold: its activation is the two-step flow (the first
/// primes the chip, "Hold or tap again · pushes to a remote", the second
/// sends). While the request is in flight a chip shows a spinner (the pane is
/// read again first, then the keys go); afterwards it says "Sent: 1. Yes" in
/// green (the others dim, so a second answer cannot slip out); a failure says
/// so on that chip and a hold retries it. When the pane turned out to ask
/// something else, nothing was sent: the new question is shown and the chip
/// under the thumb says "The question changed" for a moment, taking no tap.
/// Options without a gate send on a tap.
///
/// On a card ([fixedHeight]) every chip is one line, which makes the block's
/// height a function of the option count ([heightFor]); the card reserves it.
/// In the sheet chips wrap and all options show.
class ReplyChips extends StatelessWidget {
  const ReplyChips({
    super.key,
    required this.prompt,
    required this.controller,
    required this.onChoose,
    required this.onMore,
    this.fixedHeight = true,
    this.limit = cardLimit,
    this.guarded = false,
  });

  final PromptInfo prompt;

  /// Owns the send state the chips draw; a tap goes to [onChoose], which the
  /// owner routes to `controller.choose` (it may add bookkeeping around it).
  final QuickReplyController controller;
  final Future<void> Function(QuickReply reply) onChoose;

  /// "N more…" opens the sheet, where every option shows. Cards only.
  final VoidCallback? onMore;
  final bool fixedHeight;

  /// Chips a fixed-height block shows before the rest collapse into a "more"
  /// chip (which takes the last place).
  final int limit;

  /// The answers just appeared or just moved: they take no taps and are drawn
  /// dimmed until the person has had time to see them (see `tapGuard`).
  final bool guarded;

  /// Chips a card shows (a "more" chip takes the last place when there are
  /// more options than this).
  static const cardLimit = 5;

  static const _gap = 6.0;
  static const _chip = kMinTap;

  /// Chips drawn on a card for [prompt] (the "more" chip counts as one).
  static int count(PromptInfo prompt, {int limit = cardLimit}) =>
      prompt.replies.length <= limit ? prompt.replies.length : limit;

  /// Height of a card's chip block with [n] chips.
  static double heightFor(int n) => n == 0 ? 0 : n * _chip + (n - 1) * _gap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _chips(context, controller),
      );

  Widget _chips(BuildContext context, QuickReplyController c) {
    final phase = c.phase;
    final overflow = fixedHeight && prompt.replies.length > limit;
    final shown = overflow ? prompt.replies.sublist(0, limit - 1) : prompt.replies;
    final hidden = prompt.replies.length - shown.length;
    // While a request is out or answered, only its own chip is live.
    final locked = guarded || phase == ReplyPhase.sending || phase == ReplyPhase.sent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, r) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: _gap),
          _ReplyChip(
            // A hold belongs to the answer under the finger: a new prompt
            // brings new chips, which drops it.
            key: ValueKey((i, r)),
            reply: r,
            state: _stateOf(c, phase, r),
            error: c.error,
            enabled: !locked,
            oneLine: fixedHeight,
            onTap: () => onChoose(r),
            onHold: () {
              controller.confirmByHold(r);
              unawaited(onChoose(r));
            },
          ),
        ],
        if (overflow) ...[
          const SizedBox(height: _gap),
          _ReplyChip(
            reply: QuickReply(label: '$hidden more…', keys: const []),
            state: _ChipState.more,
            enabled: onMore != null && !locked,
            oneLine: true,
            onTap: onMore ?? () {},
          ),
        ],
      ],
    );
  }

  static _ChipState _stateOf(QuickReplyController c, ReplyPhase phase, QuickReply r) {
    if (c.confirming == r) return _ChipState.confirming;
    if (c.subject != r) return _ChipState.normal;
    return switch (phase) {
      ReplyPhase.sending => _ChipState.sending,
      ReplyPhase.sent => _ChipState.sent,
      ReplyPhase.failed => _ChipState.failed,
      ReplyPhase.changed => _ChipState.changed,
      _ => _ChipState.normal,
    };
  }
}

enum _ChipState { normal, confirming, sending, sent, failed, changed, more }

class _ReplyChip extends StatelessWidget {
  const _ReplyChip({
    super.key,
    required this.reply,
    required this.state,
    required this.enabled,
    required this.oneLine,
    required this.onTap,
    this.onHold,
    this.error,
  });

  final QuickReply reply;
  final _ChipState state;
  final bool enabled;
  final bool oneLine;

  /// A tap on an ungated chip; for a gated one, the assistive activation (the
  /// two-step flow).
  final VoidCallback onTap;

  /// A hold of a gated chip reached its end.
  final VoidCallback? onHold;
  final String? error;

  /// Sent and sending chips are answers already given; the rest of a gated
  /// option's life (resting, primed, failed) is held.
  bool get _held => onHold != null && reply.needsConfirm && state != _ChipState.sending && state != _ChipState.sent;

  /// The chip that says the question changed hides its option, so it takes no
  /// tap until it shows it again.
  bool get _takesTaps => enabled && state != _ChipState.changed;

  @override
  Widget build(BuildContext context) {
    if (!_held) {
      return PressBuilder(
        onTap: _takesTaps ? onTap : null,
        scale: 0.985,
        button: true,
        semanticLabel: _semantic(),
        builder: (context, pressed) => _body(context, pressed: pressed),
      );
    }
    return HoldToConfirm(
      enabled: _takesTaps,
      semanticLabel: _semantic(),
      onActivate: onTap,
      onConfirmed: onHold!,
      builder: (context, hold) => _body(context, pressed: hold.holding, hold: hold),
    );
  }

  String? _semantic() => switch (state) {
        _ChipState.confirming => reply.risk == null
            ? 'Confirm: ${reply.label}'
            : 'Confirm: ${reply.label}, ${reply.risk}',
        _ChipState.sent => 'Sent: ${reply.label}',
        _ChipState.failed => 'Couldn’t send ${reply.label}${error == null ? '' : ': $error'}. Retry',
        _ChipState.changed => 'The question changed. Nothing was sent',
        _ChipState.normal when reply.needsConfirm => reply.risk == null
            ? '${reply.label}, needs holding or a second activation'
            : '${reply.label}, needs holding or a second activation: ${reply.risk}',
        _ => null,
      };

  String get _holdText => reply.risk == null ? 'Hold to send' : 'Hold to send · ${reply.risk}';

  Widget _body(BuildContext context, {required bool pressed, HoldState? hold}) {
    final ds = context.ds;
    final risky = reply.needsConfirm;
    final showsHold = hold?.showsHold ?? false;
    final (bg, pressedBg, fg, border, label) = switch (state) {
      _ChipState.confirming => (
          ds.danger.withValues(alpha: 0.14),
          ds.danger.withValues(alpha: 0.24),
          ds.dangerText,
          ds.danger.withValues(alpha: 0.55),
          showsHold
              ? _holdText
              : reply.risk == null
                  ? 'Hold or tap again to confirm'
                  : 'Hold or tap again · ${reply.risk}',
        ),
      _ChipState.sent => (
          ds.done.withValues(alpha: 0.14),
          ds.done.withValues(alpha: 0.14),
          ds.text,
          null,
          'Sent: ${reply.label}',
        ),
      _ChipState.failed => (
          ds.danger.withValues(alpha: 0.12),
          ds.danger.withValues(alpha: 0.22),
          ds.dangerText,
          null,
          showsHold ? _holdText : (_held ? 'Couldn’t send · hold to retry' : 'Couldn’t send · tap to retry'),
        ),
      _ChipState.changed => (ds.blockedWash, ds.blockedWash, ds.blockedText, null, 'The question changed'),
      _ChipState.more => (ds.fill, ds.fillPressed, ds.accentText, null, reply.label),
      _ => (ds.fill, ds.fillPressed, ds.text, null, showsHold ? _holdText : reply.label),
    };
    // Chips that are not the subject of a request in flight / sent step back;
    // the one saying the question changed is read, so it stays clear.
    final live = enabled || state == _ChipState.sending || state == _ChipState.sent || state == _ChipState.changed;
    final row = Row(
      children: [
        if (state == _ChipState.sending) ...[
          const BusySpinner(size: 14),
          const SizedBox(width: 10),
        ] else if (state == _ChipState.sent) ...[
          Icon(LucideIcons.check, size: 16, color: ds.done),
          const SizedBox(width: 8),
        ] else if (state == _ChipState.confirming || state == _ChipState.failed) ...[
          Icon(LucideIcons.triangleAlert, size: 16, color: fg),
          const SizedBox(width: 8),
        ] else if (state == _ChipState.changed) ...[
          Icon(LucideIcons.refreshCw, size: 16, color: fg),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: oneLine ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: Type.answer.copyWith(color: live ? fg : ds.textMuted),
          ),
        ),
        if (state == _ChipState.more)
          Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary)
        else if (risky && state == _ChipState.normal)
          // A resting hint that a hold is coming; red is for the chip that is
          // actually primed.
          Icon(LucideIcons.triangleAlert, size: 15, color: ds.textSecondary),
      ],
    );
    // The padding sits on the content, not the chip: the fill, a layer between
    // the chip's colour and its words, covers the whole chip.
    final content = Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: row);
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
