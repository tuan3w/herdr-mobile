# Agent session screen (ACP)

The chat view of an agent session: transcript, docks, sheets.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

## Agent session screen (ACP)

Slim bar like the pane bar (status glyph by phase, title over
`agent · machine · folder`, a tap on the title area opens the agent
switcher (`docs/screens/agent-screens.md`), `Session options`, which holds the
session overview and `Show terminal` for a followed pane's chat); plan header (`1 of 3` + the
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
same reducer) under the link strip's `Updating…` / `Showing the copy saved today at
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
(`AgentSessionView.delivery`): `Will be queued until the turn ends` (pi, omp
before it takes steering, or anything already waits: the order is kept) or
`Goes into the turn. Hold Send to send it after.`
(Claude Code, Codex, omp with steering, and every agent in a terminal);
nothing when it would go out at once. The two intents of a mid-turn message
are therefore a tap (now: into the turn) and a hold on Send (after: it waits on
the phone, where it can be edited or taken back, like any queued message). The
hold is only offered where a tap would steer; where a message waits anyway a
hold is a tap. The send button never moves: it becomes Queue (a plain
send for the steering agents) and Stop is its own round, neutral button to its
left, drawn while a turn runs and deaf for `tapGuard` (450 ms) from the moment
it appears, so the tap that started the turn, or the second tap of a double
tap on Send/Queue, cannot cancel it (it cannot reach it either: a different
place). What
waits shows above the field as soft rows, oldest first, text cut to two lines
(through `visibleText()`), three at most and `N more queued` for the rest. A
tap opens a row in a sheet (edit, Save, Remove; it says `Already sent` when
the turn ended meanwhile; the edit is a sheet, not the field, so a draft in the
field is never overwritten and an edit keeps its place in the queue and its
attachments), the cross (44 dp) removes it. The queue goes out one message at
a time when the turn ends; after the person's own Stop it goes out as soon as
the turn has stopped, all of it as one message (text joined by a blank line, in
the order sent, then attachments), because stopping a turn is going on with
what was queued behind it. A failed turn, a turn stopped from elsewhere (not
for an agent in a terminal, see below) or a refusal holds the messages: one line (quiet tone; the refusal itself is already
in the link strip) says why, with `Resume`. Steered messages just appear as the
user's row. Haptics: `sent` when the session took the message (sent, steered,
queued or held), `failed` when it did not or an attachment cannot be made; see
"Send haptics follow the outcome".

**An agent in a terminal** (`ObservedAgentSession`) takes the same composer:
Send types the message into the pane at once, as the agent's own Enter does
(omp steers it; Claude Code and Codex read it after the current tool call),
and a hold on Send keeps it on the phone, in the same rows, to edit or remove,
until the pane has stopped working. Three differences, each with its reason.
(1) Before anything is typed into a pane that is working, the screen is read
(`_screenAsks`: omp's approval and plan review, the generic prompt detector, the
question tool): a dialog that opened since herdr last said `working` would take
the text and the Enter as its answer, and `1. Yes` is the default of most. It
refuses with `The terminal is asking something. Answer it first; the message
wasn’t sent.`, and the text goes back to the field. (2) A message typed in
goes to the agent's own queue or steer buffer, where the phone can neither
edit nor take it back, and the chat shows it only when the agent writes it to
its log (Claude at once, as `queue-operation`; omp when it injects it, after
the tool batch; Codex: UNVERIFIED). Until then it is a quiet row at the top of
the queue list (`QueuedState.sent`: arrow glyph, `Sent to the terminal · not
read yet`, no cross, no edit sheet, not counted in `N more queued`), so a
message that left the field is never nowhere. The row goes when the log shows
the message (each row counts the ones still ahead of it), or when the turn has
ended without it, and then the link strip says it is not in the log
(`_confirmSent` keeps waiting while the turn runs). The hold on Send is the way
to a message the person can still change. (3) What waits goes out when
the pane stops working, whatever stopped it: the phone cannot tell a turn
stopped in the terminal from one that finished, so it never holds the queue
for that (an ACP session does). After the person's own Stop the messages go
together as one, as there. A pane that needs the person (`blocked`) takes
nothing; the messages wait. The session is not dropped for being unused while
messages wait in it, and the queue is in memory only, like any other. It is
not sent while the app has no connection to the machine (the background
profile): it goes when the phone is back. That Enter steers in omp, Claude
Code and Codex is the owner's check on a device; the phone's reading of a
screen for a dialog is covered by tests, not measured on a real agent.

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
`StatusPanel` in the link strip: `Sign in on the machine`, the agent's own words,
the method names, the agent's login command when it sent one (mono, copyable),
a primary `Open a terminal on <machine>` that starts a plain shell workspace
in the session's folder (`SessionLauncher`, no command typed) and opens it,
and `Copy command` / `Retry` (a connection that failed for the login). The
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
  person's permission (not a call the agent only skipped: omp marks a `wait` it
  interrupted or that had nothing to wait for as an error, 48 times in one session,
  and `toolSkipped` keeps those in the fold, cancelled, with their text), a stop row and a note are ordinary rows after the
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
  files, `N more` (then `Show less`), so 300 files stay lazy. A tap opens the
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
`retrying 2 of 5`), `Needs you · 7 tools` in `blockedText`, `Explore ·
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
subagents cost the ones on screen. An observed session has the same sections
(`observed_roster.dart`): Running, Waiting, Done (failed first, newest first, 8
shown, `Show N more`), with Running first (omp names every subagent of a `task`
call pending at once, so Waiting first would bury the ones that run); a running subagent whose job the log lists has the held
stop of the background sheet (`Ask to stop` for omp, which can only be asked) and
the sheet has one `Stop all` for them (`BackgroundStopper` and the controls in
`background_controls.dart` are shared with the background sheet; `Stop all` asks
for subagents only, in one message). The chip says `6 running` (the total is in
the sheet title), or `66 subagents` when none runs, with a `+` while only the end
of the log is read (the sheet then says so and offers `Load earlier messages`);
with the link down it says no more than the count, and the rows say `Was
running`. A subagent is matched to its job by name (Claude: by the agent id of its log); one with no job listed
(Codex, a synchronous omp `task`) has no stop control. Why: a swarm of 24 reviewers left the running ones at the
bottom of 66 oldest-first rows.

*Drill-in* is a pushed screen (`SubagentRunScreen`): a bar with the description
and `Subagent · <type>`, a state strip with the same live line (without the type,
the bar has it), then either the **conversation** (Claude:
the same `TranscriptView` over `SubagentRunSession`, an `AgentSessionView` over
the run that is read-only and marks the run's transcript as a turn in progress
while it runs; no fork of the transcript code) under the pinned prompt (`Asked
to`, `asked_to.dart`: Markdown flattened to three lines of prose, a tap shows it
whole as Markdown with tappable paths and links, bounded to 40% of the screen), or the
**summary** (omp and Codex over ACP send no conversation): one line above it
says `Summary only.` (the same slot shows `Loading…` or the retry row, so
nothing moves when a read ends without a log), the figures it reported (model, tokens, cost, progress), what it was asked (Markdown),
what it is doing, its recent output (mono, 5 lines of 300 characters at most),
the retry or note, why it stopped and its result. omp's run gets the
conversation too when its own log on the host can be read (best effort, SFTP,
AGENT_SESSIONS.md "omp subagent transcripts"): the same `TranscriptView`, with
one caption row under the pinned prompt (`LogOriginNote`: `From omp's log on the
host`, plus `Earlier part not shown` when a cap cut the start). While that first
read runs the summary has a `Loading…` line (`BusySpinner`); only a connection
failure shows `Couldn't read the log · Tap to retry` (44 dp row); a log that is
missing, unreadable, of an unknown version or not a conversation leaves the
summary as it was, with no error line. The screen asks for the log only while it is open
(`watchSubagentLog`). No composer. The request a
subagent asks is answered from the same dock, above which one quiet line says
`From subagent: Explore` (`OriginLine`; the hold rules are untouched, and the
lead-in sentence is taken from the subagent's own transcript, not the main
agent's); the run's own screen shows only its requests. Back returns to the
scroll position the person left.

The first frame of a conversation plans only its newest 120 items while the
subagent runs (`firstFrameStart`): a subagent's conversation is ONE turn of up
to 2000 items, so planning by turns could not skip any of it, and the open log
parses every message. The rest is prepared in pieces of 120 items between frames
(`PlanWarmup`, `live: true`) and joins without moving the view. A finished
turn is never cut (its fold line would show wrong figures). Measured on the
desktop only (2,001 items, JIT): 43-91 ms for the first frame before, 2.4-3.7 ms
after; not measured on a phone.

**Session overview** (`session_overview.dart`,
`session_overview_model.dart`). `Session overview` in the options sheet
opens a sheet (`showAppSheet`: it stops below
the status bar and scrolls when it is taller than the room). In order: the status in words and how long
(`Working · 4 min`), `Goal` (the first message, three lines), `Plan · 1 of 3
done` with a thin bar and the step in progress, `Changed · 12 files +310 −42`
(the files of every turn merged by path, eight, then `N more` in steps of 16;
a tap opens the file's diff in place with `ChangedFileRow` and `DiffPanel`),
`Commands · 14 · 2 failed` (five: the failed ones first, then the newest, mono,
a failed one with the failed disc and `exit 1` muted beside it: the disc and
the `2 failed` count are the sheet's only red, so they do not compete with
`Needs you`; a tap shows all of the command),
`Subagents` (one row into the roster), `Mode and model` (a dangerous mode's
name and warning icon in the danger tint, its reason muted), `Context and cost` (a thin bar, `182k of 200k
tokens · 91% of context`, the cost with its currency, the last turn's tokens)
and `Needs you` (what asks, `From subagent: …`; a tap closes the sheet,
the dock is under it). A part the session has nothing for is absent, never a
placeholder. The transcript parts come from the per-turn summaries the folds
already compute (`overviewOf`, memoized per transcript list) and the sheet
rebuilds only when a list it reads is replaced, so a streaming answer costs it
nothing. **Context warning**: from 85% (`contextWarnAt`) the bar's subtitle
line adds `Context 91%` in `dangerText` (the words, at weight 600, next to the
place line, which gives way first); nothing below that and nothing without a
window size; at the same point the overview's bar takes the working colour
and its words their weight (a nearly full context is worth a look, not a
failure: red there outshouted what needs the person).

**Content the agents send** (`content_blocks.dart`
and the `content_*.dart` files). Every block that is not Markdown text goes
through `ContentBlockView`, in an agent message, in the person's own message
(`UserRow`) and in a tool call's output; every string through `visibleText()`.

- **Pictures** (`content_image.dart`). A block with base64 `data` shows an
  inline preview: its aspect, at most 220 dp high and as wide as the column,
  never more than twice its natural size (a 48 px icon stays an icon),
  `Radii.md` with a hairline, and a tap (44 dp at least) opens the photo
  viewer (below) on that picture, among the thread's other pictures
  (`ThreadPhotos`, read at the tap; `photo_thread.dart`). While it
  decodes a quiet 120 x 96 box with the picture icon stands in (no spinner;
  the one exception is below: a picture the person tapped to load).
  A screen reader reads `Image, image/png, chart.png` (the name is the last part
  of the uri, when there is one). Data that cannot be drawn degrades to a line
  with the reason in plain words: `The picture data is not valid base64.`, `The
  picture is not an image this app can read (image/jpeg).`, `Too large to show
  here (14 MB).`, `The picture is empty (0 × 0).`, `The agent sent no picture
  data.` Over 12 MB decoded is refused before any decoding.
- **Memory.** Base64 longer than 64 KB is decoded in another isolate
  (`compute`); the bitmap is shrunk to 1024 px on its longest side while the
  codec decodes it, so the full bitmap never exists. Previews live in
  `ImagePreviewCache` keyed by what the picture IS (its data; a log picture's
  cache key), so a re-attach, which builds new blocks with equal data, finds the
  preview it already decoded: eight are kept once nothing
  draws them, the least recently used is disposed first, and one a row is
  drawing is never disposed. A 200-picture transcript builds the rows near the
  screen, so it holds those plus eight, not 200 (test: `content_blocks_test.dart`).
  The viewer decodes its own copy (2048 px, the file viewer's cap) and disposes
  it with the screen.
- **Pictures of a terminal-log chat** (Claude Code, Codex, omp: the host does
  not send picture bytes with the log; `LogImageView`). A quiet line, `Image ·
  105 KB · image/png` (the size first: at 2x text the type may wrap or be cut,
  and the size is what says whether a tap is worth it) with `Tap to load`. A tap
  fetches once however often it is repeated, with the one spinner in the 120 x 96
  frame (a wait the person started); a failure says why with `Tap to retry.`; a
  picture over 12 MB, a log the host says is not what it was, and a view that
  cannot fetch (`Not available here`, a subagent's transcript) have no retry. A
  picture the phone already holds (`DiskCache`) simply shows: its first frame is
  already the picture frame (no chip first, no spinner: nobody tapped), so a row
  never changes height after it is first painted. A retry after the row was
  scrolled away and back asks again; it does not show the old failure.
- **Privacy: nothing is fetched on its own.** (Except the line above: a log
  picture is fetched only on a tap, or read from the cache.) A block with only a `uri` is a line, `Image ·
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
`Waiting for bg_6 · 4h 36m` and the board row `idle · jobs 4h` (not `Working`), the composer offers Send, and a
strip above it (`n running in background`, plus `omp continues by itself when
it finishes` where a finish wakes the agent) opens the sheet. The sheet lists
Running and Finished (`failed` first, five, `Show more`), one row per task with
a Lucide kind icon, the first command line in mono through `visibleText()`, and
a Stop that is a hold (`HoldToConfirm`; a tap shows `Hold to stop`; TalkBack
primes then sends). Where the route is a message (omp) the chip reads `Ask omp
to stop` and the footer says so once. `Stopping…` uses the one allowed
`BusySpinner` for at most 12 s, then `Could not confirm` + `Retry`. After Stop
ends a turn with jobs left, one toast `Turn stopped · 1 job still running` with
`Open`. The strip is hidden in the compact layout (the bar chip carries the
count); it appears and goes without animation. Why not `Collapse` like the
link strips: it sits on the composer, and jobs start and end at the agent's
pace, several a turn; a fold would slide the composer under the thumb each
time. The link strip under the bar and the rare `Needs you` strip (a request
waiting for the link) do fold in and out with `Collapse`, like the pane's
banner.

**Continue and Past sessions** (`continue_button.dart`, `ui/features/history/`).
An ended session whose keeper is gone shows its saved transcript read-only and the
link strip says `Session ended` with `The agent kept the conversation.` and a
`Continue` button (the one allowed `BusySpinner` while it resumes; a failure is a
toast with the host's words and the button comes back; evicted sessions keep
`Take over`). `Past sessions` (a row in the new-agent-session form, which passes the
typed folder; the board reaches it through its `+`) lists what an agent
remembers on a machine: machine chips when more than one is online, agent chips,
a `This folder` chip when the opener passed a folder, search past six rows. Row =
title (`Untitled session`), folder tail, `5m ago · 14 messages`; whole row is
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
