import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/command_risk.dart' show standingPermission;
import '../../../data/repositories/prompt_detector.dart' show isNegativeReply;

import 'package:herdr_mobile/ui/core/kit.dart';

import 'quick_reply_controller.dart';

/// How a prompt's answers are grouped: the answers that allow first, then,
/// after a wider gap, the ones that decline ([isNegativeReply]), drawn quiet.
/// Why: as identical chips in the agent's order, `3. No` looked like
/// `2. Yes, don't ask again` one row above it, and the person reads the
/// fill, not the words, when the thumb is already moving.
///
/// On a card ([ReplyChips.fixedHeight]) a standing grant ("don't ask again",
/// "allow all edits", a mode that asks for less: `standingPermission`) is not
/// on the main path: it goes behind `N more…` into the reply sheet, where
/// every option shows and it is still held. Why: a permission that outlives
/// this answer is the one almost nobody should give from a glance.
@immutable
class ReplyLayout {
  const ReplyLayout._(this.allow, this.hidden, this.refuse);

  /// Groups [prompt]'s answers for a card with room for [limit] chips (the
  /// "more" chip counts as one), or for the sheet ([card] false), where
  /// every answer shows.
  factory ReplyLayout.of(PromptInfo prompt, {bool card = true, int limit = ReplyChips.cardLimit}) {
    final refuse = [
      for (final r in prompt.replies)
        if (isNegativeReply(r)) r,
    ];
    final allow = [
      for (final r in prompt.replies)
        if (!isNegativeReply(r)) r,
    ];
    if (!card) return ReplyLayout._(allow, 0, refuse);
    final main = [
      for (final r in allow)
        if (r.risk != standingPermission) r,
    ];
    final standing = allow.length - main.length;
    if (standing == 0 && allow.length + refuse.length <= limit) return ReplyLayout._(allow, 0, refuse);
    // The "more" chip takes one place. Declining stays on the card (it is
    // always safe), but leaves an allow its place when there is one.
    final room = math.max(limit - 1, 1);
    final refusals = math.min(refuse.length, main.isEmpty ? room : math.max(room - 1, 0));
    final allows = math.min(main.length, room - refusals);
    return ReplyLayout._(
      main.sublist(0, allows),
      prompt.replies.length - allows - refusals,
      refuse.sublist(0, refusals),
    );
  }

  /// The answers that allow, in the agent's order.
  final List<QuickReply> allow;

  /// Answers behind the "more" chip (0: no "more" chip).
  final int hidden;

  /// The answers that decline, in the agent's order, after the gap.
  final List<QuickReply> refuse;

  /// Chips in the allow group (the "more" chip is one of them).
  int get _upper => allow.length + (hidden > 0 ? 1 : 0);

  /// Chips drawn.
  int get count => _upper + refuse.length;

  /// Height of the block when every chip is one line (a card).
  double get height {
    double group(int n) => n == 0 ? 0 : n * kMinTap + (n - 1) * ReplyChips._gap;
    final between = _upper > 0 && refuse.isNotEmpty ? ReplyChips._groupGap : 0.0;
    return group(_upper) + between + group(refuse.length);
  }
}

/// The one-tap answers to a blocked agent's prompt, full-width and 44 high,
/// each labelled with its own option text, grouped by [ReplyLayout]: the
/// answers that allow, then the ones that decline, quiet (no fill at rest).
/// A label keeps the agent's number (`3. No`): it is the agent's words, and
/// with the groups reordered it still says which row of the terminal the
/// chip answers (the keys sent come from the option, not the label).
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
/// height a function of the layout ([heightFor]); the card reserves it.
/// In the sheet chips wrap and all options show, in the same groups.
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

  /// Chips a fixed-height block shows, the "more" chip included.
  final int limit;

  /// The answers just appeared or just moved: they take no taps and are drawn
  /// dimmed until the person has had time to see them (see `Dwell.tapGuard`).
  final bool guarded;

  /// Chips a card shows (a "more" chip takes one place when not every
  /// option fits or a standing grant is held back).
  static const cardLimit = 5;

  static const _gap = Gap.sm;

  /// Between the answers that allow and the ones that decline: wider than
  /// the gap between chips, so the two read as two groups.
  static const _groupGap = Gap.lg;

  /// Height of a card's chip block for [prompt]: every chip one line, the
  /// groups and their gap included.
  static double heightFor(PromptInfo prompt, {int limit = cardLimit}) => ReplyLayout.of(prompt, limit: limit).height;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: controller, builder: (context, _) => _chips(context, controller));

  Widget _chips(BuildContext context, QuickReplyController c) {
    final phase = c.phase;
    final layout = ReplyLayout.of(prompt, card: fixedHeight, limit: limit);
    // While a request is out or answered, only its own chip is live.
    final locked = guarded || phase == ReplyPhase.sending || phase == ReplyPhase.sent;
    var i = 0;
    Widget chip(QuickReply r, {required bool refuse}) => AnswerChip(
      // A hold belongs to the answer under the finger: a new prompt
      // brings new chips, which drops it.
      key: ValueKey((i++, r)),
      label: r.label,
      reason: r.risk,
      risk: r.needsConfirm ? AnswerRisk.gate : AnswerRisk.none,
      state: _stateOf(c, phase, r),
      tone: refuse ? AnswerChipTone.quiet : AnswerChipTone.neutral,
      hold: r.needsConfirm,
      error: c.error,
      enabled: !locked,
      maxLines: fixedHeight ? 1 : 2,
      onTap: () => onChoose(r),
      onHeld: () {
        controller.confirmByHold(r);
        unawaited(onChoose(r));
      },
    );
    final upper = [
      for (final r in layout.allow) chip(r, refuse: false),
      if (layout.hidden > 0)
        _MoreChip(label: '${layout.hidden} more…', onTap: onMore != null && !locked ? onMore : null),
    ];
    final lower = [for (final r in layout.refuse) chip(r, refuse: true)];
    List<Widget> spaced(List<Widget> group) => [
      for (final (j, w) in group.indexed) ...[if (j > 0) const SizedBox(height: _gap), w],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...spaced(upper),
        if (upper.isNotEmpty && lower.isNotEmpty) const SizedBox(height: _groupGap),
        ...spaced(lower),
      ],
    );
  }

  static AnswerChipState _stateOf(QuickReplyController c, ReplyPhase phase, QuickReply r) {
    if (c.confirming == r) return AnswerChipState.primed;
    if (c.subject != r) return AnswerChipState.rest;
    return switch (phase) {
      ReplyPhase.sending => AnswerChipState.sending,
      ReplyPhase.sent => AnswerChipState.sent,
      ReplyPhase.failed => AnswerChipState.failed,
      ReplyPhase.changed => AnswerChipState.changed,
      _ => AnswerChipState.rest,
    };
  }
}

/// `N more…`: opens the sheet, where every option shows.
class _MoreChip extends StatelessWidget {
  const _MoreChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: PressScale.panel,
      button: true,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: kMinTap),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: pressed && onTap != null ? ds.fillPressed : ds.fill,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.answer.copyWith(color: onTap != null ? ds.textSecondary : ds.textMuted),
              ),
            ),
            Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
          ],
        ),
      ),
    );
  }
}
