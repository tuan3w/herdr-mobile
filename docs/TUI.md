# Desk client (`rust/`)

The desk front-end for agents: `herdr-tui` starts an agent (omp, claude, codex, pi) in the
current folder, or attaches to a running session (`herdr-tui <keeper id>`, what a herdr pane
runs). Every session is a keeper session, so the phone sees and answers it too. It is the
only terminal client of the keeper (the python `view` that used to run in herdr panes is
gone). It speaks the keeper's ACP socket as a viewer (`_meta.herdr.viewer`), and links the
same `keeper` library the phone's `herdr-host` does (`rust/crates/keeper`). Written in Rust,
no async runtime, small on purpose.

Status: v0 (prototype) runs end to end; the code is being rebuilt as the layers below.
Everything here is the target; what is measured is marked.

## The moment

At the desk, in a herdr pane next to the editor. An agent is working on something the
person cares about. Unlike the phone they have a keyboard, a wide screen and minutes of
attention, and they judge the tool against codex and omp. Same five questions as the app,
asked with a keyboard:

1. **Does anything need me?** A permission card at the bottom, with the exact command.
2. **Is it alive?** One status line: what it is doing now, for how long, how to stop it.
3. **What did it do?** The conversation above, outcome first, tool calls folded.
4. **Steer it.** A composer that is always there and always clear where text goes.
5. **Can I trust it?** The command shown whole; nothing answered by default or by a timeout.

## What codex teaches (and what we leave)

Read from `openai/codex` `codex-rs/tui` (cloned to `temp/codex-ref`, untracked).

| Codex does | Why it works | Ours |
| --- | --- | --- |
| **Inline viewport.** Finished messages are written into the terminal's scrollback (`insert_history.rs`); only the bottom pane is live. | Native scroll and copy, history survives exit, at the price of a 1,440-line forked terminal (`custom_terminal.rs`) and reflow code. | **Leave** (owner chose the alternate screen). We keep its other lessons. |
| History cells are immutable once finished; a streaming message is committed by newline (`streaming/`), not per token. | No flicker, no half lines in scrollback. | Adopt: commit whole lines; the unfinished tail lives in the live area. |
| Tool calls group and fold: `• Explored └ Search … Read …`, output capped at 5 lines with a count of the rest (`TOOL_CALL_MAX_LINES`). | Outcome first, process one keypress down. | Adopt. Full output behind the pager. |
| One status line while working: `• Working (12s • esc to interrupt)`. | Alive, how long, how to stop, in one row. | Adopt. Elapsed shown at second resolution only while visible. |
| Approval: the command, then numbered options with a single key each (`y`, `p`, `esc`), `Enter` confirms, "No, and tell the agent what to do differently". | Fast, and the person sees what they approve. | Adopt the shape. Guards below. |
| Composer: `›` prompt with a placeholder, footer with shortcuts left and context right. | Always clear where typing goes. | Adopt. |
| Colour: terminal default foreground, ANSI palette only, dim for secondary; no custom RGB, no ANSI black/white (`styles.md`). | Works in every theme, light or dark. | Adopt. Fixes my v0, which was fine only by accident. |
| Snapshot tests of the rendered screen via a vt100 emulator. | Catches what a person would see. | Adopt (our `herdr-screen-check` idea, for a terminal). |
| A 12k-line composer, paste-burst detection, themes, voice, plugins, keymaps. | Years of product. | **Leave.** Add only what a viewer needs. |

## Screen model

The viewer owns the screen (alternate screen, owner's decision: faster and lighter than
printing into scrollback, and the layout is ours to get right).

```
 transcript viewport   entries wrapped to the width, follows the bottom
 approval dock         only while a request waits
 status line           one row: what it is doing, for how long, how to stop
 composer              always there, grows to 6 rows
 footer                key hints
```

- History is held in a store bounded by **bytes**, not rows; tool output is trimmed to a
  head and tail with a count when it arrives. Dropped items are said so (`N earlier items`);
  the keeper still has them.
- Wrapped lines are cached per (entry, width) and dropped on resize, so a redraw during
  streaming wraps only the entry that changed. Nothing is drawn when nothing changed, and
  the only timer is the 1 s elapsed counter while a turn runs.
- The mouse is taken for clicks, the wheel and drags (`?1002h` + SGR `?1006h`; never plain motion
  `?1003`, which would wake the loop on every pointer move; `?1002` reports motion only while a
  button is held). A click (press and release on one cell) opens or closes what it is on and
  chooses a permission option; it acts on the release, so a drag that starts on a tool call
  selects its text instead of opening it. `HERDR_TUI_MOUSE=off` hands the mouse back
  (alternate-scroll `?1007h` still turns the wheel into Up and Down).
- **Selection is ours** (`select.rs`). A terminal that has given its mouse to an application
  selects nothing itself: herdr forwards the drag to the pane instead of copying it, and
  Shift-drag in the outer terminal cuts a rectangle across herdr's sidebar and the other panes
  (0.1.36, the first release with clicks, left no way to select in a herdr pane). So a drag
  puts a band behind the cells it covers (`Theme::selection`: the terminal's own background
  moved toward the palette's blue, the text keeping its colour, so it reads on light and dark;
  a plain swap of foreground and background was white on near-black on a light terminal; where
  the background is unknown, or with `NO_COLOR`, it still swaps them), and on release the text of those cells (rows as
  drawn, nothing trailing, the screen's two-column margin taken off) goes out as an OSC 52
  write, which herdr hands to the clipboard of the machine the person sits at and most
  terminals allow. The footer says `Copied N characters`. Any key, click, wheel turn or new
  output drops the highlight, because it points at screen cells, not messages. It selects what
  is on the screen: a drag does not scroll. Codex maps its selection to the message source; ours
  is the screen: a wrapped paragraph or a long command copies with a line break at every wrap
  (a terminal that tracks soft wraps would join them), and the bullet at the start of a message
  copies too if the drag begins on it. Mapping the selection to the message source would fix
  both; it is a larger piece than the screen selection and not done.
  Unverified: inside a live herdr on a desktop (checked in a pty against the real keeper that the
  write leaves, not that herdr puts it on the clipboard), and over a terminal that refuses OSC 52
  (nothing arrives, and the footer still says copied: the write cannot be confirmed).
- Cost of choosing this over printing into scrollback (codex): no native scrollback after
  exit, and copying is limited to what is on the screen.
- Tables are a box of connected lines (`╭┬╮ │ ├┼┤ ╰┴╯`), faint, with a rule under the header
  and between rows only when a cell wraps. The owner tried codex's bar-less layout (whitespace
  columns, a `━` under the header) and wanted connected lines back; what both replaced, the
  dashed `┄┼┄` between rows, read as noise.
- Streaming (from codex's `streaming/table_holdback.rs`): a table still arriving is held back
  behind one quiet line until a blank line ends it, so the box never re-measures under the
  reader. Codex's line-by-line commit queue is not copied: it exists because codex commits whole
  lines into scrollback; here the unfinished line is drawn live, so a queue would only delay.
- Scrolled back, the reading position is held by the block at the bottom edge, not by a count
  from the bottom, so output arriving below never moves what is being read.
- Code is coloured by syntect's default grammars (oniguruma: 3x faster than fancy-regex and
  about 1.5 MB less memory per grammar, measured for Rust on this machine), with the scopes
  mapped onto the palette in `theme.rs` rather than a bundled theme. A growing block resumes
  from where its colouring stopped instead of re-reading itself on every chunk.

## Small touches (and why they are allowed)

The app's rule is that nothing moves at rest and delight is friction that vanished. The viewer
keeps it literally: the only thing that moves is the elapsed counter on the 1 s tick a running turn
already has (`elapsed.rs`). No spinner, sheen, rotating verb or tip, pulse, or fold animation:
each was motion on a frequent path answering no question (a fold opens in the frame after the
click; the anchor keeps the clicked row where it was). A request that needs the person is said once,
on its panel (`▲ Needs you`, still), and the footer leaves the panel's keys to it. A finished tool
call carries no mark (success is the default, so the `✗` stays the one mark in the column), the
rule above the box carries no title (the window title has it), and `ctx` appears from 60 % (not
actionable before). The end-of-turn line answers "what did it do?" (question 3); the bell and the
window title serve "does anything need me?" for a pane nobody is looking at.

## Journeys

**Open a session.** `herdr-tui` starts, connects, asks the keeper to replay, prints the
last turns into scrollback with a line saying how many earlier turns exist, and shows the
composer. Waiting for the phone to open the session says so (it does today).

**An agent needs me.** The card appears in the live area, above the status line: the
tool title, the command whole (wrapped, never cut; `Read all` only past ~12 rows),
options numbered. Keys are ignored for 400 ms after it appears (a keystroke meant for the
composer must not answer it). Digits answer only while the composer is empty.

**Follow.** Streaming text appears line by line above the status line. Tool rows appear when a
call finishes, folded; the status line names the running one.

**Steer.** `Enter` sends, `Ctrl-J` / `Alt-Enter` newline, `Ctrl-P` recalls (Up scrolls), `Ctrl-C`
stops a running turn and (idle, empty) leaves. Typed text survives a failed send.

**Queue.** `Enter` while a turn runs does not send: the message waits (`queue.rs`, at most 10,
memory only, per viewer, not shared with the phone's queue) as a `↳` row above the box, and goes
out one at a time when the turn ends; pictures are read then, not when queued. Same rule as the
phone: a turn that failed, was refused or was stopped from elsewhere *holds* the queue (`Held ·
reason · Enter resumes`; `Enter` on an empty box resumes it, and a held message blocks the ones
behind it so a refusal never reorders them); the person's own `Ctrl-C` is "stop this turn and send
what is queued now" (the working row says so), and what was typed meanwhile becomes one message
(messages with files are never merged: `[Image #n]` restarts at 1 per message). To edit one,
`Backspace` on an empty box takes the newest back (the gesture that takes the last attached file
off), and a click on a `↳` row takes that one back; there is no command for it, and `Alt-↑` is not
used because many terminals deliver the wheel as Up/Down. Because the queue dies with the program,
`Ctrl-D` and the idle `Ctrl-C` ask twice,
`/new` and `Ctrl-R` refuse, and exit prints `Not sent: …` for each. There is no steering from the
desk, even for agents that take it: the keeper does not log a steered message, so a re-attach would
lose it from the replay (`docs/AGENT_SESSIONS.md`, "Known gap, in the keeper").

**Commands.** `/` opens a list above the input (this program's commands first, then the agent's
from `available_commands_update`); `Tab` completes, `Enter` runs, `Esc` closes. `/model`,
`/thinking`, `/mode` open a picker (or take a name: `/model opus`) and send
`session/set_config_option`, as the phone does; refused while a turn runs. `/new` (alias `/clear`)
starts a fresh keeper session of the same agent in the same folder in this pane and leaves the old
one running. None of these is sent to the agent as chat: omp's ACP mode has no `/clear` or `/new`
(only its own TUI does), so they would reach the model as a message and clear nothing. A `/word`
the agent does not list is held once (Enter again sends it), as the phone's `UnknownCommandGuard`.

`/plan` switches to the mode named plan (again: back to the mode it left, else `default`),
Shift-Tab steps to the next mode, `/settings` lists every select option the agent reported that
has a choice to make, `/info` (aliases `/version`, `/about`) writes the version, folder, program
and session id into the conversation. In the list, skills (`skill:name`) follow the agent's
commands and also answer to their name without `skill:`; a name typed in full is the first row.

A mode that lowers the guard (`risk.rs`, a port of the phone's `mode_danger.dart`: bypass,
full access, accept edits, auto...) is never reached by Shift-Tab, which skips it. Chosen with
`/mode`, the first Enter says what it does and the same choice again confirms it (`/plan` back
to the mode it left is exempt: it was the person's own). A local command that cannot run
(`/model zzz`) leaves what was typed in the box; `/new` and Ctrl-R wait while files are attached.

**Files and pictures.** A path (or several, quoted or with `\ ` as terminals write a dropped file,
or `file://`) pasted into an *empty* box is attached, as the phone's `@file`; up to 10 a message,
listed as `+ name` on the row above the input. Pasted into text it stays text, since a person may
mean the path. A file goes as a `resource_link` (`name` relative to the session's folder, the
absolute `file://` `uri`, no title). A PNG, JPEG, GIF or WebP up to 5 MB goes as a picture (an
`image` block, base64, read when the message is sent) when the agent's `initialize` says
`promptCapabilities.image`; the list then says `· picture`, and the paste hint says `as a
picture` or why it is a link (the agent takes none, it is over 5 MB, or the message already
carries 20 MB of pictures: the keeper refuses a line over 32 MiB). A picture is read only if it
is still a regular file (a pipe or device goes as a link). Verified with omp: a picture from
outside the session's folder, no tools allowed, was read correctly.

**Pointing at a picture.** Each picture that is attached leaves `[Image #n]` in the box at the
cursor (a number it keeps while others come and go), so a message can say "the button in [Image #2]
is wrong". On send the text goes as typed, and each picture is introduced by a text block with its
placeholder (`[Image #2]`) followed by the picture (or its link), in order, so the words and the
pictures line up for the agent; the conversation shows `[Image #2] name` under the text. A box
with only placeholders still counts as empty for pasting a path. Backspace right after a
placeholder takes it and its picture off together; taking a picture off any other way (Ctrl-C,
`/files`) takes its placeholders out of the text; numbering starts again after a send. Verified
with omp: with a blue picture as `[Image #1]` and a red one as `[Image #2]`, "which image number
is red?" answered `2`.

A screenshot on the clipboard: a terminal pastes text only, so `Ctrl-V` (and an empty paste, which
is what a terminal that binds Ctrl-V sends when the clipboard holds a picture) reads it with
`wl-paste`, `xclip` or `pngpaste` (`clip.rs`, on a thread, 4 s a tool), checks it starts like a
PNG, JPEG, GIF or WebP, saves it as `~/.herdr-mobile/inbox/tui-<session>/clipboard-<secs>-<n>.<ext>`
(the phone's inbox: folders 0700, files 0600) and attaches it as any file. Each Ctrl-V adds one:
up to 10 files and 20 MB of pictures a message; the list shows them by file name. Verified with
omp and a stand-in `xclip` (two pictures, red then blue, no tools allowed: "First: red. Second:
blue."). Not verified: a real Wayland or X11 clipboard, macOS `pngpaste`.

Taking them off: Backspace on an empty box takes the last one off (a note says which), Ctrl-C takes
all off, `/files` (aliases `/attachments`, `/detach`) opens a picker on the list and Enter takes the
one chosen off. The row says the first two when the screen is wide enough. A refused send gives
the text and the files back.

**Updating.** `/update [check|VERSION]` runs `update::run` (the same code as `herdr-tui update`) on a
thread, with the progress in the footer, so the session stays alive; the program file is replaced
whole by a rename after its checksum matches, and the open copy keeps running its old file. When
a new file is in place the conversation says so and `Ctrl-R` loads it (the same path as a copy
installed by the app). On the list, Enter on `/update` only completes the name: a stray Enter never
starts a download. Leaving during a download abandons it (the file is untouched; a scratch
folder `.herdr-tui-update-<pid>` beside the program is left behind).

**Something is wrong.** The keeper closed, the agent exited, the session did not open:
a note in scrollback and a status line in words, with what to do (`herdr-tui` exits
non-zero so the pane shows it, never a blank screen).

## Parity with the other surfaces

A permission is answered on the phone card, the notification and here. Properties the
person relies on, filled from each surface's code:

| Property | Phone card/dock | This viewer (target) |
| --- | --- | --- |
| Shows the command | whole, `Read all` | whole |
| Guard against a stale answer | `tapGuard` after arrival | 400 ms after arrival |
| Hold for risky / standing grants | hold | second deliberate key, labelled |
| Confirmation | haptic, then next card | note in scrollback |
| Failure path | honest, Retry | note, card stays, can retry |
| Several waiting | walk them | `1 of N`, answer in order |
| Question (form) | answered in sheet | panel, a field at a time, answers in sight, last `Enter` sends; same 400 ms guard; `Esc` declines; a URL question is left to the phone |

Open cells are findings, not silence: risky-hint rules (`mode_danger.dart`,
`permission_subject.dart` hold the phone's rules; do not re-derive them, port or share).
A text field's `pattern` and `format` are not checked here (the phone checks `pattern`);
the agent checks again.

## Updating, and what every release must keep

An installed `herdr-tui` updates itself by asking GitHub for files **by name**, and the oldest copy
in the field keeps doing so for as long as it runs. Every release therefore keeps:

- the files `herdr-tui-linux-x86_64`, `herdr-tui-linux-aarch64`, `herdr-tui-macos-arm64` and
  `herdr-tui-macos-x86_64`, and `herdr-tui-SHA256SUMS` listing them (`<hex>  <name>`);
- the URL layout `github.com/tuan3w/herdr-mobile/releases/{latest/download,download/vX.Y.Z}/<file>`;
- `herdr-tui --version` printing `herdr-tui X.Y.Z`, with no session and no arguments needed.

Three places name the files: `update/release.rs` (the client), `tool/install-tui.sh` and the
`herdr-tui` job in `.github/workflows/release.yml`. A test in
`release.rs` reads the other two and fails when they disagree. Add a platform in all three in one
change; renaming a file strands every installed client older than the rename (it says "could not
download" and keeps running), and `install.sh` is then the only way back.

Who can update itself: before 0.1.30 there is no binary; 0.1.30 to 0.1.37 have no `update` (run
`install.sh` again); 0.1.38 and later have `herdr-tui update`. A session older than 0.1.38 does not
notice a replaced file, so reopen it with `herdr-tui attach ID`. The app does not install or
replace `herdr-tui` (it installs `herdr-host`, `docs/HOST_PROTOCOL.md`): update the one you
installed yourself.

## Plan

| Step | Today (v0) | Problem | Change |
| --- | --- | --- | --- |
| Screen model | Alternate screen, history in RAM by item count | Memory not bounded by size, wrap redone per frame | Byte-bounded store, per-width cache |
| Streaming | Redraw whole history per event | Cost grows with history | Width-keyed line cache, redraw only on change |
| Colour | Cyan/yellow/etc. | Fine in few themes | ANSI palette per codex `styles.md`; default fg |
| Permission | Digit answers instantly | Stale answer, no hold, no `Read all` | Guard, second key for standing grants |
| Tool rows | One row each | Noise on long turns | Group consecutive calls, cap, count |
| Tests | Unit tests of model | Nothing proves the screen | vt100 snapshot of each state, worst-case data |
| Questions | Note only | Dead end | Answer forms in the card |
| Herdr | Reported from inside a herdr pane (`report-agent`, `viewer/src/herdr.rs`) | The python `view` did this; the viewer had to | Done |

## Owner decisions

1. **Alternate screen** (decided). Inline scrollback was the other option.
2. **Replay on open.** The whole replay goes into the byte-bounded store first; delta replay
   (`_meta.herdr.since`) only if opening a long session is slow.
3. **Distribution** of the binary to hosts: `install.sh` (a person) and `herdr-tui update`; the
   app does not install it. A session the phone starts gets its herdr tab only when a
   `herdr-tui` is on that host (`docs/AGENT_SESSIONS.md` "Shared sessions").
