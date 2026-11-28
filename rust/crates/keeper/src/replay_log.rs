//! What the keeper keeps of a session for `session/load`, grouped in turns.
//!
//! A turn is a user message and everything up to the next one (a
//! `user_message_chunk` after agent activity opens the next turn; updates that
//! only restate session state are not activity). When the log passes its bounds
//! it gives up detail before it gives up turns: the heavy parts of the oldest
//! tool calls are cut away first (the row stays: title, kind, status,
//! locations), and only then are whole turns dropped, oldest first. The newest
//! turn is never cut or dropped, nor is a turn a waiting request is about.
//!
//! Sizes are measured as python's `json.dumps` measures them (non-ASCII
//! escaped): the format of the log and the golden fixture
//! (`tests/fixtures/replay_golden.json`) depend on it.

use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet, VecDeque};

const AMBIENT: [&str; 5] = [
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    "session_info_update",
    "usage_update",
];
const CHUNKS: [&str; 3] = [
    "agent_message_chunk",
    "agent_thought_chunk",
    "user_message_chunk",
];
const TOOLS: [&str; 2] = ["tool_call", "tool_call_update"];
const FINISHED: [&str; 3] = ["completed", "failed", "cancelled"];
const OUTPUT_META: [&str; 4] = [
    "terminal_output_delta",
    "terminal_output",
    "terminal_input",
    "mcp_output_delta",
];
const INPUT_KEYS: [&str; 8] = [
    "command",
    "file_path",
    "filePath",
    "path",
    "file",
    "pattern",
    "url",
    "query",
];
const TOOL_KEYS: [&str; 11] = [
    "sessionUpdate",
    "toolCallId",
    "title",
    "kind",
    "status",
    "locations",
    "name",
    "content",
    "rawInput",
    "rawOutput",
    "_meta",
];
/// Chunks merge into one entry up to this size, or a quarter of the byte bound.
const MERGE_MAX: usize = 262_144;
/// A restated state bigger than this is not worth replaying.
const CARRY_MAX: usize = 65_536;

/// One logged message and its size on the wire.
#[derive(Clone, Debug)]
pub struct Entry {
    id: u64,
    pub msg: Value,
    pub size: usize,
}

impl Entry {
    /// Names the entry for [`ReplayLog::remove`].
    #[must_use]
    pub fn id(&self) -> u64 {
        self.id
    }
}

#[derive(Debug)]
struct Turn {
    seq: u64,
    entries: VecDeque<Entry>,
    size: usize,
    user: bool,
    act: bool,
    /// Its heavy parts were looked at.
    slim: bool,
    /// And something was left out.
    cut: bool,
    tools: HashSet<String>,
}

impl Turn {
    fn new(seq: u64) -> Turn {
        Turn {
            seq,
            entries: VecDeque::new(),
            size: 0,
            user: false,
            act: false,
            slim: false,
            cut: false,
            tools: HashSet::new(),
        }
    }

    fn pinned(&self, pinned: &HashSet<String>) -> bool {
        !self.tools.is_disjoint(pinned)
    }
}

#[derive(Debug)]
pub struct ReplayLog {
    /// Hard: past it (or `max_entries`) turns are dropped.
    max_bytes: usize,
    max_entries: usize,
    full_turns: u64,
    soft_bytes: usize,
    turns: BTreeMap<u64, Turn>,
    last: Option<u64>,
    /// The last state update of each kind that a dropped turn held.
    carry: Vec<(String, Entry)>,
    bytes: usize,
    count: usize,
    next_seq: u64,
    next_entry: u64,
    /// The oldest turn the trim pass has not looked at.
    scan: u64,
    /// Turns the trim pass skipped because a request waits on them.
    late: Vec<u64>,
    /// Turns dropped, ever.
    dropped: u64,
    /// Turns held that had detail cut.
    trimmed: u64,
}

impl ReplayLog {
    #[must_use]
    pub fn new(
        max_bytes: usize,
        max_entries: usize,
        full_turns: u64,
        soft_bytes: Option<usize>,
    ) -> ReplayLog {
        ReplayLog {
            max_bytes,
            max_entries,
            full_turns,
            soft_bytes: soft_bytes
                .filter(|s| *s > 0)
                .map_or(max_bytes, |s| s.min(max_bytes)),
            turns: BTreeMap::new(),
            last: None,
            carry: Vec::new(),
            bytes: 0,
            count: 0,
            next_seq: 0,
            next_entry: 0,
            scan: 0,
            late: Vec::new(),
            dropped: 0,
            trimmed: 0,
        }
    }

    #[must_use]
    pub fn bytes(&self) -> usize {
        self.bytes
    }
    #[must_use]
    pub fn count(&self) -> usize {
        self.count
    }
    /// Turns dropped, ever.
    #[must_use]
    pub fn dropped(&self) -> u64 {
        self.dropped
    }
    /// Turns held that had detail cut.
    #[must_use]
    pub fn trimmed(&self) -> u64 {
        self.trimmed
    }
    /// The sequence number the next turn will get.
    #[must_use]
    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }
    #[must_use]
    pub fn turn_count(&self) -> usize {
        self.turns.len()
    }
    /// True when the log still holds the turn `seq` (a `since` that names a
    /// turn it has given up is answered with the whole log, python
    /// `replay_since`).
    #[must_use]
    pub fn has_turn(&self, seq: u64) -> bool {
        self.turns.contains_key(&seq)
    }

    /// Every entry in replay order.
    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.carry
            .iter()
            .map(|(_, e)| e)
            .chain(self.turns.values().flat_map(|t| t.entries.iter()))
    }

    /// `(entry, turn seq)` in replay order: what restates state first, then the
    /// turns from `since` on (all of them when it is `None`).
    pub fn replay(&self, since: Option<u64>) -> impl Iterator<Item = (&Entry, Option<u64>)> {
        let carried = self.carry.iter().map(|(_, e)| (e, None));
        let turns = self
            .turns
            .values()
            .filter(move |t| since.is_none_or(|s| t.seq >= s))
            .flat_map(|t| t.entries.iter().map(move |e| (e, Some(t.seq))));
        carried.chain(turns)
    }

    fn over(&self) -> bool {
        self.bytes > self.max_bytes || self.count > self.max_entries
    }

    /// Appends one update; `size` is its length on the wire and `waiting` names
    /// the tool calls a pending request is about. Returns the id of the entry
    /// that now holds `msg` (the one it merged into, or a new one).
    pub fn add(
        &mut self,
        msg: Value,
        size: usize,
        waiting: impl FnOnce() -> HashSet<String>,
    ) -> u64 {
        let kind = kind_of(&msg).map(str::to_string);
        let kind = kind.as_deref();
        let seq = match self
            .last
            .filter(|s| !(kind == Some("user_message_chunk") && self.turns[s].act))
        {
            Some(s) => s,
            None => {
                let s = self.next_seq;
                self.next_seq += 1;
                self.turns.insert(s, Turn::new(s));
                self.last = Some(s);
                s
            }
        };
        let merge_max = MERGE_MAX.min(self.max_bytes / 4);
        let fresh_id = self.next_entry;
        let t = self
            .turns
            .get_mut(&seq)
            .expect("the turn was just found or made");
        if kind == Some("user_message_chunk") {
            t.user = true;
        } else if !kind.is_some_and(|k| AMBIENT.contains(&k)) {
            t.act = true;
        }
        if let (Some(k), Some(id)) = (
            kind,
            update_of(&msg)
                .and_then(|u| u.get("toolCallId"))
                .and_then(Value::as_str),
        ) {
            if TOOLS.contains(&k) {
                t.tools.insert(id.to_string());
            }
        }
        let merged = match t.entries.back_mut() {
            Some(prev) if size + prev.size <= merge_max && mergeable(&prev.msg, &msg) => {
                append_text(&mut prev.msg, &msg);
                prev.size += size;
                Some(prev.id)
            }
            _ => None,
        };
        let entry_id = merged.unwrap_or_else(|| {
            t.entries.push_back(Entry {
                id: fresh_id,
                msg,
                size,
            });
            self.count += 1;
            self.next_entry += 1;
            fresh_id
        });
        t.size += size;
        self.bytes += size;
        if self.bytes > self.soft_bytes || self.over() {
            self.enforce(&waiting());
        }
        entry_id
    }

    /// Takes an entry back out: the user message of a prompt the agent refused.
    /// A turn left with no entry goes; one left with no user message (only what
    /// the agent streamed meanwhile) joins the turn before it, since it belongs
    /// to that one's activity. `false` when the entry is not in the log
    /// (dropped meanwhile).
    pub fn remove(&mut self, entry: u64) -> bool {
        let found = self.turns.iter().rev().find_map(|(seq, t)| {
            t.entries
                .iter()
                .position(|e| e.id == entry)
                .map(|i| (*seq, i))
        });
        let Some((seq, i)) = found else { return false };
        let t = self.turns.get_mut(&seq).expect("found a moment ago");
        let Some(e) = t.entries.remove(i) else {
            return false;
        };
        t.size -= e.size;
        self.bytes -= e.size;
        self.count -= 1;
        self.mend(seq);
        true
    }

    /// Settles turn `seq` after an entry left it.
    fn mend(&mut self, seq: u64) {
        let Some(t) = self.turns.get_mut(&seq) else {
            return;
        };
        let kinds: Vec<Option<&str>> = t.entries.iter().map(|e| kind_of(&e.msg)).collect();
        t.user = kinds.contains(&Some("user_message_chunk"));
        t.act = kinds
            .iter()
            .any(|k| *k != Some("user_message_chunk") && !k.is_some_and(|k| AMBIENT.contains(&k)));
        if !t.entries.is_empty() && t.user {
            return;
        }
        let before = self.turns.range(..seq).next_back().map(|(s, _)| *s);
        let mut t = self.turns.remove(&seq).expect("looked up above");
        if !t.entries.is_empty() {
            let Some(b) = before else {
                // The first turn: it stays, as one that opens with no user message.
                self.turns.insert(seq, t);
                return;
            };
            let prev = self.turns.get_mut(&b).expect("found above");
            prev.entries.append(&mut t.entries);
            prev.size += t.size;
            prev.act = prev.act || t.act;
            prev.tools.extend(t.tools);
            prev.slim = prev.slim && t.slim;
            if t.cut {
                if prev.cut {
                    self.trimmed -= 1;
                }
                prev.cut = true;
            }
        } else if t.cut {
            self.trimmed -= 1;
        }
        if self.last == Some(seq) {
            self.last = before;
        }
    }

    fn enforce(&mut self, pinned: &HashSet<String>) {
        // The soft budget is what a replay costs the phone: old detail goes as
        // soon as it is passed, and nothing else (no turn is dropped for it).
        while self.bytes > self.soft_bytes {
            if !self.trim_next(pinned) {
                break;
            }
        }
        while self.over() {
            if let Some(last) = self.last.filter(|l| self.bulk(*l)) {
                // The turn in flight is what fills the log (omp sends an update
                // for every beat and chunk of a long command). The turns before it
                // are a sliver, so dropping them frees next to nothing and only
                // loses the conversation: it eats its own oldest entries instead.
                if self.trim_next(pinned) || self.cut_oldest(Some(last)) {
                    continue;
                }
                break;
            }
            if !(self.trim_next(pinned) || self.drop_next(pinned) || self.cut_oldest(None)) {
                break;
            }
        }
    }

    /// Whether turn `seq` alone is over a bound, or, past the entry bound, holds
    /// more than half of what that bound allows: dropping the turns before it
    /// cannot be what makes room.
    fn bulk(&self, seq: u64) -> bool {
        let t = &self.turns[&seq];
        if t.size > self.max_bytes || t.entries.len() > self.max_entries {
            return true;
        }
        self.count > self.max_entries && t.entries.len() * 2 > self.max_entries
    }

    /// Cuts the heavy parts out of the oldest turn not yet cut: outside the
    /// newest `full_turns` first. `false` when there is none to cut.
    fn trim_next(&mut self, pinned: &HashSet<String>) -> bool {
        self.late.retain(|s| self.turns.contains_key(s));
        if let Some(i) = self.late.iter().position(|s| !self.turns[s].pinned(pinned)) {
            let s = self.late.remove(i);
            self.slim_turn(s);
            return true;
        }
        let limit = self.next_seq.saturating_sub(self.full_turns);
        while self.scan < limit {
            let s = self.scan;
            self.scan += 1;
            let Some(t) = self.turns.get(&s) else {
                continue;
            };
            if t.slim {
                continue;
            }
            if self.last == Some(s) || t.pinned(pinned) {
                self.late.push(s);
                continue;
            }
            self.slim_turn(s);
            return true;
        }
        // Then the newest turns, oldest first, but never the newest: they keep
        // their detail for as long as the budget allows, and a cut turn is still
        // a turn of the conversation, which dropping it is not.
        let take = usize::try_from(self.full_turns).unwrap_or(usize::MAX);
        let recent: Vec<u64> = self.turns.keys().rev().take(take).copied().collect();
        for s in recent.into_iter().rev() {
            let t = &self.turns[&s];
            if self.last != Some(s) && !t.slim && !t.pinned(pinned) {
                self.slim_turn(s);
                return true;
            }
        }
        false
    }

    fn slim_turn(&mut self, seq: u64) {
        let mut next_entry = self.next_entry;
        let t = self.turns.get_mut(&seq).expect("a turn that exists");
        t.slim = true;
        let finished: HashSet<String> = t
            .entries
            .iter()
            .filter_map(|e| {
                let u = update_of(&e.msg)?;
                let tool = u
                    .get("sessionUpdate")
                    .and_then(Value::as_str)
                    .is_some_and(|k| TOOLS.contains(&k));
                let done = u
                    .get("status")
                    .and_then(Value::as_str)
                    .is_some_and(|s| FINISHED.contains(&s));
                (tool && done)
                    .then(|| u.get("toolCallId")?.as_str().map(str::to_string))
                    .flatten()
            })
            .collect();

        enum Slot {
            Kept(Entry),
            Row(usize),
        }
        struct Row {
            session_id: Value,
            small: Map<String, Value>,
            hit: bool,
            tag: Option<String>,
        }
        let old_len = t.entries.len();
        let mut out: Vec<Slot> = Vec::new();
        let mut rows: Vec<Row> = Vec::new();
        // A finished call becomes one entry: tool call id -> its row.
        let mut merged: BTreeMap<String, usize> = BTreeMap::new();
        for e in std::mem::take(&mut t.entries) {
            let Some(u) = update_of(&e.msg).filter(|u| {
                u.get("sessionUpdate")
                    .and_then(Value::as_str)
                    .is_some_and(|k| TOOLS.contains(&k))
            }) else {
                out.push(Slot::Kept(e));
                continue;
            };
            let (small, hit) = trim_tool(u);
            let tid = u
                .get("toolCallId")
                .and_then(Value::as_str)
                .filter(|id| finished.contains(*id))
                .map(str::to_string);
            if let Some(&r) = tid.as_ref().and_then(|id| merged.get(id)) {
                fold_tool(&mut rows[r].small, &small);
                rows[r].hit = rows[r].hit || hit;
                if rows[r].tag.is_none() {
                    rows[r].tag = parent_tag(u);
                }
                continue;
            }
            let session_id = e
                .msg
                .pointer("/params/sessionId")
                .cloned()
                .unwrap_or(Value::Null);
            rows.push(Row {
                session_id,
                small,
                hit,
                tag: parent_tag(u),
            });
            if let Some(id) = tid {
                merged.insert(id, rows.len() - 1);
            }
            out.push(Slot::Row(rows.len() - 1));
        }
        let mut any_cut = false;
        let mut built: Vec<Option<Entry>> = Vec::with_capacity(rows.len());
        for row in rows {
            let Row {
                session_id,
                mut small,
                hit,
                tag,
            } = row;
            if let Some(tag) = tag {
                if parent_tag(&Value::Object(small.clone())).as_deref() != Some(tag.as_str()) {
                    set_nested(
                        &mut small,
                        &["_meta", "claudeCode", "parentToolUseId"],
                        Value::String(tag),
                    );
                }
            }
            if hit {
                any_cut = true;
                set_nested(&mut small, &["_meta", "herdr"], json!({"trimmed": true}));
            }
            let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": Value::Object(small)}});
            let size = ascii_len(&msg);
            built.push(Some(Entry {
                id: next_entry,
                msg,
                size,
            }));
            next_entry += 1;
        }
        let entries: VecDeque<Entry> = out
            .into_iter()
            .map(|s| match s {
                Slot::Kept(e) => e,
                Slot::Row(i) => built[i].take().expect("each row is used once"),
            })
            .collect();
        let n: usize = entries.iter().map(|e| e.size).sum();
        self.bytes = self.bytes + n - t.size;
        self.count = self.count + entries.len() - old_len;
        t.entries = entries;
        t.size = n;
        if any_cut && !t.cut {
            t.cut = true;
            self.trimmed += 1;
        }
        self.next_entry = next_entry;
    }

    /// An entry that leaves the log but restates session state (the mode, the
    /// command list) is remembered: the last of each kind still replays.
    fn keep_state(&mut self, e: Entry) {
        let Some(k) = kind_of(&e.msg)
            .filter(|k| AMBIENT.contains(k))
            .map(str::to_string)
        else {
            return;
        };
        if e.size > CARRY_MAX {
            return;
        }
        match self.carry.iter_mut().find(|(name, _)| *name == k) {
            Some(slot) => slot.1 = e,
            None => self.carry.push((k, e)),
        }
    }

    /// Drops the oldest turn that is not the newest and that no waiting request
    /// is about, whole. `false` when there is none.
    fn drop_next(&mut self, pinned: &HashSet<String>) -> bool {
        let mut pick = None;
        for (seq, t) in &self.turns {
            if self.last == Some(*seq) {
                return false;
            }
            if !t.pinned(pinned) {
                pick = Some(*seq);
                break;
            }
        }
        let Some(seq) = pick else { return false };
        let t = self.turns.remove(&seq).expect("picked from the map");
        self.bytes -= t.size;
        self.count -= t.entries.len();
        if t.user || t.act {
            self.dropped += 1;
        }
        if t.cut {
            self.trimmed -= 1;
        }
        for e in t.entries {
            self.keep_state(e);
        }
        true
    }

    /// Last resort, when what is left (the newest turn, a waiting one) is over
    /// the bounds by itself: the oldest entry that is not a user message, never
    /// the newest entry; of the turn `only` when given, else of the oldest turn
    /// that has one. `false` when there is none.
    fn cut_oldest(&mut self, only: Option<u64>) -> bool {
        let seqs: Vec<u64> = only.map_or_else(|| self.turns.keys().copied().collect(), |s| vec![s]);
        for seq in seqs {
            let is_last = self.last == Some(seq);
            let t = self.turns.get_mut(&seq).expect("a turn that exists");
            let mut keep = Vec::new();
            while t
                .entries
                .front()
                .is_some_and(|e| kind_of(&e.msg) == Some("user_message_chunk"))
            {
                keep.extend(t.entries.pop_front());
            }
            let ok = t.entries.len() > 1 || (t.entries.len() == 1 && !is_last);
            let gone = if ok { t.entries.pop_front() } else { None };
            if let Some(e) = &gone {
                t.size -= e.size;
                self.bytes -= e.size;
                self.count -= 1;
                if !t.cut {
                    t.cut = true;
                    self.trimmed += 1;
                }
            }
            for e in keep.into_iter().rev() {
                t.entries.push_front(e);
            }
            if let Some(e) = gone {
                self.keep_state(e);
                return true;
            }
        }
        false
    }
}

fn update_of(msg: &Value) -> Option<&Value> {
    msg.get("params")?.get("update").filter(|u| u.is_object())
}

fn kind_of(msg: &Value) -> Option<&str> {
    update_of(msg)?.get("sessionUpdate")?.as_str()
}

fn parent_tag(u: &Value) -> Option<String> {
    let p = u
        .get("_meta")?
        .get("claudeCode")?
        .get("parentToolUseId")?
        .as_str()?;
    (!p.is_empty()).then(|| p.to_string())
}

/// Length of `v` as python's `json.dumps(v, separators=(",", ":"))` writes it:
/// non-ASCII characters are escaped (`\uXXXX`, a surrogate pair past the BMP).
fn ascii_len(v: &Value) -> usize {
    v.to_string()
        .chars()
        .map(|c| if c.is_ascii() { 1 } else { 6 * c.len_utf16() })
        .sum()
}

fn chars_prefix(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn mergeable(a: &Value, b: &Value) -> bool {
    if a.pointer("/params/sessionId") != b.pointer("/params/sessionId") {
        return false;
    }
    let (Some(ua), Some(ub)) = (update_of(a), update_of(b)) else {
        return false;
    };
    let kind = ua.get("sessionUpdate").and_then(Value::as_str);
    if !kind.is_some_and(|k| CHUNKS.contains(&k))
        || kind != ub.get("sessionUpdate").and_then(Value::as_str)
    {
        return false;
    }
    if ua.get("messageId") != ub.get("messageId") {
        return false;
    }
    [ua, ub].iter().all(|u| {
        let keys_ok = u.as_object().is_some_and(|o| {
            o.keys()
                .all(|k| ["sessionUpdate", "content", "messageId"].contains(&k.as_str()))
        });
        let text = u
            .get("content")
            .and_then(Value::as_object)
            .is_some_and(|c| {
                c.get("type").and_then(Value::as_str) == Some("text")
                    && c.get("text").is_some_and(Value::is_string)
                    && c.keys().all(|k| k == "type" || k == "text")
            });
        keys_ok && text
    })
}

fn append_text(into: &mut Value, from: &Value) {
    let add = from
        .pointer("/params/update/content/text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if let Some(Value::String(s)) = into.pointer_mut("/params/update/content/text") {
        s.push_str(&add);
    }
}

/// What names a call in a row (its command or path) out of a tool's input.
fn trim_input(v: &Value) -> Option<Value> {
    match v {
        Value::String(s) => Some(Value::String(chars_prefix(s, 300))),
        Value::Object(o) => {
            let out: Map<String, Value> = INPUT_KEYS
                .iter()
                .filter_map(|k| {
                    Some((
                        (*k).to_string(),
                        Value::String(chars_prefix(o.get(*k)?.as_str()?, 300)),
                    ))
                })
                .collect();
            (!out.is_empty()).then_some(Value::Object(out))
        }
        _ => None,
    }
}

fn trim_content(items: &Value) -> Value {
    let Some(a) = items.as_array() else {
        return json!([]);
    };
    Value::Array(
        a.iter()
            .filter(|it| {
                it.is_object()
                    && (it.get("type").and_then(Value::as_str) == Some("terminal")
                        || ascii_len(it) <= 400)
            })
            .cloned()
            .collect(),
    )
}

fn trim_meta(m: &Map<String, Value>) -> Value {
    let mut out = Map::new();
    for (k, v) in m {
        if OUTPUT_META.contains(&k.as_str()) {
            continue;
        }
        let mut v = v.clone();
        if ascii_len(&v) > 2000 {
            match (k.as_str(), &v) {
                // Claude's copy of the whole result lives here; the subagent tag must stay.
                ("claudeCode", Value::Object(cc)) => {
                    let keep: Map<String, Value> = cc
                        .iter()
                        .filter(|(a, _)| *a == "toolName" || *a == "parentToolUseId")
                        .map(|(a, b)| (a.clone(), b.clone()))
                        .collect();
                    v = Value::Object(keep);
                }
                _ => continue,
            }
        }
        out.insert(k.clone(), v);
    }
    Value::Object(out)
}

/// The update without its heavy parts, and whether anything was left out.
fn trim_tool(u: &Value) -> (Map<String, Value>, bool) {
    let mut small = Map::new();
    for (k, v) in u.as_object().into_iter().flatten() {
        match (k.as_str(), v) {
            ("rawOutput", _) => {}
            ("rawInput", Value::Null) => {
                small.insert(k.clone(), Value::Null);
            }
            ("rawInput", v) => {
                if let Some(t) = trim_input(v) {
                    small.insert(k.clone(), t);
                }
            }
            ("content", Value::Null) => {
                small.insert(k.clone(), Value::Null);
            }
            ("content", v) => {
                small.insert(k.clone(), trim_content(v));
            }
            ("_meta", Value::Object(m)) => {
                small.insert(k.clone(), trim_meta(m));
            }
            ("title", Value::String(s)) => {
                small.insert(k.clone(), Value::String(chars_prefix(s, 500)));
            }
            ("locations", Value::Array(a)) => {
                small.insert(
                    k.clone(),
                    Value::Array(a.iter().take(20).cloned().collect()),
                );
            }
            (k2, v) if TOOL_KEYS.contains(&k2) || ascii_len(v) <= 2000 => {
                small.insert(k.clone(), v.clone());
            }
            _ => {}
        }
    }
    let hit = ascii_len(&Value::Object(small.clone())) < ascii_len(u);
    (small, hit)
}

/// Lays a later update of a call over the merged one, as a reader would.
fn fold_tool(into: &mut Map<String, Value>, small: &Map<String, Value>) {
    for (k, v) in small {
        match (k.as_str(), v) {
            ("sessionUpdate", v) => {
                if v == "tool_call" {
                    into.insert(k.clone(), v.clone());
                }
            }
            ("_meta", Value::Object(new)) if into.get("_meta").is_some_and(Value::is_object) => {
                if let Some(Value::Object(old)) = into.get_mut("_meta") {
                    for (a, b) in new {
                        old.insert(a.clone(), b.clone());
                    }
                }
            }
            _ => {
                into.insert(k.clone(), v.clone());
            }
        }
    }
}

/// Sets `path` inside `map`, making (or replacing a non-object with) objects on the way.
fn set_nested(map: &mut Map<String, Value>, path: &[&str], value: Value) {
    let (first, rest) = path.split_first().expect("a non-empty path");
    if rest.is_empty() {
        map.insert((*first).to_string(), value);
        return;
    }
    let entry = map.entry((*first).to_string()).or_insert_with(|| json!({}));
    if !entry.is_object() {
        *entry = json!({});
    }
    if let Value::Object(inner) = entry {
        set_nested(inner, rest, value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(update: Value) -> Value {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": update}})
    }

    fn user(text: &str) -> Value {
        note(
            json!({"sessionUpdate": "user_message_chunk", "messageId": format!("u-{text}"), "content": {"type": "text", "text": text}}),
        )
    }

    fn agent(mid: &str, text: &str) -> Value {
        note(
            json!({"sessionUpdate": "agent_message_chunk", "messageId": mid, "content": {"type": "text", "text": text}}),
        )
    }

    fn tool(id: &str, status: &str, output: usize) -> Value {
        let kind = if status == "pending" {
            "tool_call"
        } else {
            "tool_call_update"
        };
        note(
            json!({"sessionUpdate": kind, "toolCallId": id, "title": format!("run {id}"), "kind": "execute", "status": status,
            "rawInput": {"command": "ls", "extra": "x".repeat(50)}, "rawOutput": "o".repeat(output)}),
        )
    }

    fn mode(name: &str) -> Value {
        note(json!({"sessionUpdate": "current_mode_update", "currentModeId": name}))
    }

    fn put(log: &mut ReplayLog, msg: Value) -> u64 {
        let size = ascii_len(&msg);
        log.add(msg, size, HashSet::new)
    }

    fn texts(log: &ReplayLog, since: Option<u64>) -> Vec<String> {
        log.replay(since)
            .filter_map(|(e, _)| {
                update_of(&e.msg)?
                    .pointer("/content/text")?
                    .as_str()
                    .map(str::to_string)
            })
            .collect()
    }

    fn big() -> ReplayLog {
        ReplayLog::new(1 << 30, 1 << 20, 3, None)
    }

    #[test]
    fn a_user_message_after_activity_opens_the_next_turn_and_ambient_updates_are_not_activity() {
        let mut log = big();
        put(&mut log, mode("plan"));
        put(&mut log, user("one"));
        put(&mut log, mode("act"));
        put(&mut log, agent("a1", "answer"));
        assert_eq!(log.turn_count(), 1);
        put(&mut log, user("two"));
        assert_eq!(log.turn_count(), 2);
        // Two user chunks in a row, with no activity between them, stay one turn.
        put(&mut log, user("two b"));
        assert_eq!(log.turn_count(), 2);
    }

    #[test]
    fn chunks_of_one_message_merge_but_a_new_message_or_an_extra_field_does_not() {
        let mut log = big();
        put(&mut log, user("q"));
        let a = put(&mut log, agent("m1", "he"));
        let b = put(&mut log, agent("m1", "llo"));
        assert_eq!(a, b);
        put(&mut log, agent("m2", "next"));
        let mut odd = agent("m2", "!");
        odd["params"]["update"]["_meta"] = json!({"x": 1});
        put(&mut log, odd);
        assert_eq!(texts(&log, None), ["q", "hello", "next", "!"]);
        assert_eq!(log.count(), 4);
    }

    #[test]
    fn the_oldest_turns_are_dropped_whole_and_the_newest_is_never_dropped() {
        let mut log = ReplayLog::new(900, 1000, 1, None);
        for i in 0..6 {
            put(&mut log, user(&format!("q{i}")));
            put(&mut log, agent(&format!("m{i}"), &"w".repeat(100)));
        }
        assert!(log.dropped() > 0);
        let t = texts(&log, None);
        assert!(t.contains(&"q5".to_string()), "{t:?}");
        assert!(!t.contains(&"q0".to_string()));
        assert!(log.bytes() <= 900);
    }

    #[test]
    fn a_turn_a_waiting_request_is_about_is_not_dropped() {
        let mut log = ReplayLog::new(1200, 1000, 1, None);
        put(&mut log, user("q0"));
        let t = tool("waiting", "pending", 0);
        let size = ascii_len(&t);
        log.add(t, size, HashSet::new);
        for i in 1..8 {
            let msg = user(&format!("q{i}"));
            let size = ascii_len(&msg);
            log.add(msg, size, || HashSet::from(["waiting".to_string()]));
            let msg = agent(&format!("m{i}"), &"w".repeat(200));
            let size = ascii_len(&msg);
            log.add(msg, size, || HashSet::from(["waiting".to_string()]));
        }
        assert!(texts(&log, None).contains(&"q0".to_string()));
        assert!(log.entries().any(|e| update_of(&e.msg)
            .and_then(|u| u.get("toolCallId"))
            .is_some()));
    }

    #[test]
    fn detail_goes_before_turns_do_and_the_row_stays() {
        // Soft bound below the hard one: heavy tool output is cut, no turn is dropped.
        let mut log = ReplayLog::new(1 << 20, 1000, 1, Some(2000));
        for i in 0..4 {
            put(&mut log, user(&format!("q{i}")));
            put(&mut log, tool(&format!("t{i}"), "pending", 0));
            put(&mut log, tool(&format!("t{i}"), "completed", 3000));
            put(&mut log, agent(&format!("m{i}"), "done"));
        }
        assert_eq!(log.dropped(), 0);
        assert_eq!(log.turn_count(), 4);
        assert!(log.trimmed() >= 1);
        let first_tool = log
            .entries()
            .find_map(|e| update_of(&e.msg).filter(|u| u.get("toolCallId").is_some()))
            .expect("a tool row stays");
        assert_eq!(first_tool["title"], "run t0");
        assert_eq!(first_tool["status"], "completed");
        assert!(first_tool.get("rawOutput").is_none());
        assert_eq!(first_tool["rawInput"], json!({"command": "ls"}));
        assert_eq!(first_tool["_meta"]["herdr"]["trimmed"], true);
        // The newest turn keeps its detail.
        let newest = log
            .entries()
            .filter_map(|e| update_of(&e.msg))
            .filter(|u| u["toolCallId"] == "t3")
            .count();
        assert_eq!(newest, 2);
    }

    #[test]
    fn a_finished_call_becomes_one_entry_when_its_turn_is_trimmed() {
        let mut log = ReplayLog::new(1 << 20, 1000, 1, Some(1500));
        put(&mut log, user("q0"));
        put(&mut log, tool("a", "pending", 0));
        put(&mut log, tool("a", "in_progress", 2000));
        put(&mut log, tool("a", "completed", 2000));
        put(&mut log, user("q1"));
        put(&mut log, agent("m", "x"));
        put(&mut log, user("q2"));
        put(&mut log, agent("m2", "y"));
        let rows: Vec<_> = log
            .entries()
            .filter_map(|e| update_of(&e.msg))
            .filter(|u| u["toolCallId"] == "a")
            .collect();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["status"], "completed");
        assert_eq!(
            rows[0]["sessionUpdate"], "tool_call",
            "the first update's kind wins"
        );
    }

    #[test]
    fn the_last_mode_of_a_dropped_turn_still_replays_first() {
        let mut log = ReplayLog::new(700, 1000, 1, None);
        put(&mut log, user("q0"));
        put(&mut log, mode("plan"));
        put(&mut log, agent("m0", &"w".repeat(100)));
        for i in 1..6 {
            put(&mut log, user(&format!("q{i}")));
            put(&mut log, agent(&format!("m{i}"), &"w".repeat(100)));
        }
        assert!(log.dropped() > 0);
        let first = log.entries().next().expect("something replays");
        assert_eq!(kind_of(&first.msg), Some("current_mode_update"));
        assert!(log
            .replay(None)
            .next()
            .is_some_and(|(_, seq)| seq.is_none()));
    }

    #[test]
    fn since_skips_older_turns_but_keeps_restated_state() {
        let mut log = big();
        put(&mut log, user("q0"));
        put(&mut log, agent("a", "r0"));
        put(&mut log, user("q1"));
        put(&mut log, agent("b", "r1"));
        assert_eq!(texts(&log, Some(1)), ["q1", "r1"]);
        assert_eq!(texts(&log, None), ["q0", "r0", "q1", "r1"]);
    }

    #[test]
    fn removing_a_refused_prompt_drops_its_turn_or_hands_the_rest_to_the_turn_before() {
        let mut log = big();
        put(&mut log, user("q0"));
        put(&mut log, agent("a", "r0"));
        let refused = put(&mut log, user("q1"));
        assert_eq!(log.turn_count(), 2);
        assert!(log.remove(refused));
        assert_eq!(log.turn_count(), 1);

        // The agent streamed something meanwhile: it joins the turn before.
        let refused = put(&mut log, user("q2"));
        put(&mut log, agent("b", "meanwhile"));
        assert!(log.remove(refused));
        assert_eq!(log.turn_count(), 1);
        assert_eq!(texts(&log, None), ["q0", "r0", "meanwhile"]);
        assert!(
            !log.remove(refused),
            "an entry that is gone is not removed twice"
        );
        assert_eq!(log.count(), 3);
    }

    #[test]
    fn a_turn_that_fills_the_log_eats_its_own_oldest_entries_and_spares_the_turns_before() {
        let mut log = ReplayLog::new(1 << 30, 20, 3, None);
        put(&mut log, user("q0"));
        put(&mut log, agent("a", "r0"));
        put(&mut log, user("q1"));
        for i in 0..60 {
            put(&mut log, agent(&format!("m{i}"), &format!("beat{i}")));
        }
        assert!(log.count() <= 20);
        assert_eq!(
            log.dropped(),
            0,
            "the earlier turn is a sliver: dropping it frees nothing"
        );
        let t = texts(&log, None);
        assert!(t.contains(&"q0".to_string()) && t.contains(&"q1".to_string()));
        assert!(t.contains(&"beat59".to_string()) && !t.contains(&"beat0".to_string()));
    }

    #[test]
    fn sizes_count_non_ascii_the_way_python_escapes_it() {
        assert_eq!(ascii_len(&json!("é")), 8);
        assert_eq!(ascii_len(&json!("😀")), 14);
        assert_eq!(ascii_len(&json!({"a": 1})), 7);
    }

    #[test]
    fn the_counters_always_match_what_is_held() {
        let mut log = ReplayLog::new(3000, 40, 2, Some(1500));
        for i in 0..30 {
            put(&mut log, user(&format!("q{i}")));
            put(&mut log, tool(&format!("t{i}"), "pending", 0));
            put(&mut log, tool(&format!("t{i}"), "completed", 400 * (i % 4)));
            put(&mut log, agent(&format!("m{i}"), "ok"));
            let held: usize = log
                .entries()
                .filter(|e| {
                    log.turns
                        .values()
                        .any(|t| t.entries.iter().any(|x| x.id == e.id))
                })
                .map(|e| e.size)
                .sum();
            assert_eq!(held, log.bytes(), "bytes after turn {i}");
            let n = log.turns.values().map(|t| t.entries.len()).sum::<usize>();
            assert_eq!(n, log.count(), "count after turn {i}");
        }
    }
}
