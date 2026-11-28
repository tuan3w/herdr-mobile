//! The `keeper` service: the keeper's commands (`probe`, `list`, `start`,
//! `history`, `kill`), the attach stream to a keeper's socket, and the
//! agent-log streams (`follow`, `blob`), on the one `serve` connection.
//!
//! The work is [`keeper::ctl`] and the `run` functions of `keeper::follow` and
//! `keeper::history`, the same code the command line runs. This module checks
//! what a client sent, maps the exit codes the command line ends with to wire
//! errors, and moves bytes.

use crate::service::{Class, MethodKind, MethodSpec, Service};
use crate::session::{Incoming, StreamCtx, BATCH_HOLD};
use keeper::ctl::{self, CtlError, Env, StartRequest};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError};

/// What a client may send as one line to a keeper before the line is dropped
/// (the daemon's own cap, `keeper::spawn::MAX_CLIENT_LINE`).
const CLIENT_LINE_CAP: usize = keeper::spawn::MAX_CLIENT_LINE;

/// Longest path accepted (a folder or a log file), as the app's
/// `keeper_command.dart` has it.
const MAX_PATH: usize = 4096;

/// How often a running command looks for a client that left.
const WATCH_EVERY: Duration = Duration::from_millis(25);

/// Stack of the helper threads: they copy bytes.
const HELPER_STACK: usize = 128 * 1024;

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "probe",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "The agent ids this machine can run (binary on PATH, or an npx fallback).",
        args_example: "{}",
        result_example: r#"{"routes":["omp","claude"]}"#,
    },
    MethodSpec {
        name: "list",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "Every keeper on this machine, newest first: the array `herdr-host list` prints. A keeper whose process is gone is listed as exited.",
        args_example: "{}",
        result_example: r#"[{"id":"k3x9q2","agent":"omp","cwd":"/home/me/proj","state":"running","started_at":1700000000000,"pid":4242,"pending":0,"turn_active":false,"unseen_done":false,"clients":1,"session_id":"s1"}]"#,
    },
    MethodSpec {
        name: "start",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "Starts a keeper that owns one agent in `cwd` (`~` allowed) and answers with its record once the agent has answered `initialize`. Errors: bad_request (unknown agent, bad cwd), not_found (folder missing), agent_missing (not installed), failed (the agent did not start; the message holds its stderr).",
        args_example: r#"{"agent":"omp","cwd":"~/proj"}"#,
        result_example: r#"{"id":"k3x9q2","agent":"omp","cwd":"/home/me/proj","state":"running","pid":4242}"#,
    },
    MethodSpec {
        name: "history",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "What an agent remembers, for the start form: the object `herdr-host history` prints. With `cwd` only that folder's sessions, otherwise every folder. Errors: not_found (folder), agent_missing, failed.",
        args_example: r#"{"agent":"omp","cwd":"~/proj"}"#,
        result_example: r#"{"agent":"omp","list":true,"load":true,"resume":false,"more":false,"sessions":[{"sessionId":"s1","cwd":"/home/me/proj","title":"Fix the build","updatedAt":"2026-01-01T10:00:00Z"}]}"#,
    },
    MethodSpec {
        name: "kill",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "Stops a keeper and its agent (SIGTERM to the group, SIGKILL after 2 s) and removes its files. Errors: bad_request (not a keeper id), not_found.",
        args_example: r#"{"id":"k3x9q2"}"#,
        result_example: r#"{"ok":true}"#,
    },
    MethodSpec {
        name: "attach",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "Joins a keeper: DATA both ways is the keeper socket's line-delimited ACP JSON-RPC. The client may split lines across DATA frames; a line to the keeper is written whole (32 MiB cap, a longer one is dropped). The host ends the stream when the keeper hangs up; the client ends or resets to detach, and the keeper keeps running. Open with zctx. Errors: not_found (no such keeper), agent_exited (the message says why), failed (still starting, retryable).",
        args_example: r#"{"id":"k3x9q2"}"#,
        result_example: "{}",
    },
    MethodSpec {
        name: "follow",
        kind: MethodKind::Stream,
        class: Class::Bulk,
        summary: "Streams an agent's on-disk session log (an absolute .jsonl path under the home folder) as DATA text records: `<endOffset>\\t<json>`, `S\\t<offset>` (a tail read's start), `R\\t<offset>` (the file shrank or was replaced), `C\\t<offset>` (up to here is sent), `E\\t<message>`. Runs until the client ends or resets its side, `to` is reached, or `idle_exit` seconds pass without growth. Errors: bad_request, not_found.",
        args_example: r#"{"path":"/home/me/.omp/agent/sessions/s1.jsonl","from":0,"digest":false,"poll_ms":250,"idle_exit":0,"tail_bytes":196608}"#,
        result_example: "{}",
    },
    MethodSpec {
        name: "blob",
        kind: MethodKind::Stream,
        class: Class::Bulk,
        summary: "The binary payload `follow` dropped from the log line that starts at byte `start` and whose payload hash is `hash` (16 hex digits, the `ref=` of its note): DATA `B\\t<base64 piece>` records, then `D\\t<length>`. Errors: bad_request, not_found.",
        args_example: r#"{"path":"/home/me/.omp/agent/sessions/s1.jsonl","start":1024,"hash":"0123456789abcdef"}"#,
        result_example: "{}",
    },
];

#[derive(Debug, Deserialize)]
struct StartArgs {
    agent: String,
    cwd: String,
}

#[derive(Debug, Deserialize)]
struct HistoryArgs {
    agent: String,
    #[serde(default)]
    cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
struct IdArgs {
    id: String,
}

#[derive(Debug, Deserialize)]
struct FollowArgs {
    path: String,
    #[serde(default)]
    from: Option<u64>,
    #[serde(default)]
    to: Option<u64>,
    #[serde(default)]
    digest: bool,
    #[serde(default)]
    poll_ms: Option<u64>,
    #[serde(default)]
    idle_exit: Option<u64>,
    #[serde(default)]
    tail_bytes: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct BlobArgs {
    path: String,
    start: u64,
    hash: String,
}

/// The `keeper` service.
#[derive(Debug, Default)]
pub struct KeeperService;

impl KeeperService {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Service for KeeperService {
    fn name(&self) -> &'static str {
        "keeper"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, _hello: &ClientHello) -> ServiceStatus {
        ServiceStatus::available()
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "probe" => Ok(json!({"routes": ctl::probe(&env(ctx))})),
            "list" => list(ctx),
            "start" => start(ctx),
            "history" => history(ctx),
            "kill" => kill(ctx),
            "attach" => attach(ctx),
            "follow" => follow(ctx),
            "blob" => blob(ctx),
            other => Err(WireError::new(
                ErrorCode::UnknownMethod,
                format!("keeper has no method {other}"),
            )),
        }
    }
}

// ---- what a client sent ----

fn env(ctx: &StreamCtx) -> Env {
    Env {
        home: ctx.home().to_path_buf(),
        path: std::env::var("PATH").unwrap_or_default(),
    }
}

fn args<T: DeserializeOwned>(ctx: &StreamCtx) -> Result<T, WireError> {
    serde_json::from_value(ctx.args().clone()).map_err(|e| {
        WireError::new(
            ErrorCode::BadRequest,
            format!("the arguments are not valid: {e}"),
        )
    })
}

fn bad(message: impl Into<String>) -> WireError {
    WireError::new(ErrorCode::BadRequest, message)
}

/// A folder or file path as it may reach a keeper command: not empty, not
/// longer than [`MAX_PATH`], no control character (a newline included).
fn valid_path(what: &str, p: &str) -> Result<(), WireError> {
    if p.is_empty() || p.chars().count() > MAX_PATH || p.chars().any(|c| c.is_control()) {
        return Err(bad(format!("{what} is not a valid path")));
    }
    Ok(())
}

fn valid_agent(agent: &str) -> Result<(), WireError> {
    if keeper::routes::by_id(agent).is_none() {
        return Err(bad(format!("unknown agent {agent}")));
    }
    Ok(())
}

fn valid_keeper_id(id: &str) -> Result<(), WireError> {
    if !keeper::records::is_valid_id(id) {
        return Err(bad(format!("{id} is not a keeper id")));
    }
    Ok(())
}

// ---- what a command answered ----

/// The wire error for a command's exit code (`keeper::exit`).
fn wire_error(code: i32, message: String) -> WireError {
    let code = match code {
        keeper::exit::USAGE => ErrorCode::BadRequest,
        keeper::exit::GONE => ErrorCode::NotFound,
        keeper::exit::EXITED => ErrorCode::AgentExited,
        keeper::exit::MISSING => ErrorCode::AgentMissing,
        _ => ErrorCode::Failed,
    };
    WireError::new(code, message)
}

fn ctl_error(e: CtlError) -> WireError {
    wire_error(e.code, e.message)
}

/// The sentences a command wrote to its error stream, without the
/// `herdr-mobile: ` the command line puts before each.
fn sentence(err: &[u8]) -> String {
    String::from_utf8_lossy(err)
        .lines()
        .map(|l| l.strip_prefix("herdr-mobile: ").unwrap_or(l))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// The end of a command that ran as `run(args, out, err, cancel)`.
fn exit_result(code: i32, err: &[u8]) -> Result<Value, WireError> {
    if code == 0 {
        return Ok(json!({}));
    }
    let message = sentence(err);
    Err(wire_error(
        code,
        if message.is_empty() {
            format!("the command failed (exit {code})")
        } else {
            message
        },
    ))
}

// ---- calls ----

fn list(ctx: &StreamCtx) -> Result<Value, WireError> {
    let infos = ctl::list(&env(ctx)).map_err(ctl_error)?;
    serde_json::to_value(infos).map_err(|e| WireError::new(ErrorCode::Internal, e.to_string()))
}

fn start(ctx: &StreamCtx) -> Result<Value, WireError> {
    let a: StartArgs = args(ctx)?;
    valid_agent(&a.agent)?;
    valid_path("cwd", &a.cwd)?;
    let info = ctl::start(
        &env(ctx),
        &StartRequest {
            agent: a.agent,
            cwd: a.cwd,
        },
    )
    .map_err(ctl_error)?;
    serde_json::to_value(info).map_err(|e| WireError::new(ErrorCode::Internal, e.to_string()))
}

fn kill(ctx: &StreamCtx) -> Result<Value, WireError> {
    let a: IdArgs = args(ctx)?;
    valid_keeper_id(&a.id)?;
    ctl::kill(&env(ctx), &a.id).map_err(ctl_error)?;
    Ok(json!({"ok": true}))
}

fn history(ctx: &StreamCtx) -> Result<Value, WireError> {
    let a: HistoryArgs = args(ctx)?;
    valid_agent(&a.agent)?;
    let mut argv = vec![a.agent];
    if let Some(cwd) = a.cwd {
        valid_path("cwd", &cwd)?;
        argv.push(cwd);
    }
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = with_cancel(ctx, false, |cancel| {
        keeper::history::run_with(&argv, &mut out, &mut err, cancel)
    });
    exit_result(code, &err)?;
    serde_json::from_slice(&out).map_err(|e| {
        WireError::new(
            ErrorCode::Failed,
            format!("the agent's history is not JSON: {e}"),
        )
    })
}

// ---- streams ----

/// Runs `f` with a flag that is set when the stream is reset (or, with
/// `until_client_ends`, when the client ends its side). The commands that take
/// the flag stop at their next look.
fn with_cancel<R>(ctx: &StreamCtx, until_client_ends: bool, f: impl FnOnce(&AtomicBool) -> R) -> R {
    let cancel = AtomicBool::new(false);
    let finished = AtomicBool::new(false);
    std::thread::scope(|scope| {
        let _ = std::thread::Builder::new()
            .name("keeper-watch".into())
            .stack_size(HELPER_STACK)
            .spawn_scoped(scope, || {
                while !finished.load(Ordering::SeqCst) {
                    let gone = if until_client_ends {
                        !ctx.sleep(WATCH_EVERY)
                    } else {
                        std::thread::sleep(WATCH_EVERY);
                        ctx.cancelled()
                    };
                    if gone {
                        cancel.store(true, Ordering::SeqCst);
                        return;
                    }
                }
            });
        let result = f(&cancel);
        finished.store(true, Ordering::SeqCst);
        result
    })
}

/// Sends what a command writes as DATA, as it is written.
struct DataOut<'a>(&'a StreamCtx);

impl Write for DataOut<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0
            .send_data(buf)
            .map(|()| buf.len())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "the stream is closed"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// The `follow` command line flags for `a` (never `--z`: the session
/// compresses).
fn follow_argv(a: &FollowArgs) -> Vec<String> {
    let mut argv = vec![a.path.clone()];
    let mut number = |flag: &str, v: Option<u64>| {
        if let Some(v) = v {
            argv.push(flag.to_string());
            argv.push(v.to_string());
        }
    };
    number("--from", a.from);
    number("--to", a.to);
    number("--poll-ms", a.poll_ms);
    number("--idle-exit", a.idle_exit);
    number("--tail-bytes", a.tail_bytes);
    if a.digest {
        argv.push("--digest".to_string());
    }
    argv
}

fn follow(ctx: &StreamCtx) -> Result<Value, WireError> {
    let a: FollowArgs = args(ctx)?;
    valid_path("path", &a.path)?;
    ctx.set_batch(BATCH_HOLD);
    let argv = follow_argv(&a);
    let mut err = Vec::new();
    let code = with_cancel(ctx, true, |cancel| {
        keeper::follow::run_with(&argv, &mut DataOut(ctx), &mut err, cancel)
    });
    exit_result(code, &err)
}

fn blob(ctx: &StreamCtx) -> Result<Value, WireError> {
    let a: BlobArgs = args(ctx)?;
    valid_path("path", &a.path)?;
    let argv = [a.path, a.start.to_string(), a.hash];
    let mut err = Vec::new();
    let code = with_cancel(ctx, false, |cancel| {
        keeper::follow::run_blob_with(&argv, &mut DataOut(ctx), &mut err, cancel)
    });
    exit_result(code, &err)
}

// ---- attach ----

/// Cuts the client's bytes into whole lines. A partial line is held until its
/// newline; a line over `cap` is dropped whole (the rest of it too, as it
/// arrives) so the keeper never sees half a message.
struct LineAssembler {
    held: Vec<u8>,
    skipping: bool,
    cap: usize,
}

impl LineAssembler {
    fn new(cap: usize) -> Self {
        Self {
            held: Vec::new(),
            skipping: false,
            cap,
        }
    }

    /// Adds `data`; appends every line it completes (newline included) to `out`.
    fn push(&mut self, mut data: &[u8], out: &mut Vec<u8>) {
        while !data.is_empty() {
            match data.iter().position(|&b| b == b'\n') {
                Some(at) => {
                    let (piece, rest) = data.split_at(at + 1);
                    data = rest;
                    if self.skipping {
                        self.skipping = false;
                    } else if self.held.len() + piece.len() <= self.cap {
                        out.append(&mut self.held);
                        out.extend_from_slice(piece);
                    } else {
                        self.held.clear();
                    }
                }
                None => {
                    if !self.skipping {
                        if self.held.len() + data.len() > self.cap {
                            self.held.clear();
                            self.skipping = true;
                        } else {
                            self.held.extend_from_slice(data);
                        }
                    }
                    return;
                }
            }
        }
    }
}

/// Client DATA → keeper socket, whole lines only. Ends when the client ends or
/// resets (the stream's `recv` says `None`) or the keeper stops reading; then
/// the socket is shut down so the other direction ends too.
fn client_to_keeper(ctx: &StreamCtx, mut socket: std::os::unix::net::UnixStream) {
    let mut lines = LineAssembler::new(CLIENT_LINE_CAP);
    let mut whole = Vec::new();
    while let Some(incoming) = ctx.recv() {
        let Incoming::Data(bytes) = incoming else {
            continue;
        };
        whole.clear();
        lines.push(&bytes, &mut whole);
        if !whole.is_empty() && socket.write_all(&whole).is_err() {
            break;
        }
    }
    let _ = socket.shutdown(std::net::Shutdown::Both);
}

fn attach(ctx: &StreamCtx) -> Result<Value, WireError> {
    let a: IdArgs = args(ctx)?;
    valid_keeper_id(&a.id)?;
    ctx.set_batch(BATCH_HOLD);
    let mut socket = ctl::connect(&env(ctx), &a.id).map_err(|e| {
        let retryable = e.code == keeper::exit::FAILED;
        let err = ctl_error(e);
        if retryable {
            err.retryable()
        } else {
            err
        }
    })?;
    let io_error = |e: io::Error| {
        WireError::new(
            ErrorCode::Failed,
            format!("cannot use the keeper's socket: {e}"),
        )
    };
    let up = socket.try_clone().map_err(io_error)?;
    let helper_ctx = ctx.clone();
    std::thread::Builder::new()
        .name("keeper-attach-up".into())
        .stack_size(HELPER_STACK)
        .spawn(move || client_to_keeper(&helper_ctx, up))
        .map_err(|e| WireError::new(ErrorCode::Busy, format!("no thread for the stream: {e}")))?;
    // Keeper → client, as it comes: the client cuts lines itself.
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match socket.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if ctx.send_data(&buf[..n]).is_err() {
                    break;
                }
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    // The keeper hung up, or the client left (its helper shut the socket):
    // either way this side is done. The keeper itself keeps running.
    let _ = socket.shutdown(std::net::Shutdown::Both);
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse<T: DeserializeOwned>(text: &str) -> T {
        serde_json::from_str(text).expect("the example parses into the method's arguments")
    }

    #[test]
    fn every_example_is_valid_json_and_its_arguments_parse_into_the_typed_arguments() {
        for m in METHODS {
            let args: Value = parse(m.args_example);
            serde_json::from_str::<Value>(m.result_example).expect(m.name);
            match m.name {
                "probe" | "list" => assert_eq!(args, json!({})),
                "start" => drop(parse::<StartArgs>(m.args_example)),
                "history" => drop(parse::<HistoryArgs>(m.args_example)),
                "kill" | "attach" => drop(parse::<IdArgs>(m.args_example)),
                "follow" => {
                    let f: FollowArgs = parse(m.args_example);
                    // Every field the example shows reaches the command line.
                    assert_eq!(
                        follow_argv(&f),
                        [
                            "/home/me/.omp/agent/sessions/s1.jsonl",
                            "--from",
                            "0",
                            "--poll-ms",
                            "250",
                            "--idle-exit",
                            "0",
                            "--tail-bytes",
                            "196608",
                        ]
                    );
                }
                "blob" => drop(parse::<BlobArgs>(m.args_example)),
                other => panic!("{other} has no typed arguments in this test"),
            }
        }
    }

    #[test]
    fn follow_sends_only_the_flags_the_client_asked_for() {
        let a: FollowArgs = parse(r#"{"path":"/h/x.jsonl","to":90,"digest":true}"#);
        assert_eq!(
            follow_argv(&a),
            ["/h/x.jsonl", "--to", "90", "--digest"],
            "no --z: the session compresses"
        );
    }

    #[test]
    fn a_command_exit_code_becomes_the_wire_error_the_app_acts_on() {
        for (code, want) in [
            (64, ErrorCode::BadRequest),
            (66, ErrorCode::NotFound),
            (67, ErrorCode::AgentExited),
            (69, ErrorCode::AgentMissing),
            (70, ErrorCode::Failed),
            (1, ErrorCode::Failed),
        ] {
            assert_eq!(wire_error(code, String::new()).code, want, "exit {code}");
        }
        let e = exit_result(66, b"herdr-mobile: no such file\nherdr-mobile: second\n")
            .expect_err("a failure");
        assert_eq!(e.message, "no such file\nsecond", "no command-line prefix");
        assert!(exit_result(0, b"").is_ok());
        assert!(
            exit_result(70, b"").is_err(),
            "a silent failure still fails"
        );
    }

    #[test]
    fn paths_with_control_characters_or_no_length_never_reach_a_command() {
        assert!(valid_path("cwd", "/home/me/proj").is_ok());
        assert!(valid_path("cwd", "~/ünï cödé").is_ok());
        for bad in ["", "a\nb", "a\0b", "a\x1bb", "a\x7fb"] {
            assert!(valid_path("cwd", bad).is_err(), "{bad:?}");
        }
        assert!(valid_path("cwd", &"a".repeat(MAX_PATH)).is_ok());
        assert!(valid_path("cwd", &"a".repeat(MAX_PATH + 1)).is_err());
    }

    #[test]
    fn keeper_ids_and_agents_are_checked_before_use() {
        assert!(valid_keeper_id("k3x9q2").is_ok());
        for bad in ["", "../x", "UP", "a b", "ab"] {
            assert!(valid_keeper_id(bad).is_err(), "{bad:?}");
        }
        assert!(valid_agent("omp").is_ok());
        assert!(valid_agent("rm -rf").is_err());
    }

    fn lines_of(cap: usize, chunks: &[&[u8]]) -> Vec<u8> {
        let mut a = LineAssembler::new(cap);
        let mut out = Vec::new();
        for c in chunks {
            a.push(c, &mut out);
        }
        out
    }

    #[test]
    fn a_line_split_across_frames_is_written_whole_and_a_partial_one_is_held() {
        assert_eq!(
            lines_of(64, &[b"{\"a\":", b"1}\n{\"b\"", b":2}\n{\"c\""]),
            b"{\"a\":1}\n{\"b\":2}\n"
        );
        // One byte at a time gives the same lines.
        let text = b"one\ntwo two\n\nthree\n";
        let bytes: Vec<&[u8]> = text.chunks(1).collect();
        assert_eq!(lines_of(64, &bytes), text);
    }

    #[test]
    fn a_line_over_the_cap_is_dropped_whole_and_the_next_line_is_intact() {
        // Over the cap across frames: nothing of it is written.
        assert_eq!(lines_of(8, &[b"123456", b"789012", b"34\nok\n"]), b"ok\n");
        // Over the cap in one frame, complete line.
        assert_eq!(lines_of(8, &[b"123456789\nok\n"]), b"ok\n");
        // Exactly at the cap is fine.
        assert_eq!(lines_of(8, &[b"1234567\n"]), b"1234567\n");
    }
}
