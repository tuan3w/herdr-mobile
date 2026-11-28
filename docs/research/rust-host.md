# Getting the host side out of python (all-Rust)

**Principle (owner):** the *protocol* — the agent's ACP / JSON-RPC — is the
only foreign surface, and it is **already ours in Rust**
(`rust/crates/acp`). Everything *non-protocol* — process ownership, the unix
socket, the channel mux, the desktop tab — is **us**, and should be Rust, for
performance and to drop the `python3` host prerequisite.

This is a cut-over plan, not a research note. The Rust half already exists; the
work is the process/socket daemon.

## The inventory: four embedded python scripts

All four live in Dart as string constants, shipped base64/zlib to the host.
Only the first two are load-bearing today.

| Script | Dart home | Lines | Role | Status |
| --- | --- | --- | --- | --- |
| **keeper daemon** | `rust/crates/keeper` (`herdr-host` binary) | — | Owns each ACP agent; survives phone drop; unix socket; `start/attach/list/kill/follow/blob/history`. The **phone path runs this**; the python `keeper_script.dart` is now only the terminal client (`view`/`desk`) and the three gaps below | **Shipped (phone path).** |
| **mux** | `bridge_command.dart` (`_pythonMux`) | ~170 | One relay per SSH connection; multiplexes the herdr socket into the app's framed protocol | Load-bearing; replace. |
| **bridge** | `bridge_command.dart` (`_pythonBridge`) | ~21 | Single-shot relay, `herdr`-socket → channel | Fallback path. |
| **prune** | `bridge_command.dart` (`_pythonPrune`) | ~10 | Trims the mux's projection table | Inlined into the mux. |

`_pythonEvents` (~37) is the events-only variant of the same relay. So the
relay family is **one Rust program** with modes, not four scripts.

## What "protocol" vs "us" means here

- **Protocol (foreign, stays the agent's):** ACP JSON-RPC on the agent's
  stdio. `rust/crates/acp` already owns this — `rpc.rs`, `update.rs`,
  `permission.rs`, `config.rs`. The keeper does **not** re-implement it; it
  spawns the agent and pumps stdio.
- **Us (becomes Rust):** everything around that pipe —
  - the **keeper daemon**: spawn + supervise the agent, the unix socket, the
    multi-client `attach` bridge (`_herdr/resolved`, replay), the `~/.herdr-
    mobile/keepers/` state files, `follow`/`blob`/`history`, macOS **launchd**.
  - the **relay/mux**: the host-side socket ⇄ channel pump that gives one SSH
    connection many logical channels.

The clean split is exactly the owner's line: *the agent speaks ACP (protocol);
we own the daemon and the channel (us), in Rust.*

## What Rust already has

```
rust/crates/keeper   records.rs (505)  replay_log.rs (1143)  routes.rs (67)  search.rs (129)
rust/crates/acp      rpc.rs (297)  update.rs (600)  permission.rs (91)  config.rs (155)
```

`keeper/src/lib.rs` is explicit about the contract: *"The Python keeper is the
reference. This crate must read and write the same files and speak the same
wire, because both implementations share `~/.herdr-mobile/keepers/`."* The
pure-data parts (records, replay log, routes, search) are **done**. The exit
codes (64/66/67/69/70/78) are already shared in `keeper::exit`.

`rust/README.md` "Not yet" lists the **Rust keeper daemon** as the open item —
this note is the plan for it.

## The remaining work (the daemon)

Ordered by risk, not by file:

1. **Agent process supervision.** Spawn the ACP agent, pump its stdio through
   the `acp` crate, detect exit, apply the exit codes. This is the core loop
   and the main correctness surface.
2. **The unix socket + `attach` bridge.** Accept multiple clients, fan out
   every update, route a waiting request to all of them, tell the rest who
   answered first (`_herdr/resolved` → `$/cancel_request`). The python `Keeper`
   class (≈1,300 lines, `keeper_script.dart:1145`) is the reference.
3. **State files.** Byte-compatible with the python keeper in
   `~/.herdr-mobile/keepers/` — a python-written keeper on disk must stay
   readable after a Rust upgrade and vice versa (users upgrade in place).
   `records.rs` already defines the shape; verify field-for-field.
4. **Subcommands.** `start`/`list`/`kill`/`follow`/`blob`/`history`/`probe`.
   Mostly thin wrappers over 1–3; `follow` (JSONL tail) and `blob` are I/O.
5. **macOS launchd** (`start_via_launchd`, `keeper_script.dart:2497`). The one
   genuinely fiddly Rust piece: the plist, `launchctl` bootout, the
   `dev.herdrmobile.keeper.<id>` label scheme. **Needs a real Mac check, not
   just CI** — `rust/README.md` only ships Linux + macOS binaries for
   herdr-tui, so the platform is already in scope, but launchd-from-Rust is
   unproven here.
6. **The herdr-pane tab** (`open_pane`, `keeper_script.dart:2092`). Optional;
   degrades to a no-op when there is no herdr. Port last, or gate it off in
   Rust behind the same `HERDR_MOBILE_NO_PANE` / `~/.herdr-mobile/no-panes`.

The **mux** is a smaller, independent piece: one Rust binary that speaks the
host-side half of the app's framed protocol over the herdr socket
(`MuxClient` is the Dart side, `mux_client.dart`). It replaces
`buildMuxCommand`/`buildEventsCommand` (`bridge_command.dart:349`/`366`).

## Cut-over sequence (no big-bang)

The contract tests are already the safety net: `crates/keeper/tests/
keeper_contract.rs` runs the *real* keeper hermetically (its own home, no
herdr, scripted agent), and `replay_differential.rs` compares the Rust replay
log against the python one on seeded sessions. So:

1. **Rust keeper to parity.** Implement the daemon until
   `keeper_contract.rs` + `replay_differential.rs` pass against the python
   reference, byte-for-byte on the state files.
2. **Dual-install, Rust-first.** Ship the Rust keeper binary in the release
   (herdr-tui already ships per-platform binaries + `SHA256SUMS`). Install it
   alongside the python; the app prefers Rust, falls back to python when the
   binary is absent (old host, mid-update). Same `~/.herdr-mobile/` state, so
   a python-started session is attachable by Rust and vice versa.
3. **Drive it on a phone, then on a host without herdr** (the ACP
   herdr-independence check the Rex note logged as unverified).
4. **Cut python.** Once parity is proven in the field: the app stops shipping
   the 4.5k-line python string, `keeper_command.dart` execs the binary, and
   `python3` is no longer a host prerequisite for agent sessions. Remove the
   `_needPython` guards and the exit-78 path.
5. **Mux + bridge** follow the same dual-install → cut path, independently, so
   an agent-sessions rollout is not blocked on the transport.

After 4+5, the host side is one Rust binary (the keeper) + the relay, and the
install story is just that binary — no `python3`.

## What the binary keeper had not ported (now ported)

The phone path cut over to `herdr-host` with four gaps against the python
keeper (`keeper_script.dart`). All four are in `rust/crates/keeper` now; the
python keeper's one remaining role, the terminal client `view`/`desk`, is
`herdr-tui`'s (it links the keeper as a library).

1. **The herdr-pane tab** (`open_pane`) — `pane.rs`. After `initialize`, a
   tick-polled chain of `herdr` CLI calls shows the session in the workspace of
   the linked worktree that holds the folder, else in `Phone sessions`, running
   `herdr-tui attach <id>`. It opens only when both `herdr` and a `herdr-tui`
   (`PATH`, `~/.local/bin`, `~/.herdr-mobile/bin`) resolve — the python `view`
   fallback is gone — and records the pane it used as `pane_id`. A reason not to
   open one is written to the keeper's log (`no herdr pane: …`).
2. **The alert hook** (`HERDR_KEEPER_ON_BLOCKED`, else an executable
   `~/.herdr-mobile/on-blocked`) — `alerts.rs`, with the secret masking of
   `redact.rs`. At most four at once, SIGKILL of the hook's group after 5 s.
3. **macOS launchd** — `launchd.rs`. Claude Code's keeper starts as a job of
   `gui/<uid>` (the login Keychain opens only there); the plist text and the
   `launchctl` command lines are plain data tested on every host, only the
   `launchctl` calls are macOS-only. **Not run on a Mac.**
4. **`close_fds`** — `fds.rs`, the one module with `unsafe` (the workspace
   lint is `deny`, with that module's `allow`). The agent, a hook and a `herdr`
   command start with only descriptors 0–2: `close_range(3, ~0,
   CLOSE_RANGE_CLOEXEC)`, else a sweep of 3..min(open-file limit, 4096). They
   are marked close-on-exec, not closed, because `std` reports a failed `exec`
   through a close-on-exec pipe it keeps in the child.

The state files are shared (`~/.herdr-mobile/keepers/`), so a keeper started by
the phone, by `herdr-host start` or by `herdr-tui` is attachable by all of them.

## Why Rust, concretely

- **Perf on the hot path.** The keeper pumps every agent update to every
  attached client and re-serialises the replay log on each `attach` of a long
  thread; the mux pumps every byte of every herdr request. Python's GIL +
  JSON re-encode is the cost; Rust removes it. (This is the stated reason —
  the app's `AGENTS.md` "the UI thread belongs to the person" principle has a
  host-side twin: the daemon's thread belongs to the agent.)
- **One language, one install artifact.** The host side becomes the same
  binary family as `herdr-tui`. No 4.5k-line python string embedded in Dart.
- **The protocol is already Rust.** `acp` + `keeper` exist; the daemon is the
  missing half of a crate that is mostly done.

## Risks / what to verify

- **State-format compatibility** is the hard invariant. A bug here strands
  in-flight sessions across an upgrade. The differential test is the guard;
  add a "read a python-written keeper dir" fixture.
- **macOS launchd from Rust** is unproven in this repo — gate it behind a real
  Mac run, not CI alone.
- **Concurrency** in the socket accept loop + agent supervision is the main
  correctness surface; the python `Keeper` is the oracle.
- **Do not** touch the live herdr on this machine while testing; use scratch
  state dirs (`HERDR_KEEPER_*` env, its own home) as the contract test does.

## Decisions

- **No python fallback.** Clean cutover (the `AGENTS.md` rule): when the Rust
  keeper is parity-green, the app ships the binary and stops shipping the
  4.5k-line python string; there is no "fall back to python if the binary is
  absent" path. The in-place upgrade is handled by **state compatibility**
  (a python-written `~/.herdr-mobile/keepers/` stays readable by Rust), not by
  a dual implementation. Same for the mux/bridge relay.
- **One `herdr-host` binary**, subcommands `keeper` and `mux` — one artifact
  per platform, consistent with how `herdr-tui` ships. (Revisit only if the
  install surface gets heavy.)
