//! `follow`: read one agent's on-disk session log (`.jsonl`) and stream it to
//! the phone, daemon-free. The wire, the scrubbing and the offsets are a byte
//! for byte from the python keeper (`keeper_script.dart` 4297-4693): one record
//! per line `<endOffset>\t<json>` (long strings cut, binary payloads dropped
//! with a `ref=` to `blob`), plus `S\t<offset>` (a tail read's start), `R\t<offset>`
//! (the file shrank or was replaced), `C\t<offset>` (up to here is sent) and
//! `E\t<message>` (reading failed, exit 70). `--z` zips a batch of at least
//! `zlib_batch::ATTACH_ZIP_MIN` bytes into one `Z` line of one zlib stream.
//!
//! The offsets and the line accounting must match the python exactly, because
//! the phone resumes at the offsets it is given and `blob` fetches by them.

use crate::exit;
use crate::zlib_batch::{self, Zlib};
use serde_json::Value;
use sha1::{Digest, Sha1};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// The log's byte bounds (python `FOLLOW_*`).
const TAIL: u64 = 192 * 1024;
const TAIL_MIN: u64 = 16 * 1024;
const TAIL_MAX: u64 = 64 * 1024 * 1024;
const CUT: usize = 16 * 1024;
const DIGEST_CUT: usize = 8 * 1024;
const RAW: usize = 2048;
const LINE_MAX: u64 = 4 * 1024 * 1024;
const READ: u64 = 1024 * 1024;
/// `(after, every)` back-off of the poll while the file is quiet.
const BACKOFF: [(f64, f64); 2] = [(60.0, 1.0), (600.0, 2.0)];
const BINARY_TYPES: [&str; 6] = [
    "image",
    "base64",
    "audio",
    "input_audio",
    "input_image",
    "binary",
];
const BINARY_KEYS: [&str; 5] = ["data", "base64", "bytes", "b64_json", "blob"];
/// What `slim` drops from an omp assistant message (`OmpLogMapper` never reads).
const MESSAGE_NOISE: [&str; 10] = [
    "usage",
    "contextSnapshot",
    "responseId",
    "credentialId",
    "duration",
    "ttft",
    "completedAt",
    "api",
    "provider",
    "errorId",
];
/// What `digest` does not send at all.
const DIGEST_DROP: [&str; 2] = ["custom", "model_usage"];

/// `s` cut to its first `limit` bytes (UTF-8) and a note, if longer.
fn cut_str(s: &str, limit: usize) -> String {
    // A cheap bound: if it can't fit even in 4 bytes/char, it is over.
    if s.len() * 4 <= limit {
        return s.to_string();
    }
    if s.len() <= limit {
        return s.to_string();
    }
    let b = s.as_bytes();
    // Cut on a character boundary.
    let mut end = limit.min(b.len());
    while end > 0 && !b[end].is_ascii() && (b[end] & 0xC0) == 0x80 {
        end -= 1;
    }
    let head = String::from_utf8_lossy(&b[..end]).into_owned();
    let cut = s.len() - head.len();
    format!("{head}... [{cut} bytes cut]")
}

/// The part of string `x` (value of key `k`) that `scrub` drops, or `None`.
/// `binary`: the object that holds it is typed as a binary one.
fn binary_payload(binary: bool, k: &str, x: &str) -> Option<String> {
    let n = x.len();
    // A data URI keeps its `data:<type>;base64,` in the note: the type is what
    // the phone shows before the picture.
    if n > 256 && x.starts_with("data:") && x.get(..128).is_some_and(|h| h.contains(',')) {
        return x.split_once(',').map(|(_, p)| p.to_string());
    }
    let b64 = |s: &str| {
        s.len() >= 256
            && s.bytes()
                .take(256)
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'=' | b'_' | b'-'))
    };
    if (binary && n > 256) || (BINARY_KEYS.contains(&k) && n > 1024 && b64(&x[..256.min(n)])) {
        return Some(x.to_string());
    }
    None
}

/// The 16 lowercase hex digits of the payload's SHA-1 (python `payload_hash`).
fn payload_hash(p: &str) -> String {
    let mut h = Sha1::new();
    h.update(p.as_bytes());
    let d = h.finalize();
    d[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// `v` with every long string cut and every binary payload dropped; the
/// structure stays, so the result is JSON of the same shape. With `start` (the
/// log line's offset), a dropped payload says where it can be fetched again.
fn scrub(v: &Value, start: Option<u64>, limit: usize) -> Value {
    match v {
        Value::String(s) => Value::String(cut_str(s, limit)),
        Value::Array(a) => Value::Array(a.iter().map(|x| scrub(x, start, limit)).collect()),
        Value::Object(o) => {
            let binary = o
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|t| BINARY_TYPES.contains(&t));
            let mut out = serde_json::Map::new();
            for (k, x) in o {
                let kv = cut_str(k, limit);
                let vx = match x {
                    Value::String(s) => match binary_payload(binary, k, s) {
                        None => Value::String(cut_str(s, limit)),
                        Some(p) => {
                            let n = s.len();
                            let note = match start {
                                None => format!("[{n} bytes of data not sent]"),
                                Some(st) => format!(
                                    "[{n} bytes of data not sent; ref={st}.{}]",
                                    payload_hash(&p)
                                ),
                            };
                            Value::String(s[..n - p.len()].to_string() + &note)
                        }
                    },
                    other => scrub(other, start, limit),
                };
                out.insert(kv, vx);
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

/// `v` (one log line as parsed) without what the phone never reads, or `None`
/// for an entry that is only bookkeeping (`credential_pin`).
fn slim(v: Value) -> Option<Value> {
    let is_pin = v.get("type").and_then(Value::as_str) == Some("credential_pin");
    let is_message = v.get("type").and_then(Value::as_str) == Some("message");
    if is_pin {
        return None;
    }
    let mut out = v;
    // Only a message entry's message is trimmed: other roles and entry types
    // may carry keys of the same names.
    if is_message {
        if let Some(Value::Object(m)) = out.get_mut("message") {
            if m.get("role").and_then(Value::as_str) == Some("assistant") {
                for k in MESSAGE_NOISE {
                    m.remove(k);
                }
                if let Some(Value::Array(c)) = m.get_mut("content") {
                    for b in c {
                        if let Some(b) = b.as_object_mut() {
                            if b.get("type").and_then(Value::as_str) == Some("thinking") {
                                b.remove("thinkingSignature");
                            }
                        }
                    }
                }
            }
            if let Some(Value::Object(d)) = m.get_mut("details") {
                d.remove("displayContent");
            }
        }
    }
    Some(out)
}

/// `o` as `follow --digest` sends it: the model's thinking is emptied and the
/// bookkeeping entries are not sent (`None`).
fn digest(o: Value) -> Option<Value> {
    let is_drop = o
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(|t| DIGEST_DROP.contains(&t));
    if is_drop {
        return None;
    }
    let mut out = o;
    if let Some(Value::Object(m)) = out.get_mut("message") {
        if let Some(Value::Array(c)) = m.get_mut("content") {
            for b in c {
                if let Some(b) = b.as_object_mut() {
                    if b.get("type").and_then(Value::as_str) == Some("thinking")
                        && b.get("thinking").is_some_and(Value::is_string)
                    {
                        b.insert("thinking".into(), Value::String(String::new()));
                    }
                }
            }
        }
    }
    Some(out)
}

/// One log line (bytes) as the compact UTF-8 JSON the phone gets, or `None`
/// for a blank line or one the phone has no use for. Whatever is not JSON
/// becomes `{"raw": first 2 KB}`.
fn follow_record(raw: &[u8], start: Option<u64>, brief: bool) -> Option<Vec<u8>> {
    // blank?
    if raw.iter().all(|b| b.is_ascii_whitespace()) {
        return None;
    }
    let limit = if brief { DIGEST_CUT } else { CUT };
    // A line that is not JSON becomes `{"raw": first 2 KB}`; a line that parses
    // but the phone has no use for (a credential pin, a digest-dropped entry)
    // is dropped.
    let raw = sanitize_surrogates(raw);
    let parsed = match serde_json::from_slice::<Value>(&raw) {
        Ok(v) => v,
        Err(_) => {
            let head = String::from_utf8_lossy(&raw[..RAW.min(raw.len())]).into_owned();
            let out = serde_json::to_string(&serde_json::json!({"raw": head})).ok()?;
            return Some(out.into_bytes());
        }
    };
    let obj = slim(parsed).and_then(|o| if brief { digest(o) } else { Some(o) })?;
    let out = serde_json::to_string(&scrub(&obj, start, limit)).ok()?;
    Some(out.into_bytes())
}

/// The bytes of `raw` with every unpaired surrogate escape (`\ud800`-`\udfff`
/// that is not half of a `\ud800-\udbff` + `\udc00-\udfff` pair) replaced by
/// `\ufffd`, so a line an agent wrote with a lone surrogate still parses:
/// Python's `json.loads` accepts it, `serde_json` does not.
fn sanitize_surrogates(raw: &[u8]) -> Vec<u8> {
    let s = match std::str::from_utf8(raw) {
        Ok(s) => s,
        Err(_) => return raw.to_vec(),
    };
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        // A `\uXXXX` escape.
        if bytes[i] == b'\\' && i + 6 <= bytes.len() && bytes[i + 1] == b'u' {
            let hex = &s[i + 2..i + 6];
            let cp = u32::from_str_radix(hex, 16).unwrap_or(0);
            if (0xd800..=0xdfff).contains(&cp) {
                // A high surrogate followed by a low one is a valid pair: keep
                // both. Otherwise it is unpaired: replace with `\ufffd`.
                let paired = cp <= 0xdbff
                    && i + 12 <= bytes.len()
                    && bytes[i + 6] == b'\\'
                    && bytes[i + 7] == b'u'
                    && (0xdc00..=0xdfff)
                        .contains(&u32::from_str_radix(&s[i + 8..i + 12], 16).unwrap_or(0));
                if paired {
                    out.extend_from_slice(&bytes[i..i + 12]);
                    i += 12;
                    continue;
                }
                out.extend_from_slice(b"\\ufffd");
                i += 6;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

/// The real path of `path`, which must be an absolute `.jsonl` file under
/// `$HOME` that this user can read; `Err` (exit 66) otherwise.
fn follow_target(path: &str, sentence: Option<&str>) -> Result<PathBuf, String> {
    let not_abs = |p: &Path| {
        sentence
            .map(str::to_string)
            .unwrap_or_else(|| format!("not an absolute path to a .jsonl file: {}", trunc(p, 200)))
    };
    let not_home = |p: &Path| {
        sentence
            .map(str::to_string)
            .unwrap_or_else(|| format!("not a log file in your home folder: {}", trunc(p, 200)))
    };
    let not_read = |p: &Path| {
        sentence
            .map(str::to_string)
            .unwrap_or_else(|| format!("not a readable file: {}", trunc(p, 200)))
    };
    let p = Path::new(path);
    if !p.is_absolute() || !path.ends_with(".jsonl") {
        return Err(not_abs(p));
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .and_then(|h| std::fs::canonicalize(&h).ok())
        .unwrap_or_default();
    // `os.path.realpath`: resolve symlinks when the file is there, lexically
    // when it is not (a missing log, a `..` that resolves elsewhere).
    let real = match std::fs::canonicalize(p) {
        Ok(r) => r,
        Err(_) => lexical_normalize(p),
    };
    if !real.starts_with(&home) || !real.to_string_lossy().ends_with(".jsonl") {
        return Err(not_home(p));
    }
    let st = match std::fs::metadata(&real) {
        Ok(st) => st,
        Err(e) => {
            return Err(sentence
                .map(str::to_string)
                .unwrap_or_else(|| format!("cannot read {}: {}", trunc(p, 200), e)));
        }
    };
    if !st.is_file() {
        return Err(not_read(p));
    }
    // `os.access(R_OK)`: a file nobody may read is refused here, not with a
    // raw `Permission denied` from the reader.
    if std::fs::OpenOptions::new().read(true).open(&real).is_err() {
        return Err(not_read(p));
    }
    Ok(real)
}

/// `..`/`.` components resolved lexically (no symlinks, no existence check):
/// the `os.path.realpath` of a path that may not exist.
fn lexical_normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            c => out.push(c.as_os_str()),
        }
    }
    out
}

fn trunc(p: &Path, n: usize) -> String {
    let s = p.to_string_lossy();
    if s.len() <= n {
        s.into_owned()
    } else {
        s[..n].to_string()
    }
}

/// Write [data] to [out] and flush; `false` when the reader went away.
fn put(out: &mut dyn Write, data: &[u8]) -> bool {
    out.write_all(data).and_then(|()| out.flush()).is_ok()
}

/// The reader of one log file. `pos` is the offset after the last line
/// consumed; the bytes of a line still waiting for its newline are held in
/// `buf`, never printed.
struct Follower<'a> {
    path: PathBuf,
    frm: Option<u64>,
    tail: u64,
    poll: Duration,
    idle_exit: u64,
    until: Option<u64>,
    brief: bool,
    z: Option<Zlib>,
    file: std::fs::File,
    ident: (u64, u64),
    pos: u64,
    read_pos: u64,
    buf: Vec<u8>,
    total: u64,
    over: bool,
    skip: bool,
    out: Vec<Vec<u8>>,
    last_growth: Instant,
    sink: &'a mut dyn Write,
    cancel: &'a AtomicBool,
    /// Writing to the sink failed: nobody reads any more.
    broken: bool,
}

impl<'a> Follower<'a> {
    // Eight knobs from the CLI; a config struct would just move the noise.
    #[allow(clippy::too_many_arguments)]
    fn new(
        path: PathBuf,
        frm: Option<u64>,
        poll: Duration,
        idle_exit: u64,
        tail: u64,
        zipped: bool,
        until: Option<u64>,
        brief: bool,
        sink: &'a mut dyn Write,
        cancel: &'a AtomicBool,
    ) -> std::io::Result<Self> {
        let file = std::fs::File::open(&path)?;
        Ok(Follower {
            path,
            frm,
            poll,
            idle_exit,
            tail,
            brief,
            until,
            z: zipped.then(zlib_batch::new_stream),
            file,
            ident: (0, 0),
            pos: 0,
            read_pos: 0,
            buf: Vec::new(),
            total: 0,
            over: false,
            skip: false,
            out: Vec::new(),
            last_growth: Instant::now(),
            sink,
            cancel,
            broken: false,
        })
    }

    /// Writes and flushes one batch. `false` when the output is gone; the
    /// follower stops at its next look.
    fn emit(&mut self, data: &[u8]) -> bool {
        let out = match &self.z {
            Some(z) if data.len() >= zlib_batch::ATTACH_ZIP_MIN => {
                zlib_batch::zipped_batch(z, data)
            }
            _ => data.to_vec(),
        };
        let ok = put(self.sink, &out);
        self.broken |= !ok;
        ok
    }

    fn byte_at(&self, offset: u64) -> Option<u8> {
        use std::os::unix::fs::FileExt;
        let mut b = [0u8; 1];
        let n = self.file.read_at(&mut b, offset).ok()?;
        (n == 1).then_some(b[0])
    }

    fn restart_line(&mut self) {
        self.buf.clear();
        self.total = 0;
        self.over = false;
    }

    /// Begin at the last `tail` bytes (after a newline), or at `frm`. Says where
    /// the tail starts (`S`, 0: the whole file).
    fn start_tail(&mut self, size: u64, marker: bool) {
        let start = size.saturating_sub(self.tail);
        if !self.emit(format!("S\t{start}\n").as_bytes()) {
            return;
        }
        self.skip = start > 0;
        let start = if self.skip {
            start.saturating_sub(1)
        } else {
            start
        };
        self.pos = start;
        self.read_pos = start;
        self.restart_line();
        if marker {
            let _ = self.emit(format!("R\t{start}\n").as_bytes());
        }
    }

    fn begin(&mut self) {
        use std::os::unix::fs::MetadataExt;
        let st = self.file.metadata().expect("the file is open");
        self.ident = (st.dev(), st.ino());
        let size = st.len();
        match self.frm {
            None => self.start_tail(size, false),
            Some(frm) => {
                let at_line = frm <= size && (frm == 0 || self.byte_at(frm - 1) == Some(b'\n'));
                if at_line {
                    self.pos = frm;
                    self.read_pos = frm;
                } else if self.until.is_some() {
                    // A bounded read has no tail to fall back on: it starts over.
                    self.pos = 0;
                    self.read_pos = 0;
                    let _ = self.emit(b"R\t0\n");
                } else {
                    // The file is not the one the offset came from.
                    self.start_tail(size, true);
                }
            }
        }
    }

    /// One stat. `true` when there is something to read: the file grew, or it
    /// shrank or was replaced and starts over.
    fn check(&mut self) -> bool {
        use std::os::unix::fs::MetadataExt;
        let st = match std::fs::metadata(&self.path) {
            Ok(s) => s,
            Err(_) => return false,
        };
        let ident = (st.dev(), st.ino());
        if ident == self.ident && st.len() >= self.read_pos {
            return st.len() > self.read_pos;
        }
        // Replaced or shrank: re-open and start over.
        let file = match std::fs::File::open(&self.path) {
            Ok(f) => f,
            Err(_) => return false,
        };
        self.file = file;
        let st = self.file.metadata().expect("the file is open");
        self.ident = (st.dev(), st.ino());
        self.start_tail(st.len(), true);
        self.last_growth = Instant::now();
        true
    }

    fn pump(&mut self) {
        use std::os::unix::fs::FileExt;
        loop {
            if self.broken {
                return;
            }
            let (want, finishing) = match self.until {
                Some(until) if self.read_pos >= until => {
                    if self.total == 0 {
                        return;
                    }
                    (READ, true)
                }
                Some(until) => (READ.min(until - self.read_pos), false),
                _ => (READ, false),
            };
            let mut data = vec![0u8; want as usize];
            let n = match self.file.read_at(&mut data, self.read_pos) {
                Ok(n) => n,
                Err(_) => return,
            };
            if n == 0 {
                return;
            }
            data.truncate(n);
            if finishing {
                if let Some(i) = data.iter().position(|&b| b == b'\n') {
                    data.truncate(i + 1);
                }
            }
            self.read_pos += n as u64;
            self.last_growth = Instant::now();
            self.feed(&data);
            if !self.out.is_empty() {
                let joined: Vec<u8> = self.out.concat();
                self.out.clear();
                if !self.emit(&joined) {
                    return;
                }
            }
            if finishing && data.ends_with(b"\n") {
                return;
            }
        }
    }

    fn feed(&mut self, data: &[u8]) {
        let n = data.len();
        let mut start = 0usize;
        while start < n {
            let i = data[start..].iter().position(|&b| b == b'\n');
            let end = match i {
                Some(i) => start + i,
                None => n,
            };
            let k = end - start;
            if k > 0 {
                self.total += k as u64;
                if self.total > LINE_MAX {
                    // Too long to ship: counted, not kept.
                    self.over = true;
                    self.buf.clear();
                } else if !self.skip && !self.over {
                    self.buf.extend_from_slice(&data[start..end]);
                }
            }
            if i.is_none() {
                return;
            }
            self.pos += self.total + 1;
            if self.skip {
                self.skip = false;
            } else {
                let rec = if self.over {
                    Some(
                        format!("{{\"raw\":\"[line of {} bytes not sent]\"}}", self.total)
                            .into_bytes(),
                    )
                } else {
                    follow_record(&self.buf, Some(self.pos - self.total - 1), self.brief)
                };
                if let Some(rec) = rec {
                    let line = format!("{}\t{}\n", self.pos, String::from_utf8_lossy(&rec));
                    self.out.push(line.into_bytes());
                }
            }
            self.restart_line();
            start = end + 1;
        }
    }

    /// Seconds to the next look: the base poll while it grows, longer the
    /// longer it has been quiet.
    fn interval(&self) -> Duration {
        let idle = self.last_growth.elapsed().as_secs_f64();
        let mut slow = 0.0;
        for (after, every) in BACKOFF {
            if idle >= after {
                slow = every;
            }
        }
        let base = self.poll.as_secs_f64();
        Duration::from_secs_f64(base.max(slow))
    }

    /// Sleeps `seconds`; `false` when the follow is over: cancelled (the
    /// phone went away) or the reader of the output is gone.
    fn wait(&self, seconds: Duration) -> bool {
        // Polls the flag in small chunks, so a cancel ends the follow at once,
        // not at the next poll (the python's `select([0], ...)`).
        let end = Instant::now() + seconds;
        loop {
            if self.over_now() {
                return false;
            }
            let now = Instant::now();
            if now >= end {
                return true;
            }
            std::thread::sleep((end - now).min(Duration::from_millis(50)));
        }
    }

    fn over_now(&self) -> bool {
        self.broken || self.cancel.load(Ordering::SeqCst)
    }

    fn run(&mut self) -> std::io::Result<()> {
        self.begin();
        self.pump();
        // Everything the file held is sent: the phone is up to date.
        if !self.emit(format!("C\t{}\n", self.pos).as_bytes()) {
            return Ok(());
        }
        if self.until.is_some() {
            return Ok(());
        }
        while self.wait(self.interval()) {
            if self.idle_exit > 0 && self.last_growth.elapsed().as_secs() >= self.idle_exit {
                return Ok(());
            }
            if self.check() {
                self.pump();
            }
        }
        Ok(())
    }
}

/// `follow PATH [--z] [--from N] [--to N] [--digest] [--poll-ms N]
/// [--idle-exit S] [--tail-bytes N]`.
pub fn cmd_follow(args: &[String]) -> i32 {
    // The phone is gone when stdin reaches EOF: the cancel flag says so.
    let gone = std::sync::Arc::new(AtomicBool::new(false));
    {
        let gone = std::sync::Arc::clone(&gone);
        std::thread::spawn(move || {
            use std::io::Read;
            let mut b = [0u8; 4096];
            let stdin = std::io::stdin();
            let mut lock = stdin.lock();
            loop {
                match lock.read(&mut b) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
            gone.store(true, Ordering::SeqCst);
        });
    }
    run(args, &mut std::io::stdout(), &gone)
}

/// [`cmd_follow`] to any `out`, with the reasons it fails on stderr. Every
/// record batch is flushed at once. Setting `cancel` ends the polling phase of
/// a follow at its next look (a bounded read, `--to`, is sent to its end).
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
    let Some(path) = args.first() else {
        say(err, "follow needs a log path");
        return exit::USAGE;
    };
    let mut frm: Option<u64> = None;
    let mut until: Option<u64> = None;
    let mut poll_ms = None;
    let mut idle_exit = 0u64;
    let mut tail_bytes = TAIL;
    let mut zipped = false;
    let mut brief = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--z" => zipped = true,
            "--digest" => brief = true,
            "--from" | "--to" | "--poll-ms" | "--idle-exit" | "--tail-bytes" => {
                let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) else {
                    say(err, format!("{} needs a number", args[i]));
                    return exit::USAGE;
                };
                match args[i].as_str() {
                    "--from" => frm = Some(v),
                    "--to" => until = Some(v),
                    "--poll-ms" => poll_ms = Some(v),
                    "--idle-exit" => idle_exit = v,
                    "--tail-bytes" => tail_bytes = v,
                    _ => unreachable!(),
                }
                i += 2;
                continue;
            }
            other => {
                say(err, format!("unknown follow flag {other}"));
                return exit::USAGE;
            }
        }
        i += 1;
    }
    // Clamps (python `main`).
    let poll_ms = poll_ms.unwrap_or(250).clamp(20, 60000);
    let tail = tail_bytes.clamp(TAIL_MIN, TAIL_MAX);
    let frm = frm.or_else(|| until.map(|_| 0));
    let real = match follow_target(path, None) {
        Ok(p) => p,
        Err(msg) => {
            say(err, msg);
            return exit::GONE;
        }
    };
    let mut f = match Follower::new(
        real,
        frm,
        Duration::from_millis(poll_ms),
        idle_exit,
        tail,
        zipped,
        until,
        brief,
        out,
        cancel,
    ) {
        Ok(f) => f,
        Err(e) => {
            say(err, e);
            return exit::GONE;
        }
    };
    match f.run() {
        Ok(()) => 0,
        Err(e) => {
            let _ = f.emit(format!("E\t{}\n", trunc_msg(&e.to_string())).as_bytes());
            exit::FAILED
        }
    }
}

/// One `herdr-mobile: <what>` line.
fn say(err: &mut dyn Write, what: impl std::fmt::Display) {
    let _ = writeln!(err, "herdr-mobile: {what}");
}

fn trunc_msg(s: &str) -> String {
    s.replace('\n', " ").chars().take(300).collect()
}

/// `blob PATH START HASH`: the binary payload `follow` dropped from the log
/// line that begins at byte `START` of `PATH` and whose hash is `HASH`
/// (the `ref=` of its note): `B\t<piece of base64 text>` records, then
/// `D\t<length>`.
pub fn cmd_blob(args: &[String]) -> i32 {
    run_blob(args, &mut std::io::stdout(), &AtomicBool::new(false))
}

/// [`cmd_blob`] to any `out`, with the reasons it fails on stderr.
pub fn run_blob(args: &[String], out: &mut dyn Write, cancel: &AtomicBool) -> i32 {
    run_blob_with(args, out, &mut std::io::stderr(), cancel)
}

/// [`run_blob`] with the reasons it fails (`herdr-mobile: <sentence>` lines)
/// written to `err`. Stops at the next piece once `cancel` is set.
pub fn run_blob_with(
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
    cancel: &AtomicBool,
) -> i32 {
    let (Some(path), Some(start), Some(hash)) = (args.first(), args.get(1), args.get(2)) else {
        say(err, "blob needs PATH START HASH");
        return exit::USAGE;
    };
    let start: u64 = match start.parse() {
        Ok(n) => n,
        Err(_) => {
            say(err, "START is not a number");
            return exit::USAGE;
        }
    };
    if !hash.chars().all(|c| c.is_ascii_hexdigit()) || hash.len() != 16 {
        say(err, "HASH is not 16 hex digits");
        return exit::USAGE;
    }
    let gone = "That picture is not in the log any more.";
    let real = match follow_target(path, Some(gone)) {
        Ok(p) => p,
        Err(msg) => {
            say(err, msg);
            return exit::GONE;
        }
    };
    let file = match std::fs::File::open(&real) {
        Ok(f) => f,
        Err(_) => {
            say(err, gone);
            return exit::GONE;
        }
    };
    let result = read_blob(&file, start, hash);
    match result {
        Ok(raw) => {
            for chunk in raw.as_bytes().chunks(48 * 1024) {
                if cancel.load(Ordering::SeqCst)
                    || !put(
                        out,
                        format!("B\t{}\n", String::from_utf8_lossy(chunk)).as_bytes(),
                    )
                {
                    return 0;
                }
            }
            put(out, format!("D\t{}\n", raw.len()).as_bytes());
            0
        }
        Err(msg) => {
            say(err, msg);
            exit::GONE
        }
    }
}

/// Read the line at [start] and find the payload whose hash is [hash].
fn read_blob(file: &std::fs::File, start: u64, hash: &str) -> Result<String, String> {
    use std::os::unix::fs::FileExt;
    let gone = "That picture is not in the log any more.";
    if start > 0 {
        let mut b = [0u8; 1];
        let n = file.read_at(&mut b, start - 1).unwrap_or(0);
        // A byte read of one that is not the newline before the line means the
        // log moved since the picture was listed.
        if n != 1 || b[0] != b'\n' {
            return Err("The log changed since that picture was listed.".to_string());
        }
    }
    let mut data = Vec::new();
    let mut at = start;
    let mut end = false;
    while !end && (data.len() as u64) <= LINE_MAX {
        let mut piece = vec![0u8; 1024 * 1024];
        let n = file.read_at(&mut piece, at).unwrap_or(0);
        if n == 0 {
            break;
        }
        piece.truncate(n);
        match piece.iter().position(|&b| b == b'\n') {
            Some(i) => {
                data.extend_from_slice(&piece[..i]);
                end = true;
            }
            None => {
                data.extend_from_slice(&piece);
                at += n as u64;
            }
        }
    }
    if !end || (data.len() as u64) > LINE_MAX {
        return Err(gone.to_string());
    }
    let obj: Value = serde_json::from_slice(&data).map_err(|_| gone.to_string())?;
    for p in blob_payloads(&obj) {
        if payload_hash(&p) != hash {
            continue;
        }
        // Whitespace is not part of base64: a payload with line breaks must not
        // break the one-record-per-line protocol.
        let raw: String = p.split_whitespace().collect();
        if !raw.is_ascii() {
            return Err("That is not a picture.".to_string());
        }
        return Ok(raw);
    }
    Err(gone.to_string())
}

/// The payloads `scrub` drops from `v`, in the order it meets them.
fn blob_payloads(v: &Value) -> Vec<String> {
    let mut out = Vec::new();
    collect_payloads(v, &mut out);
    out
}

fn collect_payloads(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::Array(a) => {
            for x in a {
                collect_payloads(x, out);
            }
        }
        Value::Object(o) => {
            let binary = o
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|t| BINARY_TYPES.contains(&t));
            for (k, x) in o {
                match x {
                    Value::String(s) => {
                        if let Some(p) = binary_payload(binary, k, s) {
                            out.push(p);
                        }
                    }
                    other => collect_payloads(other, out),
                }
            }
        }
        _ => {}
    }
}
