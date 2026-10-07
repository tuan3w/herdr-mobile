# Changelog

What changed for the person using herdr mobile, newest first. Versions follow
`0.1.x` patch releases; each section is the release notes of its GitHub
release.

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
