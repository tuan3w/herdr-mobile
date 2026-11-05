import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'hold_confirm.dart';
import 'motion.dart';
import 'press.dart';
import 'spinner.dart';
import 'theme.dart';
import 'tokens.dart';

/// What marks an answer that asks for more than a tap.
enum AnswerRisk {
  /// No marker.
  none,

  /// A triangle: the answer is held (a standing grant, a risky command).
  gate,

  /// A quiet shield: the answer asks for less checking, without a hold.
  elevated,
}

/// Where an answer is in its life. The caller owns it: the chip never decides
/// that something was sent.
enum AnswerChipState {
  rest,

  /// The assistive first activation primed it: the next one (or a hold) sends.
  primed,

  /// The request is out: a spinner.
  sending,

  /// The answer was accepted.
  sent,

  /// It was not: a hold (or a tap) retries.
  failed,

  /// The pane asked something else: nothing was sent, and the chip takes no
  /// tap while it says so.
  changed,
}

enum AnswerChipTone {
  neutral,

  /// The answer stops or ends something: danger words, a danger wash at rest.
  danger,

  /// The answer declines (`3. No`): no fill at rest and secondary words, so
  /// it reads apart from the filled answers that allow, led by a small ✕ so
  /// it still reads as an answer to tap. Pressed, it fills like any chip.
  /// Why no fill: as one more identical fill, `No` looked like the
  /// `Yes, don't ask again` above it; with a fill and no mark it still did.
  quiet,
}

/// One answer to an agent: the option text exactly as the agent gave it, on a
/// chip that carries its own outcome, so the block around it never changes
/// size.
///
/// - [hold]: the answer goes out only when the finger stays down until the
///   fill ends ([HoldToConfirm], [onHeld]); a tap or an early release says
///   how ("Hold to send · why", [holdVerb] and [reason]). Assistive technology
///   cannot hold: its activation calls [onTap], which owns the two-step flow
///   (the caller primes, [AnswerChipState.primed], then sends).
/// - Without [hold] a tap calls [onTap].
/// - Haptics: the hold's own (intent, tick). `Haptics.sent` is the caller's,
///   once the answer was accepted.
/// - [wide] chips fill the width, 44 high; narrow ones hug their words and
///   sit at the end of a row inside a 44 touch box.
class AnswerChip extends StatelessWidget {
  const AnswerChip({
    super.key,
    required this.label,
    this.reason,
    this.detail,
    this.risk = AnswerRisk.none,
    this.state = AnswerChipState.rest,
    this.tone = AnswerChipTone.neutral,
    this.hold = false,
    this.holdVerb = 'Hold to send',
    this.enabled = true,
    this.wide = true,
    this.maxLines = 2,
    this.error,
    this.onTap,
    this.onHeld,
    this.semanticLabel,
  });

  /// The option text, verbatim.
  final String label;

  /// Why the answer is held (`pushes to a remote`), said after the hold words.
  final String? reason;

  /// A line under the label in every state (what a mode does, its risk).
  final String? detail;
  final AnswerRisk risk;
  final AnswerChipState state;
  final AnswerChipTone tone;
  final bool hold;

  /// What a hold does, said on a tap or an early release (`Hold to stop`).
  final String holdVerb;

  /// False while the answers are deaf (just appeared, another one is out):
  /// drawn dimmed, no taps.
  final bool enabled;
  final bool wide;
  final int maxLines;

  /// Why sending failed, for assistive technology.
  final String? error;
  final VoidCallback? onTap;
  final VoidCallback? onHeld;

  /// Replaces the chip's default description for assistive technology.
  final String? semanticLabel;

  /// A narrow chip paints this high inside its 44 touch box: it sits in a
  /// row's trailing slot next to a 56 high row's text.
  static const _narrowHeight = 36.0;

  /// A narrow chip is at least this wide, so `Stop` and `Stopping…` do not
  /// change the row's width.
  static const _narrowMinWidth = 104.0;

  bool get _held => hold && onHeld != null && state != AnswerChipState.sending && state != AnswerChipState.sent;

  bool get _takesTaps => enabled && state != AnswerChipState.changed;

  String get _holdText => reason == null ? holdVerb : '$holdVerb · $reason';

  String? get _semantic =>
      semanticLabel ??
      switch (state) {
        AnswerChipState.primed => reason == null ? 'Confirm: $label' : 'Confirm: $label, $reason',
        AnswerChipState.sent => 'Sent: $label',
        AnswerChipState.failed => 'Couldn’t send $label${error == null ? '' : ': $error'}. Retry',
        AnswerChipState.changed => 'The question changed. Nothing was sent',
        AnswerChipState.rest when hold =>
          reason == null
              ? '$label, needs holding or a second activation'
              : '$label, needs holding or a second activation: $reason',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final tap = _takesTaps ? onTap : null;
    if (!_held) {
      return PressBuilder(
        onTap: tap,
        scale: PressScale.panel,
        button: true,
        minTapSize: kMinTap,
        semanticLabel: _semantic,
        builder: (context, pressed) => _body(context, pressed: pressed),
      );
    }
    return HoldToConfirm(
      enabled: _takesTaps,
      semanticLabel: _semantic,
      scale: PressScale.panel,
      onActivate: onTap ?? () {},
      onConfirmed: onHeld!,
      builder: (context, hold) => _body(context, pressed: hold.holding, hold: hold),
    );
  }

  Widget _body(BuildContext context, {required bool pressed, HoldState? hold}) {
    final ds = context.ds;
    final danger = tone == AnswerChipTone.danger;
    final quiet = tone == AnswerChipTone.quiet;
    final showsHold = hold?.showsHold ?? false;
    final (bg, pressedBg, fg, edge) = switch (state) {
      AnswerChipState.primed => (ds.wash(ds.danger), ds.washPressed(ds.danger), ds.dangerText, ds.armedEdge(ds.danger)),
      AnswerChipState.sent => (ds.wash(ds.done), ds.wash(ds.done), ds.text, null),
      AnswerChipState.failed => (ds.wash(ds.danger), ds.washPressed(ds.danger), ds.dangerText, null),
      AnswerChipState.changed => (ds.blockedWash, ds.blockedWash, ds.blockedText, null),
      _ when danger => (ds.wash(ds.danger), ds.washPressed(ds.danger), ds.dangerText, null),
      _ when quiet => (Colors.transparent, ds.fill, ds.textSecondary, null),
      _ => (ds.fill, ds.fillPressed, ds.text, null),
    };
    final shown = showsHold
        ? _holdText
        : switch (state) {
            AnswerChipState.primed => reason == null ? 'Hold or tap again' : 'Hold or tap again · $reason',
            AnswerChipState.sent => 'Sent: $label',
            // A gated answer still needs a hold to go out again: the words say so.
            AnswerChipState.failed => this.hold ? 'Couldn’t send · Hold to retry' : 'Couldn’t send · Retry',
            AnswerChipState.changed => 'The question changed',
            _ => label,
          };
    // Chips that are not the answer in flight step back while the answers are
    // deaf; the one saying the question changed is read, so it stays clear.
    final live =
        enabled ||
        state == AnswerChipState.sending ||
        state == AnswerChipState.sent ||
        state == AnswerChipState.changed;
    final color = live ? fg : ds.textMuted;
    final lead = switch (state) {
      AnswerChipState.sending => const BusySpinner(size: IconSize.inline),
      AnswerChipState.sent => Icon(LucideIcons.check, size: IconSize.row, color: ds.done),
      // Primed is caution before acting; failed is a failure (docs/DESIGN.md, icons).
      AnswerChipState.primed => Icon(LucideIcons.triangleAlert, size: IconSize.row, color: fg),
      AnswerChipState.failed => Icon(LucideIcons.circleAlert, size: IconSize.row, color: fg),
      AnswerChipState.changed => Icon(LucideIcons.refreshCw, size: IconSize.row, color: fg),
      // Inline-sized, inside the one-line 44 a card reserves per chip.
      AnswerChipState.rest when quiet => Icon(LucideIcons.x, size: IconSize.inline, color: color),
      AnswerChipState.rest => null,
    };
    // A resting hint that the answer asks for more; red is for the chip that is
    // actually primed. A held answer says "Hold" at rest: a triangle alone did
    // not tell the person that a tap would not send.
    final markColor = danger ? ds.dangerText : ds.textSecondary;
    final marker = state != AnswerChipState.rest
        ? null
        : switch (risk) {
            AnswerRisk.gate when this.hold => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Hold', style: Type.caption.copyWith(color: markColor)),
                const SizedBox(width: Gap.xs),
                Icon(LucideIcons.triangleAlert, size: IconSize.inline, color: markColor),
              ],
            ),
            AnswerRisk.gate => Icon(LucideIcons.triangleAlert, size: IconSize.inline, color: markColor),
            AnswerRisk.elevated => Icon(LucideIcons.shieldHalf, size: IconSize.inline, color: ds.textSecondary),
            AnswerRisk.none => null,
          };
    final detail = (this.detail ?? '').isEmpty ? null : this.detail;
    final words = Text(
      shown,
      maxLines: wide ? maxLines : 1,
      overflow: TextOverflow.ellipsis,
      style: (wide ? Type.answer : Type.labelStrong).copyWith(color: color),
    );
    final Widget content;
    if (wide) {
      content = Padding(
        // The padding sits on the content, not the chip: the fill, a layer
        // between the chip's colour and its words, covers the whole chip. A
        // one-line chip centres in its 44 instead (a card reserves exactly
        // that per chip, at any text size).
        padding: EdgeInsets.symmetric(horizontal: Gap.md, vertical: maxLines == 1 ? 0 : Gap.sm),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: Gap.sm)],
            Expanded(
              // The detail (what a mode does, its risk) stays in every state:
              // the chip keeps its height under the finger and the warning
              // stays readable while confirming.
              child: detail == null
                  ? words
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        words,
                        Text(detail, style: Type.secondary.copyWith(color: danger ? ds.dangerText : ds.textSecondary)),
                      ],
                    ),
            ),
            if (marker != null) ...[const SizedBox(width: Gap.sm), marker],
          ],
        ),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (lead != null) ...[lead, const SizedBox(width: Gap.sm)],
              Flexible(child: words),
            ],
          ),
        ),
      );
    }
    final chip = AnimatedContainer(
      duration: Motion.pressing(pressed),
      curve: Motion.easeOut,
      constraints: wide
          ? const BoxConstraints(minHeight: kMinTap)
          : const BoxConstraints(minWidth: _narrowMinWidth, minHeight: _narrowHeight),
      decoration: BoxDecoration(
        color: pressed && enabled ? pressedBg : bg,
        borderRadius: BorderRadius.circular(Radii.sm),
        // Always a border, clear unless primed: a border pads the box, and a
        // primed chip must not grow under the finger.
        border: Border.all(color: edge ?? Colors.transparent),
      ),
      child: hold == null ? content : Stack(fit: StackFit.passthrough, children: [hold.fill, content]),
    );
    if (wide) return chip;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
      child: Align(widthFactor: 1, heightFactor: 1, child: chip),
    );
  }
}
