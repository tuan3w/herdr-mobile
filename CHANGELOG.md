# Changelog

What changed for the person using herdr mobile, newest first. Versions follow
`0.1.x` patch releases; each section is the release notes of its GitHub
release.

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
