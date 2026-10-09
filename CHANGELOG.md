# Changelog

What changed for the person using herdr mobile, newest first. Versions follow
`0.1.x` patch releases; each section is the release notes of its GitHub
release.

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
