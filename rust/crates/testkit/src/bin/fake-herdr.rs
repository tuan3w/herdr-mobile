//! A deterministic stand-in for herdr's API socket, for transfer_bench.dart and
//! tests of the herdr relay.
//!
//! One JSON request per connection, one JSON line back (like the real socket),
//! except `events.subscribe`, which keeps its connection and gets a
//! `pane_updated` event (shaped like herdr 0.9.3's: the whole pane, ~770 B, with
//! a title spinner and a revision that change every time) for each `bench.emit`
//! count asked for. Serves `ping`, `session.snapshot`, `pane.read`. Payloads have
//! the shape and size of what herdr 0.9.3 sends (snapshot: workspaces, tabs,
//! panes, layouts and agents, ~680 B per pane; pane.read: ANSI rows). Content is
//! seeded, and a pane advances only when it is read, so a sequential client sees
//! the same bytes in every run. The bytes are those of the python program this
//! replaces (`pyrandom` is CPython's generator).
//!
//! usage: fake-herdr SOCKET_PATH   (prints READY when listening)

use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex, MutexGuard};
use testkit::pyrandom::Random;

const WORKSPACES: usize = 8;
const PANES: usize = 40;
const SLIDE: i64 = 3; // rows a pane's output moves between two reads
const FOOTER: i64 = 4; // rows at the bottom that change on every read

const WORDS: &str = "final class return await import const if else struct fn let match Future \
String widget paint herdr agent pane socket transport notify state \
Xin\u{a0}chào tiếng\u{a0}Việt đường\u{a0}dẫn ✓ ● → …";

const SESSION: &str = "/home/user/.omp/agent/sessions/--media-user-data-workspace-project--/\
2026-10-02T23-33-15-235Z_01a0fef6-ff63-7588-ad24-4d9497a89aed.jsonl";

const STATUSES: [&str; 4] = ["idle", "working", "blocked", "done"];
const SPINNER: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// (workspace id, tab id, pane id) of pane `i`.
fn pane_id(i: usize) -> (String, String, String) {
    let w = i % WORKSPACES;
    (
        format!("w{w}"),
        format!("w{w}:t1"),
        format!("w{w}:p{}", i / WORKSPACES + 1),
    )
}

fn agent_of(n: usize) -> Value {
    match n % 4 {
        0 => json!("omp"),
        1 => json!("claude"),
        2 => json!("codex"),
        _ => Value::Null,
    }
}

fn snapshot(seq: usize) -> Value {
    let mut panes = Vec::new();
    let mut agents = Vec::new();
    for n in 0..PANES {
        let (w, t, p) = pane_id(n);
        let bump = if n % 7 == seq % 7 { seq } else { 0 };
        let status = STATUSES[(n + bump) % 4];
        let title = format!(
            "π > Task {n} {}",
            if n % 5 == 0 {
                "Ý tưởng mới"
            } else {
                "refactor the thing"
            }
        );
        let cwd = format!("/media/user/data/workspace/project{}", n % WORKSPACES);
        let agent_session =
            json!({"source": "herdr:omp", "agent": "omp", "kind": "path", "value": SESSION});
        let terminal_id = format!("term_{:014x}", n * 7919);
        let pane = json!({
            "pane_id": p,
            "terminal_id": terminal_id,
            "workspace_id": w,
            "tab_id": t,
            "focused": n == 3,
            "cwd": cwd,
            "foreground_cwd": cwd,
            "agent": agent_of(n),
            "terminal_title": title,
            "terminal_title_stripped": title,
            "agent_status": status,
            "agent_session": agent_session,
            "scroll": {"offset_from_bottom": 0, "max_offset_from_bottom": 95, "viewport_rows": 28},
            "revision": 4 + seq / 3,
        });
        if let Some(agent) = pane["agent"].as_str() {
            agents.push(json!({
                "terminal_id": terminal_id,
                "agent": agent,
                "terminal_title": title,
                "terminal_title_stripped": title,
                "agent_status": status,
                "screen_detection_skipped": true,
                "agent_session": agent_session,
                "workspace_id": w,
                "tab_id": t,
                "pane_id": p,
                "focused": n == 3,
                "state_change_seq": 7 + seq,
                "cwd": cwd,
                "foreground_cwd": cwd,
                "revision": 4 + seq / 3,
            }));
        }
        panes.push(pane);
    }
    let labels = ["research", "herdr-mobile", "Dự án", "infra"];
    let workspaces: Vec<Value> = (0..WORKSPACES)
        .map(|w| {
            json!({
                "workspace_id": format!("w{w}"), "number": w + 1, "label": labels[w % 4],
                "focused": w == 0, "pane_count": PANES / WORKSPACES, "tab_count": 1,
                "active_tab_id": format!("w{w}:t1"), "agent_status": "working",
            })
        })
        .collect();
    let tabs: Vec<Value> = (0..WORKSPACES)
        .map(|w| {
            json!({
                "tab_id": format!("w{w}:t1"), "workspace_id": format!("w{w}"), "number": 1, "label": "1",
                "focused": w == 0, "pane_count": PANES / WORKSPACES, "agent_status": "working",
            })
        })
        .collect();
    let layouts: Vec<Value> = (0..WORKSPACES)
        .map(|w| {
            let ids: Vec<String> = (0..PANES)
                .map(pane_id)
                .filter(|(ww, _, _)| *ww == format!("w{w}"))
                .map(|(_, _, p)| p)
                .collect();
            let layout_panes: Vec<Value> = ids
                .iter()
                .enumerate()
                .map(|(k, i)| {
                    json!({"pane_id": i, "focused": k == 0,
                           "rect": {"x": 46 * (k % 2), "y": 20 * (k / 2), "width": 46, "height": 20}})
                })
                .collect();
            let splits: Vec<Value> = (0..ids.len().saturating_sub(1))
                .map(|k| {
                    json!({"id": format!("split_{k}_root"), "direction": "right", "ratio": 0.3857143,
                           "rect": {"x": 0, "y": 0, "width": 120, "height": 40}})
                })
                .collect();
            json!({
                "workspace_id": format!("w{w}"), "tab_id": format!("w{w}:t1"), "zoomed": false,
                "area": {"x": 0, "y": 0, "width": 120, "height": 40},
                "focused_pane_id": ids[0],
                "panes": layout_panes,
                "splits": splits,
            })
        })
        .collect();
    json!({
        "version": "0.9.3", "protocol": 22,
        "focused_workspace_id": "w0", "focused_tab_id": "w0:t1", "focused_pane_id": "w0:p1",
        "workspaces": workspaces, "tabs": tabs, "panes": panes,
        "layouts": layouts, "agents": agents,
    })
}

fn body_row(pane: u64, absolute: i64) -> String {
    // python seeds with `pane * 1000003 + absolute` (always positive here)
    let mut r = Random::new(pane * 1_000_003 + absolute.unsigned_abs());
    let mut b: Vec<String> = vec![format!("\x1b[2m{absolute:>5} \x1b[0m")];
    let mut cells = 6usize;
    if r.randrange(6) == 0 {
        b.insert(0, "\x1b[48;2;20;60;30m".to_string());
    }
    if absolute.rem_euclid(11) < 3 {
        return format!("\x1b[38;5;244m┌{}┐\x1b[0m", "─".repeat(94));
    }
    let words: Vec<&str> = WORDS.split_whitespace().collect();
    while cells < 100 {
        let w = words[r.randrange(words.len() as u32) as usize];
        if r.random() < 0.9 {
            let (red, green, blue) = (r.randrange(256), r.randrange(256), r.randrange(256));
            b.push(format!("\x1b[38;2;{red};{green};{blue}m"));
        }
        b.push(format!("{w} "));
        cells += w.chars().count() + 1;
        if r.random() < 0.6 {
            b.push("\x1b[0m".to_string());
        }
    }
    b.concat()
}

fn footer_rows(step: i64) -> Vec<String> {
    vec![
        format!(
            "\x1b[38;5;75m{}\x1b[0m working ({step}s)",
            SPINNER[step.rem_euclid(10) as usize]
        ),
        format!("\x1b[2m{}\x1b[0m", "─".repeat(100)),
        "> ".to_string(),
        format!(
            "\x1b[2mtokens {}  ctx {}%\x1b[0m",
            step * 37,
            step.rem_euclid(100)
        ),
    ]
}

/// Removes `\x1b[` + parameter bytes `0-?` + intermediate bytes ` -/` + a final byte `@-~`.
fn strip_ansi(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == 0x1b && b.get(i + 1) == Some(&b'[') {
            let mut j = i + 2;
            while j < b.len() && (0x30..=0x3f).contains(&b[j]) {
                j += 1;
            }
            while j < b.len() && (0x20..=0x2f).contains(&b[j]) {
                j += 1;
            }
            if j < b.len() && (0x40..=0x7e).contains(&b[j]) {
                i = j + 1;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// python's `int(x)` of a JSON value.
fn py_int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.trim().parse().ok(),
        Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

/// python truthiness of a JSON value.
fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64() != Some(0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// python's `%s` of a JSON value.
fn py_str(v: &Value) -> String {
    match v {
        Value::Null => "None".to_string(),
        Value::Bool(true) => "True".to_string(),
        Value::Bool(false) => "False".to_string(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

struct State {
    reads: Mutex<HashMap<String, i64>>,
    snapshots: Mutex<usize>,
    subs: Mutex<Vec<Arc<UnixStream>>>,
    emitted: Mutex<usize>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// `Ok(result)` or `Err(error)`, the part of a response after its id.
type Reply = Result<Value, Value>;

fn pane_read(state: &State, params: &Value) -> Reply {
    let pid_value = params.get("pane_id").cloned().unwrap_or(Value::Null);
    let index = pid_value
        .as_str()
        .and_then(|p| (0..PANES).find(|&i| pane_id(i).2 == p));
    let (Some(index), Some(pid)) = (index, pid_value.as_str()) else {
        return Err(
            json!({"code": "pane_not_found", "message": format!("pane {} not found", py_str(&pid_value))}),
        );
    };
    let step = {
        let mut reads = lock(&state.reads);
        let slot = reads.entry(pid.to_string()).or_insert(0);
        let step = *slot;
        *slot += 1;
        step
    };
    let asked = params
        .get("lines")
        .filter(|v| truthy(v))
        .and_then(py_int)
        .unwrap_or(1000);
    let lines = asked.min(1000);
    let newest = 1000 + step * SLIDE;
    let mut rows: Vec<String> = (newest - lines + FOOTER..newest)
        .map(|a| body_row(index as u64, a))
        .collect();
    rows.extend(footer_rows(step));
    // rows[-lines:]
    let start = if lines > 0 {
        rows.len().saturating_sub(lines as usize)
    } else {
        usize::try_from(-lines).unwrap_or(0).min(rows.len())
    };
    let mut rows = rows.split_off(start);
    let plain = params.get("strip_ansi").is_none_or(truthy);
    if plain {
        rows = rows.iter().map(|r| strip_ansi(r)).collect();
    }
    let workspace = pid.split(':').next().unwrap_or(pid);
    let mut text = rows.join("\r\n");
    text.push_str("\r\n");
    Ok(json!({"type": "pane_read", "read": {
        "pane_id": pid, "workspace_id": workspace, "tab_id": format!("{workspace}:t1"),
        "source": params.get("source").cloned().unwrap_or_else(|| json!("recent")),
        "format": if plain { "plain" } else { "ansi" },
        "text": text, "truncated": false,
    }}))
}

fn pane_event(n: usize) -> Value {
    let index = n % PANES;
    let (w, t, p) = pane_id(index);
    let title = format!("π {} Task {index} refactor the thing", SPINNER[n % 10]);
    let cwd = format!("/media/user/data/workspace/project{}", index % WORKSPACES);
    json!({
        "data": {
            "pane": {
                "agent": agent_of(index),
                "agent_session": {"agent": "omp", "kind": "path", "source": "herdr:omp", "value": SESSION},
                "agent_status": "working",
                "cwd": cwd,
                "focused": index == 3,
                "foreground_cwd": cwd,
                "pane_id": p,
                "revision": 118_000 + n,
                "scroll": {"max_offset_from_bottom": 4758, "offset_from_bottom": 0, "viewport_rows": 57},
                "tab_id": t,
                "terminal_id": format!("term_{:014x}", index * 7919),
                "terminal_title": title,
                "terminal_title_stripped": title,
                "workspace_id": w,
            },
            "type": "pane_updated",
        },
        "event": "pane_updated",
    })
}

fn emit(state: &State, count: usize) {
    let subs: Vec<Arc<UnixStream>> = lock(&state.subs).clone();
    let first = {
        let mut emitted = lock(&state.emitted);
        let first = *emitted;
        *emitted += count;
        first
    };
    for n in first..first + count {
        let mut line = pane_event(n).to_string().into_bytes();
        line.push(b'\n');
        for c in &subs {
            let _ = (&**c).write_all(&line);
        }
    }
}

fn handle(state: &State, mut conn: UnixStream) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 65536];
    while !buf.contains(&b'\n') {
        match conn.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    let Ok(Value::Object(req)) = serde_json::from_slice::<Value>(&buf) else {
        return;
    };
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    let method = req.get("method").cloned().unwrap_or(Value::Null);
    let params = match req.get("params") {
        Some(p) if truthy(p) => p.clone(),
        _ => json!({}),
    };
    let method_name = method.as_str().unwrap_or("");
    if method_name == "events.subscribe" {
        let ack = format!("{{\"id\":{id},\"result\":{{\"type\":\"subscription_started\"}}}}\n");
        let conn = Arc::new(conn);
        if (&*conn).write_all(ack.as_bytes()).is_ok() {
            lock(&state.subs).push(conn); // stays open; the connection is closed when the client goes
        }
        return;
    }
    let reply: Reply = match method_name {
        "bench.emit" => {
            let count = params.get("count").map_or(Some(1), py_int).unwrap_or(1);
            emit(state, usize::try_from(count).unwrap_or(0));
            Ok(json!({"type": "ok"}))
        }
        "ping" => Ok(json!({"type": "pong", "version": "0.9.3", "protocol": 22})),
        "session.snapshot" => {
            let seq = {
                let mut n = lock(&state.snapshots);
                *n += 1;
                *n
            };
            Ok(json!({"type": "session_snapshot", "snapshot": snapshot(seq)}))
        }
        "pane.read" => pane_read(state, &params),
        _ => Err(
            json!({"code": "invalid_request", "message": format!("unknown variant `{}`", py_str(&method))}),
        ),
    };
    // herdr writes the id first
    let mut out = Map::new();
    out.insert("id".to_string(), id);
    match reply {
        Ok(result) => out.insert("result".to_string(), result),
        Err(error) => out.insert("error".to_string(), error),
    };
    let mut line = Value::Object(out).to_string().into_bytes();
    line.push(b'\n');
    let _ = conn.write_all(&line);
}

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: fake-herdr SOCKET_PATH");
        std::process::exit(1);
    };
    let _ = std::fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("fake-herdr: cannot bind {path}: {e}");
            std::process::exit(1);
        }
    };
    {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "READY");
        let _ = out.flush();
    }
    let state = Arc::new(State {
        reads: Mutex::new(HashMap::new()),
        snapshots: Mutex::new(0),
        subs: Mutex::new(Vec::new()),
        emitted: Mutex::new(0),
    });
    for conn in listener.incoming().flatten() {
        let state = Arc::clone(&state);
        std::thread::spawn(move || handle(&state, conn));
    }
}
