//! The keeper's ACP proxy: one agent, many clients, and the id tables that
//! keep their requests straight. Ported from the python `Keeper.on_*` methods
//! (`keeper_script.dart` 1676-2249). The daemon does the I/O; this does the
//! logic and hands back the bytes to write.
//!
//! The in-flight tables are the contract, so they are named for what they
//! hold, exactly as the python:
//! - `routes`: a client's request on its way to the agent (the client's id,
//!   remapped to a numeric agent id).
//! - `fwd`: an agent's request on its way to ONE client (a forwarded `fs/*`).
//! - `pending`: an agent's request given to EVERY live client (a held
//!   permission / elicitation); the first answer wins.

use crate::records::{Info, State};
use crate::replay_log::ReplayLog;
use crate::routes::Route;
use acp::{code, method, Id, Message, RpcError};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

/// The log's byte cap (python `keeper_script.dart:142`): `HERDR_KEEPER_LOG_BYTES`,
/// a test sets it small to exercise the cut.
fn log_bytes() -> usize {
    std::env::var("HERDR_KEEPER_LOG_BYTES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(16 * 1024 * 1024)
}

/// The log's message cap (python `keeper_script.dart:143`):
/// `HERDR_KEEPER_LOG_MESSAGES`, a test sets it small to exercise the cut.
fn log_count() -> usize {
    std::env::var("HERDR_KEEPER_LOG_MESSAGES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_000)
}

/// `HERDR_KEEPER_FULL_TURNS` (python `:144`): the newest turns whose tool
/// detail the log keeps whole.
fn log_full_turns() -> u64 {
    std::env::var("HERDR_KEEPER_FULL_TURNS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3)
}

/// `HERDR_KEEPER_LOG_SOFT_BYTES` (python `:146`): past this a replay drops
/// the oldest turns' tool detail.
fn log_soft_bytes() -> usize {
    std::env::var("HERDR_KEEPER_LOG_SOFT_BYTES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1536 * 1024)
}

/// The ids the keeper's own handshake uses.
pub const INIT_ID: &str = "keeper-init";
pub const AUTH_ID: &str = "keeper-auth";

/// A client connection's keeper-side state.
#[derive(Debug)]
pub struct Client {
    /// The phone / terminal's name, for `_herdr/resolved {by}`.
    pub label: String,
    /// A terminal (`view`) client: it does not count as having seen the end.
    pub viewer: bool,
    /// It has sent a `session/*` request: it gets broadcasts.
    pub live: bool,
    /// The herdr pane it came from, if any (`_meta.herdr.pane`).
    pub pane_id: Option<String>,
    /// The last time it sent a line, ms: the answerer's recency.
    pub last_input_ms: i64,
}

/// A client's request, on its way to the agent.
#[derive(Debug)]
struct ClientRoute {
    client: u64,
    /// The agent id this request goes out under.
    oid: i64,
    /// The id the client used, to put back on the answer.
    client_id: Id,
    method: String,
    params: Value,
    /// It is a `session/prompt`: it starts a turn.
    prompt: bool,
}

/// An agent's request, on its way to one client.
#[derive(Debug, Clone)]
struct Fwd {
    agent_id: Id,
    client: u64,
}

/// An agent's request, given to every live client.
#[derive(Debug, Clone)]
struct Held {
    kid: String,
    agent_id: Id,
    method: String,
    params: Value,
    clients: HashSet<u64>,
    /// `Some("ask"|"plan")` when the request was a Cursor extension translated
    /// into a phone form/card: the answer is translated back.
    xlate: Option<&'static str>,
    /// The original Cursor params (for translating the answer back).
    orig: Value,
}

/// The message of a prompt just sent, not yet logged.
#[derive(Debug)]
struct Stash {
    sid: String,
    blocks: Vec<Value>,
    mid: String,
    client: u64,
}

/// Bytes the router wants written, from one input line.
#[derive(Default, Debug)]
pub struct Out {
    /// To the agent's stdin, each a line without its newline.
    pub agent: Vec<String>,
    /// To each client, each a line without its newline.
    pub clients: HashMap<u64, Vec<String>>,
    /// The record changed: the daemon saves it.
    pub dirty: bool,
    /// The agent is answered and the daemon may start accepting clients.
    pub ready: bool,
    /// The agent is gone (its `initialize` failed): the daemon ends the start.
    pub failed: bool,
    /// Events the alert hook is told about (the daemon runs the hook).
    pub alerts: Vec<AlertEvent>,
}

/// What the alert hook is told: the event (`blocked` or `done`) and the text it
/// is about, cut but not yet redacted ([`crate::redact::redact_line`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlertEvent {
    pub event: &'static str,
    pub summary: String,
}

impl Out {
    // `to_*` taking `&mut self` (not `&self`): they append to `clients`,
    // which is the point. The lint's `to_* → &self` heuristic does not apply.
    #[allow(clippy::wrong_self_convention)]
    fn to_client(&mut self, client: u64, line: String) {
        self.clients.entry(client).or_default().push(line);
    }
    #[allow(clippy::wrong_self_convention)]
    fn to_clients(&mut self, clients: impl Iterator<Item = u64>, line: String) {
        for c in clients {
            self.to_client(c, line.clone());
        }
    }
}

/// The proxy's state.
#[derive(Debug)]
pub struct Router {
    pub id: String,
    pub agent: String,
    pub cwd: String,
    pub info: Info,
    log: ReplayLog,
    /// A 6-byte log-generation tag, hex, in `_meta.herdr.epoch`.
    pub epoch: String,
    session_id: Option<String>,
    /// The original `session/new`/`load` result: what a re-load returns.
    setup: Value,
    /// The agent's `initialize` result, the cached answer to clients.
    pub init_result: Option<Value>,
    init_done: bool,
    /// `authenticate` was sent and not yet answered: the start owes it.
    pub(crate) auth_stage: bool,
    /// The formatted reason when the agent refused `authenticate`.
    pub auth_reason: Option<String>,
    /// The agent's `initialize` error message, when it refused.
    pub init_reason: Option<String>,
    clients: HashMap<u64, Client>,
    routes: HashMap<i64, ClientRoute>,
    fwd: HashMap<String, Fwd>,
    /// Claude's live background tasks: a level, not a log entry.
    bg_level: Option<String>,
    /// Cursor's todo list (the plan), in order: `cursor/update_todos`.
    cursor_todos: Vec<(String, Value)>,
    stash: Option<Stash>,
    /// The user-message entries logged for each prompt, to retract on refusal.
    sent: HashMap<i64, Vec<u64>>,
    pending: HashMap<String, Held>,
    /// The stop of a turn that ended while no phone was attached.
    unseen_stop: Option<String>,
    /// The diagnostic log (`.log` file); `dlog` writes to it. `None` until the
    /// daemon opens it.
    diag: Option<std::io::BufWriter<std::fs::File>>,
    next_out: i64,
    next_kid: u64,
    next_client: u64,
}

impl Router {
    /// A fresh proxy; the daemon sends `initialize` straight after.
    #[must_use]
    pub fn new(id: String, agent: String, cwd: String, epoch: String) -> Self {
        let info = Info {
            id: id.clone(),
            agent: agent.clone(),
            cwd: cwd.clone(),
            state: State::Starting,
            started_at: Some(now_ms()),
            pid: Some(std::process::id() as i64),
            ..Default::default()
        };
        Self {
            id,
            agent,
            cwd,
            info,
            log: ReplayLog::new(
                log_bytes(),
                log_count(),
                log_full_turns(),
                Some(log_soft_bytes()),
            ),
            epoch,
            session_id: None,
            setup: Value::Object(Map::new()),
            init_result: None,
            init_done: false,
            auth_stage: false,
            auth_reason: None,
            init_reason: None,
            clients: HashMap::new(),
            routes: HashMap::new(),
            fwd: HashMap::new(),
            pending: HashMap::new(),
            stash: None,
            sent: HashMap::new(),
            bg_level: None,
            cursor_todos: Vec::new(),
            unseen_stop: None,
            diag: None,
            next_out: 1,
            next_kid: 1,
            next_client: 1,
        }
    }

    /// The daemon opens the diagnostic log and hands it over.
    pub fn set_diag(&mut self, w: std::io::BufWriter<std::fs::File>) {
        self.diag = Some(w);
    }

    /// The session's title, when the agent has named it (`""` before).
    #[must_use]
    pub fn title(&self) -> &str {
        self.info
            .extra
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
    }

    /// One line to the diagnostic log (python `dlog` `:1494`): a timestamp and
    /// the text, capped. `session/load` never reads this; the tests do.
    pub(crate) fn dlog(&mut self, text: &str) {
        let Some(w) = self.diag.as_mut() else {
            return;
        };
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // `DDDDDDDDTHH:MM:SS` from the epoch: enough to order the lines.
        let days = secs / 86_400;
        let rem = secs % 86_400;
        let h = rem / 3600;
        let m = (rem % 3600) / 60;
        let s = rem % 60;
        let stamp = format!("{days:08x}T{h:02}:{m:02}:{s:02}");
        use std::io::Write;
        let _ = writeln!(
            w,
            "{stamp} {}",
            text.replace('\n', " ")
                .chars()
                .take(2000)
                .collect::<String>()
        );
        let _ = w.flush();
    }

    /// The `initialize` request the daemon sends to the agent (python
    /// `init_request` `:2681-2702`).
    #[must_use]
    pub fn init_request(route: Option<&Route>) -> String {
        let mut caps = json!({
            "fs": {"readTextFile": false, "writeTextFile": false},
            "terminal": false,
            "elicitation": {"form": {}},
            "session": {"configOptions": {"boolean": {}}},
        });
        if let Some(air) = route.and_then(|r| (!r.air.is_empty()).then_some(r.air.clone())) {
            if let Some(obj) = caps.as_object_mut() {
                obj.insert(
                    "_meta".into(),
                    json!({"jetbrains": {"air": {"version": 1, "capabilities": air}}}),
                );
            }
        }
        json!({
            "jsonrpc": "2.0", "id": INIT_ID, "method": "initialize",
            "params": {
                "protocolVersion": 1,
                "clientCapabilities": caps,
                "clientInfo": {"name": "herdr-keeper", "title": "herdr keeper", "version": "1"},
            },
        })
        .to_string()
    }

    /// The `authenticate` request, when the route names a method the agent
    /// offers (python `on_init_response` `:2326-2333`).
    #[must_use]
    pub fn auth_request(method_name: &str) -> String {
        json!({
            "jsonrpc": "2.0", "id": AUTH_ID, "method": "authenticate",
            "params": {"methodId": method_name},
        })
        .to_string()
    }

    /// A line from the agent.
    pub fn on_agent_line(&mut self, line: &str, out: &mut Out) {
        let Ok(msg) = Message::parse(line) else {
            self.dlog(&format!(
                "agent wrote a line that is not JSON: {}",
                trunc(line, 200)
            ));
            return;
        };
        match msg {
            Message::Response { id, outcome } => self.on_agent_response(id, outcome, out),
            Message::Request { id, method, params } => {
                self.on_agent_request(id, method, params, out)
            }
            Message::Notification { method, params } => {
                self.on_agent_notification(&method, params, line.to_string(), out)
            }
        }
    }

    /// A line from a client.
    pub fn on_client_line(&mut self, client: u64, line: &str, out: &mut Out) {
        if let Some(c) = self.clients.get_mut(&client) {
            c.last_input_ms = now_ms();
        }
        let Ok(msg) = Message::parse(line) else {
            self.dlog(&format!(
                "client sent a line that is not JSON: {}",
                trunc(line, 200)
            ));
            return;
        };
        match msg {
            Message::Request { id, method, params } => {
                self.on_client_request(client, id, method, params, out)
            }
            Message::Notification { method, params } => {
                self.on_client_notification(client, &method, &params, out)
            }
            Message::Response { id, outcome } => self.on_client_answer(client, id, outcome, out),
        }
    }

    /// A client connected: register it. Its first `initialize` arrives through
    /// [`Self::on_client_line`] and names it.
    pub fn add_client(&mut self, out: &mut Out) -> u64 {
        let id = self.next_client;
        self.next_client += 1;
        self.clients.insert(
            id,
            Client {
                label: "client".to_string(),
                viewer: false,
                live: false,
                pane_id: None,
                last_input_ms: 0,
            },
        );
        self.info.clients = self.clients.len() as u32;
        out.dirty = true;
        id
    }

    /// A client went: drop its state and tell the agent whose request it had.
    pub fn drop_client(&mut self, client: u64, out: &mut Out) {
        if self.clients.remove(&client).is_none() {
            return;
        }
        for (kid, f) in self.fwd.clone() {
            if f.client == client {
                self.fwd.remove(&kid);
                out.agent.push(
                    json!({"jsonrpc":"2.0","id":f.agent_id,"error":{"code":-32000,"message":"the client went away"}})
                        .to_string(),
                );
            }
        }
        for h in self.pending.values_mut() {
            h.clients.remove(&client);
        }
        if self.stash.as_ref().is_some_and(|s| s.client == client) {
            self.stash = None;
        }
        self.info.clients = self.clients.len() as u32;
        out.dirty = true;
    }

    // -- the agent side -----------------------------------------------------

    fn on_agent_response(&mut self, id: Id, outcome: Result<Value, RpcError>, out: &mut Out) {
        if let Id::Str(s) = &id {
            if s == INIT_ID {
                self.on_init_response(outcome, out);
                return;
            }
            if s == AUTH_ID {
                self.on_auth_response(outcome, out);
                return;
            }
        }
        let Id::Num(n) = id else {
            return;
        };
        let Some(route) = self.routes.remove(&n) else {
            return;
        };
        let ok = outcome.is_ok();
        // Only session-opening answers set the session and its setup (python
        // `:2054`); a prompt's `{"stopReason"}` must not clobber it.
        if ok
            && matches!(
                route.method.as_str(),
                "session/new" | "session/load" | "session/resume"
            )
        {
            self.note_session(&route, outcome.as_ref().ok(), out);
        }
        if route.prompt {
            self.end_turn(&route, &outcome, out);
        }
        let line = match outcome {
            Ok(result) => json!({"jsonrpc":"2.0","id":route.client_id,"result":result}),
            Err(e) => json!({"jsonrpc":"2.0","id":route.client_id,"error":e}),
        };
        if self.clients.contains_key(&route.client) {
            out.to_client(route.client, line.to_string());
        }
    }

    fn on_init_response(&mut self, outcome: Result<Value, RpcError>, out: &mut Out) {
        let Ok(mut result) = outcome else {
            let err = outcome.as_ref().err();
            if err.is_some_and(|e| e.code == code::METHOD_NOT_FOUND) {
                self.finish_init(out);
            } else {
                self.init_reason = err
                    .map(|e| e.message.clone())
                    .filter(|m| !m.is_empty())
                    .or_else(|| Some("no result".to_string()));
                out.failed = true;
            }
            return;
        };
        // The phone loads sessions; an agent that does not say so is told it
        // can, so a re-attach replays.
        if let Some(caps) = result
            .get_mut("agentCapabilities")
            .and_then(Value::as_object_mut)
        {
            caps.insert("loadSession".to_string(), json!(true));
        }
        self.init_result = Some(result);
        self.finish_init(out);
    }

    fn on_auth_response(&mut self, outcome: Result<Value, RpcError>, out: &mut Out) {
        // `finish_init` is a no-op here (`init_done` is already set by the
        // `initialize` answer), so the ready flag is set directly — the
        // handshake's auth loop waits on it.
        match outcome {
            Ok(_) => {
                self.auth_stage = false;
                out.ready = true;
            }
            // An agent that does not know `authenticate` has nothing to sign in to.
            Err(e) if e.code == code::METHOD_NOT_FOUND => {
                self.auth_stage = false;
                out.ready = true;
            }
            Err(e) => {
                self.auth_reason = Some(format!(
                    "the agent refused to sign in: {}",
                    cursor_sign_in_reason(&e)
                ));
                out.failed = true;
            }
        }
    }

    fn finish_init(&mut self, out: &mut Out) {
        if self.init_done {
            return;
        }
        self.init_done = true;
        self.info.state = State::Running;
        out.dirty = true;
        out.ready = true;
    }

    fn on_agent_request(&mut self, id: Id, mut method: String, mut params: Value, out: &mut Out) {
        // The prompt this request is about comes first, for the clients that did not
        // send it: an agent may ask before it says anything (python `flush_stash()`).
        self.flush_stash(None, out);
        // Cursor's own question and plan-approval become the phone's form and
        // card, held like any other (python `XLATE` `:79`).
        let xlate = match method.as_str() {
            "cursor/ask_question" => Some("ask"),
            "cursor/create_plan" => Some("plan"),
            _ => None,
        };
        let orig = params.clone();
        if let Some(kind) = xlate {
            let mut sid = self.session_id.clone();
            if sid.is_none() {
                sid = orig
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .map(str::to_string);
            }
            if kind == "plan" && self.session_id.is_some() {
                if let Some(todos) = orig.get("todos") {
                    self.cursor_plan_update(todos, false, out);
                }
            }
            let (new_method, new_params) = if kind == "ask" {
                (
                    method::ELICITATION_CREATE.to_string(),
                    cursor_ask_to_elicitation(&orig, sid.as_deref()),
                )
            } else {
                (
                    method::REQUEST_PERMISSION.to_string(),
                    cursor_plan_to_permission(&orig, sid.as_deref()),
                )
            };
            let Some(new_params) = new_params else {
                self.dlog(&format!("{method} had nothing to show: cancelled"));
                out.agent.push(
                    json!({"jsonrpc":"2.0","id":id,"result":{"outcome":{"outcome":"cancelled"}}})
                        .to_string(),
                );
                return;
            };
            method = new_method;
            params = new_params;
        }
        let is_held = matches!(
            method.as_str(),
            method::REQUEST_PERMISSION | method::ELICITATION_CREATE
        );
        if is_held {
            let kid = format!("kp{}", self.next_kid);
            self.next_kid += 1;
            let clients: HashSet<u64> = self.live_clients().collect();
            self.pending.insert(
                kid.clone(),
                Held {
                    kid: kid.clone(),
                    agent_id: id,
                    method: method.clone(),
                    params: params.clone(),
                    clients,
                    xlate,
                    orig,
                },
            );
            self.info.pending = self.pending.len() as u32;
            out.dirty = true;
            out.alerts.push(AlertEvent {
                event: "blocked",
                summary: summarize(&method, &params),
            });
            let line =
                json!({"jsonrpc":"2.0","id":kid,"method":method,"params":params}).to_string();
            out.to_clients(self.live_clients(), line);
            return;
        }
        let Some(client) = self.answerer() else {
            out.agent.push(
                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":format!("No client is attached to answer {method}.")}})
                    .to_string(),
            );
            return;
        };
        let kid = format!("kp{}", self.next_kid);
        self.next_kid += 1;
        self.fwd.insert(
            kid.clone(),
            Fwd {
                agent_id: id,
                client,
            },
        );
        out.to_client(
            client,
            json!({"jsonrpc":"2.0","id":kid,"method":method,"params":params}).to_string(),
        );
    }

    fn on_agent_notification(
        &mut self,
        method_name: &str,
        params: Value,
        raw: String,
        out: &mut Out,
    ) {
        match method_name {
            method::SESSION_UPDATE => {
                self.note_update(&params, raw.len(), out);
                out.to_clients(self.live_clients(), raw);
            }
            method::CANCEL_REQUEST => {
                // The agent cancelled one of its own requests.
                let Some(target) = params.get("requestId").cloned() else {
                    return;
                };
                let target = target_id(&target);
                if let Some((kid, held)) = self
                    .pending
                    .iter()
                    .find(|(_, h)| h.agent_id == target)
                    .map(|(k, h)| (k.clone(), h.clone()))
                {
                    self.pending.remove(&kid);
                    self.info.pending = self.pending.len() as u32;
                    out.dirty = true;
                    let note = json!({"jsonrpc":"2.0","method":method::HERDR_RESOLVED,"params":{"requestId":kid,"by":"agent","answer":"cancelled"}}).to_string();
                    let cancel = json!({"jsonrpc":"2.0","method":method::CANCEL_REQUEST,"params":{"requestId":kid}}).to_string();
                    for c in held.clients {
                        if self.clients.contains_key(&c) {
                            out.to_client(c, note.clone());
                            out.to_client(c, cancel.clone());
                        }
                    }
                    return;
                }
                if let Some((kid, f)) = self
                    .fwd
                    .iter()
                    .find(|(_, f)| f.agent_id == target)
                    .map(|(k, f)| (k.clone(), f.clone()))
                {
                    self.fwd.remove(&kid);
                    out.to_client(f.client, json!({"jsonrpc":"2.0","method":method::CANCEL_REQUEST,"params":{"requestId":kid}}).to_string());
                }
            }
            "cursor/update_todos" if self.session_id.is_some() => {
                let todos = params.get("todos").cloned().unwrap_or(Value::Null);
                let merge = params.get("merge").and_then(Value::as_bool) == Some(true);
                self.cursor_plan_update(&todos, merge, out);
            }
            "cursor/task" if self.session_id.is_some() => {
                let Some(task) = cursor_task_update(&params) else {
                    self.dlog("cursor/task names no tool call: dropped");
                    return;
                };
                let p = json!({"sessionId":self.session_id,"update":task});
                let raw =
                    json!({"jsonrpc":"2.0","method":method::SESSION_UPDATE,"params":p}).to_string();
                self.on_agent_notification(method::SESSION_UPDATE, p, raw, out);
            }
            "_claude/sdkMessage" if raw.contains("background_tasks_changed") => {
                self.bg_level = Some(raw);
            }
            _ => out.to_clients(self.live_clients(), raw),
        }
    }

    /// The todo list after a change, as the `plan` session/update every client
    /// gets (and the log keeps) (python `cursor_plan_update`).
    fn cursor_plan_update(&mut self, todos: &Value, merge: bool, out: &mut Out) {
        if !merge {
            self.cursor_todos.clear();
        }
        for t in todos.as_array().into_iter().flatten() {
            let Some(id) = t.get("id").and_then(Value::as_str) else {
                continue;
            };
            let Some(content) = t.get("content").and_then(Value::as_str) else {
                continue;
            };
            let status = t.get("status").and_then(Value::as_str);
            if status == Some("cancelled") {
                self.cursor_todos.retain(|(k, _)| k != id);
                continue;
            }
            let status = match status {
                Some("in_progress") | Some("completed") | Some("pending") => status,
                _ => Some("pending"),
            };
            let entry = json!({"content":content,"priority":"medium","status":status});
            if let Some(slot) = self.cursor_todos.iter_mut().find(|(k, _)| k == id) {
                slot.1 = entry;
            } else {
                self.cursor_todos.push((id.to_string(), entry));
            }
        }
        let entries: Vec<Value> = self.cursor_todos.iter().map(|(_, v)| v.clone()).collect();
        let p = json!({"sessionId":self.session_id,"update":{"sessionUpdate":"plan","entries":entries}});
        let raw = json!({"jsonrpc":"2.0","method":method::SESSION_UPDATE,"params":p}).to_string();
        self.on_agent_notification(method::SESSION_UPDATE, p, raw, out);
    }

    fn note_update(&mut self, params: &Value, size: usize, out: &mut Out) {
        let Some(upd) = params.get("update").and_then(Value::as_object) else {
            return;
        };
        let kind = upd.get("sessionUpdate").and_then(Value::as_str);
        if kind == Some("session_info_update") {
            if let Some(t) = upd
                .get("title")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                self.info.extra.insert(
                    "title".to_string(),
                    json!(t.chars().take(300).collect::<String>()),
                );
                out.dirty = true;
            }
        }
        self.info
            .extra
            .insert("last_event_at".to_string(), json!(now_ms()));
        if self.stash.is_some() && kind.is_some() {
            if kind == Some("user_message_chunk") {
                // The agent logged the user message itself: the daemon's copy
                // is a duplicate (python `note_update`).
                self.stash = None;
            } else {
                let skip = self.stash.as_ref().map(|s| s.client);
                self.flush_stash(skip, out);
            }
        }
        let msg = json!({"jsonrpc":"2.0","method":method::SESSION_UPDATE,"params":params});
        self.log_add(&msg, size, out);
    }

    // -- the client side ----------------------------------------------------

    fn on_client_request(
        &mut self,
        client: u64,
        id: Id,
        method: String,
        params: Value,
        out: &mut Out,
    ) {
        if method == method::INITIALIZE {
            self.introduce(client, &params);
            if let Some(result) = &self.init_result {
                out.to_client(
                    client,
                    json!({"jsonrpc":"2.0","id":id,"result":result}).to_string(),
                );
                return;
            }
        }
        if matches!(method.as_str(), "session/load" | "session/resume")
            && self.session_id.is_some()
            && params.get("sessionId").and_then(Value::as_str) == self.session_id.as_deref()
        {
            self.serve_held(client, &id, &method, &params, out);
            return;
        }
        let oid = self.next_out;
        self.next_out += 1;
        let prompt = method == method::SESSION_PROMPT;
        self.routes.insert(
            oid,
            ClientRoute {
                client,
                oid,
                client_id: id,
                method: method.clone(),
                params: params.clone(),
                prompt,
            },
        );
        if method.starts_with("session/") && method != "session/list" {
            if let Some(c) = self.clients.get_mut(&client) {
                c.live = true;
            }
        }
        if prompt {
            self.begin_turn(&params, oid, client, out);
            out.dirty = true;
        }
        out.agent
            .push(json!({"jsonrpc":"2.0","id":oid,"method":method,"params":params}).to_string());
    }

    fn on_client_notification(
        &mut self,
        client: u64,
        method_name: &str,
        params: &Value,
        out: &mut Out,
    ) {
        if method_name == method::CANCEL_REQUEST {
            let Some(target) = params.get("requestId").cloned() else {
                return;
            };
            let target = target_id(&target);
            let oid = self
                .routes
                .iter()
                .find(|(_, r)| r.client == client && r.client_id == target)
                .map(|(oid, _)| *oid);
            if let Some(oid) = oid {
                out.agent.push(json!({"jsonrpc":"2.0","method":method::CANCEL_REQUEST,"params":{"requestId":oid}}).to_string());
            }
            return;
        }
        out.agent
            .push(json!({"jsonrpc":"2.0","method":method_name,"params":params}).to_string());
    }

    fn on_client_answer(
        &mut self,
        client: u64,
        id: Id,
        outcome: Result<Value, RpcError>,
        out: &mut Out,
    ) {
        let Id::Str(kid) = id else {
            return;
        };
        if let Some(held) = self.pending.remove(&kid) {
            let answer = match &outcome {
                Ok(result) => answer_of(&held.method, &held.params, result),
                Err(_) => "cancelled".to_string(),
            };
            let line = match &outcome {
                Ok(result) => {
                    let result = match held.xlate {
                        Some("ask") => cursor_ask_result(result, &held.orig),
                        Some("plan") => cursor_plan_result(result),
                        _ => result.clone(),
                    };
                    json!({"jsonrpc":"2.0","id":held.agent_id,"result":result})
                }
                Err(e) => json!({"jsonrpc":"2.0","id":held.agent_id,"error":e}),
            };
            out.agent.push(line.to_string());
            self.info.pending = self.pending.len() as u32;
            out.dirty = true;
            let by = self
                .clients
                .get(&client)
                .map(|c| c.label.clone())
                .unwrap_or_else(|| "client".to_string());
            let note = json!({"jsonrpc":"2.0","method":method::HERDR_RESOLVED,"params":{"requestId":kid,"by":by,"answer":answer}}).to_string();
            let cancel =
                json!({"jsonrpc":"2.0","method":method::CANCEL_REQUEST,"params":{"requestId":kid}})
                    .to_string();
            for c in held.clients {
                if c != client && self.clients.contains_key(&c) {
                    out.to_client(c, note.clone());
                    out.to_client(c, cancel.clone());
                }
            }
            return;
        }
        let Some(f) = self.fwd.remove(&kid) else {
            return;
        };
        let line = match outcome {
            Ok(result) => json!({"jsonrpc":"2.0","id":f.agent_id,"result":result}),
            Err(e) => json!({"jsonrpc":"2.0","id":f.agent_id,"error":e}),
        };
        out.agent.push(line.to_string());
    }

    fn introduce(&mut self, client: u64, params: &Value) {
        let Some(c) = self.clients.get_mut(&client) else {
            return;
        };
        let info = params.get("clientInfo");
        c.label = info
            .and_then(|i| i.get("title").or_else(|| i.get("name")))
            .and_then(Value::as_str)
            .map(|s| s.chars().take(80).collect::<String>())
            .unwrap_or_else(|| "client".to_string());
        let meta = params.pointer("/_meta/herdr");
        if let Some(meta) = meta {
            c.viewer = meta.get("viewer").and_then(Value::as_bool).unwrap_or(false);
            c.pane_id = meta.get("pane").and_then(Value::as_str).map(str::to_string);
        }
        if let Some(pane) = &c.pane_id {
            self.info.pane_id = Some(pane.clone());
        }
    }

    // -- turns --------------------------------------------------------------

    fn begin_turn(&mut self, params: &Value, oid: i64, client: u64, out: &mut Out) {
        self.flush_stash(Some(client), out);
        self.info.turn_active = true;
        out.dirty = true;
        let Some(sid) = params.get("sessionId").and_then(Value::as_str) else {
            return;
        };
        let line = state_update_line(sid, "running", None);
        out.to_clients(self.live_clients().filter(|c| *c != client), line);
        let Some(blocks) = params.get("prompt").and_then(Value::as_array) else {
            return;
        };
        let blocks: Vec<Value> = blocks
            .iter()
            .filter(|b| b.is_object())
            .map(|b| {
                let is_text = b.get("type").and_then(Value::as_str) == Some("text");
                if is_text || serde_json::to_string(b).unwrap_or_default().len() <= 20_000 {
                    b.clone()
                } else {
                    json!({"type":"text","text":format!("[{} omitted]", b.get("type").and_then(Value::as_str).unwrap_or("attachment"))})
                }
            })
            .collect();
        if !blocks.is_empty() {
            self.stash = Some(Stash {
                sid: sid.to_string(),
                blocks,
                mid: format!("keeper-{:016x}", rand64()),
                client,
            });
        }
        let _ = oid; // the stash is keyed by its sender; the oid is in `sent`
    }

    fn flush_stash(&mut self, skip: Option<u64>, out: &mut Out) {
        let Some(st) = self.stash.take() else {
            return;
        };
        let mut logged = Vec::new();
        let mut line_for_clients: Option<String> = None;
        for b in &st.blocks {
            let msg = json!({"jsonrpc":"2.0","method":method::SESSION_UPDATE,"params":{"sessionId":st.sid,"update":{"sessionUpdate":"user_message_chunk","content":b,"messageId":st.mid}}});
            let line = msg.to_string();
            if let Some(e) = self.log_add(&msg, line.len(), out) {
                logged.push(e);
            }
            line_for_clients.get_or_insert(line);
        }
        if let Some(line) = line_for_clients {
            out.to_clients(
                self.live_clients()
                    .filter(|c| *c != st.client && Some(*c) != skip),
                line,
            );
        }
        if !logged.is_empty() {
            let oid = self
                .routes
                .iter()
                .find(|(_, r)| r.client == st.client && r.prompt)
                .map(|(oid, _)| *oid);
            if let Some(oid) = oid {
                self.sent.insert(oid, logged);
            }
        }
    }

    fn end_turn(&mut self, route: &ClientRoute, outcome: &Result<Value, RpcError>, out: &mut Out) {
        let refused = matches!(outcome, Err(e) if e.code == code::SESSION_BUSY);
        if refused {
            // The agent took nothing: the prompt's user message must not be
            // logged (a refused attempt is not a message). Drop the stash so it
            // is not flushed at the next turn.
            self.stash = None;
            if let Some(es) = self.sent.remove(&route.oid) {
                for e in es {
                    self.log.remove(e);
                }
            }
        } else {
            self.flush_stash(Some(route.client), out);
            self.sent.remove(&route.oid);
        }
        let stop = outcome
            .as_ref()
            .ok()
            .and_then(|r| r.get("stopReason"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let sid = route.params.get("sessionId").and_then(Value::as_str);
        if let Some(sid) = sid {
            let others = || self.live_clients().filter(move |c| *c != route.client);
            if !refused {
                out.to_clients(others(), state_update_line(sid, "idle", stop.as_deref()));
            }
            if self.busy() {
                out.to_clients(others(), state_update_line(sid, "running", None));
            } else if refused {
                out.to_clients(others(), state_update_line(sid, "idle", None));
            }
        }
        let seen = self.clients.values().any(|c| c.live && !c.viewer);
        // "Seen" and the `done` alert are about the phone: a terminal client
        // does not count as having seen the end. A phone that is connected
        // (it has sent a line) but has not loaded the session yet is still
        // there, and the alert waits.
        if !seen
            && !self
                .clients
                .values()
                .any(|c| !c.viewer && c.last_input_ms > 0)
        {
            out.alerts.push(AlertEvent {
                event: "done",
                summary: match stop.as_deref() {
                    Some(stop) => format!("Turn finished ({stop})"),
                    None => "Turn finished".to_string(),
                },
            });
        }
        self.unseen_stop = if seen { None } else { stop };
        self.info.unseen_done = self.unseen_stop.is_some();
        self.info.turn_active = self.busy();
        out.dirty = true;
    }

    // -- the log ------------------------------------------------------------

    fn log_add(&mut self, msg: &Value, size: usize, out: &mut Out) -> Option<u64> {
        let cap = log_bytes();
        let (msg, size) = if size <= cap {
            (msg.clone(), size)
        } else {
            let small = self.shrink(msg, size, cap)?;
            (small.0, small.1)
        };
        let waiting = self.waiting_tools();
        let e = self.log.add(msg, size, || waiting);
        out.dirty = true;
        Some(e)
    }

    fn shrink(&self, msg: &Value, size: usize, cap: usize) -> Option<(Value, usize)> {
        let upd = msg.pointer("/params/update")?.as_object()?;
        let kind = upd.get("sessionUpdate")?.as_str()?;
        let mut small = Map::new();
        small.insert("sessionUpdate".into(), json!(kind));
        match kind {
            "agent_message_chunk" | "user_message_chunk" | "thought_chunk" => {
                if let Some(mid) = upd.get("messageId") {
                    small.insert("messageId".into(), mid.clone());
                }
                let head = upd
                    .get("content")
                    .and_then(|c| c.get("text"))
                    .and_then(Value::as_str)
                    .map(|t| t.chars().take(cap / 16).collect::<String>())
                    .unwrap_or_default();
                let text = if head.is_empty() {
                    format!("[{size} bytes omitted]")
                } else {
                    format!("{head}\n[{size} bytes omitted]")
                };
                small.insert("content".into(), json!({"type":"text","text":text}));
            }
            "tool_call" | "tool_call_update" => {
                for key in ["toolCallId", "status", "kind"] {
                    if let Some(v) = upd.get(key) {
                        small.insert(key.into(), v.clone());
                    }
                }
                if let Some(title) = upd.get("title").and_then(Value::as_str) {
                    small.insert(
                        "title".into(),
                        json!(title.chars().take(500).collect::<String>()),
                    );
                }
                small.insert(
                    "content".into(),
                    json!([{"type":"content","content":{"type":"text","text":format!("[output of {size} bytes omitted]")}}]),
                );
            }
            _ => return None,
        }
        let stub = json!({"jsonrpc":"2.0","method":method::SESSION_UPDATE,"params":{"sessionId":msg.pointer("/params/sessionId"),"update":small}});
        let n = stub.to_string().len();
        (n <= cap).then_some((stub, n))
    }

    fn waiting_tools(&self) -> HashSet<String> {
        let mut ids = HashSet::new();
        for h in self.pending.values() {
            if let Some(tid) = h
                .params
                .pointer("/toolCall/toolCallId")
                .and_then(Value::as_str)
            {
                ids.insert(tid.to_string());
            }
        }
        ids
    }

    // -- re-load ------------------------------------------------------------

    fn serve_held(
        &mut self,
        client: u64,
        id: &Id,
        method_name: &str,
        params: &Value,
        out: &mut Out,
    ) {
        self.flush_stash(Some(client), out);
        let replay = method_name == "session/load";
        let Some(sid) = self.session_id.clone() else {
            return;
        };
        if replay {
            let since = self.replay_since(params);
            if let Some(s) = since {
                out.to_client(client, json!({"jsonrpc":"2.0","method":"_herdr/replay","params":{"sessionId":sid,"from":s}}).to_string());
            }
            let mut turn: Option<u64> = None;
            for (e, seq) in self.log.replay(since) {
                let ok_sid = e.msg.pointer("/params/sessionId").and_then(Value::as_str)
                    == Some(sid.as_str());
                if !ok_sid {
                    continue;
                }
                let mut o = e.msg.clone();
                if let Some(s) = seq {
                    if turn != Some(s) {
                        if let Some(p) = o.get_mut("params").and_then(Value::as_object_mut) {
                            let meta = p
                                .entry("_meta")
                                .or_insert_with(|| Value::Object(Map::new()));
                            if let Some(meta) = meta.as_object_mut() {
                                meta.insert("herdr".into(), json!({"epoch":self.epoch,"turn":s}));
                            }
                        }
                        turn = Some(s);
                    }
                }
                out.to_client(client, o.to_string());
            }
        }
        let mut result = self.setup.clone();
        if replay {
            // What the log gave up, for an app that knows to say so (the python
            // keeper creates `_meta` when the session result has none).
            let herdr =
                json!({"droppedTurns":self.log.dropped(),"trimmedTurns":self.log.trimmed()});
            let obj = result
                .as_object_mut()
                .expect("the session result is an object");
            let meta = obj
                .entry(String::from("_meta"))
                .or_insert_with(|| Value::Object(Map::new()))
                .as_object_mut()
                .expect("`_meta` is an object");
            meta.insert("herdr".into(), herdr);
        }
        if let Some(bg) = &self.bg_level {
            out.to_client(client, bg.clone());
        }
        out.to_client(
            client,
            json!({"jsonrpc":"2.0","id":id,"result":result}).to_string(),
        );
        if let Some(c) = self.clients.get_mut(&client) {
            c.live = true;
        }
        if self.busy() {
            out.to_client(client, state_update_line(&sid, "running", None));
        } else if let Some(stop) = &self.unseen_stop {
            out.to_client(client, state_update_line(&sid, "idle", Some(stop.as_str())));
        }
        if self.unseen_stop.is_some() && self.clients.get(&client).is_none_or(|c| !c.viewer) {
            self.unseen_stop = None;
            self.info.unseen_done = false;
            out.dirty = true;
        }
        for h in self.pending.values().cloned() {
            out.to_client(
                client,
                json!({"jsonrpc":"2.0","id":h.kid,"method":h.method,"params":h.params}).to_string(),
            );
        }
    }

    fn replay_since(&self, params: &Value) -> Option<u64> {
        let s = params.pointer("/_meta/herdr/since")?;
        if s.get("epoch").and_then(Value::as_str) != Some(self.epoch.as_str()) {
            return None;
        }
        let turn = s.get("turn")?.as_u64()?;
        // A stamp for a turn the log has given up is answered with the whole
        // log (python `replay_since`).
        self.log.has_turn(turn).then_some(turn)
    }

    fn note_session(&mut self, route: &ClientRoute, result: Option<&Value>, out: &mut Out) {
        let sid = if route.method == "session/new" {
            result
                .and_then(|r| r.get("sessionId"))
                .and_then(Value::as_str)
        } else {
            route.params.get("sessionId").and_then(Value::as_str)
        };
        let Some(sid) = sid.filter(|s| !s.is_empty()) else {
            return;
        };
        if self.session_id.is_none() {
            self.session_id = Some(sid.to_string());
            self.info.session_id = Some(sid.to_string());
            self.setup = result.cloned().unwrap_or_else(|| Value::Object(Map::new()));
            out.dirty = true;
        } else if self.session_id.as_deref() == Some(sid) {
            self.setup = result.cloned().unwrap_or(self.setup.clone());
        }
    }

    // -- helpers ------------------------------------------------------------

    fn live_clients(&self) -> impl Iterator<Item = u64> + '_ {
        self.clients.iter().filter(|(_, c)| c.live).map(|(c, _)| *c)
    }

    fn answerer(&self) -> Option<u64> {
        self.clients
            .iter()
            .filter(|(_, c)| c.live && !c.viewer)
            .max_by_key(|(_, c)| c.last_input_ms)
            .map(|(c, _)| *c)
            .or_else(|| self.live_clients().next())
    }

    fn busy(&self) -> bool {
        self.routes.values().any(|r| r.prompt)
    }

    /// The agent is gone: close every client with the exit note and record it.
    pub fn agent_exited(&mut self, code: i32, reason: &str, out: &mut Out) {
        let line = json!({"jsonrpc":"2.0","method":method::HERDR_AGENT_EXITED,"params":{"exitCode":code,"reason":reason}}).to_string();
        for c in self.clients.keys().copied() {
            out.to_client(c, line.clone());
        }
        // A request the agent never answered is gone with it (python `finish`).
        let cancelled: Vec<(String, String)> = self
            .pending
            .values()
            .map(|h| (h.method.clone(), h.kid.clone()))
            .collect();
        for (method, kid) in &cancelled {
            self.dlog(&format!(
                "pending {method} {kid} cancelled: the agent exited"
            ));
        }
        self.pending.clear();
        self.info.state = State::Exited;
        self.info.extra.insert("exit_code".to_string(), json!(code));
        self.info.exit_reason = Some(reason.to_string());
        self.info.exited_at = Some(now_ms());
        self.info.pending = 0;
        out.dirty = true;
    }
}

/// The text an alert is about: a permission request's tool title (else its
/// kind), a question's message; cut by the hook's redaction, not here.
fn summarize(method_name: &str, params: &Value) -> String {
    let text = |v: Option<&Value>| {
        v.and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    if method_name == method::REQUEST_PERMISSION {
        let call = params.get("toolCall").filter(|c| c.is_object());
        return call
            .and_then(|c| text(c.get("title")).or_else(|| text(c.get("kind"))))
            .unwrap_or_else(|| "permission request".to_string());
    }
    text(params.get("message")).unwrap_or_else(|| "question".to_string())
}

/// What a JSON-RPC id points at, for comparing an `Id` to a `Value`.
fn target_id(v: &Value) -> Id {
    match v {
        Value::String(s) => Id::Str(s.clone()),
        Value::Number(n) => Id::Num(n.as_i64().unwrap_or(0)),
        _ => Id::Num(0),
    }
}

fn state_update_line(sid: &str, state: &str, stop: Option<&str>) -> String {
    let mut upd = Map::new();
    upd.insert("sessionUpdate".into(), json!("state_update"));
    upd.insert("state".into(), json!(state));
    if let Some(s) = stop {
        upd.insert("stopReason".into(), json!(s));
    }
    json!({"jsonrpc":"2.0","method":method::SESSION_UPDATE,"params":{"sessionId":sid,"update":upd}})
        .to_string()
}

fn answer_of(method: &str, params: &Value, result: &Value) -> String {
    // What a client answered, in words for the other clients (python
    // `answer_of`): a question's action, or the chosen option's name.
    if method == "elicitation/create" {
        return result
            .get("action")
            .and_then(Value::as_str)
            .filter(|a| !a.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| "cancel".to_string());
    }
    let out = result.get("outcome").unwrap_or(&Value::Null);
    if out.get("outcome").and_then(Value::as_str) != Some("selected") {
        return "cancelled".to_string();
    }
    let oid = out.get("optionId").and_then(Value::as_str);
    let Some(oid) = oid else {
        return "cancelled".to_string();
    };
    // The chosen option's name, from the request's options (python `answer_of`).
    let options = params.get("options").and_then(Value::as_array);
    for o in options.into_iter().flatten() {
        if o.get("optionId").and_then(Value::as_str) == Some(oid) {
            if let Some(name) = o.get("name").and_then(Value::as_str) {
                return name.to_string();
            }
        }
    }
    oid.to_string()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// The first `n` chars of a line, for a diagnostic (python `trunc`).
pub(crate) fn trunc(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// `[{const, title}]` of Cursor's `{id, label}` options (python `cursor_choices`).
fn cursor_choices(options: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for o in options.as_array().into_iter().flatten() {
        let Some(id) = o.get("id").and_then(Value::as_str) else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        let label = o
            .get("label")
            .and_then(Value::as_str)
            .filter(|l| !l.is_empty())
            .unwrap_or(id);
        out.push(json!({"const": id, "title": label}));
    }
    out
}

/// `cursor/ask_question` as the `elicitation/create` the phone shows
/// (python `cursor_ask_to_elicitation`). `None` when there is no question.
fn cursor_ask_to_elicitation(params: &Value, session_id: Option<&str>) -> Option<Value> {
    let mut props: Vec<(String, Value)> = Vec::new();
    for q in params
        .get("questions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(qid) = q.get("id").and_then(Value::as_str) else {
            continue;
        };
        if qid.is_empty() {
            continue;
        }
        let opts = cursor_choices(q.get("options").unwrap_or(&Value::Null));
        if opts.is_empty() {
            continue;
        }
        let title = q
            .get("prompt")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
            .unwrap_or(qid)
            .to_string();
        let prop = if q.get("allowMultiple").and_then(Value::as_bool) == Some(true) {
            json!({"type":"array","title":title,"items":{"anyOf":opts}})
        } else {
            json!({"type":"string","title":title,"oneOf":opts})
        };
        props.push((qid.to_string(), prop));
    }
    if props.is_empty() {
        return None;
    }
    let mut map = Map::new();
    let mut required = Vec::new();
    for (k, v) in &props {
        map.insert(k.clone(), v.clone());
        required.push(json!(k));
    }
    let title = params
        .get("title")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .unwrap_or("Cursor has a question");
    Some(json!({
        "sessionId": session_id,
        "mode": "form",
        "toolCallId": params.get("toolCallId"),
        "message": title,
        "requestedSchema": {"type":"object","properties":map,"required":required},
    }))
}

/// What goes back to Cursor for the phone's answer (python `cursor_ask_result`).
fn cursor_ask_result(result: &Value, orig: &Value) -> Value {
    let action = result.get("action").and_then(Value::as_str);
    if action == Some("decline") {
        return json!({"outcome":{"outcome":"skipped"}});
    }
    let Some(content) = result.get("content") else {
        return json!({"outcome":{"outcome":"cancelled"}});
    };
    if action != Some("accept") || !content.is_object() {
        return json!({"outcome":{"outcome":"cancelled"}});
    }
    let mut answers = Vec::new();
    for q in orig
        .get("questions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(qid) = q.get("id").and_then(Value::as_str) else {
            continue;
        };
        let Some(v) = content.get(qid) else {
            continue;
        };
        let ids = if let Some(list) = v.as_array() {
            list.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()
        } else if let Some(s) = v.as_str() {
            vec![s.to_string()]
        } else {
            Vec::new()
        };
        answers.push(json!({"questionId":qid,"selectedOptionIds":ids}));
    }
    json!({"outcome":{"outcome":"answered","answers":answers}})
}

/// `cursor/create_plan` as a `session/request_permission` (python
/// `cursor_plan_to_permission`). `None` when there is no plan.
fn cursor_plan_to_permission(params: &Value, session_id: Option<&str>) -> Option<Value> {
    let plan = params.get("plan").and_then(Value::as_str)?;
    if plan.trim().is_empty() {
        return None;
    }
    let name = params.get("name").and_then(Value::as_str);
    let overview = params.get("overview").and_then(Value::as_str);
    let text = if let Some(o) = overview.filter(|o| !o.is_empty()) {
        format!("{o}\n\n{plan}")
    } else {
        plan.to_string()
    };
    Some(json!({
        "sessionId": session_id,
        "toolCall": {
            "toolCallId": params.get("toolCallId"),
            "title": format!("Approve plan: {}", name.filter(|n| !n.is_empty()).unwrap_or("plan")),
            "kind": "switch_mode",
            "status": "pending",
            "content": [{"type":"content","content":{"type":"text","text":text}}],
            "rawInput": {"plan": text},
        },
        "options": [
            {"optionId":"accept","name":"Approve plan","kind":"allow_once"},
            {"optionId":"reject","name":"Reject plan","kind":"reject_once"},
        ],
    }))
}

/// Accepted only when the person chose "Approve plan" (python `cursor_plan_result`).
fn cursor_plan_result(result: &Value) -> Value {
    let out = result.get("outcome").unwrap_or(&Value::Null);
    if out.get("outcome").and_then(Value::as_str) == Some("selected") {
        match out.get("optionId").and_then(Value::as_str) {
            Some("accept") => return json!({"outcome":{"outcome":"accepted"}}),
            Some("reject") => return json!({"outcome":{"outcome":"rejected"}}),
            _ => {}
        }
    }
    json!({"outcome":{"outcome":"cancelled"}})
}

/// The `tool_call_update` for a finished subagent task (python
/// `cursor_task_update`). `None` when it names no tool call.
fn cursor_task_update(params: &Value) -> Option<Value> {
    let tcid = params.get("toolCallId").and_then(Value::as_str)?;
    if tcid.is_empty() {
        return None;
    }
    let mut task = Map::new();
    for key in ["description", "model", "agentId"] {
        if let Some(s) = params.get(key).and_then(Value::as_str) {
            task.insert(key.into(), json!(s));
        }
    }
    let mut kind = params.get("subagentType").cloned().unwrap_or(Value::Null);
    if let Some(custom) = kind.get("custom").and_then(Value::as_str) {
        kind = json!(custom);
    }
    if let Some(k) = kind.as_str() {
        task.insert("subagentType".into(), json!(k));
    }
    if let Some(ms) = params.get("durationMs") {
        if ms.is_u64() || ms.is_i64() {
            task.insert("durationMs".into(), ms.clone());
        }
    }
    Some(
        json!({"sessionUpdate":"tool_call_update","toolCallId":tcid,"_meta":{"cursor":{"task":task}}}),
    )
}

/// Why `authenticate` failed, for the person (python `cursor_sign_in_reason`):
/// the agent's reason (Cursor puts it in `data.message`), cut before any link
/// (it points at a browser on that computer) and to its first sentence, then
/// the next step.
fn cursor_sign_in_reason(err: &RpcError) -> String {
    let mut more = err
        .data
        .as_ref()
        .and_then(|d| d.get("message"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_default();
    if !more.is_empty() {
        if let Some(cut) = more.find("http") {
            more.truncate(cut);
        }
        let s = more.trim().to_string();
        more = match s.find(". ") {
            Some(dot) => s[..dot].to_string(),
            None => s,
        };
        let s = more.trim_end_matches([' ', ':', ';', ',', '.']).to_string();
        more = s;
    }
    if more.is_empty() {
        more = err.message.trim().to_string();
    }
    let more = trunc(more.trim().trim_end_matches('.'), 300);
    let more = if more.is_empty() {
        "no reason given".to_string()
    } else {
        more
    };
    format!(
        "{more}. Sign in on that computer first (run the agent's login command), then start again."
    )
}

fn rand64() -> u64 {
    let mut b = [0u8; 8];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut b);
    }
    u64::from_le_bytes(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The lines queued for `client`, as JSON.
    fn lines(out: &Out, client: u64) -> Vec<Value> {
        out.clients
            .get(&client)
            .map(|l| {
                l.iter()
                    .map(|s| serde_json::from_str(s).expect("a JSON line"))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// A request goes to a client BEFORE the prompt it is about, for a client that did not send
    /// the prompt: the agent may ask before it says anything (python `on_agent_request` starts
    /// with `flush_stash`).
    #[test]
    fn a_request_follows_the_prompt_it_is_about_for_the_other_client() {
        let mut r = Router::new("abc123".into(), "omp".into(), "/w".into(), "ep".into());
        let mut out = Out::default();
        let (a, b) = (r.add_client(&mut out), r.add_client(&mut out));
        // The agent has answered `initialize`; A opens the session, B loads it.
        r.on_agent_line(
            &json!({"jsonrpc":"2.0","id":INIT_ID,"result":{"protocolVersion":1}}).to_string(),
            &mut out,
        );
        let send = |r: &mut Router, c: u64, v: Value| {
            let mut out = Out::default();
            r.on_client_line(c, &v.to_string(), &mut out);
            out
        };
        let made = send(
            &mut r,
            a,
            json!({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/w","mcpServers":[]}}),
        );
        let oid = match made.agent.first().map(|l| serde_json::from_str::<Value>(l)) {
            Some(Ok(v)) => v["id"].clone(),
            other => panic!("session/new reaches the agent: {other:?}"),
        };
        let mut out = Out::default();
        r.on_agent_line(
            &json!({"jsonrpc":"2.0","id":oid,"result":{"sessionId":"s1"}}).to_string(),
            &mut out,
        );
        send(
            &mut r,
            b,
            json!({"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"s1","cwd":"/w","mcpServers":[]}}),
        );
        send(
            &mut r,
            a,
            json!({"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s1","prompt":[{"type":"text","text":"perm:ls"}]}}),
        );
        // The agent asks at once, before any update.
        let mut out = Out::default();
        r.on_agent_line(
            &json!({"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{
                "sessionId":"s1","toolCall":{"toolCallId":"t1","title":"ls"},"options":[]}})
            .to_string(),
            &mut out,
        );
        let seen: Vec<String> = lines(&out, b)
            .iter()
            .map(|v| {
                v["method"].as_str().map_or_else(String::new, |m| {
                    format!(
                        "{m}:{}",
                        v["params"]["update"]["sessionUpdate"]
                            .as_str()
                            .unwrap_or("")
                    )
                })
            })
            .collect();
        assert_eq!(
            seen,
            [
                "session/update:user_message_chunk",
                "session/request_permission:"
            ],
            "B sees the prompt first"
        );
        assert_eq!(
            lines(&out, a).len(),
            1,
            "A sent the prompt: it gets only the request"
        );
    }
}
