//! The client side of one keeper session: handshake, load or create, prompts,
//! permission requests and questions. Pure: events and the time go in, [`Effect`]s
//! come out, and the I/O layer carries them out. That keeps every rule here testable
//! without a socket, a thread or a clock.

use crate::attach::{self, Attachment};
use crate::question::{self, Act, Form};
use crate::transcript::Transcript;
use acp::{code, method, Id, Message, PermissionRequest, RpcError, SessionUpdate};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;

/// A request is not answered by a key pressed this soon after it appeared: that
/// key was meant for what was on screen before (the composer).
pub const ANSWER_GUARD_MS: u64 = 400;
/// How long to wait before asking again for a session the phone has not opened yet.
const RETRY_AFTER: Duration = Duration::from_secs(1);

/// How the session starts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Start {
    /// The keeper already has (or will soon have) a session: load it.
    Attach,
    /// A new keeper with no session yet: create one in this folder.
    Create { cwd: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Waiting for the keeper to answer `initialize`.
    Initializing,
    /// Waiting for the keeper's record to name a session.
    WaitingForSession,
    /// `session/load` (replay) or `session/new` is in flight.
    Opening,
    Ready,
    /// Over, with the reason in words.
    Ended(String),
}

/// What the I/O layer should do.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Send(Message),
    /// Read the keeper's record and answer with [`Event::Record`].
    ReadRecord,
    /// Answer with [`Event::Retry`] after this long.
    RetryIn(Duration),
    /// Put this text and these files back in the input: they were not sent.
    RestoreInput(String, Vec<Attachment>),
    /// A queued message was refused: it goes back to the front of the queue, held, for `why`.
    RestoreQueued {
        id: u64,
        text: String,
        files: Vec<Attachment>,
        why: String,
    },
}

/// What reached the session.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Message(Message),
    /// The keeper's record, or `None` when it cannot be read.
    Record(Option<Record>),
    Retry,
    /// The connection closed.
    Closed,
}

/// The parts of the keeper's record the session needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub session_id: Option<String>,
    pub cwd: String,
    /// The reason, when the keeper's agent has exited.
    pub exited: Option<String>,
}

/// What a waiting request asks.
#[derive(Clone, Debug, PartialEq)]
pub enum Ask {
    Permission(PermissionRequest),
    /// A question in form mode, with the person's answers so far.
    Question(Form),
}

/// A request waiting for the person.
#[derive(Clone, Debug, PartialEq)]
pub struct Waiting {
    pub id: Id,
    pub ask: Ask,
    pub arrived_ms: u64,
}

impl Waiting {
    #[must_use]
    pub fn permission(&self) -> Option<&PermissionRequest> {
        match &self.ask {
            Ask::Permission(r) => Some(r),
            Ask::Question(_) => None,
        }
    }
    #[must_use]
    pub fn question(&self) -> Option<&Form> {
        match &self.ask {
            Ask::Question(f) => Some(f),
            Ask::Permission(_) => None,
        }
    }
}

/// Why the person's action did nothing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refused {
    NotReady,
    /// A prompt is already in flight.
    Busy,
    /// A key came too soon after the request appeared.
    TooSoon,
    NoSuchOption,
    NothingWaiting,
    /// The request on the person's screen is no longer the one that waits: their key was meant
    /// for another.
    Changed,
    /// The session is over; nothing can reach the agent.
    Ended,
    /// The question's field does not take what was given, and why, in the person's words.
    Invalid(String),
}

#[derive(Debug)]
enum Call {
    Init,
    Load,
    New,
    Prompt {
        text: String,
        files: Vec<Attachment>,
        /// The id of the queued message this prompt carries, when it came from the queue.
        queued: Option<u64>,
    },
    /// A change of one select option (the model, the thinking level, the mode): the option's
    /// id and the value asked for, and the names the person sees, for the note.
    SetConfig {
        config_id: String,
        value: String,
        what: String,
        choice: String,
    },
}

#[derive(Debug)]
pub struct Session {
    start: Start,
    phase: Phase,
    sid: Option<String>,
    next_id: i64,
    calls: HashMap<i64, Call>,
    waiting: Vec<Waiting>,
    /// The `_meta.herdr.pane` the keeper is told about, when run inside a herdr pane.
    pane: Option<String>,
    /// The agent takes pictures in a prompt (`promptCapabilities.image`, from `initialize`).
    images: bool,
}

impl Session {
    /// A session and the effects that begin it.
    #[must_use]
    pub fn begin(start: Start, pane: Option<String>) -> (Session, Vec<Effect>) {
        let mut s = Session {
            start,
            phase: Phase::Initializing,
            sid: None,
            next_id: 0,
            calls: HashMap::new(),
            waiting: Vec::new(),
            pane,
            images: false,
        };
        let mut meta = json!({"viewer": true});
        if let Some(p) = &s.pane {
            meta["pane"] = json!(p);
        }
        let init = s.call(
            Call::Init,
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientCapabilities": {},
                   "clientInfo": {"name": "herdr-tui", "title": format!("Terminal on {}", crate::host::short_host()), "version": crate::cli::VERSION},
                   "_meta": {"herdr": meta}}),
        );
        (s, vec![init])
    }

    #[must_use]
    pub fn phase(&self) -> &Phase {
        &self.phase
    }
    #[must_use]
    pub fn session_id(&self) -> Option<&str> {
        self.sid.as_deref()
    }
    /// The oldest request waiting, and how many wait in all.
    #[must_use]
    pub fn waiting(&self) -> &[Waiting] {
        &self.waiting
    }
    /// Whether the request on screen is a permission, the only kind that digits, Tab and the
    /// arrows answer or walk. On a question they belong to the box (a typed field) or to the
    /// question's own keys.
    #[must_use]
    pub fn permission_waiting(&self) -> bool {
        self.waiting
            .first()
            .is_some_and(|w| w.permission().is_some())
    }
    /// Whether the agent takes pictures in a prompt.
    #[must_use]
    pub fn accepts_pictures(&self) -> bool {
        self.images
    }
    #[must_use]
    pub fn ready(&self) -> bool {
        self.phase == Phase::Ready
    }
    /// Whether a prompt is in flight.
    #[must_use]
    pub fn prompting(&self) -> bool {
        self.calls
            .values()
            .any(|c| matches!(c, Call::Prompt { .. }))
    }

    fn call(&mut self, call: Call, method: &str, params: Value) -> Effect {
        self.next_id += 1;
        self.calls.insert(self.next_id, call);
        Effect::Send(Message::request(self.next_id, method, params))
    }

    fn is_ended(&self) -> bool {
        matches!(self.phase, Phase::Ended(_))
    }

    fn end(&mut self, reason: impl Into<String>) {
        if !matches!(self.phase, Phase::Ended(_)) {
            self.phase = Phase::Ended(reason.into());
            // A request can no longer be answered: do not leave it asking.
            self.waiting.clear();
        }
    }

    /// Handles one event.
    pub fn handle(&mut self, ev: Event, now_ms: u64, tr: &mut Transcript) -> Vec<Effect> {
        match ev {
            Event::Closed => {
                self.end("the keeper closed the connection");
                Vec::new()
            }
            // Once over, it stays over: a late answer to an old call must not bring it back.
            Event::Retry | Event::Record(_) | Event::Message(Message::Response { .. })
                if self.is_ended() =>
            {
                Vec::new()
            }
            Event::Retry => self.read_record_if_waiting(),
            Event::Record(rec) => self.record(rec),
            Event::Message(Message::Response {
                id: Id::Num(n),
                outcome,
            }) => self.response(n, outcome, tr),
            Event::Message(Message::Response { .. }) => Vec::new(),
            Event::Message(Message::Notification { method, params }) => {
                self.notification(&method, &params, now_ms, tr);
                Vec::new()
            }
            Event::Message(Message::Request { id, method, params }) => {
                self.request(id, &method, &params, now_ms, tr)
            }
        }
    }

    fn read_record_if_waiting(&self) -> Vec<Effect> {
        if self.phase == Phase::WaitingForSession {
            vec![Effect::ReadRecord]
        } else {
            Vec::new()
        }
    }

    fn record(&mut self, rec: Option<Record>) -> Vec<Effect> {
        if self.phase != Phase::WaitingForSession {
            return Vec::new();
        }
        let Some(rec) = rec else {
            self.end("the keeper's record cannot be read");
            return Vec::new();
        };
        if let Some(reason) = rec.exited {
            self.end(reason);
            return Vec::new();
        }
        match rec.session_id {
            Some(sid) => {
                self.sid = Some(sid.clone());
                self.phase = Phase::Opening;
                vec![self.call(
                    Call::Load,
                    method::SESSION_LOAD,
                    json!({"sessionId": sid, "cwd": rec.cwd, "mcpServers": []}),
                )]
            }
            // The phone opens the session just after the start: ask again shortly.
            None => vec![Effect::RetryIn(RETRY_AFTER)],
        }
    }

    fn response(
        &mut self,
        n: i64,
        outcome: Result<Value, RpcError>,
        tr: &mut Transcript,
    ) -> Vec<Effect> {
        let Some(call) = self.calls.remove(&n) else {
            return Vec::new();
        };
        match (call, outcome) {
            (Call::Init, Err(e)) => {
                self.end(format!("the keeper refused this terminal ({})", e.message));
                Vec::new()
            }
            (Call::Init, Ok(init)) => {
                // A boolean `true`, as on the phone (`_b(prompt['image'])`).
                self.images = init
                    .pointer("/agentCapabilities/promptCapabilities/image")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                match self.start.clone() {
                    Start::Attach => {
                        self.phase = Phase::WaitingForSession;
                        vec![Effect::ReadRecord]
                    }
                    Start::Create { cwd } => {
                        self.phase = Phase::Opening;
                        vec![self.call(
                            Call::New,
                            method::SESSION_NEW,
                            json!({"cwd": cwd, "mcpServers": []}),
                        )]
                    }
                }
            }
            (Call::Load, Err(e)) | (Call::New, Err(e)) => {
                self.end(format!("the session did not open ({})", e.message));
                Vec::new()
            }
            (Call::Load, Ok(result)) => {
                self.phase = Phase::Ready;
                Self::config_from(&result, tr);
                Vec::new()
            }
            (Call::New, Ok(result)) => {
                Self::config_from(&result, tr);
                match result.get("sessionId").and_then(Value::as_str) {
                    Some(sid) => {
                        self.sid = Some(sid.to_string());
                        self.phase = Phase::Ready;
                    }
                    None => self.end("the agent opened no session"),
                }
                Vec::new()
            }
            (
                Call::Prompt {
                    text,
                    files,
                    queued,
                },
                Err(e),
            ) => {
                // A prompt the agent refused outright is a failed turn: a queue behind it holds.
                if e.code != code::SESSION_BUSY {
                    tr.set_stop("error");
                }
                tr.note(if e.code == code::SESSION_BUSY {
                    "The agent is busy; not sent".to_string()
                } else {
                    format!("Not sent: {}", e.message)
                });
                match queued {
                    Some(id) => vec![Effect::RestoreQueued {
                        id,
                        text,
                        files,
                        why: if e.code == code::SESSION_BUSY {
                            "the agent was busy".to_string()
                        } else {
                            e.message
                        },
                    }],
                    None => vec![Effect::RestoreInput(text, files)],
                }
            }
            (Call::Prompt { .. }, Ok(result)) => {
                tr.turn_end(result.get("stopReason").and_then(Value::as_str));
                Vec::new()
            }
            (
                Call::SetConfig {
                    config_id,
                    value,
                    what,
                    choice,
                },
                Ok(result),
            ) => {
                // The answer carries every option as it stands now; an agent that sends none is
                // taken at its word for the one that changed.
                let opts =
                    acp::parse_config_options(result.get("configOptions").unwrap_or(&Value::Null));
                if opts.is_empty() {
                    tr.set_current(&config_id, &value);
                } else {
                    tr.apply(SessionUpdate::Config(opts));
                }
                tr.note(format!("{what}: {choice}"));
                Vec::new()
            }
            (Call::SetConfig { what, .. }, Err(e)) => {
                tr.note(format!(
                    "Could not change {}: {}",
                    what.to_lowercase(),
                    e.message
                ));
                Vec::new()
            }
        }
    }

    /// The model, mode and thinking level an agent reports in its answer to `session/new` or `load`.
    fn config_from(result: &Value, tr: &mut Transcript) {
        let mut opts =
            acp::parse_config_options(result.get("configOptions").unwrap_or(&Value::Null));
        if !opts.iter().any(|o| o.is("model")) {
            opts.extend(acp::legacy_models(result));
        }
        if !opts.is_empty() {
            tr.apply(SessionUpdate::Config(opts));
        }
    }

    fn notification(&mut self, name: &str, p: &Value, now_ms: u64, tr: &mut Transcript) {
        match name {
            method::SESSION_UPDATE
                if p.get("sessionId").and_then(Value::as_str) == self.sid.as_deref() =>
            {
                if let Some(u) = p.get("update").and_then(SessionUpdate::from_value) {
                    tr.apply(u);
                }
            }
            method::HERDR_RESOLVED => {
                self.forget(p.get("requestId"), now_ms);
                let by = p
                    .get("by")
                    .and_then(Value::as_str)
                    .unwrap_or("another client");
                let answer = p.get("answer").and_then(Value::as_str).unwrap_or("?");
                tr.note(format!("Answered in {by}: {answer}"));
            }
            method::CANCEL_REQUEST => self.forget(p.get("requestId"), now_ms),
            method::HERDR_AGENT_EXITED => self.end(
                p.get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("the agent exited"),
            ),
            _ => {}
        }
    }

    fn forget(&mut self, request_id: Option<&Value>, now_ms: u64) {
        if let Some(id) = request_id.and_then(|v| serde_json::from_value::<Id>(v.clone()).ok()) {
            let head = self.waiting.first().map(|w| w.id.clone());
            self.waiting.retain(|w| w.id != id);
            self.promote(head, now_ms);
        }
    }

    /// A request that becomes the head was not on screen until now, so its guard window starts now:
    /// a key aimed at the one before it must not answer it.
    fn promote(&mut self, was_head: Option<Id>, now_ms: u64) {
        if let Some(head) = self.waiting.first_mut() {
            if Some(&head.id) != was_head.as_ref() {
                head.arrived_ms = now_ms;
            }
        }
    }

    fn request(
        &mut self,
        id: Id,
        name: &str,
        p: &Value,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Vec<Effect> {
        match name {
            method::REQUEST_PERMISSION => {
                self.hold(
                    id,
                    Ask::Permission(PermissionRequest::from_params(p)),
                    now_ms,
                );
                Vec::new()
            }
            method::ELICITATION_CREATE => {
                match Form::parse(p, now_ms) {
                    Some(form) => self.hold(id, Ask::Question(form), now_ms),
                    // The keeper gives a question to every client and forwards the first answer
                    // (its held questions), so this terminal is never the one expected to
                    // answer. A refusal here (the phone's invalidParams) would be that first
                    // answer and take the question from the phone, so a mode it cannot show is
                    // only noted and left to the phone.
                    None => {
                        let q = p.get("message").and_then(Value::as_str).unwrap_or("");
                        tr.note(format!("Question: {q} (answer it on the phone)"));
                    }
                }
                Vec::new()
            }
            other => vec![Effect::Send(Message::error(
                id,
                RpcError::new(
                    code::METHOD_NOT_FOUND,
                    format!("A terminal view does not answer {other}."),
                ),
            ))],
        }
    }

    /// Queues a request, once: the keeper may give the same one again.
    fn hold(&mut self, id: Id, ask: Ask, now_ms: u64) {
        if !self.waiting.iter().any(|w| w.id == id) {
            self.waiting.push(Waiting {
                id,
                ask,
                arrived_ms: now_ms,
            });
        }
    }

    /// The person sends a message.
    ///
    /// # Errors
    /// [`Refused::NotReady`] before the session is open, [`Refused::Busy`] while a prompt is in flight.
    /// The text and the files are then still the caller's to keep.
    pub fn send(
        &mut self,
        text: &str,
        files: &[Attachment],
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.prompt(text, files, None, tr)
    }

    /// The message `id` of the queue goes out. Same refusals as [`Session::send`]; if the agent
    /// refuses it later, [`Effect::RestoreQueued`] says so (the box is the person's, not this
    /// message's).
    ///
    /// # Errors
    /// As [`Session::send`].
    pub fn send_queued(
        &mut self,
        id: u64,
        text: &str,
        files: &[Attachment],
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.prompt(text, files, Some(id), tr)
    }

    fn prompt(
        &mut self,
        text: &str,
        files: &[Attachment],
        queued: Option<u64>,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        if !self.ready() {
            return Err(Refused::NotReady);
        }
        if self.prompting() {
            return Err(Refused::Busy);
        }
        let sid = self.sid.clone().ok_or(Refused::NotReady)?;
        tr.user(attach::echo(text, files));
        Ok(vec![self.call(
            Call::Prompt {
                text: text.to_string(),
                // The picture bytes are not kept for the whole turn: a refused send gives the
                // files back, and they are read again when it is sent again.
                files: files
                    .iter()
                    .map(|f| Attachment {
                        data: None,
                        ..f.clone()
                    })
                    .collect(),
                queued,
            },
            method::SESSION_PROMPT,
            json!({"sessionId": sid, "prompt": attach::blocks(text, files, self.images)}),
        )])
    }

    /// The person changes one select option of the session (`session/set_config_option`, as the
    /// phone does). `what` and `choice` are the names they saw, for the note that follows.
    ///
    /// # Errors
    /// [`Refused::NotReady`] before the session is open, [`Refused::Busy`] while a turn runs.
    pub fn set_config(
        &mut self,
        config_id: &str,
        value: &str,
        what: &str,
        choice: &str,
        tr: &Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        if !self.ready() {
            return Err(Refused::NotReady);
        }
        if self.prompting() || tr.running() {
            return Err(Refused::Busy);
        }
        let sid = self.sid.clone().ok_or(Refused::NotReady)?;
        Ok(vec![self.call(
            Call::SetConfig {
                config_id: config_id.to_string(),
                value: value.to_string(),
                what: what.to_string(),
                choice: choice.to_string(),
            },
            method::SESSION_SET_CONFIG_OPTION,
            json!({"sessionId": sid, "configId": config_id, "value": value}),
        )])
    }

    /// The person asks the agent to stop.
    pub fn cancel(&mut self, tr: &mut Transcript) -> Vec<Effect> {
        let Some(sid) = &self.sid else {
            return Vec::new();
        };
        tr.note("Asked the agent to stop");
        // ACP: a client that cancels a turn answers every request still open as cancelled. Left
        // asking, they could be approved after the person said stop.
        let mut effects: Vec<Effect> = self
            .waiting
            .drain(..)
            .map(|w| {
                let result = match w.ask {
                    Ask::Permission(_) => acp::outcome_cancelled(),
                    Ask::Question(_) => question::cancelled(),
                };
                Effect::Send(Message::result(w.id, result))
            })
            .collect();
        effects.push(Effect::Send(Message::notification(
            method::SESSION_CANCEL,
            json!({"sessionId": sid}),
        )));
        effects
    }

    /// The person answers the oldest waiting request with option `index`.
    ///
    /// # Errors
    /// [`Refused::NothingWaiting`], [`Refused::TooSoon`] within [`ANSWER_GUARD_MS`] of
    /// the request appearing, or [`Refused::NoSuchOption`].
    pub fn answer(
        &mut self,
        index: usize,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        if self.is_ended() {
            return Err(Refused::Ended);
        }
        let w = self.waiting.first().ok_or(Refused::NothingWaiting)?;
        if now_ms.saturating_sub(w.arrived_ms) < ANSWER_GUARD_MS {
            return Err(Refused::TooSoon);
        }
        let option = w
            .permission()
            .and_then(|r| r.options.get(index))
            .ok_or(Refused::NoSuchOption)?;
        let reply = Message::result(w.id.clone(), acp::outcome_selected(&option.id));
        tr.note(format!("Answered: {}", option.name));
        self.waiting.remove(0);
        self.promote(None, now_ms);
        Ok(vec![Effect::Send(reply)])
    }

    /// Answers the request `shown`, the one the person's screen last drew, and refuses when it is
    /// no longer the one that waits (it was answered elsewhere, and another took its place).
    ///
    /// # Errors
    /// [`Refused::Changed`] on a different request, else as [`Session::answer`].
    pub fn answer_for(
        &mut self,
        shown: &Id,
        index: usize,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.check_shown(shown)?;
        self.answer(index, now_ms, tr)
    }

    /// Withdraws the request on screen: a permission is answered `cancelled` (the way out of one
    /// that offers nothing to choose), a question is declined, as the phone's Decline does.
    ///
    /// # Errors
    /// As [`Session::answer_for`].
    pub fn dismiss_for(
        &mut self,
        shown: &Id,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.check_shown(shown)?;
        let w = self.waiting.first().ok_or(Refused::NothingWaiting)?;
        if now_ms.saturating_sub(w.arrived_ms) < ANSWER_GUARD_MS {
            return Err(Refused::TooSoon);
        }
        let (result, said) = match w.ask {
            Ask::Permission(_) => (acp::outcome_cancelled(), "Cancelled the request"),
            Ask::Question(_) => (question::declined(), "Declined the question"),
        };
        let reply = Message::result(w.id.clone(), result);
        tr.note(said);
        self.waiting.remove(0);
        self.promote(None, now_ms);
        Ok(vec![Effect::Send(reply)])
    }

    /// The person acts on the question `shown`, the one their screen last drew: moves the mark,
    /// ticks, goes back, or confirms a field. Confirming the last sends the answers. A key this
    /// soon after the question appeared, or a confirm this soon after the field did, was meant
    /// for what was on screen before and does nothing.
    ///
    /// # Errors
    /// As [`Session::answer_for`], [`Refused::Invalid`] with what is wrong with the field, and
    /// [`Refused::NoSuchOption`] when the request on screen is not a question.
    pub fn question_for(
        &mut self,
        shown: &Id,
        act: Act,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.check_shown(shown)?;
        let w = self.waiting.first_mut().ok_or(Refused::NothingWaiting)?;
        let arrived = w.arrived_ms;
        let Ask::Question(form) = &mut w.ask else {
            return Err(Refused::NoSuchOption);
        };
        let since = if form.confirms(&act) {
            arrived.max(form.since_ms())
        } else {
            arrived
        };
        if now_ms.saturating_sub(since) < ANSWER_GUARD_MS {
            return Err(Refused::TooSoon);
        }
        let Some(result) = form.act(act, now_ms).map_err(Refused::Invalid)? else {
            return Ok(Vec::new());
        };
        tr.note(format!("Answered: {}", form.summary()));
        let reply = Message::result(w.id.clone(), result);
        self.waiting.remove(0);
        self.promote(None, now_ms);
        Ok(vec![Effect::Send(reply)])
    }

    fn check_shown(&self, shown: &Id) -> Result<(), Refused> {
        if self.is_ended() {
            return Err(Refused::Ended);
        }
        match self.waiting.first() {
            None => Err(Refused::NothingWaiting),
            Some(w) if &w.id != shown => Err(Refused::Changed),
            Some(_) => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(n: i64, result: Value) -> Event {
        Event::Message(Message::result(Id::Num(n), result))
    }

    fn note(m: &str, params: Value) -> Event {
        Event::Message(Message::notification(m, params))
    }

    fn record(sid: Option<&str>) -> Event {
        Event::Record(Some(Record {
            session_id: sid.map(str::to_string),
            cwd: "/w".into(),
            exited: None,
        }))
    }

    /// A session attached and loaded, with its transcript.
    fn ready() -> (Session, Transcript) {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(record(Some("sess")), 0, &mut tr);
        s.handle(ok(2, json!({})), 0, &mut tr);
        assert!(s.ready());
        (s, tr)
    }

    fn permission(id: &str) -> Event {
        Event::Message(Message::request(
            id,
            method::REQUEST_PERMISSION,
            json!({"toolCall": {"toolCallId": "t", "title": "Run ls"}, "options": [{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject"}]}),
        ))
    }

    #[test]
    fn it_announces_itself_as_a_viewer_in_its_pane() {
        let (_, effects) = Session::begin(Start::Attach, Some("w1:p2".into()));
        let [Effect::Send(Message::Request { method, params, .. })] = effects.as_slice() else {
            panic!("one request")
        };
        assert_eq!(method, "initialize");
        assert_eq!(
            params["_meta"]["herdr"],
            json!({"viewer": true, "pane": "w1:p2"})
        );
    }

    #[test]
    fn attaching_reads_the_record_then_loads_the_session_in_its_folder() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        assert_eq!(s.handle(ok(1, json!({})), 0, &mut tr), [Effect::ReadRecord]);
        let fx = s.handle(record(Some("sess")), 0, &mut tr);
        let [Effect::Send(Message::Request { method, params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            (
                method.as_str(),
                params["sessionId"].as_str(),
                params["cwd"].as_str()
            ),
            ("session/load", Some("sess"), Some("/w"))
        );
        assert_eq!(s.phase(), &Phase::Opening);
    }

    #[test]
    fn a_session_the_phone_has_not_opened_yet_is_asked_for_again() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        assert_eq!(
            s.handle(record(None), 0, &mut tr),
            [Effect::RetryIn(RETRY_AFTER)]
        );
        assert_eq!(s.handle(Event::Retry, 0, &mut tr), [Effect::ReadRecord]);
        assert_eq!(s.phase(), &Phase::WaitingForSession);
    }

    #[test]
    fn the_model_the_agent_reports_when_it_opens_the_session_reaches_the_transcript() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Create { cwd: "/p".into() }, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(ok(2, json!({"sessionId": "x", "configOptions": [{"id": "model", "category": "model", "type": "select", "currentValue": "m", "options": [{"value": "m", "name": "Big Model"}]}]})), 0, &mut tr);
        assert_eq!(tr.model(), Some("Big Model"));
        // The older shape works too.
        let mut tr2 = Transcript::default();
        let (mut s2, _) = Session::begin(Start::Create { cwd: "/p".into() }, None);
        s2.handle(ok(1, json!({})), 0, &mut tr2);
        s2.handle(ok(2, json!({"sessionId": "x", "models": {"currentModelId": "q", "availableModels": [{"modelId": "q", "name": "Quick"}]}})), 0, &mut tr2);
        assert_eq!(tr2.model(), Some("Quick"));
    }

    #[test]
    fn creating_makes_a_session_in_the_folder_and_is_ready_when_it_answers() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(
            Start::Create {
                cwd: "/proj".into(),
            },
            None,
        );
        let fx = s.handle(ok(1, json!({})), 0, &mut tr);
        let [Effect::Send(Message::Request { method, params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            (method.as_str(), params["cwd"].as_str()),
            ("session/new", Some("/proj"))
        );
        s.handle(ok(2, json!({"sessionId": "fresh"})), 0, &mut tr);
        assert!(s.ready());
        assert_eq!(s.session_id(), Some("fresh"));
    }

    #[test]
    fn a_keeper_whose_agent_exited_ends_the_session_with_its_reason() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(
            Event::Record(Some(Record {
                session_id: Some("x".into()),
                cwd: "/".into(),
                exited: Some("exit 3".into()),
            })),
            0,
            &mut tr,
        );
        assert_eq!(s.phase(), &Phase::Ended("exit 3".into()));
    }

    #[test]
    fn updates_for_another_session_are_ignored() {
        let (mut s, mut tr) = ready();
        let upd = |sid: &str| {
            note(
                "session/update",
                json!({"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "messageId": "m", "content": {"type": "text", "text": "hi"}}}),
            )
        };
        s.handle(upd("other"), 0, &mut tr);
        assert!(tr.items().is_empty());
        s.handle(upd("sess"), 0, &mut tr);
        assert_eq!(tr.items().len(), 1);
    }

    #[test]
    fn sending_shows_the_message_and_only_one_prompt_is_in_flight() {
        let (mut s, mut tr) = ready();
        let fx = s.send("hello", &[], &mut tr).expect("sent");
        let [Effect::Send(Message::Request { method, params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            (method.as_str(), params["prompt"][0]["text"].as_str()),
            ("session/prompt", Some("hello"))
        );
        assert_eq!(tr.items().len(), 1);
        assert_eq!(s.send("again", &[], &mut tr), Err(Refused::Busy));
        assert_eq!(
            tr.items().len(),
            1,
            "a refused message is not shown as sent"
        );
    }

    #[test]
    fn a_prompt_in_flight_counts_as_working_even_when_the_agent_never_says_so() {
        let (mut s, mut tr) = ready();
        assert!(!s.prompting());
        s.send("hello", &[], &mut tr).expect("sent");
        assert!(s.prompting() && !tr.running());
        s.handle(ok(3, json!({"stopReason": "cancelled"})), 0, &mut tr);
        assert!(!s.prompting());
    }

    #[test]
    fn nothing_is_sent_before_the_session_is_open() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        assert_eq!(s.send("hi", &[], &mut tr), Err(Refused::NotReady));
    }

    #[test]
    fn a_refused_prompt_gives_its_text_back_and_says_why() {
        let (mut s, mut tr) = ready();
        s.send("hello", &[], &mut tr).expect("sent");
        let busy = Event::Message(Message::error(
            Id::Num(3),
            RpcError::new(code::SESSION_BUSY, "busy"),
        ));
        assert_eq!(
            s.handle(busy, 0, &mut tr),
            [Effect::RestoreInput("hello".into(), vec![])]
        );
        assert!(!s.prompting());
        assert!(
            matches!(&tr.items().back().expect("a note").entry, crate::transcript::Entry::Note(n) if n.contains("busy"))
        );
    }

    #[test]
    fn a_refused_queued_prompt_goes_back_to_the_queue_and_never_to_the_box() {
        let (mut s, mut tr) = ready();
        s.send_queued(7, "next", &[], &mut tr).expect("sent");
        let busy = Event::Message(Message::error(
            Id::Num(3),
            RpcError::new(code::SESSION_BUSY, "busy"),
        ));
        assert_eq!(
            s.handle(busy, 0, &mut tr),
            [Effect::RestoreQueued {
                id: 7,
                text: "next".into(),
                files: vec![],
                why: "the agent was busy".into(),
            }]
        );
        assert!(!s.prompting());
    }

    #[test]
    fn a_prompt_the_agent_fails_is_a_failed_turn_for_the_queue_but_a_busy_one_is_not() {
        let fail = |c: i64| {
            let (mut s, mut tr) = ready();
            s.send("hello", &[], &mut tr).expect("sent");
            s.handle(
                Event::Message(Message::error(Id::Num(3), RpcError::new(c, "no"))),
                0,
                &mut tr,
            );
            tr.take_stop()
        };
        assert_eq!(fail(code::METHOD_NOT_FOUND).as_deref(), Some("error"));
        assert_eq!(fail(code::SESSION_BUSY), None);
    }

    #[test]
    fn a_finished_prompt_ends_the_turn_and_frees_the_next_send() {
        let (mut s, mut tr) = ready();
        s.send("one", &[], &mut tr).expect("sent");
        s.handle(ok(3, json!({"stopReason": "end_turn"})), 0, &mut tr);
        assert!(s.send("two", &[], &mut tr).is_ok());
    }

    #[test]
    fn attached_files_go_as_links_after_the_text_and_come_back_with_it_when_refused() {
        let (mut s, mut tr) = ready();
        let f = attach::attachment("/w/src/a.rs", "/w");
        let fx = s
            .send("look", std::slice::from_ref(&f), &mut tr)
            .expect("sent");
        let [Effect::Send(Message::Request { params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            params["prompt"],
            json!([{"type": "text", "text": "look"}, {"type": "resource_link", "uri": "file:///w/src/a.rs", "name": "src/a.rs"}])
        );
        assert!(matches!(&tr.items().back().expect("echo").entry,
            crate::transcript::Entry::Message { text, .. } if text == "look\n@src/a.rs"));
        let busy = Event::Message(Message::error(
            Id::Num(3),
            RpcError::new(code::SESSION_BUSY, "busy"),
        ));
        assert_eq!(
            s.handle(busy, 0, &mut tr),
            [Effect::RestoreInput("look".into(), vec![f])]
        );
    }

    #[test]
    fn a_permission_cannot_be_answered_the_instant_it_appears() {
        let (mut s, mut tr) = ready();
        s.handle(permission("kp1"), 10_000, &mut tr);
        assert_eq!(
            s.answer(0, 10_000 + ANSWER_GUARD_MS - 1, &mut tr),
            Err(Refused::TooSoon)
        );
        assert_eq!(s.waiting().len(), 1);
        let fx = s
            .answer(0, 10_000 + ANSWER_GUARD_MS, &mut tr)
            .expect("answered");
        let [Effect::Send(Message::Response { id, outcome: Ok(r) })] = fx.as_slice() else {
            panic!("a result")
        };
        assert_eq!(
            (id, r["outcome"]["optionId"].as_str()),
            (&Id::from("kp1"), Some("a"))
        );
        assert!(s.waiting().is_empty());
    }

    #[test]
    fn requests_are_answered_in_order_and_a_repeated_one_is_not_queued_twice() {
        let (mut s, mut tr) = ready();
        s.handle(permission("kp1"), 0, &mut tr);
        s.handle(permission("kp1"), 0, &mut tr);
        s.handle(permission("kp2"), 0, &mut tr);
        assert_eq!(s.waiting().len(), 2);
        assert_eq!(s.answer(9, 1000, &mut tr), Err(Refused::NoSuchOption));
        s.answer(1, 1000, &mut tr).expect("answered");
        assert_eq!(s.waiting()[0].id, Id::from("kp2"));
    }

    #[test]
    fn a_request_answered_elsewhere_or_withdrawn_leaves_the_queue() {
        let (mut s, mut tr) = ready();
        s.handle(permission("kp1"), 0, &mut tr);
        s.handle(permission("kp2"), 0, &mut tr);
        s.handle(
            note(
                "_herdr/resolved",
                json!({"requestId": "kp1", "by": "herdr mobile", "answer": "Allow once"}),
            ),
            0,
            &mut tr,
        );
        assert_eq!(s.waiting().len(), 1);
        s.handle(
            note("$/cancel_request", json!({"requestId": "kp2"})),
            0,
            &mut tr,
        );
        assert!(s.waiting().is_empty());
        assert!(tr.items().iter().any(|i| matches!(&i.entry, crate::transcript::Entry::Note(n) if n == "Answered in herdr mobile: Allow once")));
    }

    #[test]
    fn a_request_it_cannot_answer_is_refused_with_an_error() {
        let (mut s, mut tr) = ready();
        let fx = s.handle(
            Event::Message(Message::request("kp9", "fs/read_text_file", json!({}))),
            0,
            &mut tr,
        );
        assert!(
            matches!(fx.as_slice(), [Effect::Send(Message::Response { outcome: Err(e), .. })] if e.code == code::METHOD_NOT_FOUND)
        );
    }

    #[test]
    fn closing_or_the_agent_exiting_ends_it_once_with_the_first_reason() {
        let (mut s, mut tr) = ready();
        s.handle(
            note("_herdr/agent_exited", json!({"reason": "exit 3"})),
            0,
            &mut tr,
        );
        s.handle(Event::Closed, 0, &mut tr);
        assert_eq!(s.phase(), &Phase::Ended("exit 3".into()));
    }

    fn two_options() -> Value {
        json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject", "kind": "reject_once"}])
    }

    fn ask_with(id: &str, options: Value) -> Event {
        Event::Message(Message::request(
            id,
            method::REQUEST_PERMISSION,
            json!({"toolCall": {"toolCallId": "t", "title": "x"}, "options": options}),
        ))
    }

    #[test]
    fn a_late_answer_to_an_old_call_cannot_bring_an_ended_session_back() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(record(Some("sess")), 0, &mut tr);
        s.handle(
            note("_herdr/agent_exited", json!({"reason": "exit 3"})),
            0,
            &mut tr,
        );
        s.handle(ok(2, json!({})), 0, &mut tr);
        s.handle(Event::Retry, 0, &mut tr);
        assert_eq!(s.phase(), &Phase::Ended("exit 3".into()));
        assert_eq!(s.send("x", &[], &mut tr), Err(Refused::NotReady));
    }

    #[test]
    fn a_key_meant_for_one_request_cannot_answer_the_one_that_took_its_place() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(ask_with("B", json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "ALWAYS", "name": "Always", "kind": "allow_always"}])), 100, &mut tr);
        // A is answered on the phone and B moves up; the person's key, aimed at A, lands a moment later.
        s.handle(
            note(
                "_herdr/resolved",
                json!({"requestId": "A", "by": "phone", "answer": "x"}),
            ),
            9000,
            &mut tr,
        );
        assert_eq!(
            s.answer_for(&Id::from("A"), 1, 9001, &mut tr),
            Err(Refused::Changed),
            "the screen showed A"
        );
        assert_eq!(
            s.answer_for(&Id::from("B"), 1, 9001, &mut tr),
            Err(Refused::TooSoon),
            "B has only just appeared"
        );
        assert!(
            s.answer_for(&Id::from("B"), 1, 9000 + ANSWER_GUARD_MS, &mut tr)
                .is_ok(),
            "once B has been on screen long enough"
        );
    }

    #[test]
    fn answering_the_head_starts_the_next_requests_guard_window() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(ask_with("B", two_options()), 0, &mut tr);
        s.answer_for(&Id::from("A"), 0, 5000, &mut tr)
            .expect("answered");
        assert_eq!(
            s.answer_for(&Id::from("B"), 0, 5000 + ANSWER_GUARD_MS - 1, &mut tr),
            Err(Refused::TooSoon)
        );
    }

    #[test]
    fn a_request_that_offers_nothing_to_choose_can_be_withdrawn() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("Z", json!([])), 0, &mut tr);
        assert_eq!(s.answer(0, 99_999, &mut tr), Err(Refused::NoSuchOption));
        let fx = s
            .dismiss_for(&Id::from("Z"), 99_999, &mut tr)
            .expect("withdrawn");
        assert!(
            matches!(fx.as_slice(), [Effect::Send(Message::Response { id, outcome: Ok(r) })] if id == &Id::from("Z") && r["outcome"]["outcome"] == "cancelled")
        );
        assert!(s.waiting().is_empty());
        assert_eq!(
            s.dismiss_for(&Id::from("Z"), 99_999, &mut tr),
            Err(Refused::NothingWaiting)
        );
    }

    #[test]
    fn stopping_the_turn_answers_every_open_request_as_cancelled() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(ask_with("B", two_options()), 0, &mut tr);
        let fx = s.cancel(&mut tr);
        let cancelled = fx.iter().filter(|e| matches!(e, Effect::Send(Message::Response { outcome: Ok(r), .. }) if r["outcome"]["outcome"] == "cancelled")).count();
        assert_eq!(cancelled, 2, "{fx:?}");
        assert!(
            matches!(fx.last(), Some(Effect::Send(Message::Notification { method, .. })) if method == "session/cancel")
        );
        assert!(s.waiting().is_empty(), "nothing left to approve after stop");
    }

    #[test]
    fn a_session_that_ended_asks_nothing_and_answers_nothing() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(Event::Closed, 0, &mut tr);
        assert!(s.waiting().is_empty(), "the panel goes with the link");
        s.handle(ask_with("B", two_options()), 0, &mut tr);
        assert_eq!(s.answer(0, 99_999, &mut tr), Err(Refused::Ended));
        assert_eq!(
            s.answer_for(&Id::from("B"), 0, 99_999, &mut tr),
            Err(Refused::Ended)
        );
        assert!(!tr.items().iter().any(|i| matches!(&i.entry, crate::transcript::Entry::Note(n) if n.starts_with("Answered"))), "no claim of an answer that went nowhere");
    }

    #[test]
    fn cancel_names_the_session() {
        let (mut s, mut tr) = ready();
        let fx = s.cancel(&mut tr);
        assert!(
            matches!(fx.as_slice(), [Effect::Send(Message::Notification { method, params })] if method == "session/cancel" && params["sessionId"] == "sess")
        );
    }

    /// An omp-style form with an enum, a boolean and a string.
    fn question(id: &str) -> Event {
        Event::Message(Message::request(
            id,
            method::ELICITATION_CREATE,
            json!({"sessionId": "sess", "mode": "form", "message": "Set up the run",
                   "requestedSchema": {"type": "object", "required": ["colour"], "properties": {
                       "colour": {"type": "string", "enum": ["red", "green", "blue"]},
                       "fast": {"type": "boolean"},
                       "note": {"type": "string"}}}}),
        ))
    }

    fn sent(fx: &[Effect]) -> Option<(&Id, &Value)> {
        match fx {
            [Effect::Send(Message::Response { id, outcome: Ok(r) })] => Some((id, r)),
            _ => None,
        }
    }

    #[test]
    fn a_question_is_walked_field_by_field_and_answered_with_what_was_chosen() {
        let (mut s, mut tr) = ready();
        s.handle(question("kq"), 10_000, &mut tr);
        assert!(s.waiting()[0].question().is_some());
        let q = Id::from("kq");
        let t = 10_000 + ANSWER_GUARD_MS;
        assert_eq!(
            s.question_for(&q, Act::Down, t - 1, &mut tr),
            Err(Refused::TooSoon),
            "a key meant for the composer does not touch it"
        );
        s.question_for(&q, Act::Pick(2), t, &mut tr)
            .expect("marked");
        assert_eq!(
            s.question_for(&q, Act::Enter(String::new()), t, &mut tr),
            Ok(Vec::new())
        );
        // A second Enter at once was aimed at the field that just went.
        assert_eq!(
            s.question_for(&q, Act::Enter(String::new()), t + 1, &mut tr),
            Err(Refused::TooSoon)
        );
        let t = t + ANSWER_GUARD_MS;
        s.question_for(&q, Act::Up, t, &mut tr).expect("Yes");
        s.question_for(&q, Act::Enter(String::new()), t, &mut tr)
            .expect("next");
        let t = t + ANSWER_GUARD_MS;
        let fx = s
            .question_for(&q, Act::Enter("ship it".into()), t, &mut tr)
            .expect("sent");
        assert_eq!(
            sent(&fx),
            Some((
                &q,
                &json!({"action": "accept", "content": {"colour": "blue", "fast": true, "note": "ship it"}})
            ))
        );
        assert!(s.waiting().is_empty());
        assert!(tr
            .items()
            .iter()
            .any(|i| matches!(&i.entry, crate::transcript::Entry::Note(n) if n.contains("blue"))));
    }

    #[test]
    fn a_wrong_answer_is_refused_with_its_reason_and_the_question_stays() {
        let (mut s, mut tr) = ready();
        s.handle(Event::Message(Message::request("kq", method::ELICITATION_CREATE,
            json!({"mode": "form", "message": "How many?", "requestedSchema": {"type": "object", "required": ["n"], "properties": {"n": {"type": "integer"}}}}))), 0, &mut tr);
        let q = Id::from("kq");
        assert!(matches!(
            s.question_for(&q, Act::Enter("lots".into()), 1000, &mut tr),
            Err(Refused::Invalid(_))
        ));
        let form = s.waiting()[0].question().expect("still asking");
        assert_eq!(form.text(), "lots", "the typed text is kept");
        let fx = s
            .question_for(&q, Act::Enter("3".into()), 2000, &mut tr)
            .expect("sent");
        assert_eq!(
            sent(&fx).map(|(_, r)| &r["content"]),
            Some(&json!({"n": 3}))
        );
    }

    #[test]
    fn a_question_answered_on_the_phone_leaves_and_a_key_meant_for_it_does_nothing() {
        let (mut s, mut tr) = ready();
        s.handle(question("A"), 0, &mut tr);
        s.handle(permission("B"), 0, &mut tr);
        s.handle(
            note(
                "_herdr/resolved",
                json!({"requestId": "A", "by": "herdr mobile", "answer": "accept"}),
            ),
            9000,
            &mut tr,
        );
        s.handle(
            note("$/cancel_request", json!({"requestId": "A"})),
            9000,
            &mut tr,
        );
        assert_eq!(s.waiting().len(), 1);
        assert_eq!(
            s.question_for(&Id::from("A"), Act::Enter(String::new()), 9001, &mut tr),
            Err(Refused::Changed)
        );
        assert_eq!(
            s.answer_for(&Id::from("B"), 0, 9001, &mut tr),
            Err(Refused::TooSoon),
            "the permission behind it has only just appeared"
        );
    }

    #[test]
    fn esc_declines_a_question_and_stopping_the_turn_cancels_it() {
        let (mut s, mut tr) = ready();
        s.handle(question("A"), 0, &mut tr);
        s.handle(question("B"), 0, &mut tr);
        let fx = s
            .dismiss_for(&Id::from("A"), 1000, &mut tr)
            .expect("declined");
        assert_eq!(
            sent(&fx).map(|(_, r)| r),
            Some(&json!({"action": "decline"}))
        );
        let fx = s.cancel(&mut tr);
        assert!(
            matches!(fx.first(), Some(Effect::Send(Message::Response { id, outcome: Ok(r) })) if id == &Id::from("B") && r == &json!({"action": "cancel"})),
            "{fx:?}"
        );
    }

    #[test]
    fn only_a_permission_on_screen_takes_the_permission_keys() {
        let (mut s, mut tr) = ready();
        assert!(!s.permission_waiting(), "nothing is waiting");
        s.handle(question("A"), 0, &mut tr);
        s.handle(permission("B"), 0, &mut tr);
        assert!(
            !s.permission_waiting(),
            "the question in front keeps its keys"
        );
        s.dismiss_for(&Id::from("A"), 1000, &mut tr)
            .expect("declined");
        assert!(s.permission_waiting());
    }

    #[test]
    fn a_question_this_terminal_cannot_show_is_left_to_the_phone() {
        let (mut s, mut tr) = ready();
        let fx = s.handle(
            Event::Message(Message::request(
                "kq",
                method::ELICITATION_CREATE,
                json!({"mode": "url", "url": "https://example.com", "message": "Sign in"}),
            )),
            0,
            &mut tr,
        );
        assert!(fx.is_empty(), "no answer: it would be the first and win");
        assert!(s.waiting().is_empty());
        assert_eq!(tr.items().len(), 1, "it is noted");
    }

    fn set_model(s: &mut Session, tr: &Transcript) -> (i64, Message) {
        let fx = s
            .set_config("model", "b", "Model", "Opus 4.1", tr)
            .expect("asked");
        let [Effect::Send(m @ Message::Request { id: Id::Num(n), .. })] = fx.as_slice() else {
            panic!("one request")
        };
        (*n, m.clone())
    }

    #[test]
    fn changing_an_option_asks_the_agent_as_the_phone_does_and_follows_its_answer() {
        let (mut s, mut tr) = ready();
        tr.apply(SessionUpdate::Config(acp::parse_config_options(&json!([
            {"id": "model", "category": "model", "type": "select", "currentValue": "a", "options": [{"value": "a", "name": "Model A"}, {"value": "b", "name": "Opus 4.1"}]}
        ]))));
        let (n, m) = set_model(&mut s, &tr);
        let Message::Request { method, params, .. } = m else {
            panic!("request")
        };
        assert_eq!(method, "session/set_config_option");
        assert_eq!(
            params,
            json!({"sessionId": "sess", "configId": "model", "value": "b"})
        );
        // The agent answers with every option as it stands.
        s.handle(
            ok(n, json!({"configOptions": [
                {"id": "model", "category": "model", "type": "select", "currentValue": "b", "options": [{"value": "a", "name": "Model A"}, {"value": "b", "name": "Opus 4.1"}]}]})),
            0,
            &mut tr,
        );
        assert_eq!(tr.model(), Some("Opus 4.1"));
        let (n2, _) = set_model(&mut s, &tr);
        // An agent that answers with no options is taken at its word.
        tr.set_current("model", "a");
        s.handle(ok(n2, json!({})), 0, &mut tr);
        assert_eq!(tr.model(), Some("Opus 4.1"));
        assert!(matches!(
            tr.items().back().map(|i| &i.entry),
            Some(crate::transcript::Entry::Note(t)) if t == "Model: Opus 4.1"
        ));
    }

    #[test]
    fn a_refused_change_says_so_and_leaves_the_option_alone() {
        let (mut s, mut tr) = ready();
        tr.apply(SessionUpdate::Config(acp::parse_config_options(&json!([
            {"id": "model", "category": "model", "type": "select", "currentValue": "a", "options": [{"value": "a", "name": "Model A"}, {"value": "b", "name": "Opus 4.1"}]}
        ]))));
        let (n, _) = set_model(&mut s, &tr);
        s.handle(
            Event::Message(Message::error(
                Id::Num(n),
                RpcError::new(-32602, "unknown model"),
            )),
            0,
            &mut tr,
        );
        assert_eq!(tr.model(), Some("Model A"));
        assert!(matches!(
            tr.items().back().map(|i| &i.entry),
            Some(crate::transcript::Entry::Note(t)) if t == "Could not change model: unknown model"
        ));
    }

    #[test]
    fn an_option_is_not_changed_while_a_turn_runs_or_before_the_session_is_open() {
        let (mut s, mut tr) = ready();
        s.send("hi", &[], &mut tr).expect("sent");
        assert_eq!(
            s.set_config("model", "b", "Model", "B", &tr),
            Err(Refused::Busy)
        );
        let tr2 = Transcript::default();
        let (mut fresh, _) = Session::begin(Start::Attach, None);
        assert_eq!(
            fresh.set_config("model", "b", "Model", "B", &tr2),
            Err(Refused::NotReady)
        );
    }

    #[test]
    fn a_picture_goes_as_a_picture_only_to_an_agent_that_says_it_takes_them() {
        let open = |caps: Value| {
            let mut tr = Transcript::default();
            let (mut s, _) = Session::begin(Start::Attach, None);
            s.handle(ok(1, caps), 0, &mut tr);
            s.handle(record(Some("sess")), 0, &mut tr);
            s.handle(ok(2, json!({})), 0, &mut tr);
            (s, tr)
        };
        let mut p = attach::attachment("/w/a.png", "/w");
        p.size = 10;
        p.data = Some(attach::base64(b"hi"));
        let (mut s, mut tr) =
            open(json!({"agentCapabilities": {"promptCapabilities": {"image": true}}}));
        assert!(s.accepts_pictures());
        let fx = s.send("", std::slice::from_ref(&p), &mut tr).expect("sent");
        let [Effect::Send(Message::Request { params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            params["prompt"],
            json!([{"type": "image", "data": "aGk=", "mimeType": "image/png"}])
        );
        let (s, _) = open(json!({"agentCapabilities": {"promptCapabilities": {"image": {}}}}));
        assert!(
            !s.accepts_pictures(),
            "only a boolean true is a yes, as on the phone"
        );
        for no in [
            json!({}),
            json!({"agentCapabilities": {"promptCapabilities": {"image": false}}}),
            json!({"agentCapabilities": {"promptCapabilities": {"image": null}}}),
        ] {
            let (mut s, mut tr) = open(no);
            assert!(!s.accepts_pictures());
            let fx = s.send("", std::slice::from_ref(&p), &mut tr).expect("sent");
            let [Effect::Send(Message::Request { params, .. })] = fx.as_slice() else {
                panic!("one request")
            };
            assert_eq!(
                params["prompt"][0]["type"], "resource_link",
                "a link instead"
            );
        }
    }
}
