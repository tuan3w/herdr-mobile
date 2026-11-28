//! `transfer`: files from the phone to the host's inbox, the only place
//! `herdr-host serve` writes. Everything lands in
//! `<home>/.herdr-mobile/inbox/<12 hex of sha1(session key)>/<yyyyMMdd-HHmmss
//! UTC>-<safe name>`: outside every repository, owner-only (folders 0700,
//! files 0600). The agent is handed that path, so it can read it, and so can
//! anything running as the same user: nothing secret belongs here.
//!
//! The target path is derived from the fixed base and [`safe_name`] only, and
//! `put` accepts nothing but a path of exactly that shape, so a hostile client
//! path cannot leave the inbox. The naming rules are a port of the app's
//! `inboxSafeName` / `HostInbox` (`host_inbox.dart`), whose cases are tests
//! here.

use crate::service::{Class, MethodKind, MethodSpec, Service};
use crate::session::{Incoming, StreamCtx};
use crate::svc::fs::{io_error, parse_args};
use serde::Deserialize;
use serde_json::{json, Value};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError};

/// What one upload may weigh.
pub const MAX_PUT: u64 = 2 * 1024 * 1024 * 1024;

/// Files in the inbox older than this go in a sweep.
pub const DEFAULT_MAX_AGE_DAYS: u64 = 14;

/// The most files one sweep removes.
pub const DEFAULT_MAX_FILES: usize = 200;

/// An unfinished upload nobody resumed in this long is garbage.
const STALE_PARTIAL: Duration = Duration::from_secs(24 * 60 * 60);

/// A safe name has at most this many characters and bytes; file systems
/// allow 255 bytes, and the stamp, a `-99` suffix and `.part` need room.
const MAX_NAME_CHARS: usize = 100;
const MAX_NAME_BYTES: usize = 200;

/// Names handed out by this process, so two files reserved in the same second
/// cannot get one name before either exists.
static TAKEN: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);
const TAKEN_CAP: usize = 2000;

/// Targets being uploaded right now by this process.
static ACTIVE: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "reserve",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "Picks the inbox path for the phone file `name` of the session `key` and creates its folders (0700). The name is made safe (letters of any script, digits, `.-_`; never a dotfile; at most 100 characters) and unique (-2, -3 before the extension).",
        args_example: r#"{"key":"session-1","name":"Report 1.pdf"}"#,
        result_example: r#"{"path":"/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-Report_1.pdf"}"#,
    },
    MethodSpec {
        name: "put",
        kind: MethodKind::Stream,
        class: Class::Bulk,
        summary: "Uploads one file to a reserved path. The host answers MSG {have} (bytes it already holds of this exact upload, resume from there), the client sends DATA from `have` and then END; the host checks size and sha256, renames into place (mode 0600) and ends {path,size}. A mismatch deletes the partial file and ends with error `changed`; a dropped connection keeps it for the next try. At most 2 GiB (too_large).",
        args_example: r#"{"path":"/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-Report_1.pdf","size":1204,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}"#,
        result_example: r#"{"path":"/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-Report_1.pdf","size":1204}"#,
    },
    MethodSpec {
        name: "sweep",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "Removes regular files older than `max_age_days` directly inside the inbox's session folders, oldest first, at most `max_files`, plus unfinished uploads untouched for a day, then the folders that are left empty. Links are never followed or removed; nothing outside the inbox is touched.",
        args_example: r#"{"max_age_days":14,"max_files":200}"#,
        result_example: r#"{"removed":3}"#,
    },
];

#[derive(Debug, Deserialize)]
struct ReserveArgs {
    key: String,
    name: String,
}

#[derive(Debug, Deserialize)]
struct PutArgs {
    path: String,
    size: u64,
    sha256: String,
}

#[derive(Debug, Deserialize)]
struct SweepArgs {
    #[serde(default = "default_age")]
    max_age_days: u64,
    #[serde(default = "default_files")]
    max_files: usize,
}

fn default_age() -> u64 {
    DEFAULT_MAX_AGE_DAYS
}

fn default_files() -> usize {
    DEFAULT_MAX_FILES
}

/// The `transfer` service.
#[derive(Default)]
pub struct TransferService;

impl TransferService {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Service for TransferService {
    fn name(&self) -> &'static str {
        "transfer"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        ServiceStatus::available()
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "reserve" => {
                let args: ReserveArgs = parse_args(ctx.args())?;
                let path = reserve_path(ctx.home(), &args.key, &args.name, SystemTime::now())?;
                Ok(json!({"path": path.to_string_lossy()}))
            }
            "put" => put(ctx),
            "sweep" => {
                let args: SweepArgs = parse_args(ctx.args())?;
                let age = Duration::from_secs(args.max_age_days.saturating_mul(24 * 60 * 60));
                let removed = sweep(ctx.home(), age, args.max_files, SystemTime::now());
                Ok(json!({"removed": removed}))
            }
            other => Err(WireError::new(
                ErrorCode::UnknownMethod,
                format!("transfer has no method {other}"),
            )),
        }
    }
}

// ---- naming ----

fn is_kept(c: char) -> bool {
    matches!(c, '.' | '-' | '_')
        || matches!(
            c.general_category_group(),
            GeneralCategoryGroup::Letter
                | GeneralCategoryGroup::Mark
                | GeneralCategoryGroup::Number
        )
}

fn is_letter_or_digit(c: char) -> bool {
    matches!(
        c.general_category_group(),
        GeneralCategoryGroup::Letter | GeneralCategoryGroup::Number
    )
}

fn is_blank(c: char) -> bool {
    c.is_whitespace() || c == '\u{FEFF}'
}

/// A file name that is safe to create on the host: the last path segment of
/// `raw` (split at `/` and `\`) with every character that is not a letter or
/// mark or number of any script, `.`, `-` or `_` replaced by `_`, leading dots
/// removed (never a dotfile), at most 100 characters and 200 bytes with the
/// extension kept, and never empty (`file`).
///
/// The extension is the text from the last dot when that dot is neither first
/// nor last and the text is at most 13 UTF-16 units; it is kept whole and the
/// stem is cut instead.
#[must_use]
pub fn safe_name(raw: &str) -> String {
    let last = raw
        .split(['/', '\\'])
        .map(|s| s.trim_matches(is_blank))
        .rfind(|s| !s.is_empty())
        .unwrap_or("");
    let cleaned: String = last
        .chars()
        .map(|c| if is_kept(c) { c } else { '_' })
        .collect();
    let name = cleaned.trim_start_matches('.');
    let (mut stem, ext) = match name.rfind('.') {
        Some(dot)
            if dot > 0 && dot < name.len() - 1 && name[dot..].encode_utf16().count() <= 13 =>
        {
            (&name[..dot], &name[dot..])
        }
        _ => (name, ""),
    };
    if !stem.chars().any(is_letter_or_digit) {
        stem = "file";
    }
    let room = MAX_NAME_CHARS - ext.chars().count();
    let bytes = MAX_NAME_BYTES - ext.len();
    let mut out = String::new();
    let (mut chars, mut used) = (0usize, 0usize);
    for c in stem.chars() {
        if chars + 1 > room || used + c.len_utf8() > bytes {
            break;
        }
        out.push(c);
        chars += 1;
        used += c.len_utf8();
    }
    out.push_str(ext);
    out
}

/// The `<12 hex>` folder of a session key: the first 12 hex digits of its SHA-1.
#[must_use]
pub fn session_folder(key: &str) -> String {
    let digest = Sha1::digest(key.as_bytes());
    let mut hex = hex(&digest);
    hex.truncate(12);
    hex
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

/// `yyyyMMdd-HHmmss` in UTC.
#[must_use]
pub fn stamp(at: SystemTime) -> String {
    let secs = match at.duration_since(UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_secs()).unwrap_or(i64::MAX / 2),
        Err(e) => -i64::try_from(e.duration().as_secs()).unwrap_or(i64::MAX / 2),
    };
    let days = secs.div_euclid(86_400);
    let rest = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}{m:02}{d:02}-{:02}{:02}{:02}",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// Year, month, day of a day count since 1970-01-01 (proleptic Gregorian).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

/// `<stamp>-<safe>` for the first try, `<stamp>-<stem>-<n>.<ext>` after.
fn numbered(stamp: &str, safe: &str, n: u32) -> String {
    if n == 1 {
        return format!("{stamp}-{safe}");
    }
    match safe.rfind('.') {
        Some(dot) if dot > 0 && dot < safe.len() - 1 => {
            format!("{stamp}-{}-{n}{}", &safe[..dot], &safe[dot..])
        }
        _ => format!("{stamp}-{safe}-{n}"),
    }
}

// ---- where the inbox is ----

const HOME_FOLDER: &str = ".herdr-mobile";

fn inbox_base(home: &Path) -> PathBuf {
    home.join(HOME_FOLDER).join("inbox")
}

/// Makes sure `<home>/.herdr-mobile/inbox/<folder>` is a real folder (0700 when
/// created, others left as they were) and returns it. A link anywhere below
/// the home is refused: the inbox is never reached through one.
fn ensure_session_dir(home: &Path, folder: &str) -> Result<PathBuf, WireError> {
    let mut path = home.to_path_buf();
    let mut label = String::from("~");
    for part in [HOME_FOLDER, "inbox", folder] {
        path.push(part);
        label.push('/');
        label.push_str(part);
        match fs::symlink_metadata(&path) {
            Ok(m) if m.file_type().is_symlink() => {
                return Err(WireError::new(
                    ErrorCode::BadRequest,
                    format!("{label}: is a link; the inbox is never reached through one"),
                ));
            }
            Ok(m) if !m.is_dir() => {
                return Err(WireError::new(
                    ErrorCode::NotADirectory,
                    format!("{label}: is not a folder"),
                ));
            }
            Ok(_) => {}
            Err(e) if e.kind() == ErrorKind::NotFound => {
                match fs::DirBuilder::new().mode(0o700).create(&path) {
                    Ok(()) => {}
                    Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
                    Err(e) => return Err(io_error(&e, &label)),
                }
            }
            Err(e) => return Err(io_error(&e, &label)),
        }
    }
    Ok(path)
}

fn taken_insert(path: &Path) -> bool {
    let mut guard = TAKEN.lock().unwrap_or_else(PoisonError::into_inner);
    let set = guard.get_or_insert_with(HashSet::new);
    if set.len() > TAKEN_CAP {
        set.clear();
    }
    set.insert(path.to_path_buf())
}

/// Reserves the path for the phone file `name` of the session `key`: creates
/// the folders and returns a path nothing on the host and nothing this
/// process handed out is using.
///
/// # Errors
/// `bad_request` when the inbox is reached through a link, `permission` and
/// the like when the folders cannot be made.
pub fn reserve_path(
    home: &Path,
    key: &str,
    name: &str,
    now: SystemTime,
) -> Result<PathBuf, WireError> {
    let dir = ensure_session_dir(home, &session_folder(key))?;
    let safe = safe_name(name);
    let stamp = stamp(now);
    for n in 1..10_000 {
        let leaf = numbered(&stamp, &safe, n);
        let path = dir.join(&leaf);
        if !taken_insert(&path) {
            continue;
        }
        let used = |p: &Path| fs::symlink_metadata(p).is_ok();
        if used(&path) || used(&dir.join(format!("{leaf}.part"))) {
            continue;
        }
        return Ok(path);
    }
    Err(WireError::new(
        ErrorCode::Failed,
        "too many files with this name in this second",
    ))
}

fn is_session_folder(name: &str) -> bool {
    name.len() == 12 && name.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Whether `name` has the shape [`reserve_path`] gives a file: a UTC stamp,
/// `-`, then safe-name characters, not a dotfile, not a `.part`/`.meta`
/// companion, within the file system's limit.
fn is_inbox_name(name: &str) -> bool {
    let b = name.as_bytes();
    let stamped = b.len() > 16
        && b[..8].iter().all(u8::is_ascii_digit)
        && b[8] == b'-'
        && b[9..15].iter().all(u8::is_ascii_digit)
        && b[15] == b'-';
    if !stamped || b.len() > 230 {
        return false;
    }
    let rest = &name[16..];
    !rest.starts_with('.')
        && rest.chars().all(is_kept)
        && !name.ends_with(".part")
        && !name.ends_with(".meta")
}

/// Splits `given` into the session folder and the file name when it is
/// exactly `<home>/.herdr-mobile/inbox/<12 hex>/<inbox name>` and nothing else
/// (no `..`, `.`, doubled or extra separators, other parents).
fn parse_inbox_path(home: &Path, given: &str) -> Result<(String, String), WireError> {
    let bad = || {
        WireError::new(
            ErrorCode::BadRequest,
            format!("{given:?} is not a path the inbox handed out"),
        )
    };
    let base = inbox_base(home);
    let base = base.to_str().ok_or_else(bad)?;
    let rest = given
        .strip_prefix(base)
        .and_then(|r| r.strip_prefix('/'))
        .ok_or_else(bad)?;
    let mut parts = rest.split('/');
    let (Some(folder), Some(name), None) = (parts.next(), parts.next(), parts.next()) else {
        return Err(bad());
    };
    if !is_session_folder(folder) || !is_inbox_name(name) {
        return Err(bad());
    }
    Ok((folder.to_string(), name.to_string()))
}

// ---- put ----

/// Keeps two uploads of one target from running at once in this process.
#[derive(Debug)]
struct Busy(PathBuf);

impl Busy {
    fn acquire(target: &Path) -> Result<Self, WireError> {
        let mut guard = ACTIVE.lock().unwrap_or_else(PoisonError::into_inner);
        if guard
            .get_or_insert_with(HashSet::new)
            .insert(target.to_path_buf())
        {
            Ok(Self(target.to_path_buf()))
        } else {
            Err(WireError::new(
                ErrorCode::Busy,
                "this file is being uploaded already",
            ))
        }
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        let mut guard = ACTIVE.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(set) = guard.as_mut() {
            set.remove(&self.0);
        }
    }
}

fn failed(what: &str, e: &io::Error) -> WireError {
    WireError::new(ErrorCode::Failed, format!("{what}: {e}"))
}

fn companion(dir: &Path, name: &str, ext: &str) -> PathBuf {
    dir.join(format!("{name}.{ext}"))
}

/// Deletes the partial file and its record. Best effort: what cannot be
/// removed is retried by the next upload or the sweep.
fn discard(part: &Path, meta: &Path) {
    let _ = fs::remove_file(part);
    let _ = fs::remove_file(meta);
}

/// How many bytes of `part` belong to this upload: all of them when `meta`
/// records the same size and digest and the file is a regular file no longer
/// than `size`; otherwise none.
fn resumable(part: &Path, meta: &Path, size: u64, sha: &str) -> u64 {
    let recorded = fs::read(meta)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    let same = recorded.is_some_and(|v| {
        v["size"].as_u64() == Some(size)
            && v["sha256"]
                .as_str()
                .is_some_and(|s| s.eq_ignore_ascii_case(sha))
    });
    if !same {
        return 0;
    }
    match fs::symlink_metadata(part) {
        Ok(m) if m.is_file() && m.len() <= size => m.len(),
        _ => 0,
    }
}

/// Hashes the first `len` bytes of `part`; `None` when the file turns out
/// shorter.
fn hash_prefix(ctx: &StreamCtx, part: &Path, len: u64) -> Result<Option<Sha256>, WireError> {
    let mut file = File::open(part).map_err(|e| failed("reading the partial file", &e))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut left = len;
    while left > 0 {
        if ctx.cancelled() {
            return Err(WireError::new(
                ErrorCode::Cancelled,
                "the stream was closed",
            ));
        }
        let want = usize::try_from(left).map_or(buf.len(), |l| l.min(buf.len()));
        match file.read(&mut buf[..want]) {
            Ok(0) => return Ok(None),
            Ok(n) => {
                hasher.update(&buf[..n]);
                left -= n as u64;
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) => return Err(failed("reading the partial file", &e)),
        }
    }
    Ok(Some(hasher))
}

fn create_private(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

/// Starts the upload over: an empty `.part` and a `.meta` that says whose it is.
fn start_fresh(part: &Path, meta: &Path, size: u64, sha: &str) -> Result<File, WireError> {
    discard(part, meta);
    let record = json!({"size": size, "sha256": sha}).to_string();
    let mut m = create_private(meta).map_err(|e| failed("starting the upload", &e))?;
    m.write_all(record.as_bytes())
        .map_err(|e| failed("starting the upload", &e))?;
    create_private(part).map_err(|e| failed("starting the upload", &e))
}

/// The file to append to, the bytes it already holds and their digest state.
fn prepare(
    ctx: &StreamCtx,
    part: &Path,
    meta: &Path,
    size: u64,
    sha: &str,
) -> Result<(u64, Sha256, File), WireError> {
    let have = resumable(part, meta, size, sha);
    if have > 0 {
        if let Some(hasher) = hash_prefix(ctx, part, have)? {
            let file = OpenOptions::new()
                .append(true)
                .open(part)
                .map_err(|e| failed("resuming the upload", &e))?;
            return Ok((have, hasher, file));
        }
    }
    let file = start_fresh(part, meta, size, sha)?;
    Ok((0, Sha256::new(), file))
}

fn changed(why: &str) -> WireError {
    WireError::new(ErrorCode::Changed, why)
}

fn put(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: PutArgs = parse_args(ctx.args())?;
    if args.size > MAX_PUT {
        return Err(WireError::new(
            ErrorCode::TooLarge,
            "at most 2 GiB in one upload",
        ));
    }
    let sha = args.sha256.to_ascii_lowercase();
    if sha.len() != 64 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(WireError::new(
            ErrorCode::BadRequest,
            "sha256 is 64 hex digits",
        ));
    }
    let (folder, name) = parse_inbox_path(ctx.home(), &args.path)?;
    let dir = ensure_session_dir(ctx.home(), &folder)?;
    let target = dir.join(&name);
    if fs::symlink_metadata(&target).is_ok_and(|m| m.is_dir()) {
        return Err(WireError::new(
            ErrorCode::NotAFile,
            format!("{}: is a folder", args.path),
        ));
    }
    let _busy = Busy::acquire(&target)?;
    let part = companion(&dir, &name, "part");
    let meta = companion(&dir, &name, "meta");

    let (have, mut hasher, mut out) = prepare(ctx, &part, &meta, args.size, &sha)?;
    ctx.send_msg(&json!({"have": have}))?;

    let mut total = have;
    loop {
        match ctx.recv() {
            Some(Incoming::Data(chunk)) => {
                total += chunk.len() as u64;
                if total > args.size {
                    discard(&part, &meta);
                    return Err(changed("more bytes arrived than the upload announced"));
                }
                hasher.update(&chunk);
                out.write_all(&chunk)
                    .map_err(|e| failed("writing the file", &e))?;
            }
            Some(Incoming::Msg(_)) => {
                return Err(WireError::new(
                    ErrorCode::BadRequest,
                    "an upload takes DATA only",
                ));
            }
            None => break,
        }
    }
    if ctx.cancelled() {
        // The partial file and its record stay: the next attempt resumes.
        return Err(WireError::new(
            ErrorCode::Cancelled,
            "the stream was closed",
        ));
    }
    let digest = hex(&hasher.finalize());
    if total != args.size || digest != sha {
        drop(out);
        discard(&part, &meta);
        return Err(changed("the file that arrived is not the one announced"));
    }
    out.sync_all().map_err(|e| failed("writing the file", &e))?;
    drop(out);
    fs::set_permissions(&part, fs::Permissions::from_mode(0o600))
        .map_err(|e| failed("finishing the file", &e))?;
    fs::rename(&part, &target).map_err(|e| failed("finishing the file", &e))?;
    let _ = fs::remove_file(&meta);
    Ok(json!({"path": args.path, "size": total}))
}

// ---- sweep ----

/// Removes old files from the inbox's session folders; returns how many went.
/// Best effort: what cannot be listed or removed is left for the next sweep.
fn sweep(home: &Path, max_age: Duration, max_files: usize, now: SystemTime) -> usize {
    let is_real_dir = |p: &Path| fs::symlink_metadata(p).is_ok_and(|m| m.is_dir());
    let base = inbox_base(home);
    if !is_real_dir(&home.join(HOME_FOLDER)) || !is_real_dir(&base) {
        return 0;
    }
    let Ok(folders) = fs::read_dir(&base) else {
        return 0;
    };
    let dirs: Vec<PathBuf> = folders
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_str().is_some_and(is_session_folder))
        .filter(|e| e.metadata().is_ok_and(|m| m.is_dir()))
        .map(|e| e.path())
        .collect();

    let age_of = |m: &fs::Metadata| m.modified().ok().and_then(|t| now.duration_since(t).ok());
    let mut doomed: Vec<(SystemTime, PathBuf)> = Vec::new();
    for dir in &dirs {
        let Ok(files) = fs::read_dir(dir) else {
            continue;
        };
        for entry in files.filter_map(Result::ok) {
            // `DirEntry::metadata` does not follow links: a link is not a file here.
            let Ok(meta) = entry.metadata() else { continue };
            let (Some(name), Some(age)) =
                (entry.file_name().to_str().map(str::to_owned), age_of(&meta))
            else {
                continue;
            };
            if !meta.is_file() {
                continue;
            }
            let partial = name.ends_with(".part") || name.ends_with(".meta");
            let stale = if partial {
                age > STALE_PARTIAL
            } else {
                age > max_age
            };
            // The record of an upload that is still receiving bytes is not stale.
            let part_alive = name.strip_suffix(".meta").is_some_and(|stem| {
                fs::symlink_metadata(dir.join(format!("{stem}.part")))
                    .is_ok_and(|p| age_of(&p).is_some_and(|a| a <= STALE_PARTIAL))
            });
            if stale && !part_alive {
                if let Ok(t) = meta.modified() {
                    doomed.push((t, entry.path()));
                }
            }
        }
    }
    doomed.sort();
    let mut removed = 0;
    for (_, path) in doomed.into_iter().take(max_files) {
        if fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    for dir in &dirs {
        // Succeeds only for an empty folder.
        let _ = fs::remove_dir(dir);
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn wire_code(r: Result<impl std::fmt::Debug, WireError>) -> ErrorCode {
        r.expect_err("an error").code
    }

    // ---- the cases of host_inbox_test.dart ----

    #[test]
    fn hostile_and_odd_names_become_sane_names() {
        let cases = [
            ("../x", "x"),
            ("../../.ssh/authorized_keys", "authorized_keys"),
            ("a/b", "b"),
            (r"C:\Users\me\Report 1.docx", "Report_1.docx"),
            (".bashrc", "bashrc"),
            ("...hidden.txt", "hidden.txt"),
            ("", "file"),
            ("   ", "file"),
            ("..", "file"),
            ("/", "file"),
            ("x/..", "file"),
            ("😀", "file"),
            ("x😀y.png", "x_y.png"),
            ("tài liệu.pdf", "tài_liệu.pdf"),
            ("Bản vẽ kỹ thuật (v2).dwg", "Bản_vẽ_kỹ_thuật__v2_.dwg"),
            ("a\u{202e}b.txt", "a_b.txt"),
            ("name\n.txt", "name_.txt"),
            ("photo.JPG", "photo.JPG"),
            ("archive.tar.gz", "archive.tar.gz"),
            ("noext", "noext"),
            ("trailing.", "trailing."),
        ];
        for (input, want) in cases {
            assert_eq!(safe_name(input), want, "for {input:?}");
        }
        assert_eq!(
            safe_name("ta\u{300}i.pdf"),
            "ta\u{300}i.pdf",
            "combining marks stay"
        );
    }

    #[test]
    fn a_long_name_is_cut_to_100_characters_and_200_bytes_and_the_extension_stays() {
        let cut = safe_name(&format!("{}.txt", "a".repeat(300)));
        assert_eq!(cut.chars().count(), 100);
        assert!(cut.ends_with(".txt"));

        // Three bytes a letter: the byte cap bites before the character cap.
        let viet = safe_name(&format!("{}.pdf", "ệ".repeat(150)));
        assert!(viet.len() <= 200);
        assert!(viet.ends_with(".pdf"));
        assert!(viet.chars().count() < 100);
        assert!(viet.chars().all(is_kept));

        // Four bytes a letter, outside the BMP.
        let astral = safe_name(&format!("{}.pdf", "\u{20000}".repeat(120)));
        assert!(astral.len() <= 200);
        assert!(astral.chars().all(is_kept));
    }

    #[test]
    fn whatever_goes_in_the_result_is_a_safe_non_hidden_non_empty_file_name() {
        let long = "x".repeat(500);
        let inputs = [
            "../../etc/passwd",
            "a\0b",
            ".",
            "....",
            "~/x",
            r"..\..\win",
            "x\t\ty",
            "\u{1F600}\u{1F600}.png",
            "with space and ünïcödé.txt",
            ".ssh",
            "CON",
            "a:b*c?.txt",
            "\"quoted\".md",
            long.as_str(),
        ];
        for input in inputs {
            let out = safe_name(input);
            assert!(!out.is_empty(), "{input:?}");
            assert!(out.chars().all(is_kept), "{input:?} -> {out:?}");
            assert!(!out.starts_with('.'), "{input:?} -> {out:?}");
            assert!(out.chars().count() <= 100, "{input:?}");
        }
    }

    #[test]
    fn the_session_folder_is_twelve_hex_of_the_sha1_of_the_key() {
        assert_eq!(session_folder("abc"), "a9993e364706"); // sha1("abc") = a9993e36 4706816a…
        assert_ne!(session_folder("abc"), session_folder("abd"));
        assert!(is_session_folder(&session_folder("")));
    }

    #[test]
    fn the_stamp_is_utc_with_civil_dates() {
        let at = |s: u64| UNIX_EPOCH + Duration::from_secs(s);
        assert_eq!(stamp(at(0)), "19700101-000000");
        assert_eq!(stamp(at(951_782_400)), "20000229-000000"); // a leap day
        assert_eq!(stamp(at(1_700_000_000)), "20231114-221320");
        assert_eq!(stamp(at(1_791_191_287)), "20261005-090807");
        assert_eq!(
            stamp(UNIX_EPOCH - Duration::from_secs(1)),
            "19691231-235959"
        );
    }

    fn mode_of(p: &Path) -> u32 {
        fs::metadata(p).expect("metadata").permissions().mode() & 0o7777
    }

    const NOW: u64 = 1_791_191_287; // 2026-10-05 09:08:07 UTC

    fn at_now() -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(NOW)
    }

    #[test]
    fn reserve_lands_under_the_inbox_in_the_folder_of_the_key() {
        let home = tempfile::tempdir().expect("home");
        let path = reserve_path(home.path(), "abc", "tài liệu.pdf", at_now()).expect("reserve");
        assert_eq!(
            path,
            home.path()
                .join(".herdr-mobile/inbox/a9993e364706/20261005-090807-tài_liệu.pdf")
        );
        assert!(path.parent().expect("parent").is_dir());
        assert!(!path.exists(), "a reservation is a name, not a file");
        let other = reserve_path(home.path(), "abd", "x.txt", at_now()).expect("reserve");
        assert!(!other.starts_with(home.path().join(".herdr-mobile/inbox/a9993e364706")));
    }

    #[test]
    fn reserve_makes_new_folders_0700_and_leaves_existing_ones_alone() {
        let home = tempfile::tempdir().expect("home");
        let state = home.path().join(".herdr-mobile");
        fs::create_dir(&state).expect("state");
        fs::set_permissions(&state, fs::Permissions::from_mode(0o755)).expect("chmod");
        fs::create_dir(state.join("keepers")).expect("keepers");
        reserve_path(home.path(), "s", "x", at_now()).expect("reserve");
        let folder = state.join("inbox").join(session_folder("s"));
        assert_eq!(mode_of(&state.join("inbox")), 0o700);
        assert_eq!(mode_of(&folder), 0o700);
        assert_eq!(
            mode_of(&state),
            0o755,
            "the state folder is not ours to change"
        );
        assert_eq!(mode_of(&state.join("keepers")), 0o755);

        let fresh = tempfile::tempdir().expect("home");
        reserve_path(fresh.path(), "s", "x", at_now()).expect("reserve");
        assert_eq!(mode_of(&fresh.path().join(".herdr-mobile")), 0o700);
    }

    #[test]
    fn a_hostile_name_stays_inside_the_session_folder() {
        let home = tempfile::tempdir().expect("home");
        let folder = home
            .path()
            .join(".herdr-mobile/inbox")
            .join(session_folder("s"));
        let long = "a".repeat(300);
        for name in [
            "../x",
            "../../.ssh/authorized_keys",
            "a/b",
            ".bashrc",
            "",
            long.as_str(),
            "😀",
            "tài liệu.pdf",
            r"..\..\x",
            "/etc/passwd",
        ] {
            let path = reserve_path(home.path(), "s", name, at_now()).expect(name);
            assert_eq!(path.parent(), Some(folder.as_path()), "{name:?}");
            let leaf = path.file_name().and_then(|l| l.to_str()).expect("leaf");
            assert!(leaf.len() <= 255, "{name:?}");
            assert!(!leaf.contains(".."), "{name:?}");
            assert!(
                is_inbox_name(leaf),
                "put must accept what reserve gives: {leaf}"
            );
        }
    }

    #[test]
    fn a_name_taken_on_the_host_gets_2_3_before_the_extension() {
        let home = tempfile::tempdir().expect("home");
        let folder = home
            .path()
            .join(".herdr-mobile/inbox")
            .join(session_folder("s"));
        fs::create_dir_all(&folder).expect("folder");
        fs::write(folder.join("20261005-090807-report.pdf"), b"x").expect("file");
        let second = reserve_path(home.path(), "s", "report.pdf", at_now()).expect("2");
        assert_eq!(second, folder.join("20261005-090807-report-2.pdf"));
        fs::write(&second, b"x").expect("file");
        fs::write(folder.join("20261005-090807-report-3.pdf"), b"x").expect("file");
        let fourth = reserve_path(home.path(), "s", "report.pdf", at_now()).expect("4");
        assert_eq!(fourth, folder.join("20261005-090807-report-4.pdf"));

        fs::write(folder.join("20261005-090807-notes"), b"x").expect("file");
        let notes = reserve_path(home.path(), "s", "notes", at_now()).expect("notes");
        assert_eq!(notes, folder.join("20261005-090807-notes-2"));
    }

    #[test]
    fn an_unfinished_upload_holds_its_name_too() {
        let home = tempfile::tempdir().expect("home");
        let folder = home
            .path()
            .join(".herdr-mobile/inbox")
            .join(session_folder("s"));
        fs::create_dir_all(&folder).expect("folder");
        fs::write(folder.join("20261005-090807-big.bin.part"), b"x").expect("part");
        let path = reserve_path(home.path(), "s", "big.bin", at_now()).expect("reserve");
        assert_eq!(path, folder.join("20261005-090807-big-2.bin"));
    }

    #[test]
    fn two_files_reserved_at_once_never_get_the_same_path() {
        let home = tempfile::tempdir().expect("home");
        let paths: HashSet<PathBuf> = (0..5)
            .map(|_| reserve_path(home.path(), "s", "IMG.jpg", at_now()).expect("reserve"))
            .collect();
        assert_eq!(paths.len(), 5);
        let folder = home
            .path()
            .join(".herdr-mobile/inbox")
            .join(session_folder("s"));
        assert!(paths.contains(&folder.join("20261005-090807-IMG.jpg")));
        assert!(paths.contains(&folder.join("20261005-090807-IMG-5.jpg")));
    }

    #[test]
    fn a_folder_that_cannot_be_made_fails_with_a_typed_error() {
        if rustix::process::geteuid().is_root() {
            return;
        }
        let home = tempfile::tempdir().expect("home");
        let state = home.path().join(".herdr-mobile");
        fs::create_dir(&state).expect("state");
        fs::set_permissions(&state, fs::Permissions::from_mode(0o500)).expect("chmod");
        let denied = reserve_path(home.path(), "s", "x", at_now());
        fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).expect("restore");
        assert_eq!(wire_code(denied), ErrorCode::Permission);
        assert!(
            reserve_path(home.path(), "s", "x", at_now()).is_ok(),
            "nothing was remembered"
        );
    }

    #[test]
    fn an_inbox_reached_through_a_link_is_refused() {
        let home = tempfile::tempdir().expect("home");
        let elsewhere = tempfile::tempdir().expect("elsewhere");
        let state = home.path().join(".herdr-mobile");
        fs::create_dir(&state).expect("state");
        symlink(elsewhere.path(), state.join("inbox")).expect("link");
        assert_eq!(
            wire_code(reserve_path(home.path(), "s", "x", at_now())),
            ErrorCode::BadRequest
        );
        assert_eq!(fs::read_dir(elsewhere.path()).expect("list").count(), 0);

        let second = tempfile::tempdir().expect("home");
        let inbox = second.path().join(".herdr-mobile/inbox");
        fs::create_dir_all(&inbox).expect("inbox");
        symlink(elsewhere.path(), inbox.join(session_folder("s"))).expect("link");
        assert_eq!(
            wire_code(reserve_path(second.path(), "s", "x", at_now())),
            ErrorCode::BadRequest
        );
    }

    // ---- which paths `put` takes ----

    #[test]
    fn the_catalog_examples_parse_into_the_typed_arguments() {
        for m in METHODS {
            let args: Value = serde_json::from_str(m.args_example).expect("example is JSON");
            serde_json::from_str::<Value>(m.result_example).expect("result is JSON");
            match m.name {
                "reserve" => {
                    parse_args::<ReserveArgs>(&args).expect(m.name);
                }
                "put" => {
                    let a = parse_args::<PutArgs>(&args).expect(m.name);
                    let home = Path::new("/home/dev");
                    parse_inbox_path(home, &a.path)
                        .expect("the example path is a valid inbox path");
                }
                "sweep" => {
                    parse_args::<SweepArgs>(&args).expect(m.name);
                }
                other => panic!("no typed arguments for {other}"),
            }
        }
    }

    #[test]
    fn put_takes_only_the_exact_shape_of_a_reserved_path() {
        let home = Path::new("/home/dev");
        let good = "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt";
        assert_eq!(
            parse_inbox_path(home, good).expect("good"),
            (
                "a9993e364706".to_string(),
                "20261005-090807-x.txt".to_string()
            )
        );
        let bad = [
            // traversal and separators
            "/home/dev/.herdr-mobile/inbox/a9993e364706/../20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-../x",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/sub/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706//20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox//a9993e364706/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/./a9993e364706/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt/",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/",
            "/home/dev/.herdr-mobile/inbox/a9993e364706",
            // other parents
            "/home/other/.herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/keepers/a9993e364706/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/../../../.ssh/authorized_keys",
            "/etc/passwd",
            "~/.herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt",
            ".herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt",
            "",
            // the folder
            "/home/dev/.herdr-mobile/inbox/A9993E364706/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e36470/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e3647061/20261005-090807-x.txt",
            "/home/dev/.herdr-mobile/inbox/zzzzzzzzzzzz/20261005-090807-x.txt",
            // the name
            "/home/dev/.herdr-mobile/inbox/a9993e364706/x.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-.bashrc",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt.part",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-x.txt.meta",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-a b.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-a\0b.txt",
            "/home/dev/.herdr-mobile/inbox/a9993e364706/2026100-090807-x.txt",
        ];
        for path in bad {
            assert_eq!(
                parse_inbox_path(home, path).map_err(|e| e.code),
                Err(ErrorCode::BadRequest),
                "{path:?}"
            );
        }
        let too_long = format!(
            "/home/dev/.herdr-mobile/inbox/a9993e364706/20261005-090807-{}",
            "a".repeat(300)
        );
        assert!(parse_inbox_path(home, &too_long).is_err());
    }

    // ---- resume bookkeeping ----

    #[test]
    fn a_partial_file_resumes_only_for_the_same_size_and_digest() {
        let dir = tempfile::tempdir().expect("dir");
        let part = dir.path().join("f.part");
        let meta = dir.path().join("f.meta");
        let sha = "ab".repeat(32);
        fs::write(&part, vec![1u8; 100]).expect("part");
        assert_eq!(resumable(&part, &meta, 500, &sha), 0, "no record");
        fs::write(&meta, json!({"size": 500, "sha256": sha}).to_string()).expect("meta");
        assert_eq!(resumable(&part, &meta, 500, &sha), 100);
        assert_eq!(resumable(&part, &meta, 500, &sha.to_uppercase()), 100);
        assert_eq!(resumable(&part, &meta, 501, &sha), 0, "another size");
        assert_eq!(
            resumable(&part, &meta, 500, &"cd".repeat(32)),
            0,
            "another digest"
        );
        assert_eq!(
            resumable(&part, &meta, 50, &sha),
            0,
            "part longer than the file"
        );
        fs::write(&meta, b"not json").expect("meta");
        assert_eq!(resumable(&part, &meta, 500, &sha), 0);
    }

    #[test]
    fn a_partial_file_that_is_a_link_is_never_resumed() {
        let dir = tempfile::tempdir().expect("dir");
        let decoy = dir.path().join("decoy");
        fs::write(&decoy, b"precious").expect("decoy");
        let part = dir.path().join("f.part");
        let meta = dir.path().join("f.meta");
        symlink(&decoy, &part).expect("link");
        let sha = "ab".repeat(32);
        fs::write(&meta, json!({"size": 500, "sha256": sha}).to_string()).expect("meta");
        assert_eq!(resumable(&part, &meta, 500, &sha), 0);
        // Starting over replaces the link, it does not write through it.
        let mut f = start_fresh(&part, &meta, 500, &sha).expect("fresh");
        f.write_all(b"new").expect("write");
        assert_eq!(fs::read(&decoy).expect("decoy"), b"precious");
        assert_eq!(fs::read(&part).expect("part"), b"new");
        assert_eq!(mode_of(&part), 0o600);
        assert_eq!(mode_of(&meta), 0o600);
    }

    #[test]
    fn two_uploads_of_one_target_cannot_run_together() {
        let target = PathBuf::from("/tmp/herdr-test-busy-target");
        let first = Busy::acquire(&target).expect("first");
        assert_eq!(wire_code(Busy::acquire(&target)), ErrorCode::Busy);
        drop(first);
        assert!(Busy::acquire(&target).is_ok());
    }

    // ---- sweep ----

    struct Inbox {
        home: tempfile::TempDir,
    }

    impl Inbox {
        fn new() -> Self {
            Self {
                home: tempfile::tempdir().expect("home"),
            }
        }

        fn base(&self) -> PathBuf {
            self.home.path().join(".herdr-mobile/inbox")
        }

        /// A file `days` old (fractions allowed) at `rel` below the home.
        fn file(&self, rel: &str, age: Duration) -> PathBuf {
            let path = self.home.path().join(rel);
            fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
            fs::write(&path, b"x").expect("file");
            File::options()
                .write(true)
                .open(&path)
                .expect("open")
                .set_modified(at_now() - age)
                .expect("set mtime");
            path
        }

        fn sweep(&self, max_age: Duration, cap: usize) -> usize {
            sweep(self.home.path(), max_age, cap, at_now())
        }
    }

    const DAY: Duration = Duration::from_secs(86_400);
    const H: &str = ".herdr-mobile/inbox/aaaaaaaaaaaa";

    #[test]
    fn sweep_removes_only_old_regular_files_directly_inside_session_folders() {
        let inbox = Inbox::new();
        let day = |n: u32| DAY * n;
        inbox.file(&format!("{H}/old-20d"), day(20));
        inbox.file(&format!("{H}/old-15d"), day(15));
        let new = inbox.file(&format!("{H}/new-13d"), day(13));
        let exactly = inbox.file(&format!("{H}/exactly-14d"), day(14));
        let other = inbox.file(
            ".herdr-mobile/inbox/bbbbbbbbbbbb/old-other-session",
            day(40),
        );
        // Not to be touched:
        let precious = inbox.file("precious", day(90));
        symlink(&precious, inbox.base().join("aaaaaaaaaaaa/old-link")).expect("link");
        let deep = inbox.file(&format!("{H}/sub/deep-old"), day(90));
        let not_hex = inbox.file(".herdr-mobile/inbox/not-a-hash/old", day(90));
        let top = inbox.file(".herdr-mobile/inbox/top-level-old", day(90));
        let keepers = inbox.file(".herdr-mobile/keepers/state", day(90));
        let notes = inbox.file("notes.txt", day(90));
        let upper = inbox.file(".herdr-mobile/inbox/CCCCCCCCCCCC/old-upper", day(90));

        assert_eq!(inbox.sweep(day(14), 200), 3);

        assert!(!inbox.base().join("aaaaaaaaaaaa/old-20d").exists());
        assert!(!inbox.base().join("aaaaaaaaaaaa/old-15d").exists());
        assert!(!other.exists());
        for kept in [
            &new, &exactly, &precious, &deep, &not_hex, &top, &keepers, &notes, &upper,
        ] {
            assert!(kept.exists(), "{kept:?} must stay");
        }
        assert!(
            fs::symlink_metadata(inbox.base().join("aaaaaaaaaaaa/old-link")).is_ok(),
            "a link is skipped, not removed"
        );
        assert!(
            !inbox.base().join("bbbbbbbbbbbb").exists(),
            "an emptied folder goes"
        );
    }

    #[test]
    fn sweep_never_removes_more_than_the_cap_and_takes_the_oldest_first() {
        let inbox = Inbox::new();
        for h in ["111111111111", "222222222222", "333333333333"] {
            for i in 0..100u32 {
                let age = DAY * 30 + Duration::from_secs(u64::from(i) * 60);
                inbox.file(&format!(".herdr-mobile/inbox/{h}/f{i}"), age);
            }
        }
        assert_eq!(inbox.sweep(DAY * 14, 200), 200);
        let left = |n: u32| {
            (0..3)
                .filter(|h| {
                    inbox
                        .base()
                        .join(format!("{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}", h + 1))
                        .join(format!("f{n}"))
                        .exists()
                })
                .count()
        };
        assert_eq!(left(99), 0, "the oldest are gone");
        assert_eq!(left(0), 3, "the newest of them stay");
        assert_eq!(inbox.sweep(DAY * 14, 7), 7);
        assert_eq!(inbox.sweep(DAY * 14, 200), 93);
    }

    #[test]
    fn sweep_drops_stale_unfinished_uploads_but_not_one_still_growing() {
        let inbox = Inbox::new();
        let hours = |n: u64| Duration::from_secs(n * 3600);
        let old_part = inbox.file(&format!("{H}/20260101-000000-a.bin.part"), hours(30));
        let old_meta = inbox.file(&format!("{H}/20260101-000000-a.bin.meta"), hours(30));
        let fresh_part = inbox.file(&format!("{H}/20260101-000000-b.bin.part"), hours(2));
        let fresh_meta = inbox.file(&format!("{H}/20260101-000000-b.bin.meta"), hours(2));
        // A long upload: its record is old but the part is still being written.
        let live_part = inbox.file(&format!("{H}/20260101-000000-c.bin.part"), hours(1));
        let live_meta = inbox.file(&format!("{H}/20260101-000000-c.bin.meta"), hours(40));
        let done = inbox.file(&format!("{H}/20260101-000000-d.bin"), hours(30));

        assert_eq!(inbox.sweep(DAY * 14, 200), 2);
        assert!(!old_part.exists() && !old_meta.exists());
        for kept in [&fresh_part, &fresh_meta, &live_part, &live_meta, &done] {
            assert!(kept.exists(), "{kept:?} must stay");
        }
    }

    #[test]
    fn sweep_does_not_follow_links_out_of_the_inbox() {
        let inbox = Inbox::new();
        let outside = tempfile::tempdir().expect("outside");
        let decoy = outside.path().join("decoy");
        fs::write(&decoy, b"keep").expect("decoy");
        File::options()
            .write(true)
            .open(&decoy)
            .expect("open")
            .set_modified(at_now() - DAY * 90)
            .expect("mtime");
        fs::create_dir_all(inbox.base()).expect("inbox");
        // A session folder that is a link to a folder outside.
        symlink(outside.path(), inbox.base().join("dddddddddddd")).expect("link");
        // A file link inside a real session folder, pointing at the decoy.
        fs::create_dir_all(inbox.base().join("eeeeeeeeeeee")).expect("folder");
        symlink(&decoy, inbox.base().join("eeeeeeeeeeee/old-link")).expect("link");

        assert_eq!(inbox.sweep(DAY * 14, 200), 0);
        assert_eq!(fs::read(&decoy).expect("decoy"), b"keep");
        assert!(fs::symlink_metadata(inbox.base().join("dddddddddddd")).is_ok());
        assert!(fs::symlink_metadata(inbox.base().join("eeeeeeeeeeee/old-link")).is_ok());
    }

    #[test]
    fn sweep_through_a_linked_inbox_does_nothing() {
        let home = tempfile::tempdir().expect("home");
        let outside = tempfile::tempdir().expect("outside");
        fs::create_dir_all(outside.path().join("aaaaaaaaaaaa")).expect("folder");
        let old = outside.path().join("aaaaaaaaaaaa/old");
        fs::write(&old, b"x").expect("old");
        File::options()
            .write(true)
            .open(&old)
            .expect("open")
            .set_modified(at_now() - DAY * 90)
            .expect("mtime");
        fs::create_dir(home.path().join(".herdr-mobile")).expect("state");
        symlink(outside.path(), home.path().join(".herdr-mobile/inbox")).expect("link");
        assert_eq!(sweep(home.path(), DAY * 14, 200, at_now()), 0);
        assert!(old.exists());
    }

    #[test]
    fn sweep_with_no_inbox_is_quietly_nothing() {
        let inbox = Inbox::new();
        assert_eq!(inbox.sweep(DAY * 14, 200), 0);
        fs::create_dir_all(inbox.base()).expect("inbox");
        assert_eq!(inbox.sweep(DAY * 14, 200), 0);
    }
}
