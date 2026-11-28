# testkit

Test fixtures for herdr-mobile. Nothing here ships (`publish = false`); no
python is needed to run any of it. Three binaries replace the former python
fixtures, byte for byte (each is checked against the python program's own
output, and the tests freeze values recorded from it):

| binary | replaces | what it is |
|---|---|---|
| `fake-acp-agent` | `app/test/support/fake_acp_agent.py` | A scripted ACP agent. JSON-RPC lines on stdio; `session/prompt` runs the script named by the prompt text (`plain`, `ask`, `perm:<title>`, `slow`, `noise`, `die`, `sleep:<s>`, `exit:<n>`, `long:<n>`, `heavy:…`, `big:<n>`, `picture:<n>`, `reply:<text>`, `quiet`, `task:<id>`, `sdktask:<id>`, `cursor-*`, …). The doc comment at the top of `src/bin/fake-acp-agent.rs` lists every script, flag and variable. |
| `fake-herdr` | `app/benchmark/fake_herdr.py` | A deterministic stand-in for herdr's API socket: `ping`, `session.snapshot`, `pane.read`, `bench.emit` and an `events.subscribe` stream of `pane_updated` events. One JSON request per connection, one line back. Content is seeded (`pyrandom` is CPython's Mersenne Twister) and a pane advances only when it is read. |
| `bench-acp-agent` | `app/benchmark/support/bench_acp_agent.py` | A minimal ACP agent for `session_open_bench`: `session/prompt` plays the file named by `$BENCH_SEED` (one `session/update` object per line), then ends the turn. |

## `fake-acp-agent`

Run it as the agent behind a keeper (a wrapper script named `omp`,
`codex-acp`, ... that `exec`s it) or directly over a pipe.

Environment (all optional; an empty value counts as unset):

| variable | effect |
|---|---|
| `FAKE_ACP_LOG=<file>` | every message the agent receives is appended as `{"recv": {...}}`, one JSON line each (python `json.dumps` spelling) |
| `FAKE_ACP_STORE=<json file>` | the agent's own session store (`{"sessions":[{sessionId, cwd, title?, updatedAt?, messageCount?, updates:[…]}]}`); enables `session/list`, `session/load`, `loadSession` and `sessionCapabilities`, and records the sessions it makes (`sess-N`, first free N) |
| `FAKE_ACP_PAGE=<n>` | sessions per `session/list` page (default 50) |
| `FAKE_ACP_CAPS=list,load,resume` | narrows the capabilities a store advertises |
| `FAKE_ACP_LIST_FAIL`, `FAKE_ACP_LIST_DELAY=<s>`, `FAKE_ACP_LIST_NOISE` | `session/list` fails, waits, or first sends garbage plus a request of its own and waits for the answer |
| `FAKE_ACP_BUSY_FILE=<file>` | while the file exists every prompt gets `-32003 Session is busy` (after one chunk, unless the file says `quiet`) |
| `FAKE_ACP_AUTH=<method>`, `_AUTH_FAIL`, `_AUTH_UNKNOWN`, `_AUTH_EXIT` | advertise an auth method and refuse `session/new` until `authenticate`; or make `authenticate` fail, answer `-32601`, or exit 4 |
| `FAKE_ACP_FAIL_INIT` | exit 5 (stderr `cannot start: no login`) instead of answering `initialize` |
| `FAKE_ACP_INIT_DELAY=<s>` | wait before answering `initialize` |
| `FAKE_ACP_IGNORE_TERM` | SIGTERM does not end it |
| `FAKE_ACP_PID_FILE=<file>` | `<pid>\t<cwd>` appended when it answers `initialize` |

It writes `fake agent up` to stderr at start and exits 0 at EOF on stdin.

## `fake-herdr`

`fake-herdr SOCKET_PATH` binds the unix socket (replacing a stale file), prints
`READY` on stdout once it listens, and serves until killed. Exit code 1 with a
usage line without an argument.

## `bench-acp-agent`

`BENCH_SEED=<file> bench-acp-agent`, speaking ACP on stdio.

## Finding the binaries

- **Rust tests**: `testkit::bin("fake-acp-agent")` returns the path, and
  `testkit::bin_dir()` the directory. Add `testkit = { path = "../testkit" }` to
  the crate's `[dev-dependencies]` (done for `host`, `keeper` and `viewer`).
  A dev-dependency does not make cargo build another package's *binaries*, so:
  `cargo test --workspace` and `cargo test -p testkit` have them built already
  (testkit's own tests need them); when only another crate's tests were built
  (`cargo test -p host`), `bin()` runs `cargo build --offline -p testkit --bins`
  once, in the same target directory and profile, and cargo's build lock makes
  concurrent callers wait for it.
- **Everything else (Dart tests, benchmarks)**: `$HERDR_TESTKIT_DIR`, default
  `rust/target/<profile>` (the same place `herdr-host` is built into):
  `cd rust && cargo build -p testkit` (debug) or `cargo build --release -p testkit`.
  With `HERDR_TESTKIT_DIR` set, Rust tests use that directory too and never build.
  CI builds them next to `herdr-host`: `cargo build --release --locked -p host -p testkit`.

## Library

`testkit::pyjson` is python's `json.dumps` (`ensure_ascii`, default or compact
separators, `sort_keys`), `testkit::pyrandom` is `random.Random(int)`; they exist
so the fixtures print the bytes the python programs printed.
