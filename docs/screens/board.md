# The board (Agents tab)

How the Agents board shows, sorts, answers and reviews agents.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

## Blocked prompts

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

A card that stops waiting (answered, or answered elsewhere) goes to its new
section at once and leaves a gap of its own height that closes over
`Motion.expand` (`AgentFolding`), so the next question glides up under the
thumb instead of jumping by a whole card; reduced motion skips the gap.

## What needs you: one set

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


## Selection mode (batch actions)

A long press on a card or row selects it; taps toggle; the header reads `N
selected` with All and Cancel; the tab bar and the triage pill step aside and
Stop, Message and Close take the tab bar's slot in the same pill (the Dock
lane, cells shaped like tab cells, contents cross-faded), so the bottom keeps
its shape and the actions are where the tabs were. Picking ends when the board
is left (another tab, or Machines through the connection strip) unless a batch
action is still running. Why: the tab bar was hidden on every tab while the
board was picking, so Machines and Settings had no way back. Every action goes
through a confirm sheet built from live data: targets, skipped ones with the
reason, and a count in the button (`Stop 3 agents`). A blocked terminal
agent is listed under `Waiting for an answer (skipped)` and is typed into only
if `Send anyway` is switched on (off by default); a blocked agent session never
is. Results land in one toast (`Stopped 3 · 1 failed: build-box offline`).

## Starting and duplicating

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
  are live) while the app is in front, from any tab or pushed screen. By key,
  not by count: an agent that went out of reach stays known as waiting
  (`AttentionSet.waitingKeys`), so a Wi-Fi to mobile handover, which empties
  the set and fills it again with the same agents, is quiet (comparing counts
  cued every agent already waiting), and one agent answered while another
  starts waiting is felt though the count stayed the same. Not during the
  first 3 s after start-up or after resuming (the fleet catching up is not
  news), at most one per 2 s, nothing for an agent that stops waiting. The
  Agents badge and the triage pill's count roll when they change (`RollText`,
  `ui/core/roll_text.dart`: only the changed digits move, up when the count
  rises, over `Motion.settle`); the badge (`CountBadge`) arrives and leaves with
  a scale. Reduced motion changes them at once.
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
- **Glance notification**: the quiet `Watching N agents` notice carries
  `2 need you · 3 working`; a terminal agent's needs-you notification shows the
  question and the command and offers up to two buttons for the options that
  are not gated (docs/ALERTS.md).
