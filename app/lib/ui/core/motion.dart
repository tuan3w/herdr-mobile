import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Motion tokens. UI motion stays under ~300ms and uses strong ease-out curves:
/// built-in curves are too weak, and ease-in delays the moment the user is
/// watching most closely.
abstract final class Motion {
  /// Entering / responding to input. Starts fast, settles gently.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// Press-down feedback: snap in.
  static const press = Duration(milliseconds: 100);

  /// Release: slightly slower than the press, so the response never feels abrupt.
  static const release = Duration(milliseconds: 180);

  /// Default for state changes (colour, size of small elements).
  static const standard = Duration(milliseconds: 200);

  /// Expanding/collapsing sections.
  static const expand = Duration(milliseconds: 220);

  /// A status glyph settling into a new status (a one-shot draw-in).
  static const settle = Duration(milliseconds: 240);

  /// How long the wash on a card that just changed section takes to fade. A
  /// fade-out of a highlight, not a movement: it may outlast a transition.
  static const arrival = Duration(milliseconds: 420);

  /// Honour the platform's reduced-motion setting: drop movement, keep
  /// colour/opacity changes.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Duration for a control's pressed/released colour and scale: snap in,
  /// ease out.
  static Duration pressing(bool down) => down ? press : release;

  /// Bottom sheet / tray open and close: the response snaps (out < in).
  static const sheetIn = Duration(milliseconds: 250);
  static const sheetOut = Duration(milliseconds: 190);

  /// Page push/pop (the Cupertino slide, shortened from the SDK's 500 ms).
  static const page = Duration(milliseconds: 260);

  /// An opacity-only change of what is on screen (a tab switch, and a page
  /// under reduced motion in place of the slide).
  static const fade = Duration(milliseconds: 120);
}

/// The app's haptic vocabulary, as `Motion` is its motion vocabulary. Five
/// meanings, each one feel; screens say what happened, never which motor
/// pattern. Android's `HapticFeedback` has few strengths, so they are kept for
/// distinct moments: a tick is common, everything else is rare enough to mean
/// something.
abstract final class Haptics {
  /// A tap, a selection, a step: the light click of choosing something.
  static void tick() => unawaited(HapticFeedback.selectionClick());

  /// A long press registered (pick, open actions): a firmer press.
  static void hold() => unawaited(HapticFeedback.mediumImpact());

  /// Something went out: an answer, a message, a key. Soft, once.
  static void sent() => unawaited(HapticFeedback.lightImpact());

  /// A risky answer is primed and waits for its confirmation.
  static void armed() => unawaited(HapticFeedback.mediumImpact());

  /// Something failed, or a guarded action was refused: the heaviest one, so
  /// it cannot be mistaken for a tap.
  static void failed() => unawaited(HapticFeedback.heavyImpact());
}
