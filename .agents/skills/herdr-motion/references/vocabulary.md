# Motion vocabulary

Put the right name on a loosely described effect, so it can be asked for
precisely. Lead with the term, and contrast close alternatives when two compete.
The Flutter column shows how this app would build it. "Not here" marks effects
the app deliberately does not use.

## Entrances and exits

| Term | Meaning | Flutter / here |
| --- | --- | --- |
| Fade in / out | Appears or disappears by changing opacity | `AnimatedOpacity`; tab switch, `Motion.fade` |
| Slide in | Enters from off-screen | page push, toast (16 dp) |
| Scale in | Grows to full size, usually with a fade | jump pill, 0.92 to 1 |
| Pop in | Appears with a slight overshoot | `PopOnRise` on a rising count only |
| Reveal | Uncovered gradually by a clip or mask | `ClipRect` + `Align.heightFactor` (`Collapse`) |

## Sequencing and timing

| Term | Meaning | Flutter / here |
| --- | --- | --- |
| Tween / interpolation | In-between frames from a start to an end value | `Tween`, `TweenSequence` |
| Stagger | Items animate one after another with a small delay | not here: lists are live data |
| Orchestration | Several animations timed to feel like one | `Interval` curves on one controller |
| Duration / delay | How long, and how long before it starts | `Motion` tokens |
| Stepped animation | Moves in discrete steps | not here (the old turning glyph was removed) |

## Movement and transforms

| Term | Meaning | Flutter / here |
| --- | --- | --- |
| Translate | Move along X or Y | `Transform.translate`, `SlideTransition` |
| Scale | Bigger or smaller | `AnimatedScale`, `ScaleTransition` |
| Transform origin | The anchor a scale grows from | `alignment:` (`PopOnRise(alignment:)`) |
| Origin-aware | Grows out of its trigger, not its own centre | menus and popovers; sheets rise from the bottom |

## Transitions between states

| Term | Meaning | Flutter / here |
| --- | --- | --- |
| Crossfade | Old fades out while new fades in, in the same spot | `AnimatedSwitcher`; the page under reduced motion |
| Continuity transition | The before and after stay visibly connected | the folding gap (`AgentFolding`) |
| Morph | One shape turns into another | `StatusGlyph` settle |
| Shared element / hero | An element travels into its new place | `Hero`; photo thumbnails into the viewer |
| Layout animation | Size or position change animates instead of snapping | `AnimatedSize` |
| Accordion / collapse | A section expands and collapses its height | `Collapse` |
| Direction-aware | Forward goes one way, back the other | Cupertino page slide |

## Feedback and interaction

| Term | Meaning | Flutter / here |
| --- | --- | --- |
| Press / tap feedback | A small scale or tint while pressed | `PressBuilder` |
| Ripple | A circle spreads from the touch | not here (press, don't ripple) |
| Hold to confirm | A fill grows while held | `HoldToConfirm` |
| Swipe to dismiss / act | Drag something away to act on it | `SwipeToReview` |
| Rubber-banding | Resistance and snap-back past an edge | `photo_math.dart`, `swipe_review.dart` |
| Momentum / fling | Motion that carries the release velocity | `SpringSimulation` velocity |
| Projection | Choosing the rest point from where a fling would stop | `sheet_frame.dart` |
| Shake | A quick jitter for a rejected input | not here: a `failed` haptic and words |

## Easing and springs

| Term | Meaning | Flutter / here |
| --- | --- | --- |
| Ease-out | Starts fast, ends slow; the default for UI | `Motion.easeOut` |
| Ease-in | Starts slow; feels sluggish on UI | not here |
| Ease-in-out | Slow, fast, slow; for moving A to B on screen | not tokenised; ask before adding |
| Linear | Constant speed | the hold fill only |
| Spring | Physics instead of a fixed duration | `SpringDescription` |
| Damping ratio | 1 = no overshoot; lower = bouncier | `withDampingRatio(ratio:)` |
| Bounce | Overshoot and settle | `withDurationAndBounce(bounce:)`, ≤ 0.1 here |
| Interruptible | Can be redirected mid-flight from its current value | springs, implicit widgets |
| Velocity handoff | The animation continues at the finger's speed | `SpringSimulation(..., velocity)` |

## Ambient (the app avoids all of these)

Loop, pulse, float, shimmer or skeleton, marquee, idle animation, typewriter
caret. The one loop the app allows is `BusySpinner`, and only while the person waits.

## Performance words

| Term | Meaning |
| --- | --- |
| Jank | Visible stutter from missed frames |
| Frame budget | 16.7 ms at 60 Hz: build plus layout on the UI thread, then raster |
| Compositing layer | A separately composited subtree (`Opacity`, `RepaintBoundary`); cheap to move, costly when there are many |
| Relayout / rebuild | Work that runs per frame when an animation drives layout or `setState` |
| Raster time | GPU-thread time per frame; it was measured on the phone, not the desktop |
