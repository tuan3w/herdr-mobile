//! `fs.search`: find files and folders by name under a folder, breadth first so
//! the shallow matches come first and a phone can show them while the walk goes
//! on. Read-only; symlinks are reported and never followed; one stat per
//! match and none per entry.
//!
//! The walk is a plain function over an injected clock, cancel flag and sink,
//! so the batching rule and the caps are tested without sleeping.

use crate::service::{Class, MethodKind, MethodSpec};
use crate::session::StreamCtx;
use crate::svc::fs::{io_error, mtime_ms, parse_args, resolve};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::fs::{self, Metadata};
use std::path::{Path, PathBuf};
use std::time::Duration;
use wire::{ErrorCode, WireError};

/// Entries in one MSG, at most.
pub const BATCH: usize = 100;

/// The first batch leaves with the first entry; later ones when full or when
/// this long has passed since the last one.
pub const BATCH_HOLD: Duration = Duration::from_millis(150);

pub const DEFAULT_MAX_RESULTS: u64 = 500;
pub const MAX_RESULTS_CAP: u64 = 2000;
pub const DEFAULT_MAX_DEPTH: u64 = 12;
pub const MAX_DEPTH_CAP: u64 = 32;

/// The scan stops (and says `truncated`) after this many directory entries ...
pub const SCAN_CAP: usize = 200_000;

/// ... or this long.
pub const WALL_CAP: Duration = Duration::from_secs(20);

/// Looked at every this many entries of a folder, so a huge folder is still
/// cancellable.
const CANCEL_EVERY: usize = 256;

const DEFAULT_IGNORE: &[&str] = &[
    ".git",
    "node_modules",
    "target",
    ".cache",
    "__pycache__",
    ".venv",
    "build",
];

pub(crate) const SPEC: MethodSpec = MethodSpec {
    name: "search",
    kind: MethodKind::Stream,
    class: Class::Interactive,
    summary: "Finds files and folders by name under `root`, breadth first (shallow matches first). `query` is a case-insensitive part of the NAME (absent or empty matches everything, useful with `modified_within_s`); `kind` any|file|dir; `modified_within_s` keeps entries changed that many seconds ago or less; `max_results` (default 500, at most 2000); `max_depth` (default 12, at most 32; the entries of `root` are depth 1); `hidden` includes names starting with a dot (default false); `ignore` names a folder is skipped by, and not reported, wherever it is (default .git node_modules target .cache __pycache__ .venv build; [] searches everything). Links are reported as kind `link` and never followed. MSG {entries:[{path,name,kind:file|dir|link|other,size,mtime_ms}]} of at most 100, the first as soon as there is an entry, then when full or every 150 ms. END {scanned,truncated,elapsed_ms,skipped_dirs}: truncated is true when max_results or the scan caps (200000 entries, 20 s) stopped the walk; skipped_dirs counts folders that could not be read. Errors not_found, permission, not_a_directory (the root).",
    args_example: r#"{"root":"~/projects","query":"readme","kind":"file","modified_within_s":86400,"max_results":500,"max_depth":12,"hidden":false,"ignore":[".git","node_modules"]}"#,
    result_example: r#"{"scanned":4210,"truncated":false,"elapsed_ms":38,"skipped_dirs":0}"#,
};

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum KindFilter {
    #[default]
    Any,
    File,
    Dir,
}

#[derive(Debug, Deserialize)]
pub(crate) struct SearchArgs {
    pub root: String,
    #[serde(default)]
    pub query: Option<String>,
    #[serde(default)]
    pub kind: KindFilter,
    #[serde(default)]
    pub modified_within_s: Option<u64>,
    #[serde(default)]
    pub max_results: Option<u64>,
    #[serde(default)]
    pub max_depth: Option<u64>,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub ignore: Option<Vec<String>>,
}

/// What a walk looks for and where it stops.
#[derive(Clone, Debug)]
pub(crate) struct Options {
    /// Lower-cased; empty matches every name.
    pub query: String,
    pub kind: KindFilter,
    /// Entries modified before this (ms since the epoch) are not matches.
    pub not_before_ms: Option<i64>,
    pub max_results: usize,
    pub max_depth: usize,
    pub hidden: bool,
    pub ignore: Vec<String>,
    pub scan_cap: usize,
    pub wall_cap: Duration,
}

impl Options {
    /// The options of a request; `now_ms` is the current time for
    /// `modified_within_s`.
    pub(crate) fn from_args(args: &SearchArgs, now_ms: i64) -> Self {
        let clamp = |v: Option<u64>, default: u64, cap: u64| -> usize {
            usize::try_from(v.unwrap_or(default).clamp(1, cap)).unwrap_or(1)
        };
        Self {
            query: args.query.as_deref().unwrap_or("").to_lowercase(),
            kind: args.kind,
            not_before_ms: args.modified_within_s.map(|s| {
                now_ms.saturating_sub(i64::try_from(s).unwrap_or(i64::MAX).saturating_mul(1000))
            }),
            max_results: clamp(args.max_results, DEFAULT_MAX_RESULTS, MAX_RESULTS_CAP),
            max_depth: clamp(args.max_depth, DEFAULT_MAX_DEPTH, MAX_DEPTH_CAP),
            hidden: args.hidden,
            ignore: args
                .ignore
                .clone()
                .unwrap_or_else(|| DEFAULT_IGNORE.iter().map(|s| (*s).to_string()).collect()),
            scan_cap: SCAN_CAP,
            wall_cap: WALL_CAP,
        }
    }
}

/// How a walk ended (the END object).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Summary {
    pub scanned: usize,
    pub truncated: bool,
    pub skipped_dirs: usize,
    pub elapsed: Duration,
}

impl Summary {
    fn json(&self) -> Value {
        json!({
            "scanned": self.scanned,
            "truncated": self.truncated,
            "elapsed_ms": u64::try_from(self.elapsed.as_millis()).unwrap_or(u64::MAX),
            "skipped_dirs": self.skipped_dirs,
        })
    }
}

fn cancelled() -> WireError {
    WireError::new(ErrorCode::Cancelled, "the stream was closed")
}

/// Whether `name` holds `needle` (already lower-case), ignoring case, without
/// allocating for the usual all-ASCII name.
fn contains_ci(name: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    if name.is_ascii() && needle.is_ascii() {
        let (n, p) = (name.as_bytes(), needle.as_bytes());
        return n.len() >= p.len() && n.windows(p.len()).any(|w| w.eq_ignore_ascii_case(p));
    }
    name.to_lowercase().contains(needle)
}

fn kind_name(t: std::fs::FileType) -> &'static str {
    if t.is_symlink() {
        "link"
    } else if t.is_dir() {
        "dir"
    } else if t.is_file() {
        "file"
    } else {
        "other"
    }
}

fn entry_json(path: &Path, name: &str, kind: &str, meta: &Metadata) -> Value {
    json!({
        "path": path.to_string_lossy(),
        "name": name,
        "kind": kind,
        "size": meta.len(),
        "mtime_ms": mtime_ms(meta),
    })
}

/// Walks `root` (given as `given` by the client, for errors) and hands the
/// matches to `sink` in batches. `clock` is the time since the walk began.
///
/// # Errors
/// `not_found`, `permission` and `not_a_directory` for the root; `cancelled`
/// when `cancel` turns true; whatever `sink` returns.
pub(crate) fn walk(
    root: &Path,
    given: &str,
    opts: &Options,
    clock: &mut dyn FnMut() -> Duration,
    cancel: &dyn Fn() -> bool,
    sink: &mut dyn FnMut(Vec<Value>) -> Result<(), WireError>,
) -> Result<Summary, WireError> {
    let meta = fs::metadata(root).map_err(|e| io_error(&e, given))?;
    if !meta.is_dir() {
        return Err(WireError::new(
            ErrorCode::NotADirectory,
            format!("{given}: is not a folder"),
        ));
    }

    let mut queue: VecDeque<(PathBuf, usize)> = VecDeque::new();
    queue.push_back((root.to_path_buf(), 1));
    let mut pending: Vec<Value> = Vec::new();
    let mut sent_any = false;
    let mut last_sent = Duration::ZERO;
    let (mut scanned, mut found, mut skipped_dirs) = (0usize, 0usize, 0usize);
    let mut truncated = false;

    let flush = |pending: &mut Vec<Value>,
                 sent_any: &mut bool,
                 last_sent: &mut Duration,
                 at: Duration,
                 sink: &mut dyn FnMut(Vec<Value>) -> Result<(), WireError>|
     -> Result<(), WireError> {
        if pending.is_empty() {
            return Ok(());
        }
        sink(std::mem::take(pending))?;
        *sent_any = true;
        *last_sent = at;
        Ok(())
    };

    'walk: while let Some((dir, level)) = queue.pop_front() {
        if cancel() {
            return Err(cancelled());
        }
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(e) if level == 1 => return Err(io_error(&e, given)),
            Err(_) => {
                skipped_dirs += 1;
                continue;
            }
        };
        for (i, entry) in entries.enumerate() {
            if i % CANCEL_EVERY == 0 && i > 0 && cancel() {
                return Err(cancelled());
            }
            let Ok(entry) = entry else { continue };
            if scanned >= opts.scan_cap {
                truncated = true;
                break 'walk;
            }
            scanned += 1;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !opts.hidden && name.starts_with('.') {
                continue;
            }
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            let kind = kind_name(file_type);
            if kind != "file" && opts.ignore.contains(&name) {
                continue;
            }
            let wanted_kind = match opts.kind {
                KindFilter::Any => true,
                KindFilter::File => kind == "file",
                KindFilter::Dir => kind == "dir",
            };
            if wanted_kind && contains_ci(&name, &opts.query) {
                if let Ok(meta) = entry.metadata() {
                    let fresh = opts.not_before_ms.is_none_or(|t| mtime_ms(&meta) >= t);
                    if fresh {
                        pending.push(entry_json(&entry.path(), &name, kind, &meta));
                        found += 1;
                    }
                }
            }
            if kind == "dir" && level < opts.max_depth {
                queue.push_back((entry.path(), level + 1));
            }
            let now = clock();
            if found >= opts.max_results {
                truncated = true;
                break 'walk;
            }
            if now >= opts.wall_cap {
                truncated = true;
                break 'walk;
            }
            let due = pending.len() >= BATCH
                || (!pending.is_empty()
                    && (!sent_any || now.saturating_sub(last_sent) >= BATCH_HOLD));
            if due {
                flush(&mut pending, &mut sent_any, &mut last_sent, now, sink)?;
            }
        }
    }
    let elapsed = clock();
    flush(&mut pending, &mut sent_any, &mut last_sent, elapsed, sink)?;
    Ok(Summary {
        scanned,
        truncated,
        skipped_dirs,
        elapsed,
    })
}

/// `fs.search` on a stream.
pub(crate) fn search(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: SearchArgs = parse_args(ctx.args())?;
    let root = resolve(ctx.home(), &args.root)?;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX));
    let opts = Options::from_args(&args, now_ms);
    let began = std::time::Instant::now();
    let summary = walk(
        &root,
        &args.root,
        &opts,
        &mut || began.elapsed(),
        &|| ctx.cancelled(),
        &mut |entries| {
            ctx.send_msg(&json!({"entries": entries}))?;
            Ok(())
        },
    )?;
    Ok(summary.json())
}

#[cfg(test)]
mod tests;
