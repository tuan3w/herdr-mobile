import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Motion tokens. UI motion stays under ~300ms and uses one strong ease-out
/// curve (the same curve Telegram calls EASE_OUT_QUINT): built-in curves are
/// too weak, and ease-in delays the moment the person is watching. Exits run
/// the same curve forward ([curved], [easeOutExit]), so they start fast too;
/// Material 3 accelerates exits, herdr deliberately does not.
abstract final class Motion {
  /// Entering / responding to input. Starts fast, settles gently.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// [easeOut] for a value running backwards (an exit, a collapse): fast
  /// first, like the entrance. A plain reverse of [easeOut] would be ease-in.
  static final easeOutExit = easeOut.flipped;

  /// [parent] through [easeOut], and through [easeOutExit] when it reverses,
  /// continuing from where it is if it reverses mid-flight ([ExitCurvedAnimation]).
  /// Every curved animation that can run both ways uses this.
  static ExitCurvedAnimation curved(Animation<double> parent) => ExitCurvedAnimation(parent);

  /// Press-down feedback: snap in.
  static const press = Duration(milliseconds: 100);

  /// Release: slightly slower than the press, so the response never feels abrupt.
  static const release = Duration(milliseconds: 180);

  /// An opacity-only change of what is on screen (a tab switch, and a page
  /// under reduced motion in place of the slide).
  static const fade = Duration(milliseconds: 120);

  /// Default for state changes (colour, size of small elements).
  static const standard = Duration(milliseconds: 200);

  /// Expanding/collapsing sections, a scroll the app makes.
  static const expand = Duration(milliseconds: 220);

  /// A one-shot draw-in: a status glyph settling, a badge arriving, a number
  /// rolling.
  static const settle = Duration(milliseconds: 240);

  /// Bottom sheet, toast and floating bars, in and out (out < in).
  static const sheetIn = Duration(milliseconds: 250);
  static const sheetOut = Duration(milliseconds: 190);

  /// Page push/pop (the Cupertino slide, shortened from the SDK's 500 ms).
  static const page = Duration(milliseconds: 260);

  /// The check that draws itself after a connection test passes.
  static const draw = Duration(milliseconds: 320);

  /// The brand mark drawing itself on first run.
  static const brand = Duration(milliseconds: 420);

  /// A hold-to-confirm fills slowly and linearly, then snaps back fast.
  static const holdFill = Duration(milliseconds: 550);
  static const holdSnapBack = Duration(milliseconds: 200);

  /// How far a floating thing (a pill, a bar, a toast) travels as it enters.
  static const travel = 16.0;

  /// The scale an entering element starts from (never below 0.9).
  static const enterScale = 0.97;

  /// How far a changed number rolls, as a fraction of its font size.
  static const rollTravel = 0.3;

  /// Honour the platform's reduced-motion setting: drop movement, keep
  /// colour/opacity changes.
  static bool reduced(BuildContext context) => MediaQuery.disableAnimationsOf(context);

  /// [d], or nothing under reduced motion.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;

  /// Duration for a control's pressed/released colour and scale: snap in,
  /// ease out.
  static Duration pressing(bool down) => down ? press : release;
}

/// [Motion.easeOut] forward and [Motion.easeOutExit] in reverse, without the
/// jump a plain `CurvedAnimation(reverseCurve:)` makes when it turns round
/// mid-flight: it swaps curves at the same controller value, so a toast
/// replaced a third of the way in goes from ~0.8 shown to ~0.03. The exit
/// instead starts from what is on screen and runs the exit curve to zero.
class ExitCurvedAnimation extends Animation<double> with AnimationWithParentMixin<double> {
  ExitCurvedAnimation(this.parent);

  @override
  final Animation<double> parent;

  /// The parent's value when the current exit began, once read.
  double? _from;

  @override
  double get value {
    final p = parent.value;
    if (parent.status != AnimationStatus.reverse) {
      _from = null;
      return Motion.easeOut.transform(p);
    }
    final from = _from ??= p;
    if (from <= 0) return 0;
    return Motion.easeOut.transform(from) * Motion.easeOutExit.transform((p / from).clamp(0.0, 1.0));
  }

  /// Nothing to release (it holds no listener of its own); kept so it can
  /// stand in for the `CurvedAnimation` it replaces.
  void dispose() {}
}

/// How far a control shrinks under the finger, by its size: the bigger the
/// surface, the less it moves.
abstract final class PressScale {
  /// Wide surfaces: answer chips, strips, toasts' actions.
  static const panel = 0.985;

  /// Buttons and floating pills.
  static const button = 0.97;

  /// Chips.
  static const chip = 0.96;

  /// Round and icon-only controls, tiles in a grid.
  static const icon = 0.92;
}

/// Springs for anything a finger hands over (a drag released, a fling).
/// Critically damped unless the gesture carried momentum; then a little
/// bounce (ratio >= 0.85), never more.
abstract final class Springs {
  /// A sheet or a photo let go: carries the finger's speed and lands softly.
  static final carry = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.88);

  /// Back to rest with no overshoot (a drag cancelled, a double tap).
  static final settle = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 1);

  /// A swiped row that did not go far enough, coming back.
  static final recoil = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 380),
    bounce: 0.1,
  );

  /// A swiped row leaving.
  static final out = SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 260));

  /// When a spring counts as arrived, by what it moves.
  static const pixel = Tolerance(distance: 0.05, velocity: 1);
  static const scale = Tolerance(distance: 0.0005, velocity: 0.002);
  static const swipe = Tolerance(distance: 0.2, velocity: 8);

  /// Seconds of a fling's speed that carry on after the finger lifts, to pick
  /// where a sheet or a swiped card lands (Apple's projection).
  static const projectSheet = 0.25;
}

/// Timers, not animations: how long something waits or stays.
abstract final class Dwell {
  /// New content under a finger takes no tap for this long.
  static const tapGuard = Duration(milliseconds: 450);

  /// A press held this long is a hold (before it, a tap).
  static const holdIntent = Duration(milliseconds: 150);

  /// How long the "hold to …" hint stays after an early release.
  static const holdHint = Duration(milliseconds: 2400);

  /// A primed risky answer waits this long for its second tap.
  static const confirm = Duration(seconds: 4);

  /// A copy button shows its check this long.
  static const copied = Duration(milliseconds: 1600);

  /// A held key repeats after [keyRepeatDelay], then every [keyRepeatGap].
  static const keyRepeatDelay = Duration(milliseconds: 320);
  static const keyRepeatGap = Duration(milliseconds: 45);

  /// The keyboard counts as still once its inset has not moved for this long.
  static const keyboardQuiet = Duration(milliseconds: 120);

  /// A field that triggers a lookup waits for typing to pause this long.
  static const typingPause = Duration(milliseconds: 500);

  /// A spinner or a skeleton shows only for work that takes longer than this.
  static const spinnerDelay = Duration(milliseconds: 120);

  /// A page that changed its address without loading (a single-page app's
  /// route) has its `<title>` read again after this long: frameworks set the
  /// title after the route renders, so a read at the change is one route
  /// behind.
  static const titleSettle = Duration(milliseconds: 400);

  /// A toast stays: short words, longer words, and one with an action.
  static const toastShort = Duration(milliseconds: 1500);
  static const toastLong = Duration(milliseconds: 2750);
  static const toastAction = Duration(milliseconds: 5000);

  /// Clocks that count seconds (a turn's elapsed time, an auto-resolve countdown) step this often.
  static const second = Duration(seconds: 1);

  /// `Stopping…` waits this long for a stopped job to leave the running set before it says it could not confirm.
  static const stopConfirm = Duration(seconds: 12);

  /// While the app is hidden no frame comes, so a coalesced flush waits this long instead.
  static const hiddenFlush = Duration(milliseconds: 250);

  /// Elapsed-time labels at minute resolution are polled this often.
  static const minuteStep = Duration(seconds: 30);

  /// A deep link waits this long for its machine to connect before giving up.
  static const linkPatience = Duration(seconds: 8);

  /// A Stop the person tapped counts as theirs this long: a later, unrelated turn end is never taken for it.
  static const stopAsked = Duration(seconds: 20);

  /// The triage walk's `All clear` stays this long before the sheet leaves.
  static const allClear = Duration(milliseconds: 900);

  /// A sent answer's `Sent: …` stays this long before the walk moves on.
  static const sentRead = Duration(milliseconds: 700);

  /// A preconnect outlives a finger that lifted without opening by this much.
  static const preconnectLinger = Duration(milliseconds: 400);

  /// A sideways drag on an agent screen must show its intent to swipe to the
  /// next agent within this long of touching down (a selection drag starts
  /// at 500 ms); once recognised, the finger drives it with no time limit.
  static const swipeIntent = Duration(milliseconds: 450);

  /// A board answer's `Sent` and `Changed` states stay this long.
  static const answerSent = Duration(seconds: 3);
  static const answerChanged = Duration(milliseconds: 1500);

  /// A batch action's result toast stays this long: it may list what failed.
  static const batchResult = Duration(seconds: 6);

  /// A reopened app waits this long for the agent it was showing to be listed.
  static const resumePatience = Duration(seconds: 8);

  /// `ArrivalCue`: quiet this long after start, then at most one buzz per [arrivalSpacing].
  static const arrivalCalm = Duration(seconds: 3);
  static const arrivalSpacing = Duration(seconds: 2);

  /// Warming the transcript's plan does at most [planBudget] of work per [planGap], between frames.
  static const planBudget = Duration(milliseconds: 4);
  static const planGap = Duration(milliseconds: 2);

  /// A machine's list refresh after an action gives up after this long; events catch up later.
  static const refreshTimeout = Duration(seconds: 5);

  /// The pane's screen reads: at most one per [paneRead] while output streams, a
  /// deeper (scrollback) read at most per [paneDeepRead], back to the short read
  /// after [paneDeepRevert] of quiet, and a poll every [paneFallback] if events stop.
  static const paneRead = Duration(milliseconds: 120);
  static const paneDeepRead = Duration(milliseconds: 1500);
  static const paneDeepRevert = Duration(seconds: 2);
  static const paneFallback = Duration(seconds: 4);

  /// Waits one frame or so past an animation, so a measurement sees its end state.
  static const afterSettle = Duration(milliseconds: 30);

  /// An open file viewer stats its file this often to notice a change on disk.
  static const diskWatch = Duration(seconds: 15);

  /// A photo zoomed back out to fit keeps its sharp decode this long: zooming in again does not decode twice.
  static const photoSharp = Duration(seconds: 2);
}

/// The app's haptic vocabulary, as `Motion` is its motion vocabulary. Five
/// meanings, each one feel; screens say what happened, never which motor
/// pattern. Android's `HapticFeedback` has few strengths, so they are kept for
/// distinct moments: a tick is common, everything else is rare enough to mean
/// something. [hold] and [armed] share a motor: both say "something firm
/// happened under your finger".
abstract final class Haptics {
  /// A tap, a selection, a step: the light click of choosing something.
  static void tick() => unawaited(HapticFeedback.selectionClick());

  /// A long press registered (pick, open actions): a firmer press.
  static void hold() => unawaited(HapticFeedback.mediumImpact());

  /// Something went out: an answer, a message, a key. Soft, once, and only
  /// when it was accepted, never on the tap that asked for it.
  static void sent() => unawaited(HapticFeedback.lightImpact());

  /// A risky answer is primed and waits for its confirmation; a new question
  /// arrived (rate-limited by `ArrivalCue`, never fired by a widget's build).
  static void armed() => unawaited(HapticFeedback.mediumImpact());

  /// Something failed, or a guarded action was refused: the heaviest one, so
  /// it cannot be mistaken for a tap.
  static void failed() => unawaited(HapticFeedback.heavyImpact());
}
