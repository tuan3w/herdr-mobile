# Motion recipes, with the app's own exemplars

Read the exemplar before you write a new one. Extend the pattern rather than
starting a second one. Every value comes from `Motion` (`ui/core/motion.dart`).
The numbers here describe the exemplars as they were written; the code is the
truth. If a file has moved, search for the symbol. If the pattern itself
changed, update this file.

## Press feedback

`PressBuilder(scale: 0.96, builder: (context, pressed) => ...)`. The tint or
scale goes in on pointer-down after the scroll-intent delay
(`Motion.press`, 100 ms) and comes out on release (`Motion.release`, 180 ms). A
drag away cancels it. Rows use a tint, not a scale. No ripple anywhere.

## Something appears or leaves in place (a pill, a badge, a chip)

`AnimatedOpacity` plus `AnimatedScale` (0.92 to 1) over `Motion.release`, with
`Motion.easeOut`. While it fades out it keeps its old words, so the text never
changes mid-fade. Exemplar: the jump pill in `ui/core/terminal_jump.dart`.
Remove the opacity wrapper once it is fully visible if it sits on a resting
screen.

## Expand and collapse

`Collapse` (`ui/core/rows.dart`) over `Motion.expand`. Collapsed content is
excluded from semantics, focus and hit testing. A card whose own content grows
(a question appears) uses `AnimatedSize` instead of snapping.

## Something leaves a list without the rest jumping

The departing item leaves a gap of its own height, and the gap closes over
`Motion.expand`, so the next item glides up under the thumb
(`AgentFolding`, `ui/features/agents/agents_grouping.dart`). Under reduced
motion the gap is skipped. Taps on items that moved are guarded (`SettleGate`,
`ui/core/tap_guard.dart`).

## A status changes on screen

Fade the old shape and draw the new one once over `Motion.settle`, then stop
the ticker. A glyph built with its status never animates (`StatusGlyph`,
`ui/core/glyphs.dart`). A card that changed section gets a wash that fades over
`Motion.arrival`: a highlight decaying, not a movement.

## A count that brings news rises

`PopOnRise` (`ui/core/pop.dart`): a 1.22 scale pop over `Motion.settle`, built
from a `TweenSequence` and created lazily on the first rise. Nothing happens
when the count falls or the widget first appears.

## One-time success

`DrawCheck` (`ui/core/draw_check.dart`): the check draws itself once in 320 ms.
Use it only for rare moments that mean something (today, a connection test that passed).

## Hold to confirm a risky action

`HoldToConfirm` (`ui/core/hold_confirm.dart`): an intent delay of 150 ms, then a
linear danger fill over 550 ms, and a snap back of 200 ms on an early release
(nothing is sent). Haptics: `armed` when the hold starts, `tick` on a tap or
early release, `sent` on completion. A plain tap shows the hint
(`Hold to send · <reason>`) for 2.4 s. Screen readers get prime-then-send.

## Swipe to act, with undo

`SwipeToReview` (`ui/features/agents/swipe_review.dart`): 1:1 tracking, a
quiet label revealed underneath, past the threshold or on a flick the row
slides out on a spring (`withDurationAndBounce`, 260 ms out; 380 ms with 0.1
bounce back), the action runs, and an Undo toast appears, coalesced by
`groupKey`. A rubber band at the end. `snapToEnd` with a `Tolerance` so the row
keeps no sub-pixel offset.

## A sheet the finger drives

App sheets go through `showAppSheet` (`ui/core/chrome.dart`): `sheetIn` /
`sheetOut`, and no animation under reduced motion (drag to dismiss still works).
For snap points the attach sheet's `SheetPosition`
(`ui/features/attach/sheet_frame.dart`) is the model: a spring with
`withDampingRatio(stiffness: 420, ratio: 0.88)`, a target picked from the
projected fling (`y + velocity * 0.25`), `animateWith(SpringSimulation(spring,
current, target, velocity))`, and content laid out once and moved with transforms.

## Pinch, pan and double-tap

`ui/features/photos/photo_stage.dart` and `photo_math.dart`: springs that
start from the live value, stop when a finger lands, rubber-band at the edges,
and pure arithmetic with pure tests. No `InteractiveViewer`, no timed tweens.

## Scroll to a place

Under 3 viewports away, animate over 220 ms with `Motion.easeOut`. Farther
than that, or under reduced motion, jump. Never animate a follow while new
content streams in, and never move the view while a finger is down.

## Streaming text

Text is paced by `RevealPacer`, driven by a `Ticker` that exists only while
text is held back. It snaps (shows everything) when the message ends, the app
resumes, a finger lands, the backlog passes 8 KB, Smooth text is off, or the
view is hidden. It has no fade and no caret. See `docs/ENGINEERING.md`
"Agent sessions (ACP)".

## Toasts

`showToast` (`ui/core/toast.dart`): one at a time, replaced in place, a slide of
16 dp plus a fade over `sheetIn` / `sheetOut`, fade only under reduced motion.
The kind picks the haptic. See `docs/DESIGN.md` "Toasts".

## A spring from scratch

```dart
final _controller = AnimationController.unbounded(vsync: this);
static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 400, ratio: 1);

void _settle(double target, double velocity) {
  _controller.animateWith(SpringSimulation(
    _spring, _controller.value, target, velocity,
    snapToEnd: true, tolerance: const Tolerance(distance: 0.2, velocity: 8),
  ));
}

void _onDragStart(DragStartDetails _) => _controller.stop(); // the finger wins
```

Use ratio 1 by default and ~0.88 after a flick. The velocity is the gesture's
release velocity, in the same units as the value.
