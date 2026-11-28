//! A scripted ACP agent for the keeper tests.
//!
//! Speaks JSON-RPC lines on stdio like the real adapters: `initialize`,
//! `session/new`, `session/prompt` (behaviour chosen by the prompt text),
//! `session/cancel`, and `session/load`, which it refuses ("unsupported while
//! live"). Exits on EOF like claude-agent-acp, codex-acp and pi-acp.
//!
//! Every message it receives is appended to the file in $FAKE_ACP_LOG as one JSON
//! line `{"recv": {...}}`, so a test can count what reached the agent.
//!
//! Prompt texts:
//!   plain         two message chunks, end_turn
//!   ask           title, a chunk, a permission (id 7001), then a question (id
//!                 "elic-1"), then a chunk saying what was answered, end_turn
//!   perm:<title>  one permission whose tool title is <title>, then end_turn
//!   slow          a chunk, then waits for session/cancel and ends `cancelled`
//!   noise         garbage lines on stdout, then a chunk, end_turn
//!   die           a permission request, then exits with code 3 (stderr: boom)
//!   sleep:<s>     a chunk, then ends the turn after <s> seconds
//!   exit:<n>      exits with code <n> at once
//!   long:<n>      <n> chunks with distinct message ids, end_turn
//!   heavy:<tools>:<min KB>:<max KB>:<label>
//!                 a thought, <tools> tool calls with <min>..<max> KB outputs (start,
//!                 progress, finish; a big rawInput each; every fifth an edit with a
//!                 diff), then `answer <label>`, end_turn. `heavyhold:` is the same
//!                 without the answer: the turn stays open until session/cancel.
//!   big:<n>       a tool call update, then a chunk, each with <n> bytes of output, end_turn
//!   picture:<n>   an image chunk of <n> base64 characters, then a chunk, end_turn
//!   reply:<text>  one chunk "re: <text>" with its own message id, end_turn
//!   len:<text>    one chunk `len=<number of characters of <text>>`, end_turn (a prompt of any size
//!                 is read whole and counted; not in the python original)
//!   quiet         says nothing and waits for session/cancel, which ends the turn `cancelled`
//!   task:<id>     an `async_task_spawned` (shell, canStop) for <id>, a chunk, end_turn
//!   sdktask:<id>  Claude's raw `_claude/sdkMessage` `background_tasks_changed` naming <id>
//!                 (a `local_bash`), a chunk, end_turn
//!   sdkend:<id>   `background_tasks_changed` with no tasks, end_turn
//!   cursor-ask    `cursor/ask_question` (q1 single choice red/blue, q2 multiple fig/plum/pear),
//!                 then a chunk `got:<the answer, JSON>`, end_turn. `cursor-ask-empty`: no question.
//!   cursor-plan   `cursor/create_plan`, then a chunk `got:<the answer, JSON>`, end_turn
//!   cursor-todos  `cursor/update_todos` (merge false, then merge true), a chunk, end_turn
//!   cursor-plan-todos  `cursor/create_plan` with two todos, then `cursor/update_todos` (merge true) completing
//!                 the first, then a chunk `got:<the answer, JSON>`, end_turn
//!   cursor-task   a `Task: Explore codebase` tool call (pending, then completed), then Cursor's
//!                 `cursor/task` notification for it (custom subagent type), a chunk, end_turn
//!                 `cursor-task-bad`: the notification names no tool call (toolCallId is a number)
//! `_session/async_task/stop {asyncTaskId}` answers {stopped: true} and sends an
//! `async_task_state_update` `stopped` for a task spawned with `task:`, else {stopped: false}.
//! Busy guard (omp's `AgentBusyError`, `-32003 sessionBusy`): while the file named
//! by $FAKE_ACP_BUSY_FILE exists, the agent is busy with an autonomous turn of its
//! own: a prompt gets one chunk of that turn's output and then the error, and is
//! not taken (nothing of it is "said" afterwards). A file that says "quiet" makes
//! the agent refuse without that chunk.
//! Environment: FAKE_ACP_AUTH=<method id> advertises that auth method and refuses `session/new`
//! ("Authentication required") until `authenticate` was called; FAKE_ACP_AUTH_FAIL=1 makes
//! `authenticate` Cursor's browser failure (-32602, the reason and a link in data.message),
//! FAKE_ACP_AUTH_UNKNOWN=1 answers it -32601, FAKE_ACP_AUTH_EXIT=1 exits with code 4 on it.
//! FAKE_ACP_IGNORE_TERM=1 ignores SIGTERM; FAKE_ACP_FAIL_INIT=1
//! exits with code 5 before answering initialize; FAKE_ACP_INIT_DELAY=<s> waits
//! that long before answering initialize (a cold `npx -y`); FAKE_ACP_PID_FILE=<file>
//! gets a line `<pid>\t<cwd>` appended when it answers initialize.
//! What a keeper test may ask the agent to report when it answers initialize (each a file to write):
//! FAKE_ACP_FDS_FILE=<file> gets the JSON array of the agent's open file descriptors, sorted;
//! FAKE_ACP_UMASK_FILE=<file> is created empty (its mode shows the umask the agent runs under);
//! FAKE_ACP_ENV_FILE=<file> gets a JSON object of the variables named by FAKE_ACP_ENV_KEYS
//! (comma separated; null for an unset one). FAKE_ACP_TITLE_ON_NEW=1 sends a
//! `session_info_update` titled "Fake title" right after `session/new` is answered.
//! The prompt `gate` waits until the file named by FAKE_ACP_GATE exists, then ends the turn.
//! The agent's own store (what survives the process, like omp's session folder):
//! FAKE_ACP_STORE=<json file> {"sessions": [{sessionId, cwd, title?, updatedAt?,
//! messageCount?, updates: [session/update payloads]}]}. With it set, initialize
//! advertises loadSession, sessionCapabilities.list and .resume (FAKE_ACP_CAPS=
//! list,load,resume narrows it to the listed ones), `session/list` answers from
//! the file (`cwd` filter, FAKE_ACP_PAGE sessions per page with a `nextCursor`;
//! FAKE_ACP_LIST_FAIL=1 answers an error, FAKE_ACP_LIST_DELAY=<s> waits first,
//! FAKE_ACP_LIST_NOISE=1 first sends a garbage line, a notification and a request
//! (`elicitation/create`, id noise-1) and waits for its answer), `session/load` of a stored id replays
//! its updates and answers `{}`, and `session/new` records the session (id: the
//! first free `sess-N`) with every update it sends, so a NEW agent process can
//! load it later. Without FAKE_ACP_STORE the agent is as before (no list/load).
//!
//! Output is byte-compatible with the python program this replaces: the same
//! messages in the same key order, written with python's `json.dumps` spelling.

use serde_json::{json, Map, Value};
use std::collections::{HashSet, VecDeque};
use std::io::{self, BufRead, Write};
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use testkit::pyjson::{dumps, DEFAULT, SORTED};

/// An environment variable as python's `os.environ.get(k)` read in a boolean
/// or `or default` context: unset and empty are the same.
fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

/// What python would die with: its traceback goes to stderr, the exit code is 1.
fn crash(message: &str) -> ! {
    eprintln!("fake-acp-agent: {message}");
    std::process::exit(1);
}

fn py_int(text: &str) -> i64 {
    text.trim()
        .replace('_', "")
        .parse()
        .unwrap_or_else(|_| crash(&format!("invalid literal for int(): {text:?}")))
}

fn py_float(text: &str) -> f64 {
    text.trim()
        .parse()
        .unwrap_or_else(|_| crash(&format!("could not convert string to float: {text:?}")))
}

fn sleep_secs(secs: f64) {
    if secs > 0.0 {
        std::thread::sleep(Duration::from_secs_f64(secs));
    }
}

/// python's `%s` of a JSON value (None for a missing one).
fn py_str(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => "None".to_string(),
        Some(Value::Bool(true)) => "True".to_string(),
        Some(Value::Bool(false)) => "False".to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

/// python's `x % y` for ints.
fn py_mod(x: i64, y: i64) -> i64 {
    if y == 0 {
        crash("integer division or modulo by zero");
    }
    ((x % y) + y) % y
}

/// `time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())`.
fn now_iso() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // civil-from-days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

fn text_chunk(text: &str) -> Value {
    json!({"type": "text", "text": text})
}

struct Agent {
    input: io::StdinLock<'static>,
    out: io::Stdout,
    backlog: VecDeque<Value>,
    cancelled: bool,
    replies: u32,
    spawned: HashSet<String>,
    log: Option<String>,
    store: Option<String>,
    page: usize,
}

impl Agent {
    fn new() -> Self {
        Agent {
            input: io::stdin().lock(),
            out: io::stdout(),
            backlog: VecDeque::new(),
            cancelled: false,
            replies: 0,
            spawned: HashSet::new(),
            log: env("FAKE_ACP_LOG"),
            store: env("FAKE_ACP_STORE"),
            page: env("FAKE_ACP_PAGE").map_or(50, |p| py_int(&p).max(0) as usize),
        }
    }

    fn note(&self, obj: &Value) {
        let Some(log) = &self.log else { return };
        let line = format!("{}\n", dumps(obj, DEFAULT));
        let appended = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .and_then(|mut f| f.write_all(line.as_bytes()));
        if let Err(e) = appended {
            crash(&format!("{log}: {e}"));
        }
    }

    // ---- the agent's own store ----

    fn store_read(&self) -> Value {
        let mut data = self
            .store
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}));
        if !data.get("sessions").is_some_and(Value::is_array) {
            data["sessions"] = json!([]);
        }
        data
    }

    fn store_write(&self, data: &Value) {
        let Some(store) = &self.store else { return };
        let tmp = format!("{store}.tmp{}", std::process::id());
        let written =
            std::fs::write(&tmp, dumps(data, DEFAULT)).and_then(|()| std::fs::rename(&tmp, store));
        if let Err(e) = written {
            crash(&format!("{store}: {e}"));
        }
    }

    fn new_session_id(&self, counter: u32, cwd: Option<&str>) -> String {
        if self.store.is_none() {
            return format!("sess-{counter}");
        }
        let mut data = self.store_read();
        let mut n = 1;
        while find_session(&data, &format!("sess-{n}")).is_some() {
            n += 1;
        }
        let sid = format!("sess-{n}");
        let cwd = cwd.filter(|c| !c.is_empty()).map_or_else(
            || std::env::current_dir().map_or_else(|_| String::new(), |p| p.display().to_string()),
            str::to_string,
        );
        if let Some(sessions) = data["sessions"].as_array_mut() {
            sessions.push(json!({
                "sessionId": sid, "cwd": cwd, "updatedAt": now_iso(),
                "messageCount": 0, "updates": [], "own": true,
            }));
        }
        self.store_write(&data);
        sid
    }

    fn store_record(&self, sid: &str, upd: &Value) {
        if self.store.is_none() {
            return;
        }
        let mut data = self.store_read();
        let Some(sessions) = data["sessions"].as_array_mut() else {
            return;
        };
        let Some(s) = sessions.iter_mut().find(|s| s["sessionId"] == sid) else {
            return;
        };
        if !s.get("own").is_some_and(truthy) {
            return;
        }
        let Some(obj) = s.as_object_mut() else { return };
        let updates = obj.entry("updates").or_insert_with(|| json!([]));
        if let Some(list) = updates.as_array_mut() {
            list.push(upd.clone());
        }
        let count = updates.as_array().map_or(0, |list| {
            list.iter()
                .filter(|u| {
                    matches!(
                        u.get("sessionUpdate").and_then(Value::as_str),
                        Some("user_message_chunk" | "agent_message_chunk")
                    )
                })
                .count()
        });
        obj.insert("updatedAt".to_string(), json!(now_iso()));
        obj.insert("messageCount".to_string(), json!(count));
        self.store_write(&data);
    }

    fn capabilities(&self) -> Value {
        let mut caps = json!({"loadSession": false, "promptCapabilities": {"image": true}});
        if self.store.is_some() {
            let wanted = env("FAKE_ACP_CAPS").unwrap_or_else(|| "list,load,resume".to_string());
            let wanted: Vec<&str> = wanted.split(',').collect();
            caps["loadSession"] = json!(wanted.contains(&"load"));
            let mut sc = Map::new();
            if wanted.contains(&"list") {
                sc.insert("list".to_string(), json!({}));
            }
            if wanted.contains(&"resume") {
                sc.insert("resume".to_string(), json!({}));
            }
            if !sc.is_empty() {
                caps["sessionCapabilities"] = Value::Object(sc);
            }
        }
        caps
    }

    // ---- wire ----

    fn write_raw(&mut self, bytes: &[u8]) {
        let mut out = self.out.lock();
        if out.write_all(bytes).and_then(|()| out.flush()).is_err() {
            std::process::exit(1);
        }
    }

    fn send(&mut self, obj: &Value) {
        let line = format!("{}\n", dumps(obj, DEFAULT));
        self.write_raw(line.as_bytes());
    }

    fn reply(&mut self, id: &Value, result: Value) {
        self.send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
    }

    fn error(&mut self, id: &Value, code: i64, message: &str) {
        self.send(
            &json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}),
        );
    }

    fn stderr(&self, text: &str) {
        let mut err = io::stderr().lock();
        let _ = err.write_all(text.as_bytes());
        let _ = err.flush();
    }

    /// The next message from the client: held-back ones first; `None` at EOF.
    fn read(&mut self) -> Option<Value> {
        if let Some(msg) = self.backlog.pop_front() {
            return Some(msg);
        }
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match self.input.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => return None,
                Ok(_) => {}
            }
            let text = String::from_utf8_lossy(&buf);
            let line = text.trim();
            if line.is_empty() {
                continue;
            }
            let Ok(msg) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            if !msg.is_object() {
                continue;
            }
            self.note(&json!({"recv": msg}));
            if msg.get("method").and_then(Value::as_str) == Some("session/cancel") {
                self.cancelled = true;
            }
            return Some(msg);
        }
    }

    /// Reads until the answer to our request `rid`; other requests wait.
    fn wait_response(&mut self, rid: &Value) -> Value {
        let mut skipped = Vec::new();
        let found = loop {
            let Some(msg) = self.read() else {
                std::process::exit(0)
            };
            if msg.get("method").is_none() && msg.get("id") == Some(rid) {
                break msg;
            }
            if msg.get("method").and_then(Value::as_str) != Some("session/cancel") {
                skipped.push(msg);
            }
        };
        for msg in skipped.into_iter().rev() {
            self.backlog.push_front(msg);
        }
        found
    }

    fn update(&mut self, sid: &str, upd: Value) {
        self.store_record(sid, &upd);
        self.send(&json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}}));
    }

    fn sdk_level(&mut self, sid: &str, tasks: Value) {
        self.send(&json!({"jsonrpc": "2.0", "method": "_claude/sdkMessage", "params": {"sessionId": sid, "message": {
            "type": "system", "subtype": "background_tasks_changed", "tasks": tasks, "uuid": "u", "session_id": sid}}}));
    }

    fn chunk(&mut self, sid: &str, text: &str, mid: Option<&str>) {
        let mut u = json!({"sessionUpdate": "agent_message_chunk", "content": text_chunk(text)});
        if let Some(mid) = mid {
            u["messageId"] = json!(mid);
        }
        self.update(sid, u);
    }

    fn permission(&mut self, sid: &str, rid: i64, title: &str) -> Value {
        self.send(&json!({
            "jsonrpc": "2.0", "id": rid, "method": "session/request_permission",
            "params": {
                "sessionId": sid,
                "toolCall": {"toolCallId": format!("tc-{rid}"), "title": title, "kind": "execute", "status": "pending"},
                "options": [
                    {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                ],
            },
        }));
        self.wait_response(&json!(rid))
    }

    /// A blocking `cursor/*` request; returns the client's answer.
    fn cursor_call(&mut self, sid: &str, rid: &str, method: &str, params: Value) -> Value {
        let mut params = params;
        params["sessionId"] = json!(sid);
        self.send(&json!({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}));
        self.wait_response(&json!(rid))
    }

    /// Sends `got:<the answer, JSON>` the way python's `json.dumps(sort_keys=True)` spells it.
    fn got(&mut self, sid: &str, answer: &Value, mid: &str) {
        let text = format!(
            "got:{}",
            dumps(answer.get("result").unwrap_or(&Value::Null), SORTED)
        );
        self.chunk(sid, &text, Some(mid));
    }

    fn hold_until_cancel(&mut self) {
        let mut later = Vec::new();
        while !self.cancelled {
            let Some(m) = self.read() else {
                std::process::exit(0)
            };
            if m.get("method").and_then(Value::as_str) != Some("session/cancel") {
                later.push(m);
            }
        }
        for msg in later.into_iter().rev() {
            self.backlog.push_front(msg);
        }
    }

    // ---- session/list, session/load ----

    fn list_sessions(&mut self, rid: &Value, params: &Value) {
        sleep_secs(env("FAKE_ACP_LIST_DELAY").map_or(0.0, |d| py_float(&d)));
        if env("FAKE_ACP_LIST_NOISE").is_some() {
            self.write_raw(b"this is not json\n");
            self.send(&json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "x", "update": {"sessionUpdate": "current_mode_update"}}}));
            self.send(&json!({"jsonrpc": "2.0", "id": "noise-1", "method": "elicitation/create", "params": {"mode": "form", "message": "?"}}));
            self.wait_response(&json!("noise-1"));
        }
        if env("FAKE_ACP_LIST_FAIL").is_some() {
            self.error(rid, -32000, "store unreadable");
            return;
        }
        let mut rows: Vec<Value> = if self.store.is_some() {
            self.store_read()["sessions"]
                .as_array()
                .cloned()
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        if let Some(cwd) = params.get("cwd").filter(|c| !c.is_null()) {
            rows.retain(|s| s.get("cwd").unwrap_or(&Value::Null) == cwd);
        }
        let start = match params.get("cursor") {
            Some(Value::String(s)) if !s.is_empty() => s.trim().parse::<i64>().unwrap_or(0),
            Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
            _ => 0,
        };
        let page = self.page as i64;
        let len = rows.len() as i64;
        // rows[start:start + PAGE] with python's slice rules
        let clamp = |i: i64| (if i < 0 { (i + len).max(0) } else { i.min(len) }) as usize;
        let (lo, hi) = (clamp(start), clamp(start + page));
        let mut out = Vec::new();
        for s in rows.get(lo..hi.max(lo)).unwrap_or_default() {
            let mut row = Map::new();
            row.insert(
                "sessionId".to_string(),
                s.get("sessionId").cloned().unwrap_or(Value::Null),
            );
            row.insert(
                "cwd".to_string(),
                s.get("cwd").cloned().unwrap_or(Value::Null),
            );
            for k in ["title", "updatedAt"] {
                if let Some(v) = s.get(k).filter(|v| !v.is_null()) {
                    row.insert(k.to_string(), v.clone());
                }
            }
            if let Some(count) = s.get("messageCount").filter(|v| !v.is_null()) {
                row.insert(
                    "_meta".to_string(),
                    json!({"messageCount": count, "size": 1}),
                );
            }
            out.push(Value::Object(row));
        }
        let mut result = json!({"sessions": out});
        if start + page < len {
            result["nextCursor"] = json!((start + page).to_string());
        }
        self.reply(rid, result);
    }

    fn load_session(&mut self, rid: &Value, params: &Value) {
        let found = if self.store.is_some() {
            let sid = params.get("sessionId").cloned().unwrap_or(Value::Null);
            self.store_read()["sessions"].as_array().and_then(|all| {
                all.iter()
                    .find(|s| s.get("sessionId") == Some(&sid))
                    .cloned()
            })
        } else {
            None
        };
        let Some(s) = found else {
            self.error(
                rid,
                -32000,
                "session/load is unsupported for a live session",
            );
            return;
        };
        for upd in s
            .get("updates")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            self.send(&json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": s["sessionId"], "update": upd}}));
        }
        self.reply(rid, json!({}));
    }

    // ---- prompts ----

    /// heavy:<tools>:<min KB>:<max KB>:<label>: a thought, <tools> tool calls
    /// (start, progress, finish with 'output of min..max KB', half of them in
    /// `rawOutput`, half in `content`, each with a big `rawInput`, an edit now and
    /// then with a diff), then the answer `answer <label>`. `heavyhold:` is the
    /// same without the answer: the turn stays open until session/cancel.
    fn heavy(&mut self, sid: &str, text: &str) {
        let parts: Vec<&str> = text.split(':').collect();
        let &[_, tools, lo, hi, label] = parts.as_slice() else {
            crash("heavy: expected heavy:<tools>:<min KB>:<max KB>:<label>");
        };
        let (tools, lo, hi) = (py_int(tools), py_int(lo), py_int(hi));
        self.update(
            sid,
            json!({
                "sessionUpdate": "agent_thought_chunk", "messageId": format!("think-{label}"),
                "content": text_chunk(&format!("thinking about turn {label}")),
            }),
        );
        for i in 0..tools {
            let tid = format!("t{label}-{i}");
            let size = ((lo + py_mod(i * 7919, hi - lo + 1)) * 1024) as usize;
            let output = format!("output of {tid}: {}", "x".repeat(size));
            let edit = i % 5 == 4;
            self.update(sid, json!({
                "sessionUpdate": "tool_call", "toolCallId": tid, "title": format!("Run: step {i} of turn {label}"),
                "kind": if edit { "edit" } else { "execute" }, "status": "pending",
                "rawInput": {"command": format!("step {i}"), "script": "s".repeat(3000)},
                "locations": [{"path": format!("/work/f{i}.txt"), "line": 1}],
            }));
            self.update(sid, json!({"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "in_progress"}));
            let mut done = json!({"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed"});
            if i % 2 != 0 {
                done["rawOutput"] = json!(output);
            } else {
                done["content"] = json!([{"type": "content", "content": text_chunk(&output)}]);
            }
            if edit {
                let mut content = done
                    .get("content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                content.push(json!({"type": "diff", "path": format!("/work/f{i}.txt"), "oldText": "a\n".repeat(500), "newText": "b\n".repeat(500)}));
                done["content"] = Value::Array(content);
            }
            self.update(sid, done);
        }
        if text.starts_with("heavy:") {
            self.chunk(
                sid,
                &format!("answer {label}"),
                Some(&format!("answer-{label}")),
            );
        }
    }

    fn prompt(&mut self, msg: &Value) {
        let id = msg["id"].clone();
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let sid = params
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let sid = sid.as_str();
        if let Some(busy) = env("FAKE_ACP_BUSY_FILE").filter(|b| Path::new(b).exists()) {
            let said = std::fs::read_to_string(&busy).unwrap_or_default();
            if said.trim() != "quiet" {
                self.chunk(sid, "subagent progress", Some("own-turn"));
            }
            self.error(&id, -32003, "Session is busy");
            return;
        }
        let text = params
            .get("prompt")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .map_or("", |b| b.get("text").and_then(Value::as_str).unwrap_or(""))
            .to_string();
        let text = text.as_str();
        self.store_record(
            sid,
            &json!({"sessionUpdate": "user_message_chunk", "content": text_chunk(text)}),
        );
        let mut stop = "end_turn";
        if text == "plain" {
            self.chunk(sid, "Hel", None);
            self.chunk(sid, "lo", None);
        } else if text == "ask" {
            self.update(
                sid,
                json!({"sessionUpdate": "session_info_update", "title": "Fake title"}),
            );
            self.chunk(sid, "thinking", None);
            let p = self.permission(sid, 7001, "Run: ls -la");
            self.update(sid, json!({"sessionUpdate": "tool_call_update", "toolCallId": "tc-7001", "status": "completed"}));
            self.send(&json!({
                "jsonrpc": "2.0", "id": "elic-1", "method": "elicitation/create",
                "params": {
                    "sessionId": sid, "mode": "form", "message": "Pick one?\nsecond line",
                    "requestedSchema": {"type": "object", "properties": {"value": {"type": "string", "enum": ["a", "b"]}}},
                },
            }));
            let e = self.wait_response(&json!("elic-1"));
            let option = p
                .get("result")
                .filter(|r| truthy(r))
                .and_then(|r| r.get("outcome"))
                .and_then(|o| o.get("optionId"));
            let action = e
                .get("result")
                .filter(|r| truthy(r))
                .and_then(|r| r.get("action"));
            let said = format!("answered:{}/{}", py_str(option), py_str(action));
            self.chunk(sid, &said, None);
        } else if let Some(title) = text.strip_prefix("perm:") {
            self.permission(sid, 7002, title);
        } else if text == "gate" {
            // waits for the file named by FAKE_ACP_GATE to exist
            let gate =
                env("FAKE_ACP_GATE").unwrap_or_else(|| crash("gate: FAKE_ACP_GATE is not set"));
            while !Path::new(&gate).exists() {
                std::thread::sleep(Duration::from_millis(20));
            }
        } else if text == "slow" {
            self.chunk(sid, "working", None);
            self.hold_until_cancel();
            stop = "cancelled";
        } else if text == "noise" {
            self.write_raw(b"this is not json\n[1,2,3]\n\n");
            self.chunk(sid, "after noise", None);
        } else if text == "die" {
            self.send(&json!({
                "jsonrpc": "2.0", "id": 7003, "method": "session/request_permission",
                "params": {"sessionId": sid, "toolCall": {"toolCallId": "tc-7003", "title": "Doomed"}, "options": []},
            }));
            self.stderr("boom\n");
            std::process::exit(3);
        } else if let Some(secs) = text.strip_prefix("sleep:") {
            self.chunk(sid, "sleeping", None);
            sleep_secs(py_float(secs));
        } else if let Some(code) = text.strip_prefix("exit:") {
            std::process::exit(py_int(code) as i32);
        } else if let Some(n) = text.strip_prefix("big:") {
            let n = py_int(n).max(0) as usize;
            self.update(sid, json!({"sessionUpdate": "tool_call_update", "toolCallId": "big-1", "status": "completed", "title": "Big output",
                "content": [{"type": "content", "content": text_chunk(&"y".repeat(n))}]}));
            self.chunk(sid, &"z".repeat(n), Some("mbig"));
            self.chunk(sid, "tail", Some("mtail"));
        } else if text == "quiet" {
            self.hold_until_cancel();
            stop = "cancelled";
        } else if let Some(n) = text.strip_prefix("picture:") {
            // picture:<chars>: the agent shows a picture of that many base64 characters.
            let n = py_int(n).max(0) as usize;
            let data: String = "QUJD".repeat(n / 4 + 1).chars().take(n).collect();
            self.update(
                sid,
                json!({"sessionUpdate": "agent_message_chunk", "messageId": "pic-1",
                "content": {"type": "image", "mimeType": "image/png", "data": data}}),
            );
            self.chunk(sid, "that was the picture", Some("after-pic"));
        } else if let Some(rest) = text.strip_prefix("len:") {
            self.chunk(sid, &format!("len={}", rest.chars().count()), Some("len"));
        } else if let Some(said) = text.strip_prefix("reply:") {
            self.replies += 1;
            let mid = format!("reply-{}", self.replies);
            self.chunk(sid, &format!("re: {said}"), Some(&mid));
        } else if let Some(tid) = text.strip_prefix("task:") {
            self.spawned.insert(tid.to_string());
            self.update(sid, json!({"sessionUpdate": "async_task_spawned", "asyncTaskId": tid, "name": "sleep 600", "taskType": "shell",
                "description": "sleep 600", "showInTranscript": false, "canStop": true, "toolCallId": format!("tc-{tid}")}));
            self.chunk(sid, &format!("started {tid}"), None);
        } else if let Some(tid) = text.strip_prefix("sdktask:") {
            self.sdk_level(
                sid,
                json!([{"task_id": tid, "task_type": "local_bash", "description": "sleep 600"}]),
            );
            self.chunk(sid, &format!("started {tid}"), None);
        } else if text.starts_with("sdkend:") {
            self.sdk_level(sid, json!([]));
        } else if let Some(n) = text.strip_prefix("long:") {
            for i in 0..py_int(n) {
                self.chunk(sid, &format!("line {i} "), Some(&format!("m{i}")));
            }
        } else if text == "cursor-ask" {
            let r = self.cursor_call(sid, "cur-ask", "cursor/ask_question", json!({
                "toolCallId": "tc-ask", "title": "Need input",
                "questions": [
                    {"id": "q1", "prompt": "Which colour?", "options": [{"id": "red", "label": "Red"}, {"id": "blue", "label": "Blue"}]},
                    {"id": "q2", "prompt": "Which fruits?", "allowMultiple": true,
                     "options": [{"id": "fig", "label": "Fig"}, {"id": "plum", "label": "Plum"}, {"id": "pear", "label": "Pear"}]},
                ],
            }));
            self.got(sid, &r, "cur-ask-got");
        } else if text == "cursor-ask-empty" {
            let r = self.cursor_call(
                sid,
                "cur-ask",
                "cursor/ask_question",
                json!({"toolCallId": "tc-ask", "questions": []}),
            );
            self.got(sid, &r, "cur-ask-got");
        } else if text == "cursor-plan" {
            let r = self.cursor_call(sid, "cur-plan", "cursor/create_plan", json!({
                "toolCallId": "tc-plan", "name": "Refactor tabs", "overview": "Keep UX.",
                "plan": "1. Inspect.\n2. Change.", "todos": [{"id": "t1", "content": "Inspect", "status": "pending"}],
            }));
            self.got(sid, &r, "cur-plan-got");
        } else if text == "cursor-plan-todos" {
            let r = self.cursor_call(sid, "cur-plan", "cursor/create_plan", json!({
                "toolCallId": "tc-plan", "name": "Two steps", "plan": "1. Inspect.\n2. Change.",
                "todos": [{"id": "t1", "content": "Inspect", "status": "pending"}, {"id": "t2", "content": "Change", "status": "pending"}],
            }));
            self.send(&json!({"jsonrpc": "2.0", "method": "cursor/update_todos", "params": {"toolCallId": "tc-todo", "merge": true, "todos": [
                {"id": "t1", "content": "Inspect", "status": "completed"}]}}));
            self.got(sid, &r, "cur-plan-got");
        } else if text == "cursor-todos" {
            let todos = json!([{"id": "1", "content": "Set up", "status": "completed"}, {"id": "2", "content": "Build", "status": "in_progress"},
                {"id": "3", "content": "Drop me", "status": "cancelled"}]);
            self.send(&json!({"jsonrpc": "2.0", "method": "cursor/update_todos", "params": {"toolCallId": "tc-todo", "todos": todos, "merge": false}}));
            self.send(&json!({"jsonrpc": "2.0", "method": "cursor/update_todos", "params": {"toolCallId": "tc-todo", "merge": true, "todos": [
                {"id": "2", "content": "Build", "status": "completed"}, {"id": "4", "content": "Test", "status": "pending"}]}}));
            self.chunk(sid, "todos sent", Some("cur-todos"));
        } else if text == "cursor-task" {
            self.update(sid, json!({"sessionUpdate": "tool_call", "toolCallId": "tc-task", "title": "Task: Explore codebase", "kind": "other",
                "status": "pending", "rawInput": {"_toolName": "task", "prompt": "find auth",
                                                  "description": "Explore codebase", "subagentType": "explore"}}));
            self.update(sid, json!({"sessionUpdate": "tool_call_update", "toolCallId": "tc-task", "status": "completed"}));
            self.send(&json!({"jsonrpc": "2.0", "method": "cursor/task", "params": {
                "toolCallId": "tc-task", "description": "Explore codebase", "prompt": "find auth",
                "subagentType": {"custom": "reviewer"}, "model": "composer", "agentId": "ag-1", "durationMs": 1234}}));
            self.chunk(sid, "task sent", Some("cur-task"));
        } else if text == "cursor-task-bad" {
            self.send(&json!({"jsonrpc": "2.0", "method": "cursor/task", "params": {"toolCallId": 7, "description": "Explore codebase"}}));
            self.chunk(sid, "task sent", Some("cur-task"));
        } else if text.starts_with("heavy:") || text.starts_with("heavyhold:") {
            self.heavy(sid, text);
            if text.starts_with("heavyhold:") {
                self.hold_until_cancel();
                stop = "cancelled";
            }
        }
        self.reply(&id, json!({"stopReason": stop}));
    }

    // ---- main loop ----

    fn run(&mut self) {
        if env("FAKE_ACP_IGNORE_TERM").is_some() {
            // python's SIG_IGN: SIGTERM no longer ends the process
            let flag = Arc::new(AtomicBool::new(false));
            let _ = signal_hook::flag::register(signal_hook::consts::SIGTERM, flag);
        }
        let mut sessions = 0u32;
        let mut authed = false;
        self.stderr("fake agent up\n");
        loop {
            let Some(msg) = self.read() else { return };
            let Some(method) = msg
                .get("method")
                .and_then(Value::as_str)
                .map(str::to_string)
            else {
                continue;
            };
            let Some(rid) = msg.get("id").cloned() else {
                continue;
            };
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            match method.as_str() {
                "initialize" => {
                    if let Some(pid_file) = env("FAKE_ACP_PID_FILE") {
                        let cwd = std::env::current_dir()
                            .map_or_else(|_| String::new(), |p| p.display().to_string());
                        let line = format!("{}\t{cwd}\n", std::process::id());
                        let appended = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&pid_file)
                            .and_then(|mut f| f.write_all(line.as_bytes()));
                        if let Err(e) = appended {
                            crash(&format!("{pid_file}: {e}"));
                        }
                    }
                    write_probe_files();
                    if env("FAKE_ACP_FAIL_INIT").is_some() {
                        self.stderr("cannot start: no login\n");
                        std::process::exit(5);
                    }
                    sleep_secs(env("FAKE_ACP_INIT_DELAY").map_or(0.0, |d| py_float(&d)));
                    let auth = match env("FAKE_ACP_AUTH") {
                        Some(method) => json!([{"id": method, "name": "Login"}]),
                        None => json!([]),
                    };
                    let result = json!({
                        "protocolVersion": 1,
                        "agentInfo": {"name": "fake-acp", "version": "1"},
                        "agentCapabilities": self.capabilities(),
                        "authMethods": auth,
                    });
                    self.reply(&rid, result);
                }
                "session/new" => {
                    if env("FAKE_ACP_AUTH").is_some() && !authed {
                        self.error(&rid, -32000, "Authentication required");
                        continue;
                    }
                    sessions += 1;
                    let sid =
                        self.new_session_id(sessions, params.get("cwd").and_then(Value::as_str));
                    self.reply(&rid, json!({
                        "sessionId": sid,
                        "modes": {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}]},
                    }));
                    if env("FAKE_ACP_TITLE_ON_NEW").is_some() {
                        let sid = sid.clone();
                        self.update(
                            &sid,
                            json!({"sessionUpdate": "session_info_update", "title": "Fake title"}),
                        );
                    }
                }
                "session/load" => self.load_session(&rid, &params),
                "session/prompt" => {
                    self.cancelled = false;
                    self.prompt(&msg);
                }
                "session/list" => self.list_sessions(&rid, &params),
                "_session/async_task/stop" => {
                    let tid = params
                        .get("asyncTaskId")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    let stopped = self.spawned.remove(tid);
                    if stopped {
                        let sid = params
                            .get("sessionId")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        self.update(&sid, json!({"sessionUpdate": "async_task_state_update", "asyncTaskId": tid, "state": "stopped"}));
                    }
                    self.reply(&rid, json!({"stopped": stopped}));
                }
                "authenticate" => {
                    if env("FAKE_ACP_AUTH_EXIT").is_some() {
                        self.stderr("signed out\n");
                        std::process::exit(4);
                    }
                    if env("FAKE_ACP_AUTH_UNKNOWN").is_some() {
                        self.error(&rid, -32601, "Method not found");
                    } else if env("FAKE_ACP_AUTH_FAIL").is_some() {
                        // Cursor's shape when it cannot open a browser: generic message, the reason (with a link) in data.
                        self.send(&json!({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "Invalid params", "data": {
                            "message": "Failed to open browser for login. Please visit: https://cursor.com/loginDeepControl?challenge=abc123"}}}));
                    } else {
                        authed = true;
                        self.reply(&rid, json!({}));
                    }
                }
                other => self.error(&rid, -32601, &format!("unknown method {other}")),
            }
        }
    }
}

/// The files a keeper test asked for at `initialize` (FAKE_ACP_FDS_FILE, _UMASK_FILE, _ENV_FILE).
fn write_probe_files() {
    let write = |path: &str, bytes: &[u8]| {
        if let Err(e) = std::fs::write(path, bytes) {
            crash(&format!("{path}: {e}"));
        }
    };
    if let Some(path) = env("FAKE_ACP_FDS_FILE") {
        // The names first, the directory handle dropped, then keep what still exists:
        // the descriptor that listing used is gone by then.
        let dir = if Path::new("/proc/self/fd").exists() {
            "/proc/self/fd"
        } else {
            "/dev/fd"
        };
        let names: Vec<String> = std::fs::read_dir(dir)
            .map(|d| {
                d.filter_map(|e| e.ok()?.file_name().into_string().ok())
                    .collect()
            })
            .unwrap_or_default();
        let mut fds: Vec<i64> = names
            .iter()
            .filter(|n| Path::new(dir).join(n).exists())
            .filter_map(|n| n.parse().ok())
            .collect();
        fds.sort_unstable();
        write(&path, dumps(&json!(fds), DEFAULT).as_bytes());
    }
    if let Some(path) = env("FAKE_ACP_UMASK_FILE") {
        write(&path, b"");
    }
    if let Some(path) = env("FAKE_ACP_ENV_FILE") {
        let mut vars = Map::new();
        for key in env("FAKE_ACP_ENV_KEYS")
            .unwrap_or_default()
            .split(',')
            .filter(|k| !k.is_empty())
        {
            vars.insert(
                key.to_string(),
                std::env::var(key).map_or(Value::Null, Value::from),
            );
        }
        write(&path, dumps(&Value::Object(vars), DEFAULT).as_bytes());
    }
}

fn find_session<'a>(data: &'a Value, sid: &str) -> Option<&'a Value> {
    data["sessions"]
        .as_array()?
        .iter()
        .find(|s| s["sessionId"] == sid)
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

fn main() {
    Agent::new().run();
}
