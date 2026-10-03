import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/pane_preview.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'quick_reply_controller.dart';

/// The one-tap answers to a blocked agent's prompt, full-width and 44 high,
/// each labelled with its own option text.
///
/// Feedback lives ON the chip you tapped, so the block never changes size:
/// a risky option (`needsConfirm`) turns into "Tap again to confirm"; while the
/// request is in flight it shows a spinner; afterwards it says "Sent: 1. Yes"
/// in green (the others dim, so a second answer cannot slip out); a failure
/// says so on that chip and a tap retries it.
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
  });

  final PromptInfo prompt;

  /// Owns the send state the chips draw; a tap goes to [onChoose], which the
  /// owner routes to `controller.choose` (it may add bookkeeping around it).
  final QuickReplyController controller;
  final Future<void> Function(QuickReply reply) onChoose;

  /// "N more…" opens the sheet, where every option shows. Cards only.
  final VoidCallback? onMore;
  final bool fixedHeight;

  /// Chips a card shows (a "more" chip takes the last place when there are
  /// more options than this).
  static const cardLimit = 5;

  static const _gap = 6.0;
  static const _chip = kMinTap;

  /// Chips drawn on a card for [prompt] (the "more" chip counts as one).
  static int count(PromptInfo prompt) =>
      prompt.replies.length <= cardLimit ? prompt.replies.length : cardLimit;

  /// Height of a card's chip block with [n] chips.
  static double heightFor(int n) => n == 0 ? 0 : n * _chip + (n - 1) * _gap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _chips(context, controller),
      );

  Widget _chips(BuildContext context, QuickReplyController c) {
    final phase = c.phase;
    final overflow = fixedHeight && prompt.replies.length > cardLimit;
    final shown = overflow ? prompt.replies.sublist(0, cardLimit - 1) : prompt.replies;
    final hidden = prompt.replies.length - shown.length;
    // While a request is out or answered, only its own chip is live.
    final locked = phase == ReplyPhase.sending || phase == ReplyPhase.sent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, r) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: _gap),
          _ReplyChip(
            reply: r,
            state: _stateOf(c, phase, r),
            error: c.error,
            enabled: !locked,
            oneLine: fixedHeight,
            onTap: () => onChoose(r),
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
      _ => _ChipState.normal,
    };
  }
}

enum _ChipState { normal, confirming, sending, sent, failed, more }

class _ReplyChip extends StatelessWidget {
  const _ReplyChip({
    required this.reply,
    required this.state,
    required this.enabled,
    required this.oneLine,
    required this.onTap,
    this.error,
  });

  final QuickReply reply;
  final _ChipState state;
  final bool enabled;
  final bool oneLine;
  final VoidCallback onTap;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final risky = reply.needsConfirm;
    final (bg, pressedBg, fg, border, label, semantic) = switch (state) {
      _ChipState.confirming => (
          ds.danger.withValues(alpha: 0.14),
          ds.danger.withValues(alpha: 0.24),
          ds.dangerText,
          ds.danger.withValues(alpha: 0.55),
          'Tap again to confirm',
          'Confirm: ${reply.label}',
        ),
      _ChipState.sent => (
          ds.done.withValues(alpha: 0.14),
          ds.done.withValues(alpha: 0.14),
          ds.text,
          null,
          'Sent: ${reply.label}',
          'Sent: ${reply.label}',
        ),
      _ChipState.failed => (
          ds.danger.withValues(alpha: 0.12),
          ds.danger.withValues(alpha: 0.22),
          ds.dangerText,
          null,
          'Couldn’t send · tap to retry',
          'Couldn’t send ${reply.label}${error == null ? '' : ': $error'}. Retry',
        ),
      _ChipState.more => (ds.fill, ds.fillPressed, ds.accentText, null, reply.label, null),
      _ => (ds.fill, ds.fillPressed, ds.text, null, reply.label, null),
    };
    // Chips that are not the subject of a request in flight / sent step back.
    final live = enabled || state == _ChipState.sending || state == _ChipState.sent;
    return PressBuilder(
      onTap: enabled ? onTap : null,
      scale: 0.985,
      button: true,
      semanticLabel: semantic,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: kMinTap),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: pressed && enabled ? pressedBg : bg,
          borderRadius: BorderRadius.circular(10),
          border: border == null ? null : Border.all(color: border),
        ),
        child: Row(
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
            ],
            Expanded(
              child: Text(
                label,
                maxLines: oneLine ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: Type.label.copyWith(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: live ? fg : ds.textMuted,
                ),
              ),
            ),
            if (state == _ChipState.more)
              Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary)
            else if (risky && state == _ChipState.normal)
              Icon(LucideIcons.triangleAlert, size: 15, color: ds.dangerText),
          ],
        ),
      ),
    );
  }
}
