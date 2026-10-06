# Agent sessions (ACP)

Direction for the second session type, and what is built. Terminal sessions
exist; agent sessions are new. Built and exercised against a real `omp acp`
over SSH: the protocol layer (`app/lib/data/acp/`), the host keeper, the SSH
exec channel, the session repository, the board section, the start form and
the chat screen. Checked through the keeper and the app's own client against
omp, Claude Code, Codex and pi (see "Checked on this machine" below for what
each did); only omp was also driven from a phone. Facts below cite the upstream
source they come from (the ACP spec, herdr, the agents' ACP adapters) or are
marked UNVERIFIED. omp facts come from `omp acp` 18.4.12 on this machine.

## Two session types, one board

| | Terminal session | Agent session |
| --- | --- | --- |
| What the phone is | An observer and keyboard for a TUI that runs in a herdr pane | An ACP client: it owns the conversation |
| Source of truth | The screen: `pane.read` rows, status from herdr's detector | Structured messages: `session/update`, requests |
| Prompts and questions | Scraped from the screen (`prompt_detector.dart`), layouts drift weekly | `session/request_permission`, `elicitation/create`: typed, with tool kind and raw input |
| Slash commands | Hand-written tables, SFTP discovery (`slash_catalog.dart`) | `available_commands_update`, with input hints |
| Good for | Anything already running; every TUI feature; agents without an ACP route | Phone-first work: approve, answer, steer, read a clean transcript |
| Cannot | Tell reliably what a prompt will do | Attach to a TUI already running (below) |

They are complementary. Terminal sessions stay the compatibility layer and the
way to watch what the desktop is doing; agent sessions are for what you start
or resume from the phone. Both feed one board.

**One board.** A board row is a session with a `phase`. Terminal rows get it
from herdr's agent status (`idle`, `working`, `blocked`, `done`); agent rows
from `AgentSessionState.phase` (`idle`, `working`, `blockedOnPermission`,
`blockedOnQuestion`, `session_state.dart`). The board needs only: source
(terminal or agent), machine, title, phase, time in phase, and for a blocked
row the same card model (`subject`, `risk`, choices) regardless of source. A
permission request and a scraped prompt both fill it: `PromptInfo.subject` /
`QuickReply.risk` (Approvals) are that shared model. Opening a row opens the
pane (terminal) or the transcript (agent).

## Data model (built)

Layers, all pure Dart (no Flutter), `app/lib/data/acp/`:

- `json_rpc.dart`: `AcpTransport` (`lines`, `send`, `close`), `splitLines`
  (synchronous byte-to-line splitter, same rule as `muxMessages`: never
  `await for` an SSH channel), `JsonRpcConnection` (ids, per-request timeout,
  incoming requests to a handler, `$/cancel_request` both ways, pending requests
  fail with `JsonRpcClosedException` at EOF, malformed lines go to `onProblem`).
- `acp_models.dart`: tolerant v1 models plus the v2 draft fields that cost
  nothing (`user_message`/`agent_message` upserts, `state_update`,
  `tool_call_content_chunk`, `plan_update`, `subject` on permission requests,
  `availableCommands` in session responses). Unknown variants are
  `UnknownUpdate(type, raw)`, `UnknownBlock`, `UnknownConfigOption`; `_meta` is
  kept as `meta` (also on chunks, upserts, `session_info_update`,
  `usage_update` and the prompt response, whose `usage` is `TurnUsage`).
- `session_state.dart`: `AgentSessionState`, a pure reducer. `apply(update)` for
  agent updates; `withUserMessage`, `withTurnStarted/Ended`, `withCancelRequested`,
  `withPending/withoutPending`, `withSetup`, `withDisconnected` for what the
  client does. Messages are keyed by `(role, messageId)` (omp reuses one id for
  the thought and the answer of a turn), chunks append and merge adjacent text,
  v2 upserts replace/keep/clear content, a replay may open a message with
  `content: []` then stream chunks. Tool calls are keyed by id with patch
  semantics (omitted keeps, null clears; an update for an unseen call creates
  it); command output from `_meta` is appended per call (`ToolOutput`). A turn
  that ends in a refusal or a limit adds a `TranscriptStop`. Plan, commands and
  config options are replaced whole. The local echo of the user's prompt is
  dropped when the agent repeats it. The message streaming in right now keeps
  its text in a `LiveText` that chunks append to in place (the one exception to
  immutability; "The streaming fast path" below). `apply(update, at:)` stamps
  `lastActivityAt`, and the time of what it adds (`TranscriptItem.at`; none
  while the state is `replaying`); the reducer itself reads no clock. An agent
  switching the mode on its own adds a `TranscriptNote`. See "The turn model".
- `acp_client.dart`: `AcpClient` (`initialize`, `newSession`,
  `loadSession`/`resumeSession`, `listSessions`, `prompt`, `steer`, `cancel`,
  `setMode`, `setConfigOption`, `closeSession`) and `AcpClientHandler`
  (permission and elicitation; no default implementation, nothing is ever
  allowed silently). It checks capabilities before calling (images, audio,
  embedded context, steering), offers no `fs/*` or `terminal/*` (answered
  `-32601`), offers form elicitation only (URL mode answered `-32602`, as the
  spec says), and has no timeout on a prompt turn. One prompt at a time per
  session: a second throws; "Steering and input" below says what the app does
  with a message sent mid-turn.
- `process_transport.dart`: `Process` transport for tests and desktop tooling
  only. The SSH transport is written by the orchestrator over the existing exec
  channel (`AcpTransport` is `lines` + `send` + `close` so it fits).

Cancellation follows the ACP spec (https://agentclientprotocol.com, "Prompt
turn" and "Cancellation"): `cancel()` sends `session/cancel`, marks unfinished tool
calls cancelled, answers every waiting permission as `cancelled` itself, and
`prompt()` completes with `StopReason.cancelled` even when the agent reports the
cancellation as an error. A request the agent withdraws with `$/cancel_request`
is answered `-32800` once and the handler's `cancelled` future fires.

## Routes: how each agent speaks ACP

| Agent | Command on the host | Notes (path) |
| --- | --- | --- |
| omp | `omp acp` (native) | `oh-my-pi/packages/coding-agent/src/modes/acp/`. Caps: `loadSession`, `list/fork/resume/close`, image + embeddedContext. Config options `mode`, `model` (781 entries), `thinking`. Questions via `elicitation/create` (`acp-agent.ts:315-470`): `select` is a string enum, `confirm` a boolean, `input` a string, each as field `value`. Replays history on `session/load` (`acp-agent.ts:2270`). Extension methods `_omp/*` (`acp-agent.ts:1120`). Needs client `elicitation.form`, else it auto-answers (`:2014`). |
| Claude Code | `npx -y @agentclientprotocol/claude-agent-acp` | `claude-agent-acp/src/acp-agent.ts`. Wraps the Claude Agent SDK, uses the `~/.claude` login. Caps: load, list, resume, close, fork, delete. Permission option ids `allow-once` (allow_once), `allow-with-updates` (allow_always), `reject`; plan exit has several allow_always ids. AskUserQuestion becomes a form with an "Other" field, only if the client offers form elicitation (`:9299`). EOF/SIGTERM disposes and kills the CLI (`index.ts:91-107`). Reads `~/.claude/projects/*/<id>.jsonl`, so a second process can resume a TUI session (UNVERIFIED). |
| Codex | `npx -y @agentclientprotocol/codex-acp` | `codex-acp/src/CodexAcpServer.ts`. Spawns `codex app-server`. Needs a login (`api-key`, `chat-gpt`...). Approvals: `allow_once`, `allow_for_session` and `accept_execpolicy_amendment` (both allow_always), `decline`, `cancel`. `request_user_input` becomes a form. `session/list` shows TUI threads, but resume fails while another client holds the thread ("active writer", `CodexThreadErrors.ts:83`). No SIGTERM handler. |
| pi | `npx -y pi-acp` (community) or `pi --mode rpc` | `pi-acp/src/`. Spawns `pi --mode rpc`. Caps: load, list, delete; no resume/close/fork. pi has no tool-approval gate: permission requests exist only for extension `select`/`confirm`; `input`/`editor` are cancelled with a notice, no elicitation (`session.ts:932-1011`). Thought chunks not sent. `session/load` kills a live session with the same id (`agent.ts:946`). `pi --mode rpc` is JSONL, not JSON-RPC: `{type: "prompt"}` commands, `response` records, uncorrelated events, `extension_ui_request/response` (`pi-mono/packages/coding-agent/docs/rpc.md`). A client could speak it directly (turn ends at `agent_settled`); the adapter exists, so use it. |

**Checked on this machine (2026-10-04), through the keeper and the app's own
client, one tiny turn each, stores redirected to temp dirs:**

- **omp**: full turn with a permission, a link drop with the request pending,
  re-attach, answer; also driven from the phone.
- **Claude Code** (`claude-agent-acp` 0.85.1): a full turn. A `mkdir` asked for
  permission; the request carries `toolCall.rawInput {command, description}`,
  kind `execute`, and two options (`allow-once` / "Yes" allow_once, `reject` /
  "No" reject_once). `describePermission` shows the command and the path it
  touches. A safe `echo` is allowed by Claude's own rules and asks nothing.
- **Codex** (`codex-acp` 2.1.1): chat works. With an isolated `CODEX_HOME`
  no approval was ever asked: a write outside the sandbox ended in "the
  sandbox blocked it" without a request, and a `touch` in the workspace was
  reported done although no file appeared and no tool call was surfaced.
  Approvals and tool rows are unverified in the owner's real config.
- **pi** (`pi-acp` 0.0.34, pi 0.87.1): starts, `session/new` works, but the
  prompt gets no answer: pi's own RPC returns an assistant message with
  `stopReason: error` ("OAuth refresh failed for anthropic ... invalid_grant",
  the owner's pi login has expired) and the adapter ends the turn with a plain
  `end_turn`, hiding the error. The app flags a turn that ends with no answer
  (`The agent ended the turn without an answer ...`).

Other adapters read: `acp-adapter` (Go, ACP over `codex app-server`, `claude -p`,
`pi --mode rpc`) answers a `session/cancel` *request* and drops notifications
(`internal/acp/server.go:382-389`, UNVERIFIED in tests); treat third-party
bridges as needing a conformance check per agent.

## Attach to a session already running in a herdr pane

ACP does not do this: over stdio the client launches the agent. Per agent:

- **omp `/collab`: partial.** Hosts register in `~/.omp/run/collab-hosts/<id>.json`
  + `<id>.sock` (`collab/registry.ts:166-502`). The socket answers `snapshot`
  (`busy`, `inputRequired`, cwd, model) and `link`; it carries no events and
  takes no prompts. Attaching needs the relay (WebSocket, AES-GCM envelope,
  `collab/protocol.ts`); a pending dialog is re-sent to the next writable guest
  (`collab/host.ts:794`). No self-hostable relay besides a local stand-in
  (`packages/collab-web/scripts/local-relay.ts`). Cheap win: poll `snapshot`
  over SSH to show `busy`/`inputRequired` for panes herdr cannot classify.
- **Codex: yes if the TUI uses the shared daemon.** `codex app-server daemon`
  (`--listen unix://`) lets a second client `thread/resume` a loaded thread and
  receive replayed pending requests (`app-server/src/request_processors/thread_lifecycle.rs:716-826`,
  `outgoing_message.rs:446`); `thread/status/changed` carries `waitingOnApproval`
  and `waitingOnUserInput`. It only helps when the TUI was started against the
  daemon (`DaemonAutoStart`; default UNVERIFIED). The phone would speak
  app-server JSON-RPC, not ACP.
- **pi: no.** The stable TUI is not attachable; `PI_EXPERIMENTAL=1 pi server`
  has sockets and attach/detach (`src/experimental/`), no approvals found.
- **Claude Code: no mechanism found.**

Verdict: do not build attach-to-live now. Agent sessions are started from the
phone; terminal sessions remain the way to watch the desktop.

## The keeper (host-side)

Problem: closing stdin ends the agent (claude-agent-acp, codex-acp and pi-acp
all exit on EOF; `index.ts` of each). A phone on a train drops SSH every few
minutes, and a permission or a question waiting at that moment would be lost.

**What exists.** None of the four projects read is a keeper:

- `stdiobus`: C supervisor routing NDJSON by `sessionId` to worker pools,
  restart-rate window, SIGTERM then SIGKILL drain; the kernel source is not in
  the clone (only binaries, `examples/README.md`), no event log, no replay, no
  permission handling.
- `agentpool`: `src/acp/bridge/ws_server.py` spawns the agent once and swaps a
  single client slot (`:106-139`) but drops output while no client is attached
  and holds nothing; its `NoOpClient` auto-grants permissions
  (`client/implementations/noop_client.py:51`). Spawn/shutdown ladder
  `transports.py:437-461` is reusable.
- `acp-adapter` (Go) and `claw-orchestrator` (TS): in-process facades, one
  client, the backend dies with the connection (`internal/codex/process.go:107`,
  `bin/acp-server.ts:92-98`); pending requests fail when the client goes
  (`server.go:2019`). claw refuses `loadSession` for lack of id mapping.
- ACP RFDs: `proxy-chains.mdx` (conductor chain) says nothing about client
  disconnect; `streamable-http-websocket-transport.mdx` re-attaches with a new
  `initialize` + `session/load` and contradicts itself on whether sessions
  survive (`:74` vs `:291`); v1 has no stream replay, v2 plans `Last-Event-ID`.

So the keeper is ours to write. It is built: `app/lib/data/services/keeper_script.dart`
(a single python3 file, standard library, python 3.6+, embedded as a Dart
string; `keeper_command.dart` installs it once per host, below). One keeper per
agent process, state in
`~/.herdr-mobile/keepers/` (directory 0700; `<id>.json`, `<id>.sock` and
`<id>.log`, files 0600; ids are six unambiguous random characters). Tests run
the real script against a scripted agent (`app/test/keeper_test.dart`,
`app/test/support/fake_acp_agent.py`).

Installed once per host, not shipped per command (it is ~22 KB deflated; `list`
runs every few minutes and `attach` on every reconnect). `keeperInstallCommand()`
is a command of about 1.5 KB, and the script travels on the exec channel's
stdin (`keeperInstallPayload()`: base64 lines; the caller writes them and then
closes stdin, the installer reads to EOF), because some SSH servers refuse a
long command (Dropbear: 9000 bytes). It writes
`~/.herdr-mobile/keeper-<version>.py` atomically (temp file, rename; directory
and file 0700), prints `{"ok":true}` and removes other versions' files and
stale temp files. `<version>` is 12 hex digits of FNV-1a 64 over the script
text, so a new app version never collides with an old file; a keeper already
running holds its script in memory, so deleting its file is safe. Every other
command is a few hundred bytes: it runs that file with `python3` and exits
**65** ("not installed") when the file of this app version is missing; the
caller installs and retries once. Different app versions installing on one host
would delete each other's file and reinstall on every use; one app version per
host is assumed.

Commands: `probe` (routes runnable on the host), `list`,
`start --agent ID --cwd DIR`, `attach ID`, `kill ID`. The agent command comes
from `agentRoutes`: the binary, else `npx -y <package>`. PATH is widened with
`~/.local/bin`, the adapters folder, bun/cargo/nvm/homebrew dirs, because a
non-interactive SSH PATH is poor. Exit codes: 0 done, 64 bad arguments, 65 not
installed, 66 folder missing (`start`) or no such keeper (`attach`, `kill`), 67
the keeper's agent has exited (`attach`), 69 agent not installed on the host, 70
agent failed `initialize`, 78 python3 missing.

1. `start` double-forks (`setsid`), redirects its std streams, ignores SIGHUP
   and spawns the agent with pipes in its own process group (no inherited file
   descriptors). It listens on a unix socket only (no network). The id is
   claimed by binding the socket, so racing starts get different ids. `start`
   prints the keeper's JSON once the agent has answered `initialize`; if the
   agent dies or refuses, nothing is left behind and stderr carries the
   agent's last words.
2. The keeper sends `initialize` itself (form elicitation and boolean config
   options offered, no fs or terminal) and caches the answer; clients get the
   cache under their own id,
   with `loadSession: true` (the keeper answers the load). Other requests are
   forwarded; the keeper renumbers the phone's request ids (a new client counts
   from 1 again while an old prompt is in flight) and restores them on the
   answer. Agent session ids pass through untouched.
3. Events: every `session/update` goes to an in-memory log (`ReplayLog` in the
   script) grouped in **turns**: a user message and everything up to the next
   (a `user_message_chunk` after agent activity opens one; updates that only
   restate state, like a mode or the command list, are not activity). It gives
   up **detail before turns**, under two byte budgets and an entry bound.
   Replay bytes dominate the time to open a thread over a phone link (about
   4 round trips plus bytes at the link's rate: 4 MB is ~3.7 s at 120 ms and
   10 Mbit, measured with `app/benchmark/session_open_bench.dart`), so the
   **soft budget** (1.5 MB, `HERDR_KEEPER_LOG_SOFT_BYTES`) is what a replay
   should cost: as soon as the log passes it, the oldest turns are *trimmed*,
   oldest first, outside the newest three (`HERDR_KEEPER_FULL_TURNS`) first,
   then those three, oldest first, **never the newest turn** (it stays whole
   even when it alone passes the soft budget), until the log is under it or
   nothing is left to trim. A trimmed tool call keeps title, kind, status,
   locations and the command or path that names it; its `rawOutput`, big
   `rawInput`, diff bodies, long output text and big `_meta`
   (`terminal_output*`, Claude's whole result) go, the entries of a finished
   call merge into one, and `_meta.herdr.trimmed = true` marks it (the subagent
   tag `parentToolUseId` is kept). A trimmed turn is a few KB, so 12 heavy
   turns of 1.8 MB replay as 1.9 MB with every question and answer. Only the
   **hard bound** (16 MB, `HERDR_KEEPER_LOG_BYTES`, or 20000 entries,
   `HERDR_KEEPER_LOG_MESSAGES`) drops whole oldest turns, after trimming:
   never splitting one, never the newest turn, never a turn a pending request
   is about; the last mode/command list of a dropped turn is kept and replays
   first. Only when the newest turn alone is over the hard bound does the log
   eat its oldest entries (never a user message, never the newest entry). The
   entry bound also trims turns (the newest excepted) before it drops one.
   Each turn carries its own byte and entry counts, and a cursor marks the
   oldest turn not yet trimmed, so an update costs O(1) amortized and nothing
   re-scans the log. The keeper counts
   `dropped_turns` (ever) and `trimmed_turns` (held now) and reports them in the
   answer to `session/load` as `_meta.herdr = {droppedTurns, trimmedTurns}`
   (other apps ignore it). Adjacent text chunks of one message merge, which is
   lossless for the reducer and keeps a long turn at a few entries. The prompts
   the phone sends are added as `user_message_chunk` (messageId `keeper-...`)
   unless the agent echoes them, because an agent does not echo a live prompt
   but a replay must show it. The message is logged just before the agent's
   next update, or at once when a client loads the session; it is **taken back
   out of the log** (`ReplayLog.remove`, counters and turns following it) when
   the agent answers that prompt `-32003 sessionBusy` (omp, busy with a turn of
   its own): a refused prompt is no part of the conversation. A turn that
   loses its user message this way and holds only what the agent streamed
   meanwhile joins the turn before it; a turn left empty goes. Tuning: `HERDR_KEEPER_LOG_SOFT_BYTES`,
   `HERDR_KEEPER_LOG_BYTES`, `HERDR_KEEPER_LOG_MESSAGES`, `HERDR_KEEPER_FULL_TURNS`. The log is not on
   disk (open question below). Before this (script of app 0.4.16 and older) the
   log was 4 MB / 4000 entries and dropped the oldest whole entries, so a long
   tool-heavy chat lost its first turns and, after a re-attach, the phone lost
   them too. **The script is installed per host by content hash and a running
   keeper keeps the code it started with**: the new retention applies to
   sessions started after the host got the new script; a keeper that is
   already running keeps the old bounds until it is restarted (a new session).
4. Requests from the agent: `session/request_permission` and
   `elicitation/create` go into a pending table under keeper ids (`kp1`...) and
   to the attached client; the agent's request stays open, the keeper never
   answers for the user. The first answer is forwarded on the agent's own id,
   a later duplicate is logged and ignored; an agent `$/cancel_request` drops
   the entry. Other requests of the agent (`fs/*`, extensions) are forwarded
   to an attached client, and answered `-32000` when none is attached.
5. `attach ID` bridges stdio to the socket. A connection becomes the writer
   with its first valid JSON-RPC line (garbage and a connect-and-close probe
   never evict). `session/load` for the session the keeper holds is answered
   by the keeper: the log for that session, then the cached setup as the
   response (`session/resume` gets the setup only), then `state_update`
   (`running` when a turn is in flight, `idle` + `stopReason` when a turn ended
   unseen), then the pending requests re-issued. It is never forwarded: pi-acp
   kills the live session and others refuse. A `session/load` for another id
   is forwarded, and the first `session/new`/`load`/`resume` response fixes
   the keeper's `sessionId`. A prompt whose client left is orphaned: its end
   reaches the next client as `state_update idle`.
6. One writer at a time: a new attach evicts the old one with a notification
   `_herdr/evicted` and a close. Detach is not cancel: `session/cancel` is
   forwarded only when a client sends it. A client too slow to read (64 MB
   backlog) is dropped; it re-attaches and replays.
7. Alerts: when a request enters the pending table (`KEEPER_EVENT=blocked`),
   and when a prompt turn ends with no client attached (`done`), the keeper
   runs the executable named by `HERDR_KEEPER_ON_BLOCKED`, else
   `~/.herdr-mobile/on-blocked` if executable (the ntfy plugin of
   `docs/ALERTS.md`), with `KEEPER_ID KEEPER_AGENT KEEPER_CWD KEEPER_TITLE
   KEEPER_EVENT KEEPER_SUMMARY`. The summary is the tool title or the first
   line of the question, cut to 300 characters before any pattern runs (a
   hostile 100 KB line costs microseconds), secrets masked
   (`Authorization`/`Bearer`, `key=`, `token=`, URL passwords, long mixed
   tokens), 120 characters. Redaction runs only when a hook file exists. Not
   blocking, killed after 5 s, at most four at a time, never fatal.
8. Lifecycle: the keeper exits when the agent exits. It records state
   `exited`, the exit code and `exit_reason` in `<id>.json`, tells an attached
   client (`_herdr/agent_exited`) and leaves; `list` shows the record for 24 h
   and then deletes it, together with stale sockets. Requests pending at that
   moment are noted as cancelled in `<id>.log`. `list` also marks a keeper
   whose process or socket vanished as exited. `kill` sends SIGTERM to the
   keeper, which sends SIGTERM to the agent's process group and SIGKILL 3 s
   later, then forgets the keeper (it also dismisses an exited record).
   Non-JSON lines from the agent and garbage from a client are logged to
   `<id>.log` (kept under 1 MB) and skipped. Idle sessions are reaped by the
   agent's own policy, not by us.

`list` prints `KeeperInfo.toJson` plus `agent_pid`: `session_id`, `title` (from
`session_info_update`, 300 characters), `pending`, `last_event_at`,
`turn_active` (a `session/prompt` is in flight; the keeper sees every prompt
and its answer, so this holds while nobody is attached) and `unseen_done` (a
turn ended while no client was attached; cleared when a client loads the
session) are kept current in the record (`pending`, `turn_active` and
`unseen_done` at once, the rest at most one second late). The board shows an
unattached session as blocked when `pending > 0`, else working when
`turn_active`, else idle. `state` is `starting` from the moment the keeper
claims its id until the agent has answered `initialize` (the record exists from
the first instant, so a cold `npx -y` start of a minute or more is listed,
never swept as an orphan, and `kill` reaches it; `kill` only signals a pid whose
command line is a keeper script).

Open: cost of replaying a large log over a slow link (the soft budget keeps a
replay near 1.5 MB and the hard 16 MB bound is the ceiling; measured
with `app/benchmark/session_open_bench.dart`: the replay is plain text and is 84-86 % of a
cold open of a full log at 30 / 10 Mbit/s; the app paints a saved copy
meanwhile, see "The saved copy and the pre-connect"); whether to keep the log on disk to survive a
keeper crash (the agent's own store already survives; `session/resume` then
rebuilds without history). A single update over the byte bound (16 MB) is
replaced in the log by a stub (a message chunk keeps a head and says how many
bytes were left out; a tool call keeps title, status and a note; anything else
is dropped) and never pushes older entries out.

## Session lifecycle in the app

`AcpAgentSession` (`app/lib/data/repositories/acp_agent_session.dart`) owns one
`AcpClient` per keeper while it is attached; `AgentSessionRepository` owns one
session per keeper of every online machine.

- **Who holds a channel.** Every attach is an exec channel, and sshd's
  `MaxSessions` (10 by default) is shared with the mux, the events and SFTP,
  so sessions are NOT all attached. The board is built from ONE `list` per
  machine (on connect, on resume, on pull to refresh, and every 30 s while the
  Agents tab is visible): `pending > 0` is blocked, `turnActive` is working,
  `unseenDone` is a review. A session nobody has attached shows that and
  never a stale transcript (`link` is `live`: healthy, not watched). Per
  machine the repository attaches at most 4 sessions by its own choice: those
  with a waiting request first (longest waiting first), then up to 3 of the
  most recently active (`lastEventAt`). A screen that shows a session holds it
  (`acquire` / `release`): that session attaches whatever the cap says, makes
  room by letting others go (channels are released before new ones are taken),
  and keeps its channel even over the cap. When a session is let go it keeps
  showing the phase it had until the next listing.
- **Attach.** `attach` -> `initialize` -> `session/load` when the keeper holds
  a session (replay, then the waiting requests come back), else `session/new`.
  A re-attach keeps showing the old transcript (marked disconnected) until the
  replay is whole, then swaps, keeping what the replay lacks (`withHeld`: the
  items above the replay's first item, matched by tool call id and message
  id/text, three in a row; no match at all keeps everything above a divider,
  `Earlier, from this phone`; a call the host has since trimmed keeps the
  phone's fuller copy; the lines that built the kept items go back in front of
  the saved copy's, so a restart shows them too, but not the divider). When the
  keeper says it dropped turns, one quiet note opens the transcript
  (`Earlier messages are no longer kept on the host (N turns).`). For 1 s after an attach the phase never falls
  below what was known before (the state is empty until the keeper sends again
  what waits). Hanging up closes the transport at once, so the channel is free.
- **Link drop.** `link = reconnecting`. With the machine offline nothing is
  tried (no `list`, no timer: the session waits for the machine, then tries
  once). Otherwise the session asks the host whether the keeper still runs
  (`list`), then attaches again after 1, 2, 4, 8, 15, 30 s, each delay spread
  by +-20 % (sessions that lost the link together do not knock together), at
  most 12 times per outage; then `link = failed` and `reattach()` is "Retry". A
  refusal that retrying cannot cure (`AgentHostException.fatal`, an agent
  error such as a login, a protocol the app does not speak) is `failed` at
  once. A session nobody wants any more stops retrying.
- **start() and a listing.** A listing can find a keeper before `start()`
  returns; both go through one idempotent adopt, so there is one session, one
  attach.
- **Exit.** `_herdr/agent_exited` ends the session at once with the keeper's
  reason; the same ending comes from `list` (`state: exited`, `exit_reason`,
  else "`<agent>` exited with code N."). No retry.
- **Evicted.** `_herdr/evicted` on the client the session holds now means
  another device took the keeper: `link = ended`, "Opened on another device.",
  `evicted = true`, no automatic attach (two phones would evict each other for
  ever). `reattach()` ("Take over") attaches again on purpose. The keeper also
  evicts this session's own half-dead channel when its new one attaches; that
  notice reaches a client the session already dropped and is ignored.
- **Background.** 90 s after `hidden`/`paused` the transport is closed (the
  keeper keeps the agent); nothing runs, no timer, until `resumed`, which
  attaches what is wanted at once and lists the hosts. The repository lists
  the hosts on connect, on resume and every 30 s only while the Agents tab is
  visible.
- **Notifications.** A session notifies once per flush (one per frame; see
  "The streaming fast path") however many updates came; the repository only
  when something the board shows changes (phase, link, title, the waiting
  request), never for streaming text.
- **Review.** A turn the app watched end (`end_turn`, `max_tokens`, ...) is
  "to review" until `markSeen`; cancelled and error turns are not; history
  replayed by `session/load` is not. Marked per device with `ReviewedState`
  (separate instance from the terminal panes'). A turn that ended while the
  phone was away counts only if the keeper reports it after the load
  (`state_update` idle with a stop reason). A listed `unseenDone` still
  unreviewed when an attach becomes whole is kept as this device's own review
  (the load clears the keeper's flag): an Undo of the screen's review would
  otherwise be undone by the next listing. The screen reviews only from the
  live replay, never from a saved copy (DESIGN.md, "Opening is instant").
- **Requests.** Nothing is answered except through `answerPermission` /
  `answerQuestion`; cancel, a dropped link, `end` and `dispose` answer as
  cancelled; there is no timeout.

### The saved copy and the pre-connect

Opening a thread used to wait for an exec channel, `initialize` and the keeper
replaying its whole log. Two things take that wait out of what the person sees;
neither changes the protocol.

- **The saved copy** (`TranscriptCache`, `data/services/transcript_cache.dart`;
  `TranscriptRecorder` and `replayCachedTranscript`, `data/acp/transcript_log.dart`).
  While an attach runs, the session keeps the newest window of the raw
  `session/update` lines it received, as they came (`JsonRpcConnection.onNotificationLine`
  hands the line over; nothing is encoded again, no line is edited), the answer
  to `session/load`, and the prompts this phone sent (written as the
  `user_message_chunk` the keeper's own log has, since the keeper never echoes
  them back). The window is capped by count (4000), characters (1 MiB) and per
  line (128 KiB: a longer line is left out, never cut, and the copy is marked
  `partial`). A new attach starts it over, because the keeper sends the whole
  log again. It is written when a turn ends (debounced, 3 s, the first ask
  starts the wait so a stream cannot push it off), at once when the last screen
  lets go and when the app goes to the background, never per chunk, and only
  once an attach's replay was whole. One file per session under the app's
  private **cache** directory (`transcripts/`; on Android outside Auto Backup,
  since a transcript may hold secrets; never preferences), written to
  `<file>.tmp` and renamed, in a worker isolate (`Isolate.run`; a job is a
  top-level function and plain data). The file is versioned (a JSON header with
  the version, the key, the session id, the time, `partial`, the line count and
  the setup, then the lines verbatim); a file that is damaged, cut short, of
  another version or key, or larger than the cap is deleted and ignored. Each
  file is capped at 1 MiB (oldest lines first) and the directory at 5 MiB (the
  session opened longest ago goes first; reading marks one as opened). A
  session that ends or is ended KEEPS its copy (an ended thread still reads on
  the phone, and Continue builds on it); a listing that drops a session
  deletes its copy, the first listing of a machine in a run sweeps the copies of
  keepers that went while the app was closed (`retain`), and a removed machine
  takes its copies along (`deleteMachine`).
- **Showing it.** `acquire()` (and a pre-connect, below) reads the copy while the
  attach starts. The lines are decoded in the worker, then folded on the UI
  thread through `applyUpdateParams`, the same function the live client folds
  every notification with, from `AgentSessionState(replaying: true)`: history
  carries no times, no mode notes, nothing waits (`withDisconnected`). The state
  is shown at once and **held** (`_holding`, the mechanism a re-attach already
  used): while the replay arrives the old transcript stays, and the replay
  replaces it when it is whole, with the same keys for the same rows, **except
  when it is shorter**: the keeper's log is bounded, and a thread never gets
  shorter because of a re-attach (below). A copy
  that arrives after the replay began is dropped; a copy of another ACP session
  (the keeper started over) is not shown. `AgentSessionView.cachedAsOf` is the
  time the copy was last right, non-null until the live replay replaced it; the
  link strip says `Showing the copy saved at 14:02. Nothing here can be
  answered.` for it in every state but live (under `Updating…` while connecting).
  **A saved copy is not a live request**: requests are not in a log, they come
  from the keeper with a live attach, so a copy has none; `PromptDock` shows
  nothing while `cachedAsOf` is set and `answerPermission`/`answerQuestion` do
  nothing, so a permission cannot be answered before the attach confirms that
  it still waits.
- **Pre-connect** (`AgentSessions.preconnect`, `PreconnectTap`). A finger going
  down on a session row (not a hover) takes a hold: `AcpAgentSession.warm()`
  attaches and reads the copy while the finger completes its tap and the route
  is pushed; the tap hands the hold to `openAgent`, whose screen cancels
  it once it holds the session itself (no second attach), and a finger that
  slides past the touch slop (a scroll, a swipe), a cancelled pointer or a
  lifted finger that opened nothing lets go (a hold nobody cancels ends after
  6 s). A warm hold counts as a held session for the machine's channel budget
  but changes nothing the board shows (`link` stays `live`). It is refused,
  with an inert hold, in the background profile, for a session that cannot
  attach, and when the machine already has `maxAttached` (4) sessions holding a
  channel, so it can never cost another session its channel. The Agents board
  needs no extra trigger for waiting sessions: they are attached first by the
  existing rule. A finished turn nobody has seen is deliberately **not**
  attached (the keeper clears `unseen_done` when a client loads, for every
  device); the board reads its saved copy instead (`preload`), so opening it is
  as fast, up to `maxAttached` such sessions per machine and never in the
  background.
- **The first frame** (`plan_warmup.dart`, `TranscriptView`). A thread of more
  than 120 items is planned from its last 8 turns only; once the route has
  stopped moving, `PlanWarmup` plans the older turns one by one into a scratch
  plan, at most 4 ms per 2 ms gap on the UI thread, which memoizes their
  Markdown, changed files and tool groups; then the real plan covers
  everything, which is cheap by then, and the older rows join above the origin
  without moving the view. A replay replacing the copy (every item a new
  object) plans the tail again and prepares the rest again, for a reader at the
  end; a reader who scrolled away keeps the whole plan. The first frame of a
  thread with a "since you left" divider older than the tail is planned whole.

Measured on a desktop in the Flutter test binding (debug JIT, a 600-message
thread of markdown, code and tool calls over the fake keeper, a 309 KB copy,
median of 5, `benchmark/open_cache_bench_test.dart`), time from opening the
screen to the first frame with transcript rows: with a keeper that answers at
once, 130 ms before this work, 83 ms with the tail-first plan, 85 ms with the
copy too (nothing to hide); with a keeper that answers after 150 ms (simulated
round trip), 261 ms before, 216 ms with the plan, 54 ms with the copy. They are
desktop numbers; the phone is not measured (`AGENTS.md`: never quote a desktop
number for it).

### Durable sessions: Continue and Past sessions

The keeper is a liveness helper, not the record. When the host restarts (or a
keeper is killed) the keeper and its agent die, the listing says `exited`
("The keeper process is gone (killed, or the host restarted).") and after
`KEEP_EXITED` (24 h) the row is gone. The conversation is not: every agent keeps
its own store (omp `~/.omp/agent/sessions`, Claude `~/.claude/projects`, Codex
`~/.codex/sessions`, pi) and ACP exposes it, which is how Zed treats history
(Zed's `crates/agent_servers/src/acp.rs`: `list_sessions`,
`load_session`, `resume_session`). Checked on this machine: `omp acp` answers
`session/list {cwd}` in under 0.3 s (116 sessions without a folder filter).

- **Continue** (`AgentSessions.resume`, `AcpAgentSession.resumeTarget`). An
  ended session (not evicted, session id known) offers `Continue`: a NEW keeper
  is started in the same folder and the phone asks it for `session/load` of the
  old id. A keeper that holds no session forwards `session/load` to the agent
  (`on_client_request`/`note_session`), the agent replays the history, the keeper
  logs it, and from then on it is an ordinary session (`AcpAgentSession.openPast`
  sets the id before the attach). The ended session's saved copy is carried
  over with the held/`withHeld` machinery, so the transcript the person was
  reading does not blink; the old row (and the exited keeper record) is dropped
  once the new one is attached. An agent without `loadSession` but with
  `session/resume` is reopened with that (the saved copy stays the transcript);
  with neither the attach fails with "`<agent>` cannot reopen past sessions."
  A failed attempt kills the new keeper and leaves the ended session as it was.
  Two asks for the same id share one attempt; a session already held live for
  that id is returned instead (Codex refuses a second client, pi's load kills a
  live session with the same id).
- **Past sessions** (`AgentSessions.history`, `AgentHost.history`, keeper
  command `history <agent> [cwd]`). The command runs the agent briefly with no
  keeper and no session, `initialize`, then pages `session/list` (5 pages /
  200 sessions at most, 30 s per request), prints one JSON line
  (`PastSessions`: the agent's capabilities `list`/`load`/`resume`, `more`, and
  per session id, folder, title, `updatedAt`, `messageCount`, newest first) and
  always tears the agent down (process group, SIGTERM then SIGKILL). Exit codes
  64 unknown agent, 66 folder missing, 69 not installed, 70 agent error. It
  touches no keeper state.
- The phone keeps nothing authoritative about a conversation: the saved copy is
  a display cache, the agent is the record.

### The streaming fast path (data side)

What makes a frame of streaming cost the same at row 20 and at row 2 000.
The widgets that consume it are the live row
of the transcript (`LiveMessageRow`, `LiveMessageModel`, `TranscriptPlan`;
`docs/DESIGN.md`, "Agent session screen (ACP)"); this is the data layer's contract.

- **The live slot.** The message streaming in right now keeps the end of its
  text in a `LiveText` (`data/acp/live_text.dart`: append-only, pieces kept as
  they came, `append` O(1), `text` joins on demand, `tail(from)` reads only what
  grew, `version`, and a `Listenable` that is told by `flush()`, never by
  `append`). `AgentSessionState.apply` appends a plain text chunk for that
  message to its `LiveText` **in place** and returns a new, cheap state object
  whose `items` is the **same list instance**. This is the one documented
  exception to "immutable": every state that shares the message shares its
  growing text. Everything else still copies: a new message, a tool call, a
  stop note, a user prompt, an upsert, a chunk for another message (moves the
  slot, once), a chunk that is not plain text (an image, text with `_meta`)
  and the end of the turn, a disconnect or `state_update idle` (the live
  message is *settled* into plain blocks). There is at most one live message,
  `state.liveMessage` / `state.liveKey`; `state.liveTextOf(key)` gives its
  text. `TranscriptMessage.text` and `.blocks` give the text so far for live and
  settled messages alike (for a live message `blocks` builds the list on each
  call; a row that follows the stream reads `live` instead); history and the
  user's prompt never get a `LiveText`. A replay leaves its last message live
  (nothing ended it); a consumer treats text that is already there when it
  first looks as history. The text a copy-per-chunk reducer would give and the
  text of the live slot are the same for every recorded trace and for random
  update sequences (`test/acp/live_slot_test.dart`, which keeps the old reducer
  as a reference). Measured on a desktop VM (reducer only, 20 KB in 120-char
  chunks): 8 000 items, old 22 us per chunk, new 0.5 us; 200 items, old 1.0 us,
  new 0.3 us.
- **On the views.** `AgentSessionView.liveTextOf(messageKey)` gives the
  `Listenable` of the live message (null when it is not live) and
  `AgentSessionView.turnStartedAt` the instant of Send (below). A session
  notifies its own listeners every flush, as before (`state` is a new object per
  chunk, `state.items` is not): a list compares `identical(state.items, last)`
  and only the live row listens to the text.
- **Flush.** `AcpAgentSession` marks itself dirty on every change and a
  `FlushScheduler` (`data/streaming/flush_scheduler.dart`) decides when the
  listeners are told: `FrameFlush` (`ui/core/frame_flush.dart`, injected by
  `bootApp` through `AgentSessionRepository(flush:)`) runs the flush as a
  transient frame callback, **at the start of the next frame, before build**, so
  the notification lands in the frame the chunks belong to and never a frame
  late; the default `TimerFlush` (a `Timer` of `notifyEvery`, 16 ms) is what
  tests use. Chunks between two frames are one flush (one `notifyListeners`,
  one `LiveText.flush`). An urgent change (phase, a request, link, title, a
  finished turn, a disconnect) is carried by the same next flush and is never
  held back by a slower one already waiting. A flush asked for while the
  frame's own flush runs belongs to the next frame. The background profile
  (`keepAliveInBackground` while the app is away; frames do not run) keeps its
  timers: 2 s for streaming text, `notifyEvery` for urgent changes; coming back
  flushes at the next frame. While the app is hidden `FrameFlush` falls back to a
  timer (a frame callback would wait for the app to return). The observed
  (pane) sessions still use their own timer and flush their live text with it.
- **Send.** `AcpAgentSession.send` calls the client's `prompt`, whose
  synchronous part appends the local user row and starts the turn, and takes the
  client's state **in the same call** instead of a microtask later: the first
  frame after Send shows the row and `working`, and `turnStartedAt` is the
  instant of Send by the session's clock (not the first token; for a turn this
  app only saw running, when it first saw it; null when no turn runs). The
  status line's elapsed clock counts from it.
- **Pacing** (`data/streaming/reveal_pacer.dart`, pure Dart, driven by
  `LiveMessageModel` in the transcript on a `Ticker` that runs only while text
  is held back; Smooth text, `AppSettings.smoothText`, turns it off).
  `RevealPacer` decides how much of the text that arrived is shown: `append`
  what came, `advance(dt)` once per frame returns the next part, `snap()`
  returns everything pending. Per 16 ms frame it reveals
  `max(minRate = 2, backlog * k = 1/6, deadline rate)` characters, where the
  deadline rate is what shows every piece within `maxLag = 200 ms` of its
  arrival: the visible lag stays under about 250 ms for the recorded cadences of
  claude, codex and omp (worst measured in the tests, a desktop simulation at
  16 ms frames: 192-196 ms, also with late frames), for a lump of 176 characters
  every 500 ms (188 ms) and for 200 ms bursts; a steady stream stays under
  160 ms. Cuts fall right after
  whitespace (a word is shown whole; the partial last word waits for its space
  or its deadline), on characters for a token of more than 24 characters with
  no whitespace (paths, URLs), always on a grapheme-cluster boundary
  (`package:characters`; the last cluster of the pending text is held in case
  the next chunk extends it; CRLF and a lone `\r` at the end are never split),
  and past a deadline to the next word boundary within 24 characters. Reduced
  motion (`reducedMotion`) shows whole lines and the partial last line at its
  deadline. The text is never altered: the deltas and the final `snap` are
  exactly what was appended; the same appends and `dt`s give the same deltas.
  **The caller snaps** when the turn ends, the app resumes, the person touches
  the transcript, the text is history (a replay, a message that was already
  there when the row first showed), or the person asked for no motion where
  lines do not suit; `advance` snaps by itself when the backlog passes 8 KB
  (`snapBacklog`). All constants are constructor arguments; they are proposals
  until tuned on the phone with the stream bench.

### The turn model (data side)

The data half of the turn model: pure Dart in `app/lib/data/acp/turns/` (barrel `turns.dart`) plus additive
changes in `session_state.dart` and `acp_client.dart`. The transcript consumes it
(`docs/DESIGN.md` "Turns": `TranscriptPlan` over `turnsOf`, the fold line, quiet
tool rows with `toolSummary` and `groupTools`, the Changed card, `StatusLine`
over `activityOf`). Tests: `test/acp/turns_test.dart`, `test/acp/turn_state_test.dart`, folded
from the recorded traces with their own clock (`test/acp/support/trace_state.dart`).

- **Times, and honesty about history.** Every `TranscriptItem` has
  `at` (when this client first saw it, by the clock given to
  `apply(update, at:)`; `AcpClient` passes its clock) and `timed` (`at != null`).
  `TranscriptMessage.endedAt` is when it stopped growing (the update that
  settled it: the next item, the end of the turn); `TranscriptTool` has
  `at`/`startedAt` (first seen, so a wait for approval is inside the step),
  `finishedAt` (the first time it was seen finished; a call that reopens loses
  it) and `duration`; cancelling stamps the calls it cancels.
  `withUserMessage`, `withTurnEnded` and `withCancelRequested` take `at:` and
  `AcpClient.prompt/cancel` give it. **A replay has no times.**
  `AcpClient.loadSession` starts the state with `replaying: true`; while it is
  set `apply` stamps nothing (items get `at == null`) and writes no mode note;
  `withSetup` (the answer to the load) ends it. `lastActivityAt` is still
  stamped (it is when this client last heard anything). A call that started in
  a replay and finished live has `finishedAt` only, so no duration; a turn that
  began in a replay has no `startedAt`, so no duration even when it went on
  live (the first part is missing). UI rule: show a duration only when `timed`.
- **Mode note.** A `current_mode_update`, or a `config_option_update` that
  changes the mode option (`currentModeId`), adds one `TranscriptNote` (key
  `n<k>`, text `Mode changed to <name>`, `modeId`, `at`; the name is the mode
  option's choice name, else the `modes` name, else the id). Not for a replay,
  not the first sight of a mode (nothing to change from), not when the mode did
  not change (omp sends both updates for one change: one note), never for
  `withConfigOptions` (the answer to the person's own `set_config_option`).
  **The person's own change is silent:** `AcpClient.setMode` /
  `setConfigOption` call `withExpectedMode` / `withExpectedConfig` *before* the
  request (the agent may report before it answers) and clear it in `finally`;
  `expectedMode` suppresses a note only for exactly that mode and is consumed
  when the mode arrives. A note splits the agent message that follows it (a
  chunk without an id after a note starts a new message).
  `AgentSessionState.waitingToolIds` are the calls with a pending permission.
- **`turnsOf(items, {live})`** (`turn.dart`) gives `List<Turn>`: a turn starts
  at every user message; items before the first one are a turn with
  `user == null` (autonomous activity, what came after a replay). Memoized by
  list identity (`Expando`), one pass over the items per structural change; a
  chunk into the live message leaves the list, so it costs nothing; a turn
  whose items did not change is the *same object* as before (cached by its first
  item), so a widget can key on `identical(turn, old)`. `live: true`
  (`state.turnActive`) makes the last turn live (`Turn.withLive`, a memoized
  twin). `Turn` has: `user`, `items`, `live`/`ended`, `answer`, `narration`,
  `thoughts`, `tools`, `stops`, `notes`, `work` (tools, thoughts, narration in
  order: what folds), `hasWork`, `toolCounts` (by `ToolKind`), `failedCount`,
  `cancelledCount`, `unfinishedCount`, `changed`, `commands`, `startedAt`,
  `endedAt`, `duration`/`timed`, `breakouts([waiting])`, `needsAttention`.
  Statistics are `late final`: a turn the UI never asks costs only its
  classification.
  - **The answer** is the last agent message with content, ignoring stop rows,
    notes and blank messages, when nothing the agent did (tool call, thought)
    comes after it; else null. Live or not: a message streaming after the last
    tool is the answer, and becomes narration if another tool starts (rare). A
    live message always counts as content (its text grows without the list
    changing). Every other agent message with content is **narration**; the
    thoughts are `thoughts`; both fold into `work` with the tool calls. A plain
    chat reply (no work) has an answer and no work log.
  - **Breakouts** (what stays visible when the log folds): tools that failed
    (`toolFailed`: status `failed`, or a command that exited non-zero or by a
    signal, whatever the status says), tools that were cancelled, tools in the
    `waiting` set (`waitingToolIds`) and every stop row (refusal, `max_tokens`,
    `max_turn_requests`), in transcript order.
  - **Time.** `startedAt` is the user message's `at` (else the first item's);
    `endedAt` is the latest of the messages' `endedAt ?? at`, the tools'
    `finishedAt ?? at` and the stop rows' and notes' `at`, null while live;
    `duration` is their difference, null whenever either is unknown. The end of
    a turn is an event only through the message it settled, so a turn that ends
    on a tool call ends when that call did.
- **`ChangedFile`** (`changes.dart`): `path`, `added`, `removed`, `isNew`,
  `isDelete`, `diffs`. `Turn.changed` = `changedFilesOf` the turn's *completed*
  calls (an edit waiting for approval changed nothing; a failed one nothing),
  one per path in the order first touched. Several diffs of a path (an agent
  that edits a file twice; codex, one diff per hunk under the title "Editing
  files") are grouped; a diff whose `oldText` is the previous diff's `newText`
  extends one chain and counts once as the net change. `isNew`: the first diff
  had no `oldText`. `isDelete`: a completed call of kind `delete` named the
  path (`locations`, else `rawInput` `file_path`/`filePath`/`path`/`file`) and
  no later diff wrote it. Counts come from `lineStats(old, new)`
  (`line_diff.dart`): lines added and removed as `git diff --numstat` counts a
  changed line (one out, one in), exact: common head and tail cut, then the
  length of the shortest edit script (Myers, O(ND), only the length, memory
  O(N+M)). Bounded: a side of more than 5 000 lines, or a script of more than
  2 000 edits, is counted by multiset (a line is added when the new text holds
  more copies of it, removed when fewer): linear, exact unless lines moved.
  Line ends (`\r\n`) and a final line feed are not changes. Checked against a
  reference LCS on random texts. None of the recorded traces holds a diff
  (the edit shapes in the tests are written out as the adapters send them).
- **`toolSummary(call)`** (`tool_summary.dart`, memoized per call object):
  structured parts, plain strings, ANSI stripped, no raw JSON ever (a title
  that is JSON falls back to `name`, then to a word for the kind), at most 240
  graphemes (cut with `clip`, never inside a letter or a cluster):

  | Kind | `text` | Other parts |
  | --- | --- | --- |
  | read, delete | basename of `locations[0].path`, else `rawInput` path; title when none | `hint`: the directory, last two components (`tmp/scratch`) |
  | edit | basename of the first diff's path (else `locations`/`rawInput`) | `hint`, `added`, `removed` (null without a diff or when none changed), `fileCount` |
  | execute | the command: `rawInput.command` (string or argv list), else the title (omp titles come as `$ cmd`); the `sh/bash/zsh -c '...'` wrapper codex adds is removed; first non-blank line | `extraLines`; **only when failed**: `failure` (last meaningful output line: not blank, not a code fence, not omp's `Wall time:` footer), `exitCode`, `signal` |
  | search | `rawInput` `pattern`/`query`/`regex`/`search`/`q`/`glob`/`text`, else title | `hits` only when the output says: a count field, a list, "Found N files", "No matches"; never guessed from the text's size |
  | fetch | host of `rawInput.url`/`uri`/`href`/`link`/`urls[0]` | |
  | think, move, switch mode, other | the title | |

  The output text comes from `ToolOutput` (codex, pi `_meta`), else
  `rawOutput` (a string, or `content[].text`: Claude, omp), else the call's text
  content; the exit code from `ToolOutput`, else a first line `Exit code N`
  (Claude's wording: UNVERIFIED, the traces hold no failed command).
  `ToolSummary.plain` joins the parts with ` · ` for labels and tests; the UI
  lays the parts out. `Turn.commands` (`CommandRun`: command, exit code, signal,
  failed) is the same data per command.
- **`groupTools(tools)`** gives `List<ToolGroup>`: every maximal run of **two or
  more adjacent calls of kind read or search whose status is `completed`** is
  one group (`isGroup`, `reads` = different files read, a read of an unknown
  file counts alone, `searches`, `label` = `Read 3 files · searched 2×`,
  `searched once` for one); every other call, a lone read included, is a
  group of one. A pending, running, failed, cancelled or waiting call is
  never in a group and ends the run before it. No call is lost or repeated.
- **Fold line** (`work_summary.dart`): `workSummaryParts(turn)` /
  `workSummaryLine(turn)` = `Worked 42s · 3 files · 4 commands · 1 failed`
  (`1 cancelled` too). Zero parts are omitted, singular for 1; `Worked`
  carries the duration only when `turn.duration` is known and at least a second
  (`formatDuration`: `42s`, `3m`, `3m 5s`, `1h 5m`). Files are changed files,
  commands are calls of kind execute. For a live turn the UI shows the status
  line, not this.
- **Status line** (`activity.dart`): `activityOf(state, now:)` is null when no
  turn runs, else, in order: `waiting` (a call with a pending permission, its
  summary; or `Waiting for you` for a question), `tool` (the latest call that
  is pending or in progress, its `ToolSummary.plain`; Claude never says
  `in_progress`), `thought` (the first sentence of the latest thought, only
  while it is the last thing of the turn: Markdown marks removed, cut at the
  first `. ! ?` before a space), else `working` (`Working`). `since` is when the
  step began (for `elapsed(now)`, null when unknown) and `quiet` is
  `quietFor(state, now:)`: how long nothing arrived while a turn runs and the
  agent does not wait for the person, once it is at least 60 s (`quietAfter`),
  counted from `lastActivityAt` or the user message when that is later; never
  when idle, disconnected, or without a clock.
- **Not here, by design.** Subagent text and calls are not in a `Turn`: they
  never enter `items` ("Subagents (data side)"); no overview-sheet aggregation (it sums
  `Turn.changed` per session later); `ToolSummary` makes no text safe for
  display (`visibleText` stays the UI's job) and the data layer has its own
  ANSI stripper (`data/decision/plain_text.dart`, reused) because it cannot
  import the `ui/` one.

### Subagents (data side)

Everything is in `AgentSessionState`
(`session_state.dart`) and `data/acp/subagents/`; pure Dart, no UI.

- **`SubagentRun`** (`subagents/subagent_run.dart`), in
  `state.subagents`, ordered by first appearance and never reordered (a flat
  list: a subagent that starts a subagent is a run with `parentRunId`). Fields:
  `id`, `route` (`claude`/`omp`/`codex`), `parentToolCallId` (the row of the
  transcript that started it; the row stays, link by `state.subagentsOfToolCall(id)`),
  `parentRunId`, `name`, `title` (`Subagent` until the agent says), `agentType`,
  `assignment`, `status` (`waiting | running | finished | failed | cancelled`),
  `startedAt`/`finishedAt` (this client's clock; null in a replay),
  `reportedElapsed` (what the agent says while it runs), `totalElapsed` (its own
  figure at the end), `elapsed` (best known), `toolCount`, `tokens`, `cost`,
  `model`, `percent`, `lastTool` + `lastToolLine` (`Bash`, `ls -1 /tmp/scratch`),
  `recentTools`, `recentOutput`, `note`, `result`, `failure`, `retry`,
  `background`, `plan`, `hasTranscript`, `items` (the child transcript),
  `droppedItems`, `log` (set when the transcript was read from omp's log on the host). A field an agent does not send is null or empty, never made up.
  `SubagentSummary` (`state.subagentSummary`: `total`, `waiting`, `running`,
  `finished`, `failed`, `cancelled`, `active`) is memoized by the runs list's
  identity.
- **Routing (Claude).** An update that carries `_meta.claudeCode.parentToolUseId`
  (message chunks, upserts, tool calls, plans), or is about a tool call that
  an earlier tagged update made (later updates of a child's call carry no tag:
  recorded: the Bash call's `toolResponse` update in `claude/subagent`), goes to the transcript of that run and never to
  `items`. The parent is the `Task`/`Agent` call (`_meta.claudeCode.toolName`, or
  `subagent: true` in the adapter's own scenarios): the call row stays in the main
  transcript and the run is made from it. The child transcript is an
  `AgentSessionState` of its own, folded by the same rules as the main one: the
  child message that streams in keeps its text in a `LiveText`
  (`run.liveTextOf(key)`, `state.flushSubagentLive()` tells its listeners), the
  items list and the runs list stay the same instances while only text grows,
  and a child's call is stamped with the time it was seen. Decision:
  children stream through the same live slot (no second code path); the UI
  need not make them smooth.
- **Facts per update, not from the merged call.** A call's `meta` keeps the last value of each top-level key,
  so the end-of-call `toolResponse` (`agentType`, `totalDurationMs`,
  `totalTokens`, `totalToolUseCount`, `content`, `resolvedModel`) is lost when the
  next update's `claudeCode` replaces it (recorded: the Agent call's two last
  updates in `claude/subagent`). The
  reducer reads each update's own `_meta` (`launchFacts(call, updateMeta:)`).
  The result text is `toolResponse.content`, else the call's text content, without the
  `agentId: ... <usage>` trailer.
- **Status.** Claude: failed/cancelled calls fail/cancel the run; `completed` is
  `finished`, unless the run was started in the background
  (`run_in_background`, or `toolResponse.status: async_launched`): then the call
  completes at once and the run keeps `running` until a response says it
  ended (UNVERIFIED: no recorded trace shows a background run end, and
  the plain client may never be told) or the person cancels. A call that is `pending` is `waiting`
  until its `prompt` arrives or a child does something, or while a permission asks
  to start it (`withPending` / `withoutPending`).
- **Held updates.** A child update whose run does not exist yet (the update came before the
  `Task` call, the adapter's own scenario `subagent-late-child-update`) is held
  in `SubagentBook.held` (at most 500, oldest dropped) and applied in order when the call
  arrives; the call id is remembered, so its untagged updates are held too. A call that was
  first seen without its tag (the adapter says the eager `tool_call` of a
  permission can miss it and the refining update restores it) moves out of the
  main transcript into the run when the tag arrives.
- **Replay.** `session/load` replays tagged updates; the same fold builds the same runs
  (tested against `claude/subagent`), with no times.
- **Caps.** A child transcript keeps the newest 2000 items (trimmed in steps of
  200); `droppedItems` counts the rest and `toolCount` keeps counting. Held
  updates: 500. `recentTools`/`recentOutput`: 5. `result`: 64 KB. `assignment`: 4000.
- **Cancel.** `withCancelRequested` / `withTurnEnded(cancelled)` and an agent's
  `cancelled` status on the parent call mark the active runs cancelled (and the
  runs they started, and their unfinished calls). A run that ended stays ended.
  UNVERIFIED: whether cancelling the turn really stops Claude's background
  subagents.
- **Request origin.** `withPending` stamps `PendingRequest.origin`
  (`SubagentOrigin {id, title, agentType, label}`; `label` is the agent type else the
  title: "From subagent: Explore") when a request names a run:
  by `_meta.claudeCode.parentToolUseId` on the permission's `toolCall` (the adapter sets it
  for non-AIR clients), else by the tool call id (recorded: the Claude permission in
  `claude/subagent` has no `_meta`, but its call was tagged earlier), for a question
  by `toolCallId` or its `_meta`. A request from a subagent blocks like any (`phase`,
  the board's count); a permission for the `Task` call itself has no origin. Not
  resolvable: Codex routes a child's approval to the root session with the child's
  item id (no thread id): no origin (UNVERIFIED against a session).
- **omp.** `task` calls (omp sends no tool name over ACP): a call is a subagent launcher when
  `rawOutput.details` has `progress` or `results`, or it is titled `task` with
  `rawInput.tasks[]` (or flat `{name, agent, task}`) and no `op` (the `todo`
  tool). One run per subagent, id `<call id>#<index>`, built from `progress[]`
  (`agent`, `status`, `currentTool`/`currentToolArgs`, `recentTools`,
  `recentOutput`, `toolCount`, `tokens`, `cost`, `completionPercent`,
  `resolvedModel`, `retryState`, `durationMs`) and `results[]` (`exitCode`,
  `output` = `result`, `error`/`abortReason` = `failure`, `durationMs`). Statuses:
  `pending` waiting, `running`, `completed` finished, `failed`, `aborted`
  cancelled; a result with an error or a non-zero exit fails it. The reducer makes no
  transcript for it: the stream is a summary and the screen must not draw it as a chat unless a
  transcript was read from omp's own log (see "omp subagent transcripts" below). Shapes are from
  oh-my-pi's source (`AgentProgress`, `SingleResult`, `TaskToolDetails`) and were checked
  against a real run on 2026-10-05 (omp 18.4.12, `omp acp`, one `task` with one subagent, in a
  scratch directory with `PI_CODING_AGENT_DIR` redirected; `app/test/fixtures/omp_logs/acp_task_updates.json`
  holds the call and two progress updates): the `tool_call` is titled `Spawning <name> subagent`
  with `rawInput {context, tasks[{name, agent, task, ...}]}`; `rawOutput.details.progress[]` carries
  `id` (the name, `PongReply`, which is also the artifact file name), `agent` (the type, `task`),
  `status` `pending | running | completed`, `assignment`, `tokens`, `cost`, `toolCount`, `durationMs`,
  `recentTools [{tool, args, isError, endMs}]`; `details.results` stayed empty and the background
  job's completion came as a `Background task <name> complete.` progress update (call still
  `in_progress`), a `wait` call returned the `<task-result>` text. The observed path keeps its own
  `SubagentInfo` roster (a different type, from the log); the ACP runs borrow its vocabulary.
- **omp subagent transcripts (best effort, SFTP only).** omp's ACP stream has no conversation of a
  subagent and no file path, but omp keeps a log of each `task` subagent on the host, in the format
  `OmpLogMapper` reads. Layout, verified on omp 18.4.12 (source read at oh-my-pi 18.6.0:
  `session/session-manager.ts` `artifactsDirectoryFor`, `task/executor.ts`, `task/output-manager.ts`,
  `session/session-paths.ts`):
  - the ACP `sessionId` **is** omp's session id (`session/new` result = `session` entry `id` of the
    parent file);
  - the parent's session file is `<sessions root>/<project folder>/<time>_<session id>.jsonl`
    (`2026-10-05T07-06-23-175Z_01a10ae2-...jsonl`; created with the first answer); the sessions root
    is `<agent dir>/sessions`, `~/.omp/agent/sessions` by default (`PI_CODING_AGENT_DIR` moves it,
    XDG moves it to `$XDG_DATA_HOME/omp/sessions`); the project folder is the working directory
    with `/`, `\` and `:` turned into `-`: `-tmp-<rest>` under the temp dir, `-<rest>` under home,
    else `--<path>--` (the temp dir is checked first);
  - the artifact directory is the parent file without `.jsonl`; a `task` subagent writes
    `<artifact dir>/<id>.jsonl` (its log) and `<id>.md` (its output, at the end), `<id>` being
    `progress[].id`: the requested name, `-2`, `-3` for a repeat, `Parent.Child` for a nested one
    (omp does not sanitize a requested name; this app reads only `[A-Za-z0-9_.-]` ids, see below);
  - the log is the same entry format as the parent's: `title` (v 1), then a `session` header
    `{version: 3, id, cwd, parentSession: <parent file path>}`, `model_change`, `session_init` (with the
    system prompt, 14 KB), `model_usage`, `message` entries, `custom` entries, `session_exit`. The
    subagent's own `session` id is not the parent's; `parentSession` names the parent file.
  `app/lib/data/repositories/subagent_transcripts.dart` does it: `OmpSessionLocator` finds the
  parent file by listing the sessions root (exact folder names omp would use, then folders whose
  name contains the working directory's own name; `~/.omp/agent/sessions`, then
  `~/.local/share/omp/sessions`), `SubagentLogReader` reads and maps the log, `SubagentTranscripts`
  (one per `AcpAgentSession`, created on first use) schedules it. Rules:
  - the path is `<artifact dir>/<name>.jsonl`, `name` from the run (`progress[].id`) after
    `validSubagentName` (`subagent_log_path.dart`): letters, digits, `_`, `-`, inner single dots, at
    most 120 characters; nothing else (separators, `..`, a leading or trailing dot, spaces, an
    extension) gets no read at all, not even a listing; the agent's text never chooses a path;
  - SFTP only (`RemoteFiles`: `stat`, `list`, `read`, `realpath`), never a shell; reads go through the
    transport isolate and are clamped; a header must say `session` version 3 (`SubagentLogReader.knownVersion`)
    and, when it names a parent, the artifact folder's own file, else the log is not used;
  - caps: the newest 1 MiB of a long log from a line boundary, the newest 4000 lines of that, lines over
    256 KiB skipped and counted, the newest 2000 items (`SubagentRun.maxItems`); what is cut off the
    start is `SubagentLogInfo.earlierNotShown` and the drill-in says `Earlier part not shown`; a
    later read takes only what was appended (a half-written last line waits), starts over when the
    file shrank or grew by more than the cap;
  - cadence: only while a drill-in is open (`AgentSessionView.watchSubagentLog(runId, true/false)`, counted
    per screen): one read on open, then every 3 s while the run is active (a `stat` when nothing grew),
    one more after it ended; no timer without a watcher, and no read while the app is in the background. A run that
    still waits for its first progress (no id yet) is not read. The roster does not read;
  - the transcript is not part of the reducer's state (the client replaces that state on every
    publish); `SubagentOverlay` lays it over the run in `AcpAgentSession.subagentRun(s)` with
    stable identities;
  - failure is silent: no session file, no log, no SFTP, no permission, an unknown version, another
    parent, nothing that maps, a bad name: the run stays the summary and `SubagentLogStatus` is
    `unavailable` (looked for again while the run is active, not-found believed for 5 ticks). Only a connection failure
    is `failed`: the summary gets one line, `Couldn't read the log · Tap to retry`; `Loading…` shows
    only during the first read;
  - a transcript read from the log shows once `From omp's log on the host` under the pinned prompt.
  Not covered: a custom `PI_CODING_AGENT_DIR` (not guessable from here; the run stays a summary),
  a temp dir that is not `/tmp` with a name that does not contain the project's folder name,
  names with spaces, a subagent that started subagents (its own cards show no runs), a subagent
  whose log is bigger than one line cap per entry (skipped lines leave a tool row `running`).
- **Codex.** `collabAgentToolCall` with title `spawnAgent` (the other tools only control an
  existing agent) and `subAgentActivity` rows; child thread ids are in `rawInput`
  only (`receiverThreadIds`, `agentsStates {thread: {status, message}}`,
  `agentThreadId`, `agentPath`). One run per child thread, id = the thread id (the
  spawn row and the activity rows of one child are one run), title = the first line of
  the prompt, `status` from `pendingInit | running | interrupted | completed | errored |
  shutdown | notFound`, `note` = the agent's latest message. No transcript. UNVERIFIED
  against a recorded session (no trace has a subagent).
- **pi**: none; an ordinary tool call never makes a run.
- **Never advertised.** The app does not advertise the ACP `subagents`
  capability (a child's request would block the agent);
  children therefore arrive as tagged updates on the one session.
- **For the UI.** `AgentSessionView.subagentRuns` / `subagentSummary` /
  `subagentRun(id)` / `subagentsOfToolCall(id)` (SteerData adds them; the observed
  roster stays `subagents`). Read `run.items` for the drill-in, `run.liveTextOf` for the
  streaming message, `origin` on `state.pending` for the dock. A disconnected session
  leaves its runs as they were: the UI must not show "running" for it. The status line
  (`activityOf`) says "Waiting for you" for a child's permission (the child's call is not
  in the turn); `origin` names who.
  Unmodelled: the adapter's `subagent_spawned` / `subagent_state_update`
  (sent only to a client that advertises `subagents`, which this app never does)
  and `async_task_*` (sent only to a client that advertises the AIR async-tasks
  capability) are `UnknownUpdate`.

### Steering and input (data side)

The data half of steering and input. Pure Dart:
`data/acp/prompt_queue.dart`, `prompt_content.dart`, `auth_needed.dart`,
`data/services/image_prep.dart`, and the send path of `acp_agent_session.dart`.
No UI file.

**One send, three deliveries.** `AgentSessionView.send(text)` and
`sendBlocks(blocks, {queue})` choose by what the session knows when called;
`delivery` (`SendDelivery`) says the same beforehand, so the composer can say
"Queued" or "Sent to the running turn":

| Situation | Delivery | What happens |
| --- | --- | --- |
| Idle, nothing waiting | `now` | a `session/prompt`; the future completes when the turn ends |
| Working, route steers (`canSteer`) | `steered` | `_session/steering` into the running turn; completes when the agent answered |
| Working, route does not steer, or `queue: true` | `queued` | into `queued`; completes at once; sent as a prompt when the turn has ended |
| Something already waits | `queued` | behind it, the order the person sent them in |
| Link being re-made (`reconnecting`, `connecting`) | `queued` | waits for the link and for the agent to be idle |
| No link and none coming (never attached, ended, failed) | | `error` "Not connected. The message was not sent." |

**Per route** (sources are the adapters' upstream code; none of this ran
against a live Codex, Claude Code or pi, only against scripted agents: UNVERIFIED live):

- **Claude Code**: `initialize._meta.steering.supported` (top level, beside
  `agentCapabilities`; `acp-agent.ts:2724`) and
  `agentCapabilities._meta.claudeCode.promptQueueing` (`:2664`). `_session/steering`
  takes `{sessionId, prompt: ContentBlock[], _meta?}` and answers `injected`,
  `startedNewTurn` or, when the request carries `_meta.steering.idleBehavior:
  "promptRequired"`, `promptRequired` with nothing done (`:553-578`, `steer()` at
  `:3713`). The app always sends that option to Claude Code: a turn the agent
  starts by itself for a steer is detached from any `session/prompt`, so nothing
  would ever tell the app it ended. An injected message pre-empts the current
  generation (the SDK aborts the cycle; the steered message runs as a second
  one) and while a permission or question waits it is delivered at `later`
  priority instead (`:3766`); the turn settles only after a result answers the
  steer. A second `session/prompt` mid-turn would be queued by the agent
  (`promptQueueing`), but the app steers instead and queues on the phone only
  when asked (`queue: true`).
- **Codex**: `initialize._meta.steering.supported`; params `{sessionId, prompt}`
  only (`CodexAcpServer.ts:1992`, extra fields ignored); answers `injected`,
  `startedNewTurn` or `failed`; steers of one session are serialised by the
  adapter (`SteeringQueue.ts`). A picture on a model without vision is refused
  with "The current model does not support image input" (`:1827`), for a steer and
  for a prompt alike. After `startedNewTurn` the new turn is detached too, and
  Codex has no `promptRequired`: the app shows the message and does not claim a
  running turn it could never see end. It can only happen when the turn ended
  while the steer was in flight; what happens to a `session/prompt` sent while
  such a turn still streams is UNVERIFIED (the adapter waits for earlier
  prompts to drain, `:1869`).
- **omp**: no steering method (`_omp/*` extensions only). A `session/prompt`
  while the app's own turn runs **cancels that turn** ("Implicitly cancel the
  running turn so the new prompt can queue behind the abort cleanup",
  `modes/acp/acp-agent.ts:803-824`), and while a turn of the agent's own runs
  (autonomous, no prompt of ours) it answers `-32003 sessionBusy`
  (`:857-871`). So omp messages are **never** sent mid-turn: the app queues them.
  A `-32003` answer means nothing was taken: the client takes the optimistic
  message row (by its key, wherever the agent's own output has got since) and
  the turn back out of the state (`AgentSessionState.withoutUserMessage`), the
  saved copy's lines with it (`TranscriptRecorder.takeBackLocalUser`), and the
  text waits in the queue, held. The keeper does the same in its log (item 3
  of "The keeper"): a message omp refused must not come back as a bubble after
  a re-attach. Each Resume that omp refuses again used to add one more
  identical bubble; a person who sends the same words twice, and has both
  taken, still sees two.
- **pi**: no steering. `pi-acp` queues a second prompt itself and says
  "Queued" in a message chunk, with `session_info_update._meta.piAcp.queueDepth`
  (`session.ts:365-387`), and a cancel clears that queue and resolves the queued
  prompts as cancelled (`:396-412`), where the phone cannot show, edit or
  remove them. The app queues on the phone and sends one prompt at a time.

**The queue** (`PromptQueue`; `AgentSessionView.queued`, `editQueued(id, text)`,
`removeQueued(id)`, `resumeQueue()`). A `QueuedMessage` has `id`, `blocks`
(`text`, `attachments`), `at`, `state` and `heldReason`:

- `waiting` goes out when the turn ends, and only then: when the session is
  attached, not replaying, not settling after an attach (1 s: the keeper has not
  yet said whether a turn runs), idle and with nothing pending, one prompt at a
  time. The test keeps a counter of prompts in flight and asserts it never
  passes 1.
- `held` never goes by itself. Stop holds everything that waits, at once ("Held
  because you stopped the turn"); a turn that ends `cancelled` or `error` on a
  live link holds what is left; a message the agent refused (a picture on a
  text-only model, `AcpProtocolException`, an auth error) is added held with
  the reason, so the text is not lost. `resumeQueue()` releases all held
  messages, in order. Editing keeps the attachments; a blank text on a message
  with none changes nothing.
- Held in memory by `AcpAgentSession`, nothing on disk. It survives a dropped
  link and a re-attach of the same session object (the transcript is replaced
  by the replay, the queue is not) and the screen closing. It does **not**
  survive the app being killed; the person's unsent text is lost with it. After a
  re-attach nothing goes out until the keeper's `state_update` says the agent is
  idle (a dropped link does not hold the queue: the turn on the keeper may still
  run).
- The list is replaced on each change: compare by identity.

**Known gap, in the keeper (not changed here).** `keeper_script.dart` logs a
`session/prompt` of the phone as a `user_message_chunk` (`begin_turn`) so a
replay shows it, but `_session/steering` goes through as an ordinary forwarded
request: a steered message is not in the keeper's log, so after a re-attach
(`session/load` served from that log) it is missing from the transcript, and a
`startedNewTurn` turn is not counted in `turn_active`. Fix in the keeper: log the
steering `prompt` blocks like `begin_turn` does, and treat `startedNewTurn` as a
turn.

**Pictures and files** (`sendBlocks`; `acceptsImages`, `acceptsEmbeddedContext`
from `promptCapabilities`; the client refuses an image or embedded block the
agent did not advertise, and the session keeps the message held with that error).

- `image_prep.dart`, `prepareImage(bytes)`: refuses input over 25 MB or 150
  megapixels (`ImagePrepException`, a message for the person), decodes with
  `dart:ui` (`ImageDescriptor.instantiateCodec` with a target size, native and
  off the UI isolate; the JPEG decoder scales while decoding, so a 12 MP photo
  is never held at full size), downscales so the long side is at most 1568 px,
  flattens transparency onto white and encodes JPEG in a worker isolate with
  `package:image` (`dart:ui` cannot encode JPEG), quality 85, 75 ... 35, then
  a fifth smaller, until it is at most 1 MiB. A re-encode carries no EXIF (no
  GPS); the desktop engine applies the EXIF orientation before that (a
  test shows it; on the phone UNVERIFIED). `PreparedImage.toBlock()` is the
  `ImageBlock`. All four adapters advertise `image`; Codex refuses on a text-only
  model and the app says so as a plain error (and keeps the text, held).
- `prompt_content.dart`: an `@file` is a `resource_link` with `name` = the path
  relative to the session's folder (absolute when outside), `uri` = absolute
  `file://` (percent-encoded) and **no title**. What each adapter does with it:
  omp keeps `title ?? name ?? uri` (`acp-agent.ts:1711`), so only the name
  survives and a title would hide the path; pi writes `[Context] <uri>`
  (`translate/prompt.ts:22`); Claude Code writes `[@<last uri segment>](<uri>)`
  (`formatUriAsLink`, `acp-agent.ts:10544`); Codex writes `[@<name>](<uri>)`
  (`CodexAcpClient.ts:1344`). That one form reads in all four. Embedded text
  (`resource` with `text`) goes only to an agent with `embeddedContext` and only up
  to 64 KB (`maxEmbeddedBytes`); a bigger file stays a link.

**Signing in** (`AgentSessionView.authNeeded`, `auth_needed.dart`). Detected
when `session/new`/`load` or a prompt (or steer) fails with ACP `-32000`
(`auth_required`) and a message about authentication, or with `authMethods` /
`reason: auth_required` in the error data (pi-acp's `authRequired`,
`auth-required.ts`; Claude Code and Codex throw `RequestError.authRequired()`
with no data). `-32000` alone is not enough: the keeper uses it too ("The client
went away", "No client is attached"). `AuthNeeded` has the words for the person
("Claude Code needs you to sign in on the host."), the agent's own message,
and the methods (`AuthChoice`: id, name, description, `terminal` when the method
has `type: "terminal"` or `_meta["terminal-auth"]`, with that hint's label and
`command args` for display). The methods come from the error data when it has
them, else from the `initialize` answer. The phone runs no login flow: it never
calls `authenticate` and does not advertise `auth.terminal` (so Claude Code and
omp send no terminal methods at all, pi always does; the sign-in itself happens
in a terminal session on the host). On a failed attach the link is `failed` with
that sentence, and Retry (`reattach`) attaches again. Cleared by the next send and
by a successful attach. No trace holds an auth error (none of the 16 traces was
recorded signed out): the shapes are from the adapters' source, UNVERIFIED live.
Claude Code's v2 `stopReason: error` with `error.code -32000` in a `state_update`
is not read.

### Sending a phone file to the host (data side)

An ACP prompt can carry an image as bytes, but any other phone file has to be
UPLOADED to the host and handed to the agent as a `resource_link` with its host
path. Data side only; the attach sheet is another piece (`docs/DESIGN.md`).

- **Where it lands.** `reserveInboxPath(machine, sessionKey:, fileName:)`
  (`host_inbox.dart`) returns `<home>/.herdr-mobile/inbox/<sha1(sessionKey)[0:12]>/<yyyyMMdd-HHmmss>-<safe name>`,
  outside every repository. `<home>` is the SFTP login directory (`realPath('.')`).
  The path is built ONLY from that base and `inboxSafeName(fileName)`: the last
  path segment, everything that is not a letter (any script, Vietnamese
  included), digit, `.`, `-` or `_` replaced by `_`, leading dots removed (never
  a dotfile), at most 100 characters and 200 bytes with the extension kept, never
  empty (`file`). `../../.ssh/authorized_keys` becomes `authorized_keys` inside the
  session folder. A taken name gets `-2`, `-3` before the extension (checked on
  the host, and against names handed out in this run). Folders are created 0700
  (one `makeDirs` per folder per run, started with the first name check), the
  file 0600.
- **How it travels.** `RemoteFiles.upload(localPath:, remotePath:, onProgress:)`
  returns an `UploadJob` (`done`, `cancel()`). The file is read and sent INSIDE
  the transport isolate on the machine's one SSH connection and SFTP channel (no
  new connection; sshd's `MaxSessions` is not spent). Only paths go to the
  worker and only counters (`uprog`: sent, total) come back, at most every 100
  ms; bytes never reach the UI isolate. Disk reads go through a ring of 32 KB
  buffers (nothing allocated per block) into WRITE requests kept in flight (a
  window, not write-wait-write): the window follows the link's bandwidth delay
  product (starts at 8, 1.5x the product plus two, at most 32 = 1 MB), so the
  queue stays short. A buffer is refilled only after its request was answered.
- **Browsing wins.** Browsing and uploads share the one SFTP channel, and a
  listing queued behind a window of writes waits for it to drain. So the window
  drops to 4 while any browse request is in flight, two uploads split it, and
  the adaptive window never holds more than the link needs.
- **Caps.** 200 MB (`uploadMaxBytes`): a bigger file fails `tooLarge` from one
  local stat, before anything connects. At most 2 uploads run per machine
  (`RemoteFiles.maxUploads`), the rest wait in order; a waiting upload that is
  cancelled never starts and a cancelled or failed one frees its place at once.
- **Failure.** Every failure is the job's `done` error, a `RemoteFileException`;
  `UploadCancelled` (a subclass, kind `failed`) after `cancel()`. A lost link
  (or 30 s without an answer) is `network` and nothing resumes; the half-written
  file is closed and removed in the background (on a dead link that cannot work:
  the cleanup below collects it). `cancel()` returns at once: no more writes are
  issued, `done` fails, the partial is removed afterwards.
- **Cleanup.** `InboxJanitor` (`host_inbox.dart`, wired in `sshConnectionFactory`)
  sweeps each machine once per 24 h (last run in prefs) 20 s after it first goes
  online: regular files older than 14 days directly inside `<inbox>/<12 hex>/`,
  at most 200 per sweep, SFTP only, never a link, a folder, or anything outside
  the inbox. Session folders stay (empty folders are a few bytes).
- **Trust.** The agent receives that path and can read the file, and so can any
  process of the same host user. Do not send secrets this way; 0600 and a folder
  outside the repo only keep it out of `git status` and other users' reach.
- **Measured.** `benchmark/upload_bench.dart` (modelled link) and
  `benchmark/upload_real_bench.dart` (a real sshd on loopback, through the
  production isolate path) print the throughput. Loopback has no latency, but
  dartssh2's Dart-side encryption costs CPU as on a phone, only faster: never
  quote it as a phone number.

## Slash commands, questions, permissions

- **Slash commands.** `available_commands_update` replaces the whole list; omp
  sends 98 including `skill:<name>` and an input `hint`. The palette
  (`SlashViewModel`) takes `AgentSessionState.commands` for agent sessions and
  keeps the built-in tables for terminal sessions only. The agent decides what a
  typed `/name` means; the client sends it as prompt text.
- **Questions.** `elicitation/create` in form mode is the question tool of all
  three agents (omp, Claude AskUserQuestion, Codex request_user_input). The UI
  renders `ElicitationSchema.fields` (string, number, single and multi enum,
  boolean), validates with `schema.validate()` (the spec says clients SHOULD),
  and answers accept/decline/cancel. Never offer URL mode until the app has a
  consent screen that shows the full URL (spec requires it). Forms must not be
  used for secrets; Codex marks them `isSecret` in `_meta.codex`: show a
  warning, do not hide the field.
- **Permissions feed risk.** A `PermissionRequest` carries `toolCall.kind`,
  `title` and `rawInput`. For `execute` the command is `rawInput.command` (omp,
  Claude, Codex shapes differ: take `command` when it is a string, else
  `title`). Run `commandRisk(command)` / `riskOf(title)` from
  `app/lib/data/repositories/command_risk.dart`; always show the command. Option
  kinds replace the text heuristics: `PermissionOptionKind.isStanding`
  (`allow_always`, `reject_always`) needs the second tap, and `grantsStandingPermission(option.name)`
  stays as a net for agents that mislabel. Option ids are agent-specific
  (`allow-with-updates`, `allow_for_session`, `accept_execpolicy_amendment`):
  show `name`, send `optionId`, never match ids. The gate is a hint with a
  reason, never the only safeguard.

## The session screen

`app/lib/ui/features/agent_session/`, reading `AgentSessionView` only (never a
transport). One slim bar (status glyph by phase, title over
`agent · machine · folder`, a button for the mode/model/config options), a
plan header (`1 of 3` and the current step), a virtualized transcript stuck to
the bottom with Jump to latest, the permission dock or question form, and the
composer. Items: user message as a quiet block (folds after 8 lines), agent
message as Markdown (`ui/core/markdown/`, DESIGN.md "Markdown": code blocks with
syntax colour and a copy button, tables, tappable paths and links through
`AgentMdScope`), thoughts collapsed to "Thinking" (Markdown inside), tool calls as one-line
rows that expand (diff with +/- colours, terminal output capped to the last 40
lines with Show all). The permission dock always shows the command (mono)
above the options; options of kind `allow_always`/`reject_always`, and any with
a risk reason from `command_risk.dart`, need a second tap that says why;
Cancel request answers `cancelled`. Questions render the elicitation schema
(string, number, boolean, single and multi enum) with validation; URL mode is
never offered. The composer's send button is a stop button while the phase is
not idle; a lone `/word` opens a palette built from `AgentSessionState.commands`
(its own small palette: `SlashViewModel` is terminal-only). Link states show a
strip: reconnecting, ended with the reason, failed with Retry, and "Opened on
another device" with Take over.

### What the chat shows, and which agent sends what

Data the app used to drop, now kept. Facts carry the
adapter source they come from; nothing here was run against a live Codex, pi
or Claude yet (UNVERIFIED), the reducer and the screen are tested with
messages shaped like the adapters' own recorded fixtures.

- **Command output.** omp and Claude Code put a command's output in
  `content` text (and `rawOutput`). codex-acp and pi-acp announce a command
  with `content: [{type: terminal, terminalId}]` and `_meta.terminal_info
  {cwd, terminal_id}`, and send the output **only in `_meta`**, as deltas to
  append:

  | Key | Sender | Meaning |
  | --- | --- | --- |
  | `terminal_output_delta {terminal_id, data}` | codex-acp, to a plain client (`ToolCallReports.ts`, `client-profiles.test.ts`) | a chunk of output; with no streaming, the whole output once at the end |
  | `terminal_output {terminal_id, data}` | pi-acp (`bash.ts`), codex-acp for Zed's profile | the same, another name; pi sends the part of the result that extends what it sent before, or the whole result when it does not extend it |
  | `terminal_exit {terminal_id, exit_code, signal}` | both | the end; codex sends `exit_code: null` when it cannot tell |
  | `mcp_output_delta {data}` | codex-acp | one trimmed progress line of an MCP call |
  | `terminal_input {terminal_id, data}` | codex-acp, AIR clients only | stdin the agent typed; ignored (a plain client gets it as an output chunk) |

  The reducer folds them into `ToolCall.output` (`ToolOutput`: `text`,
  `progress`, `exitCode`, `signal`, `cutChars`) and takes them out of
  `ToolCall.meta`, which is now merged key by key instead of replaced per
  update (`terminal_info.cwd` stays). Deltas are appended in arrival order; an
  update for a call whose start was missed creates the call and keeps its
  output; a repeated `tool_call` start replaces the fields but keeps the
  output; a second `terminal_exit` replaces the first. There is one buffer per
  call (both adapters use the tool call id as the terminal id), capped at 64 K
  characters with some slack, cut at a line start, and `cutChars` says how much
  went. No sequence numbers exist, so a delta the agent sends twice is shown
  twice. The open row shows the output as the command's output (colour codes
  stripped, a `\r` rewrite keeps the last version, hidden characters shown),
  `Exited with code N.` / `Stopped by signal S.` when it did not succeed,
  `No output.` for a finished command that printed nothing, `Waiting for
  output…` while one that has not printed yet runs, and the old "output is in a
  terminal on the host" note only when a finished call truly carries nothing.
  The replay after a re-attach is the keeper's log: a tool call of an old turn
  can come back with its output cut (`Output trimmed`, see "The keeper", item 3).
- **Stop reasons.** Claude Code sends `refusal`, `max_tokens` and
  `max_turn_requests` (`claude-agent-acp` `acp-agent.ts`), omp `max_tokens` and
  `refusal` (`acp-agent.ts:1639-1661`); codex-acp and pi-acp send none of them
  (not found in their sources). The reducer appends a `TranscriptStop` (key
  `n<N>`, a quiet row: "The agent stopped: it hit the length limit." /
  "...it refused to continue." / "...it reached its limit of steps for one
  turn.") when a turn ends with one, from the prompt response and from the v2
  `state_update idle` alike (one row if both report it). `cancelled`, `error`
  and `end_turn` add none (an error already shows as the session's problem).
  Rows are not persisted by any agent: a history the agent replays on
  `session/load` has none.
- **Boolean options.** The app advertises
  `clientCapabilities.session.configOptions.boolean` in `AcpClientCapabilities`
  **and in the keeper's own `initialize`** (`keeper_script.dart`; the agent
  never sees the app's: the keeper asks once and caches). Claude Code
  (`clientSupportsBooleanConfigOptions`) and Codex (`FastModeConfig.ts`) then
  send `fast` as a boolean, which the session bar draws as a switch. omp is
  safe: it builds only select options (`acp-agent.ts:1746-1784`), never reads
  `clientCapabilities.session`, its ACP layer is a plain TypeScript interface
  with no validation (`packages/utils/src/acp/protocol.ts`), and it refuses a
  boolean `set_config_option` (`:759`), which the app never sends because omp
  never sends a boolean option. A keeper that is already running asked its
  agent at its own start and keeps that answer for its whole life: only
  sessions started after the update get switches.
- **Kept `_meta`, usage.** Chunks, `agent_message`-style upserts,
  `session_info_update` (pi-acp: `piAcp {queueDepth, running}`, kept in
  `infoMeta`), `usage_update` and `PromptResponse` keep their `_meta`.
  `PromptResponse.usage` (omp sends it, `#buildTurnUsage`) is `TurnUsage`,
  held as `AgentSessionState.turnUsage` / `turnMeta` for the last finished turn
  (cleared by a turn that reports none). `usage_update` was already read into
  `usage`. No screen shows them yet. Claude's `_meta.claudeCode.parentToolUseId`
  (on everything a subagent says) is on `MessageChunk.meta`, `MessageUpsert.meta`,
  `PlanUpdate.meta` and in a tool call's `_meta`; the reducer routes by it
  (see "Subagents (data side)").
- **Auto-resolving questions.** Codex sends
  `_meta.codex.autoResolutionMs` on a `request_user_input` form when it will
  go on without an answer (`CodexElicitationHandler.ts:290-306`: after the
  timeout it resolves with empty answers and aborts the request). The question
  form shows "The agent goes on without an answer within 45 s." under the
  fields, computed from `PendingQuestion.receivedAt` (the app's clock when the
  request arrived) plus the time, moving once a second through a private
  one-second `StepClock` that runs only while the label is on screen and time
  is left (nothing animates). "Within" is deliberate: after a re-attach the
  keeper re-issues the request, so the app counts from the re-issue and the
  agent's own timer may be further along. When the agent withdraws the
  request, the form goes as before. Codex deprecates the field in favour of
  `isBlocking`; the app reads only the field.
- **Activity stamp.** `AgentSessionState.lastActivityAt` is set by every
  update from the agent, modelled or not (`apply(update, at: clock())`;
  `AcpClient` stamps with its clock, the session's `_clock`). It is the data
  for a status line that says "working" while text still arrives after the
  `PromptResponse` (Claude with background tasks, UNVERIFIED). `phase` and the
  board do not read it yet: what counts as recent is a UI decision.

## Phases

`idle`: no turn. `working`: a prompt is in flight, or v2 `state_update: running`.
`blockedOnPermission` / `blockedOnQuestion`: a request waits (permission wins
when both). `disconnected` is a flag, not a phase: the link ended and the agent
may live on (with a keeper it does). Board "Needs you" = blocked, with the
machine and the link live; "to review" (the Done section) = the last turn
ended and the user has not opened the session (`lastStopReason` + a per-device
reviewed marker, Attention's model). Both are `AttentionSet`'s rules, shared
with the terminal panes; the session rows sit in the same status sections.

## Risks

- ACP v2 is a draft; v1 messages are modelled, v2 fields tolerated, a v2-only
  agent is refused at `initialize` (`AcpProtocolException`).
- Third-party bridges (pi-acp, acp-adapter) deviate (cancel as request,
  `session/load` closing live sessions); check each before shipping a route.
- Resume races a TUI: Codex refuses while it holds the thread; Claude and pi
  share session files with their TUIs (concurrent writers UNVERIFIED).
- `session/new` leaves a session file even when empty (omp); the app should
  list and offer to resume rather than create per tap.
- Prompt turns have no timeout. A dead link is noticed by the transport: SSH
  pings every 25 s (10 s timeout) and a missed ping resets the connection, so
  every exec channel, and with it every session, ends within ~35 s and the
  session re-attaches (keeper) with backoff.
- Large `session/load` replays and 781-entry config options: parse in the
  transport isolate, reduce on the main isolate in small batches (the reducer
  copies the item list per chunk: fine for hundreds of items, batch beyond).
- Auth: omp and Claude use the host's stored login; Codex and pi may answer
  `auth_required`. The UI needs a "sign in on the host" path (terminal session).

## Open questions

1. Keeper on every host by default, or opt-in per machine? (python3 only.)
2. Where does the keeper log live, and how long?
3. omp `/collab` snapshot polling for terminal rows: worth it before keepers?
4. Is `claude-agent-acp` conformant enough (steering `_meta`, ext methods) or
   do we pin a version per host?
5. Image attachments: the phone has the camera; all four routes accept images.
6. One keeper for several sessions of the same agent (ACP allows it), or one
   per session? One per agent process is assumed above.

## Decision data

The data half of what a decision shows: pure Dart under
`app/lib/data/decision/` plus `data/repositories/last_seen.dart`, no widgets.
The session screen reads them (see "Who reads it" below). Data tests:
`app/test/decision/` (real traces from `app/test/fixtures/traces/**` replayed
through the reducer, plus hostile inputs).

**Permission evidence** (`permission_evidence.dart`).
`permissionEvidence(request, items:)` gives a `PermissionEvidence` for a
`session/request_permission`; `planApprovalEvidence(question, items:)` does the
same for an omp plan approval (an `elicitation/create`), else null. Parts:

| Part | Source | Bound |
| --- | --- | --- |
| `planMarkdown` | `rawInput.plan` (a non-blank string) on any request; else the first text of `toolCall.content` when the call is a plan call: kind `switch_mode` (Claude `ExitPlanMode`: title `Approve Plan`; codex plan review), the tool name `ExitPlanMode`, or an option id `implement_plan` / `revise_plan`. A `Bash` call's content text is a description, never a plan | cut at 40000 characters (`planCharLimit`) at a line start, a code fence left open is closed, then `… N more characters not shown`; `planCutChars` says how many |
| `diffs` | the `ToolDiff`s of `toolCall.content`: path, old/new text, `added`/`removed` line counts, `isNew` | at most 12 (`hiddenDiffs` counts the rest); each side cut at 60000 characters (`cutChars`); the count is the minimal line diff (Myers, edit distance only), and an upper bound with `approximate: true` past 1000 edits, 20000 lines or a cut side |
| `locations` | `toolCall.locations` (`path`, `line`), deduped; with no locations and no diff, the `file_path`/`filePath`/`path`/`notebook_path` of `rawInput` | at most 20 (`hiddenLocations`) |
| `intent` | `lastAgentSentence(items, beforeToolCallId:)` | 200 characters |

Every text is free of ANSI sequences; plan and paths show other hidden
characters (bidi marks, zero-width, controls) as visible `‹U+202E›` escapes (the
rules of `ui/.../visible_text.dart`, copied into `plain_text.dart` because the
data layer cannot import `ui/`); the intent drops them, since a direction
override must not reorder a sentence. No plan or diff means null or empty, never
a placeholder.

- **Which agent sends a plan how** (read from the adapters' upstream source,
  the recorded traces hold none): Claude `ExitPlanMode`
  (`claude-agent-acp` `tool-calls/reporters/interaction.ts`) sends kind
  `switch_mode`, title `Approve Plan`, the plan as a text content and in
  `rawInput.plan`; the prompt's own title `Ready to code?` is in
  `PermissionRequest.title` / `_meta`. Codex
  (`codex-acp/src/__tests__/scenarios/data/**/plan-review-permission.jsonl`)
  sends kind `switch_mode`, `rawInput.plan`, options `implement_plan`
  (allow_once) and `revise_plan` (reject_once). omp
  (`acp-agent.ts` `#requestAcpPlanApprovalChoice`) asks a form: message
  `Approve plan "<title>" and start implementation?`, a blank line, **the first
  12 lines of the plan** and `…` when there are more, and one string enum
  `Approve and execute` / `Refine plan`. `planApprovalEvidence` matches exactly
  that (both enum values and the message start) and marks
  `planIsPreview` when the `…` line is there: the full omp plan is a file on the
  host the phone cannot read over ACP, so say "first 12 lines" in the UI.
  UNVERIFIED against live agents: the recorded plan scenarios use the todo
  tool, so no fixture holds a plan approval; the shapes are the adapters' own
  test data, written into the tests.
- **`lastAgentSentence(items, beforeToolCallId:)`**: the nearest agent message
  before the call (else before the end of the list) that has a sentence, and
  `null` at the first user message (an earlier turn's text is not why the agent
  asks now). Thoughts are skipped. It reads only the last 4000 characters,
  drops closed fenced code (and an open one), reduces Markdown (emphasis, code
  ticks, links, list and heading marks) to words, takes the last block (a list
  item is its own block; a wrapped paragraph is one), and splits sentences at
  `. ! ? …` followed by a space or the end, and at CJK/fullwidth stops
  (`。！？．｡`, Arabic `؟`, danda) with no space needed. `src/main.py`, `3.5.1`,
  `e.g.`, `Dr.` and a list number `1.` do not split. Nothing with a letter or
  digit (emoji only, `...`) is null. Recorded cases: Claude's `subagent` trace
  gives "I'll fetch the TaskCreate schema and then create a task to run ls."
  past two tools and a thought; Claude's and omp's `permission` traces give
  null (the agent had only thought, or asked before saying anything).

**Mode risk** (`mode_danger.dart`). `assessMode(id:, name:)` returns a
`ModeAssessment` (`ModeRisk {none, elevated, dangerous}` and a one-sentence
reason, null for none); `assessSessionMode(state)` reads the session's current
mode; `currentModeOf(state)` is the shared "which mode is this session in" (the
`mode` config option, else `modes`; null when `modes` only repeats a
thinking-level option, which is what pi-acp does). Id and name are both read
and the worse wins; each is looked up in a table of known modes by its
lower-case letters and digits only (`bypassPermissions`, `bypass_permissions`
and `Bypass Permissions` are one entry), then matched against words for modes
nobody has listed. Descriptions are never read (Claude's `default` says it
"prompts for dangerous operations").

| Route | Mode (id) | Risk |
| --- | --- | --- |
| Claude | `default`, `plan`, `dontAsk` (denies what is not pre-approved) | none |
| Claude | `acceptEdits`, `auto` (a classifier answers the prompts) | elevated |
| Claude | `bypassPermissions` | dangerous |
| Codex | `read-only`, `workspace-write` (codex's own default preset) | none |
| Codex | `agent` ("Auto review": asks only for what it judges unsafe) | elevated |
| Codex | `agent-full-access` ("Full access"), `danger-full-access` | dangerous |
| omp | `default`, `plan` | none |
| pi | none: its modes are thinking levels | none |
| unknown | contains `bypass`, `yolo`, `fullaccess`, `dangerously`, `skippermission`, `skipapproval`, `nosandbox` | dangerous |
| unknown | contains `acceptedits`, `autoaccept`, `autoapprove`, `autoedit`, `acceptall`, `dontask`, `neverask`, `noprompt`, `noapproval`, `unrestricted`, `unsafe`, or has the word `auto` / `autonom…` | elevated |

Unknown and suspicious means shown, so a wrong guess costs a tint, not trust.
Every mode id in the recorded traces is asserted against this table. Changing a
row is a one-line edit of `_known`.

**Session chips** (`session_chips.dart`). `sessionChipsOf(state)` gives
`SessionChips`: `all`, `shown` (at most 4), `overflow`, `hidden`. Order is fixed
whatever order the agent lists options in: mode, model, effort (category
`thought_level`), boolean switches in the agent's order (`on` carries the
state), then any other select, labelled `Title: choice` (a bare `Default` would
mean nothing). The mode chip carries `risk` and `reason`; it is the only risky
kind, and a risky chip is kept in `shown` even when it would be cut. A model the
agent names only by id (`provider/name`) loses the provider prefix. Labels are
cleaned of hidden characters and cut at 28 characters. A setting with no value
to show, and an option of a kind this client does not know (`UnknownConfigOption`),
make no chip. `settingId` is the option to `session/set_config_option`; a mode
listed only as `modes` has `viaModes` (use `session/set_mode`).

**Last seen** (`repositories/last_seen.dart`). `LastSeen([store])` keeps one
`SeenMarker(at, itemCount)` per session key in prefs key `lastSeen.v1`
(`PrefsLastSeenStore`; tests use `MemoryLastSeenStore` from
`test/decision/support/trace_session.dart`), the most recent 200 (re-marking
moves a session to the front). Call `load()` at start-up, and
`markSeen(key, at, state.items.length)` when the person leaves the screen or
the app goes to the background. `sinceLeft(key, state)` returns `SinceLeft`
(`since`, `steps`, `tools`, `messages`, `stops`, `notes`, `needsYou`,
`firstUnseenKey`) for "6 steps since 14:02 · 1 needs you" and the divider above
`firstUnseenKey`, or null:

- No marker (first visit): null, no divider.
- **Position is an item count, never a time**: the transcript only grows at its
  end, so every item at an index at or above the marker is new, and replayed
  items need no usable time. A history replayed by `session/load` is not news:
  while `state.replaying`, or while `items.length` is below the marker (the
  replay has not got there yet), the answer is null; a replay that rebuilds the
  same items gives no news up to the marker, only what lies past it. Ask once
  the replay has finished; asking in the middle of it under-counts.
- `steps` = new tools + new agent messages + new stop rows + new notes (the
  agent changed the mode on its own). The user's messages and the agent's
  thoughts are news but not steps; the divider still goes above the first new
  item of any kind.
- `needsYou` = every pending request now, new or old. Nothing new and nothing
  waiting is null. A request already pending when the person left gives
  `steps == 0`, `needsYou == 1`, `firstUnseenKey == null`.

**Who reads it** (the session screen, `app/lib/ui/features/agent_session/`, drawn
as DESIGN.md "What a decision shows" says): the permission dock and the
question form call `permissionEvidence` / `planApprovalEvidence` once per
request (the panel is keyed by it) with `session.state.items` at that moment;
`SessionChipsRow` (above the composer) reads `sessionChipsOf`;
`announcesDanger` (`danger_announce.dart`) reads `currentModeOf` and
`assessMode` for the one `armed` haptic; `AgentSessionScreen` loads `LastSeen`
from the providers (`bootApp` loads it before `runApp`), calls `markSeen` when
the screen closes and on `paused` / `hidden`, and asks `sinceLeft` once, when
the transcript is whole: `state.replaying` is false and the link is live (or
ended with items). A session still connecting is never marked, so a history
that has not arrived cannot overwrite where the person was.

Not done: the Claude plan file (`planFilePath`, sent only to clients that
advertise `planFile`) is not read; the since-you-left header line is the
divider only (the bar adds nothing).
