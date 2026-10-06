---
name: herdr-motion
description: How herdr-mobile moves and feels (Flutter). Covers whether something should animate at all, the Motion tokens, springs and gestures, interruption, reduced motion, haptics and the frame budget on a mid-range phone. Use it whenever you add or change an animation, transition, AnimatedX widget, AnimationController, Ticker, gesture (drag, swipe, pinch, sheet, scroll-to), haptic or scroll behaviour. Also use it when asked to make something feel better, smoother or more alive, to audit the motion, to find where motion belongs, or to name a motion effect, even if nobody says "animation". Use herdr-design for what a screen should do; herdr-motion covers how it should feel.
---

# Motion and feel in herdr-mobile

People open this app many times a day for a few seconds at a time, often while
an agent streams output underneath. Motion here has one job: help the person
follow what changed or feel that their touch landed. Anything else is noise,
it costs battery, and on a mid-range phone it costs frames. That is why the app
is quiet: **nothing moves at rest**, and most changes are simply instant.

The bar comes from Emil Kowalski's design engineering and Apple's *Designing
Fluid Interfaces*, translated to Flutter and made stricter by what was measured
on a Galaxy A51. The source of truth for values is `app/lib/ui/core/motion.dart`
and `docs/DESIGN.md` (principle 7, "Micro-interactions", "Busy spinner",
"Working agent glyph"). Phone-specific facts (keyboard, frame budget) are in
`docs/ENGINEERING.md`.

## 1. Should it animate at all?

Answer this first. Often the answer is no, and then you write no motion code.

| How often the person sees it | Decision | Examples here |
| --- | --- | --- |
| Continuously, or driven by the agent rather than the person | Never animate. At most one settle when it changes on screen | status updates, streaming text, board refresh, elapsed-time labels |
| 100+ times a day, or from keys | No animation, or a short fade | key row, quick keys, typing, tab switch (`Motion.fade`) |
| Tens of times a day | Fast and subtle | press feedback, opening a pane, a sheet |
| Occasionally | Standard | toast, collapse, a card changing section |
| Rarely, and meaning something | Delight is allowed | `DrawCheck` after a connection test succeeds |

Then name the purpose in one word. If you can't, don't build it:

- **Feedback**: the touch landed (press scale, hold fill, haptic).
- **Continuity**: where something came from or went (sheet from the bottom, the gap a
  departing card leaves closing under the thumb: `AgentFolding`).
- **State change**: a change the person would otherwise miss (`StatusGlyph` settle, the
  arrival wash, `PopOnRise` on a rising count).
- **Preventing a jump**: content would teleport (`AnimatedSize` when a card's question
  appears).

Two rules about what the person is reading or touching:

- Data being read never moves for style, and the view never moves under a
  finger. A finger going down stops follow-scrolling and reveal pacing.
- Nothing appears or moves under the thumb and accepts a tap at once.
  `tapGuard` (450 ms) and `SettleGate` exist for that. Motion near a tap target
  must respect them.

## 2. Pick the cheapest tool that works

1. **No animation.** An instant state change, plus a haptic if the moment matters.
2. **`PressBuilder(scale:)`** for press feedback (~0.96 on small controls, none on rows).
3. **Implicit widgets** (`AnimatedScale`, `AnimatedSize`, `AnimatedSwitcher`,
   `AnimatedOpacity` only while dimmed) with `Motion` durations and `Motion.easeOut`.
4. **One-shot `AnimationController`** for a sequenced or drawn effect. Run it
   forward once, then let the ticker stop (`StatusGlyph`, `DrawCheck`, `PopOnRise`).
5. **Physics** (`SpringSimulation` via `controller.animateWith`) for anything a
   finger drives or can interrupt.

Never use `controller.repeat()` or any loop. The only exception is `BusySpinner`, and only
while the person waits on work they started; it disappears when the work ends.
A `Ticker` lives only while something moves (`KeyboardFrames` is the model:
it runs while `viewInsets` change and 120 ms after, then stops). Write a test
that the ticker stops.

## 3. Properties

- Animate transform and opacity. Layout animation (`AnimatedSize`) only for an
  element's own height change, never for a list per frame.
- No `Opacity`, `AnimatedOpacity` or `FadeTransition` left at 1: each one is a
  composited layer. Wrap only while actually dimmed or fading.
- No `BackdropFilter` blur: a full-screen blur pass per frame is too
  expensive on mid-range GPUs.
- Nothing scales from below 0.9. Entrances start at 0.92 to 0.97 plus opacity.
- Put a `RepaintBoundary` around something that animates over a large still area.

## 4. Curves and durations come from `Motion`

`Motion` (`ui/core/motion.dart`) names each motion by its role: press and
release, fade, standard, expand, settle, sheet in and out, page, arrival. Read
the file for the current values. Pick the token by role, not by the number
you want.

The curve is `Motion.easeOut`, a strong ease-out. Never use ease-in on UI: it
delays the moment the person is watching. A raw `Cubic(...)` or an animation
`Duration(milliseconds:)` in `lib/ui` is a defect (timers are not animations).
If no token fits the role, add one to `motion.dart` and a line to
`docs/DESIGN.md`; don't inline a value. `docs/DESIGN.md` changes only for a
new token or a rule every screen follows, not for one screen's motion.

Keep UI motion under ~300 ms, and make it asymmetric: slow where the person
decides, fast where the system answers. A press goes in faster than it comes
out, a sheet closes faster than it opens, and a hold to confirm fills slowly and
linearly, then snaps back fast.

## 5. Springs and gestures (anything a finger touches)

The interface should feel like an object in the hand. These rules come from
Apple's fluid interfaces:

- **1:1 tracking.** Content stays glued to the finger, keeping the grab offset.
  Feedback is continuous during the drag, not only at the end.
- **Start from the live value.** Every animation starts at what is on screen now,
  never at the logical target. A finger landing mid-animation stops it where it
  is (`photo_stage.dart`).
- **Hand off velocity.** On release, pass the gesture's velocity into the
  `SpringSimulation` so dragging and animating have no seam.
- **Project momentum.** Choose the snap target from where a fling would stop,
  not from where the finger lifted (Apple's projection, in `sheet_frame.dart`
  and `photo_math.dart`). A quick flick is enough; it doesn't have to cross a
  distance threshold.
- **Rubber-band at edges.** Resist progressively and never hard-stop
  (`photo_math.dart`, `swipe_review.dart`).
- **Damping.** Critically damped by default (`ratio: 1` /
  `withDurationAndBounce(bounce: 0)`). Use a little bounce (ratio ~0.85 to 0.9,
  bounce ≤ 0.1) only when the gesture itself carried momentum. Snap to the end
  (`snapToEnd`, a small `Tolerance`) so a still element keeps no sub-pixel offset.
- **Disambiguate.** Press feedback waits for the scroll-intent delay
  (`PressBuilder`), so scrolling a list never flashes rows. Ignore a second finger
  once a one-finger drag has started. A horizontal swipe inside a vertical list
  must not steal vertical scrolls.
- Every gesture has a semantic alternative (a `Mark reviewed` action, a
  two-step prime-then-send for a hold).

Use the existing code as models: `swipe_review.dart` (swipe to act, with undo),
`sheet_frame.dart` (sheet snap points and projection), `photo_stage.dart`
(pinch, pan, double tap). `photo_math.dart` holds the pure arithmetic and its tests.

## 6. Interruption

Anything can be reversed mid-flight from its current value. Implicit widgets
retarget by themselves. Controllers use `animateTo` from `controller.value`, and
springs use the live position and velocity. Never lock input while a transition
plays. A toast that is leaving slides back in when it is replaced. It does not
restart.

## 7. Reduced motion ships with the animation

`Motion.reduced(context)` is true means: drop the movement and keep the
opacity and colour changes that help people follow. The page becomes a
`Motion.fade` cross-fade, sheets open with no animation (drag still works),
settle, pop and the folding gap are skipped, and scroll-to jumps. Streaming
reveals whole lines. Test the reduced path as well as the normal one.

## 8. Haptics are words

Use `Haptics` (`motion.dart`), never `HapticFeedback`. Each one means one thing:

| Call | Means |
| --- | --- |
| `tick` | a tap, selection or step (also an early release of a hold) |
| `hold` | a long press registered |
| `sent` | something went out (fire it when the request was accepted, not on the tap) |
| `armed` | a risky answer is primed or held; a new question arrived |
| `failed` | something failed or a guarded action was refused |

Fire the haptic on the causal event, in the same frame as the visual. Rare
haptics keep their meaning: don't add one to a frequent action beyond `tick`,
and rate-limit the ones events trigger (`ArrivalCue`: at most one per 2 s, none
in the first 3 s after a start or resume). A toast's kind fires its own haptic;
callers don't.

## 9. The frame budget is measured on a phone

A frame has 16.7 ms on a Galaxy A51-class phone while an agent streams
~140 KB per refresh. Desktop and `flutter test` timings say nothing about it.

- Nothing rebuilds a large subtree per frame. While the keyboard moves there is one
  relayout per frame and no rebuilds (`docs/ENGINEERING.md` "Keyboard").
- Streaming text updates one live row, never the list (`LiveMessageRow`,
  `RevealPacer`, `FrameFlush`).
- When feel or frames matter, check them on the phone: a profile build, real
  touch (`adb shell input swipe`), a controllable load, `./autoresearch.sh`
  (keyboard) and `./autoresearch-stream.sh` (streaming). If you could not, say
  which feel-checks remain.

## How to work

**Building motion.** Go through sections 1 to 8 in order, write the code, then
report in at most a few lines: the frequency tier and purpose (or why you
built nothing), the ingredients (tool, properties, token, spring), and what
needs a feel-check on the device. Don't offer options. Make the call and give
the reason in one line.

**Reviewing motion.** Default to flagging. Use one table:

| Before | After | Why |
| --- | --- | --- |
| `AnimatedOpacity(opacity: 1, ...)` around a resting row | no wrapper; fade only while dimmed | a composited layer per row at rest |
| `Curves.easeIn` on the sheet | `Motion.easeOut` | ease-in delays the moment the person is watching |

Cite `file:line`. Then give a verdict, **Block** or **Approve**. Block for: a loop, motion at rest,
motion on a key-driven or 100+/day action, a raw curve or duration, ease-in,
input locked during a transition, something that moves under the thumb and
takes a tap, or a reduced-motion path that is missing. Prefer fixes in this order: delete it,
reduce it, fix the token or curve, make it interruptible, move it to
transform or opacity, make it asymmetric, polish it.

**Auditing or finding opportunities.** Sweep `lib/ui` for `.repeat(`,
`AnimationController`, `Ticker`, `Duration(milliseconds`, `Curves.`, `Cubic(`,
`HapticFeedback`, `Opacity(`, `FadeTransition`, `BackdropFilter`, `AnimatedSize`,
`setState` in scroll and gesture callbacks. Look for jarring changes: content that
teleports, a section that pops, a sheet that doesn't follow the finger. Gate
every candidate through section 1. Cap suggestions at 5 to 7, ordered by
leverage, and list the candidates you rejected with the question that killed
them. "The motion here is already right" is a valid result. Respect decisions
that `docs/DESIGN.md` already documents.

**Naming an effect.** See `references/vocabulary.md`. For implementation
patterns with this app's exemplars, see `references/recipes.md`.

## Never ship

| Never | Instead |
| --- | --- |
| A looping or repeating animation | Still state; `BusySpinner` only while the person waits |
| Animation at rest or on agent-driven updates | One settle when it changes on screen, or nothing |
| `Curves.*`, raw `Cubic`, raw animation `Duration` in `lib/ui` | `Motion` tokens (add one if missing) |
| Ease-in on UI | `Motion.easeOut` |
| Scale from 0 | 0.92 to 0.97 plus opacity |
| Opacity widgets at 1, `BackdropFilter` | Wrap only while dimmed; no blur |
| A gesture that animates only on release, or from the target value | 1:1 tracking, live value, velocity handoff |
| `HapticFeedback.*` | `Haptics.*` |
| Motion without a reduced-motion path | `Motion.reduced(context)` |
| A ticker that never stops | Stop it when the motion ends; test it |
| A view that moves under a finger, or a tap target that moves and accepts taps at once | Freeze while touched; `tapGuard` |
| "It felt fine on the desktop" | A profile build on the phone |
