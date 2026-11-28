//! `fs`: looking at the host's files. Read-only: nothing here creates, changes
//! or removes anything. Paths are absolute or start with `~` (the home of the
//! user `serve` runs as); beyond that nothing is restricted, which is the same
//! reach the app had over SFTP.

use crate::service::{Class, MethodKind, MethodSpec, Service};
use crate::session::{Compress, StreamCtx};
use rustix::io::Errno;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use std::fs::{self, File, Metadata};
use std::io::{self, ErrorKind, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use wire::{ClientHello, ErrorCode, ServiceStatus, WireError};

/// Entries in one `fs.list` MSG.
pub const LIST_CHUNK: usize = 500;

/// The most `fs.read` hands out in one request.
pub const MAX_READ: u64 = 64 * 1024 * 1024;

/// Paths one `fs.watch` may follow.
pub const MAX_WATCH_PATHS: usize = 32;

/// The fastest `fs.watch` poll.
pub const MIN_WATCH_INTERVAL_MS: u64 = 500;

const DEFAULT_WATCH_INTERVAL_MS: u64 = 2000;

/// A MSG may not pass 1 MiB on the wire; a name is escaped to at most six
/// bytes a byte, so a chunk closes early when its names could get near that.
const LIST_BUDGET: usize = 400_000;

static METHODS: &[MethodSpec] = &[
    MethodSpec {
        name: "stat",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "What `path` is, following links: kind file|dir|other, size in bytes, modification time in milliseconds since the epoch, and the permission bits. Errors not_found, permission.",
        args_example: r#"{"path":"~/notes.txt"}"#,
        result_example: r#"{"kind":"file","size":1204,"mtime_ms":1760000000000,"mode":420}"#,
    },
    MethodSpec {
        name: "list",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "The entries of a folder, as MSG {entries} of at most 500 each (never `.` or `..`, in the order the system gives them, a link is kind `link`). Ends with {count}. Errors not_found, permission, not_a_directory.",
        args_example: r#"{"path":"~/projects"}"#,
        result_example: r#"{"count":1}"#,
    },
    MethodSpec {
        name: "real_path",
        kind: MethodKind::Call,
        class: Class::Interactive,
        summary: "The absolute path `path` really is: `~` and `~/x` expand to the home folder, links and `..` are resolved. Errors not_found, permission.",
        args_example: r#"{"path":"~"}"#,
        result_example: r#"{"path":"/home/dev"}"#,
    },
    MethodSpec {
        name: "read",
        kind: MethodKind::Stream,
        class: Class::Bulk,
        summary: "Bytes of a file. First MSG {size,mtime_ms} of the file being read; if `if_match` is given and differs the stream ends with error `changed` and no data. Then DATA, then END {eof}: eof is true when fewer than `length` bytes were there. `length` is at most 64 MiB (too_large). Never compressed unless `z` is true.",
        args_example: r#"{"path":"~/notes.txt","offset":0,"length":65536,"if_match":{"size":1204,"mtime_ms":1760000000000},"z":false}"#,
        result_example: r#"{"eof":true}"#,
    },
    MethodSpec {
        name: "watch",
        kind: MethodKind::Stream,
        class: Class::Interactive,
        summary: "Polls up to 32 paths every `interval_ms` (at least 500). One MSG per path at once, then one per change. size and mtime_ms are absent when the path does not exist.",
        args_example: r#"{"paths":["~/notes.txt"],"interval_ms":2000}"#,
        result_example: r#"{}"#,
    },
    super::thumb::SPEC,
    super::search::SPEC,
];

/// The `fs` service.
#[derive(Default)]
pub struct FsService;

impl FsService {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Service for FsService {
    fn name(&self) -> &'static str {
        "fs"
    }

    fn methods(&self) -> &'static [MethodSpec] {
        METHODS
    }

    fn availability(&self, _: &ClientHello) -> ServiceStatus {
        ServiceStatus::available()
    }

    fn open(&self, method: &str, ctx: &StreamCtx) -> Result<Value, WireError> {
        match method {
            "stat" => {
                let args: PathArgs = parse_args(ctx.args())?;
                stat(ctx.home(), &args.path)
            }
            "list" => {
                let args: PathArgs = parse_args(ctx.args())?;
                list(ctx, &args.path)
            }
            "real_path" => {
                let args: PathArgs = parse_args(ctx.args())?;
                real_path(ctx.home(), &args.path)
            }
            "read" => read(ctx),
            "watch" => watch(ctx),
            "thumb" => super::thumb::thumb(ctx),
            "search" => super::search::search(ctx),
            other => Err(WireError::new(
                ErrorCode::UnknownMethod,
                format!("fs has no method {other}"),
            )),
        }
    }
}

// ---- arguments, paths, errors (shared with `transfer`) ----

#[derive(Debug, Deserialize)]
pub(crate) struct PathArgs {
    pub path: String,
}

#[derive(Debug, Deserialize)]
pub(crate) struct Identity {
    pub size: u64,
    pub mtime_ms: i64,
}

#[derive(Debug, Deserialize)]
pub(crate) struct ReadArgs {
    pub path: String,
    #[serde(default)]
    pub offset: u64,
    pub length: u64,
    #[serde(default)]
    pub if_match: Option<Identity>,
    #[serde(default)]
    pub z: bool,
}

#[derive(Debug, Deserialize)]
pub(crate) struct WatchArgs {
    pub paths: Vec<String>,
    #[serde(default = "default_interval")]
    pub interval_ms: u64,
}

fn default_interval() -> u64 {
    DEFAULT_WATCH_INTERVAL_MS
}

/// The typed arguments of an `OPEN`.
pub(crate) fn parse_args<T: DeserializeOwned>(args: &Value) -> Result<T, WireError> {
    serde_json::from_value(args.clone())
        .map_err(|e| WireError::new(ErrorCode::BadRequest, format!("bad arguments: {e}")))
}

/// The host path a client path names: absolute, or `~` / `~/x` under `home`.
/// A NUL byte, a relative path and `~user` are `bad_request`.
pub(crate) fn resolve(home: &Path, given: &str) -> Result<PathBuf, WireError> {
    let bad = |why: &str| WireError::new(ErrorCode::BadRequest, format!("{given:?}: {why}"));
    if given.contains('\0') {
        return Err(bad("a path cannot contain a NUL byte"));
    }
    if given == "~" {
        return Ok(home.to_path_buf());
    }
    if let Some(rest) = given.strip_prefix("~/") {
        return Ok(home.join(rest));
    }
    if given.starts_with('/') {
        return Ok(PathBuf::from(given));
    }
    Err(bad("a path starts with / or ~/"))
}

/// A file system error as the wire's closed set of codes, worded for a person
/// with the path the client sent.
pub(crate) fn io_error(e: &io::Error, given: &str) -> WireError {
    let (code, words) = match e.kind() {
        ErrorKind::NotFound => (ErrorCode::NotFound, "does not exist".to_string()),
        ErrorKind::PermissionDenied => (ErrorCode::Permission, "permission denied".to_string()),
        ErrorKind::NotADirectory => (ErrorCode::NotADirectory, "is not a folder".to_string()),
        ErrorKind::IsADirectory => (ErrorCode::NotAFile, "is a folder".to_string()),
        _ if Errno::from_io_error(e) == Some(Errno::LOOP) => (
            ErrorCode::Failed,
            "has too many levels of links".to_string(),
        ),
        _ => (ErrorCode::Failed, e.to_string()),
    };
    WireError::new(code, format!("{given}: {words}"))
}

/// Modification time in milliseconds since the epoch.
pub(crate) fn mtime_ms(meta: &Metadata) -> i64 {
    meta.mtime()
        .saturating_mul(1000)
        .saturating_add(meta.mtime_nsec() / 1_000_000)
}

fn kind_of(meta: &Metadata) -> &'static str {
    let t = meta.file_type();
    if t.is_file() {
        "file"
    } else if t.is_dir() {
        "dir"
    } else if t.is_symlink() {
        "link"
    } else {
        "other"
    }
}

fn permission_bits(meta: &Metadata) -> u32 {
    meta.mode() & 0o7777
}

fn entry_json(name: &str, meta: &Metadata) -> Value {
    json!({
        "name": name,
        "kind": kind_of(meta),
        "size": meta.len(),
        "mtime_ms": mtime_ms(meta),
        "mode": permission_bits(meta),
    })
}

// ---- stat, real_path ----

fn stat(home: &Path, given: &str) -> Result<Value, WireError> {
    let path = resolve(home, given)?;
    let meta = fs::metadata(&path).map_err(|e| io_error(&e, given))?;
    Ok(json!({
        "kind": kind_of(&meta),
        "size": meta.len(),
        "mtime_ms": mtime_ms(&meta),
        "mode": permission_bits(&meta),
    }))
}

fn real_path(home: &Path, given: &str) -> Result<Value, WireError> {
    let path = resolve(home, given)?;
    let real = fs::canonicalize(&path).map_err(|e| io_error(&e, given))?;
    Ok(json!({"path": real.to_string_lossy()}))
}

// ---- list ----

/// Hands the entries of the folder `path` to `sink` in chunks of at most
/// [`LIST_CHUNK`]; an empty folder gives one empty chunk. Returns the count.
fn list_chunks(
    path: &Path,
    given: &str,
    sink: &mut dyn FnMut(Vec<Value>) -> Result<(), WireError>,
) -> Result<usize, WireError> {
    let dir = fs::read_dir(path).map_err(|e| io_error(&e, given))?;
    let mut chunk = Vec::new();
    let mut budget = 0usize;
    let mut count = 0usize;
    let mut sent_any = false;
    for entry in dir {
        // An entry that vanished or cannot be read between the listing and
        // the stat is skipped: the folder is changing under us.
        let Ok(entry) = entry else { continue };
        let Ok(meta) = entry.metadata() else { continue };
        let name = entry.file_name().to_string_lossy().into_owned();
        budget += name.len() * 6 + 120;
        chunk.push(entry_json(&name, &meta));
        count += 1;
        if chunk.len() >= LIST_CHUNK || budget >= LIST_BUDGET {
            sink(std::mem::take(&mut chunk))?;
            sent_any = true;
            budget = 0;
        }
    }
    if !chunk.is_empty() || !sent_any {
        sink(chunk)?;
    }
    Ok(count)
}

fn list(ctx: &StreamCtx, given: &str) -> Result<Value, WireError> {
    let path = resolve(ctx.home(), given)?;
    let count = list_chunks(&path, given, &mut |entries| {
        if ctx.cancelled() {
            return Err(WireError::new(
                ErrorCode::Cancelled,
                "the stream was closed",
            ));
        }
        ctx.send_msg(&json!({"entries": entries}))?;
        Ok(())
    })?;
    Ok(json!({"count": count}))
}

// ---- read ----

/// Opens `path` for reading without ever blocking (a FIFO would, on `open`)
/// and returns the handle with the identity of what it will read.
pub(crate) fn open_regular(path: &Path, given: &str) -> Result<(File, Metadata), WireError> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NONBLOCK.bits().cast_signed())
        .open(path)
        .map_err(|e| io_error(&e, given))?;
    let meta = file.metadata().map_err(|e| io_error(&e, given))?;
    if meta.is_dir() {
        return Err(WireError::new(
            ErrorCode::NotAFile,
            format!("{given}: is a folder"),
        ));
    }
    if !meta.is_file() {
        return Err(WireError::new(
            ErrorCode::NotAFile,
            format!("{given}: is not a regular file"),
        ));
    }
    Ok((file, meta))
}

fn read(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: ReadArgs = parse_args(ctx.args())?;
    if args.length > MAX_READ {
        return Err(WireError::new(
            ErrorCode::TooLarge,
            format!("at most {} MiB in one read", MAX_READ / 1024 / 1024),
        ));
    }
    let path = resolve(ctx.home(), &args.path)?;
    if !args.z {
        ctx.set_compress(Compress::Never);
    }
    let (mut file, meta) = open_regular(&path, &args.path)?;
    let (size, mtime) = (meta.len(), mtime_ms(&meta));
    if let Some(want) = &args.if_match {
        if want.size != size || want.mtime_ms != mtime {
            return Err(WireError::new(
                ErrorCode::Changed,
                format!("{}: the file changed", args.path),
            ));
        }
    }
    ctx.send_msg(&json!({"size": size, "mtime_ms": mtime}))?;

    let mut remaining = args.length;
    let mut eof = args.offset >= size;
    if !eof {
        file.seek(SeekFrom::Start(args.offset))
            .map_err(|e| io_error(&e, &args.path))?;
        let mut buf = vec![0u8; 32 * 1024];
        while remaining > 0 {
            if ctx.cancelled() {
                return Err(WireError::new(
                    ErrorCode::Cancelled,
                    "the stream was closed",
                ));
            }
            let want = usize::try_from(remaining).map_or(buf.len(), |r| r.min(buf.len()));
            let n = match file.read(&mut buf[..want]) {
                Ok(n) => n,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(io_error(&e, &args.path)),
            };
            if n == 0 {
                eof = true;
                break;
            }
            ctx.send_data(&buf[..n])?;
            remaining -= n as u64;
        }
    }
    Ok(json!({"eof": eof}))
}

// ---- watch ----

/// What a watched path was at one poll: `(size, mtime_ms)` when it exists.
type Seen = Option<(u64, i64)>;

fn look(path: &Path) -> Seen {
    fs::metadata(path).ok().map(|m| (m.len(), mtime_ms(&m)))
}

fn change_msg(given: &str, seen: Seen) -> Value {
    match seen {
        Some((size, mtime)) => {
            json!({"path": given, "exists": true, "size": size, "mtime_ms": mtime})
        }
        None => json!({"path": given, "exists": false}),
    }
}

fn watch(ctx: &StreamCtx) -> Result<Value, WireError> {
    let args: WatchArgs = parse_args(ctx.args())?;
    if args.paths.is_empty() || args.paths.len() > MAX_WATCH_PATHS {
        return Err(WireError::new(
            ErrorCode::BadRequest,
            format!("watch 1 to {MAX_WATCH_PATHS} paths"),
        ));
    }
    if args.interval_ms < MIN_WATCH_INTERVAL_MS {
        return Err(WireError::new(
            ErrorCode::BadRequest,
            format!("the interval is at least {MIN_WATCH_INTERVAL_MS} ms"),
        ));
    }
    let mut watched = Vec::with_capacity(args.paths.len());
    for given in &args.paths {
        let path = resolve(ctx.home(), given)?;
        let seen = look(&path);
        ctx.send_msg(&change_msg(given, seen))?;
        watched.push((given, path, seen));
    }
    while ctx.sleep(std::time::Duration::from_millis(args.interval_ms)) {
        for (given, path, before) in &mut watched {
            let now = look(path);
            if now != *before {
                *before = now;
                ctx.send_msg(&change_msg(given, now))?;
            }
        }
    }
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::{symlink, PermissionsExt};

    const HOME: &str = "/home/dev";

    fn code(r: Result<impl std::fmt::Debug, WireError>) -> ErrorCode {
        r.expect_err("an error").code
    }

    #[test]
    fn the_catalog_examples_parse_into_the_typed_arguments() {
        for m in METHODS {
            let args: Value = serde_json::from_str(m.args_example).expect("example is JSON");
            serde_json::from_str::<Value>(m.result_example).expect("result is JSON");
            match m.name {
                "stat" | "list" | "real_path" => {
                    parse_args::<PathArgs>(&args).expect(m.name);
                }
                "read" => {
                    let a = parse_args::<ReadArgs>(&args).expect(m.name);
                    assert!(a.if_match.is_some());
                }
                "watch" => {
                    let a = parse_args::<WatchArgs>(&args).expect(m.name);
                    assert!(a.interval_ms >= MIN_WATCH_INTERVAL_MS);
                }
                "thumb" => {
                    let a = parse_args::<super::super::thumb::ThumbArgs>(&args).expect(m.name);
                    assert!(a.if_match.is_some());
                }
                "search" => {
                    let a = parse_args::<super::super::search::SearchArgs>(&args).expect(m.name);
                    assert!(a.modified_within_s.is_some() && a.ignore.is_some());
                }
                other => panic!("no typed arguments for {other}"),
            }
        }
    }

    #[test]
    fn paths_are_absolute_or_under_the_home() {
        let home = Path::new(HOME);
        assert_eq!(resolve(home, "~").expect("~"), home);
        assert_eq!(resolve(home, "~/a/b").expect("~/a/b"), home.join("a/b"));
        assert_eq!(resolve(home, "~/").expect("~/"), home);
        assert_eq!(
            resolve(home, "/etc/hosts").expect("abs"),
            Path::new("/etc/hosts")
        );
        for bad in ["", "relative/x", "./x", "~root/x", "~x", "/a\0b", "~/a\0"] {
            assert_eq!(code(resolve(home, bad)), ErrorCode::BadRequest, "{bad:?}");
        }
    }

    #[test]
    fn file_system_errors_become_the_codes_a_client_can_act_on() {
        let dir = tempfile::tempdir().expect("tempdir");
        let file = dir.path().join("f");
        fs::write(&file, b"x").expect("write");
        let given = |p: &Path| p.to_string_lossy().into_owned();
        let home = dir.path();

        let missing = given(&dir.path().join("missing"));
        assert_eq!(code(stat(home, &missing)), ErrorCode::NotFound);
        let through_file = given(&file.join("below"));
        assert_eq!(code(stat(home, &through_file)), ErrorCode::NotADirectory);
        let err = stat(home, &missing).expect_err("missing");
        assert!(
            err.message.contains(&missing),
            "the path as sent: {}",
            err.message
        );
    }

    #[test]
    fn stat_follows_links_and_reports_the_target() {
        let dir = tempfile::tempdir().expect("tempdir");
        let file = dir.path().join("f");
        fs::write(&file, b"hello").expect("write");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).expect("chmod");
        symlink(&file, dir.path().join("l")).expect("link");
        fs::create_dir(dir.path().join("d")).expect("dir");
        let home = dir.path();

        let s = stat(home, "~/l").expect("stat link");
        assert_eq!(s["kind"], "file");
        assert_eq!(s["size"], 5);
        assert_eq!(s["mode"], 0o640);
        let modified = fs::metadata(&file)
            .expect("meta")
            .modified()
            .expect("mtime");
        let ms = modified
            .duration_since(std::time::UNIX_EPOCH)
            .expect("after the epoch")
            .as_millis();
        assert_eq!(i128::from(s["mtime_ms"].as_i64().expect("int")), ms as i128);
        assert_eq!(stat(home, "~/d").expect("dir")["kind"], "dir");
    }

    #[test]
    fn a_link_loop_is_an_error_not_a_hang() {
        let dir = tempfile::tempdir().expect("tempdir");
        symlink(dir.path().join("b"), dir.path().join("a")).expect("link a");
        symlink(dir.path().join("a"), dir.path().join("b")).expect("link b");
        let home = dir.path();
        assert_eq!(code(stat(home, "~/a")), ErrorCode::Failed);
        assert_eq!(code(real_path(home, "~/a")), ErrorCode::Failed);
        let entries = collect(&dir.path().join("a"), "~/a");
        assert_eq!(code(entries), ErrorCode::Failed);
        // Listing the folder that holds the loop works: both are links.
        let ok = collect(dir.path(), "~").expect("list");
        assert!(ok.iter().all(|e| e["kind"] == "link"));
    }

    #[test]
    fn real_path_expands_the_home_and_resolves_links() {
        let dir = tempfile::tempdir().expect("tempdir");
        let home = fs::canonicalize(dir.path()).expect("canonical");
        fs::create_dir(home.join("real")).expect("dir");
        symlink(home.join("real"), home.join("via")).expect("link");
        assert_eq!(
            real_path(&home, "~").expect("home")["path"],
            home.to_string_lossy().as_ref()
        );
        assert_eq!(
            real_path(&home, "~/via/../real").expect("resolved")["path"],
            home.join("real").to_string_lossy().as_ref()
        );
        assert_eq!(code(real_path(&home, "~/nope")), ErrorCode::NotFound);
    }

    fn collect(path: &Path, given: &str) -> Result<Vec<Value>, WireError> {
        let mut all = Vec::new();
        list_chunks(path, given, &mut |chunk| {
            all.extend(chunk);
            Ok(())
        })?;
        Ok(all)
    }

    #[test]
    fn list_has_lstat_kinds_and_never_the_dot_entries() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join("file"), b"abc").expect("file");
        fs::create_dir(dir.path().join("sub")).expect("dir");
        symlink(dir.path().join("sub"), dir.path().join("link")).expect("link");
        symlink(dir.path().join("gone"), dir.path().join("dangling")).expect("dangling");
        let mut by_name: std::collections::BTreeMap<String, Value> = collect(dir.path(), "~")
            .expect("list")
            .into_iter()
            .map(|e| (e["name"].as_str().expect("name").to_string(), e))
            .collect();
        assert_eq!(by_name.len(), 4, "no . or ..: {by_name:?}");
        assert_eq!(by_name.remove("file").expect("file")["size"], 3);
        assert_eq!(by_name["sub"]["kind"], "dir");
        assert_eq!(by_name["link"]["kind"], "link", "lstat: a link is a link");
        assert_eq!(by_name["dangling"]["kind"], "link");
    }

    #[test]
    fn list_cuts_chunks_at_500_and_sends_one_for_an_empty_folder() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut sizes = Vec::new();
        let n = list_chunks(dir.path(), "~", &mut |c| {
            sizes.push(c.len());
            Ok(())
        })
        .expect("empty");
        assert_eq!((n, sizes.as_slice()), (0, [0usize].as_slice()));

        for i in 0..1200 {
            fs::write(dir.path().join(format!("f{i}")), b"").expect("file");
        }
        sizes.clear();
        let n = list_chunks(dir.path(), "~", &mut |c| {
            sizes.push(c.len());
            Ok(())
        })
        .expect("1200");
        assert_eq!(
            (n, sizes.as_slice()),
            (1200, [500usize, 500, 200].as_slice())
        );

        for i in 1200..1500 {
            fs::write(dir.path().join(format!("f{i}")), b"").expect("file");
        }
        sizes.clear();
        list_chunks(dir.path(), "~", &mut |c| {
            sizes.push(c.len());
            Ok(())
        })
        .expect("1500");
        assert_eq!(sizes, [500, 500, 500], "no empty trailing chunk");
    }

    #[test]
    fn a_name_that_is_not_utf8_is_sent_lossily_not_skipped() {
        let dir = tempfile::tempdir().expect("tempdir");
        let odd = OsString::from_vec(b"caf\xE9.txt".to_vec());
        if fs::write(dir.path().join(&odd), b"x").is_err() {
            return; // a file system that insists on UTF-8 names
        }
        let entries = collect(dir.path(), "~").expect("list");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["name"], "caf\u{FFFD}.txt");
    }

    #[test]
    fn listing_a_file_or_a_missing_folder_says_which() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::write(dir.path().join("f"), b"x").expect("file");
        assert_eq!(
            code(collect(&dir.path().join("f"), "f")),
            ErrorCode::NotADirectory
        );
        assert_eq!(
            code(collect(&dir.path().join("x"), "x")),
            ErrorCode::NotFound
        );
    }

    #[test]
    fn a_folder_you_may_not_open_is_permission_unless_you_are_root() {
        if rustix::process::geteuid().is_root() {
            return;
        }
        let dir = tempfile::tempdir().expect("tempdir");
        let locked = dir.path().join("locked");
        fs::create_dir(&locked).expect("dir");
        fs::write(locked.join("f"), b"x").expect("file");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");
        let listed = collect(&locked, "locked");
        let statted = stat(dir.path(), "~/locked/f");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).expect("restore");
        assert_eq!(code(listed), ErrorCode::Permission);
        assert_eq!(code(statted), ErrorCode::Permission);
    }

    #[test]
    fn reading_refuses_folders_and_things_that_are_not_files() {
        let dir = tempfile::tempdir().expect("tempdir");
        fs::create_dir(dir.path().join("d")).expect("dir");
        let c = open_regular(&dir.path().join("d"), "d").expect_err("folder");
        assert_eq!(c.code, ErrorCode::NotAFile);
        let c = open_regular(Path::new("/dev/null"), "/dev/null").expect_err("device");
        assert_eq!(c.code, ErrorCode::NotAFile);
        let c = open_regular(&dir.path().join("none"), "none").expect_err("missing");
        assert_eq!(c.code, ErrorCode::NotFound);
    }

    #[test]
    fn a_fifo_is_refused_without_waiting_for_a_writer() {
        let dir = tempfile::tempdir().expect("tempdir");
        let fifo = dir.path().join("pipe");
        // `mkfifo` rather than `rustix::fs::mknodat`, which macOS does not have.
        let made = std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .expect("mkfifo runs");
        assert!(made.success(), "mkfifo");
        let c = open_regular(&fifo, "pipe").expect_err("fifo");
        assert_eq!(c.code, ErrorCode::NotAFile);
    }

    #[test]
    fn a_watched_path_is_reported_with_its_size_and_time_only_when_it_exists() {
        assert_eq!(
            change_msg("~/x", None),
            json!({"path": "~/x", "exists": false})
        );
        assert_eq!(
            change_msg("~/x", Some((3, 9))),
            json!({"path": "~/x", "exists": true, "size": 3, "mtime_ms": 9})
        );
    }
}
