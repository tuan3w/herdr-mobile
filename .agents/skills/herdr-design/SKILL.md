---
name: herdr-design
description: Design herdr-mobile from the person's side. Trace each journey (an agent needs me, glance, follow, steer, start, review, set up, something broke, away from the phone), question every step's purpose, find the best path, keep what delights, remove noise, and keep the app coherent as a whole. Use it for any product or UX decision in the app, such as a new feature or screen, a change to a flow, copy, what to show or hide, a request to make something better, simpler or feel right, a design or UX review, or planning work in lib/ui. Use it even when the request sounds purely visual or purely technical. Pair it with herdr-motion (how it moves) and herdr-screen-check (proving it in pixels).
---

# Designing herdr-mobile

Design here means **how it works for the person**, not how it looks. Start where the person
is, walk forward through what they see, understand and do, and judge every element by
whether it helps them. The look follows from that. `docs/DESIGN.md` records
the visual system and every screen's behaviour; this skill is how to decide
what those should be.

## Who it is for

A person runs coding agents on their machines and is somewhere else: on a
train, in a meeting, in the kitchen. They are a **supervisor, not a
pair-programmer**. They have seconds of attention and one hand free, the radio is flaky,
and the phone has a mid-range GPU. They read commands and want the truth, not
reassurance.

Whenever they pick up the phone, they ask, in this order:

1. **Does anything need me?** Which agent, what exactly it asks, and what happens if I say yes.
2. **Is everything alive and on track?** What is running, for how long, and whether anything is stuck.
3. **What did it do?** The outcome (files changed, failures, the answer), not the process.
4. **Steer it.** Correct, redirect, stop, or start new work.
5. **Can I trust it?** The agent's mode and permissions, and this app's view: is what I
   see live, stale, or a saved copy?

The app is excellent when each answer costs a glance and each action costs one
deliberate gesture. After that, the app lets them put the phone away. Anything
that answers none of the five questions is noise until proven otherwise.

## The method

Use it for a new feature, a change, or a review. Write the steps down; the
thinking you skip is where noise and dead ends come from.

### 1. Find the moment

Who is holding the phone, where, why they opened the app now, what they
already know (a notification's text, a haptic), and what they want to leave
with. How often does this happen: many times a day, or once ever? Say it in one
sentence:

> On the train, a notification says omp is waiting. I want to approve the
> safe thing, see that it went, and put the phone away.

### 2. Trace the journey end to end

Start at the trigger (a notification, a worry, a habit) and end when the
phone goes back in the pocket. Then cover the next time they open the app, too.
For each step, write down what they see, what they must understand, what they do, what the app does,
and what they know afterwards. Include the waits (network), the failures
(offline, stale, refused, host gone, permission denied) and the interruptions
(a call, the app backgrounded, the screen rotated).

Trace through the code, not memory: open the files, cite `file:line`, and
render the screens (herdr-screen-check). `references/journeys.md` maps the
journeys the app already has and the parts they share. Start there, then
verify, because the code moves on.

Ask of every step:

| Question | What you are looking for |
| --- | --- |
| **Purpose** | Which of the five questions does it serve? If none, it is a noise candidate. |
| **Necessity** | Can this step disappear? Default the answer, remember the last choice, fold it into the previous step, infer it from context. |
| **Cost** | Taps, reading, waiting, thinking, precision (small or far targets), risk. |
| **Truth** | Is what is shown true now? If it might not be, does it say so (stale, saved copy, offline)? |
| **Safety** | What is the worst a mistaken tap does here? Is the guard in proportion? |
| **Recovery** | If it fails, does the person know what happened and what to do, without losing what they typed? |

### 3. Find the best path

The best path has the fewest decisions with full understanding, not the fewest pixels.
These are the patterns this app has proven:

- **Bring the action to the information.** Answer from the board card, the
  notification or the dock. Don't make the person open a pane to say yes.
- **The default view is the outcome.** Process is one tap down, raw detail is a drill-down.
  A finished turn folds its log; the answer, what changed and the exceptions stay visible.
- **Say it once, where they look.** One state, one place, one mark. Don't stack an
  outline, a wash and a badge on the same fact.
- **Guards are proportional.**
  - Something cheap and reversible is a plain tap.
  - Something cheap that could be a slip gets a tap plus an Undo toast.
  - Something risky or irreversible, or a standing grant ("don't ask again"), is held.
  - A bulk action gets a confirm sheet built from live data, with the count in the button.
  - Never confirm the cheap; never let the irreversible be a single tap.
- **Show what is approved.** The command or path itself, whole or behind
  `Read all`, never inferred from scrollback. A rule-based risk hint is a hint,
  not the safeguard.
- **Nothing moves under the thumb and takes a tap.** New content that arrives
  under a finger is not tappable for a moment (`tapGuard`). The view never scrolls
  under a finger.
- **Instant, and honest about it.** Push the screen on the frame of the tap and
  ask the host inside it. Paint the last known state at once and mark it until
  it is fresh. A saved copy is never live and never answers anything.
- **Never a dead end.** Something unavailable stays, dimmed, with its reason. A
  failure says what happened and what to do next. Nothing disappears silently.
- **Keep their work.** Typed text survives a failed send, the app going to the background, and rotation.
- **Fit the hand.** Targets are 44 dp or more. Primary actions sit low, within thumb reach. The
  compact layout (landscape with the keyboard) keeps the composer reachable.
- **One of each.** One toast system, one sheet, one photo viewer, one attach
  sheet, one guard, one spinner. The same thing looks the same, sits in the same place, and
  answers to the same gesture everywhere.
- **Respect the battery and the radio.** A timer, subscription, poll or retry is
  a cost to the person. Each one stops when nobody looks, and follows the background
  profile.

### 4. Keep a ledger: noise and delight

Make two lists for the journey, and mark each item keep, remove or change, with a reason.

**Noise** is anything that doesn't answer one of the five questions:

- the same fact said twice (a second title, two "Copied" confirmations)
- decoration, chevrons that say nothing, motion at rest, spinners on a resting screen
- a confirmation for something cheap
- a notification nobody asked for
- an empty section header
- a raw id where a name exists
- a label for the obvious
- an option almost nobody needs, sitting on the main path

**Delight** here is mostly friction that vanished:

- answering without opening anything
- the next question gliding up under the thumb
- a thread that opens instantly where it was left
- `Marked 3 reviewed` with one Undo
- `sent` felt only when it really went
- a phone photo landing in the host's inbox

Add a few earned moments, rare and meaningful: the check that draws itself
after a connection test passes. Delight is what remains when the other things are
right; it is never confetti added on top. If a "delightful" idea adds motion or
noise to a frequent path, it is noise.

### 5. Check the whole app

No screen stands alone. Before deciding, check:

- **The same concept on every surface: build a parity table.** When a journey
  shows one thing in several places, make a table: one row per surface
  (for a waiting agent: board card, triage sheet, pane answer dock, session
  prompt dock, notification), and one column per property the person relies
  on:
  - what is shown (question, command, how much of it)
  - the guard against a stale tap
  - the hold on risky answers
  - the haptic
  - the confirmation
  - the failure path
  - the words

  Fill every cell from that surface's own code, not from the shared component it
  uses. Twins drift through a flag that defaults to off, an argument one caller
  never passes, or a copy that missed a fix, so the shared widget only proves
  that the capability exists, not that this surface turns it on. An empty or
  differing cell is a finding unless a reason is written down (in
  `docs/DESIGN.md` when it is a system rule, otherwise next to the code). Put
  the table in the plan.
- **Same object, same word.** Machine, workspace, tab, pane, agent, session,
  turn. Use the words the app already uses (see `references/journeys.md`).
- **Entry and exit.** Notifications, deep links, the board, tabs and the
  launcher all land somewhere coherent. Back goes where the person expects.
- **State that carries.** What survives a launch, a resume or a reconnect, and what deliberately doesn't.
- **Two patterns for one job.** Pick one and migrate every caller. Don't add a third.
- **The cost elsewhere.** A new timer or subscription changes the background profile. A new
  row type changes every list that holds it.

### 6. Write the plan, then prove it

Write the plan as a table:

| Step | Today | Problem (question, cost, risk) | Change | Where |
| --- | --- | --- | --- | --- |

Then:

- **Fix data correctness before polish.** Polish on missing or wrong data is decoration.
- **Build from `ui/core`.**
- **Prove it in pixels** with worst-case data (herdr-screen-check).
- **Decide motion** with herdr-motion.
- **Feel it on the phone.** If you couldn't check something, say so.
- **Update `docs/DESIGN.md` only when a system-level rule or token changes**: a
  new pattern, a token, a rule every screen follows. Say why next to what.
  Screen-level tweaks don't go in it.

## Words

The app speaks like the docs:

- **Plain, short, specific, sentence case.**
- **Outcome first, with numbers and units,** joined by a middle dot:
  `Hold to send · pushes to a remote`, `Quiet for 2m`, `Marked 3 reviewed`,
  `Interrupt 3 agents`, `Couldn't refresh · Retry`.
- **Name the thing, not the category.**
- **Say how to recover:** `This photo is 52 MB. The viewer opens photos up to 40 MB.`
- **No apology, exclamation or cuteness.**
- **Correct plurals, tabular figures.**
- **Honest tense:** a subagent `was running`, never `running`, once the link is gone.

## The surface (summary; `docs/DESIGN.md` is the source of truth)

The look is not Material. It is Notion-like paper in light and Linear-like ink in
dark: flat rows, hairlines instead of elevation, type for hierarchy, one accent,
status shown as a shape first (`StatusGlyph`), Lucide icons, press instead of ripple, and quiet motion.
Everything is built from `app/lib/ui/core/` (`tokens`, `controls`, `rows`,
`glyphs`, `chrome`, `status_panel`, `toast`, `motion`).

| Never | Instead |
| --- | --- |
| `Card`, `ListTile`, `AppBar`, `NavigationBar`, FAB, Material buttons, `AlertDialog`, `SnackBar`, `PopupMenuButton`, `SegmentedButton`, `ExpansionTile`, `InkWell`, `Icons.*` | `ui/core` equivalents, Lucide icons |
| A raw `Color`, hex or `Colors.*` in a widget | `context.ds` |
| `textTertiary` for text | `textSecondary` / `textMuted` (≥ 4.5:1); status words in `blockedText` / `dangerText` |
| `copyWith(fontSize:)` to land between styles | A `Type.*` token, or a new token |
| A touch target under 44 dp | `PressBuilder(minTapSize: kMinTap)` |
| Status shown only by colour | `StatusGlyph` shape plus colour |
| A second toast, sheet, viewer or guard system | The one in `ui/core` or `features/` |
| `semanticLabel` that repeats visible text | Leave it null; set it only for icon-only controls |
| A layout that jumps when an error appears | Reserved space (`LabeledField`) |

## Reviewing

For a code review (bugs, maintainability, and UX read from code) use herdr-review. This section is the findings format for a design review.

Default to flagging; approval is earned. Report:

1. The journeys touched, one line each: the moment, and the path today.
2. Findings, worst first:

| # | Severity | Journey step | What the person experiences | Why it matters | Change | file:line |
| --- | --- | --- | --- | --- | --- | --- |

   - **Broken:** wrong or unsafe, a dead end, or lost input.
   - **Friction:** extra steps, waits or reading.
   - **Noise:** answers none of the five questions.
   - **Inconsistent:** the same job done differently elsewhere.
   - **Polish:** small craft.

3. The noise and delight ledger.
4. Decisions for the owner: questions with more than one right answer, with your
   recommendation.
5. A verdict.

Respect decisions that `docs/DESIGN.md` documents with a reason. Reopen one
only with new evidence (a measurement, a real capture, a journey it breaks), and
say what the evidence is.

## Exploring alternatives

When the best path isn't clear, don't argue it in words: build it with
`herdr-prototype`. That skill reproduces the complaint on today's code, draws
2 or 3 genuinely different directions (each named by its axis: answer on the
card vs. in a sheet; denser vs. calmer) on the same realistic data, and ends
with one line on when each wins and what it costs, for the owner to choose.

## Going deeper

- `references/journeys.md` is the app as a whole: surfaces, the core journeys
  step by step, their shared parts and known seams. Read it before changing
  any flow.
- `references/foundations.md` holds the general principles behind all of this (Apple's
  design principles, feedback, wayfinding, typography, craft), translated for this app.
- `docs/DESIGN.md` is the system and each screen's settled behaviour.
