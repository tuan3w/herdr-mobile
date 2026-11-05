# Changelog

What changed for the person using herdr mobile, newest first. Versions follow
`0.1.x` patch releases; each section is the release notes of its GitHub
release.

## [Unreleased]

### dsh is one of the agents the app knows

`dsh` now has its name everywhere the app names an agent, next to omp, Codex,
Claude Code and pi, and Settings says where it opens: dsh runs in a terminal,
because the app reads no dsh session log yet. Nothing about the other four
changes.

## [0.1.50] - 2026-11-05

### Message an agent in a terminal while it works

Claude Code, Codex and omp running in a terminal now take a message while
they work. `Send` puts it into the turn; hold `Send` to keep it on the phone
until the turn ends.

> [!TIP]
> Try it: open an agent that runs in a terminal while it works, type a
> message and tap `Send`. Hold `Send` instead to queue it above the box; tap
> a queued message to edit it, or its cross to remove it.

- A queued message goes out when the agent stops working, one at a time.
  `Stop` sends what waits together, as one message. A stop in the terminal
  cannot be told from a finished turn, so what waits goes out then too.
- If the terminal is asking something (an approval, a plan, a question),
  nothing is typed: the text stays in the box and a strip at the top says why.
- If the agent has left the pane, or a message does not go through, what
  waits is held with `Resume`, in the order you sent it.
- A message sent into the turn shows in the chat when the agent reads it; for
  omp that can be after its current tool call.
- Not checked on a real phone with each agent: that Enter takes the message
  into a running turn in omp, Claude Code and Codex, and when Codex shows it
  in the chat.

![A chat with two messages queued above the box and a draft being typed](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.50/0.1.50-terminal-queue.png)

**Fixed**

- Pressing Send on the keyboard while an agent in a terminal works no longer
  shows a toast that it is working and sends nothing: it sends the message.

## [0.1.49] - 2026-11-04

### A waiting omp subagent no longer shows as done

A subagent that started a long background job and waits for it stays
`running` in the subagents chip and list. It used to turn `done` after about
30 seconds of silence, while omp still listed it as running.

- A subagent is `done` when omp says so: it reports the end and writes its
  result file. A quiet log no longer ends it; a recent write still marks it
  running.
- Claude Code and Codex subagents still go by the old 30-second rule.

**Fixed**

- With three subagents, one waiting on a 50-minute job, the chip said `1
  running` while the background strip said `2 running in background`. They
  agree now. Checked on the recorded files of that session; not measured on
  a phone.

## [0.1.48] - 2026-10-30

### The board says what to look at again

The board is back in sections by what each agent needs: `Needs you`, then
`Working`, then `To review`, then `Idle`, with the newest on top in each, so
the agent that just finished or just stopped is the first you see.

> [!TIP]
> Try it: tap a section's name, like `Idle`, to fold it; the fold is kept.

- Every agent is one row, except the first one that needs you, which keeps
  its card with the answers. Under each title, the row says which feature it
  is: the repo, the branch and the agent (`herdr-mobile · fix/login · omp`),
  and the machine when you have several.
- In `Needs you`, the agent waiting longest still leads, so its card does not
  change under your thumb when another agent starts waiting.
- The `Agent list` setting (`Compact` or `Cards`) is gone from Settings,
  `Look`: the board is always rows.
- `Idle` shows its five newest and folds the rest behind `N more idle`; an
  agent you saw while looking stays in view until you next open the board.
- The dotted "to review" count at the top still selects the finished agents,
  and `Reviewed` in the bar still marks them all with one `Undo`.

**Fixed**

- Idle agents no longer show as cards with `Reply…`, and one repo is no
  longer split into a group per machine.

## [0.1.47] - 2026-10-30

### Your agents, by project, in a board that holds still

What needs you stays on top. Below it, each repo is one group with all its
worktrees together, and each agent shows its task with its branch under it,
so the features of one repo sit side by side. Nothing moves unless you move
it: projects are in name order, agents in the order they were started, and
an agent that finishes only changes its mark.

> [!TIP]
> Try it: tap the dotted "to review" count at the top to select the finished
> agents, then `Reviewed` in the bar to mark them all; Undo brings them back.

- A project's line under its name sums it up, like
  `2 working · 1 done · 4 worktrees`; a project with one agent, or the only
  project, has no such line. Tap a project's name to fold it.
- Branch names are read once per machine each time the app starts, never on
  a timer. Until they arrive, a row shows its checkout's folder.
- The `N more idle` line keeps what it held while you look: an agent that
  goes idle stays in view until you next open the board.
- Swiping between chats and the agent list at the top of a chat follow the
  same order as the board.

**Fixed**

- 0.1.46 already grouped the board by project, in an order that moved
  whenever an agent started or finished; its notes did not say so.

## [0.1.46] - 2026-10-30

### A calmer home: the board is the whole app

The tab bar is gone and the board runs to the bottom of the screen. It says
how many agents need you once, at the top, and puts one question in front
with the command it wants to run as the largest text.

> [!TIP]
> Try it: tap the machine count at the top left to open Machines, and the
> gear at the top right (`Settings`) for Settings; Back returns to the board.

- The top line reads like `1 needs you · 4 working · heard just now`; on a
  narrow phone or with large text it takes a second line instead of cutting
  off how many machines are not connected.
- The first agent that needs you keeps its card; the others are rows under
  it, and `Answer one by one` walks them. Needs you can no longer be folded
  away.
- On a question, the answers that allow come first and `No` sits apart
  below them with a ✕. A "don't ask again" answer is in the full list
  behind `more…`, still held. The card's reply is a quiet `Reply…`.
- The filter chips and the floating pill are gone. `Past sessions` moved to
  the new-session form behind `+`, and the agent list density to Settings.
  A newer version puts a small dot on the gear.
- On Machines, a machine that is fine has a quiet grey dot; one connecting
  has a ring, one that needs you a ring with a dot, so it stands out even
  without colour.
- In Session overview, red marks only a failed command; a nearly full
  context turns amber.

Nothing in this release was measured on a phone.

**Fixed**

- Symbols agents draw in their terminals, such as Claude Code's
  `⏵⏵ auto mode on`, `⏺`, `⎿`, spinner stars and braille spinners, no
  longer show as empty boxes on the card and in the pane.
- A long machine address no longer leaves a gap in the middle of the cut.
- `Mark reviewed` (was `Mark all reviewed`) no longer squeezes the Done
  heading to `Do…` at large text.

## [0.1.45] - 2026-10-29

### Switch to the agent that needs you, from any chat

Tap an agent's title to reach any other agent without going back to the
board, and swipe sideways to walk only the agents that need you.

> [!TIP]
> Try it: in an agent's chat, tap its title (`Switch agent`); the last row,
> `All agents on the board`, goes back to the board.

- A small count beside the title says how many other agents need you. It
  never moves and adds no row to the chat.
- Swiping sideways now walks the agents that need you, then the finished
  ones, and swiping back always returns where you were, even after you
  answered one. At the end it says `All caught up`. The card that peeks in
  shows what the agent asks or did last, and where it is in the walk.
- Agents in several worktrees of one folder are told apart by their branch.
- The Agents board says when it last heard from your machines (heard just
  now, heard 3m ago), so a board that went quiet no longer looks live.
- In a page from your machine, the `✕` at the top (`Close page`) returns
  from any depth. The arrow (`Previous page`) goes back one page, and holding
  it lists the `Pages in this visit`. `Reload` moved into the `⋯` options.
- Tapping a row or card answers the instant your finger lands, and switching
  tabs is instant.
- An answer that needs a hold says Hold on its chip before you try a tap.
- An offline agent keeps readable text; only its status mark dims. Text
  fields have a clearer edge, and the floating bars lift in dark mode.
- Messages you type to an agent get suggestions and capital letters, and a
  password manager can fill machine passwords.
- Removing a machine needs a hold. Removing a queued message or remembered
  messages asks first, and a deleted quick phrase can be undone.
- Errors read as a plain sentence with what to do next.

Nothing in this release was measured on a phone.

**Fixed**

- A toast, pill or sheet dismissed while it was still arriving no longer
  jumps before it leaves.
- Pressing Send on the keyboard while the agent can't take a message no
  longer does nothing silently: it says why.
- The machine form's `Test connection` and Save no longer run at once, and
  the port field takes digits only.
- Errors no longer show internal codes or type names.

## [0.1.44] - 2026-10-29

### Queue messages while the agent works

In `herdr-tui`, press `Enter` while the agent is busy and the message waits
above the box as `↳`. When the turn ends it is sent, one at a time, as on
the phone.

> [!TIP]
> Try it: start a turn, type a message and press `Enter`. Press Backspace on
> the empty box, or click the queued row, to take it back and edit it.

- `Ctrl-C` stops the turn and sends what is queued at once; several messages
  typed meanwhile go as one.
- If the turn failed, the agent refused, or the turn was stopped from
  elsewhere, the queue is held (`Held · … · Enter resumes`); `Enter` on an
  empty box lets it go on.
- Leaving with messages queued asks twice; `/new` and `Ctrl-R` refuse. On exit
  each unsent message is printed as `Not sent:`. The queue holds 10 messages
  and lives only in that `herdr-tui`.
- On a very short pane the footer says `N queued` when there is no room to
  list them.

### A calmer desk client

Nothing in `herdr-tui` moves any more except the elapsed counter while a turn
runs.

- The working row is still: `● Working 12s · Ctrl-C stops`. The spinner, the
  changing word and the tips are gone, and a fold opens at once.
- `▲ Needs you` is said once, on its panel, and no longer pulses or repeats in
  the footer.
- Finished tool calls carry no `✓`, so a `✗` stands out. The rule above the box
  no longer carries the session title, and `ctx` shows from 60 %.

## [0.1.43] - 2026-10-28

### Selected text in the desk client is easy to read

Drag over text in `herdr-tui` and it gets a light band behind it, in its
own colours. On a light terminal it used to turn white on near-black.

> [!TIP]
> Try it: in a `herdr-tui` session, drag over some of the output.

- It needs the terminal to say what its background is. Where it does not, the
  old swap of colours stays; `HERDR_TUI_THEME=light` or `dark` tells
  `herdr-tui` which.

## [0.1.42] - 2026-10-28

[![Watch what's new · 1 change · 0:07 · 2.3 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.42/0.1.42-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.42/0.1.42-whats-new.mp4)

### Selected text is easy to see

Text you select in a pane now shows as a clear indigo band on the dark
terminal. Before, it was almost the colour of the page, so it was hard to
tell what you had selected.

> [!TIP]
> Try it: in a pane, press and hold on some output, then drag over it.

- The paper terminal is unchanged.

![A pane in the dark theme with a diff, a test line and a numbered list selected, shown as an indigo band](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.42/0.1.42-brighter-selection.png)

## [0.1.41] - 2026-10-28

### Videos play in the file viewer, and any file can be shared

A video in a folder opens as a card with its size and `Play`, copies to the
phone with a bar and plays with a bar to drag. Before, it opened as a hex
dump. Any file can also be handed to another app.

> [!TIP]
> Try it: in Files, open a video (an `mp4` will do) and tap `Play`.

> [!TIP]
> Try it: on any file, open `File options` and choose `Share or save…`.

- `mp4`, `mov`, `mkv`, `webm`, `avi`, `m4v` and `3gp` are videos. One up to
  24 MB starts by itself; `Cancel` stops the copy. `Save to gallery` keeps it
  in Pictures/herdr.
- `Share or save…` copies the file to the phone and hands it to the share
  sheet, so it can go to Drive, Files or another app. It is on the card of a
  file the viewer cannot show, and in `File options`.

### Select text in `herdr-tui` by dragging

Drag over text in a `herdr-tui` session, in a herdr pane too: the selection is
highlighted, copied when you let go, and the footer says how much. Since
0.1.36 a drag did nothing there, because the mouse belonged to clicks. A click
still opens a tool call, now when you let go, so a drag that starts on one
selects its text instead.

> [!TIP]
> Try it: in a `herdr-tui` session, drag across a few words of the reply.

- `herdr-tui update` keeps its progress on one line however narrow the
  terminal, so on a phone-width screen it no longer wraps into many lines.
- Ctrl-C during `herdr-tui update` stops cleanly: nothing is installed and no
  leftover folder stays beside the program.
- A failed `herdr-tui update` download says whether the network or the version
  is the problem, and a slow link that keeps delivering is no longer cut off
  after five minutes.
- The "newer herdr-tui is installed · Ctrl-R" hint goes away when the file is
  rolled back, broken or removed. Checked in a pty on Linux; macOS and the
  `wget` path were not tried.

## [0.1.40] - 2026-10-27

[![Watch what's new · 2 changes · 0:22 · 0.3 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.40/0.1.40-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.40/0.1.40-whats-new.mp4)

### The desk client has slash commands

Type `/` in a `herdr-tui` session and the commands list opens above the box:
the desk client's own, then the agent's commands and skills. `/model`,
`/thinking` and `/mode` open a list to pick a new setting from, and `/new`
(also `/clear`) starts a fresh session in the same pane while the old one keeps
running.

> [!TIP]
> Try it: in a `herdr-tui` session, type /mo and press Enter to choose a
> model.

- `/plan` goes into plan mode and, again, back to the mode it left. Shift-Tab
  steps through the modes and skips the risky ones; `/mode` asks twice before
  it picks one.
- `/settings` lists every setting the agent lets you change, and `/info` (also
  `/version`) says which herdr-tui and which session this is.
- `/update` installs the latest herdr-tui without leaving the session
  (`/update check` only says whether it would change anything, `/update 0.1.35`
  installs that release). It downloads in the background with the progress in
  the footer, checks the file before replacing it, then says `Ctrl-R loads it`.
  Leaving during the download abandons it.
- A word that looks like a command but is not one of the agent's (`/clera`) is
  held once, with a hint; Enter again sends it as a message.

![The herdr-tui command list open after typing a slash, with /model first and 70 more below](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.40/0.1.40-slash-commands.png)

### Pictures and files go with your message

Paste a file or picture path (or drop a file) into an empty box and it goes
with your message, listed on a row above the input. A PNG, JPEG, GIF or WebP up
to 5 MB goes as a picture the model sees; anything else goes as a link to the
file. `Ctrl-V` attaches the screenshot on the clipboard.

> [!TIP]
> Try it: copy a screenshot, press Ctrl-V in the box of a `herdr-tui`
> session, then name it in your message as [Image #1].

- Each picture leaves `[Image #1]`, `[Image #2]`... in your message where the
  cursor was, so you can say which one you mean. Backspace after a placeholder
  takes the picture off with it.
- Up to 10 files and 20 MB of pictures a message. Backspace
  takes the last one off, Ctrl-C all of them, and `/files` lets you pick
  one. Pasted into text, a path stays text.
- `Ctrl-V` needs `wl-paste`, `xclip` or `pngpaste`; without one the hint says
  so. A real clipboard was not tried on every system: this was checked with
  `xclip` standing in.

![A herdr-tui message with two attached pictures numbered 1 and 2, and the agent's answer naming the red one](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.40/0.1.40-attach-pictures.png)

### The agent's plan stays in view

While the agent has steps left, its plan shows as a checklist above the input
(`✓` done, `●` doing, `○` to do), so you see how far it has got without
scrolling. It hides when the plan is finished or the screen is short.

![The herdr-tui plan checklist: two steps done, one in progress, two to do](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.40/0.1.40-plan-checklist.png)

### A subagent's prompt reads as Markdown

In a subagent's screen, `Asked to` shows what it was asked as Markdown (headings,
lists, code) instead of raw characters; the card and the pinned prompt show it
as a short line of prose, and a tap shows it whole.

> [!TIP]
> Try it: open a subagent from a session and tap `Asked to`.

- Opening a subagent that is still working is quicker: its newest 120 items
  show first and the rest fill in behind. In a test with 2,001 items the first
  screen took 2.4 to 3.7 ms to plan, it was 43 to 91 ms. Measured on a desktop,
  not on a phone.
- Opening an omp subagent's log asks the host for its folders together, 944 ms
  became 645 ms on a modelled link with a 150 ms round trip (a 437 KB log).
  Not a real connection.
- This was drawn in the app's test renderer; it has not been seen on a phone.

![A subagent screen with the Asked to prompt drawn as Markdown: a heading, a bullet list and a code block](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.40/0.1.40-subagent-prompt.png)

**Fixed**

- `/clear` in the desk client was sent to the agent as a chat message and
  cleared nothing.
- The desk client's tip said Up brings back your last message; it is Ctrl-P.
- A table holding emoji such as `⚠️`, `❤️` or `✔️` came out a column too wide, and
  scrolling past it left stray bars and glyphs on screen. Wide text no longer
  does this in tables, lists, the folded `tool calls` line or the input box.
  Only one terminal was tried.
- In the input box, Left, Backspace and Delete stepped through half an emoji or
  half an accented letter; they now move a whole one. The emoji selector and
  joiner characters are dropped from what you type or paste.
- `herdr-tui ls` lines its columns up when a folder or title has Japanese,
  Chinese, Korean or emoji text.
- In a subagent's summary, `Show all` on a long result did nothing.
  `Summary only.` no longer shows while an omp log is still loading.

## [0.1.39] - 2026-10-27

### `herdr-tui update` shows the download

`herdr-tui update` draws the download as a bar that fills, with the percent,
the sizes and the speed, then says what it is checking and installing, so a
slow connection no longer looks like a hang.

> [!TIP]
> Try it: in a terminal, run `herdr-tui update` while a newer release exists,
> or `herdr-tui update 0.1.35` to watch a download.

- In a log or a pipe it prints plain lines, and without `curl` there is no bar.

## [0.1.38] - 2026-10-27

### The desk client updates itself, and can go back

`herdr-tui update` installs the latest release, and `herdr-tui update 0.1.35`
installs a named one, older ones too, so a release that misbehaves is one
command from the one before it.

> [!TIP]
> Try it: in a terminal, run `herdr-tui update --check` to see whether the
> latest release differs from yours.

- A desk client that is open notices the new one and says so in the footer;
  `Ctrl-R` loads it into the same session, in the same terminal and pane,
  without losing anything. It waits while there is a message in the box or a
  request waiting. Sessions already open with an older desk client do not look:
  reopen them once with `herdr-tui attach ID`.
- The download is checked against the release's checksums and run once before
  it replaces the old file, so a bad download or a failed step leaves what is
  installed as it was; a session that is open keeps running.
- The latest release is never a downgrade, only a version you name is. A
  version without a desk client (before 0.1.30) says so and changes nothing.
- It needs `curl` or `wget`, and `sha256sum` or `shasum`, as the install
  script does. A release before this one has no `update`: install this one
  with the install script first.

## [0.1.37] - 2026-10-27

### The desk client reaches every computer that runs a session

A session you start from the phone now opens in the newest desk client,
`herdr-tui` 0.1.37, which the computer downloads the first time and checks
before it runs. Until now it fetched an older one.

- That brings the clicks, the answers by arrows or mouse, the tables and the
  coloured code of the last release to every computer, not only to one where
  you installed it yourself.
- A click on a permission's option only chooses it, even on the one already
  marked; a second click on it answers. A tap that lands on a row the panel
  just moved under your thumb can no longer approve.
- An optional choice in an agent's question that you step past without picking
  sends no answer for it, as the phone does. It used to send the first option.

## [0.1.36] - 2026-10-27

### The desk client answers with the mouse and shows code in colour

The desk client, the terminal app that runs an agent in a herdr pane, now
opens and closes things with a click, answers a permission or a question with
the arrows or the mouse, and draws tables and code so they are easy to read.

> [!TIP]
> Try it: in a pane running `herdr-tui`, click a folded `tool calls` line or
> `… thinking` to open it, and click it again to close it.

- A click opens or closes a tool call, a run of them or the thinking, and the
  line you clicked stays where it was. Select text with Shift-drag;
  `HERDR_TUI_MOUSE=off` gives the mouse back to the terminal. It was not
  tried inside a herdr pane's own selection.
- A permission is answered with `↑` `↓` or a click: a click chooses, and a
  click on the chosen option answers with it, with the same guards as Enter.
- An agent's question is answered in the terminal too, where it used to say
  to answer on the phone: pick with the arrows, a number or a click, tick
  boxes with Space, type text in the box, and the last Enter sends every
  answer shown on the panel. Esc declines; what you were writing comes back.

![A question from the agent in the desk client, with three numbered choices and the keys that answer it](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.36/0.1.36-question.png)

### Tables and code are easier to read

> [!TIP]
> Try it: ask an agent for a table or a snippet in a pane running `herdr-tui`.

- A table is a box of connected lines, with a line under the header and, when
  a cell wraps, between rows. A column of figures lines up on the right and a
  cell keeps its code and bold. A table still arriving shows one quiet line
  until it is whole, instead of jumping as each row lands.
- A fenced block in the agent's answer, and the added and removed lines of a
  diff, are in colour by their language, on a faint green or red row for a
  diff. The download grows from 1.6 to 2.6 MB for it, and about 1.5 MB of
  memory per language shown (desktop, measured for Rust).
- Scrolled back, what you are reading stays where it is while the agent
  writes below, and the last row says how much is below; click it or press
  `End` to go back.
- A link shows where it goes after its label, numbered lists line up past 9,
  and punctuation after code no longer starts a line on its own.

![Coloured Rust and Python code in an answer, a numbered list from 8 to 10 and a link with its address](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.36/0.1.36-code.png)

![A table in a box of connected lines whose cells wrap, with a line between rows](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.36/0.1.36-table.png)

## [0.1.35] - 2026-10-27

### The desk client scrolls a long session as fast as it follows it

The desk client — the terminal app that runs an agent in a herdr pane — now
walks back through a long session at the same speed it follows the newest
output, and a viewer left open for days stays in the low megabytes.

- It keeps only the lines on screen and rebuilds the rest when you reach them,
  so a long history costs nothing until you scroll to it.
- A full frame draws in a few tenths of a millisecond, a fraction of the
  16 ms a smooth 60 fps frame has (desktop only; the feel on a phone is
  unverified).

**Fixed**

- A message that streams in no longer freezes at its first few words: you see
  it grow to the full text.
- Opening a folded run of tool calls, with the motion on, can no longer stop
  the viewer.

## [0.1.34] - 2026-10-27

### A new worktree's session opens in the tab you are looking at

A session you start from the phone in a worktree that herdr just made now opens in that
worktree's first tab, the empty shell, instead of in a second tab you had to switch to.

> [!TIP]
> Try it: from the phone, make a new worktree and start a session in it. On the computer, the
> worktree's only tab runs the session.

- Only a shell that was left alone is taken: one prompt and nothing else. A shell with output,
  a command half typed, a running program, an agent, or a workspace with more than one tab
  gets a tab of its own as before, so nothing is ever typed into something you are using.
- That tab stays yours: ending the session does not close it.
- Not verified on a real herdr: the keeper was tested against a stand-in for herdr, and the
  prompt check against the shell of your worktree.

## [0.1.33] - 2026-10-27

### Read what earlier releases added

`What’s new` in Settings, under `About`, lists every release of herdr mobile up to the one
you have: its headline and date, and a tap opens its notes with the tips and the walkthrough.
Use it to find a feature you missed when you updated.

> [!TIP]
> Try it: open Settings, then `About`, then `What’s new`.

- It is part of the app, so it opens at once, offline, and asks nobody for anything. Newer
  versions are still offered by `Update available`.
- A walkthrough's poster is the one thing that loads, when you open that release's notes.
- The desk client `herdr-tui` has its terminal library updated, closing two low-severity
  Dependabot alerts about a crate it never called in a risky way. The app pins `herdr-tui`
  0.1.31, so that fix reaches you with a later pin.

![What’s new in Settings: every release up to the installed one, with its headline and date](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.33/0.1.33-history-list.png)

![The notes of one release, with its tip card](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.33/0.1.33-history-notes.png)

## [0.1.32] - 2026-10-27

### A session opened from the phone shows up as herdr-tui on the computer

The tab that herdr opens on the computer for a session you start from the phone
runs `herdr-tui`, the desk client, instead of the old line-by-line view. The
first time, the computer downloads it (1.5 MB) from this app's release and
checks it before it runs; after that it opens offline.

> [!TIP]
> Try it: start a session from the phone with herdr running on the computer.
> Its tab in herdr opens the new client.

- Each app version names the `herdr-tui` release it works with, downloads
  exactly that one, and never runs an older one. An update of the app that needs
  a newer `herdr-tui` replaces the computer's copy the next time a session opens.
- A `herdr-tui` you installed yourself is used as it is when it is new enough,
  and never overwritten.
- No network on the computer the first time, no build for its platform or a
  download that does not match its checksum: the pane says so and opens the old
  view, so a session always opens.
- `HERDR_MOBILE_VIEW=python` on the computer keeps the old view.
- Not verified on a phone: the download was run against the published
  release on a computer, not through a session started from the app.

## [0.1.31] - 2026-10-27

### herdr-tui says which release it is

`herdr-tui --version` printed `0.1.0` next to a 0.1.30 release. It now prints the
release's own version, so you can tell whether the desk client matches the app.

- The version it announces to the agent when it connects is the same number.
- The app is unchanged.

## [0.1.30] - 2026-10-27

### A terminal client for your sessions, at the desk

`herdr-tui` is a full-screen terminal client for the sessions your agents run. It is a
separate download for the computer, not part of the phone app: this release changes nothing
in the app itself.

> [!TIP]
> Try it: on the computer, run the install command below, then start herdr-tui
> in a project folder. The session shows up in the app.

```sh
curl -fsSL https://github.com/tuan3w/herdr-mobile/releases/latest/download/install.sh | sh
```

- `herdr-tui` starts omp, claude, codex or pi in the current folder as a session the phone
  also sees; `herdr-tui attach ID` reopens one that is running.
- `herdr-tui ls` lists the sessions on the machine, the ones that need you first, and
  `herdr-tui kill ID` ends them.
- Tool runs fold, markdown and tables are laid out for the terminal, and a permission
  request shows the command itself.
- One file to install for Linux and macOS (x86_64 and arm64), checked against the release's
  `herdr-tui-SHA256SUMS`. It carries the keeper; `python3` is still needed.

![herdr-tui asking permission to run a command, with the command shown whole and three numbered answers](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.30/0.1.30-permission.png)

![herdr-tui after a finished turn: a diff, a table, and a one-line summary of what was done](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.30/0.1.30-finished-turn.png)

## [0.1.29] - 2026-10-22

[![Watch what's new · 3 changes · 0:18 · 6.1 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.29/0.1.29-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.29/0.1.29-whats-new.mp4)

### Made says what is running, and you can look at the next thing

`Made` shows an app as what started it (`npm run dev -- --port 5173`),
not as `localhost:5173`, with its pages under it. A tap opens the page over the
list, so Back returns to the list, not to the agent's screen.

> [!TIP]
> Try it: in a chat where an agent started a server, tap `Made`, then `Apps`.
> Swipe sideways to reach `Pages` and `Pictures`.

- `Servers` is now `Apps`: one row per port, the pages the agent named on it as
  chips under the row, and `Running`, `Stopped` or `Status unknown` (it was
  `Seen`). Four links on one port were four rows; they are one.
- A picture opens with the other pictures of the list to swipe to. Back
  returns to the list on the same tab.
- The tabs swipe: sideways on the list moves to the next tab.
- The page bar of an app opened from `Made` says what started it, with the
  machine first. The address stays in `⋯`.
- The `Made 13` chip counts apps and other things, not links.
- A link or `localhost:port` an agent only quotes in its words still makes a
  row, as before. Not measured on a phone: how the swipes feel.

![Made on the Apps tab: a running app named by its command, a database port, an app with no known command, and an app named by its launch command with its pages as chips, under the switch with Pages, Pictures and Docs](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.29/0.1.29-apps-named.png)

**Fixed**

- A tap on a row in `Made` no longer closes the list: Back no longer drops you
  on the agent's screen, so you can open the next row.

## [0.1.28] - 2026-10-21

### Manage a swarm of subagents, and see everything an agent made

When an agent fans out dozens of subagents, the ones running now are the first
thing you see, and you can stop them from the phone. In a long chat, `Made` now
finds what the agent made hours ago too.

> [!TIP]
> Try it: in a chat where an agent has launched subagents, tap the chip under the
> title (`6 running`). Hold `Ask to stop` on one, or `Stop all`.

- The subagent list is now Running, Waiting and Done: running first with their time and tools, the newest 8 finished ones,
  then `Show N more`. The chip says `6 running`, not `6 of 66`: the total is in
  the list, and a `+` says when only the end of a long chat has been read.
- `Stop all` in that list stops subagents only, with one message to the agent.
- A `wait` that omp skipped, or that had nothing to wait for, no longer shows as a
  red failure under the agent's answer.
- `Made` reads the earlier part of a long chat when you open it, once, and keeps
  the answer: a 7 MB chat showed 1 thing of 10 before. The chip says `Made 9+`
  until it has.
- A server with several pages (a dashboard and its tabs) is one row per page, not
  only the last one mentioned.
- `Session options` has `Copy session link`, which opens the same session on
  this phone.
- Reading the earlier part of that chat took 0.70 MB instead of 0.99 MB on the
  link (a laptop measurement, not a phone); the cost on a radio was not measured.

## [0.1.27] - 2026-10-21

[![Watch what's new · 2 changes · 0:10 · 4.2 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.27/0.1.27-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.27/0.1.27-whats-new.mp4)

### A dev-server address in an answer is a link

When an agent says `http://localhost:8791/`, in the text or alone in a code
badge, you can now tap it and open the page from the link sheet. It used to be
plain text.

> [!TIP]
> Try it: in a chat, tap a localhost address in an agent's answer, then `Open page`.

- `Made` also lists a server an agent names as `127.0.0.1:8791`, `0.0.0.0:8791`
  or `[::1]:8791`, not only as `localhost:8791` or a full link. A tunnel such
  as `-L 9100:127.0.0.1:9101` or a database address is not listed as a server.
- Tried in tests only; not on a phone yet.

![A chat where a tapped localhost address opens the link sheet with Open page and Copy link](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.27/0.1.27-dev-server-links.png)

### Icons drawn for herdr

`Made`, Settings, pictures and the steps of a chat have icons drawn for herdr
in place of generic ones, so one thing looks the same everywhere you meet it.

> [!TIP]
> Try it: in a chat, tap `Made` under the title to see the server, page, picture and document icons.

- `Made` shows a browser window with a pulse for a server, one with text for a
  page, and its own picture and document.
- Settings groups have their own icons: `Look`, `Notifications`, `Storage`,
  `About` and `Update available`. `Agents` uses the same robot as the Agents tab.
- A picture has one icon everywhere: the gallery, attachments, a photo that did
  not load and the pictures in `Made`.
- A tool call, a subagent run or a plan step that failed or was cancelled has
  the same drawn look as the done, working and waiting shapes next to it.
- Seen in rendered screens only; not on a phone yet.

![Made in this session on the Servers tab, two servers each with a browser-window icon](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.27/0.1.27-made-icons.png)

## [0.1.26] - 2026-10-21

### Clearing an omp conversation clears the chat

When you clear the conversation in omp's terminal, the chat now starts over
too. It used to keep every old message above the note "The conversation was
cleared on the machine", while the terminal was empty.

- The old messages, questions waiting for an answer and plans waiting for
  review go; the note stays as the first line of the new conversation. The
  plan list is left as it was: not checked whether omp clears it.
- Not tried on a phone yet. Claude Code already started a fresh chat after
  `/clear`; Codex was not checked.

**Fixed**

- A chat of an agent running in a terminal (Claude Code, Codex, omp) no
  longer stays on `Reconnecting…` with `Offline · reconnecting` in the
  composer after a short drop of the connection. It used to stay that way
  until you left the chat, with the agent's output still arriving. Not
  checked on a phone yet.

## [0.1.25] - 2026-10-20

### A page behind a password asks you to sign in

A page that wants a user name and password (a dev server, or a reverse proxy
in front of it, with Basic auth) now asks for them. It used to load nothing
and give no way to enter them.

> [!TIP]
> Try it: tap a link to a page behind a password and choose `Open page`; the
> `Sign in` sheet appears.

- The sheet names the machine and shows the server's own words for what it
  protects. A page and its pictures asking together share one sheet, so you
  type once. A wrong password asks again.
- Dismissing the sheet cancels the sign-in. What you type is used for that
  page only and is not kept. Not tried on a phone yet.

## [0.1.24] - 2026-10-20

[![Watch what's new · 1 change · 0:13 · 2.8 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.24/0.1.24-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.24/0.1.24-whats-new.mp4)

### A session in a worktree shows up in that worktree

At the computer, an agent you start in a worktree from the phone now has its
tab in that worktree's own workspace in herdr, next to its shell. It used to
sit in `Phone sessions`, and the worktree looked empty.

> [!TIP]
> Try it: start a new agent session, open `Checkout` and pick `New worktree…`:
> `Branch` starts with a name you can keep or change.

- `New worktree…` fills `Branch` with a name like `worktree/brave-meadow-45e8`,
  one the repo has no branch of yet. Change it, or clear it to let herdr name it.
- Only sessions started from now on move. A session in a repo's main checkout
  stays in `Phone sessions`. Not checked on a live herdr desktop yet.

![New agent session with Checkout set to New worktree and Branch holding worktree/merry-harbor-4ce3](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.24/0.1.24-branch-suggested.png)

**Fixed**

- A picture with see-through pixels, a PNG or WebP, in the full-screen
  viewer no longer shows a strip of grey squares past its right and bottom
  edge. The strip grew as you zoomed in; it was seen on a large diagram.
  Not checked on a phone yet.

## [0.1.23] - 2026-10-20

### Mermaid diagrams are drawn in answers

When an agent answers with a Mermaid diagram, you now see the diagram, not
its source: flowcharts, sequence, state, ER and class diagrams, in the app's
own look, light and dark.

> [!TIP]
> Try it: ask an agent to draw a flowchart in Mermaid, then tap the diagram,
> or `Open diagram`, to zoom it full screen.

- A diagram wider than the screen scrolls sideways; a tall one is cropped
  with `Show all`. `Copy source` on a diagram copies the Mermaid text as the
  agent wrote it, and `Save or share` in the full-screen view sends the
  diagram as a picture.
- A left-to-right flowchart is drawn top-down when that fits the screen
  better; the header says so.
- Other kinds (a Gantt chart, a pie chart), a diagram with a mistake in it,
  and one that is still arriving stay as code, with a line saying why.
- Laying one out took under 2 ms for 95% of 2,213 real diagrams on a laptop.
  Frame times on a phone and the size of the app were not measured.

## [0.1.22] - 2026-10-20

[![Watch what's new · 3 changes · 0:21 · 6.9 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.22/0.1.22-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.22/0.1.22-whats-new.mp4)

### See and manage your worktrees from the phone

A repo with several worktrees open in herdr is now one section on its
machine's screen: each checkout with its branch and the agents running in it.
You can start an agent in a new worktree, or remove one, without leaving the
app.

> [!TIP]
> Try it: on a machine's screen, tap `New agent session` (the `+` at the top),
> choose `Checkout`, then `New worktree…`.

> [!TIP]
> Try it: on a machine's screen, tap the `⋯` on a checkout (`Checkout actions`),
> then `Remove worktree`, and hold the button.

- A worktree reads `worktree-a · herdr-mobile` (its folder, then its repo) on
  the board, in notifications and in the toast after `Start`. The main
  checkout and a repo with a single open checkout look as before.
- A phone session started in a folder of a checkout is listed under that
  checkout, not under `Phone sessions`.
- `Remove worktree` takes a hold, not a tap, and never forces: a checkout with
  uncommitted changes is kept and the toast says so. The branch stays, and the
  sheet says how many agents working there will stop.
- `Checkout` appears for a folder in a git repo. `Branch` is optional: left
  empty, herdr names it. herdr runs your `worktree.created` hooks on the
  machine, as on the desktop. On a herdr that cannot create worktrees, `Start`
  says so and `This folder` still works.
- Frame times on a phone were not measured.

![The studio-mac screen: the payments-api repo lists its Main checkout on main with a blocked agent, then two worktrees, each with its branch and its agent](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.22/0.1.22-worktrees-places.png)

**Fixed**

- An omp plan review now shows as needing you, with the plan to read and its
  options as buttons. Before, the agent looked finished and the review waited
  in the terminal, and with a model slider or a nearly full context the
  buttons were missing or chose the wrong option.
- `Close workspace` on a main checkout whose worktrees are still open no
  longer ends in an error from herdr: it is dimmed and says `Worktrees are
  open · close them first`.

## [0.1.21] - 2026-10-20

### A release's clip plays inside herdr

`Play` on the clip at the top of the update sheet now plays it inside herdr,
silent, with `Play again` at the end.

- Nothing of the clip loads before you tap `Play`. If it can't load, it says
  so and offers `Retry`.
- You see this from your next update on: the sheet that offers an update is
  drawn by the version you already have.

## [0.1.20] - 2026-10-19

[![Watch what's new · 3 changes · 0:13 · 4.6 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.20/0.1.20-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.20/0.1.20-whats-new.mp4)

### Read what's new before you update

`Update available` in Settings now opens one sheet: what changed comes first,
then `Download` and `Install`.

> [!TIP]
> Try it: when Settings has a dot, tap `Update available`.

- The sheet says where the file comes from and, once downloaded, that it
  matched the release's checksum. Android still asks before it installs.
- When a release comes with a short clip of its changes, the sheet opens on
  it. `Play` opens it in your browser, and nothing of the video loads before
  that tap.
- Coming back to Settings with an update you have not opened yet scrolls it
  to the top, so the row is in view.

![The update sheet: what's new in 0.1.20 above Download 23 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.20/0.1.20-update-sheet.png)

## [0.1.19] - 2026-10-19

### A page from your machine gets the same bar as every screen

- A page from a machine has the same bar as every other screen: a globe, its
  title, and where it comes from underneath. The page gets more of the
  screen than with 0.1.18's address pill.
- `⋯` on a page shows its whole link above `Copy link`.

## [0.1.18] - 2026-10-19

### Pages from your machine open inside herdr

- A page from a machine (a dev server on its `localhost`, or an HTML file an
  agent wrote) now opens inside herdr and stays up. In the phone's browser
  herdr went to the background, lost its connection, and the page never got
  past "Opening…". Back goes back in the page, then returns where you were.
  A pill under the title says where the page comes from. The terminal link
  sheet's `Open on phone` is now `Open page`.
- While such a page is open, herdr keeps that machine's connection when you
  switch apps or turn the screen off, with the quiet Watching notice naming
  the page ("Keeping localhost:5173 on devbox open"), even with notifications
  off. If the connection drops anyway, the page says so and comes back by
  itself.
- A link in the page to the web never opens by itself: herdr says where it
  leads and `Open` takes it to your browser.
- `⋯` on a page has `Copy link` (its address on the machine) and `Open in
  browser`, for pages that need your phone's browser, such as a Google
  sign-in.
- In the file viewer, `Open in browser` on an HTML or SVG file is now `Show
  as page`.

## [0.1.17] - 2026-10-18

### One design language

- Copying a path, a link, code or a pane id no longer shows two
  confirmations on Android 13 and later: the system's own is the one. On older
  Android herdr says it once.
- A toast is a dark card that rises from behind the bar it sits on, waits
  until it has arrived before its clock starts, holds still under your finger
  and swipes away. It never covers the "needs you" pill again.
- The tab bar says where you are: the selected tab takes the accent colour on
  a soft capsule, the icons are larger, and the count sits on the icon's
  corner and rolls when it changes. Dragging along the bar lifts it slightly
  and the selection springs to where you let go.
- Picking agents and then going to Machines or Settings no longer leaves
  those tabs without a tab bar.
- Every agent and machine has one icon everywhere, drawn for herdr so the
  three tabs and the Stop, Message, Close bar weigh the same (the Machines
  icon was the biggest thing in the bar). A machine is a screen on a stand.
- An agent has one name everywhere: Claude Code, Codex, omp, pi, never
  `claude`. Counts read right (`1 subagent`, `2 need you`), times read one
  way (`4m`, `1h 05m`, `4m ago`), Interrupt is Stop and Try again is Retry.
- A board row ends with the time alone (`4m`, orange when it needs you): the
  glyph and the section already say the state.
- Machines rows are two lines with the connection dot in front, and a waiting
  count carries the needs-you mark.
- Every screen's top bar is the same: Back in the same place, at most two
  buttons. The terminal's bar keeps files and the menu; Wrap lines moved into
  Pane options, so titles are cut less.
- Answer buttons look and behave the same on the board, the pane, the reply
  sheet and the permission dock; the question above them has one style.
- Selected chips and switches are a soft accent tint instead of an outline,
  and status panels are a tint without a border.
- Settings has a hidden kit: hold Version to see every component, light and
  dark, at two text sizes.
- Swiping sideways on an agent's screen shows who is next while your finger
  moves: a card with the agent's status, title, machine and time slides in.
  Let go past the mark (or flick) to go there; let go short and you stay. At
  either end the card says there is no next agent. Screen readers get Next
  agent and Previous agent actions.

### Fixes

- Opening a dev server or a page on the phone (Open on phone, a Made row,
  Open in browser) shows the page again instead of "Not allowed": the browser
  tab now keeps the sign-in it was given.
- A link the agent wrote in bold or italics opens the link itself, without the
  `**` around it.

## [0.1.16] - 2026-10-18

### Open what an agent made, on your phone

- An HTML or SVG file in the file viewer has an Open in browser button. The
  page opens in the phone's browser tab with its own styles, scripts and
  images, read from the file's folder on the machine. An SVG, which the viewer
  could not draw at all, now shows.
- A `localhost` link in terminal output or a chat (a dev server on the
  machine) now offers Open on phone: the page opens in the browser through
  your SSH connection. Sign-in and passkeys work as in any link. An `https`
  address on the machine stays copy-only and says why.
- A machine that does not allow port forwarding says so; Copy link stays.
- A Made chip under the session's title lists what the agent has made, newest
  first, so a link or a file from an hour ago is not lost in the chat: dev
  servers (Running while one is up), HTML and SVG pages, pictures (a grid of
  thumbnails) and documents. When there is more than one kind a switch on top
  (Servers, Pages, Pictures, Docs, with a count each) changes the list; it never
  moves while you switch. A tap opens the item. A file shows up only when the
  agent made or announced it, never because a command merely read it.
- The switches in Settings (theme, agent list) and the machine form look like
  the tab bar's capsule now: a soft pill, no border.

## [0.1.15] - 2026-10-17

### Pictures are downloaded once, and steering can say "after"

- A picture you looked at is kept on the phone (at most 192 MB, the oldest go
  first), so opening a photo again, going back to one in the viewer, or
  returning to a folder no longer downloads it again. Folder thumbnails are
  kept as small copies too.
- Settings has a Storage row that says how much is kept and clears it.
- Chats of agents running in a terminal (Claude Code, omp) now show your
  pictures as a quiet line with the size and type. Tap it to load the picture;
  a failure says why and offers a retry. Pictures you have loaded stay. (A
  picture larger than about 3 MB is not fetchable and stays a line of text.)
- A picture in a chat larger than about 100 KB, yours or the agent's, no longer
  vanishes when the chat reconnects.
- A chat keeps its decoded pictures when it reconnects, instead of decoding
  every visible one again.

### Steer now, or send it after

- While an agent that takes input into its running turn works (Claude Code and
  Codex, and omp once it ships the change in `docs/omp-acp-steering.patch`), a
  tap on Send puts your message into the turn, as before, and a hold on Send
  sends it after the turn instead: it waits on the phone, where you can edit it
  or take it back. The line above the field says so.

## [0.1.14] - 2026-10-10

### A typo'd command is caught, and a picked command says what it takes

- Sending a message that starts with a `/command` the agent does not list
  (a typo like `/clera`) now stops once: a short note says so and "Send as
  message" sends it as typed. Your text stays in the field. It does not stop
  for commands every terminal takes, for paths, or for a command you have
  sent before.
- After you pick a command from the slash list, what it takes shows after it
  in grey (`/review <pr number>`), until you type.
- In Settings, opening a group scrolls it into view, so at a large text size
  its first row is no longer hidden under the tab bar.

## [0.1.13] - 2026-10-10

### Settings in four rows, and /clear starts fresh

- Settings is four rows (Look, Agents, Notifications, About) that say what
  they are set to and open in place, one at a time, instead of one long page.
  Everything is still there; Quick phrases is a page of its own under Agents.
- A newer version is a row at the top of Settings, open when you get there:
  Download is one tap, and a download's progress stays under the row while
  you look at another group.
- Tapping the tab you are already on takes Machines and Settings back to the
  top, as it already did on Agents.
- `/clear` and `/new` in an omp or Claude Code chat now start a new
  conversation, instead of leaving the old one on the screen.
- The slash-command list no longer draws over the rows below it while you
  type.

## [0.1.12] - 2026-10-10

### A smaller download, newest sessions first

- The app is a 23 MB download instead of 51 MB, for the first install and
  every update. It takes about the same space on the phone once installed.
- A machine's screen lists each workspace's newest session first, so the one
  you just started, and the ones still working, are at the top instead of
  under every finished one.
- Changing the model, mode or effort from the chips above the message field
  puts you back in the field with the keyboard up, ready to write.
- An omp tool that is still waiting (for a background job, say) shows
  "Waiting for output…" instead of a block of raw JSON.

## [0.1.11] - 2026-10-10

### One bottom bar, nothing off the screen

- Picking agents on the board (long press) puts Interrupt, Message and Close
  in the tab bar's own pill, exactly where the tabs were, instead of a
  full-width bar: the bottom keeps its shape and the thumb finds the actions
  where it left the tabs.
- The tab bar, the "need you" pill, the attach sheet's bars and toasts share
  one soft shadow, one shape and one text size limit. The attach sheet's
  selected tab is visible in dark mode.
- The session overview (tap a session's title) no longer runs under the
  status bar when it is taller than the screen; the clock and the sheet's
  title stop overlapping. Every sheet does the same, and in landscape a
  sheet still reaches both screen edges.
- On a small phone with large text, the subagents chip under a session's
  title and the `Context 91%` warning beside it end in "…" instead of
  running off the screen.
- The model and mode chips above the message box and the quick phrases are
  cut at the same width.

## [0.1.10] - 2026-10-10

### Pictures, files and commands for terminal agents

- A Claude Code or Codex agent in a herdr pane takes pictures and files from
  the phone, in the chat and in the terminal view: the paperclip, the chips and
  Send work as they do for an ACP agent. A picture is shrunk, stripped of its
  location, uploaded to the machine and reaches the agent as an image; a file
  inside the project is mentioned as `@path`, one outside it as `@/full/path`.
  Other agents in a pane get the same, but only Claude Code and Codex turn a
  pasted picture path into an image; the rest receive the path as text.
- The terminal view's composer looks like the chat's (same field, buttons and
  corner). A shell's line keeps the terminal font and has no paperclip.
- One command palette for both views: `/commands` with their hints, and Codex's
  `$skills`. A Claude Code chat lists the plugin and bundled skills the agent
  announces. Pins and recents are shared between the two views.

### Smaller things

- A chat the agent never titled (every omp chat started from the phone) is
  named after the first line of your first message, at once, as Zed does. Any
  title the agent sends replaces it. The app no longer sends `/rename` to omp
  to ask for one, so omp's "Could not generate a session title" no longer
  appears in the chat and no model call is spent on naming.

## [0.1.9] - 2026-10-10

### Claude Code and Codex as chats

- A Claude Code or Codex agent running in a herdr pane opens as a chat, like
  omp does: the whole conversation (no more scrolling a terminal that keeps
  none), what it ran with its output, the plan and the task list, and the
  subagents and background commands it started. The terminal stays one tap away.
- Approvals show the command itself on a card: tap to allow, hold for a risky
  one. Claude Code's questions (single choice, several, your own answer) are
  answered from the app. Stop sends Esc; a background job can be stopped by
  asking the agent.
- Claude Code needs herdr's hook to report its session, or a running process
  the app can recognise; Codex needs the hook. If the terminal's options offer
  `Read as chat…`, tap it and confirm: it installs herdr's hook for that agent on
  the machine (nothing is installed without the tap), then restart or resume the
  agent.
- Settings: `Open omp agents as` is now `Open agents as`.

### The whole conversation, as far back as it goes

- A chat used to show only the end of a long session: the last 192 KB of the
  agent's log, which for Claude Code is often less than one turn, with no sign
  that anything was missing. Now scroll up and the earlier messages load as you
  reach the top, all the way back to the start of the session. What you are
  reading stays where it is while they arrive.
- Opening a chat costs what it did: earlier messages are read only when you
  scroll up. A log longer than 64 MB shows its last 64 MB and says so.

## [0.1.8] - 2026-10-09

### A release to try updating with

- Nothing else changed since 0.1.7. If you are on 0.1.7, Settings now shows the
  dot and the Update panel: tap Download, then Install, to try the in-app update
  from start to finish.

## [0.1.7] - 2026-10-09

### Update from inside the app

- When a new version is out, Settings shows a small dot and an Update panel at
  the top: the version, its size and What's new (these notes). Tap Download,
  then Install; Android asks you to confirm. No more fetching the APK by hand.
- The download is compared with the checksum GitHub publishes for it before
  Android sees it; a download that breaks or goes quiet continues from where it
  stopped, and the file is checked again just before it is installed.
- herdr looks for a new version about twice a day while you use it, and on
  Settings > About > Check for updates. Switch the automatic look off there. It
  asks GitHub only, with the app's name and version; it never downloads without
  your tap.

## [0.1.6] - 2026-10-09

### A slimmer tab bar you can drag

- The bar at the bottom is smaller: 56 dp tall and centred instead of edge to
  edge, with no shadow. Every tab shows its name, and the cells are the same
  width, so nothing moves when you pick one.
- Drag along the bar and the highlight follows your finger; the tab changes
  where you let go, and a quick flick is enough. A tap works as before. The
  names warm up as the highlight arrives under them, in step with it.
- The "1 needs you" shortcut above the bar is no longer faded at its bottom
  edge.
- There is no sideways swipe over the whole screen to change tab: the bar is the
  way.

### Links open over the app

- A link you tap, and the sign-in page a machine asks you to approve (Tailscale),
  opens in a browser tab over the app, so Back or the close button returns to
  where you were. It is your phone's own browser, so your sign-ins and passkeys
  work.

### Answers are safer

- Keyboard Send on an empty reply field no longer presses Enter on the agent.
- A terminal menu whose command sits above the question shows that command when
  it is risky, and an answer that became risky since you saw it is not sent.
- A cut-off command is held like any long one, "bypass permissions" and
  "auto-accept edits" need a second step, and more risky commands are caught:
  `bash -c "$(curl …)"`, quoted or escaped command words, `curl … | python3`,
  `kill -9 -1`. A hostile command line can no longer freeze the phone while it
  is judged.
- An approval shows the command the screen asks about, not another running
  one.
- Dismissing a question or approval checks the terminal first, so a stale tap no
  longer interrupts a working agent.
- Your typed answer to a question survives the question coming back after a
  refusal.

### Fixes

- An upload whose last write fails now says so instead of reporting success.
- Replayed chats keep accented, CJK and emoji text intact in long replays.
- Text after a stray escape sequence in a plan or a command is no longer hidden.
- A machine's host key stays pinned when its connection restarts, and the
  machine form no longer pins the old host's key after you edit the address
  during a test.
- A stream that keeps dropping backs off instead of retrying every second, and
  one machine failing to connect no longer stops you adding or editing others.
- A saved machine the app cannot read is kept and skipped instead of leaving the
  app blank, and a start that fails shows what failed with a Retry button.
- Commands run under fish and csh login shells; agents get your login umask
  instead of the keeper's private one; a keeper that is still starting is no
  longer marked gone.
- A message that fails to send after you leave the screen comes back as a draft
  with a note, not silently lost.
- Cards stop reading terminal previews while the board is out of sight.
- The gallery opens the picture you tapped, and sees a picture you just took
  without restarting the app.
- The file viewer no longer shows part of a file twice when you copy while it
  loads.

## [0.1.5] - 2026-10-08

### The Idle list shows what you used last

- Idle agents are ordered by when they stopped, most recent first: the ones
  that stopped within a day, then those the app has no date for, then the older
  ones. Agents started on the phone are mixed in by when they last did
  something, so a session you used ten minutes ago no longer sits under days-old
  terminal agents on other machines.
- Idle shows its first five agents. The rest sit behind one line (`22 more
  idle`, with the first two names under it) that opens them in place; the `Idle`
  chip still shows all of them.

### Agents have names

- An omp agent in a terminal that still shows a generic title is named after
  its session: the title omp gave it, or your last message. The board, the pane
  header and notifications use that name, and an idle omp agent shows how long
  ago its session was last touched. This needs herdr to report the session, so
  run `herdr integration install omp` on the machine and restart omp in the
  pane.
- An omp session started from the phone names itself after its first answer
  (omp does not do this over ACP, so the app asks it with `/rename`). The
  `/rename` line and omp's "Session renamed to …" stay in the chat. It costs one
  small model call per session; it is not a result to review and shows no error
  if omp cannot name it.

### Smaller things

- Stop with messages waiting sends them together, as one message, once the
  turn has stopped. A turn that fails, or that someone else stopped, still holds
  the queue.
- Opening a file no longer flashes dark between screens, and the keyboard no
  longer comes back after you close a file or a picture from the chat.
- A new agent session no longer forgets older turns when its latest turn alone
  fills the history the host keeps. Sessions already running keep the old
  behaviour until they end.
- Claude Code on a Mac whose login lives in the Keychain says so, instead of
  asking you to sign in again, which cannot help from a phone session.
- A character the screen cannot draw, or a row that fails to draw, no longer
  blanks a whole transcript: the row says `Couldn’t draw this` and the rest
  stays.
- A herdr pane that shows a phone session opens the full chat, with its dock,
  photos and files.

## [0.1.4] - 2026-10-07

### Agent sessions show up on the computer

- When herdr runs on the machine, each agent session started from the phone
  now also gets a tab in a herdr workspace called `Phone sessions`. herdr lists
  it with your other agents (for example `omp · phone`, working, blocked or
  idle), on that machine and on every computer connected to it, and notifies
  you the same way. Before, a session started on the phone was invisible to
  herdr.
- The tab shows the conversation. Type a line and press Enter to send it, type
  an option's number to answer a permission, `/cancel` stops the turn and
  `/quit` closes the view (the agent keeps running). Questions with a form are
  still answered on the phone. Ending the session on the phone closes the tab.
- To keep these tabs off a machine, create the file `~/.herdr-mobile/no-panes`
  there.

### The phone and the computer share a session

- A session can be open in several places at once: a second phone or the
  terminal no longer pushes the first one out with `Opened on another device`.
  A message sent from one shows on the others as it is sent.
- A permission waits on every screen that has the session open; the first
  answer counts. The phone then says who answered and how, for example
  `Allowed once in Terminal on mac-mini`, instead of the request just
  disappearing.
- Sessions already running when you update keep the old behaviour (no tab,
  one device at a time) until they end; new ones get the new one.

## [0.1.3] - 2026-10-07

### A refused sign-in says why

- Tailscale SSH explains a refusal in its own words, and the app now shows it:
  `Tailscale refused the sign-in: tailnet policy does not permit you to SSH as
  user "admin"`, or `failed to look up admin` when the machine has no such
  user. Before, the first showed `Cannot connect: SSHAuthAbortError(...)`, the
  second a general "did not accept" text, and the app kept retrying a refusal
  that cannot succeed. It now stops and says what to check.
- Choosing `Tailscale` for a Mac (or any machine without Tailscale SSH) now
  says `This machine runs a regular SSH server (OpenSSH_10.3), not Tailscale
  SSH. Choose Private key or Password for it.` The Tailscale apps for macOS
  cannot run Tailscale SSH, so a Mac needs a key or a password.
- A sign-in link that is refused or expires, and a machine that hangs up
  without a reason, each have their own message.

### A key pasted on a phone is repaired

- Copying a private key on a phone often turns its line breaks into spaces,
  indents the lines, adds quotes or puts words before it, and the app answered
  `Private key could not be read`. The app now puts such a key back together
  before testing and saving it. A key that was cut short still fails, now with
  `incomplete paste` among the possible causes.

Checked against two real Tailscale SSH machines and a Mac running OpenSSH. Not
yet tried on a phone.

## [0.1.2] - 2026-10-07

### Your most sent messages become one-tap chips

- A message you send to an agent twice or more now shows as a chip above the
  empty message box, most sent first, up to three. Tap it to fill the box; you
  still press send. Before, only the four built-in phrases were there.
- It learns on this phone only, never from a line typed into a shell, and never
  from a message with an address or a long token in it. Turn it off or forget
  what it learned in Settings > `Quick phrases`.

### Speak instead of typing

- While a message box for an agent is empty, a mic sits where Send is. Tap it
  and speak; the words fill the box and nothing is sent until you press send.
  A long press picks the language (English, Tiếng Việt or the phone's own).
  The first tap asks for the microphone. The phone's speech service may send
  the audio to Google unless an offline language is installed.

## [0.1.1] - 2026-10-07

### Watching from the background costs far less

- A Wi-Fi to mobile handover, a tunnel or a host that reboots no longer ends
  the watch: the app brings the connections back by itself and still tells you
  when an agent needs you. Before, the first network blip in the background
  stopped watching until you opened the app.
- The background safety poll runs every 4 minutes instead of 2 and doubles as
  the liveness test, so the phone sends far fewer packets while nothing
  happens. Polls and agent-session listings of all machines now share one
  clock grid, so the radio wakes once for all of them.
- In the modelled benchmark (`./autoresearch.sh`, radio model assumed, not
  measured on a phone) a turbulent 2 hour watch went from 4607 to 355
  radio-seconds per hour, with every blocked agent announced.

### Opening a chat waits less on a slow link

- The history of a chat now crosses the link compressed: a 600-message chat
  was 1.5 MB, it is 172 KB.
- A chat you have opened before asks the machine only for its newest turns,
  not the whole history again: re-opening one that had not moved cost 172 KB
  and now costs about 3 KB. This holds for agent sessions started after your
  machine has the new helper (it installs itself the first time you open a
  chat after updating); a session that was already running keeps opening the
  old way, compressed but whole, until it ends. The copy shown at once is
  still not live, and answering still waits for the machine to confirm.
- An open waits one round trip less.
- A chat of an agent that runs in a terminal pane starts loading at once.
  Before, it waited a fixed 2 seconds on the first open, and coming back to one
  you had just left waited another 2.5 seconds before it said it was up to
  date. Its history also crosses the link compressed and without the
  bookkeeping omp keeps for itself. In the benchmark the open on the slowest
  modelled link went from 2.6 s to 0.9 s, and coming back to the chat from
  3.1 s to 0.7 s. This needs the new helper on the machine; it installs itself
  the first time you open a chat after updating.
- All figures are from desktop benchmarks with a modelled link
  (`session_open_wire_bench_test.dart`, `observed_open_bench_test.dart`); a
  phone was not measured.

## [0.1.0] - 2026-10-06

The first public release.

### See every agent

- One board for every agent on every machine you run herdr on: terminal agents
  and agent sessions in one list, grouped by what they need (needs you,
  working, done, idle), the one waiting longest first.
- One "needs you" count everywhere: the board, the Agents tab badge, the
  triage pill and notifications.
- Cards can show the last lines of each agent's terminal and how long it has
  been in its state; a compact list when you have many.

### Answer safely, from the board

- An agent's question appears on its card as one-tap answers, with the command
  it wants to run.
- A risky answer (a push, a delete, "don't ask again") is held, not tapped.
  Answers that just appeared or moved ignore taps for a moment, and the app
  re-reads the question before it sends.
- `1 needs you` walks you through every waiting agent and says `All clear`
  when none is left.

### Watch and steer

- Open an agent as a chat or as its live terminal, and switch in place
  (`Show terminal` / `Show chat`). Swipe sideways to the next agent; the app
  reopens the last one you looked at.
- The terminal has a key row, sticky Ctrl and Alt, a slash-command palette,
  quick phrases, pinch to zoom and a wrap mode. Links and file paths can be
  tapped.
- Start Claude Code, Codex, omp or pi on any machine from the `+` button and
  talk to it in a transcript: the outcome first, tool calls, plans, diffs,
  background work, photos and files from the phone. The agent runs in a small
  keeper on the host, so it keeps working when your signal drops. omp is
  verified end to end from the phone; Claude Code has run full turns through
  the app's client; Codex chats with approvals unverified; pi has not
  completed a turn yet.
- Browse the host's files over SFTP: source, Markdown, JSON, images, and a hex
  view for binaries.

### Honest on a bad network

- Wi-Fi to cellular switches and lost signal are noticed within seconds; the
  last known state paints at once and is marked stale until it is fresh.
- Optional local notifications when an agent starts waiting or finishes. Off
  by default; connections stay up for 90 seconds after you leave the app, and
  after that nothing runs in the background unless you turn them on.

### Private by design

- No relay, no account, no telemetry. The phone talks to each machine over SSH
  (a key, a password or Tailscale SSH), one shared channel per machine.
- Host keys are pinned on first use and a changed key stops the connection.
  Secrets live in the Android keystore.
- An Ed25519 key can be generated on the phone, with the line to add to the
  host's `authorized_keys`.

### Look

- A new app icon: an h whose stem rises into a shepherd's crook, holding the
  one agent that needs you. It comes with a themed (monochrome) icon for
  Android 13 and a matching notification icon.
