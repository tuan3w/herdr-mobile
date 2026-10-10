# Design language

herdr mobile is deliberately **not Material**. The reference points are Notion
mobile (warm paper, flat rows, bold page titles, soft tinted tiles and chips,
a floating bottom bar) and Linear mobile (near-black ink, a surface ladder,
hairlines, status as shape, one accent used sparingly).

## Principles

1. **Content is the interface.** No cards around list items: flat rows divided
   by hairlines. Containers (the terminal, status panels, sheets) are the
   exception.
2. **Type does the hierarchy.** Inter, size + weight + tracking as a set.
   Large bold page titles; sentence-case section labels, never letterspaced caps.
3. **One accent** (`Ds.accent`, lavender-blue). Colour otherwise means status.
4. **Status is a shape first**, colour second (`StatusGlyph`): needs you =
   filled with a bar, working = half full, done = check, idle = empty ring,
   unknown = dashed ring. Readable without colour.
5. **Hairlines, not elevation.** One physical pixel. The one shadow is
   `Ds.floatShadow`, for a surface that floats over content: the bottom bars
   (`FloatingBarPill`, the attach sheet's bars), the triage pill, toasts and the
   file viewer's `Changed on disk` pill. No backdrop blur (a full-screen blur
   pass per frame is too expensive on mid-range GPUs). Chrome bars clamp text
   at `kBarTextScale` (1.15).
6. **Press, don't ripple.** Feedback starts on pointer-down (after the scroll
   intent delay) and is a soft tint or a 0.92–0.98 scale. No ink splashes.
7. **Motion is quiet.** Under 300 ms (press 100 in / 180 out, state 200,
   sheet 250 in / 190 out, page 260), `Motion.easeOut`, transform and
   opacity only, interruptible, reduced-motion respected, nothing scales from
   below 0.9. An animation's duration and curve come from `Motion`; a raw
   `Cubic` or animation `Duration(milliseconds:)` in `ui/` is a defect (timers
   are not animations). Never a looping animation, with one exception:
   `BusySpinner` (below).
8. **Icons are Lucide** (thin line, 1.5 px), not Material icons. One object has
   one icon everywhere: an agent is `bot` (the Agents tab, subagents, the
   permission dock), a machine is `server`. The one drawn exception is the
   brand mark (below, "Brand mark").
9. **Everything is reachable.** Touch targets are at least 44 x 44 even where the
   painted shape is smaller; every control has one accessible name.
10. **Say it once; tint, don't outline.** A state is named in one place on a
    screen: a blocked card is an ordinary card (glyph, section, the orange
    question wash), not also outlined and washed orange; the triage pill is
    neutral with the glyph as its only colour. Controls are soft tints
    (`CircleButton`, `AppChip`), not rings. A gate marker at rest
    (the triangle on a risky answer) is neutral; red appears only on the chip
    that is actually asking to be confirmed.

## Tokens (`ui/core/tokens.dart`)

| | Paper (light) | Ink (dark) |
| --- | --- | --- |
| `bg` | `#FBFBFA` | `#0D0E10` |
| `surface` | `#FFFFFF` | `#16171A` |
| `fill` / `fillPressed` | `#F1F0EE` / `#E8E7E4` | `#1C1D21` / `#25262B` |
| `hairline` (dividers) | `#EAE9E6` | `#24262A` |
| `border` (input outline) | `#D3D1CC` | `#3A3D44` |
| `text` | `#37352F` | `#ECEDEF` |
| `textSecondary` | `#5F5E5A` | `#8D9098` |
| `textMuted` | `#6E6D69` | `#868993` |
| `textTertiary` (icons only) | `#8F8E8A` | `#6A6D75` |
| `accent` | `#5E6AD2` | `#5E6AD2` (text uses `accentText` `#4B57BE` / `#9AA3F2`) |
| blocked / working / done / danger (shapes) | `#CC5A1E` `#B07F00` `#258A53` `#D44C47` | `#F2994A` `#F2C94C` `#4CB782` `#EB5757` |
| `blockedText` / `dangerText` | `#AD4C14` / `#B5342F` | `#F2994A` / `#F26B6B` |

Spacing is a 4pt grid; page gutter is 20. Radii (`Radii`): tile 7, control 9,
row 10, answer chip and question wash 10 (`chip`), segmented track 11, panel 12,
empty-state tile 14, sheet 18, pills fully round. Rows are at least 56 high. A
blocked agent's question sits on `ds.blockedWash` everywhere (card, dock, sheet),
never a hand-mixed alpha.

### Three text tiers, and what each is for

| Tier | Use | Paper on bg / fill | Ink on bg / fill |
| --- | --- | --- | --- |
| `text` | titles, values | 11.8 / 10.8 | 16.5 / 14.4 |
| `textSecondary` | subtitles, field labels, unselected tab label, section labels | 6.3 / 5.7 | 6.1 / 5.3 |
| `textMuted` | meta lines (cwd, third lines), chip counts, helper text, placeholders | 5.0 / 4.6 | 5.5 / 4.8 |
| `textTertiary` | **icons, chevrons, status rings, decoration only** | 3.2 (not text) | 3.7 (not text) |

Text never uses `textTertiary`; it does not reach 4.5:1. Status in words uses
`blockedText` / `dangerText` (paper 5.3 / 5.8 on bg, 4.7 / 5.0 on their own 12%
tint; ink 8.7 / 6.5, 7.3 / 5.8 on tint). The status *shape* colours
(`blocked`, `working`, `done`, `danger`, `textTertiary` ring) reach 3:1 on `bg`
(paper 4.0 / 3.5 / 4.2 / 4.1 / 3.2, ink all above 3.7) and the mark drawn on a
filled glyph or badge is `ds.onStatus` (white on paper, `bg` on ink: at least
3.5 on paper fills and 7.7 on ink fills). The ratios were computed from the hex values above and
are asserted by `test/ui/core_controls_test.dart`; change a token and the test
tells you what broke. Stale (offline) data dims the whole row once; do not dim
its glyph as well.

Type (`Type.*`): `largeTitle` 32/700/-0.9, `title` 20/600, `barTitle` 16/600,
`row` 16/500, `body` 15, `compact` 14.5 (reading text in sheets, forms and
notices), `prompt` 14/500 (the question an agent asks), `answer` 14.5/600 (a
one-tap answer or panel button), `secondary` 13.5, `label` 13/500, `button`
15/600, `caption` 12/500. Do not `copyWith(fontSize:)` a style to land between
two of them; add a token if a role is missing. Counts use tabular figures.
Terminal text is JetBrains Mono (`monoFamily`).

## Components (`ui/core/`)

| File | Provides |
| --- | --- |
| `tokens.dart` | `Ds` (colours, via `context.ds`), `Gap`, `Radii`, `Type` |
| `theme.dart` | `AppTheme.light/dark`, `systemBars`, `TerminalColors`, `monoFamily`, the page transition (`Motion.page` slide, a `Motion.fade` cross-fade under reduced motion) |
| `glyphs.dart` | `StatusGlyph`, `LinkDot`, `IconTile`, status/link `color` (shapes), `textColor` (words) and `label` extensions |
| `brand_mark.dart` | `BrandGeometry` (the mark, on the 108-unit adaptive-icon canvas) and `BrandMark` (the icon tile that draws itself once) |
| `rows.dart` | `ListRow`, `SectionLabel`, `Collapse`, `Hairline`, `EmptyState`, `cwdTail` |
| `controls.dart` | `PressBuilder`, `AppButton`, `CircleButton`, `AppChip`, `Segmented`, `LabeledField`, `BusySpinner`, `kMinTap`, `kBarTextScale` |
| `chrome.dart` | `SliverLargeTitle`, `FloatingBar` (metrics, `clearance`), `FloatingBarSlot`, `FloatingBarPill`, `FloatingBarScrim`, `FloatingTabBar`, `AppRefresh`, `showAppSheet`, `showActionSheet`, `showConfirmSheet` |
| `status_panel.dart` | `StatusStrip` (one line), `StatusPanel` (multi-line), `StatusTint` |
| `form_sections.dart` | `FormSection`, `FormPanel`, `FormActionBar` (grouped fields on a surface panel and the sticky action bar used by the machine and new-agent-session forms) |
| `motion.dart` | easing/duration tokens, `Haptics` (the five haptic meanings) |
| `toast.dart` | `showToast` / `Toaster`, `ToastKind`, `ToastAction`, `ToastTiming`, `ToastShelf`, `ToastRouteObserver` (see Toasts) |

### Rows

`ListRow` text starts at 64 (gutter 20 + 32 leading column + 12 gap). A small
leading widget (a status glyph) is centred on the **title line**, not the block;
pass `leadingOnTitle: false` for a tall tile. Titles wrap to two lines
(`titleMaxLines`). Fold secondary facts into one subtitle line
(`claude · payments-api`) rather than stacking a third line. A row that simply
opens its target has no trailing chevron (every agent and pane row would carry
one); a chevron stays where it tells something: a folder against a file, a
drill-in from Settings. Chevrons are 16 (14 inline, in a breadcrumb or a
disclosure). Status is news, not decoration: a tool call in a session shows its
glyph only while it waits, runs, fails or was cancelled, never for a plain
success.

### Status strips and panels

`StatusStrip` is the default for a connection or state notice: ~48 high, tint,
`LinkDot` or glyph, the name, the state in a quieter tone, an optional compact
action. Stack several above a list without pushing it off screen. `StatusPanel`
is for states that need a sentence (an error message, a sign-in to approve);
both share `StatusTint` (12% tint, faint outline in the state colour).

### Blocked prompts

A blocked card shows the question and, under it, what the agent asks to run or
touch (`PromptInfo.subject`) in mono, three lines at most; the reply sheet shows
all of it. Answers are 44 high chips. A risky answer is held, not tapped: press
and hold (about 700 ms; a linear danger fill, label `Hold to send · pushes to a
remote`) sends it, an early release snaps the fill back and sends nothing, and a
plain tap only shows the same hint. A standing grant ("don't ask again",
"always allow") always needs the hold. TalkBack and switch users keep a two-step
path (the semantic tap primes, the next one sends). `HoldToConfirm`
(`ui/core/hold_confirm.dart`): `holdIntent` 150 ms, `holdFill` 550 ms,
`holdSnapBack` 200 ms, `holdHintWindow` 2.4 s; haptics `armed` at the start of
the hold, `tick` on a tap or early release, `sent` on completion. The reason
comes from the command, the question and the option, never from the
scrollback around them (`command_risk.dart`); it is a hint, and the command
stays visible.

Nothing moves or appears under the thumb and takes a tap at once. `tapGuard`
(450 ms, `ui/core/tap_guard.dart`) is the one guard: a permission request, a
question, the triage sheet's next agent and the session composer's Stop (which
takes Send's place) take no tap for that long, and their answers are dimmed
(`TapGuardState`). On the board, `SettleGate` closes the same way for every
card's answers when a card above the last answerable one came, went or was
re-ordered (a card appended below moves nothing). In the triage sheet an
answered agent stays in view with `Sent: ...` for 700 ms before the walk moves
on, the last answer shows `All clear` for 900 ms, and `esc` / `enter` move
through a menu without ever moving the walk. A new permission request or
question gives one `armed` haptic; a tap that lands inside a permission
request's guard gives a tick.

A board card's answers take no tap and are dimmed for `tapGuard` each time
its question changes (one arriving, a new one right after `Sent`, one found by
the re-read below) and each time the card changes height while it shows answers
(it grows as a question arrives, its title wraps): `TapGuardState` on the card,
re-armed on every layout that changed its size, checked in the chip and again
in the handler, alongside the board's `SettleGate`. Why: the chips are pinned to
the card's bottom, so a card that grows moves them, and a question that changes
in place puts a new answer exactly where the thumb was; the second tap of a
double tap on `1. Yes` used to answer the next question with its `1`.

An option chip never sends what the screen showed: the card, the reply sheet
and the pane dock read the pane again first (`PanePreviews.recheck`, one round
trip past the preview throttle) and send only if it still asks the question
the chip was drawn for (`promptDigest`, the notification buttons' check), with
the keys read now (the cursor may have moved). Otherwise nothing is sent, the
question asked now is shown at once on every surface, the chip under the
thumb says `The question changed` for 1.5 s (taking no tap, since it hides its
option) and the `failed` haptic plays. The chip shows its pressed state at
once and its spinner through the read and the send. Why: previews are read at
most every 1.5 s, so a question answered on the desktop could still be on the
phone, and its `1` would have answered whatever the agent asked next.

A card that stops waiting (answered, or answered elsewhere) goes to its new
section at once and leaves a gap of its own height that closes over
`Motion.expand` (`AgentFolding`), so the next question glides up under the
thumb instead of jumping by a whole card; reduced motion skips the gap.

### What needs you: one set

`AttentionSet` (`data/repositories/attention_set.dart`) is the one answer to
"does anything need me?". Every surface reads it: the Agents tab badge, the
triage pill and sheet, the board's Needs you and Done headers and their filter
chips, the Machines tab's chip, the arrival haptic and the notifier's `need
you` count. Why: each used to count for itself, and they disagreed (a badge of
3 beside a pill saying 1, a sheet saying `All clear` while a session waited, a
Machines chip counting offline panes).

- **Needs you** = terminal panes blocked on a live machine
  (`FleetAgent.needsYou`) plus agent sessions blocked on a permission or a
  question whose machine and link are live. **To review** = finished and not
  reviewed, same reachability. Something out of reach cannot be answered or
  marked, so it is not counted; where it is listed (the board, last known) the
  section header says `N offline` instead of a count that would include it.
- **Order**: longest waiting first, panes and sessions mixed (a wait whose
  start is unknown last), then machine and key. The board's Needs you section
  and the triage walk use this one order.
- **Computed once per change** of the fleet or the sessions, and listeners
  hear only when a key or the order changed. Why: the badge, the cue and the
  board each built and sorted every agent on every notify, three passes per
  change on the UI thread.
- **The badge is loud for needs you only.** It shows the needs-you count in
  the blocked colour; finished work is not in it (the pill's `· 2 to review`
  and the Done section carry that, quietly). Why: three finished agents read
  as three questions in the loud colour, and attention must be the only loud
  thing.
- **One board, one place per status.** Agent sessions sit in the same status
  sections as terminal agents (a session row in Needs you, Done, Working or
  Idle), so the status filter narrows them too. Why: a separate sessions
  section jumped above the terminal cards whenever a session started or
  stopped waiting, moving every answer under the thumb, and "what waits" had
  two places to look. A session row still only tells; it is answered in the
  session for now.
- **The triage sheet walks the set** (`showTriageSheet`): a terminal agent
  with its chips and composer, an agent session with what it asks
  (`blockedSummary`) and `Answer in the session`, which opens it over the
  sheet; the walk moves on when the person comes back. `All clear` only when
  the set is empty.
- **Machines tab**: a machine's chip is its share of the set; an offline
  machine has none (its row already says offline).
- **One agent, one row.** An agent that runs in a herdr pane and is followed
  through its log (`ObservedSessions`) is not an agent session on the board:
  observed sessions are made only when a screen opens one, and keepers run
  outside herdr panes, so the board never lists the same agent twice.

### One agent per screen

An agent screen shows one agent: a terminal pane's terminal (`PaneScreen`) or
its chat (an agent session, or an omp, Claude Code or Codex pane followed through its log). Every
way in opens it through `openAgent` (`agents/agent_navigation.dart`): the
board, notifications and links, the start forms, Duplicate, past sessions and
the agent screens themselves. An agent already in front in that view is left
as it is. Why: the pane used to have browser-style tabs, and they held
terminals only (an agent the app can read opens as a chat by default, agent sessions were
always pushed screens), so they were a second, partial list of agents beside
the board, with its own count and order. The board is the
one scan surface; an agent screen is for one agent.

- **A swipe goes to the next agent.** Inside an agent screen (over the
  terminal panel, or the chat's transcript) a quick sideways swipe shows the
  next agent in the board's order (swipe left; right for the previous one):
  its sections in turn, Needs you and Done longest waiting first, panes and
  sessions mixed as the board mixes them. The board's filter and collapsed
  sections are a way of looking, not an order, and are not applied. Why: fast
  switching without a second list, in the order that answers "does anything
  need me" first.
- **What counts as the swipe** (`AgentSwipeDetector`, `agent_swipe.dart`):
  one finger the whole time (a second one is a pinch), 64 dp sideways within
  450 ms of touching down, with under 40% as much vertical travel, and not a
  finger that first went more than 24 dp vertically (a scroll, for the rest
  of the touch). Why the numbers: a long-press selection starts at 500 ms, so
  a selection drag is never a swipe, and a scroll that drifts is not either.
- **What never triggers it.** A touch that starts within 24 dp of the
  screen's sides: the system back gestures live there. Anything under the
  finger that scrolled sideways during the touch (a code block, a table, a
  terminal wider than the screen with wrap off): that swipe is theirs, and a
  scrollable claims the drag before 64 dp. The detector listens to raw
  pointers and never joins the gesture arena, so scrolling, link taps,
  selection and pinch zoom behave exactly as without it.
- **The ends.** At either end of the order, or for an agent the board does
  not list, nothing moves and a `tick` says so. Why: the order does not wrap
  round, so the person feels where the list ends instead of landing back on
  the first agent without noticing.
- **Chat and Terminal are one agent's two views, switched from its menu.** An
  agent with both (a pane the app can follow through its log) has `Show terminal` in the
  chat's `Session options` and `Show chat` in the terminal's `Pane options`.
  It swaps the view in place, and the choice is remembered for that agent for
  the app run: the board and the swipe open it in that view after. Settings >
  `Open agents as` stays the default for an agent with no choice yet; a
  pane whose agent has no chat opens its terminal and offers no `Show chat`. A
  Claude Code or Codex pane that herdr reports no session for offers `Read as chat…`
  in its terminal's options, always (not only after a look for the log failed): it installs herdr's hook for that agent
  on the machine after one confirmation (`connect_chat.dart`), which makes
  the agent report its session.
  Why: the old `Terminal` action replaced the chat, and nothing in the
  terminal led back to it. It then became a
  two-icon toggle in every bar, 88 dp that the title needed, for something
  done a few times a day; the menu costs one more tap and gives the bar back.
- **Drafts are kept per agent** for the app run (`AgentScreens.keepDraft`),
  shared by the agent's chat and terminal. Why: a swipe and the view switch replace
  the screen, so what is typed must live outside it; with tabs, a draft in a
  hidden tab was lost past six live panes and closing a tab dropped it.
- **Back always goes to the board** (where the person came from). A swipe and
  the view switch replace the screen in front instead of pushing, and a
  notification or a link replaces the agent screen in front, if one is. Why:
  walking ten agents must not leave ten screens to back out of.
- **Motion.** A swipe replaces the route: the new screen slides a short way
  (0.2 of the width) and fades in over `Motion.standard`, from the side the
  finger came from, while the screen under it stays still (no parallax). The
  toggle only fades, over `Motion.fade`: the same agent, so nothing slides.
  Under reduced motion a swipe is that fade. At launch the screen is back at
  once (below, "What survives a launch"). Once in, the route is a page like
  any other: Back and the edge swipe use the page transition.

### Pane bar

One bar of about 56 dp: back, status glyph and title over `agent · machine`,
files, wrap, and `Pane options` (`⋯`). The options are the one way to the
pane's actions: `Show chat` (for an agent with both views), `Duplicate`, `Copy
title`, `Copy pane id <id>` (the raw id lives there, not in the bar). The title
is not a button, and nothing else hides behind it: no long press, no pull-down.
Where a blocked pane's prompt is
understood, the question and up to three answers plus `N more` dock above the
key row (`AnswerDock`). The dock is hidden in the compact and short layouts.

The answer dock also shows the command (`subject`) in mono, two lines, under a
one-line question.

The dock's answers take no tap and are dimmed for `tapGuard` each time the dock
appears (the pane turns blocked, its screen opens by a tap, a swipe or the
toggle, the link comes back)
and each time its question changes, a new question after `Sent` included
(`TapGuardState`, checked in the chip and again in the handler). Why: the dock
comes up right above the key row and the composer, so the thumb is already
there, pressing Enter or typing, when it arrives; without the guard that press
answered whatever question had just slid under it.

While the dock shows a question, a bare Enter does not reach the pane: the key
row's Enter and the keyboard's send on an empty composer press nothing, give a
tick and toast `Pick an answer above`. Why: in the agent's menu Enter accepts
the highlighted option, so it would answer past the dock's hold on a risky
option and past its guard. Arrows, Esc and a Ctrl/Alt Enter still go through
(deliberate moves in the menu), typed text still sends as a line, and with no
dock (compact or short layout, or a prompt the app does not understand) Enter
is left alone.

**Terminal jump pill** (`terminal_jump.dart`, in `TerminalView`). Away from the
newest row it is the round chevron (`Jump to latest`); when rows arrive after
the reader left (net rows added at the end, so rows the read window drops from
the top do not count, nor a redraw in place) it is a pill, `3 new lines`,
`99+ new` past 99, counted from zero each time they leave and reset on
reaching the end. A pane that turns blocked while they are away makes it
`Needs you` with the blocked glyph (one already blocked when they left is
not news; the dock shows it); that wins over the count. A tap fires `Haptics.tick`
and scrolls to the end: `Motion.easeOut` over 220 ms when under 3 viewports
away, an instant jump otherwise and under reduced motion. It comes and goes
with opacity and scale (0.92 to 1) and keeps its words while fading out.

**Live edge** (`live_edge.dart`, bottom of the terminal panel, inside the
outline). A 2 px rule: accent-tinted when the last read brought new output
(`PaneViewModel.streaming`), `hairline` when it found nothing new. While the
link is down or a read failed, the text dims to the closed-pane alpha (0.6)
and the rule is `danger` (read failed) or `textMuted` (link down only) with
a label `stale · 12s`, seconds since `PaneViewModel.lastRead` (then `1m`,
`1h`). One timer a second redraws that label, only while stale and on
screen; a live pane has no timer and no ticker. The
screen reader hears `Output is stale` once. A closed pane is dimmed, not stale.

### Agent session screen (ACP)

Slim bar like the pane bar (status glyph by phase, title over
`agent · machine · folder`, a tap on the title area opens the session
overview, `Session options`, which also holds `Show terminal` for a followed
pane's chat); plan header (`1 of 3` + the
current step); a virtualized transcript stuck to the bottom with Jump to
latest; the permission dock; the composer (send becomes stop while a turn
runs). The permission dock is a safety surface: the command is always visible
in mono, every string shown or risk-matched goes through `visibleText()`
(bidi and control characters become `‹U+202E›`), runs of blank lines fold into
`↵ N blank lines`, an overflowing command shows `More below · N lines` and a
scrollbar plus `Read all` (full text in a sheet), an unread long command makes
the first hold on Allow scroll to the end and prime it without sending (`Hold
to send · long command, read it all`), nothing is cut without saying `… N more characters`, and a new
request ignores taps for 450 ms (dimmed, no animation) so a tap meant for the
previous one cannot land on it. Links in agent text open the terminal link
sheet with the full URL.

The dock shows one request at a time: the first permission, else the first
question, with `N more waiting` under it. A question's answers typed so far are
kept outside its panel, per question and per session (`QuestionDraft`, keyed by
`PendingQuestion.draftId`, which an observed question keeps when a refused
answer re-issues it under a new id), and
dropped only once the live session no longer waits on it (answered or
withdrawn). Before, a permission arriving mid-answer took the dock, the
question's panel was disposed, and it came back blank: typed answers lost
silently. The same keeps them when the person leaves the screen or opens the
subagent that asked.

**Opening is instant, and honest about it** (`docs/AGENT_SESSIONS.md`, "The
saved copy and the pre-connect"). A finger going down on a board row starts the
attach (`preconnect_tap.dart`, raw pointer events, nothing claimed; sliding
past the touch slop or a cancel lets go). The screen paints the saved
transcript at once (the last window of the keeper's lines, folded again by the
same reducer) under the link strip's `Updating…` / `Showing the copy saved at
14:02. Nothing here can be answered.` instead of `Connecting…` and a blank
list; the keeper's replay then replaces it without a flicker. The copy is
named in every state but live (`Reconnecting…`, `Couldn’t connect`,
`Session ended`, before their reason), not only while connecting: a first
connect that failed on a flaky radio once left the copy reading as the live
session. A saved copy asks nothing: the permission dock
and the question form show nothing for it (`PromptDock` reads no request while
`cachedAsOf` is set), and the session ignores answers until the live attach
confirms a request. When the board says the session needs the person but the
request cannot be shown (a saved copy, or the link is not live), the dock
says so (`Needs you · Its request shows here once connected`) instead of
being silently empty. Opening a finished session reviews it only once what
is shown is the session as it is now (the live replay is whole, or an ended
session's own transcript), never from a saved copy or a list still
connecting: a copy may not hold the turn that finished, and a connect that
then failed once emptied To review unseen. That review says `Marked
reviewed` with the board's Undo (`markSessionReviewedWithUndo`); a turn that
ends while the person watches is seen quietly. After that Undo the screen
does not review it again while they stay (until a new turn starts), and the
session keeps a turn the keeper forgets on load as a review on this phone,
so the Undo holds past the next listing. The route's first frame plans only the last 8 turns of a
long thread (`plan_warmup.dart`); the older ones are made ready a few
milliseconds at a time once the route has stopped moving, then join above the
view without moving it.

**Typing while the agent works** (`queued_messages.dart`, `queued_hint.dart`,
`composer.dart`). The composer stays open. Before anything is sent, one quiet
line above the field says what will happen to the message
(`AgentSessionView.delivery`): `Will be queued until the turn ends` (omp, pi,
or anything already waits: the order is kept) or `Goes into the running turn`
(Claude Code, Codex); nothing when it would go out at once, and nothing for an
agent in a terminal. The send button never moves: it becomes Queue (a plain
send for the steering agents) and Stop is its own round, neutral button to its
left, drawn while a turn runs and deaf for `tapGuard` (450 ms) from the moment
it appears, so the tap that started the turn, or the second tap of a double
tap on Send/Queue, cannot cancel it (it cannot reach it either: a different
place). A terminal agent has no queue: Stop takes Send's place, primary. What
waits shows above the field as soft rows, oldest first, text cut to two lines
(through `visibleText()`), three at most and `N more queued` for the rest. A
tap opens a row in a sheet (edit, Save, Remove; it says `Already sent` when
the turn ended meanwhile; the edit is a sheet, not the field, so a draft in the
field is never overwritten and an edit keeps its place in the queue and its
attachments), the cross (44 dp) removes it. The queue goes out one message at
a time when the turn ends; after the person's own Stop it goes out as soon as
the turn has stopped, all of it as one message (text joined by a blank line, in
the order sent, then attachments), because stopping a turn is going on with
what was queued behind it. A failed turn, a turn stopped from elsewhere or a
refusal holds the messages: one line (quiet tone; the refusal itself is already
in the link strip) says why, with `Resume`. Steered messages just appear as the
user's row. Haptics: `sent` when the session took the message (sent, steered,
queued or held), `failed` when it did not or an attachment cannot be made; see
"Send haptics follow the outcome".

**Attachments** (`attach_*.dart`, the sheet is in `ui/features/attach/`, see
"Attach sheet" below). A paperclip (44 dp, bare icon) at the field's left opens
the attach sheet; what is picked becomes chips above the field. `prepareImage`
(engine codec, JPEG encoding in a worker isolate) runs while the chip says
`Preparing…` with the one spinner the app allows; a file of the phone is
uploaded to the host and its chip carries a progress ring. The message cannot
be sent until every chip is ready (button and keyboard) and the field's hint
says why (`Uploading report.pdf…`, `An upload failed: retry it or remove it`);
a failed upload keeps its chip with a `Retry` and the cross, which cancels an
upload in flight. Too large or unreadable: a plain toast and no chip. A host
file goes out as a `@path` resource link named relative to the folder, or as
embedded text when the agent takes it and the file is small UTF-8 text
(`prompt_content.dart`); a phone file as a resource link with its path in the
host's inbox (outside any repo). At most five; the sixth says so. Chips sit
above the field, scroll sideways, are 44 dp high with a 44 dp cross, show a
thumbnail (a gallery pick reuses the decoded grid thumbnail: same
`galleryThumbProvider`, same image-cache entry) or a file icon, the name and a
second line (`412 KB`, `Preparing…`, `Uploading 42% · 48 MB`, `Uploaded · 5 MB`,
`Text included`, `Sent as a path`, `Sent as a file · this agent takes no
images`). The compact layout (landscape with the keyboard up) hides the chips
with the hint, the mode chips, the quick phrases and the queue
(`HideWhenCompact`; a chip row would not leave the transcript a line), and the
paperclip then carries a round count badge: what will be sent is never hidden.
`@` at a word start does not open the picker (a literal `@` must stay
typeable).

**Signing in** (`auth_panel.dart`, `AgentSessionView.authNeeded`). A
`StatusPanel` in the link strip: `Sign in on the host`, the agent's own words,
the method names, the agent's login command when it sent one (mono, copyable),
a primary `Open a terminal on <machine>` that starts a plain shell workspace
in the session's folder (`SessionLauncher`, no command typed) and opens it,
and `Copy command` / `Try again` (a connection that failed for the login). The
phone runs no login and never says it worked: the next message sent clears the
panel, or the agent asks again. The panel scrolls inside 60% of the window and
goes in the compact layout. For a login only the Mac's Keychain holds (Claude
Code over SSH, `AuthNeeded.keychain`) the title is `<agent> needs a token`, the
methods are left out (another sign-in would end up in the Keychain again) and
the copyable command is `claude setup-token`.

**What a decision shows** (`permission_evidence_view.dart`).
Under the title, in order: the agent's last sentence before it asked (a quiet
quoted lead-in, two lines at most; absent when it said nothing), the command
box exactly as above, and the evidence the request carries, each in the same
quiet box (a few lines, scrollbar, `More below · N lines`, `Read all` into a
sheet; rows are built lazily past 8 and the box never grows past 150 / 96 dp
for a diff and 180 / 110 dp for a plan on a short screen, so the card stays
short and the dock inside its 80% share; the dock scrolls as one, the
evidence first and the answers after it): an edit as one diff box
(a header per file with its path and `+3 −1`, `new file +40`, `up to +300 −200`
when the count is an upper bound; changed lines with two lines of context,
`+ ` / `- ` prefixes besides the colour, spoken as `added:` / `removed:`; the
text of the diff goes through `visibleText()`; a file the diff does not
compare in full says so, `+N more files not shown`), and a plan as Markdown
(`PlanBox`: Claude `ExitPlanMode`, codex plan review, and omp's plan question,
whose first line stays the heading and whose plan is drawn below it; omp's is
only the first 12 lines, and says `First 12 lines of the plan`). The mono copy
of the `plan` field is not drawn twice: the command box stays only for what
else the call carries, and the risk rules still read all of it. A plan is not
a command, so the unread-long-command hold does not apply to it; every other
hold rule is unchanged. Evidence is worked out once per request (the panel is
keyed by it), never per frame; a path the diff already heads is not listed
again. Absent evidence draws nothing.

**Mode and model chips** (`session_chips_row.dart`). One row above the composer
(four chips rarely fit a phone's width, so the chips scroll sideways and `+N`
stays pinned at the right): `sessionChipsOf(state)` gives up to four
`AppChip`s (mode, model, effort, switches, then any other select) and `+N`.
A select opens the options sheet on that setting's choices
(`showSessionOptions(at: chip)`); a switch (`Fast`) flips in place, shown
selected with a check; `+N` opens the sheet. The `…` button keeps everything
else. The row takes no room when the agent offers nothing, takes no tap while
the session is not live, and goes with the quick phrases in the compact layout
(landscape with the keyboard). **Danger is persistent**: a `dangerous` mode
(`assessSessionMode`) is the first chip, in the danger tint (`AppChip.tint`: a
12% fill with the faint outline of a status strip, its words in `dangerText`)
with a triangle, and reads `Mode: Bypass Permissions, dangerous.` plus the
reason to a screen reader; an `elevated` mode is neutral with a quiet shield.
The bar says nothing more about the mode. When the agent changes the mode to a
dangerous one the transcript gets its note (once) and the phone one `armed`
haptic (`danger_announce.dart`, only the items that arrived since the last
look). **Entering danger is held.** The mode picker runs `assessMode` on
every choice: an elevated one carries the shield and its reason, a dangerous
one the triangle, its name and its reason in `dangerText`. A dangerous mode
other than the current one is a `HoldToConfirm` row (the dock's pattern: a tap
says `Hold to switch to Bypass Permissions`, a hold sets it; assistive
activation primes, then `Hold or tap again`), because one slip there turns
every later tool call into one nobody is asked about. Leaving it for a safer
mode, or an elevated one, stays a tap: it lowers no guard.

**Since you left.** `LastSeen` (loaded in `bootApp`, provided by `app.dart`)
is marked when the session screen closes and when the app goes to the
background (`paused` / `hidden`), only once the transcript is whole (the replay
finished, or an ended session that has items), so a session that never got its
history cannot overwrite where the person was. When that moment first comes,
`sinceLeft` is asked once and given to `TranscriptView(sinceLeft:)` for the
divider; the bar adds no line of its own. The bar's subtitle leaves the folder
out when it is the title (`sessionWhere`).

**The live row, pacing and follow.** The message
that is streaming in right now is one row, `LiveMessageRow`, that listens to
its own text (`LiveText`, announced once per frame) and nothing else in the
list is built for a chunk. What it shows is `LiveMessageModel`: the text
revealed so far, through `RevealPacer`, into `StreamingMd`. The model lives
with the transcript view, not the row, so scrolling away does not stop the text
or the count. The frames while text is held back come from a `Ticker` that runs
only then (never a loop). Snaps (everything pending shown at once, no
animation): the message ends, the app resumes, a finger goes down on the
transcript, the backlog passes 8 KB, Smooth text is off (Settings >
Look, `AppSettings.smoothText`, on by default) or the transcript is
hidden; reduced motion reveals whole lines. Text that is there when the row
first shows is history and is never paced. No fade, no caret.

The live row is not always the last row: a call that failed or was cancelled
breaks out of its fold below the answer, and text still arrives after Stop or
from a turn the agent started itself (the turn is then not live). So
`TranscriptPlan.liveRow` searches for it, and the view makes the model again
whenever the plan changes, also when the person opens a fold (a message that is
streaming but is not the answer sits in the log). Why: with the model missing,
the live row threw while building, and Flutter's release answer to that is a
gray box as tall as the list (`compactErrorView` now makes it one readable row
that names the error).

Follow: the end stays in view while the reader has not left it
(`_StickyPosition`, the correction happens in the layout pass), never while a
finger is down (it catches up when the last finger is up), with no animated
scroll. Away from the end, the round chevron (`Jump to latest`) becomes a pill
`N new` when blocks of the answer were finished since the reader left: a plain
count in tabular figures, a 44 dp target, announced `N new, jump to latest`.

**Turns** (`transcript_plan.dart`, `work_log_rows.dart`,
`changed_card.dart`, `status_line.dart`, `since_divider.dart`). The transcript is
a list of turns (`turnsOf`), and a turn is, in order: the person's message
(absent for activity with no message of the person's: autonomous work, what
follows a replay), the work log, the Changed card, the answer, and what breaks
out of the fold. The plan (`TranscriptPlan`) turns them into flat rows of one
lazy list, planned again from the first turn that changed (a turn nothing
touched is the same object, so a tool call that starts costs its turn; a
`debugRowBuilt` test keeps 200 steps from building 200 rows). The toggles
(`<turn>:log`, `<turn>:changed:all`, `<call>:group`, a tool's body) live with the
view, so they survive a row scrolling away.

- **The fold.** A finished turn shows its log as ONE line, `▸ Worked 42s · 3
  files · 4 commands · 1 failed` (`workSummaryParts`: counts, times and exit
  codes the app has; a part that is zero is left out; the duration is left out
  when the turn was replayed; `failed` is in `dangerText`; `Plan 3 of 3 done`
  when the plan finished in that turn). A small caret (a rotation), a 44 dp
  target; a tap opens the log in place and the rows it brings are revealed over
  `Motion.expand` (opacity and a few pixels of slide; closing just goes; reduced
  motion shows them at once). The turn that runs shows its log open, with no
  fold line; when it ends it folds. The list keeps the row at the start of its
  newer slivers by key, and the first built row keeps its place, so rows that
  appear or go above what the reader is looking at do not move it.
- **What breaks out of the fold.** A failed call (the agent said `failed`, or the
  command exited non-zero), a cancelled one, a call that waits for the
  person's permission, a stop row and a note are ordinary rows after the
  answer, never folded; in an open log they stand in their place, once.
- **The log's rows.** Tool calls are quiet rows (no chevron): the icon of the
  kind, ONE `toolSummary` line, ~44 dp, and a state shape only when the call
  has not succeeded (waiting ring, running half ring, failed cross,
  cancelled slash). Read: file name and its folder in `textMuted`. Edit: file
  name and `+a −b` (`addedText` 4.5:1 on the page and the fills in both
  themes, `dangerText`; shrinks rather than overflows). Command: the command in
  mono; failed, a second line with `exit 1` and the last line it printed.
  Search: the pattern and `4 matches` when the output says. Fetch: the host.
  Other: the title. The pressed fill is the only affordance; the input,
  output, locations and diff stay behind the tap. Opened, a file the call read,
  its input and its progress show their first 8 lines (`toolTextLines`, the
  same as a collapsed message), then `N more lines` / `Show all`: the file is
  behind its name and its path opens the file viewer, and a 40-line wall of it
  was mostly scrolled past. Command output keeps its last 40
  (`commandOutputLines`): its outcome is at the end and is read. The command
  keeps 12, a diff 60. The opened body hangs off a **fold rail** (`FoldRail`): a
  faint line under the call's icon, the body's full height, that folds the
  call on a tap anywhere along it and then brings the call's header back to
  the top if it had scrolled away, so a long output never has to be scrolled
  back up to close. It is the 24 dp indent that was already there, not 44 dp:
  it is aimed at along one axis only, and the 44 dp header still toggles; it is
  out of semantics (the header is the one toggle a screen reader needs).
  Adjacent calls that went well
  and are reads or searches are one line, `Read 3 files · searched 2×`, with a
  caret; a running, failed or waiting call never joins. Thoughts have no row
  of their own: one quiet `Thinking` line per stretch of the log (between two
  pieces of narration), which opens to the thoughts as Markdown. Narration (the
  agent's words before its last step) is Markdown at the size of the answer in
  the supporting colour (`MdTone.quote`), so a message that was the answer and
  becomes narration when a call starts after it changes colour and nothing
  else.
- **The Changed card** (finished turns only; absent when nothing changed).
  Rows of the list that share one quiet panel: `Changed · 3 files  +21 −4`, one
  row per file (name, folder, `new` / `deleted`, `+a −b`; 44 dp) and, past six
  files, `N more` (then `Show fewer`), so 300 files stay lazy. A tap opens the
  file's diff in place (the diff panel of the tool body, `DiffPanel`).
- **The status line** (`StatusLine`, after the last row, while a turn runs): what
  the agent does (`activityOf`: `Running flutter test`, the first sentence of
  the latest thought, `Working`) and `· 12s`, a clock that counts the step it
  names (a call, a thought) from when it began, `Working` from the instant of
  Send (`turnStartedAt`); a step with no known start has no clock. Stepping once
  a second (`StepClock`), no spinner, still at rest. After a minute without any
  event it adds `Quiet for 2m` below (`quietFor`, the honest stuck signal, in
  `text` at weight 600, no colour). Not shown while the agent waits for the
  person (the dock says that), gone when the turn ends; its line is always laid
  out, so the end of a turn slides nothing. The only liveness indicator.
- **The since-you-left divider.** `TranscriptView(sinceLeft:)`: a hairline with
  `N new` (`New` when no step is counted) above the first item the person has
  not seen, or above the fold line that holds it. It is taken ONCE, when the
  first value with a place arrives, and never moves; the view opens with it in
  sight: at the end when what follows it fits the screen, else with the divider
  near the top and the reader away from the end (the button leads back). A
  divider that arrives after the screen is open is placed and the view does not
  move.
- **The plan header** takes room only while the plan has steps to do, or when it
  changed in the turn that runs; a plan that finished in a turn is part of that
  turn's fold line.

**Subagents** (`subagent_format.dart`, `subagent_card.dart`,
`subagent_roster.dart`, `subagent_screen.dart`, `subagent_run_session.dart`). A call
that started subagents (`subagentsOfToolCall`) is drawn as their cards in the
work log, in place of its tool row (`toolOrSubagentRow`, the one branch in
`TranscriptView`); a child's own calls never reach the parent transcript (the
reducer keeps them out). A card is a quiet `fill` panel: the shape of its state
(`RunTone`: half ring running, empty ring not started or not updating, check
done, cross failed, slashed circle cancelled, the blocked glyph when a request
of its own waits), the run's description (two lines), and ONE live line made of
figures the app has: `running 42s · Grep · 7 tools` (omp adds `60%` and
`retrying 2 of 5`), `Waiting for you · 7 tools` in `blockedText`, `Explore ·
done · 31s · 12 tools`, `Explore · failed · 2s` in `dangerText` with the agent's
reason under it (the reducer's generic `The subagent failed` is not repeated),
`cancelled` in `textMuted`. The seconds step once a second from the shared
seconds clock (`secondsClock`), leased only while a card is running here and on
screen (`RunClock`); nothing animates, and a run whose link went away says `was
running`, never `running`. Parallel ones (calls that follow each other with
nothing between, or one omp `task` call with several) sit under one header,
`3 subagents · 2 running`. A failed or cancelled subagent keeps its call out of
the fold of a finished turn (`attentionToolIds`: the call may say `completed`).
A tap opens the card (the toggle is kept per session, `RunExpansion`, so it
survives scrolling away): what it was asked, what it handed back as quiet
Markdown (the first 3 000 characters), `Open conversation` (or `Open summary`)
and `Call details`, the tool call itself with its body. The bar chip
(`SubagentsChip`) counts `1 of 3 running`, `1 waiting for you` (tinted
`blockedText`) or `1 of 3 failed` and opens the roster sheet: Waiting (the
ones that need the person first, then the ones not started), Running,
Finished (failed first, newest first); each row is the same card, a tap opens
the run; the list is lazy past 8 lines (two thirds of the screen), so 25
subagents cost the ones on screen. An observed session keeps its own roster.

*Drill-in* is a pushed screen (`SubagentRunScreen`): a bar with the description,
a state strip with the same live line, then either the **conversation** (Claude:
the same `TranscriptView` over `SubagentRunSession`, an `AgentSessionView` over
the run that is read-only and marks the run's transcript as a turn in progress
while it runs; no fork of the transcript code) under the pinned prompt (`Asked
to`, three lines, a tap shows all, bounded to 40% of the screen), or the
**summary** (omp and Codex over ACP send no conversation): `Summary only.` once,
the figures it reported (model, tokens, cost, progress), what it was asked,
what it is doing, its recent output (mono, 5 lines of 300 characters at most),
the retry or note, why it stopped and its result. omp's run gets the
conversation too when its own log on the host can be read (best effort, SFTP,
AGENT_SESSIONS.md "omp subagent transcripts"): the same `TranscriptView`, with
one caption row under the pinned prompt (`LogOriginNote`: `From omp's log on the
host`, plus `Earlier part not shown` when a cap cut the start). While that first
read runs the summary has a `Loading…` line (`BusySpinner`); only a connection
failure shows `Couldn't read the log · Tap to retry` (44 dp row); a log that is
missing, unreadable, of an unknown version or not a conversation leaves the
summary untouched and silent. The screen asks for the log only while it is open
(`watchSubagentLog`). No composer. The request a
subagent asks is answered from the same dock, above which one quiet line says
`From subagent: Explore` (`OriginLine`; the hold rules are untouched, and the
lead-in sentence is taken from the subagent's own transcript, not the main
agent's); the run's own screen shows only its requests. Back returns to the
scroll position the person left.

**Session overview** (`session_overview.dart`,
`session_overview_model.dart`). A tap on the bar's title area, or `Session
overview` in the options sheet, opens a sheet (`showAppSheet`: it stops below
the status bar and scrolls when it is taller than the room). In order: the status in words and how long
(`Working · 4 min`), `Goal` (the first message, three lines), `Plan · 1 of 3
done` with a thin bar and the step in progress, `Changed · 12 files +310 −42`
(the files of every turn merged by path, eight, then `N more` in steps of 16;
a tap opens the file's diff in place with `ChangedFileRow` and `DiffPanel`),
`Commands · 14 · 2 failed` (five: the failed ones first, then the newest, mono,
`exit 1` in `dangerText` with a cross; a tap shows all of the command),
`Subagents` (one row into the roster), `Mode and model` (a dangerous mode in
the danger tint with its reason), `Context and cost` (a thin bar, `182k of 200k
tokens · 91% of context`, the cost with its currency, the last turn's tokens)
and `Waiting for you` (what asks, `From subagent: …`; a tap closes the sheet,
the dock is under it). A part the session has nothing for is absent, never a
placeholder. The transcript parts come from the per-turn summaries the folds
already compute (`overviewOf`, memoized per transcript list) and the sheet
rebuilds only when a list it reads is replaced, so a streaming answer costs it
nothing. **Context warning**: from 85% (`contextWarnAt`) the bar's subtitle
line adds `Context 91%` in `dangerText` (the words, at weight 600, next to the
place line, which gives way first); nothing below that and nothing without a
window size; the overview bar turns to the danger colour at the same point.

**Content the agents send** (`content_blocks.dart`
and the `content_*.dart` files). Every block that is not Markdown text goes
through `ContentBlockView`, in an agent message, in the person's own message
(`UserRow`) and in a tool call's output; every string through `visibleText()`.

- **Pictures** (`content_image.dart`). A block with base64 `data` shows an
  inline preview: its aspect, at most 220 dp high and as wide as the column,
  never more than twice its natural size (a 48 px icon stays an icon),
  `Radii.panel` with a hairline, and a tap (44 dp at least) opens the photo
  viewer (below) on that picture, among the thread's other pictures
  (`ThreadPhotos`, read at the tap; `photo_thread.dart`). While it
  decodes a quiet 120 x 96 box with the picture icon stands in (no spinner).
  A screen reader reads `Image, image/png, chart.png` (the name is the last part
  of the uri, when there is one). Data that cannot be drawn degrades to a line
  with the reason in plain words: `The picture data is not valid base64.`, `The
  picture is not an image this app can read (image/jpeg).`, `Too large to show
  here (14 MB).`, `The picture is empty (0 × 0).`, `The agent sent no picture
  data.` Over 12 MB decoded is refused before any decoding.
- **Memory.** Base64 longer than 64 KB is decoded in another isolate
  (`compute`); the bitmap is shrunk to 1024 px on its longest side while the
  codec decodes it, so the full bitmap never exists. Previews live in
  `ImagePreviewCache` keyed by block identity: eight are kept once nothing
  draws them, the least recently used is disposed first, and one a row is
  drawing is never disposed. A 200-picture transcript builds the rows near the
  screen, so it holds those plus eight, not 200 (test: `content_blocks_test.dart`).
  The viewer decodes its own copy (2048 px, the file viewer's cap) and disposes
  it with the screen.
- **Privacy: nothing is fetched.** A block with only a `uri` is a line, `Image ·
  tracker.example.com` (host only; the query string is for the sheet), and never
  a download, whatever the scheme. A tap on an `http`/`https` one shows the whole
  address in the link sheet (`AgentMdScope`); a `file:` uri on this machine or an
  absolute path (`/`, `~/`, `./`) opens the file viewer on the session's machine,
  which draws pictures, by the route a path in the Markdown takes (`MdActions`,
  asked only on the tap). Another scheme, a `file:` uri naming another host and a
  `data:` uri stay plain text. `HttpOverrides` in the test proves no request is made.
- **Links and embedded resources** (`content_resource.dart`). A `resource_link`
  (pi `/export`, codex `view_image`) is a tappable row, 44 dp at least, with
  the Lucide file icon by mime type then extension (a web address with neither
  is a link), its title / name / last segment, a mono hint (host, or the path)
  and the size; the description is a second line. Routing is the same as a
  picture's uri. An embedded text `resource` shows the same row and under it
  the first six lines in the quiet code panel (`CodePanel`, terminal palette)
  with `N more lines` / `Show all` and the copy button; whether it is open lives
  with the transcript (`allKey(rowKey)`), so it survives scrolling, and a message
  with two such panels opens both together. A blob stays a line with its size.
  Audio and unknown blocks keep their quiet line.
- **Locations** (`content_locations.dart`). The body of a tool call lists the
  files it touched as `path:line` rows (mono, 44 dp, link colour): the folder
  gives way (`…/deep/folder/`, `shortenFront`), the file name and the line never
  do short of a name wider than the screen. A tap opens the file viewer at the
  line. Four, then `+N more`. Without an `MdActions` above they are plain text.
- **Copying** (`content_copy.dart`). A long press on text belongs to
  `SelectionArea`. Tested with real gestures: a long-press handler on a row
  wins the gesture arena (the deeper recognizer is asked first) and the word is
  never selected, so a message is NOT copied by a long press of its own. The
  transcript's selection toolbar (`ContentSelectionArea`) carries the choice
  instead: after Copy come `Copy message` (what the person typed, or the answer
  without its Markdown marks) and, for an answer, `Copy as Markdown` (the source,
  byte for byte), for the message the finger went down on (`MessageCopyTracker`:
  a row notes its message on pointer down; any touch elsewhere, a tool panel or
  the gap, clears it). The toolbar shows what fits and puts the rest behind its
  overflow, so Share, Select all and sometimes `Copy as Markdown` are one tap
  further. No button is drawn on a message. A screen reader gets the custom
  action `Copy message` on every block of the message; it opens a `Message` sheet
  (`Copy text`, `Copy as Markdown`). A message that is still streaming is not
  copyable. The result is the toast `Copied` / `Copied as Markdown` and
  `Haptics.tick`.
- **Panels** (`MoreRow`, `CodePanel.onCopy`). Tool output, a command, a diff and an
  embedded text get a quiet copy icon (44 dp, `textSecondary`) at the right of the
  foot row of their panel, the row that says `N more lines` / `Show all`; a panel of
  more than six lines has that row even when nothing is hidden (`14 lines`), a
  shorter one does not. It copies the whole text the panel holds (a diff as shown,
  with `+` and `-`), not only what is open.
- **Not verified on a phone**: the Material selection toolbar's width on the
  device (how many buttons sit before the overflow), and whether TalkBack
  focuses the container that carries `Copy message`.

**Background work** (`background_strip.dart`, `background_sheet.dart`,
`background_format.dart`). A
turn and the jobs it started are different things: Stop ends the turn only.
When the turn is over and jobs run, the status line says
`Waiting for bg_6 · 4h 36m` and the board row `waiting 4h` (not `Working`), the composer offers Send, and a
strip above it (`n running in background`, plus `omp continues by itself when
it finishes` where a finish wakes the agent) opens the sheet. The sheet lists
Running and Finished (`failed` first, five, `Show more`), one row per task with
a Lucide kind icon, the first command line in mono through `visibleText()`, and
a Stop that is a hold (`HoldToConfirm`; a tap shows `Hold to stop`; TalkBack
primes then sends). Where the route is a message (omp) the chip reads `Ask omp
to stop` and the footer says so once. `Stopping…` uses the one allowed
`BusySpinner` for at most 12 s, then `Could not confirm` + `Retry`. After Stop
ends a turn with jobs left, one toast `Turn stopped · 1 job still running` with
`View`. The strip is hidden in the compact layout (the bar chip carries the
count); it appears and goes without animation.

**Continue and Past sessions** (`continue_button.dart`, `ui/features/history/`).
An ended session whose keeper is gone shows its saved transcript read-only and the
link strip says `Session ended` with `The agent kept the conversation.` and a
`Continue` button (the one allowed `BusySpinner` while it resumes; a failure is a
toast with the host's words and the button comes back; evicted sessions keep
`Take over`). `Past sessions` (the history icon in the Agents board header, and a row
in the new-agent-session form that passes the typed folder) lists what an agent
remembers on a machine: machine chips when more than one is online, agent chips,
a `This folder` chip when the opener passed a folder, search past six rows. Row =
title (`Untitled session`), folder tail, `5 min ago · 14 messages`; whole row is
the target; a session already open shows `Open`; resuming shows a spinner on that
row and ignores the others. Empty, cannot list, cannot reopen, error with Retry,
offline and `Showing the newest N` are states, not toasts. Every string passes
`visibleText()`.

**Composer ends.** The field is a stadium at its smallest height and its corner
is concentric with the round buttons (36 dp discs 6 dp inside the edge, so the
radius is 18 + 6 = 24); the paperclip is the same soft disc as Send, so both ends
weigh the same (the glyph is lifted 1 dp: the clip's ink sits low). The pane's
composer and the chat's are one frame (`composer_frame.dart`: `ComposerFrame`,
`ComposerField`, `ComposerRoundButton`, `ComposerAttachButton`), so the same
agent looks the same in both views; only a shell's line stays in the mono font
and has no paperclip.

### Selection mode (batch actions)

A long press on a card or row selects it; taps toggle; the header reads `N
selected` with All and Cancel; the tab bar and the triage pill step aside and
Interrupt, Message and Close take the tab bar's slot in the same pill
(`FloatingBarSlot` + `FloatingBarPill`, cells shaped like tab cells), so the
bottom keeps its shape and the actions are where the tabs were. Every action goes
through a confirm sheet built from live data: targets, skipped ones with the
reason, and a count in the button (`Interrupt 3 agents`). A blocked terminal
agent is listed under `Waiting for an answer (skipped)` and is typed into only
if `Send anyway` is switched on (off by default); a blocked agent session never
is. Results land in one toast (`Interrupted 3 · 1 failed: build-box offline`).

### Starting and duplicating

**One `+`, one meaning: it starts what the list holds.** The Agents tab and a
machine's screen open `New agent session` directly (the machine screen's has
its machine chosen, and is dimmed while the machine is offline); the Machines
tab's adds a machine. Same icon, same place (top right), no sheet in between.
`Past sessions` is its own history icon beside it in the Agents header, and
`Add machine` lives on the Machines tab (and the first-run empty state), not in
a menu on another tab. Why: the `+` used to open a four-row sheet on the board,
start a terminal workspace on a machine's screen and add a machine on the
Machines tab, so the same mark meant three different things.

There is one start form, `New agent session` (an agent over ACP). The phone no
longer starts bare terminal workspaces: an agent already running in a herdr
pane still opens, in its terminal or its chat. Why: two forms for one job
drifted apart (what each remembered, what each accepted), and the agent form
is the one people use.

`Start` returns to where the form was opened and shows a toast (`Open` opens
it); `Start and open` replaces the form. `Duplicate` (the pane options, the
session options) opens the agent form prefilled with machine, folder and agent
and an empty first message; nothing is remembered until Start. A pane's agent
is matched to the form's agents by name (`omp`, `claude`, `codex`, `pi`); one
the form does not offer (`aider`, `gemini`, a plain shell) falls back to the
agent last used on that machine. A sheet row that cannot be used shows its
reason (`SheetAction.unavailable`), dimmed.

### Pull to refresh

`AppRefresh`: no white disc; a 2 px ring in `textSecondary` over the page
background, `elevation: 0`. `edgeOffset` is `SliverLargeTitle.extent(context,
hasSubtitle:, bottomHeight:)`, so the ring appears just below the pinned header
and never over the first row.

### Busy spinner (the one looping animation)

`BusySpinner` is a round-capped 2 px ring, 14 px in buttons and the composer's
send. It is allowed only for work the user is actively waiting on (a button that
is saving or testing, a send in flight) and must disappear when that work
ends. It is never decoration and never part of a resting screen.

### Working agent glyph (still at rest) and the settle

A working agent's `StatusGlyph` is a half-filled ring: it says "working" by
shape, like every other status. It used to turn in 8 steps at 4 a second; with
a board of agents that was constant noise to look at and a timer plus a
repaint per glyph to pay for in battery, so nothing animates at rest. The one
motion is the **settle**: when the status of a glyph already on screen changes,
the old shape fades and the new one is drawn in once (`Motion.settle`, 240 ms:
a ring sweeps round, the check and the bar are stroked, the dot lands) and a
needs-you or done glyph sends one faint ring outward; then the ticker stops.
A glyph built with its status never animates, and reduced motion skips it.
The card that changed section also gets an accent wash that fades over
`Motion.arrival` (a highlight decaying, not a movement), and a card resizes
with `AnimatedSize` when its question appears or is answered instead of
snapping. `StepClock` remains only for the elapsed-time labels ("working 12m"),
twice a minute, while they are visible.

### Toasts

One system (`ui/core/toast.dart`), no `SnackBar`/`ScaffoldMessenger` anywhere in
`lib/ui`. `showToast(context, message, {kind, action, duration, groupKey,
groupMessage})`; code that shows one after an `await` or after its screen popped
captures `Toaster.of(context)` first (it holds the root overlay, as the
messenger used to be captured).

- **One at a time, replaced, never queued.** A new toast takes the place of the
  one showing: the text changes in place when one is on screen (no second
  slide), and a toast that is already leaving slides back in. A failure waits
  behind nothing.
- **Time from one table** (`ToastTiming`): 3 s; 5 s with an action or for
  `ToastKind.failed`. Pass `duration` only for a reason (the batch result keeps
  6 s, a prompt that did not go out 8 s).
- **Kind picks the mark and the haptic**, fired when it appears: `success`
  (check, `Haptics.sent`), `failed` (alert mark, `Haptics.failed`), `info`
  (nothing). Callers never fire these themselves for a toast.
- **Undo coalescing.** An Undo toast shared by repeated actions of one kind
  carries `groupKey` and `groupMessage(count)`: while a toast with that key is
  showing, the next call joins it (`Marked 3 reviewed`; a call
  that did several things at once adds its `count`), the
  clock restarts, and its button runs every undo, newest first. A toast that
  timed out or is leaving is not joined. Used by swipe-to-review and Mark all
  reviewed. Different kinds still replace each other.
- **Where it stands.** On the root overlay, above sheets, so it steps aside
  (`ToastRouteObserver` on the app's navigator) when a sheet or dialog opens;
  a tap on it also puts it away. Above whatever `ToastShelf` marks as covering
  the bottom edge: the tab bar (`FloatingTabBar`, lift = `clearance`), the batch
  action bar, `FormActionBar` and the bottom stacks of the pane and agent
  session screens (measured; those ride on the keyboard).
  A shelf counts only while its route is the one showing, so a pushed screen
  gets the bottom inset instead.
- **Look and motion.** `ds.surface` card with a border and `Ds.floatShadow`
  (not the Material inverse snack bar), a 44 dp text button in `accentText`, two
  lines of text at most, max 480 dp wide. Slide 16 dp + fade in `sheetIn`
  (250 ms), out `sheetOut` (190 ms), `Motion.easeOut`; reduced motion fades only.
  The text is a live region.
- **The card carries its own `Material`** (transparent). The root overlay is
  above every route, so no `Scaffold` is above the text; without one the text
  takes `MaterialApp`'s fallback style, a double yellow underline in every
  theme (a test pins plain text). Any widget put on the root overlay needs the
  same.
- **Every message is a toast, including the Stop one.** `Turn stopped · 1 job
  still running` was a Material `SnackBar` for a while: near-white on the dark
  theme and a second system with its own timing. A new message goes through
  `showToast`; nothing builds a `SnackBar`.

### Micro-interactions


- **Haptics** (`Haptics` in `motion.dart`): `tick` a tap/selection/step, `hold`
  a long press registered, `sent` something went out, `armed` a risky answer
  primed or being held, `failed` something failed. Call these, never
  `HapticFeedback`.
- **An agent starting to wait is felt** (`ArrivalCue`, `ui/shell/`). One `armed`
  haptic when a new key enters the "needs you" set (`AttentionSet.needsYouKeys`:
  terminal panes on a live machine and agent sessions whose machine and link
  are live) while the app is in front, from any tab or pushed screen. By key,
  not by count: an agent that went out of reach stays known as waiting
  (`AttentionSet.waitingKeys`), so a Wi-Fi to mobile handover, which empties
  the set and fills it again with the same agents, is quiet (comparing counts
  cued every agent already waiting), and one agent answered while another
  starts waiting is felt though the count stayed the same. Not during the
  first 3 s after start-up or after resuming (the fleet catching up is not
  news), at most one per 2 s, nothing for an agent that stops waiting. The
  Agents badge and the triage pill's count pop once when they rise
  (`PopOnRise`, `ui/core/pop.dart`: a 1.22 scale over `Motion.settle`, then
  still; reduced motion skips it).
- **Send haptics follow the outcome; a failed send loses nothing.** One
  contract for both composers: `sent` fires when the message was taken and
  `failed` when it was not, never before the outcome is known (a session
  composer that buzzed `sent` and cleared the field before an observed agent's
  send failed left the person with neither the text nor a true signal). The
  pane composer keeps its text until the request is accepted (the tap itself
  already ticked). A failed send's banner stays through the reads that
  follow, until a send succeeds or Retry is pressed; text typed while a send
  was in flight is kept. The session composer empties at once (an ACP prompt
  is taken the moment it starts, and its turn is not waited for:
  `AgentSessionView.sendBlocks` completes with whether the message was kept)
  and on a failure puts the text and attachments back, ahead of anything typed
  or attached meanwhile.
- **Swipe to review**: a leftward swipe on a done, live card or compact row,
  or on a done, reachable agent session row (not while picking), reveals a quiet
  `Reviewed`; past the threshold, or on a
  flick, the row slides out and `markReviewed` (terminal) or
  `AgentSessionView.markSeen` (session, without opening it) runs with a `Marked
  reviewed` toast and Undo, `Marked 2 reviewed` for several in a row
  (`swipe_review.dart`). Undo is `unmarkReviewed` / `unmarkSeen`, which only
  restore that very finished turn. Springs, 1:1 tracking, rubber band at
  the end; screen readers get a `Mark reviewed` action.
- **Mark all reviewed**: a ghost button on the Done section header, beside
  Select all. It reviews every finished, reachable terminal agent and session
  (`AttentionSet.toReview`) at once under ONE toast, `Marked 4 reviewed`, whose
  Undo restores them all (and joins a swipe's toast still showing). Absent
  when nothing finished can be reached: the header says `2 offline` instead.
  Why: offline finished agents used to stay counted and the button did
  nothing, silently. Per-device state only; herdr's own seen state is never
  touched.
- **Quick phrases**: a row of chips above the composers (pane and agent
  session), shown while the field is focused and empty, never in the compact
  layout. A tap fills the field and never sends. Edited in Settings; prefs key
  `quickPhrases.v1`, 12 phrases of at most 80 characters. Up to 3 learned
  chips (`SentPhrases`, key `sentPhrases.v1`) follow the person's own list, or
  lead the shipped defaults while the list is untouched: a message really
  sent beats a guess, and an edited list never moves. A message is learned
  only from text sent to an agent (never a line typed into a shell), after
  its second send, one line, no address, no token of 24+ characters, 300
  remembered at most. Why: replayed on a year of one person's messages, 14% were
  exact repeats and these chips finish 5% of messages in one tap, twice the
  defaults (`tool/predict-eval`); what a person types can hold secrets, hence
  each limit.
- **Dictation** (`ui/features/dictation/`): the mic takes Send's place in both
  composers (agent session, and a pane that has an agent) while the box is
  empty and the link is live: the same 36 dp disc, neutral at rest, the accent
  while it listens, and it stays the stop button while it listens although the
  box now holds the words (the button never turns into Send under the thumb
  mid-sentence). What is heard goes into the box at the cursor and never
  sends: the person reads it and presses Send, as with a quick-phrase chip. A
  long press picks the language: English and Tiếng Việt always have a row, dimmed
  with the reason when the phone's speech service lacks them; the choice is kept
  (`dictation.language.v1`). Not offered for a line typed into a shell. Why: a
  phone is faster to speak to than to type on, one-handed, and a wrong word
  sent to an agent is worse than a wrong word in the box.
- **`DrawCheck`** (`ui/core/draw_check.dart`): the success mark that draws
  itself once (320 ms). Rare moments only; today the machine form's connection
  test and the triage sheet's `All clear`.
- **Brand mark** (`ui/core/brand_mark.dart`). herdr's mark is a lowercase h
  whose stem rises into a shepherd's crook, holding one orange dot: herdr is
  the one who herds, and the app's job is the one agent that needs you. It
  is drawn in ink tokens (`Ds.ink.bg` tile, `Ds.ink.text` stroke,
  `Ds.ink.blocked` dot) in every theme, because it is the app icon, not a
  status. The crook curls outward: over the shoulder it read as an R at
  56 dp. One geometry (`BrandGeometry`) feeds the launcher icon, its Android
  13 monochrome layer, the notification icon (`ic_stat_herdr.xml`), the iOS
  and web icons and the first-run screen; the files are rendered from it by
  `screenshot_test/brand_assets_test.dart`, then `dart run
  flutter_launcher_icons`, so they cannot drift. It replaced a teal and amber
  hub-and-spokes mark whose colours were in no token, that had no themed
  layer and that blurred into a blob in the status bar. `BrandMark` (the
  first-run screen, `Your agents, in your pocket`) draws itself once over
  420 ms the way a hand writes it: the stem rises into the crook, the
  shoulder follows, the dot lands. It's the rarest moment in the app, so it
  gets the ceremony; reduced motion shows it finished, and the ticker stops.
  On ink the tile meets the page and the bare mark stands alone, which is
  intended.
- **Zoom detents**: pinch-zooming the terminal ticks at each whole font size
  and gives a firmer `hold` at the minimum and maximum.
- **Glance notification**: the quiet `Watching N agents` notice carries
  `2 need you · 3 working`; a terminal agent's needs-you notification shows the
  question and the command and offers up to two buttons for the options that
  are not gated (docs/ALERTS.md).

## Photo viewer (`ui/features/photos/`)

ONE full-screen viewer for every picture: a file (the browser, a tapped path,
the folder grid), a picture in the chat (inline, tool result) and the picture
chips of the composer. `openPhotoViewer` / `photoViewerRoute` push a
transparent route (the chat shows through the backdrop while a photo is
dragged away); `fileViewerRoute` (`files/photo_files.dart`) picks it for a file
whose name is a picture, and `FileViewerScreen` hands over (replaces itself)
when the bytes of a differently named file turn out to be one. A `.png` whose
bytes are text offers `View as text`. The viewer is always dark (`AppTheme.dark`
inside, light icons in the bars, black backdrop) whatever the app theme is; its
sheets are dark too.

- **Chrome.** One tap toggles it (fade, `Motion.standard`; nothing wraps it
  while fully shown, nothing in the tree is composited at rest): back, `Photo 3
  of 12` (the file name for a lone photo), info, and one `Save or share` button
  (sheet: `Save to phone`, `Share…`, `Copy path`). A one-line caption under the
  picture, shown with the bars: `name · 4,032 × 3,024` (middle-ellipsis, the
  extension and the end of the name stay; the size while loading). A drag that
  dismisses fades the bars out within a third of the way.
- **Info sheet** (`photo_info.dart`, rows from `photoInfoRows`, tested): name,
  full path (mono, copy button), `From` (a chat picture: `Tool result · Read
  screenshot.png`, `Sent by omp · date`, `You attached it`; strings through
  `visibleText`), dimensions and megapixels, size, format, modified, EXIF taken
  / camera / lens / exposure, `Turned upright (EXIF 6)`, and a note while only
  the screen-size bitmap is held.
- **Gestures** (`photo_stage.dart`, arithmetic in `photo_math.dart`). Scale is
  relative to fit (1 = the whole picture, never smaller at rest); everything is
  a spring (`SpringDescription.withDampingRatio`, stiffness 400) started from the
  live value with the finger's release velocity; there are no timed tweens.
  A finger landing stops what is moving the picture (`Listener.onPointerDown`),
  a second finger or a lifted one re-bases the gesture, nothing locks input.
  Pinch zooms around the fingers' centroid, rubber-banded in ratios past fit
  and past `maxScale` (3x actual size, 4x..16x) and springs back on release;
  double tap goes fit <-> 2.5x at the tapped point (the recogniser exists only
  on a loaded picture, or every button of a failure panel would wait 300 ms);
  a pan hands its velocity to `BouncingScrollSimulation` (momentum, rubber band
  at the edges); at an edge a further drag turns the page (rubber band at the
  first/last photo, 40 % of the width at most); a vertical drag at fit
  dismisses (the picture follows and shrinks 30 %, the backdrop fades; the
  decision uses the projected end `dy + project(vy)`, with 22 % of the height, and
  a drag taken back against its direction never closes). Detents: `Haptics.tick`
  as the picture crosses fit and as it reaches its largest size. Reduced
  motion: every spring lands at once (no slide, no travel); fades stay.
- **Pixels.** The first bitmap is decoded to fit 1.5x the screen's pixels
  (`photoBaseFactor`; never above that until the person zooms); when the
  picture is stretched past it (`wantsSharper`) one sharper decode up to
  4096 px a side (`photoSharpSide`, <= 48 MB) joins it and is given back 2 s
  after zooming out or when the photo is left. Only the open photo and its two
  neighbours hold anything (`PhotoViewerViewModel`: read the open one, then
  the one in the direction of travel, then the other, one read at a time,
  neighbours over 12 MB wait, moving on cancels a stale read). EXIF
  orientation is applied by the engine's codec (the descriptor reports the
  rotated size; checked in `photo_viewer_model_test.dart`). A picture shown past
  2 device pixels per bitmap pixel uses the nearest neighbour; a PNG / WebP /
  GIF that may be see-through (`mayHaveTransparency`, header only) sits on a
  checkerboard.
- **Loading and limits.** The thumbnail the folder grid or the chat preview
  already made stands in (`PhotoItem.placeholder`), under the one spinner and
  `4.2 MB of 11 MB` with a thin progress bar; both go when the picture is there.
  Files are read over SFTP in 2 MB pieces (`photoReadChunk`, `RemoteFiles.readAll`
  with progress and a `ReadCancel`), up to 40 MB (`photoReadCap`); over it
  nothing is read and the panel says `This photo is 52 MB. The viewer opens
  photos up to 40 MB.` with `Share…`, which copies the file to the cache
  directory in pieces (memory stays flat) and opens the share sheet
  (`PhotoExport.shareLarge`). Save and share use `gal` (MediaStore, album
  `herdr`, no permission from Android 10) and `share_plus`.
- **Folder grid** (`files/photo_grid.dart`, `photo_thumbs.dart`): a folder with
  6 or more pictures gets a `Photos` header toggle that swaps the list for a
  3-column grid; at most 3 thumbnail reads at once, smallest first, files over
  2 MB are never read for a thumbnail (a glyph and the size), scrolled-away
  tiles cancel their read.

## Attach sheet (`ui/features/attach/`)

One bottom sheet for everything that can go with a message, modelled on
Telegram's: a grabber, a scrim, a content area and a floating pill of tabs at
the bottom. `showAttachSheet` (agent_session/attach_sheet.dart) pushes
`AttachSheetRoute` on the frame of the tap (nothing awaited before it); the
tabs draw what they have (the bars, the camera tile) while the library answers.

- **Frame** (`sheet_frame.dart`). Not a Material bottom sheet, which resizes
  its content while dragged: the content is laid out ONCE at full height and
  moved with transforms. `SheetPosition.offset` is the translation from full
  height (0 = full, `restHalf` = half, ~55% of the screen, `full` = away). The
  surface follows the finger 1:1, the bars (action bar, tab bar) keep to the
  screen's bottom while the sheet is between half and full height, a release
  hands the finger's velocity to a spring (`SpringDescription.withDampingRatio`,
  stiffness 420, ratio 0.88) and picks the stop from where the sheet would end
  up (`velocity * 0.25`): between full and half the choice is one of those two
  (a hard flick down from full lands on half, the next one closes), below half
  it goes away or comes back. The grid scrolls only at full height (at half a
  drag on it moves the sheet: `SheetScroll`); at full, a pull down from the top
  hands over to the sheet. The scrim ignores taps until the sheet has come up
  (the second tap of a double tap on the paperclip). The keyboard lifts the
  sheet to full height and the tab bar steps aside. Under reduced motion the
  sheet appears and every release lands at once. Tabs keep their bottom end
  clear with `SheetScope.bottomClearance` (the half-height shift that hangs
  below the screen plus the bars) and are top-aligned, never centred, for the
  same reason.
- **Tabs** (`attach_bars.dart`, `attach_sheet_view.dart`): Gallery | Files |
  Host, each an icon and a label, the selected one on a `ds.fillPressed` capsule,
  in the tab bar's pill (`FloatingBarPill`).
  Built the first time they are shown, kept alive and out of layout while
  hidden (scroll position and state survive), cross-faded over `Motion.fade`
  (120 ms; nothing is wrapped in an opacity layer at rest). The last tab is
  remembered for the app run (`AttachKit.tab`).
- **One tray** (`tray.dart`). Every tab puts picks in the same `AttachTray`;
  the numbers on the circles are places in it, `Attach (3)` and `3 / 5` count
  every tab, `Clear` empties it. The action bar slides up (transform + opacity,
  `Motion.standard`) as soon as one thing is picked. Tiles and rows do not own
  notifiers: each listens to the tray and rebuilds only when its own number
  changed (`attach:tile` builds are counted in tests; the grid itself is never
  rebuilt by a selection, a page arriving or a tab switch).
- **Gallery** (`gallery_tab.dart`, `gallery_model.dart`,
  `data/services/phone_gallery.dart`). `photo_manager` over MediaStore (the
  maintained plugin with paged queries, albums, MediaStore's own thumbnail
  cache and limited access; it builds for Android, its Kotlin plugin is
  flagged by Flutter's built-in-Kotlin warning). A 3-column grid (more columns
  on a wide window), newest first, the camera as tile 0, a 24 dp ring in each
  tile's corner (44 dp to hit): empty on a dark wash, filled with the accent
  and the pick's number when picked (a 0.9 -> 1 pop over `Motion.press` and
  `Haptics.tick` on the change; the picture shrinks to 0.88). A tap on the
  circle toggles, a long press on the tile toggles (`Haptics.hold`), a tap on
  the tile opens the one photo viewer with a `Select` pill over the picture
  (`PhotoViewer.overlay`). The `Recent` chip lists the albums; with Android 14's
  partial access a `Manage` chip re-opens the system selector. An agent that
  takes no images gets the line `This agent does not take images. Photos go up
  as files.` and its photos upload as files.
- **Permission.** Read (never asked) when the tab is shown. Undetermined: a
  panel with the one-line reason (`Photos stay on your phone until you attach
  them.`) and `Allow photo access`: the system dialog comes only from that tap.
  Refused: `Open settings` (the access is read again on resume). Plugin
  failure: only the fallbacks. `Open the system picker` (image_picker) and
  `Take a photo` are on every one of those panels; a panel too tall for half
  height lifts the sheet to full. Manifest: `READ_MEDIA_IMAGES`,
  `READ_MEDIA_VISUAL_USER_SELECTED` (the plugin adds `READ_EXTERNAL_STORAGE`
  up to API 32).
- **Speed** (`thumb_cache.dart`). The paperclip's pointer-down and the screen's
  first frame call `GalleryModel.warm`: when the permission is already given
  and the app is in front, the first page (120 pictures) and the first 24
  thumbnails load, so the sheet opens onto pictures (never before the
  permission, never in the background, never asks). Thumbnails are JPEGs of
  <= 240 px from MediaStore's cache, decoded by the engine off the UI thread
  (`ResizeImage` at 240); `ThumbCache` is an LRU of ~200 entries / 60 MB whose
  evictions also evict the decoded bitmap, at most 4 loads at once, newest
  request first, scrolled-away tiles cancel before they start, prefetch of one
  screenful ahead in the direction of travel only when nothing on screen waits,
  the queue held during a fast fling (> 2400 dp/s), cleared on memory
  pressure. A tile is a flat tint until its bytes arrive (no spinner), then
  fades in over `Motion.fade` unless it was already in memory or motion is
  reduced. The grid is a fixed-extent `SliverGrid` (a screenful built beyond
  the edge, a `RepaintBoundary` per tile, no shadows, blur or opacity at rest)
  and loads pages of 120 as indexes are asked for. A pick is read and encoded
  at once (two at a time, `ComposerAttachments.speculate`) and abandoned if
  undone, so `Attach` has nothing left to wait for; the chips appear in the
  frame the sheet starts to leave, and uploads start when its animation is over.
- **Fresh** (`GalleryModel._refresh`). The model lives for the app run, so what
  it loaded is a saved copy: the paperclip's pointer-down, the composer's first
  show, the Gallery tab being shown and the app coming back to the front each
  read the album again (its count and its first page: two queries). The grid
  paints what it has at once and is corrected when the answer differs; a
  library that did not change notifies nobody and decodes nothing. A change
  keeps the first page, drops the pages below it (their indexes moved; they are
  asked for again as the grid scrolls there; thumbnails are keyed by picture and
  stay), and an album that disappeared falls back to `Recent`. Why: it used to
  read once per app run, so a screenshot taken while herdr was open was not on
  the grid until the app was killed. Android 14's partial access still hides
  pictures the person did not share: the `Manage` chip is the way to add them.
- **Files** (`files_tab.dart`, `data/services/phone_files.dart`). `Choose
  files…` opens the system document picker (`file_picker`, multi-select; the
  plugin streams the document into the app's cache, so nothing large passes
  through Dart memory), and picks join the tray as rows. `Recent` lists the
  last 10 phone files attached (`RecentPhoneFiles`, prefs `attach.recentFiles.v1`:
  name, size, and the host copy's path for that machine, never content or a
  phone path); a recent whose host copy still exists is attached again without
  sending it again. Over 25 MB: attached with a warning; over 200 MB: refused
  with `name is 312 MB. Files up to 200 MB can be attached.`
- **Host** (`host_tab.dart`). The file browser's own pieces inline:
  `FileBrowserViewModel` per folder (one stack, shared `FileBrowserOptions`),
  `FileRow` with a `SelectionCircle` in its trailing slot, `FileBreadcrumbs`,
  `EmptyFolderState`; opens on `Changed recently` in the session's folder, a
  find field, folders navigate in place, `Browse all…` pushes the full browser
  in pick mode as before.
- **Uploads** (`ComposerAttachments`, `data/repositories/attach_upload.dart`).
  A file of the phone (or a photo for an agent without images, or a picture
  over the encoder's 25 MB) goes to `<home>/.herdr-mobile/inbox/…` over
  SFTP (`reserveInboxPath` + `RemoteFiles.upload`) and is attached as a
  resource link to that path. The chip shows a ring over its thumbnail and
  `Uploading 42% · 48 MB`; the cross cancels, a failure shows `Retry`.
- **One rule for a picture, whatever its source.** The gallery, the camera
  tile, `Take a photo`, `Open the system picker` and an image chosen in Files
  all decide the same way (`ComposerAttachments._startPicture`, the gallery's
  `_beginGallery`): an image block when the agent takes images and the
  picture is at most 25 MB, else the original uploaded as a file, its chip
  saying `Sent as a file · this agent takes no images` from the start. The
  pickers hand over a path and a size (`PickedPhoto`), never bytes, so the
  composer chooses. Why: the camera and the system picker used to send a JPEG
  image block to an agent that takes none; the chip said ready and the send
  failed afterwards.

## Markdown (`ui/core/markdown/`)

One renderer for every Markdown surface: the agent's answer and thoughts, the
file viewer, later a plan in the permission dock. The model is `MdDocument`
(`md_document.dart`, the only thing a renderer reads); the widgets are
`MdBlockView` (one block, for a lazy list that keeps its own "Show all" state),
`MdDocumentView` (a whole static document in a column) and `mdBlockGap`.
Each block is a `Text.rich` paragraph, a list, a quote, an alert, a table or a
code block, so `SelectionArea` selects across all of them (one `SelectionArea`
over the transcript list keeps working across a code block and a table) and the
text is the semantics label. The tone comes from `MdToneScope`: an answer reads
at body size in the text colour, reasoning (`ThoughtRow`) at the secondary size
and colour, a quote in the supporting colour.

- **Blocks.** Headings 22 / 18.5 / 16 / 15 (`Type.*`, 600-700, h4-h6 body size),
  paragraphs `Type.body`, bold 700, italic, `~~strike~~`, inline code in mono
  1.5 pt smaller on the quiet fill, links `accentText` underlined faintly. A
  soft line break is a newline in chat prose and a space in the file viewer
  (`parseMd(softBreaksAsNewlines:)`). A hard break, `<br>`, entities and
  autolinks come from the model. RTL is per paragraph (the first strong
  character): such a paragraph, its list item or its quote is laid out right
  to left.
- **Spacing** (`mdBlockGap`): 10 between blocks; 16 above an h1/h2, 12 above
  h3-h6, 6 under any heading; 6 from a lead-in paragraph to its list; 12 around
  a rule. In a list: 4 between tight items, 10 between loose ones; inside a
  tight item 3 around a nested list and 6 between paragraphs. Text blocks stop
  at a reading width of about 72 characters (560 dp at 100% text; it grows with
  the text scale) on a wide screen; code and tables use the whole width.
- **Lists.** Depth is structure; the marker column is as wide as the widest
  number (ordered lists keep their start, numbers right-aligned in tabular
  figures); bullets are drawn shapes, a dot, a ring, a square by level; the
  indent stops growing past six levels and past 125% text scale. A task item
  is a read-only status shape from the glyph language (`StatusGlyph`: an empty
  ring open, a check done), never a checkbox, announced as "Done" / "Not done".
  Continuation paragraphs, code and nested quotes live inside the item.
- **Quotes and alerts.** A quote has a 3 dp bar at its start edge and the
  supporting text colour, nested to any depth. A GitHub alert is a quiet fill
  with a Lucide glyph and its name (`Note`, `Tip`, `Important` in the
  supporting colour, `Warning` in `blockedText`, `Caution` in `dangerText`): no
  coloured chrome.
- **Code.** A header 44 dp high with the language label (caption, `textMuted`),
  a wrap toggle (shown when a line is longer than ~34 characters) and a copy
  button (Lucide `copy`, 44 dp hit); copy gives the raw code and the icon says
  `Copied` for 1.6 s, with a `tick` haptic. No wrap by default: the block
  scrolls sideways, so a line stays one line; the last toggle is the start
  state of the next block. Colours are the theme's terminal palette
  (`context.terminal`, the same colours as a pane) on the quiet fill, every
  token colour >= 4.5:1 (`md_highlight_test.dart`); a dark terminal on paper
  takes the terminal's page. Highlighting (`highlight/`) is per line, kept per
  block, redone only from the first changed line, and only for the lines shown
  and complete: the open last line of a streaming block stays plain, so a
  colour never flips back. Unknown languages stay plain. 60 lines, then
  `N more lines` and `Show all` (a lazy 360 dp box past 300 lines); the caller
  owns that state. Bidi overrides and control characters show as `‹U+202E›`
  (`visibleText`), tabs go to the next multiple of four, a line past 2000
  characters is cut and counted. Every line goes through `clipLine`
  (`visibleText`, then a cut that never splits a surrogate pair): half a pair
  makes the paragraph builder throw "string is not well-formed UTF-16", and a
  row whose layout throws is left undrawn. Prose goes through `proseText`
  (half a pair becomes U+FFFD, bidi overrides go).
- **Tables.** A real table: bold header over a stronger hairline, one hairline
  per row, no zebra, text 1.5 pt under body in tabular figures. A column is as
  wide as its longest cell (and bold header) between 48 and 240 dp, longer text
  wraps in the cell, and while rows stream the widths only grow. Alignment
  follows `:--` / `:-:` / `--:`. Narrower than the screen it shares the width;
  wider it scrolls sideways with a 28 dp fade on the edge that has more, and
  never overflows. 40 rows, then `N more rows` / `Show all`. A long press
  (or the `Copy table` accessibility action) offers Copy as Markdown and Copy
  as TSV.
- **Links, paths, images** (what a tap does comes from the nearest
  `MdActions`; a surface without one draws the text without the affordance).
  Only `http` and `https` links open, and only through the link sheet, which
  shows the whole address first (a label can say anything); `mailto:`,
  `javascript:`, anchors and the like are plain text. A path (`lib/a.dart`,
  `lib/a.dart:42`, `~/x`, a relative link target, `#L42` fragments) in text,
  in inline code that is nothing but a path, or as a link target opens the
  file viewer at that line, on the session's machine, relative to its folder
  (`AgentMdScope`; in the file viewer relative to the file's folder): the host
  is asked only on the tap, never while drawing. An image is never fetched: a
  quiet chip `Image: alt · host`; a tap shows the address in the link sheet
  (web) or opens the file viewer, which draws pictures (a path).
- **What counts as a path** (one detector, `ui/core/terminal_links.dart`,
  shared by the terminal view and this Markdown, so a token is a link or not
  for the same reason in both). A path is underlined only when it looks like a
  FILE: `name.ext` (a stem and a short alphanumeric extension that is not all
  digits, so not `1.2.3`), or a well-known extension-less name (`Makefile`,
  `LICENSE`, `go.mod`, `.gitignore`, `/etc/hosts`), with an optional `:line`,
  `:line:col`, `(line,col)`, `#L12`, `#L12-L20` or ` (line 12)`. Alone (no
  directory) the extension must also be a known one, so `e.g` and `www.x.com`
  stay words. Never a link: folders (`src/`, `lib/ui`, `/usr/local/bin`), slash
  commands (`/model`, `/compact`, `/resume`: a single absolute segment with no
  dot, at the start of a line or anywhere), `and/or`, dates, versions, ratios,
  CLI flags, `host.com/x`, `user@host:/x`, `C:\x`, `package:x/y.dart`,
  `#include <x.h>`, globs, calls (`res.json()`), and the tail of an ellipsis
  (`…/a.dart`). Git's `a/` and `b/` in `--- a/x`, `+++ b/x` and `diff --git`
  headers are not part of the target (the underline still covers them); in a
  `--stat` line `a/b/c.dart` is a real folder. A missed link costs a copy and
  paste; a wrong one is an underline in the way, so every rule leans towards
  plain text. `test/link_sense_test.dart` holds the labelled table (over 230
  lines), the recorded-session check and the speed budget.
- **Tapping a path** (`openRemoteFile`): the host is asked only now. It tries
  the pane/session folder, then the two folders above it (an agent names a file
  from the project root while the pane sits in a subfolder), with git's `a/`
  `b/` prefix dropped as a second try; `/x`, `~/x`, `./x` and `../x` are not
  searched for elsewhere. A file opens the viewer; a folder opens the browser;
  a missing or forbidden one is a toast, never a dead end.
- **Text safety.** Code and inline code show every hidden or direction-changing
  character as `‹U+202E›`; prose drops the embeddings, overrides and isolates
  (they can only mislead) and keeps the right-to-left and left-to-right marks
  real RTL text needs. The engine percent-encodes such a character in a link
  target, so the sheet shows `%E2%80%AE`. HTML is text.
- **Semantics.** Each block row is a node with its plain text; headings are
  headers; a code block reads `Code, dart, 12 lines` (no language: `Code, 12
  lines`) with its header buttons and its text as separate nodes; a table
  reads `Table, 3 columns, 5 rows` (the header counts as a row) with its cells
  as separate nodes; a link, a path and an image chip are tappable nodes; a
  task item says `Done` or `Not done`. The open tail of a streaming message
  (`tail: true`) is excluded until it is final, so a screen reader is not
  re-announced every frame.
- **Streaming.** The transcript draws the answer that is arriving through one
  live row (`LiveMessageRow`, "The live row, pacing and follow" under "Agent
  session screen" above): frozen blocks as cached widgets, the open tail
  healed (`**bo` shows as bold, an open fence as a code block, a half-written
  table row waits) with `tail: true`. Ending the message changes no pixel: the
  settled rows are the same widgets with the same gaps. Not here yet: the fade
  of the newest words (off until measured on the phone) and a measurement of a
  painted block on the phone.

## Files (`features/files/`)

The question while supervising an agent is "what did it just touch?", so the
browser is built to be reached fast, scanned and not lost in.

- **Reached at once.** `openFileBrowser`, `openRemoteFile` and
  `pickRemoteDirectory` push the screen on the same frame and ask the host
  inside it: the browser works out its start folder (`FileBrowserViewModel`
  with `startDir`), a tapped path shows `FileResolvingPage` (Back, the name)
  and swaps in the viewer or the browser with a 120 ms cross-fade, or shows
  why it failed (Not found, No permission, Not reachable) with what to do. The
  skeleton (`DelayedSkeleton`) draws only after `skeletonDelay` (120 ms), so a
  fast link never flashes grey. The same path (or the browser) is opened once
  while it is being found (`_opening`). Entry points: the pane bar's Files
  (pane's cwd), the machine screen (home), a path in output or chat, and
  Session options > Files (the agent session's folder).
- **A path the agent names is found where its work is.** Agents hand work to
  subagents that write in sibling git worktrees, so `docs/X.md` is often not
  in the session folder. After the first attempts (folder, two parents, git's
  `a/` `b/`; one `stat`, unchanged) `resolveRemotePath` asks `PathFinder`
  (`data/repositories/path_finder.dart`, SFTP only: `stat`, `list`, 4 KB reads
  of `gitdir` files, no shell, links never entered): (a) the same relative
  path in the other worktrees of the session's repository (`.git/worktrees/*/
  gitdir`, or the main repo's list when the folder is itself a worktree; at
  most 12, 4 calls at a time, 3 s, lists remembered 60 s per machine and
  folder); (b) for a distinctive name (not `README.md`/`main.dart`) or after
  the Search button, an exact-name search below the folder (breadth first,
  depth 3, 400 folders, 2 s, no hidden/`node_modules`/`build`/`.dart_tool`/
  `target`/`dist`). Malformed `gitdir` files and permission errors are
  ignored; leaving the screen cancels (no call after). One hit opens with a
  toast naming its source (`From worktree herdr-mobile-ux`); several open
  `showPathChoices` (path below its root, root name, modified, newest first;
  dismissing goes back). The wait is the viewer's skeleton with a line
  (`Looking in other checkouts…`). A miss is the Not found page and names the
  path and where it looked: `docs/X.md isn't in herdr-mobile (also looked in
  3 worktrees and searched by name)` (path cut in the middle; Search offered
  only when the name search did not run). Terminal links, Markdown paths and
  chat content links all go through `openRemoteFile`, so all get it.
- **One stack, never deeper than the folder.** A walk down is one route per
  folder, all sharing one `FileBrowserSession`. A breadcrumb POPS to the
  ancestor that is on the stack (it keeps its listing and scroll; nothing is
  read again); an ancestor above where the session began points the first
  browser at it in place (`retarget`). Back goes up one level. A picker still
  answers down the whole stack.
- **What you chose stays** for the session (`FileBrowserOptions`, shared by every
  folder): hidden files, sort (Name A-Z, Modified newest first, Size largest
  first, Type), folders first, and the `Changed in the last hour` chip, which
  also sorts newest first with folders among the files (and restores the order
  when switched off, unless it was changed by hand). The filter covers THIS
  folder's listing only (SFTP lists one folder at a time): the empty state says
  so.
- **Rows** (`FileRow`) are on the `ListRow` grid: a 32 px glyph (a small picture
  for a raster image of at most 512 KB, `FileThumb`/`ThumbLoader`: only rows on
  screen, three reads at a time, 6 MB kept), the name cut in the MIDDLE so the
  extension stays (`middleEllipsize`), and one muted line `12 KB · 3 min ago`.
  An entry nobody can read (no read bit) or the host refused is dimmed and says
  `No permission`; it still opens to explain. Folders are never hidden by
  permissions.
- **Find in folder** (`foldForSearch`: lowercase, no diacritics, `đ` mapped by
  hand) filters the loaded listing as you type, from 8 entries up; no remote
  search, no shell.
- **The viewer notices the file changing.** While it is the screen in front
  (and the app resumed) it stats the file (no body read) when it comes back and
  every 15 s (`_DiskWatch`: `TickerMode` + app lifecycle, the timer is
  cancelled otherwise); a newer modified time shows the quiet `Changed on disk ·
  Reload` pill. A tap, or pulling the text down (`AppRefresh`), reads the file
  again with `FileViewerViewModel.refresh`: the old text stays on screen and in
  place (the line at the top is kept) until the new text replaces it, and stays
  with a `Couldn't refresh · Retry` strip if the read fails.

## Touch targets

44 x 44 minimum, always. `PressBuilder(minTapSize: kMinTap)` enlarges the hit
box around a smaller painted shape: `CircleButton` (40), compact `AppButton`
(36), `AppChip` (32, `AppChip.height` = 44 for a chip row; pass it as
`SliverLargeTitle.bottomHeight`) and each `Segmented` option (the track is 44
high). The layout box grows with the hit box, so lay these out at 44.

## Semantics

One node per control, announced once. `PressBuilder` rules, which every
control above follows:

- `semanticLabel: null` (default): the visible texts inside merge into one label
  (a `ListRow` reads "Needs you, title, claude · solo"). Use this wherever the
  child already says what it is.
- `semanticLabel` set: it **replaces** everything inside it, so icon-only
  controls (`CircleButton`, quick keys, send) say their name exactly once. Never
  set it on something that also contains the same text.
- The button role is announced only when the control can be activated; a plain
  `SectionLabel` or non-tappable row is plain text (`button:` overrides this for
  dimmed buttons).
- `selected` marks tabs, segments and filter chips. The tab badge is spoken
  ("Agents, 2 need you").
- Page titles, section labels, sheet titles and empty-state titles are headings
  (`Semantics(header: true)`). `LabeledField` names its text field by the
  label; the visible label text is excluded so it is not read twice.
- Collapsed content (`Collapse` while closing, `SliverLargeTitle.bottom` once
  hidden) is excluded from semantics, focus and hit testing.

## Layout and state

- `MaterialApp.builder` wraps every route in `SafeArea(top: false, bottom:
  false)`, so side insets (landscape navigation bar, cutouts) are cleared once.
  Screens handle top and bottom themselves.
- `LabeledField` always reserves one line below the input for helper or
  validation text; an error appearing never moves the field underneath.
- `MaterialApp(restorationScopeId: 'herdr')` is set. Screens opt in with
  `restorationId` (e.g. `LabeledField(restorationId:)`) for non-secret input;
  never restore keys, passwords or passphrases: restoration state is written
  to disk in the clear. One exception, kept out of it: a key generated in the
  machine form and not saved yet is held as a draft in the keychain
  (`MachineRepository.holdKeyDraft`), and only a flag is restorable. The
  person copies its public half and goes to the host; if Android reclaims the
  app meanwhile, the installed key's private half would otherwise be gone. The
  draft is dropped on Save, Discard, a hand edit of the key field, and when a
  form opens afresh. A pasted key is not held: it exists where it came from.
- A form with unsaved input asks before Back discards it (`PopScope` plus
  `showConfirmSheet`, for the bar's back, the system back and the predictive
  gesture); a clean form leaves at once. The machine form says so loudest
  for a generated key, which is kept nowhere else. A Save or Test that fails
  for any reason (keychain, timeout, a worker that died) ends its spinner and
  says what happened in the form's status panel; the input stays.
- Sheets read colours from the theme, so a light/dark switch while one is open
  restyles it. The sheet body scrolls when it does not fit.

## Theme and Settings

The theme is a setting (`ThemeChoice` light / dark / system, `AppSettings`),
**light by default**, including for installs that never chose. It is loaded in
`main()` before `runApp`, so the first frame is already right. `MaterialApp`
switches instantly (`themeAnimationDuration: Duration.zero`): a cross-fade
would lerp `ThemeData` per frame and rebuild every mounted screen, including
the hidden Agents board. The system bars follow the resolved brightness, so
`system` follows the phone.

Settings is the third tab (`features/settings/`): four rows, each saying what
it is set to and opening in place (`SettingsGroup`, on `Collapse`), one at a
time. Look (theme, agent list density, the terminal font size stepper 8 to 22
with a sample line, wrap, Dark terminal, and Smooth text: streaming answers at
an even pace, on by default, `AppSettings.smoothText`; the terminal ones edit
the pane's `TerminalSettings`), Agents (how agents open, and Quick phrases, a
row that opens its own page because the list grows), Notifications, and About
(what it talks to, update checks, source link, licences). A newer version's row
sits above them. Why four rows: the page was one long scroll of six sections
(about 1,800 dp) and each new setting made the next harder to find; four rows
fit a screen at 320 dp and 2x text, and a group grows without lengthening the
page. A row shows values, not setting names ("Light · Auto · 11.5 pt",
"Blocked by Android"), and a closed group is not built. Two tiles are tinted,
and only two: notifications Android blocks (orange, the colour that means
"needs you") and a newer version (the accent, a suggestion). The groups start
closed; the tab keeps its state, so a later visit shows what was left open.
The version is `lib/data/app_info.dart`; `test/app_settings_test.dart` fails
when it differs from `pubspec.yaml`. `AppSwitch` / `SwitchRow` live there
until another screen needs a switch.

**Updates** (`features/settings/update_group.dart`, `AppUpdate`). A newer
version on GitHub is a suggestion, so it is quiet: a 10 dp accent dot on the
Settings tab's icon (`TabSpec.mark`; the loud orange count stays the Agents
badge's alone) and an `Update available` row at the top of Settings, absent
when there is nothing newer. No toast, no notification, nothing on the board.
The row says the version and its size and is the one group open when the
person gets there (Download is then one tap, not two): on entry, or, when the
version is found while the tab is behind another, when it is next shown. A
version found while the page is showing does not open it: nothing moves under
the thumb. Its body offers one step at a time: Download (`Try again` after a
failure), a progress bar and Cancel, Install; `What's new` opens the release
notes (the version's `CHANGELOG.md` section, rendered with the shared
Markdown) in a sheet before anything is downloaded. While bytes arrive the
row carries the progress bar, open or not, so a download is never out of
sight behind another group; "Ready to install" and a failure are said to a
screen reader with the group closed. A failure says what happened and what to
do, whole and in red, in the body (the row only says "Update failed, open to
see why"); nothing is lost (a stopped download continues from its bytes).
Install opens Android's own confirm dialog, so nothing is installed silently;
if Android does not yet allow herdr to install apps, its settings page opens
and the body says to tap Install again after allowing it. The buttons stack at
large text sizes (a cut "Try again" otherwise). About holds `Check for
updates` (the manual check, with the reason when it fails) and `Check
automatically` (on by default: at most every 12 h while the app is in front;
the request carries the app name and version, and a download comes from
GitHub's file servers). Why on by default and why About says so: the app used
to say it "sends nothing anywhere else"; github.com is now the one other place
it contacts, and the Connection line says it. The download is only ever
started by a tap (it is ~50 MB of the person's radio). Android only:
`bootApp` builds no updater elsewhere and the screen then shows nothing about
updates.

The native launch window is the paper colour in day **and** night
(`herdr_bg`, no `values-night`): the chosen theme is not readable before
Flutter starts, and light is the default. A person who chose Dark sees a brief
paper-coloured launch (the Android 12 splash is paper with the app icon) before
the first dark frame.

`FloatingTabBar` is a slim floating pill (56 dp tall, 12 dp side margins, 8 dp
below, at most 312 dp wide and centred) in equal cells: a 22 dp icon over the
tab's name (`Type.label`), the selected one on a `ds.fillPressed` capsule with
`ds.text`. A hairline and `Ds.floatShadow`, no backdrop blur. Every tab is named and every cell
is the same width, so nothing moves when a tab is chosen, and the count badge
(18 dp, on the icon's corner) never meets a label. Why: the bar used to show
only the selected tab's label, which grew and slid the other two icons on every
tap, left two of three tabs as unlabelled icons, and put a `99+` badge on top of
the word "Agents"; owner's call: floating, but equal cells. Why slim: at 64 dp
and edge to edge it read as big (owner), and with its margins and scrim it
reserved about 140 dp of a 892 dp board for two rarely used tabs. The shadow:
a hard grey band was once reported under the pill. `flutter test` paints a
`BoxShadow` without its blur unless `debugDisableShadows` is turned off, which
is what that band was; `bottom_bars_shots_test.dart` turns it off, and its
renders match the phone (a soft falloff). Why `fillPressed`: `ds.fill` on the pill's surface was about 1.1:1
and vanished in dark. Three cells fit 320 dp (text is clamped at 1.15x,
`settings_test.dart`). `FloatingBar.clearance` is 56 + 16 + the bottom inset. Selection is
one capsule under the cells that slides to the chosen one (`Motion.standard`,
`Motion.easeOut`; it jumps under reduced motion and a second tap retargets it
from where it is). One number, the capsule's place in tab units, drives both
the capsule and every cell's colour, so the text warms as the capsule arrives
under it and cools as it leaves, exactly in step. Why: the colour used to be a
separate linear tween against the capsule's ease-out, so the two clocks drifted,
and the label weight (which cannot be interpolated) snapped on its own; the
weight no longer changes. The bar is the only way to switch tab: a tap, or a
drag along it. There is no sideways swipe over the whole screen (owner: no
need). Why not: nothing showed it existed, the page did not follow the finger,
and on Agents it fought swipe-to-review, since a left swipe over a finished row
reviews it and over any other row would have changed tab.
**Dragging along the bar carries the capsule** with the finger, 1:1 (the bar's
`onHorizontalDrag*`): nothing is chosen while the finger is down, a tick marks
each cell the capsule passes, it stops at the pill's two ends, and on release
the tab is the one a flick would have reached (0.1 s of the release speed
added to where the capsule is), so a quick flick is enough; a bar whose owner
did not take the choice sends the capsule back. Why: it is an object in the
hand, and a tap is the other way. The scrim that lets rows fade out above the
bar ends at `clearance`, where the triage chip begins: it is drawn above the
board, and a taller one dimmed the chip from its bottom edge up.
The cells never move and there is no press scale. Why: the first version
cross-faded a capsule in each cell (two ghosts, nothing travelled) and an
instant version read as nothing happening (owner: "not connect"); one capsule
that travels is the one motion that says where the selection went. Only a
rising count pops (`PopOnRise`). Tests find a tab with
`FloatingTabBar.tabKey(label)` and the capsule with `FloatingTabBar.capsuleKey`.

The shell (`HomeShell`) fades the incoming tab in over `Motion.fade` (120 ms,
opacity only; none under reduced motion); the outgoing tab just goes. Tapping
the active tab changes nothing and gives no haptic; on Agents it scrolls the
board to the top (`Motion.standard`, a jump under reduced motion) through a
`ScrollController` the shell owns and hands to the board as its
`PrimaryScrollController`. Back on Machines or Settings returns to Agents
first; on Agents it is as before (background while watching, else leave), and
the board's selection mode still takes it first.

Code outside the shell selects a root tab through `HomeTabs`
(`ui/core/home_tabs.dart`), which the app hands to the shell and to
`DeepLinks`; the switch is the tab bar's (fade, remembered), and selecting the
tab already showing does nothing (it does not scroll the board). The summary
notification (`N agents need you`, `herdr://agents`) selects Agents and goes
back to the shell. Why: it used to land on whatever tab the app was left on,
so the person tapped "agents need you" and saw Machines. Going back is the way
Back goes (`maybePop`, one route at a time), never `popUntil`: a screen that
asks before it closes (the machine form with unsaved input) asks, and if the
person keeps it, it stays with the tab waiting under it. Why: a notification
tap must not throw away a half-filled form, and the form already has the guard.

A link that cannot be followed (unknown machine, switched off, unreachable,
agent gone, not a herdr link) moves nothing: it says why in a toast over the
screen in front, and the toast's button opens the tab where the next step can
succeed: `Open Machines` for a machine to add, switch on or retry (Enable and
Retry live there), `Open Agents` for an agent that is gone or a link the app
cannot read. The button goes back the same guarded way, and is left out when
that tab is already in front. Why: never a dead end, never a silent loss; a
failure used to close everything, form included, and offer nothing.

Under reduced motion `showAppSheet` opens and closes with no animation (drag to
dismiss still works) and the page transition is a `Motion.fade` cross-fade: no
slide, no parallax, the edge-swipe back kept. Route durations have no context,
so they read the OS flag; the transition itself reads `Motion.reduced`.

### The terminal follows the theme

A pane is drawn on paper in the light theme and on ink in the dark one
(`TerminalPalette.light/dark`, `context.terminal`); Settings > Look > Dark
terminal keeps it dark on paper. The ANSI parser always yields the dark
`TerminalColors`; `TerminalPalette.recolor` turns a row's runs into the
palette's when the row is prepared (the dark palette returns the run itself, so
it costs nothing). On paper, the 16 ANSI colours are darker hues that reach
4.5:1 on white, text with a background of its own and no colour picks the
default that reads on it, and any text below 3.5:1 against its background is
pulled toward black, so a TUI that chose pale greys for a dark screen stays
readable.

### Wrap keeps tables whole

Wrap re-flows prose to the phone's width. A row of a table or a box (line
characters, a markdown or ASCII table: `table_lines.dart`) is never cut, since
cut in pieces it means nothing; when one is wider than the view, the view
scrolls sideways for it, and the agent swipe stands aside, as it does for
anything that scrolls sideways.

### What survives a launch

The theme, the root tab the app was left on, Smooth text, the terminal font and
wrap, and the agent screen in front with its view (`frontAgent.v1`): it is put
back once, at once and without the slide, as if the app never closed. A
session the phone has not listed yet is waited for, up to 8 s, while the board
is in front and untouched, then comes in with the page transition; if it never
comes, or the person moves on first, it is forgotten. Going back to the board
forgets it too. The view chosen with the toggle and the drafts last only the
app run. The tabs the app used to keep are read once, to carry
the terminal that was in front over, and deleted. Also,
in private cache files and never in preferences, the last transcript of each
agent session (`TranscriptCache`: it opens at once, as a saved copy, until the
keeper has answered).

## Checking a screen

`test/support/shot.dart` renders a widget on a Galaxy-A51-sized surface with the
real fonts and writes a PNG. Look at it in light and dark, with realistic data
and with worst-case data (long names, one-letter names, zero and one item,
Vietnamese diacritics), before calling a screen done.
