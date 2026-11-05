# Motion recipes, with the app's own exemplars

Read the exemplar before you write a new one. Extend the pattern rather than
starting a second one. Every value comes from `Motion`, `Springs`, `PressScale`
and `Dwell` (`ui/core/motion.dart`).
The numbers here describe the exemplars as they were written; the code is the
truth. If a file has moved, search for the symbol. If the pattern itself
changed, update this file.

## Press feedback

`PressBuilder(scale: PressScale.chip, builder: (context, pressed) => ...)`. The tint or
scale goes in on pointer-down, at once (`Motion.press`, 100 ms; a scroll that
takes over cancels it) and comes out on release (`Motion.release`, 180 ms). A
drag away cancels it. Rows use a tint, not a scale. No ripple anywhere.

## Something appears or leaves in place (a pill, a badge, a chip)

`FloatingPill` (`ui/core/floating_pill.dart`): a fade plus a scale from
`Motion.enterScale` over `Motion.release`, with `Motion.easeOut` in and
`Motion.easeOutExit` out. While it fades out it keeps its old words, so the
text never changes mid-fade. Exemplars: the jump pill
(`ui/render/terminal/terminal_jump.dart`). Remove the
opacity wrapper once it is fully visible if it sits on a resting screen.
Something in the bottom stack (the batch bar, the attach action bar) uses
`BottomStackTransition` instead: a slide of `Motion.travel` plus a fade.

## Expand and collapse

`Collapse` (`ui/core/rows.dart`) over `Motion.expand`. Collapsed content is
excluded from semantics, focus and hit testing. A card whose own content grows
(a question appears) uses `AnimatedSize` instead of snapping.

## Something leaves a list without the rest jumping

The departing item leaves a gap of its own height, and the gap closes over
`Motion.expand`, so the next item glides up under the thumb
(`AgentFolding`, `ui/features/agents/agents_grouping.dart`). Under reduced
motion the gap is skipped. Taps on items that moved are guarded (`SettleGate`,
`ui/support/tap_guard.dart`, `Dwell.tapGuard`).

## A status changes on screen

Fade the old shape and draw the new one once over `Motion.settle`, then stop
the ticker. A glyph built with its status never animates (`StatusGlyph`,
`ui/core/glyphs.dart`). The glyph is the one mark of a status change: the
board's card is only ever the waiting agent in front, so it never changes
status in place (the arrival wash it had went with the Cards density).

## A count that changes

`RollText` (`ui/core/roll_text.dart`): only the changed digits move, by
`Motion.rollTravel` of the font size with a cross-fade over `Motion.settle`,
up when the count rises and down when it falls; nothing at rest and nothing
under reduced motion. A count badge (`CountBadge`, `ui/core/count_badge.dart`)
rolls its number the same way and arrives and leaves with a scale. Never for
elapsed time: it changes on its own, not because of news.

## One-time success

`DrawCheck` (`ui/core/draw_check.dart`): the check draws itself once over `Motion.draw`.
Use it only for rare moments that mean something (today, a connection test that passed).

## Hold to confirm a risky action

`HoldToConfirm` (`ui/core/hold_confirm.dart`): an intent delay of
`Dwell.holdIntent`, then a linear danger fill over `Motion.holdFill`, and a
snap back over `Motion.holdSnapBack` on an early release (nothing is sent).
Haptics: `armed` when the hold starts, `tick` on a tap or early release,
`sent` on completion. A plain tap shows the hint (`Hold to send · <reason>`)
for `Dwell.holdHint`. Screen readers get prime-then-send.

## Swipe to act, with undo

`SwipeToReview` (`ui/features/agents/swipe_review.dart`): 1:1 tracking, a
quiet label revealed underneath, past the threshold or on a flick the row
slides out on a spring (`Springs.out`; `Springs.recoil` to
bounce back), the action runs, and an Undo toast appears, coalesced by
`groupKey`. A rubber band at the end. `snapToEnd` with a `Springs` tolerance so the row
keeps no sub-pixel offset.

## A sheet the finger drives

App sheets go through `showAppSheet` (`ui/core/sheets.dart`): `sheetIn` /
`sheetOut` through `Motion.curved`, and no animation under reduced motion (drag
to dismiss still works). For snap points the attach sheet's `SheetPosition`
(`ui/features/attach/sheet_frame.dart`) is the model: `Springs.carry`, a
target picked from the projected fling (`y + velocity * Springs.projectSheet`),
`animateWith(SpringSimulation(spring,
current, target, velocity))`, and content laid out once and moved with transforms.

## Pinch, pan and double-tap

`ui/features/photos/photo_stage.dart` and `photo_math.dart`: springs that
start from the live value, stop when a finger lands, rubber-band at the edges,
and pure arithmetic with pure tests. No `InteractiveViewer`, no timed tweens.

## Scroll to a place

Under 3 viewports away, animate over `Motion.expand` with `Motion.easeOut`. Farther
than that, or under reduced motion, jump. Never animate a follow while new
content streams in, and never move the view while a finger is down.

## Streaming text

Text is paced by `RevealPacer`, driven by a `Ticker` that exists only while
text is held back. It snaps (shows everything) when the message ends, the app
resumes, a finger lands, the backlog passes 8 KB, Smooth text is off, or the
view is hidden. It has no fade and no caret. See `docs/ENGINEERING.md`
"Agent sessions (ACP)".

## Toasts

`showToast` (`ui/core/toast.dart`): one at a time on the inverse surface. It
rises from behind the bar under it (a clip, no fade) over `sheetIn` and goes
back the same way over `sheetOut`; fade only under reduced motion. Its clock
(`Dwell.toastShort` / `toastLong` / `toastAction`) starts once it is in place
and pauses under a finger; a sideways drag follows the finger and dismisses it
past a third. The same `groupKey` swaps the words in place; a different message
takes over while the old one leaves. The kind picks the haptic. See
`docs/DESIGN.md` "Toasts".

## A spring from scratch

```dart
final _controller = AnimationController.unbounded(vsync: this);

void _settle(double target, double velocity) {
  _controller.animateWith(SpringSimulation(
    Springs.settle, _controller.value, target, velocity,
    snapToEnd: true, tolerance: Springs.swipe,
  ));
}

void _onDragStart(DragStartDetails _) => _controller.stop(); // the finger wins
```

Use `Springs.settle` by default and `Springs.carry` after a flick. The velocity
is the gesture's release velocity, in the same units as the value.
