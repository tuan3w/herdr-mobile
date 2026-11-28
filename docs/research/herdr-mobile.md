# herdr mobile

Research note from the repo’s own docs and code (11 Nov 2026). Sub-agents could not be started on this plan (every model slug was rejected as unavailable), so this was read directly.

## What it is

herdr mobile is a free, GPL-3.0-only Android client for [herdr](https://herdr.dev). It shows every coding agent on every machine you run herdr on, tells you when one needs you, and lets you answer from the phone. It is built for a bad network and one free hand. Current app version in `app/pubspec.yaml`: **0.1.61+5098**. Source: https://github.com/tuan3w/herdr-mobile. Site: https://tuan3w.github.io/herdr-mobile/.

Source: `README.md` lines 1–8, 138–143; `app/pubspec.yaml` line 22.

The person it is for is a supervisor, not a pair-programmer: agents work on their machines while they are elsewhere, with seconds of attention (`AGENTS.md`, “Who it is for”).

## What it does

- One board of terminal agents and agent sessions, grouped by needs-you, working, done, and idle. Risky answers (push, delete, “don’t ask again”) must be held, not tapped. Nothing is approved automatically; a permission always shows its command (`README.md` “What it does” and “The app’s security rules”).
- Chat or live colour terminal, swipe between agents. Terminal key row, Ctrl/Alt, slash commands (`README.md`).
- ACP chats: start Claude Code, Codex, omp, or pi on a host. The agent runs inside a python3 keeper under `~/.herdr-mobile/` so it keeps working when the phone drops. omp is verified end to end; Claude Code has run full turns with permission requests; Codex chats but its approvals are unverified; pi starts but has not completed a turn (`README.md`, `docs/ARCHITECTURE.md` §1).
- SFTP file browser: source, Markdown, JSON, images, hex (`README.md`).
- Optional local notifications, off by default. Connections stay up 90 seconds after you leave; after that nothing runs in the background unless you turn alerts on (`README.md`, `docs/ALERTS.md`).

## How it connects

```
phone ──SSH──▶ machine A ── one multiplexed channel ──▶ herdr socket
      ──SSH──▶ machine B ── …
```

No relay, no public port, no account. Auth is an SSH key, a password, or Tailscale SSH. The phone sends a short python3 mux script with the channel; it is not installed. If python3 or the socket is missing, it falls back for 30 seconds to `herdr remote-api-bridge` (herdr ≥ 0.9), then `socat`, then a short python3 relay (`README.md` “How it works”; `docs/ARCHITECTURE.md` §2).

On the phone: a Flutter UI isolate (screens, view models, ACP client) and one transport isolate per machine (SSH via `dartssh2`, zlib, JSON, SFTP). On the host: sshd, herdr’s API socket, the mux and events scripts, an optional keeper per agent session, and the sftp subsystem (`docs/ARCHITECTURE.md` §1, §7).

Install: one APK for Android 7.0+, 32- and 64-bit ARM, checked against `SHA256SUMS`. Each machine needs sshd reachable from the phone, herdr running, and for agent sessions python3 3.6+ plus the agent (`README.md` “Install”).

## Security model (as the project states it)

- Host keys are pinned on first use; a changed key is a hard stop. Secrets live in the platform keychain, not preferences (`README.md`).
- The only network socket the app opens is SSH, plus loopback listeners on the phone for pages forwarded from a machine. `app/pubspec.yaml` has no HTTP client, analytics, crash reporting, or telemetry dependency (`docs/ARCHITECTURE.md` §5).
- Bad credentials, an unreadable key, a changed host key, or a missing bridge are fatal: the machine goes to `LinkState.attention` and retries stop (`docs/ARCHITECTURE.md` §2).
- A page in the in-app WebView may load only `http://localhost` or `127.0.0.1` on a port the bridge opened. Navigation to the public web does not proceed on its own. A page’s own scripts, images, frames, and `fetch` still load as in a browser; form POST and iframe loads are not intercepted on Android (`docs/ARCHITECTURE.md` §5).

## Limits the project states

- Windows hosts are not supported (the bridge is a POSIX shell script).
- A terminal pane is read-only text, at most herdr’s 1,000 rows of scrollback. herdr cannot resize a pane to the phone’s width over its API.
- Keys are pasted or generated on the phone; there is no key file picker.
- Background alerts keep a quiet “Watching” service and cost battery (`README.md` “Known limits”).

## Stack and layout

Flutter app (`app/`), Dart SDK `^3.13.5`, Flutter ≥ 3.47. Layering is `ui/` → view models → `data/repositories` → `data/services`. Widgets do not hold transports, except the machine form’s Test (`docs/ARCHITECTURE.md` §7; `README.md` “Develop”).

Screens documented under `docs/screens/`: board, session, attach, settings, web, agent-screens, files, markdown, photos.

Also in the repo:

- `rust/`: `herdr-tui`, a desktop terminal client for the same agents. A session keeps running when you leave it and shows up on the phone (`rust/README.md`).
- `site/` and `tool/build-site.py`: the GitHub Pages site.
- `app/test/`: unit and widget tests (architecture doc says 210 test files), including real keeper and bridge scripts, captured agent traces, and screenshot renders (`docs/ARCHITECTURE.md` §8).

## Recent releases (0.1.56–0.1.61, 8–9 Nov 2026)

From `CHANGELOG.md`:

| Version | Theme |
| --- | --- |
| 0.1.61 | Delete a closed worktree to reclaim disk; hold to confirm; refuse if uncommitted changes |
| 0.1.60 | A failed command the agent later retried successfully is no longer shown in red under the answer |
| 0.1.59 | Long app names wrap in “Made” |
| 0.1.58 | Hook-reported labels on the board (status, test count, build stage) |
| 0.1.57 | Videos in Files play again |
| 0.1.56 | Sheets follow the finger |

Several of these notes say they were checked in tests or on a computer, not on a phone.
