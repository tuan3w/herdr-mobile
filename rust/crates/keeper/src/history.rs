//! `history`: briefly run one agent (no keeper, no session) and ask it what it
//! remembers, so the start form can offer "continue a session". Prints ONE JSON
//! line `{"agent","list","load","resume","more","sessions":[…]}` (see the
//! `HISTORY_*` bounds). The wire and the shape are a byte for byte from the
//! python keeper (`keeper_script.dart` 4037-4277). The agent is torn down on
//! every path.

use crate::exit;
use crate::routes::{by_id, Route};
use crate::spawn;
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// The list bounds (python `HISTORY_*` / `INIT_TIMEOUT`).
const PAGES: usize = 5;
const MAX: usize = 200;
const REQUEST: Duration = Duration::from_secs(30);
const TITLE: usize = 300;
const INIT: Duration = Duration::from_secs(120);

/// Why `history` failed: the agent is not installed (exit 69), or it ran and
/// failed (exit 70).
#[derive(Debug)]
enum TalkError {
    Missing(String),
    Other(String),
}

impl std::fmt::Display for TalkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TalkError::Missing(m) | TalkError::Other(m) => f.write_str(m),
        }
    }
}

/// `AGENT [CWD]`: the answer on stdout, SIGTERM/SIGINT/SIGHUP end it.
pub fn cmd_history(args: &[String]) -> i32 {
    let signalled = std::sync::Arc::new(AtomicBool::new(false));
    for sig in [
        signal_hook::consts::SIGTERM,
        signal_hook::consts::SIGINT,
        signal_hook::consts::SIGHUP,
    ] {
        let _ = signal_hook::flag::register(sig, std::sync::Arc::clone(&signalled));
    }
    run(args, &mut std::io::stdout(), &signalled)
}

/// [`cmd_history`] to any `out` (the one JSON line), with the reasons it
/// fails on stderr. Setting `cancel` tears the agent down and ends the call.
pub fn run(args: &[String], out: &mut dyn Write, cancel: &AtomicBool) -> i32 {
    run_with(args, out, &mut std::io::stderr(), cancel)
}

/// [`run`] with the reasons it fails (`herdr-mobile: <sentence>` lines)
/// written to `err`.
pub fn run_with(
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
    cancel: &AtomicBool,
) -> i32 {
    let mut say = |what: &dyn std::fmt::Display| {
        let _ = writeln!(err, "herdr-mobile: {what}");
    };
    let Some(agent) = args.first() else {
        say(&"history needs an agent id");
        return exit::USAGE;
    };
    let Some(route) = by_id(agent) else {
        say(&format!("unknown agent: {agent}"));
        return exit::USAGE;
    };
    let cwd = match resolve_cwd(args.get(1).map(String::as_str)) {
        Ok(c) => c,
        Err(msg) => {
            say(&msg);
            return exit::GONE;
        }
    };
    // `Some(cwd)` limits the list to that folder; `None` runs in home and lists
    // every folder.
    let limit = args.get(1).map(|_| cwd.clone());
    match talk(&route, &cwd, limit.as_deref(), cancel) {
        Ok(answer) => {
            let line = serde_json::to_string(&answer).unwrap_or_else(|_| "null".into());
            let _ = writeln!(out, "{line}").and_then(|()| out.flush());
            0
        }
        Err(e) => {
            say(&e);
            match e {
                TalkError::Missing(_) => exit::MISSING,
                TalkError::Other(_) => exit::FAILED,
            }
        }
    }
}

/// The folder the agent runs in, and what the list is limited to. `None` is the
/// home folder (list every folder); a path must exist and be openable.
fn resolve_cwd(cwd: Option<&str>) -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("history needs $HOME")?;
    let Some(cwd) = cwd else {
        return Ok(home);
    };
    let p = expand(cwd);
    if !p.is_dir() {
        return Err(format!(
            "the folder does not exist on this host: {}",
            p.display()
        ));
    }
    let meta = std::fs::metadata(&p).map_err(|_| "cannot read the folder".to_string())?;
    if !meta.is_dir() {
        return Err(format!(
            "the folder does not exist on this host: {}",
            p.display()
        ));
    }
    use std::os::unix::fs::PermissionsExt;
    if meta.permissions().mode() & 0o500 == 0 {
        return Err(format!(
            "the folder cannot be opened on this host: {}",
            p.display()
        ));
    }
    Ok(p)
}

fn expand(s: &str) -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        if s == "~" {
            return PathBuf::from(home);
        }
        if let Some(rest) = s.strip_prefix("~/") {
            return PathBuf::from(home).join(rest);
        }
    }
    let mut p = PathBuf::from(s);
    if p.is_relative() {
        if let Some(home) = std::env::var_os("HOME") {
            p = PathBuf::from(home).join(p);
        }
    }
    p
}

/// The one line `history` prints.
fn talk(
    route: &Route,
    cwd: &Path,
    limit: Option<&Path>,
    cancel: &AtomicBool,
) -> Result<Value, TalkError> {
    let mut child = match spawn::spawn_history_agent(route, cwd) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(TalkError::Missing(format!(
                "could not run {}: {e}",
                route.binary
            )));
        }
        Err(e) => {
            return Err(TalkError::Other(format!(
                "could not run {}: {e}",
                route.binary
            )));
        }
    };
    // `cancel` ends the conversation (the command line sets it on SIGTERM/
    // SIGINT/SIGHUP, `serve` when the stream is reset; the python installs
    // the same handlers and tears the agent down on the way out). Rust `read`
    // swallows EINTR, so a flag cannot interrupt the loop directly: a
    // watchdog thread kills the agent's group when it is set, the agent's
    // stdout then EOFs, the `talk` loop ends, and `tear_down` runs. The
    // watchdog ends with the conversation.
    let agent_pid = child.id() as i32;
    let finished = AtomicBool::new(false);
    std::thread::scope(|scope| {
        scope.spawn(|| watchdog(agent_pid, cancel, &finished));
        let out = converse(route, limit, &mut child);
        finished.store(true, Ordering::SeqCst);
        out
    })
}

/// Kills the agent's group when `cancel` is set, until `finished` is.
fn watchdog(pid: i32, cancel: &AtomicBool, finished: &AtomicBool) {
    while !cancel.load(Ordering::SeqCst) {
        if finished.load(Ordering::SeqCst) {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    spawn::kill_group(pid);
    let end = Instant::now() + Duration::from_secs(2);
    while Instant::now() < end {
        if finished.load(Ordering::SeqCst) {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    spawn::kill_group_hard(pid);
}

/// The conversation with the spawned agent: `initialize`, then `session/list`.
fn converse(route: &Route, limit: Option<&Path>, child: &mut Child) -> Result<Value, TalkError> {
    // `initialize` (the `air` capability is left out, as python does).
    let init_params = json!({
        "protocolVersion": 1,
        "clientCapabilities": {
            "fs": {"readTextFile": false, "writeTextFile": false},
            "terminal": false,
            "elicitation": {"form": {}},
            "session": {"configOptions": {"boolean": {}}},
        },
        "clientInfo": {"name": "herdr-keeper", "title": "herdr keeper", "version": "1"},
    });
    let mut talk = Talk::new(child);
    let mut answer = json!({
        "agent": route.id,
        "list": false,
        "load": false,
        "resume": false,
        "more": false,
        "sessions": [],
    });
    let init = match talk.call("initialize", init_params, INIT) {
        Ok(v) => v,
        Err(e) => {
            tear_down(child);
            return Err(TalkError::Other(format!("{}: {e}", route.id)));
        }
    };
    let caps = init
        .get("agentCapabilities")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let sc = caps
        .get("sessionCapabilities")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let list = sc.get("list").is_some();
    let load = caps.get("loadSession").and_then(Value::as_bool) == Some(true);
    let resume = sc.get("resume").is_some();
    answer["list"] = json!(list);
    answer["load"] = json!(load);
    answer["resume"] = json!(resume);
    if list {
        let mut found: Vec<Value> = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..PAGES {
            let mut params = json!({});
            if let Some(limit) = limit {
                params["cwd"] = json!(limit.to_string_lossy());
            }
            if let Some(c) = &cursor {
                params["cursor"] = json!(c);
            }
            let res = match talk.call("session/list", params, REQUEST) {
                Ok(v) => v,
                Err(e) => {
                    tear_down(child);
                    return Err(TalkError::Other(format!("{}: {e}", route.id)));
                }
            };
            let rows = res
                .get("sessions")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for raw in rows {
                match item(&raw, limit) {
                    Some(it) => {
                        if found.len() >= MAX {
                            answer["more"] = json!(true);
                            break;
                        }
                        found.push(it);
                    }
                    None => continue,
                }
            }
            let nxt = res
                .get("nextCursor")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty());
            cursor = nxt.map(str::to_string);
            if cursor.is_none() || answer["more"].as_bool() == Some(true) {
                break;
            }
        }
        if cursor.is_some() {
            answer["more"] = json!(true);
        }
        // ISO timestamps sort as text: newest first, unknown last, ties keep the
        // agent's order (a stable sort).
        found.sort_by(|a, b| {
            let av = a.get("updatedAt").and_then(Value::as_str).unwrap_or("");
            let bv = b.get("updatedAt").and_then(Value::as_str).unwrap_or("");
            bv.cmp(av)
        });
        answer["sessions"] = Value::Array(found);
    }
    tear_down(child);
    Ok(answer)
}

/// One session of a `session/list` answer cut to what the phone shows, or
/// `None` when it has no id (or no folder the list was limited to).
fn item(raw: &Value, limit: Option<&Path>) -> Option<Value> {
    let o = raw.as_object()?;
    let sid = o.get("sessionId").and_then(Value::as_str)?;
    if sid.is_empty() {
        return None;
    }
    let where_ = match o.get("cwd").and_then(Value::as_str) {
        Some(w) => w.to_string(),
        None => limit?.to_string_lossy().into_owned(),
    };
    let mut out = json!({"sessionId": sid, "cwd": where_});
    if let Some(title) = o.get("title").and_then(Value::as_str) {
        let t = title.trim();
        if !t.is_empty() {
            out["title"] = json!(cut(t, TITLE));
        }
    }
    if let Some(at) = o.get("updatedAt").and_then(Value::as_str) {
        if !at.is_empty() {
            out["updatedAt"] = json!(at);
        }
    }
    let count = o
        .get("_meta")
        .and_then(Value::as_object)
        .and_then(|m| m.get("messageCount"));
    if let Some(n) = count.and_then(Value::as_i64) {
        out["_meta"] = json!({"messageCount": n});
    }
    Some(out)
}

fn cut(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// One agent process for a short conversation: JSON-RPC lines both ways. A
/// reader thread hands each line to the main thread; the main thread asks and
/// waits, with a deadline, dropping notifications and answering the agent's
/// own requests with "not supported".
struct Talk {
    stdin: std::process::ChildStdin,
    rx: mpsc::Receiver<String>,
    seq: i64,
}

impl Talk {
    fn new(child: &mut Child) -> Self {
        let stdin = child.stdin.take().expect("spawn gives a stdin pipe");
        let stdout = child.stdout.take().expect("spawn gives a stdout pipe");
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let reader = std::io::BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(l) => {
                        if tx.send(l).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        Talk { stdin, rx, seq: 0 }
    }

    /// The answer to one request, or `Err` on a failure the person should see.
    fn call(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        self.seq += 1;
        let rid = format!("keeper-history-{}", self.seq);
        let req = json!({"jsonrpc": "2.0", "id": rid, "method": method, "params": params});
        self.stdin
            .write_all(req.to_string().as_bytes())
            .and_then(|_| self.stdin.write_all(b"\n"))
            .map_err(|_| "the agent closed its input".to_string())?;
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or_else(|| format!("the agent did not answer {method} in time"))?;
            let line = match self.rx.recv_timeout(remaining.min(Duration::from_secs(1))) {
                Ok(l) => l,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(format!("the agent exited before it answered {method}"));
                }
            };
            let obj: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(_) => continue,
            };
            // A notification, or a request of the agent's own: answer it so it
            // never waits on us.
            if obj.get("method").is_some() {
                if let Some(id) = obj.get("id") {
                    let err = json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "not supported while listing sessions"}});
                    let _ = self.stdin.write_all(err.to_string().as_bytes());
                    let _ = self.stdin.write_all(b"\n");
                }
                continue;
            }
            if obj.get("id").and_then(Value::as_str) == Some(rid.as_str()) {
                if let Some(err) = obj.get("error") {
                    let msg = err
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("no result");
                    return Err(msg.to_string());
                }
                return Ok(obj.get("result").cloned().unwrap_or(Value::Null));
            }
        }
    }
}

/// End the agent's process group: SIGTERM, 2 s, SIGKILL.
fn tear_down(child: &mut Child) {
    let pid = child.id() as i32;
    spawn::kill_group(pid);
    let end = Instant::now() + Duration::from_secs(2);
    while child.try_wait().ok().flatten().is_none() && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(20));
    }
    if child.try_wait().ok().flatten().is_none() {
        spawn::kill_group_hard(pid);
        let _ = child.wait();
    }
}
