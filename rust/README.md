# herdr-tui

A terminal client for coding agents, run as a herdr session. Start `omp`, `claude`, `codex` or
`pi` in your current folder and work with it in a full-screen UI; the session keeps running when
you leave it and shows up on your phone. Design: `docs/TUI.md`.

![a session with a permission request](../docs/tui/04-permission.png)

## Build

```sh
cd rust
cargo build --release          # target/release/herdr-tui, about 2.6 MB (1 MB of it the code grammars); about 6 MB of memory with a live session before code is coloured, about 1.5 MB more per language coloured (desktop, measured for Rust)
cargo test --workspace         # no python: the scripted agent and the fake herdr are Rust bins (crates/testkit)
```

Needs Rust 1.88 or newer. Build and install in one step (it works while a session is open; that
session keeps the old version):

```sh
tool/tui-install.sh            # release build -> ~/.local/bin/herdr-tui, a few seconds
tool/tui-install.sh --check    # fmt, clippy and tests first
```

## Install without Rust

Each release carries `herdr-tui` for Linux and macOS (x86_64 and arm64) with a `herdr-tui-SHA256SUMS`:

```sh
curl -fsSL https://github.com/tuan3w/herdr-mobile/releases/latest/download/install.sh | sh
```

The script checks the download against the checksums before it installs to `~/.local/bin`
(`BIN_DIR=` and `VERSION=` change that). Releases from before the desk client have no binary.

Once installed, `herdr-tui` updates itself:

```sh
herdr-tui update --check      # says whether the latest release differs from this one; changes nothing
herdr-tui update              # installs the latest release
herdr-tui update 0.1.35       # installs that release, older ones too: the way back if a new one misbehaves
```

On a terminal the download shows as one line that grows (`▕███████▌   ▏ 40%  1.0 MB / 2.6 MB  758 KB/s`); in a
log or a pipe it prints one plain line per step. It downloads with `curl` (or `wget`, without the bar), checks the file against the release's `herdr-tui-SHA256SUMS`
(`sha256sum` or `shasum`), runs it once with `--version`, and only then renames it over the old one, so
a failure at any step leaves what is installed as it was and sessions that are open keep running. The
latest release is never a downgrade; a version you name is installed even if it is older. Releases
before 0.1.30 have no desk client. The app does not install or replace `herdr-tui` (it installs
`herdr-host`), so update the one you installed.

A `herdr-tui` that is open notices that its file was replaced (when something wakes the screen, at most
every few seconds; there is no timer) and says so in the footer when idle: `↻ herdr-tui 0.1.38 is
installed · Ctrl-R loads it`. `Ctrl-R` makes that process the new version in the same terminal and pane,
attached to the same session (the keeper holds it, so nothing is lost). It waits when there is a message
in the box or a request waiting, so nothing typed or asked is dropped. A `herdr-tui` older than 0.1.38
does not look, so reopen those once with `herdr-tui attach ID`.

## The keeper

Every session is owned by a small `keeper` process, so it survives closing the terminal. The keeper is
the Rust `keeper` library linked into this binary: `herdr-tui` starts a session by re-running itself as
`herdr-tui keeper-daemon` (detached, in its own process group), so there is nothing else to install and
no `python3` or `herdr-host` is needed on the machine. Its records, sockets and replay log are in
`~/.herdr-mobile/keepers/`, the same ones the phone's `herdr-host` reads, so a session started here can
be attached from the app and the other way round. The agent you start must be installed: `omp`, or
`claude-agent-acp`, `codex-acp`, `pi-acp` (or `npx`, which is used as a fallback).

## Run

```sh
herdr-tui                          # new omp session in the current folder
herdr-tui --agent claude           # another agent
herdr-tui --agent codex --cwd ~/work/api
herdr-tui attach abc123            # reopen a session that is still running
herdr-tui ls [--all]               # sessions on this machine, what needs you first
herdr-tui kill abc123 def456       # end sessions for good
herdr-tui update [--check] [VER]   install the latest release, or VER (see Install)
```

Leaving (`Ctrl-D`) does **not** stop the agent; it prints the id to come back with. To end a session
for good, `herdr-tui kill ID` (or stop it from the app).

## Small touches

- While the agent works the status row is still: `● Working 12s · Ctrl-C stops`. Nothing in the
  viewer moves except that counter, once a second; at rest nothing wakes the loop.
- A request that needs you is said once, on its panel (`▲ Needs you`, not pulsing); the footer does
  not repeat it. A fold you open is open in the next frame.
- `Enter` while the agent works queues the message (`↳` above the box); it goes out when the turn
  ends. `Backspace` on an empty box or a click on its row takes one back. `Ctrl-C` stops the turn and sends the queue now. See `docs/TUI.md`, "Queue".
- Every turn ends with one line of what it did: `✓ Done in 16s · 1 file +6 −2 · 5 tools · 1 failed`.
  The mark turns to `!` only when the last call failed and nothing put it right.
- A new session says it is ready and offers two things to try.
- When a permission or a question arrives the terminal bell rings once and the window title becomes
  `▲ omp needs you` (and `● omp working` while it works), so a pane in the background still calls you.

## Keys

| Key | Does |
| --- | --- |
| `Enter` | send the message (queued while the agent works; with the box empty, resumes a held queue; or, with a request waiting, confirm the chosen option; on a question, confirm the field) |
| `Backspace` | with the box empty and messages queued, take the newest back into the box (a click on a `↳` row takes that one) |
| `Ctrl-J` / `Alt-Enter` | new line in the message |
| `↑` `↓` | scroll the conversation 3 lines; with a request waiting and the box empty, choose an option; inside a multi-line message they move the cursor |
| mouse wheel | scroll the conversation 3 lines |
| click | open or close a tool call, a run of them or the thinking; on the permission or question panel, choose an option, and click the chosen one again to answer with it (on a question's ticks, tick it) |
| drag | select text on the screen and copy it (the footer says how many characters); any key or click drops the highlight |
| `PgUp` `PgDn` `Home` `End` | page, start of the conversation, back to the newest |
| `Ctrl-P` / `Ctrl-N` | recall earlier sent messages |
| `Tab` / `Shift-Tab` | choose an option on the permission panel (wraps around); on a question, `Shift-Tab` goes back a field |
| Space | on a question's ticks, tick or untick the marked one |
| `1`–`9` | answer a waiting permission directly, or mark that choice on a question (box must be empty; ignored for 0.4 s after it appears) |
| `Ctrl-C` | stop the running turn; with nothing running, clear the box, then leave |
| `Esc` | browse: move among what the agent did and open or close it (below); with a request waiting, withdraw it, and decline a question |
| `Ctrl-T` | open or close every thought at once |
| `Ctrl-W` `Ctrl-U` | delete a word, clear the box |
| `Ctrl-R` | when the footer says a newer herdr-tui is installed, load it into this session |
| `Ctrl-L` | repaint the screen (also happens when the window regains focus), for when another program has written on the terminal |
| `Ctrl-D` | leave (the session keeps running); with messages queued, press twice |

An answer that stays allowed (*Always allow*) asks for the same number, Enter or click twice.

The mouse is taken so a click can open things and a drag can select text. The copy leaves as an OSC 52
write, which herdr and most terminals pass to the clipboard (inside tmux, set `set-clipboard on`).
`HERDR_TUI_MOUSE=off` gives the mouse back to the terminal: a plain drag (`Option`-drag in iTerm2) is then
the terminal's own selection, the wheel still scrolls (as Up and Down), and clicks do nothing.

### Questions

An agent's question (omp's `select`, `confirm` and `input`, Claude's AskUserQuestion, Codex's
request_user_input) is answered on a tinted panel like a permission's: `▲ Needs you · Question`, the
agent's words, then its fields one at a time (`2 of 3`). A choice is picked with `↑` `↓`, a number or a
click, and confirmed with `Enter` or a second click; a yes/no is two choices; ticks toggle with Space, a
number or a click. Text and numbers are typed in the box below, which belongs to the question while it
waits: what you were writing is set aside and comes back when the question goes, so `Enter` never sends a
message by accident. A wrong answer (a required field left empty, not a number, out of range) is named in
the footer and what you typed stays. What you answered stays on the panel, one line per field, and the
last `Enter` sends it all, as the phone would. `Shift-Tab` goes back a field; `Esc` declines. Nothing is
chosen for you and nothing is sent on a timeout; a key in the first 0.4 s after the question (or the next
field) appears does nothing. A question answered on the phone leaves the panel with a note saying so. A
question this terminal cannot show (a URL to open) is noted and left to the phone.

## Browsing and folding

A finished run of three or more tool calls folds into one line (`▸ 4 tool calls · 1 failed · Reading ×3 ·
Listing`); a call that failed always stays in view under it. Thoughts fold to `… thinking`; long output and
big diffs open to everything that was kept. `Esc` (with the box empty) starts browsing at the newest foldable
thing: `↑` `↓` (or `k` `j`) move, `→` `Enter` Space (or `l`) open, `←` (or `h`) close, `a` opens all, `z` closes
all, `Esc` or `i` goes back. Typing any other letter leaves browsing and types it. A click on any line of a
foldable thing opens or closes it, and its first line stays where it was (unless the whole conversation fits
on the screen, which is drawn from the bottom up).

## Look

Hierarchy, loudest first: your message in its band and the permission panel; the agent's words; what the
agent did (quiet, uncoloured once finished; commands are coloured only while running or failed); chrome
(hints, status, the footer). Secondary text is computed to hold a 4.6:1 contrast against your terminal's
background, and the colours are tuned for light or dark and tested against both. A table is a faint box of
connected lines, with a rule under the header and, when a cell wraps, between rows; a column of figures lines
up on the right, a cell keeps its code and bold, and a table still arriving shows one quiet line until it is
whole. Code is coloured by its language with the same palette (a fenced block, and the changed lines of a
diff by its file's extension). A table too wide to align shrinks and
wraps its long cells; one with too many columns, or whose sentences would be squeezed to a few words a
line, becomes a card per row. A link shows where it goes after its label. An added or removed line of a
diff sits on a faint green or red row.

What you said sits in a tinted band behind a `›`; the agent's words hang from a `•`; tool calls, notes
and results open in the same two-column gutter. A shell command is coloured (command names blue, flags
red). A permission request is a tinted panel with the question, the command whole, the choices and the
chosen one marked. The input is its own tinted block, like your messages above it (or, where the tint is
unknown, a rule above and below; `HERDR_TUI_INPUT=rules` asks for that). The last line says what you
are talking to and where:
`Sonnet 5.5 · thinking high · act · ctx 72% · omp · ~/workspace/herdr-mobile` (`ctx` appears from 60 %).
The model, thinking level
and mode come from what the agent reports (its config options), so a line shows only what it has said.

The tint is derived from your terminal's real background (asked once at start with OSC 11), so it is a
light grey on a light terminal and a lighter band on a dark one. If the terminal does not answer, it falls
back to `COLORFGBG`, then to a bar down the left edge. `HERDR_TUI_THEME=light|dark` forces it; `NO_COLOR`
turns colour off.

## Screens

Each has a `-light` twin in `docs/tui/`, drawn from the real frames by `python3 tool/tui-shots.py`
(no terminal involved, so the colours are exactly what the UI produces).

| | |
| --- | --- |
| Empty, typing | `01-empty`, `02-typing` |
| Working | `03-working` |
| Needs you; confirm a standing grant | `04-permission`, `05-confirm-always` |
| 58 columns | `06-narrow` |
| Done; scrolled back | `07-done`, `08-scrolled` |
| Tables: too many columns, long cells | `09-wide-table`, `10-table-wraps` |
| Browsing a folded run | `11-browse` |
| Coloured code, numbered list past 9, a link | `12-code` |
| A table still arriving | `13-streaming` |
| An agent's question | `14-question` |
| Messages queued while the agent works; a held queue | `16-queued`, `17-queued-held` |

## Inside herdr

Run in a herdr pane, `herdr-tui` reports what the session is doing (`working`, `blocked` while a request
waits, `idle`) to herdr's agent list, and releases the pane when you leave (`herdr-mobile` source, agent
`omp · phone`, with `herdr-tui attach ID` as the resume command). Because of that, a session started
here does not make the keeper open a second herdr tab for it (it starts the keeper with
`HERDR_MOBILE_NO_PANE=1`).

## Other programs writing on your terminal

While `herdr-tui` is open, a background job of the same terminal that tries to write (an image viewer
started with `&`, a build left running) is stopped by the kernel instead of printing over the screen
(`TOSTOP`). The shell lists it as `Stopped`; `fg` or `bg` resumes it. A program that is not a job of this
terminal (started with `setsid`, or by another terminal that shares the tty) cannot be stopped this way; for
that, `Ctrl-L` repaints, and so does bringing the window back into focus. Codex has the repaint but not the
stop. Checked by `python3 tool/tui-check-background-writer.py`.

## Staying in step with the app

The viewer and the app's `herdr-host` share one keeper library (what `start` prints, its exit codes, the
record fields, the wire, the replay log) and the agent table (`crates/keeper/routes.json`). The contract
is checked on every `cargo test` against the real binary: `crates/host/tests/keeper_contract.rs` runs
`herdr-host` with a scripted agent (hermetic: its own home, no herdr, never a real agent), and
`crates/viewer/tests/cli.rs` starts, lists and kills a session through `herdr-tui` itself and asserts the
daemon is `herdr-tui keeper-daemon` and that no `python3` ran. A change in the keeper that breaks the
viewer fails there, so the viewer is updated in the same change.

## Exit codes

`0` left normally · `64` bad arguments · `66` no such session or folder · `67` the agent exited ·
`69` agent or keeper not installed · `70` the keeper did not start.

## Layout

```
rust/crates/acp      JSON-RPC and ACP messages (pure)
rust/crates/keeper   keeper library: records, agent table, replay log, daemon, `ctl` (linked into herdr-tui and herdr-host)
rust/crates/host     herdr-host: `serve` and the keeper command line the phone runs
rust/crates/viewer   transcript, session state machine, markdown, UI  (the herdr-tui binary)
```

## Not yet

A session picker (`resume`). The keeper's herdr-pane tab, alert hook (`HERDR_KEEPER_ON_BLOCKED`) and macOS
launchd start are in the Rust keeper (`pane.rs`, `alerts.rs`, `launchd.rs`); the launchd start's text and
`launchctl` command lines are unit-tested, but it has not been run on a Mac (unverified).
