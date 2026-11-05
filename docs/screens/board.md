# The board (home)

How the Agents board, the app's home, shows, sorts, answers and reviews
agents, and how Machines and Settings are reached from it.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

## Calm by default

Most people run their agents on auto-accept, so "needs you" is rare and the
board's common job is the glance: does anything need me, is everything alive.
It answers both from the header and keeps everything else quiet.

- **One status line, one count.** Under the title: `2 need you · 3 to review ·
  3 working · heard just now · 1 not connected` (`nothing running` when
  nothing waits or works). The needs-you part is the only loud words (`blockedText`); the
  `Needs you` header carries no count of its own. Why: the
  count was said four times on one screen (a filter chip, the section
  header, a floating triage pill and the tab badge), and every repeat is
  chrome that costs the focus a glance is made of. On a narrow phone the
  line takes a second line (the header grows by one subtitle block) rather
  than cut its end: `1 not connect…` hid the part that mattered most. It is
  measured with the longest `heard` the minute can reach, so the header does
  not change height as the minutes tick; counts are tabular figures.
- **No filter chips, no triage pill.** The chips repeated the section headers
  and the pill repeated the count. The triage walk is `Answer one by one` on
  the Needs you header, shown when more than one agent waits (with one, the
  card in front is the whole walk). The header keeps the action's 44 dp box
  when it has none, so a second agent starting to wait moves nothing under
  the thumb.
- **One decision in front, every other agent a row.** The first agent of
  Needs you that can be answered is an `AgentCard` with its answers (and,
  when no question is read, the end of its terminal and `Reply…`); every
  other agent, waiting or not, is a one-line `AgentCompactRow`. There is no
  density setting. Why (owner decision): the `Cards` density (`BoardDensity`,
  Settings, Look, Agent list) drew eleven idle agents as bordered cards each
  with `Reply…`, and the owner could not tell what to look at. It went with
  its persistence; a value an older version saved (`app.density.v1`) is never
  read. The card only ever holds a live waiting agent, so it never changes
  status in place (its arrival wash, `Motion.arrival`, went too) and never
  swipes to review.
- **Needs you never folds.** A section's fold is restored after the process
  is reclaimed (`folded-sections`: status names, one per line; a name it
  does not know is ignored, and the 0.1.45 int and the 0.1.47 project keys
  lived under other ids, so nothing restored can throw); a folded Needs you
  would hide the one loud section.
- **No bar under home.** There is no tab bar (it held Agents, Machines and
  Settings). Why (owner decision): most of the time the person cares about
  agents, not machines; home is the app, chrome costs focus, and the bar
  covered the end of the list. The list ends `Gap.xl` above the bottom inset;
  the batch bar is the only bottom bar, and only while picking (the list then
  keeps its room). Re-tapping the Agents tab used to scroll the board to the
  top; that gesture went with the tab, and nothing replaces it: the calm
  board is short (Idle folds, sections fold) and a fling is one gesture,
  while a tappable title would be a target nobody could see.
- **The header: the machines chip on the left, `+` and Settings on the
  right.** The chip (`_MachineHealth`) says `4 of 5 machines` with a mark:
  the `LinkDot` of the machine that most needs the person (`worstLinkState`),
  the same shape its row has on Machines: the quiet filled dot when every
  machine that is switched on is online, the working ring while one
  connects, the blocked ring with a dot for one to fix or approve. A switched-off machine is neither a
  problem nor online, so it is not counted (`AgentsOverview.enabledCount`).
  It reads as status, not a button: no fill at rest (a fill only under the
  press), `Type.label` in `textSecondary`, a 44 dp target, and its mark starts
  on the large title's edge. A tap opens Machines. The gear (`Settings`)
  carries a quiet accent dot while a newer version waits (`CircleButton.mark`,
  `update available` to a screen reader). Two trailing actions, the budget;
  `Past sessions` is a row of the `New agent session` form. Scrolled, the bar keeps the chip and the two buttons and no
  compact `Agents` title (`compactTitle: false`): centred, it collided with
  the chip at 320 dp, and home needs no name. Before the first machine the
  header holds the gear alone: there is no fleet to sum up and nothing to
  start.
- **Machines and Settings are pages over home** (`HomePages`,
  `ui/shell/home_pages.dart`), with Back in their bars; Back returns home. A
  quick second tap opens one page, not two. The board under a page does not
  tick, read previews or list sessions (its `TickerMode` is off), and keeps
  its scroll and its picked set for the return.
- **The connection strip stays a strip** under the title, not words in the
  status line: it carries the next step (`Retry`, `Approve`, or Machines),
  which the status line cannot. The status line still says `N not connected`.

## Sections by status, newest first

Owner decision. 0.1.46 and 0.1.47 grouped the board by project (a repo with
its worktrees), rows in the order they were started, with a Cards density.
On the phone the owner could not tell what to look at: 3-day-old agents sat
on top and 12-minute-old ones last, one repo split into a group per machine,
and every idle agent was a card. Asked which order finds an agent fastest,
they chose status sections, newest first, rows instead of cards. The board
reads, top to bottom (`boardLayout`, `boardOrder`, `agents_grouping.dart`):

- **Needs you**: `AttentionSet`'s order, what can be answered first, longest
  waiting first, then what is out of reach. The one decision card, rows for
  the rest, `Answer one by one`, never folded. Not newest first, though the
  owner said "newest first within each": a new waiter on top would replace
  the card in front under the thumb; joining below it moves nothing, and the
  triage walk and the notifications use the same order.
- **Working**, **To review** (finished, not reviewed: the status line's
  words) and **Idle**, each newest first by when its state began
  (`compareNewestFirst`): a terminal agent's `since`; a session's turn start
  while it works (its last event moves with every event, and the row would
  move with it), else its last activity. A time within the last day first,
  then no known time (it may be minutes or months old), then older. To review
  lists what can be marked before what is out of reach. Unknown comes last,
  by machine and pane. Ties keep machine and pane order.

Rows move when their status does (a finished agent leaves Working for the top
of To review); that is the order the owner chose. Headers: `Needs you`,
`Working` and `To review` carry no count (the status line says it); `Idle`
does. Every section but Needs you folds on a tap.

**Which feature, on every row** (`agentWhere`): `herdr-mobile · fix/login ·
omp`, the repo (herdr's `repo_name`, else the folder's last part), the branch
(`MachineConnection.branchOf`) or, until it is read, the checkout's folder
(left out when it is the repo's own name), the agent kind, and the machine
when the board spans several. A part the title says, or one already said, is
left out. The line ends in an ellipsis and the time is the row's trailing
slot, so a long branch cuts the end of the line, never the time. The peek and
the reply sheet show the same line (`AgentRowData.subtitle`); a session's is
`sessionWhereOnBoard`.

**To review lives in the status line.** `3 to review` (quiet: `textSecondary`,
`secondaryStrong`, a dotted underline, warming to `text` on pointer-down; a
button read as `3 to review, select them`) selects exactly the finished agents
that can be marked (`AttentionSet.toReview`), replacing any earlier pick, and
opens To review if it was folded. The selection bar's `Reviewed` (a check in
Stop's ring) marks the picked finished agents at once, no confirm sheet,
under one toast with one Undo (`markAllReviewedWithUndo`, the swipe's group),
and ends picking. Out-of-reach ones are said, not counted: `3 to review, 1
offline`, or `2 offline to review` (not a button) when none can be marked.
Why (owner decision): a `Mark reviewed · Select all` line on a header was one
more row of chrome; the count belongs with the other counts, and selecting
first shows what will be cleared. The line is 22 dp high, so
`SliverLargeTitle` hit-tests its subtitle from a band (`_HitBand`): `kMinTap`
above the first line's middle, into the title block that takes no tap, and
the gap under it, each touch taken into the nearest line. Measured in
`batch_board_test` (a 44 dp band with the line on two lines).

**The idle fold** (`idleShown`, 5): Idle shows its five newest rows and folds
the rest behind one `N more idle` line after them, with the names of the first
two it holds; opened, it reads `Show less`. Not kept across launches. A row
the person has seen during this look, in Idle or in any other section, never
goes into the fold until they look afresh (the board shown again, the app
resumed): `idleFoldFor` and the board's `SeenRows`. Why (owner decision, a
predictable board): worked out on every build, the fold hid a row the moment
another agent went idle, under the person's eyes. Rows the person never saw,
such as a second machine's agents arriving after the board opened, fold as
usual: holding the fold as it was at the first build would have left a whole
machine's idle agents unfolded until the next look.

**Branches** come from `MachineConnection.loadBranchesOnce`: one
`worktree.list` per repo with several open checkouts, at most once per
machine per app run, after the first frame that shows a row in such a repo.
Never per rebuild (the board checks `branchesAsked`); no timer. A failure
leaves the checkout's folder on the row. A checkout opened later is named by
its folder until the machine screen or the start form reads it. The board
rebuilds when a branch is learnt (`AgentsOverview.branches`).

What went with project grouping: group headers and their summaries, the
per-project fold (`folded-groups`), start order (herdr's pane counters and
`AgentSessionView.startedAt`), `Place.repoRoot` (a group's key) and
`agentPlaceNames` (the switcher's own naming: `agentWhere` already tells
worktrees apart).

The swipe walk (Needs you, then To review), `agentsWorking`, the title
switcher (the sections and rows as the board shows them) and batch targets
read the same layout (`boardLayoutOf`, `groupByStatus`), so their order is the
board's.

## Blocked prompts

A blocked card shows the question and, under it, what the agent asks to run or
touch (`PromptInfo.subject`) in mono, three lines at most; the reply sheet shows
all of it. The subject is the largest text on the wash (`Mono.input`) and the
question a secondary line above it. Why: the command is what is approved, and
in `Mono.base` under a `Type.prompt` question it was smaller than both the
question and the answers.

Answers are 44 high chips, labelled with the agent's words, number included
(it names the agent's row; the keys come from the option). They are grouped
(`ReplyLayout`, `reply_chips.dart`): the answers that allow, then a `Gap.lg`
and the ones that decline (`isNegativeReply`), drawn quiet: no fill at rest
(a fill made `No` look like one more yes) and a small leading ✕ in
`textSecondary`, so it still reads as an answer to tap; it keeps its 44 and
its one line on the card. On the card a standing grant (`standingPermission`) is not a chip: it
waits behind `N more…` in the reply sheet, which shows every option in the
same groups and still holds it. Why: in the agent's order as identical fills,
`3. No` looked like the `2. Yes, don't ask again` above it, and a permission
that outlives the answer was one glance-tap away. The card reserves exactly
the grouped chips' height (`ReplyChips.heightFor`). A risky answer is held, not tapped: press
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
(450 ms, `Dwell.tapGuard`, `ui/support/tap_guard.dart`) is the one guard: a permission request, a
question, the triage sheet's next agent and the session composer's Stop (which
sits beside Send) take no tap for that long, and their answers are dimmed
(`TapGuardState`). On the board, `SettleGate` closes the same way for every
card's answers when a card above the last answerable one came, went or was
re-ordered (a card appended below moves nothing). In the triage sheet an
answered agent stays in view with `Sent: ...` for 700 ms before the walk moves
on, the last answer shows `All clear` for 900 ms, and `esc` / `enter` move
through a menu without ever moving the walk. A new permission request or
question gives one `armed` haptic; a tap that lands inside a guard gives the
`failed` haptic.

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

A card that stops waiting (answered, or answered elsewhere) goes to its section at once and leaves a gap of its own height that closes over
`Motion.expand` (`AgentFolding`), so the next question glides up under the
thumb instead of jumping by a whole card; reduced motion skips the gap.

## What needs you: one set

`AttentionSet` (`data/repositories/attention_set.dart`) is the one answer to
"does anything need me?". Every surface reads it: the board's status line,
the triage sheet, the board's Needs you and `to review`, the Machines
page's chip, the arrival haptic and the notifier's `need you` count. Why: each used to count for itself, and they disagreed (a badge of
3 beside a pill saying 1, a sheet saying `All clear` while a session waited, a
Machines chip counting offline panes).

- **Needs you** = terminal panes blocked on a live machine
  (`FleetAgent.needsYou`) plus agent sessions blocked on a permission or a
  question whose machine and link are live. **To review** = finished and not
  reviewed, same reachability. Something out of reach cannot be answered or
  marked, so it is not counted; where it is listed (the board, last known) the
  Needs you header says `N offline` and the status line `N offline to review`
  instead of a count that would include it.
- **Order**: longest waiting first, panes and sessions mixed (a wait whose
  start is unknown last), then machine and key. The board's Needs you section
  and the triage walk use this one order.
- **Computed once per change** of the fleet or the sessions, and listeners
  hear only when a key or the order changed. Why: the tab badge, the cue and
  the board each built and sorted every agent on every notify, three passes per
  change on the UI thread.
- **The count is loud for needs you only.** The status line says the
  needs-you count in the blocked colour; finished work is said quietly
  beside it (`3 to review`). Why: three finished agents read
  as
  three questions in the loud colour, and attention must be the only loud
  thing.
- **One board, one place per agent.** Agent sessions sit with the terminal
  agents (a session row in the section of its status). Why: a separate
  sessions
  section jumped above the terminal cards whenever a session started or
  stopped waiting, moving every answer under the thumb, and "what waits" had
  two places to look. A session row still only tells; it is answered in the
  session for now.
- **The triage sheet walks the set** (`showTriageSheet`, from `Answer one by
  one` on the Needs you header): a terminal agent
  with its chips and composer, an agent session with what it asks
  (`blockedSummary`) and `Answer in the session`, which opens it over the
  sheet; the walk moves on when the person comes back. `All clear` only when
  the set is empty.
- **Machines page**: a machine's chip is its share of the set; an offline
  machine has none (its row already says offline).
- **One agent, one row.** An agent that runs in a herdr pane and is followed
  through its log (`ObservedSessions`) is not an agent session on the board:
  observed sessions are made only when a screen opens one, and keepers run
  outside herdr panes, so the board never lists the same agent twice.


## Selection mode (batch actions)

A long press on a card or row selects it; taps toggle; the header reads `N
selected` with All and Cancel (covering the chip and the buttons); Reviewed,
Stop, Message and Close come up in a floating pill at the bottom (the Dock lane,
`BatchActionBar`, with its own scrim; a fade in and out), the only bottom bar
home has. A page pushed over the board (Machines through the connection strip,
an agent from a notification) leaves the picked set waiting: Back always
comes home, so nothing is left hidden. (When there were tabs, leaving the
board ended picking, because the tab bar was hidden while picking.) Every action goes
through a confirm sheet built from live data: targets, skipped ones with the
reason, and a count in the button (`Stop 3 agents`). A blocked terminal
agent is listed under `Waiting for an answer (skipped)` and is typed into only
if `Send anyway` is switched on (off by default); a blocked agent session never
is. Results land in one toast (`Stopped 3 · 1 failed: build-box offline`).

## Starting and duplicating

**One `+`, one meaning: it starts what the list holds.** The board and a
machine's screen open `New agent session` directly (the machine screen's has
its machine chosen, and is dimmed while the machine is offline); the Machines
page's adds a machine. Same icon, same place (top right), no sheet in between.
`Past sessions` is a row of the `New agent session` form, and `Add machine`
lives on the Machines page (and the first-run empty state), not in
a menu on another page. Why: the `+` used to open a four-row sheet on the board,
start a terminal workspace on a machine's screen and add a machine on the
Machines tab, so the same mark meant three different things.

There is one start form, `New agent session` (an agent over ACP). The phone no
longer starts bare terminal workspaces: an agent already running in a herdr
pane still opens, in its terminal or its chat. Why: two forms for one job
drifted apart (what each remembered, what each accepted), and the agent form
is the one people use.

**Where in the repo: the `Checkout` row** (`create/checkout_field.dart`). Once
the typed folder (looked up 500 ms after typing stops, at once after a browse or
a recent-folder pick) is in a git repo, `worktree.list` fills a `Checkout` row
under `Folder`: `This folder`, one row per other checkout of the repo (branch,
`N working`, `not open in herdr`) and `New worktree…`, which reveals a
`Branch` filled with a suggestion in herdr's own shape (`worktree/brave-meadow-45e8`,
never a branch the repo has; change it or clear it, empty: herdr names branch and folder, branching from the folder's
current commit). Any failure of the lookup (not a git repo, untrusted repo, a
herdr without worktrees, offline) just leaves the row out; it is never an error.
Why: two agents in one checkout share its files; a
worktree keeps them apart, and creating one is never implicit (every start begins
at `This folder`, and only the typed folder is remembered). Start creates the
worktree first, then the session in it; if the session then fails to start, the
worktree stays chosen, so Start again reuses it instead of making a second.

`Start` returns to where the form was opened and shows a toast (`Open` opens
it); `Start and open` replaces the form. `Duplicate` (the pane options, the
session options) opens the agent form prefilled with machine, folder and agent
and an empty first message; nothing is remembered until Start. A pane's agent
is matched to the form's agents by name (`omp`, `claude`, `codex`, `pi`); one
the form does not offer (`aider`, `gemini`, a plain shell) falls back to the
agent last used on that machine. A sheet row that cannot be used shows its
reason (`SheetAction.unavailable`), dimmed.


## Micro-interactions on the board

- **An agent starting to wait is felt** (`ArrivalCue`, `ui/shell/`). One `armed`
  haptic when a new key enters the "needs you" set (`AttentionSet.needsYouKeys`:
  terminal panes on a live machine and agent sessions whose machine and link
  are live) while the app is in front, on home or any pushed screen. By key,
  not by count: an agent that went out of reach stays known as waiting
  (`AttentionSet.waitingKeys`), so a Wi-Fi to mobile handover, which empties
  the set and fills it again with the same agents, is quiet (comparing counts
  cued every agent already waiting), and one agent answered while another
  starts waiting is felt though the count stayed the same. Not during the
  first 3 s after start-up or after resuming (the fleet catching up is not
  news), at most one per 2 s, nothing for an agent that stops waiting.
- **Swipe to review**: a leftward swipe on a done, live row,
  or on a done, reachable agent session row (not while picking), reveals a quiet
  `Reviewed`; past the threshold, or on a
  flick, the row slides out and `markReviewed` (terminal) or
  `AgentSessionView.markSeen` (session, without opening it) runs with a `Marked
  reviewed` toast and Undo, `Marked 2 reviewed` for several in a row
  (`swipe_review.dart`). Undo is `unmarkReviewed` / `unmarkSeen`, which only
  restore that very finished turn. Springs, 1:1 tracking, rubber band at
  the end; screen readers get a `Mark reviewed` action.
- **Mark reviewed**: `3 to review` in the status line, then `Reviewed` in
  the selection bar (see "Sections by status, newest first"). It reviews the picked
  finished, reachable terminal agents and sessions at once under ONE toast,
  `Marked 4 reviewed`, whose Undo restores them all (and joins a swipe's
  toast still showing). Per-device state only; herdr's own seen state is
  never touched. When a header's name and its actions do not fit one line
  (large text), the actions drop to their own line under the name and wrap if
  they must. Needs you keeps the room of `Answer one by one` (and chooses its
  line as if it were there) while only one agent waits, so a second one
  arriving moves no card under the thumb; at large text that is an empty
  44 dp line.
- **Glance notification**: the quiet `Watching N agents` notice carries
  `2 need you · 3 working`; a terminal agent's needs-you notification shows the
  question and the command and offers up to two buttons for the options that
  are not gated (docs/ALERTS.md).
