# The Rust keeper daemon — design

**Status:** building. Branch `rust/keeper-daemon`.

The python keeper (`app/lib/data/services/keeper_script.dart`, ~4.5k lines) is
the oracle. This note is the design for its Rust replacement: the `herdr-host`
binary, crate `keeper`.

## Invariants (compatibility surface — do not drift)

1. **Files** `~/.herdr-mobile/keepers/<id>.{json,sock,log}`; 0700 dirs, 0600
   files; info JSON field-for-field with python `info()` (the Rust `Info`
   struct + `extra: Map` flatten already does this — a test pins it).
   Atomic write = tmp + rename (already in `StateDir::write`).
2. **Socket** `<id>.sock`, AF_UNIX SOCK_STREAM, 0600, backlog 16, bound before
   the agent spawns but **accepts only after `initialize` succeeds**.
   Line-delimited JSON-RPC. Client line cap 32 MiB, agent line cap 64 MiB,
   client write buffer cap 64 MiB (drop the slow client). Max 16 conns.
3. **Shared-session protocol** (the hard part):
   - one agent, N clients; a client is `live` after its first `session/*`
     request (other than `session/list`);
   - agent `session/update` + most notifications → broadcast verbatim to live
     clients;
   - HELD requests (`session/request_permission`, `elicitation/create`) →
     issued to **every** live client under one keeper id `kp<N>`; first answer
     wins, the rest get `_herdr/resolved {requestId, by, answer}` then
     `$/cancel_request`;
   - forwarded (single-recipient) requests → one client, tracked in a
     `fwd` table; client vanishes → agent gets `error -32000`;
   - client → agent responses are re-id'd: the client's id ↔ the agent's id
     (`routes` table for client-initiated, `fwd` for agent-initiated);
   - replay on `session/load`/`session/resume` from the in-memory `ReplayLog`
     (`_herdr/replay {sessionId, from}`, `_meta.herdr = {epoch, turn}` on turn
     starts, `{droppedTurns, trimmedTurns}` in the load result);
   - agent exit → `_herdr/agent_exited {exitCode, reason}` to all conns,
     then close;
   - `Z<base64(zlib level 6, sync-flush per batch)>\n` for ≥512-byte
     complete-line batches, keeper→client only, and only on `attach --z`
     (the *attach bridge* zips, not the daemon).
4. **Exit codes** 64/65/66/67/69/70/78 and the one-JSON-line stdout of
   `probe`/`list`/`start`/`kill`/`history`.
5. **Init handshake**: `initialize` (caps: fs=false, terminal=false,
   elicitation.form, session.configOptions.boolean, + route's
   `_meta.jetbrains.air`) → inject `agentCapabilities.loadSession=true` →
   optional `authenticate` (route `auth` method present in agent's
   `authMethods`; only −32601 tolerated) → state `running` → register
   listener → report `{"ok":true,"info":...}` on the start pipe.

## Architecture

**No async runtime** (workspace house rule: std-threads + `mpsc` +
`try_wait`/`accept` polling; the viewer says so in `main.rs:4`).

One blocking event loop in the daemon:

```
loop {
  accept on the listener (nonblocking)
  read  on every client stream + agent stdout/stderr (nonblocking)
  Child::try_wait()
  tick()          // 250 ms: init timeout, idle conns, periodic save, EOF-watch
}
```

Every read is line-split into complete JSON-RPC lines and fed to the
**`Router`** — the only owner of mutable state. The loop does I/O; the router
does logic and returns bytes to write.

```
bin/herdr-host.rs      CLI dispatch (probe|list|start|attach|kill|daemon|follow|blob|history)
spawn.rs               double-fork daemonization, agent spawn (own pgroup), report pipe
daemon.rs              the event loop: listener + conns + agent pipes + tick
router.rs              Router: the ACP proxy (in-flight tables, clients, turns)
linebuf.rs             line reader with a cap (moved out of viewer, shared)
attach.rs              the attach bridge: socket ⇄ stdin/stdout, Z-batching
records.rs             (existing) Info / StateDir / scan
replay_log.rs          (existing) the trim-tested replay log
routes.rs search.rs    (existing)
```

### `Router` state

```rust
struct Router {
  id: String,
  info: Info,                     // the record, saved on change
  agent: Child,
  replay: ReplayLog,
  epoch: [u8; 6],
  session_id: Option<String>,
  setup: Option<Value>,           // the original session/new|load result
  init: Option<...>,              // the agent's initialize result (cached answer)
  clients: HashMap<Cid, Client>, // label, viewer flag, live, pane_id, wbuf
  routes: HashMap<Id, ClientRoute>,  // client→agent in flight: {client_id, agent_id, method, prompt}
  fwd:    HashMap<String, Fwd>,        // agent→one-client: {agent_id, client}
  pending: HashMap<String, Held>,      // agent→all-clients: {agent_id, method, params, conns}
  turn: Option<Turn>,             // active prompt: sender, stash, busy
  bg_level: Option<Vec<u8>>,      // claude background-task level
  next_kid: u64,
}
```

The id tables are the heart — port them exactly from
`keeper_script.dart:1985-2072` (`on_agent_request`/`on_agent_response`) and
`1729-1816` (`on_client_request`/`on_client_answer`/`settle`).

### What is NOT in v1 (documented, deliberate)

- **macOS launchd** (`start_via_launchd`) — macOS-only, optional; the Linux
  double-fork path is the default. Port later, needs a real Mac.
- **herdr-pane tab** (`open_pane`) — optional desktop visibility; gated by
  `HERDR_MOBILE_NO_PANE`/`no-panes` in python, and a no-op without herdr.
  Off by default in the Rust daemon; the `pane_id` field is still recorded
  from a client's `_meta.herdr.pane`.
- **`follow`/`blob`/`history`** — read the agent's on-disk `.jsonl`, not the
  daemon. Separate, daemon-free; port after the core is green.
- **Cursor/Claude transforms** (`cursor/*` → plan/permission,
  `_claude/sdkMessage` background level) — agent-specific; the background
  level is kept (one line), the Cursor translation is a later pass.

The contract test (`keeper_contract.rs`) exercises exactly the v1 surface:
start/kill/attach/probe/list, the wire round trip, exit codes 64/66/69, the
route table.

## Concurrency model

- The daemon is one process, one thread for the event loop. Agent stdout and
  stderr are read nonblocking in the loop (they are the only "high volume"
  source, and the loop is already there).
- No shared mutable state across threads → no locks, no `Arc<Mutex>`.
  The `Router` is `&mut` in the loop.
- The `start` command double-forks: parent reads the report pipe (deadline
  `INIT_TIMEOUT + 20`), grandchild is the daemon. The middle child exits
  immediately so the grandchild is reparented to init and outlives `start`.

## Verification

- `cargo test -p keeper` — the contract test, re-pointed at `herdr-host`
  (its `Host::run` swaps `python3 <script>` for the built binary; the
  argv/env/exit-code/stdout contracts it asserts are the target).
- `replay_differential.rs` — unchanged, still the trim oracle.
- A hand-driven session: `herdr-host start` a stub agent, `attach`, send a
  prompt, watch the update round-trip, kill it. No live herdr touched.
