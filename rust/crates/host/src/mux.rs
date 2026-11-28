//! `herdr.mux` and `herdr.events` for any [`Backend`]: pipelined requests,
//! answers cut down to what the client reads, row deltas for the two answers
//! that are mostly unchanged between reads, and a pruned event feed.
//!
//! The behaviour is a port of the python scripts the app used to ship
//! (`_pythonMux`, `_pythonEvents` in `bridge_command.dart`). What the client
//! wants kept (`projections`, `projection`) and how deltas are tuned arrive in
//! the OPEN args, so no field list lives here.

use crate::backend::{Availability, Backend, BackendError, EventSource};
use crate::service::{Class, MethodKind, MethodSpec, Service};
use crate::session::{Incoming, StreamCtx, BATCH_HOLD};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use similar::{capture_diff_slices, Algorithm, DiffTag};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError};

/// A request handler's stack: it parses one answer and diffs two row lists.
/// 256 KiB overflowed in a debug build (serde's recursive parser, the diff and
/// miniz's compressor have large unoptimised frames); untouched stack pages
/// cost no memory.
const REQUEST_STACK: usize = 2 * 1024 * 1024;

/// Requests in flight across every mux stream. The python mux had no limit;
/// a board that opens loads every card at once stays well under this.
const MAX_INFLIGHT: usize = 128;

/// How often an events stream looks for a client that left.
const WATCH_EVERY: Duration = Duration::from_millis(250);

/// The longest `coalesce_ms` an events stream accepts.
const MAX_COALESCE_MS: u64 = 5000;

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "mux",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "Pipelined requests to the backend's own API. The host sends one MSG {\"ready\":true} once the backend is reachable (END error `unavailable` before it when it is not), then the client sends MSG {id,method,params,have?} per request and gets exactly one MSG per request, out of order: the backend's response object, cut down by projections[method]. session.snapshot and pane.read answers carry seq and rows or a delta against the answer `have` names.",
        args_example: r#"{"session":"default","socket":null,"projections":{"pane.read":{"id":true,"error":true,"result":{"read":{"text":true,"truncated":true}}}},"delta":{"min_chars":512,"max_rows":4000,"keep":256,"keep_chars":4194304}}"#,
        result_example: "{}",
    },
    MethodSpec {
        name: "events",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "The backend's event feed. First MSG is the backend's acknowledgement; then one MSG per event cut down to `projection` (a line that is not JSON arrives as a JSON string). Open with zctx. Optional `coalesce_ms` (integer 0..=5000, default 0 = off; larger values are capped at 5000, a non-integer is bad_request): per pane_id, a pane_updated whose pruned data.pane equals the last one sent is dropped, the first after a quiet period goes out at once and later ones inside the window are held and only the latest is sent when the window ends; any other event is sent at once, after the held update of the pane it names (after all held updates when it names no pane). Frames of this stream are batched by the writer (30 ms).",
        args_example: r#"{"session":"default","socket":null,"subscriptions":[{"type":"pane.updated"}],"projection":{"event":true,"data":{"pane":{"pane_id":true,"agent_status":true}}},"coalesce_ms":250}"#,
        result_example: "{}",
    },
];

/// Where the backend is: the OPEN args' override of the client HELLO's
/// `herdr` section.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct Origin {
    session: Option<String>,
    socket: Option<String>,
}

/// How delta answers are tuned (the client's `muxDelta*` constants).
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(default)]
pub struct DeltaTuning {
    /// A `pane.read` shorter than this many characters is sent whole.
    pub min_chars: usize,
    /// Reads of more rows than this (old and new together) are sent whole.
    pub max_rows: usize,
    /// How many distinct answers are remembered.
    pub keep: usize,
    /// How many characters of rows are remembered at most.
    pub keep_chars: usize,
}

impl Default for DeltaTuning {
    fn default() -> Self {
        Self {
            min_chars: 512,
            max_rows: 4000,
            keep: 256,
            keep_chars: 4 << 20,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct MuxArgs {
    #[serde(flatten)]
    origin: Origin,
    projections: Map<String, Value>,
    delta: DeltaTuning,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct EventsArgs {
    #[serde(flatten)]
    origin: Origin,
    subscriptions: Vec<Value>,
    projection: Option<Value>,
    /// See [`Coalescer`]; 0 or absent = every event as it comes.
    coalesce_ms: Option<u64>,
}

impl EventsArgs {
    /// The coalescing window, capped at [`MAX_COALESCE_MS`].
    fn window(&self) -> Duration {
        Duration::from_millis(self.coalesce_ms.unwrap_or(0).min(MAX_COALESCE_MS))
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

// ---- pruning and canonical text ----

/// A projection that is neither `true` nor an object where an object was
/// holding fields.
#[derive(Debug, PartialEq, Eq)]
pub struct BadProjection;

/// `v` cut down to `spec`: `true` keeps a value whole; a map keeps the listed
/// keys of an object (of each object, for a list), in the order of the map.
///
/// # Errors
/// [`BadProjection`] when an object meets a spec that is not `true` or a map.
pub fn prune(v: &Value, spec: &Value) -> Result<Value, BadProjection> {
    if spec == &Value::Bool(true) {
        return Ok(v.clone());
    }
    match v {
        Value::Array(items) => items
            .iter()
            .map(|x| prune(x, spec))
            .collect::<Result<Vec<_>, _>>()
            .map(Value::Array),
        Value::Object(map) => {
            let fields = spec.as_object().ok_or(BadProjection)?;
            let mut out = Map::new();
            for (key, sub) in fields {
                if let Some(x) = map.get(key) {
                    out.insert(key.clone(), prune(x, sub)?);
                }
            }
            Ok(Value::Object(out))
        }
        _ => Ok(v.clone()),
    }
}

/// Compact JSON with every object's keys sorted: the same value always has the
/// same text, whatever order the backend listed the keys in.
#[must_use]
pub fn canonical(v: &Value) -> String {
    let mut out = String::new();
    write_canonical(v, &mut out);
    out
}

fn write_canonical(v: &Value, out: &mut String) {
    match v {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                if let Some(x) = map.get(key) {
                    write_canonical(x, out);
                }
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, x) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(x, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// How python's `str()` would print a JSON scalar (the snapshot's version
/// row has always been built that way).
fn py_str(v: Option<&Value>) -> String {
    match v {
        None => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) => "None".to_string(),
        Some(Value::Bool(true)) => "True".to_string(),
        Some(Value::Bool(false)) => "False".to_string(),
        Some(other) => canonical(other),
    }
}

// ---- row deltas ----

/// One step of a delta: keep a run of the old rows or insert new ones.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Op {
    /// `[start, count]`: old rows `start..start+count`.
    Keep(usize, usize),
    /// New rows.
    Lit(Vec<String>),
}

impl Op {
    fn to_json(&self) -> Value {
        match self {
            Self::Keep(start, count) => json!([start, count]),
            Self::Lit(rows) => Value::Array(rows.iter().cloned().map(Value::String).collect()),
        }
    }

    fn literal_chars(&self) -> usize {
        match self {
            Self::Keep(..) => 0,
            Self::Lit(rows) => rows.iter().map(|r| r.chars().count()).sum(),
        }
    }
}

/// The ops that turn `old` into `new`. The identical head and tail are cut
/// off first (a pane of repeated rows, blank lines or rulers, would make the
/// diff quadratic otherwise); the middle is a Myers diff.
#[must_use]
pub fn ops(old: &[String], new: &[String]) -> Vec<Op> {
    let m = old.len().min(new.len());
    let mut head = 0;
    while head < m && old[head] == new[head] {
        head += 1;
    }
    let mut tail = 0;
    while tail < m - head && old[old.len() - 1 - tail] == new[new.len() - 1 - tail] {
        tail += 1;
    }
    let mut out = Vec::new();
    if head > 0 {
        out.push(Op::Keep(0, head));
    }
    let mid_old = &old[head..old.len() - tail];
    let mid_new = &new[head..new.len() - tail];
    let mut lit: Vec<String> = Vec::new();
    for op in capture_diff_slices(Algorithm::Myers, mid_old, mid_new) {
        let (tag, from, to) = op.as_tag_tuple();
        match tag {
            DiffTag::Equal => {
                if !lit.is_empty() {
                    out.push(Op::Lit(std::mem::take(&mut lit)));
                }
                out.push(Op::Keep(from.start + head, from.len()));
            }
            DiffTag::Delete => {}
            DiffTag::Insert | DiffTag::Replace => lit.extend_from_slice(&mid_new[to]),
        }
    }
    if !lit.is_empty() {
        out.push(Op::Lit(lit));
    }
    if tail > 0 {
        out.push(Op::Keep(old.len() - tail, tail));
    }
    out
}

/// The answers the mux remembers, newest last: at most `keep` of them and
/// `keep_chars` characters of rows; the oldest go first, but the newest always
/// stays.
pub struct Cache {
    entries: VecDeque<Entry>,
    chars: usize,
    keep: usize,
    keep_chars: usize,
}

struct Entry {
    key: String,
    seq: u64,
    rows: Arc<Vec<String>>,
    chars: usize,
}

/// What the cache held for a key before [`Cache::put`] replaced it.
pub struct Previous {
    pub seq: u64,
    pub rows: Arc<Vec<String>>,
}

impl Cache {
    #[must_use]
    pub fn new(keep: usize, keep_chars: usize) -> Self {
        Self {
            entries: VecDeque::new(),
            chars: 0,
            keep,
            keep_chars,
        }
    }

    /// Remembers `rows` (of `chars` characters) as the answer `seq` for `key`
    /// and returns the answer it replaces.
    pub fn put(
        &mut self,
        key: String,
        seq: u64,
        rows: Arc<Vec<String>>,
        chars: usize,
    ) -> Option<Previous> {
        let old = self
            .entries
            .iter()
            .position(|e| e.key == key)
            .and_then(|i| self.entries.remove(i));
        self.chars += chars;
        if let Some(old) = &old {
            self.chars -= old.chars;
        }
        self.entries.push_back(Entry {
            key,
            seq,
            rows,
            chars,
        });
        while self.entries.len() > 1
            && (self.entries.len() > self.keep || self.chars > self.keep_chars)
        {
            if let Some(gone) = self.entries.pop_front() {
                self.chars -= gone.chars;
            }
        }
        old.map(|e| Previous {
            seq: e.seq,
            rows: e.rows,
        })
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Characters of rows held.
    #[must_use]
    pub fn chars(&self) -> usize {
        self.chars
    }

    #[must_use]
    pub fn holds(&self, key: &str) -> bool {
        self.entries.iter().any(|e| e.key == key)
    }
}

// ---- one mux stream ----

fn fail(id: &Value, message: &str) -> Value {
    json!({"id": id, "error": {"code": "bridge_error", "message": message}})
}

struct Mux<'a, B: Backend> {
    backend: &'a B,
    projections: Map<String, Value>,
    tuning: DeltaTuning,
    cache: Mutex<Cache>,
    seq: AtomicU64,
}

impl<'a, B: Backend> Mux<'a, B> {
    fn new(backend: &'a B, projections: Map<String, Value>, tuning: DeltaTuning) -> Self {
        Self {
            backend,
            projections,
            tuning,
            cache: Mutex::new(Cache::new(tuning.keep, tuning.keep_chars)),
            seq: AtomicU64::new(1),
        }
    }

    /// The response object for one request, whatever happened to it.
    fn serve(&self, mut request: Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let mut have = None;
        let mut method = None;
        if let Some(object) = request.as_object_mut() {
            have = object.remove("mux_have").filter(|v| !v.is_null());
            method = object
                .get("method")
                .and_then(Value::as_str)
                .map(str::to_string);
        }
        match self.backend.call(&request) {
            Ok(response) => self.post(&request, method.as_deref(), have.as_ref(), response),
            Err(e) => fail(&id, &e.to_string()),
        }
    }

    /// `response` cut down to the method's projection and, for the two
    /// delta-able answers, turned into rows or a delta. Anything unexpected
    /// leaves the backend's answer as it was.
    fn post(
        &self,
        request: &Value,
        method: Option<&str>,
        have: Option<&Value>,
        response: Value,
    ) -> Value {
        let keep = method
            .and_then(|m| self.projections.get(m))
            .filter(|k| k.as_object().is_some_and(|o| !o.is_empty()));
        let (Some(method), Some(keep)) = (method, keep) else {
            return response;
        };
        let starts_with_id = response
            .as_object()
            .and_then(|o| o.keys().next())
            .is_some_and(|k| k == "id");
        if !request.is_object() || !starts_with_id {
            return response;
        }
        let Ok(mut pruned) = prune(&response, keep) else {
            return response;
        };
        if matches!(method, "pane.read" | "session.snapshot")
            && self.delta(request, method, &mut pruned, have).is_err()
        {
            return response;
        }
        pruned
    }

    /// Replaces the snapshot with its rows, or a pane read's text with a delta,
    /// and numbers the answer (`seq`) so the client can name it next time.
    fn delta(
        &self,
        request: &Value,
        method: &str,
        d: &mut Value,
        have: Option<&Value>,
    ) -> Result<(), BadAnswer> {
        let snap = method == "session.snapshot";
        let rows: Vec<String> = {
            let Some(content) = d
                .get("result")
                .and_then(|r| r.get(if snap { "snapshot" } else { "read" }))
                .and_then(Value::as_object)
            else {
                return Ok(());
            };
            if snap {
                snapshot_rows(content)?
            } else {
                match content.get("text").and_then(Value::as_str) {
                    Some(text) if text.chars().count() >= self.tuning.min_chars => {
                        text.split('\n').map(str::to_string).collect()
                    }
                    _ => return Ok(()),
                }
            }
        };
        let chars: usize = rows.iter().map(|r| r.chars().count() + 1).sum();
        let key = canonical(&json!([method, request.get("params")]));
        let seq = self.seq.fetch_add(1, Ordering::SeqCst);
        let rows = Arc::new(rows);
        let old = lock(&self.cache).put(key, seq, Arc::clone(&rows), chars);
        let body = old
            .filter(|old| {
                have.and_then(Value::as_u64) == Some(old.seq)
                    && old.rows.len() + rows.len() <= self.tuning.max_rows
            })
            .and_then(|old| {
                let steps = ops(&old.rows, &rows);
                let literal: usize = steps.iter().map(Op::literal_chars).sum();
                (literal * 2 < chars).then(|| json!({"base": old.seq, "o": steps.iter().map(Op::to_json).collect::<Vec<_>>()}))
            });
        if let Some(object) = d.as_object_mut() {
            object.insert("seq".to_string(), json!(seq));
        }
        let Some(result) = d.get_mut("result").and_then(Value::as_object_mut) else {
            return Ok(());
        };
        if snap {
            let replacement = match body {
                Some(body) => json!({"delta": body}),
                None => json!({"rows": &*rows}),
            };
            result.insert("snapshot".to_string(), replacement);
        } else if let Some(body) = body {
            if let Some(read) = result.get_mut("read").and_then(Value::as_object_mut) {
                read.remove("text");
                read.insert("delta".to_string(), body);
            }
        }
        Ok(())
    }
}

/// An answer of a shape the row builder cannot read; the caller sends the
/// backend's answer unchanged.
#[derive(Debug)]
struct BadAnswer;

/// `v<version>`, then a letter and the sorted-key JSON of every workspace
/// (`w`), tab (`t`) and pane (`p`). herdr puts `completion_seq` on its
/// per-agent list, which rows do not carry: it travels on the pane row the app
/// already reads it from. Keys are sorted because herdr's token maps come from
/// a hash map whose order can change between snapshots, and an unchanged row
/// must read the same or it is resent in every delta.
fn snapshot_rows(snapshot: &Map<String, Value>) -> Result<Vec<String>, BadAnswer> {
    let list = |key: &str| -> &[Value] {
        snapshot
            .get(key)
            .and_then(Value::as_array)
            .map_or(&[], Vec::as_slice)
    };
    let completion: HashMap<String, &Value> = list("agents")
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|a| {
            let seq = a
                .get("completion_seq")
                .filter(|v| v.is_i64() || v.is_u64())?;
            Some((canonical(a.get("pane_id").unwrap_or(&Value::Null)), seq))
        })
        .collect();
    let mut rows = vec![format!("v{}", py_str(snapshot.get("version")))];
    for (key, letter) in [("workspaces", 'w'), ("tabs", 't'), ("panes", 'p')] {
        for x in list(key) {
            let mut row = String::from(letter);
            if key == "panes" {
                let pane = x.as_object().ok_or(BadAnswer)?;
                let id = canonical(pane.get("pane_id").unwrap_or(&Value::Null));
                if let Some(seq) = completion.get(&id) {
                    let mut with = pane.clone();
                    with.insert("completion_seq".to_string(), (*seq).clone());
                    write_canonical(&Value::Object(with), &mut row);
                    rows.push(row);
                    continue;
                }
            }
            write_canonical(x, &mut row);
            rows.push(row);
        }
    }
    Ok(rows)
}

// ---- coalescing pane updates ----

/// What the client has seen of one pane, and what is waiting for it.
#[derive(Default)]
struct PaneFeed {
    /// The `data.pane` of the last `pane_updated` sent.
    last_sent: Option<Value>,
    /// When it was sent: the window runs from here.
    sent_at: Option<Instant>,
    /// The newest update inside the window, with its arrival number.
    held: Option<(u64, Value)>,
}

/// Cuts the churn of `pane_updated` events (a busy agent's title spinner makes
/// herdr send one every few milliseconds). Pure: the caller supplies the clock.
///
/// Rules, per pane (`data.pane.pane_id`), with `window` > 0:
/// 1. an update whose `data.pane` equals the last one sent is dropped;
/// 2. the first update after a quiet `window` is sent at once; the ones that
///    follow inside the window are held, the newest replacing the older, and
///    sent when the window ends (`due`), which opens the next window;
/// 3. any other event is sent at once and never dropped. Order: a held update
///    of the pane the event names (`data.pane_id`, `data.pane.pane_id` or
///    `pane_id`) is sent just before it, and so are all held updates, oldest
///    first, for an event that names no pane (it may be about any of them);
///    only an event naming another pane overtakes a held update, and it is
///    never a `pane_updated`, which only ever waits behind its own pane's
///    earlier update.
///
/// With a zero window nothing is held, dropped or reordered.
pub struct Coalescer {
    window: Duration,
    panes: HashMap<String, PaneFeed>,
    held_seq: u64,
}

/// Panes remembered at most; past it, panes with nothing held and a spent
/// window are forgotten (they only cost a repeated update).
const MAX_PANES: usize = 1024;

fn pane_updated(event: &Value) -> Option<(&str, &Value)> {
    if event.get("event")?.as_str()? != "pane_updated" {
        return None;
    }
    let pane = event.pointer("/data/pane")?;
    Some((pane.get("pane_id")?.as_str()?, pane))
}

fn named_pane(event: &Value) -> Option<&str> {
    ["/data/pane_id", "/data/pane/pane_id", "/pane_id"]
        .iter()
        .find_map(|p| event.pointer(p)?.as_str())
}

impl Coalescer {
    #[must_use]
    pub fn new(window: Duration) -> Self {
        Self {
            window,
            panes: HashMap::new(),
            held_seq: 0,
        }
    }

    /// Sends `held` (if any) of `pane` now.
    fn release(&mut self, pane: &str, now: Instant, out: &mut Vec<Value>) {
        if let Some(feed) = self.panes.get_mut(pane) {
            if let Some((_, event)) = feed.held.take() {
                feed.last_sent = event.pointer("/data/pane").cloned();
                feed.sent_at = Some(now);
                out.push(event);
            }
        }
    }

    /// Sends every held update, oldest first.
    fn release_all(&mut self, now: Instant, out: &mut Vec<Value>) {
        let mut held: Vec<(u64, String)> = self
            .panes
            .iter()
            .filter_map(|(id, f)| f.held.as_ref().map(|(n, _)| (*n, id.clone())))
            .collect();
        held.sort_unstable();
        for (_, id) in held {
            self.release(&id, now, out);
        }
    }

    /// The events to send now for `event`, which arrived at `now`.
    pub fn push(&mut self, now: Instant, event: Value) -> Vec<Value> {
        if self.window.is_zero() {
            return vec![event];
        }
        // Held updates whose window ended come first: they are older.
        let mut out = self.due(now);
        let Some((id, pane)) = pane_updated(&event) else {
            match named_pane(&event).map(str::to_string) {
                Some(id) => self.release(&id, now, &mut out),
                None => self.release_all(now, &mut out),
            }
            out.push(event);
            return out;
        };
        let id = id.to_string();
        if self.panes.len() >= MAX_PANES && !self.panes.contains_key(&id) {
            let window = self.window;
            self.panes
                .retain(|_, f| f.held.is_some() || f.sent_at.is_some_and(|t| now < t + window));
        }
        let feed = self.panes.entry(id).or_default();
        let same = feed.last_sent.as_ref() == Some(pane);
        let in_window = feed.sent_at.is_some_and(|t| now < t + self.window);
        if in_window {
            // Newest wins; an update back to what the client has needs no send.
            feed.held = if same {
                None
            } else {
                self.held_seq += 1;
                Some((self.held_seq, event))
            };
        } else if !same {
            feed.last_sent = Some(pane.clone());
            feed.sent_at = Some(now);
            out.push(event);
        }
        out
    }

    /// The held updates whose window has ended at `now`, oldest first.
    pub fn due(&mut self, now: Instant) -> Vec<Value> {
        let mut out = Vec::new();
        if self.window.is_zero() {
            return out;
        }
        let window = self.window;
        let mut ready: Vec<(u64, String)> = self
            .panes
            .iter()
            .filter_map(|(id, f)| {
                let (n, _) = f.held.as_ref()?;
                (now >= f.sent_at? + window).then(|| (*n, id.clone()))
            })
            .collect();
        ready.sort_unstable();
        for (_, id) in ready {
            self.release(&id, now, &mut out);
        }
        out
    }

    /// When the next held update is due; `None` when nothing is held.
    #[must_use]
    pub fn next_deadline(&self) -> Option<Instant> {
        self.panes
            .values()
            .filter(|f| f.held.is_some())
            .filter_map(|f| f.sent_at)
            .map(|t| t + self.window)
            .min()
    }

    /// Every held update, for a feed that ended.
    pub fn drain(&mut self) -> Vec<Value> {
        let mut out = Vec::new();
        self.release_all(Instant::now(), &mut out);
        out
    }
}

// ---- the service ----

/// `herdr.mux` and `herdr.events` over a backend `B`: the service is named
/// after the backend.
pub struct MuxService<B: Backend> {
    backend: B,
    inflight: Arc<AtomicUsize>,
}

impl<B: Backend> MuxService<B> {
    #[must_use]
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            inflight: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// The backend pointed where the OPEN says (else where the HELLO said), or
    /// `unavailable` with the reason.
    fn bound(&self, ctx: &StreamCtx, origin: Origin) -> Result<B, WireError> {
        let mut hello: ClientHello = ctx.hello().clone();
        if let Some(session) = origin.session {
            hello.herdr.session = session;
        }
        if let Some(socket) = origin.socket.filter(|s| !s.is_empty()) {
            hello.herdr.socket = Some(socket);
        }
        match self.backend.discover(&hello) {
            Availability::Available => Ok(self.backend.bind(&hello)),
            Availability::Unavailable { reason } => {
                Err(WireError::new(ErrorCode::Unavailable, reason).retryable())
            }
        }
    }

    fn mux(&self, ctx: &StreamCtx) -> Result<Value, WireError> {
        let args: MuxArgs = parse_args(ctx)?;
        let backend = self.bound(ctx, args.origin)?;
        let mux = Mux::new(&backend, args.projections, args.delta);
        ctx.send_msg(&json!({"ready": true}))?;
        std::thread::scope(|scope| {
            while let Some(item) = ctx.recv() {
                let Incoming::Msg(request) = item else {
                    continue;
                };
                let id = request.get("id").cloned().unwrap_or(Value::Null);
                if self.inflight.fetch_add(1, Ordering::SeqCst) >= MAX_INFLIGHT {
                    self.inflight.fetch_sub(1, Ordering::SeqCst);
                    let busy = json!({"id": id, "error": {"code": "busy", "message": "too many requests in flight"}});
                    if ctx.send_msg(&busy).is_err() {
                        break;
                    }
                    continue;
                }
                let inflight = Arc::clone(&self.inflight);
                let mux = &mux;
                let spawned = std::thread::Builder::new()
                    .name("mux-request".to_string())
                    .stack_size(REQUEST_STACK)
                    .spawn_scoped(scope, move || {
                        let _release = Release(inflight);
                        let response = mux.serve(request);
                        answer(ctx, &response);
                    });
                if let Err(e) = spawned {
                    self.inflight.fetch_sub(1, Ordering::SeqCst);
                    answer(
                        ctx,
                        &fail(&id, &format!("cannot start a request thread: {e}")),
                    );
                }
            }
        });
        Ok(json!({}))
    }

    fn events(&self, ctx: &StreamCtx) -> Result<Value, WireError> {
        let args: EventsArgs = parse_args(ctx)?;
        let window = args.window();
        let backend = self.bound(ctx, args.origin)?;
        let mut source = backend
            .subscribe(&json!({"subscriptions": args.subscriptions}))
            .map_err(wire_error)?;
        ctx.set_batch(BATCH_HOLD);
        ctx.send_msg(&source.ack())?;
        let close = source.closer();
        let stop = AtomicBool::new(false);
        let outcome = std::thread::scope(|scope| {
            // A blocked read only returns when the backend speaks or hangs up:
            // hang up on it when the client leaves.
            let watcher = std::thread::Builder::new()
                .name("events-watch".to_string())
                .stack_size(REQUEST_STACK)
                .spawn_scoped(scope, || {
                    loop {
                        if stop.load(Ordering::SeqCst) || !ctx.sleep(WATCH_EVERY) {
                            break;
                        }
                    }
                    close();
                });
            let projection = args.projection.as_ref();
            let outcome = if window.is_zero() {
                pump(ctx, source.as_mut(), projection)
            } else {
                pump_coalesced(scope, ctx, source.as_mut(), projection, window)
            };
            stop.store(true, Ordering::SeqCst);
            if watcher.is_err() {
                close();
            }
            outcome
        });
        outcome.map(|()| json!({}))
    }
}

/// The event as the client's projection cuts it; sent whole when the
/// projection cannot be applied to it.
fn projected(event: Value, projection: Option<&Value>) -> Value {
    projection
        .and_then(|p| prune(&event, p).ok())
        .unwrap_or(event)
}

/// How the feed ended: quietly when the client is the one who left.
fn feed_end(ctx: &StreamCtx, error: Option<BackendError>) -> Result<(), WireError> {
    match error {
        _ if ctx.done() => Ok(()),
        None => Err(WireError::new(ErrorCode::Failed, "herdr closed the event stream").retryable()),
        Some(e) => Err(wire_error(e)),
    }
}

/// Sends the feed to the client until either side ends.
fn pump(
    ctx: &StreamCtx,
    source: &mut dyn EventSource,
    projection: Option<&Value>,
) -> Result<(), WireError> {
    loop {
        match source.next_event() {
            None => return feed_end(ctx, None),
            Some(Err(e)) => return feed_end(ctx, Some(e)),
            Some(Ok(event)) => ctx.send_msg(&projected(event, projection))?,
        }
    }
}

/// [`pump`] with a [`Coalescer`]. Reading the backend blocks, so a reader
/// thread feeds a channel and this thread waits on it until the coalescer's
/// next deadline: one timed wait, no polling, and no timeout at all while
/// nothing is held.
fn pump_coalesced<'scope, 'env>(
    scope: &'scope std::thread::Scope<'scope, 'env>,
    ctx: &StreamCtx,
    source: &'env mut dyn EventSource,
    projection: Option<&Value>,
    window: Duration,
) -> Result<(), WireError> {
    type Item = Option<Result<Value, BackendError>>;
    let (tx, rx) = std::sync::mpsc::channel::<Item>();
    std::thread::Builder::new()
        .name("events-read".to_string())
        .stack_size(REQUEST_STACK)
        .spawn_scoped(scope, move || loop {
            let item = source.next_event();
            let last = !matches!(item, Some(Ok(_)));
            if tx.send(item).is_err() || last {
                break;
            }
        })
        .map_err(|e| {
            WireError::new(
                ErrorCode::Failed,
                format!("cannot start the event reader: {e}"),
            )
        })?;
    let mut co = Coalescer::new(window);
    loop {
        let got = match co.next_deadline() {
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            Some(at) => rx.recv_timeout(at.saturating_duration_since(Instant::now())),
        };
        let ended = match got {
            Ok(Some(Ok(event))) => {
                for out in co.push(Instant::now(), projected(event, projection)) {
                    ctx.send_msg(&out)?;
                }
                continue;
            }
            Err(RecvTimeoutError::Timeout) => {
                for out in co.due(Instant::now()) {
                    ctx.send_msg(&out)?;
                }
                continue;
            }
            Ok(Some(Err(e))) => Some(e),
            Ok(None) | Err(RecvTimeoutError::Disconnected) => None,
        };
        // The feed is over: what was held was news the client has not seen.
        for out in co.drain() {
            ctx.send_msg(&out)?;
        }
        return feed_end(ctx, ended);
    }
}

struct Release(Arc<AtomicUsize>);

impl Drop for Release {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Sends one response; one too big for a frame becomes an error object so the
/// client's request still completes.
fn answer(ctx: &StreamCtx, response: &Value) {
    if let Err(crate::session::SendError::TooLarge) = ctx.send_msg(response) {
        let id = response.get("id").cloned().unwrap_or(Value::Null);
        let _ = ctx.send_msg(&fail(&id, "the answer is larger than 1 MiB on the wire"));
    }
}

fn parse_args<T: for<'de> Deserialize<'de>>(ctx: &StreamCtx) -> Result<T, WireError> {
    serde_json::from_value(ctx.args().clone())
        .map_err(|e| WireError::new(ErrorCode::BadRequest, format!("bad args: {e}")))
}

fn wire_error(e: BackendError) -> WireError {
    match e {
        BackendError::Unavailable(m) => WireError::new(ErrorCode::Unavailable, m).retryable(),
        BackendError::Failed(m) => WireError::new(ErrorCode::Failed, m).retryable(),
    }
}

impl<B: Backend> Service for MuxService<B> {
    fn name(&self) -> &'static str {
        self.backend.id()
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, hello: &ClientHello) -> ServiceStatus {
        self.backend.discover(hello).status()
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "mux" => self.mux(ctx),
            "events" => self.events(ctx),
            other => Err(WireError::new(
                ErrorCode::UnknownMethod,
                format!("{} has no method {other}", self.backend.id()),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    fn rows(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    /// What the client does with a delta's ops.
    fn apply(old: &[String], ops: &Value) -> Option<Vec<String>> {
        let mut out = Vec::new();
        for op in ops.as_array()? {
            let op = op.as_array()?;
            if let Some(start) = op.first()?.as_u64() {
                let count = op.get(1)?.as_u64()?;
                let (start, count) = (usize::try_from(start).ok()?, usize::try_from(count).ok()?);
                out.extend_from_slice(old.get(start..start + count)?);
            } else {
                for row in op {
                    out.push(row.as_str()?.to_string());
                }
            }
        }
        Some(out)
    }

    fn apply_steps(old: &[String], steps: &[Op]) -> Vec<String> {
        let json = Value::Array(steps.iter().map(Op::to_json).collect());
        apply(old, &json).expect("ops apply")
    }

    /// A deterministic pseudo-random edit of `old`: deletions, replacements,
    /// insertions, blocks moved and rows repeated.
    fn edit(old: &[String], seed: u64) -> Vec<String> {
        let mut x = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let mut next = move |n: usize| {
            x = x
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            usize::try_from(x >> 33).unwrap_or(0) % n.max(1)
        };
        let mut rows = old.to_vec();
        for _ in 0..next(6) + 1 {
            let at = next(rows.len() + 1);
            match next(4) {
                0 if at < rows.len() => {
                    rows.remove(at);
                }
                1 if at < rows.len() => rows[at] = format!("changed {}", next(1000)),
                2 => rows.insert(at, format!("new {}", next(1000))),
                _ => {
                    let again = rows.get(at).cloned().unwrap_or_default();
                    rows.insert(at, again);
                }
            }
        }
        rows
    }

    #[test]
    fn ops_turn_old_rows_into_new_rows_for_many_edits() {
        let old: Vec<String> = (0..40).map(|i| format!("row {}", i % 9)).collect();
        for seed in 0..300 {
            let new = edit(&old, seed);
            let steps = ops(&old, &new);
            assert_eq!(apply_steps(&old, &steps), new, "seed {seed}");
        }
    }

    #[test]
    fn ops_handle_empty_and_identical_inputs() {
        let some = rows(&["a", "b"]);
        assert_eq!(apply_steps(&[], &ops(&[], &some)), some);
        assert_eq!(apply_steps(&some, &ops(&some, &[])), Vec::<String>::new());
        assert_eq!(ops(&some, &some), vec![Op::Keep(0, 2)]);
        assert_eq!(ops(&[], &[]), Vec::<Op>::new());
    }

    #[test]
    fn a_scrolled_read_costs_only_the_new_rows() {
        let old: Vec<String> = (0..300).map(|i| format!("line {i}")).collect();
        let mut new: Vec<String> = old[3..].to_vec();
        new.extend(rows(&["line 300", "line 301", "line 302"]));
        let steps = ops(&old, &new);
        let literal: usize = steps.iter().map(Op::literal_chars).sum();
        assert_eq!(literal, 24, "only the three new rows travel: {steps:?}");
        assert_eq!(apply_steps(&old, &steps), new);
    }

    #[test]
    fn the_cache_holds_at_most_keep_entries_and_drops_the_oldest() {
        let mut cache = Cache::new(3, usize::MAX);
        for i in 0..5 {
            cache.put(format!("k{i}"), i, Arc::new(rows(&["x"])), 2);
        }
        assert_eq!(cache.len(), 3);
        assert!(!cache.holds("k0") && !cache.holds("k1") && cache.holds("k4"));
        assert_eq!(cache.chars(), 6);
    }

    #[test]
    fn touching_a_key_makes_it_the_newest_and_hands_back_the_old_answer() {
        let mut cache = Cache::new(2, usize::MAX);
        cache.put("a".into(), 1, Arc::new(rows(&["old"])), 4);
        cache.put("b".into(), 2, Arc::new(rows(&["b"])), 2);
        let previous = cache
            .put("a".into(), 3, Arc::new(rows(&["new"])), 4)
            .expect("held");
        assert_eq!(
            (previous.seq, previous.rows.as_slice()),
            (1, rows(&["old"]).as_slice())
        );
        cache.put("c".into(), 4, Arc::new(rows(&["c"])), 2);
        assert!(cache.holds("a") && cache.holds("c") && !cache.holds("b"));
    }

    #[test]
    fn the_cache_holds_at_most_keep_chars_but_always_the_newest_answer() {
        let mut cache = Cache::new(100, 10);
        cache.put("a".into(), 1, Arc::new(rows(&["x"])), 6);
        cache.put("b".into(), 2, Arc::new(rows(&["x"])), 6);
        assert!(!cache.holds("a") && cache.holds("b"));
        assert_eq!(cache.chars(), 6);
        cache.put("c".into(), 3, Arc::new(rows(&["x"])), 50);
        assert_eq!(cache.len(), 1);
        assert!(cache.holds("c"));
        assert_eq!(cache.chars(), 50);
    }

    #[test]
    fn prune_keeps_listed_keys_in_the_projections_order_and_maps_over_lists() {
        let v = json!({"b": 1, "a": {"x": 1, "y": 2, "z": 3}, "list": [{"p": 1, "q": 2}, {"p": 3}], "drop": true});
        let spec =
            json!({"a": {"y": true, "x": true}, "list": {"q": true}, "missing": true, "b": true});
        let got = prune(&v, &spec).expect("pruned");
        assert_eq!(
            got,
            json!({"a": {"y": 2, "x": 1}, "list": [{"q": 2}, {}], "b": 1})
        );
        let order: Vec<&String> = got.as_object().expect("object").keys().collect();
        assert_eq!(order, ["a", "list", "b"]);
        assert_eq!(prune(&json!(5), &json!({"a": true})), Ok(json!(5)));
        assert_eq!(prune(&json!({"a": 1}), &json!(false)), Err(BadProjection));
    }

    #[test]
    fn canonical_text_sorts_keys_at_every_depth() {
        let a = json!({"b": [{"z": 1, "y": "é"}], "a": null});
        let b = json!({"a": null, "b": [{"y": "é", "z": 1}]});
        assert_eq!(canonical(&a), r#"{"a":null,"b":[{"y":"é","z":1}]}"#);
        assert_eq!(canonical(&a), canonical(&b));
    }

    #[test]
    fn snapshot_rows_carry_completion_seq_on_the_pane_and_sort_pane_keys() {
        let snapshot = json!({
            "version": "0.9.3",
            "workspaces": [{"workspace_id": "w1"}],
            "tabs": [{"tab_id": "t1"}],
            "panes": [{"pane_id": "p1", "tokens": {"b": 1, "a": 2}}, {"pane_id": "p2"}],
            "agents": [{"pane_id": "p1", "completion_seq": 7}, {"pane_id": "p2", "completion_seq": "x"}],
        });
        let rows = snapshot_rows(snapshot.as_object().expect("object")).expect("rows");
        assert_eq!(
            rows,
            [
                "v0.9.3",
                r#"w{"workspace_id":"w1"}"#,
                r#"t{"tab_id":"t1"}"#,
                r#"p{"completion_seq":7,"pane_id":"p1","tokens":{"a":2,"b":1}}"#,
                r#"p{"pane_id":"p2"}"#,
            ]
        );
    }

    struct Fake {
        answers: Mutex<VecDeque<Value>>,
        calls: AtomicUsize,
        seen: Mutex<Vec<Value>>,
    }

    impl Fake {
        fn new(answers: Vec<Value>) -> Self {
            Self {
                answers: Mutex::new(answers.into()),
                calls: AtomicUsize::new(0),
                seen: Mutex::new(Vec::new()),
            }
        }
    }

    impl Backend for Fake {
        fn id(&self) -> &'static str {
            "fake"
        }
        fn discover(&self, _: &ClientHello) -> Availability {
            Availability::Available
        }
        fn bind(&self, _: &ClientHello) -> Self {
            Self::new(Vec::new())
        }
        fn call(&self, request: &Value) -> Result<Value, BackendError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            lock(&self.seen).push(request.clone());
            lock(&self.answers).pop_front().ok_or_else(|| {
                BackendError::Failed("herdr closed the connection without answering".into())
            })
        }
        fn subscribe(&self, _: &Value) -> Result<Box<dyn EventSource>, BackendError> {
            Err(BackendError::Unavailable("no".into()))
        }
    }

    fn read_answer(text: &str) -> Value {
        json!({"id": "m1", "result": {"type": "pane_read", "read": {"pane_id": "p", "text": text, "truncated": false}}})
    }

    fn projections() -> Map<String, Value> {
        json!({"pane.read": {"id": true, "error": true, "result": {"read": {"text": true, "truncated": true}}}})
            .as_object()
            .cloned()
            .expect("object")
    }

    fn big_text(rows: usize, offset: usize) -> String {
        (offset..offset + rows)
            .map(|i| format!("line number {i} of a long enough pane"))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn request(id: &str, have: Option<u64>) -> Value {
        let mut r = json!({"id": id, "method": "pane.read", "params": {"pane_id": "p"}});
        if let Some(have) = have {
            r["mux_have"] = json!(have);
        }
        r
    }

    #[test]
    fn a_read_is_pruned_numbered_and_then_answered_with_a_delta_when_the_client_names_it() {
        let first = big_text(60, 0);
        let second = big_text(60, 3);
        let fake = Fake::new(vec![read_answer(&first), read_answer(&second)]);
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());

        let whole = mux.serve(request("m1", None));
        assert_eq!(whole["seq"], 1);
        assert_eq!(whole["result"]["read"]["text"], first.as_str());
        assert!(
            whole["result"].get("type").is_none(),
            "pruned to the projection"
        );

        let delta = mux.serve(request("m2", Some(1)));
        assert_eq!(delta["seq"], 2);
        assert!(delta["result"]["read"].get("text").is_none());
        assert_eq!(delta["result"]["read"]["delta"]["base"], 1);
        let old: Vec<String> = first.split('\n').map(str::to_string).collect();
        let rebuilt = apply(&old, &delta["result"]["read"]["delta"]["o"]).expect("applies");
        assert_eq!(rebuilt.join("\n"), second);
        let seen = lock(&fake.seen);
        assert!(
            seen.iter().all(|r| r.get("mux_have").is_none()),
            "mux_have never reaches the backend"
        );
    }

    #[test]
    fn a_stale_or_missing_have_gets_the_whole_answer() {
        let text = big_text(60, 0);
        let fake = Fake::new(vec![
            read_answer(&text),
            read_answer(&text),
            read_answer(&text),
        ]);
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());
        mux.serve(request("m1", None));
        let wrong = mux.serve(request("m2", Some(99)));
        assert_eq!(wrong["result"]["read"]["text"], text.as_str());
        let none = mux.serve(request("m3", None));
        assert_eq!(none["result"]["read"]["text"], text.as_str());
    }

    #[test]
    fn a_delta_that_is_not_much_smaller_than_the_rows_is_not_sent() {
        let first = big_text(60, 0);
        let second = big_text(60, 1000);
        let fake = Fake::new(vec![read_answer(&first), read_answer(&second)]);
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());
        mux.serve(request("m1", None));
        let answer = mux.serve(request("m2", Some(1)));
        assert_eq!(answer["result"]["read"]["text"], second.as_str());
    }

    #[test]
    fn too_many_rows_and_short_text_are_sent_whole() {
        let text = big_text(60, 0);
        let tuning = DeltaTuning {
            max_rows: 100,
            ..DeltaTuning::default()
        };
        let fake = Fake::new(vec![read_answer(&text), read_answer(&text)]);
        let mux = Mux::new(&fake, projections(), tuning);
        mux.serve(request("m1", None));
        let answer = mux.serve(request("m2", Some(1)));
        assert_eq!(
            answer["result"]["read"]["text"],
            text.as_str(),
            "60 + 60 rows > 100"
        );

        let fake = Fake::new(vec![read_answer("short")]);
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());
        let short = mux.serve(request("m1", None));
        assert!(
            short.get("seq").is_none(),
            "under min_chars nothing is remembered"
        );
        assert_eq!(short["result"]["read"]["text"], "short");
    }

    #[test]
    fn a_failed_call_becomes_a_bridge_error_with_the_requests_id() {
        let fake = Fake::new(Vec::new());
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());
        let answer = mux.serve(request("m9", None));
        assert_eq!(
            answer,
            json!({"id": "m9", "error": {"code": "bridge_error", "message": "herdr closed the connection without answering"}})
        );
        let not_an_object = mux.serve(json!("hello"));
        assert_eq!(not_an_object["id"], Value::Null);
        assert_eq!(not_an_object["error"]["code"], "bridge_error");
    }

    #[test]
    fn a_method_without_a_projection_passes_through_untouched() {
        let raw = json!({"id": "m1", "result": {"type": "pong", "version": "0.9.3"}});
        let fake = Fake::new(vec![raw.clone()]);
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());
        assert_eq!(
            mux.serve(json!({"id": "m1", "method": "ping", "params": {}})),
            raw
        );
    }

    #[test]
    fn an_error_answer_is_pruned_but_kept_whole_where_the_projection_says_so() {
        let raw = json!({"id": "m1", "error": {"code": "pane_not_found", "message": "gone"}});
        let fake = Fake::new(vec![raw.clone()]);
        let mux = Mux::new(&fake, projections(), DeltaTuning::default());
        assert_eq!(mux.serve(request("m1", None)), raw);
    }

    #[test]
    fn the_args_examples_in_the_catalog_parse_into_the_typed_args() {
        let mux = METHODS.iter().find(|m| m.name == "mux").expect("mux");
        let args: MuxArgs = serde_json::from_str(mux.args_example).expect("mux args");
        assert_eq!(args.origin.session.as_deref(), Some("default"));
        assert_eq!(args.origin.socket, None);
        assert_eq!(args.delta.min_chars, 512);
        assert_eq!(args.delta.keep_chars, 4_194_304);
        assert!(args.projections.contains_key("pane.read"));
        let events = METHODS.iter().find(|m| m.name == "events").expect("events");
        let args: EventsArgs = serde_json::from_str(events.args_example).expect("events args");
        assert_eq!(args.subscriptions.len(), 1);
        assert!(args.projection.is_some());
        for m in METHODS {
            serde_json::from_str::<Value>(m.result_example).expect("result example is JSON");
        }
    }

    // ---- the coalescer ----

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// A pruned `pane_updated`: the title is what changes.
    fn pane_event(pane: &str, title: &str) -> Value {
        json!({"event": "pane_updated", "data": {"pane": {"pane_id": pane, "terminal_title": title}}})
    }

    fn status_event(pane: &str) -> Value {
        json!({"event": "pane_agent_status_changed", "data": {"pane_id": pane, "agent_status": "idle"}})
    }

    fn titles(events: &[Value]) -> Vec<String> {
        events
            .iter()
            .map(|e| {
                e.pointer("/data/pane/terminal_title")
                    .and_then(Value::as_str)
                    .unwrap_or("-")
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn zero_window_is_the_identity_even_for_identical_events() {
        let mut co = Coalescer::new(Duration::ZERO);
        let t0 = Instant::now();
        let e = pane_event("w1:p1", "a");
        for _ in 0..3 {
            assert_eq!(co.push(t0, e.clone()), vec![e.clone()]);
        }
        assert_eq!(co.next_deadline(), None);
        assert!(co.due(t0 + ms(10_000)).is_empty());
    }

    #[test]
    fn a_burst_of_ten_identical_events_is_one() {
        let mut co = Coalescer::new(ms(250));
        let t0 = Instant::now();
        let e = pane_event("w1:p1", "a");
        let mut out = Vec::new();
        for i in 0..10 {
            out.extend(co.push(t0 + ms(i * 5), e.clone()));
        }
        assert_eq!(out, vec![e.clone()]);
        assert_eq!(co.next_deadline(), None, "nothing is held: no timer needed");
        // ...and the same event long after is still the same: dropped.
        assert!(co.push(t0 + ms(5000), e).is_empty());
    }

    #[test]
    fn changes_inside_a_window_are_a_leading_event_and_one_trailing_with_the_last() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        let first = co.push(t0, pane_event("w1:p1", "1"));
        assert_eq!(
            titles(&first),
            ["1"],
            "the first after quiet goes out at once"
        );
        assert!(co.push(t0 + ms(10), pane_event("w1:p1", "2")).is_empty());
        assert!(co.push(t0 + ms(20), pane_event("w1:p1", "3")).is_empty());
        assert!(co.push(t0 + ms(30), pane_event("w1:p1", "4")).is_empty());
        assert_eq!(co.next_deadline(), Some(t0 + ms(100)));
        assert!(co.due(t0 + ms(99)).is_empty());
        assert_eq!(titles(&co.due(t0 + ms(100))), ["4"], "last wins");
        assert_eq!(co.next_deadline(), None);
        assert!(co.due(t0 + ms(500)).is_empty());
    }

    #[test]
    fn a_trailing_send_opens_a_new_window() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        co.push(t0, pane_event("w1:p1", "1"));
        co.push(t0 + ms(10), pane_event("w1:p1", "2"));
        assert_eq!(titles(&co.due(t0 + ms(100))), ["2"]);
        assert!(co.push(t0 + ms(150), pane_event("w1:p1", "3")).is_empty());
        assert_eq!(co.next_deadline(), Some(t0 + ms(200)));
        assert_eq!(titles(&co.due(t0 + ms(200))), ["3"]);
    }

    #[test]
    fn a_held_update_that_returns_to_what_was_sent_is_dropped() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        co.push(t0, pane_event("w1:p1", "a"));
        assert!(co.push(t0 + ms(10), pane_event("w1:p1", "b")).is_empty());
        assert!(co.push(t0 + ms(20), pane_event("w1:p1", "a")).is_empty());
        assert_eq!(co.next_deadline(), None, "the client already has `a`");
        assert!(co.due(t0 + ms(100)).is_empty());
    }

    #[test]
    fn panes_are_independent() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        assert_eq!(co.push(t0, pane_event("w1:p1", "a1")).len(), 1);
        assert_eq!(co.push(t0 + ms(1), pane_event("w1:p2", "b1")).len(), 1);
        assert!(co.push(t0 + ms(10), pane_event("w1:p1", "a2")).is_empty());
        assert!(co.push(t0 + ms(20), pane_event("w1:p2", "b2")).is_empty());
        assert_eq!(co.next_deadline(), Some(t0 + ms(100)));
        assert_eq!(titles(&co.due(t0 + ms(100))), ["a2"]);
        assert_eq!(co.next_deadline(), Some(t0 + ms(101)));
        assert_eq!(titles(&co.due(t0 + ms(101))), ["b2"]);
    }

    #[test]
    fn another_event_passes_at_once_and_flushes_its_panes_held_update_first() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        co.push(t0, pane_event("w1:p1", "a1"));
        co.push(t0 + ms(5), pane_event("w1:p2", "b1"));
        co.push(t0 + ms(10), pane_event("w1:p1", "a2"));
        co.push(t0 + ms(11), pane_event("w1:p2", "b2"));
        // About p1: p1's held update goes first, p2's stays held.
        let status = status_event("w1:p1");
        let out = co.push(t0 + ms(20), status.clone());
        assert_eq!(out.len(), 2);
        assert_eq!(titles(&out[..1]), ["a2"]);
        assert_eq!(out[1], status);
        assert_eq!(co.next_deadline(), Some(t0 + ms(105)));
        // The ordering flush counted as a send: a new update waits in a window.
        assert!(co.push(t0 + ms(30), pane_event("w1:p1", "a3")).is_empty());
        // An event that names no pane flushes every held update, oldest first.
        let other = json!({"event": "workspace_created", "data": {"workspace_id": "w2"}});
        let out = co.push(t0 + ms(40), other.clone());
        assert_eq!(out.len(), 3);
        assert_eq!(titles(&out[..2]), ["b2", "a3"]);
        assert_eq!(out[2], other);
        assert_eq!(co.next_deadline(), None);
    }

    #[test]
    fn an_event_about_another_pane_may_overtake_a_held_update() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        co.push(t0, pane_event("w1:p1", "a1"));
        co.push(t0 + ms(5), pane_event("w1:p1", "a2"));
        let status = status_event("w1:p9");
        assert_eq!(co.push(t0 + ms(6), status.clone()), vec![status]);
        assert_eq!(co.next_deadline(), Some(t0 + ms(100)), "still held");
    }

    #[test]
    fn events_that_are_not_pane_updates_are_never_dropped_or_delayed() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        let status = status_event("w1:p1");
        for i in 0..5 {
            assert_eq!(co.push(t0 + ms(i), status.clone()), vec![status.clone()]);
        }
        // a string line (not JSON) and a pane_updated without a pane id pass too
        let line = json!("not json");
        assert_eq!(co.push(t0, line.clone()), vec![line]);
        let nameless = json!({"event": "pane_updated", "data": {}});
        assert_eq!(co.push(t0, nameless.clone()), vec![nameless]);
    }

    #[test]
    fn drain_hands_back_everything_held_in_order() {
        let mut co = Coalescer::new(ms(100));
        let t0 = Instant::now();
        co.push(t0, pane_event("w1:p1", "a1"));
        co.push(t0, pane_event("w1:p2", "b1"));
        co.push(t0 + ms(1), pane_event("w1:p2", "b2"));
        co.push(t0 + ms(2), pane_event("w1:p1", "a2"));
        assert_eq!(titles(&co.drain()), ["b2", "a2"]);
        assert!(co.drain().is_empty());
    }

    #[test]
    fn coalesce_ms_is_validated_and_capped() {
        let parse = |v: Value| serde_json::from_value::<EventsArgs>(v);
        assert_eq!(parse(json!({})).expect("default").window(), Duration::ZERO);
        assert_eq!(
            parse(json!({"coalesce_ms": 250})).expect("250").window(),
            ms(250)
        );
        assert_eq!(
            parse(json!({"coalesce_ms": 999_999}))
                .expect("big")
                .window(),
            ms(5000)
        );
        assert!(parse(json!({"coalesce_ms": "250"})).is_err());
        assert!(parse(json!({"coalesce_ms": -1})).is_err());
        assert!(parse(json!({"coalesce_ms": 2.5})).is_err());
    }
}
