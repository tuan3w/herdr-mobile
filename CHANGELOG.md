# Changelog

What changed for the person using herdr mobile, newest first. Versions follow
`0.1.x` patch releases; each section is the release notes of its GitHub
release.

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
