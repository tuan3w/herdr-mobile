//! `fs` and `transfer` over a real `serve` session (an in-memory socket pair)
//! with a temporary home folder. The client grants credit like the app does,
//! and every wait has a timeout, so a bug fails a test instead of hanging it.

use host::svc::fs::FsService;
use host::svc::transfer::TransferService;
use host::{Registry, SessionOptions};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime};
use wire::{
    read_frame, write_frame, ClientHello, ClientInfo, ErrorCode, Flags, Frame, HerdrHello,
    Inflater, Kind, Limits, WireError, MAGIC,
};

const WAIT: Duration = Duration::from_secs(20);
const WINDOW: i64 = 1 << 20;

#[derive(Debug)]
enum Item {
    Msg(Value),
    Data(Vec<u8>),
    End(Value),
    Reset(Value),
}

struct Conn {
    out: UnixStream,
    frames: Receiver<Option<Frame>>,
    server: Option<JoinHandle<i32>>,
    next_stream: u32,
    send_credit: HashMap<u32, i64>,
    consumed: HashMap<u32, usize>,
    pending: HashMap<u32, VecDeque<Item>>,
}

fn options(home: &Path) -> SessionOptions {
    SessionOptions {
        host: wire::HostInfo {
            version: "9.9.9".into(),
            os: "linux".into(),
            arch: "x86_64".into(),
            home: home.to_string_lossy().into_owned(),
            hostname: "box".into(),
            user: "tester".into(),
        },
        home: home.to_path_buf(),
        limits: Limits::default(),
        stall: Duration::from_secs(60),
        exit_on_write_error: false,
    }
}

impl Conn {
    fn start(home: &Path) -> Self {
        let (client_end, server_end) = UnixStream::pair().expect("pair");
        let server_in = server_end.try_clone().expect("clone");
        let registry = Arc::new(Registry::new(vec![
            Arc::new(FsService::new()),
            Arc::new(TransferService::new()),
        ]));
        let opts = options(home);
        let server =
            std::thread::spawn(move || host::session::run(server_in, server_end, registry, opts));
        let mut reader = client_end.try_clone().expect("clone");
        let (tx, frames) = channel();
        std::thread::spawn(move || {
            let mut magic = [0u8; 14];
            if reader.read_exact(&mut magic).is_err() || &magic != MAGIC {
                let _ = tx.send(None);
                return;
            }
            while let Ok(Some(f)) = read_frame(&mut reader) {
                if tx.send(Some(f)).is_err() {
                    return;
                }
            }
            let _ = tx.send(None);
        });
        let mut conn = Self {
            out: client_end,
            frames,
            server: Some(server),
            next_stream: 1,
            send_credit: HashMap::new(),
            consumed: HashMap::new(),
            pending: HashMap::new(),
        };
        let hello = ClientHello {
            proto: 1,
            client: ClientInfo {
                name: "test".into(),
                version: "0".into(),
            },
            herdr: HerdrHello::default(),
        };
        write_frame(
            &mut conn.out,
            &Frame::json(Kind::Hello, 0, &serde_json::to_value(hello).expect("hello")),
        )
        .expect("send hello");
        match conn.frames.recv_timeout(WAIT) {
            Ok(Some(f)) if f.kind == Kind::Hello => {}
            other => panic!("no HELLO from the host: {other:?}"),
        }
        conn
    }

    fn open(&mut self, svc: &str, method: &str, args: &Value) -> u32 {
        let id = self.next_stream;
        self.next_stream += 2;
        self.send_credit.insert(id, WINDOW);
        write_frame(
            &mut self.out,
            &Frame::json(
                Kind::Open,
                id,
                &json!({"svc": svc, "method": method, "args": args, "zctx": false}),
            ),
        )
        .expect("send open");
        id
    }

    /// Takes one frame in, grants credit for what the host sent.
    fn pump(&mut self, wait: Duration) -> bool {
        let frame = match self.frames.recv_timeout(wait) {
            Ok(Some(f)) => f,
            Ok(None) | Err(RecvTimeoutError::Disconnected | RecvTimeoutError::Timeout) => {
                return false
            }
        };
        let stream = frame.stream;
        if frame.kind == Kind::Credit {
            let n = frame.credit_bytes().expect("credit");
            *self.send_credit.entry(stream).or_insert(0) += i64::from(n);
            return true;
        }
        let wire_len = frame.payload.len();
        let payload = match frame.flags {
            Flags::None => frame.payload,
            Flags::Deflate => Inflater::once(&frame.payload).expect("inflates"),
            Flags::DeflateCtx => panic!("these tests never open zctx streams"),
        };
        let item = match frame.kind {
            Kind::Msg => Item::Msg(serde_json::from_slice(&payload).expect("MSG is JSON")),
            Kind::Data => Item::Data(payload),
            Kind::End => Item::End(serde_json::from_slice(&payload).expect("END is JSON")),
            Kind::Reset => Item::Reset(serde_json::from_slice(&payload).expect("RESET is JSON")),
            _ => return true,
        };
        if matches!(item, Item::Msg(_) | Item::Data(_)) {
            let used = self.consumed.entry(stream).or_insert(0);
            *used += wire_len;
            if *used >= 256 * 1024 {
                let grant = u32::try_from(*used).expect("fits");
                *used = 0;
                let _ = write_frame(&mut self.out, &Frame::credit(stream, grant));
            }
        }
        self.pending.entry(stream).or_default().push_back(item);
        true
    }

    fn try_item(&mut self, stream: u32, wait: Duration) -> Option<Item> {
        loop {
            if let Some(item) = self.pending.get_mut(&stream).and_then(VecDeque::pop_front) {
                return Some(item);
            }
            if !self.pump(wait) {
                return None;
            }
        }
    }

    fn item(&mut self, stream: u32) -> Item {
        self.try_item(stream, WAIT)
            .unwrap_or_else(|| panic!("nothing arrived on stream {stream} in {WAIT:?}"))
    }

    fn msg(&mut self, stream: u32) -> Value {
        match self.item(stream) {
            Item::Msg(v) => v,
            other => panic!("expected a MSG on stream {stream}, got {other:?}"),
        }
    }

    /// The END of `stream` (the next item), as an error when it carries one.
    fn ended(&mut self, stream: u32) -> Result<Value, WireError> {
        match self.item(stream) {
            Item::End(v) => match WireError::from_end(&v) {
                Some(e) => Err(e),
                None => Ok(v),
            },
            other => panic!("expected END on stream {stream}, got {other:?}"),
        }
    }

    /// A call: OPEN, one MSG, END; or the error END.
    fn call(&mut self, svc: &str, method: &str, args: &Value) -> Result<Value, WireError> {
        let s = self.open(svc, method, args);
        match self.item(s) {
            Item::Msg(v) => {
                self.ended(s).expect("the call ends well after its result");
                Ok(v)
            }
            Item::End(v) => match WireError::from_end(&v) {
                Some(e) => Err(e),
                // A result carried by END itself.
                None => Ok(v),
            },
            other => panic!("unexpected {other:?}"),
        }
    }

    /// Every item of `stream` up to and including its END.
    fn drain(&mut self, stream: u32) -> (Vec<Value>, Vec<u8>, Result<Value, WireError>) {
        let (mut msgs, mut data) = (Vec::new(), Vec::new());
        loop {
            match self.item(stream) {
                Item::Msg(v) => msgs.push(v),
                Item::Data(d) => {
                    assert!(d.len() <= 32 * 1024, "DATA frames are at most 32 KiB");
                    data.extend(d);
                }
                Item::End(v) => {
                    let end = WireError::from_end(&v).map_or(Ok(v), Err);
                    return (msgs, data, end);
                }
                Item::Reset(v) => panic!("stream was reset: {v}"),
            }
        }
    }

    fn send_data(&mut self, stream: u32, bytes: &[u8]) {
        for chunk in bytes.chunks(32 * 1024) {
            while self.send_credit.get(&stream).copied().unwrap_or(0) < chunk.len() as i64 {
                assert!(
                    self.pump(WAIT),
                    "no credit arrived: the host stopped reading"
                );
            }
            *self.send_credit.entry(stream).or_insert(0) -= chunk.len() as i64;
            write_frame(
                &mut self.out,
                &Frame::new(Kind::Data, stream, chunk.to_vec()),
            )
            .expect("send data");
        }
    }

    fn end(&mut self, stream: u32) {
        write_frame(&mut self.out, &Frame::json(Kind::End, stream, &json!({}))).expect("send end");
    }

    fn reset(&mut self, stream: u32) {
        write_frame(
            &mut self.out,
            &Frame::json(
                Kind::Reset,
                stream,
                &json!({"code": "cancelled", "message": "test"}),
            ),
        )
        .expect("send reset");
    }

    /// Drops the connection the way a lost network does and waits for the
    /// host's session to finish, so the files are as the host left them.
    fn drop_link(mut self) {
        let _ = self.out.shutdown(std::net::Shutdown::Both);
        self.server
            .take()
            .expect("server")
            .join()
            .expect("session thread");
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        let _ = self.out.shutdown(std::net::Shutdown::Both);
        if let Some(server) = self.server.take() {
            let _ = server.join();
        }
    }
}

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Self {
        Self {
            dir: tempfile::tempdir().expect("home"),
        }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn conn(&self) -> Conn {
        Conn::start(self.path())
    }
}

fn pseudo_random(n: usize, seed: u64) -> Vec<u8> {
    let mut x = seed | 1;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 24) as u8
        })
        .collect()
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn set_mtime(path: &Path, at: SystemTime) {
    File::options()
        .write(true)
        .open(path)
        .expect("open")
        .set_modified(at)
        .expect("set mtime");
}

/// Waits until the host has written at least `len` bytes of `path`.
fn wait_for_len(path: &Path, len: u64) {
    let deadline = std::time::Instant::now() + WAIT;
    while fs::metadata(path).map_or(0, |m| m.len()) < len {
        assert!(
            std::time::Instant::now() < deadline,
            "the host never wrote {len} bytes of {path:?}"
        );
        std::thread::yield_now();
    }
}

fn is_root() -> bool {
    rustix::process::geteuid().is_root()
}

// ---------------------------------------------------------------- fs

#[test]
fn a_folder_of_1200_entries_arrives_in_three_messages() {
    let home = Home::new();
    let big = home.path().join("big");
    fs::create_dir(&big).expect("dir");
    for i in 0..1200 {
        fs::write(big.join(format!("file-{i:04}")), b"x").expect("file");
    }
    let mut c = home.conn();
    let s = c.open("fs", "list", &json!({"path": "~/big"}));
    let (msgs, data, end) = c.drain(s);
    assert!(data.is_empty());
    let sizes: Vec<usize> = msgs
        .iter()
        .map(|m| m["entries"].as_array().expect("entries").len())
        .collect();
    assert_eq!(sizes, [500, 500, 200]);
    assert_eq!(end.expect("ends well")["count"], 1200);
    let names: HashSet<String> = msgs
        .iter()
        .flat_map(|m| m["entries"].as_array().expect("entries").clone())
        .map(|e| e["name"].as_str().expect("name").to_string())
        .collect();
    assert_eq!(names.len(), 1200);
    assert!(names.contains("file-0000") && names.contains("file-1199"));
}

#[test]
fn list_entries_say_what_they_are_without_following_links() {
    let home = Home::new();
    let dir = home.path().join("d");
    fs::create_dir(&dir).expect("dir");
    fs::write(dir.join("f"), b"abcd").expect("file");
    fs::create_dir(dir.join("sub")).expect("sub");
    symlink(dir.join("sub"), dir.join("l")).expect("link");
    let mut c = home.conn();
    let s = c.open("fs", "list", &json!({"path": "~/d"}));
    let (msgs, _, end) = c.drain(s);
    end.expect("ends well");
    let entries = msgs[0]["entries"].as_array().expect("entries");
    let kind = |name: &str| {
        entries
            .iter()
            .find(|e| e["name"] == name)
            .unwrap_or_else(|| panic!("no entry {name}"))["kind"]
            .clone()
    };
    assert_eq!(entries.len(), 3);
    assert_eq!(kind("f"), "file");
    assert_eq!(kind("sub"), "dir");
    assert_eq!(kind("l"), "link");
}

#[test]
fn a_symlink_loop_does_not_hang_stat_or_list() {
    let home = Home::new();
    symlink(home.path().join("b"), home.path().join("a")).expect("a");
    symlink(home.path().join("a"), home.path().join("b")).expect("b");
    let mut c = home.conn();
    let e = c
        .call("fs", "stat", &json!({"path": "~/a"}))
        .expect_err("loop");
    assert_eq!(e.code, ErrorCode::Failed);
    let s = c.open("fs", "list", &json!({"path": "~/a"}));
    assert_eq!(c.ended(s).expect_err("loop").code, ErrorCode::Failed);
    let s = c.open("fs", "list", &json!({"path": "~"}));
    let (msgs, _, end) = c.drain(s);
    end.expect("the folder holding the loop lists fine");
    assert_eq!(msgs[0]["entries"].as_array().expect("entries").len(), 2);
}

#[test]
fn errors_name_the_path_as_the_client_sent_it_with_the_right_code() {
    let home = Home::new();
    fs::write(home.path().join("file"), b"x").expect("file");
    fs::create_dir(home.path().join("dir")).expect("dir");
    let mut c = home.conn();

    let e = c
        .call("fs", "stat", &json!({"path": "~/missing"}))
        .expect_err("missing");
    assert_eq!(e.code, ErrorCode::NotFound);
    assert!(e.message.contains("~/missing"), "{}", e.message);
    assert!(
        !e.message.contains(&*home.path().to_string_lossy()),
        "no host path the client did not send: {}",
        e.message
    );

    let s = c.open("fs", "list", &json!({"path": "~/file"}));
    assert_eq!(c.ended(s).expect_err("file").code, ErrorCode::NotADirectory);
    let s = c.open("fs", "list", &json!({"path": "~/missing"}));
    assert_eq!(c.ended(s).expect_err("missing").code, ErrorCode::NotFound);

    let s = c.open("fs", "read", &json!({"path": "~/dir", "length": 10}));
    assert_eq!(c.ended(s).expect_err("dir").code, ErrorCode::NotAFile);
    let s = c.open("fs", "read", &json!({"path": "~/missing", "length": 10}));
    assert_eq!(c.ended(s).expect_err("missing").code, ErrorCode::NotFound);
}

#[test]
fn a_folder_you_may_not_open_is_permission() {
    if is_root() {
        return;
    }
    let home = Home::new();
    let locked = home.path().join("locked");
    fs::create_dir(&locked).expect("dir");
    fs::write(locked.join("f"), b"x").expect("file");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");
    let mut c = home.conn();
    let listed = {
        let s = c.open("fs", "list", &json!({"path": "~/locked"}));
        c.ended(s)
    };
    let statted = c.call("fs", "stat", &json!({"path": "~/locked/f"}));
    let read = {
        let s = c.open("fs", "read", &json!({"path": "~/locked/f", "length": 1}));
        c.ended(s)
    };
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).expect("restore");
    assert_eq!(listed.expect_err("list").code, ErrorCode::Permission);
    assert_eq!(statted.expect_err("stat").code, ErrorCode::Permission);
    assert_eq!(read.expect_err("read").code, ErrorCode::Permission);
}

#[test]
fn tilde_expands_to_the_host_home_and_odd_paths_are_bad_requests() {
    let home = Home::new();
    let real_home = fs::canonicalize(home.path()).expect("canonical");
    fs::create_dir(real_home.join("sub")).expect("sub");
    fs::write(real_home.join("sub/x"), b"hello").expect("x");
    let mut c = Conn::start(&real_home);

    assert_eq!(
        c.call("fs", "stat", &json!({"path": "~/sub/x"}))
            .expect("stat")["size"],
        5
    );
    assert_eq!(
        c.call("fs", "stat", &json!({"path": "~"})).expect("home")["kind"],
        "dir"
    );
    assert_eq!(
        c.call("fs", "real_path", &json!({"path": "~"}))
            .expect("real")["path"],
        real_home.to_string_lossy().as_ref()
    );
    assert_eq!(
        c.call("fs", "real_path", &json!({"path": "~/sub/../sub/x"}))
            .expect("real")["path"],
        real_home.join("sub/x").to_string_lossy().as_ref()
    );
    let abs = real_home.join("sub/x").to_string_lossy().into_owned();
    assert_eq!(
        c.call("fs", "stat", &json!({"path": abs})).expect("abs")["size"],
        5
    );

    for bad in ["sub/x", "", "~other/x", "~/a\u{0}b", "/a\u{0}"] {
        let e = c.call("fs", "stat", &json!({"path": bad})).expect_err(bad);
        assert_eq!(e.code, ErrorCode::BadRequest, "{bad:?}");
    }
    let e = c.call("fs", "stat", &json!({})).expect_err("no path");
    assert_eq!(e.code, ErrorCode::BadRequest);
}

#[test]
fn stat_reports_kind_size_time_and_mode() {
    let home = Home::new();
    let file = home.path().join("f");
    fs::write(&file, b"12345").expect("file");
    fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).expect("chmod");
    let at = SystemTime::UNIX_EPOCH + Duration::from_millis(1_700_000_123_456);
    set_mtime(&file, at);
    symlink(&file, home.path().join("link")).expect("link");
    let mut c = home.conn();
    let s = c
        .call("fs", "stat", &json!({"path": "~/link"}))
        .expect("stat");
    assert_eq!(
        s,
        json!({"kind": "file", "size": 5, "mtime_ms": 1_700_000_123_456_i64, "mode": 0o640})
    );
}

fn read_args(path: &str, offset: u64, length: u64) -> Value {
    json!({"path": path, "offset": offset, "length": length})
}

#[test]
fn read_ranges_report_eof_when_fewer_bytes_than_asked_were_there() {
    let home = Home::new();
    let content = pseudo_random(100, 7);
    fs::write(home.path().join("f"), &content).expect("file");
    let mut c = home.conn();
    let mut read = |offset: u64, length: u64| {
        let s = c.open("fs", "read", &read_args("~/f", offset, length));
        let (msgs, data, end) = c.drain(s);
        assert_eq!(msgs.len(), 1, "one MSG with the identity, then DATA");
        assert_eq!(msgs[0]["size"], 100);
        (data, end.expect("ends well")["eof"].as_bool().expect("eof"))
    };
    assert_eq!(read(10, 20), (content[10..30].to_vec(), false));
    assert_eq!(
        read(0, 100),
        (content.clone(), false),
        "exactly the length: not eof"
    );
    assert_eq!(read(0, 101), (content.clone(), true));
    assert_eq!(read(90, 50), (content[90..].to_vec(), true));
    assert_eq!(read(100, 5), (Vec::new(), true), "offset at the end");
    assert_eq!(read(5000, 5), (Vec::new(), true), "offset past the end");
    assert_eq!(read(0, 0), (Vec::new(), false));
}

#[test]
fn a_read_of_over_64_mib_is_too_large_and_a_missing_length_is_a_bad_request() {
    let home = Home::new();
    fs::write(home.path().join("f"), b"x").expect("file");
    let mut c = home.conn();
    let s = c.open("fs", "read", &read_args("~/f", 0, 64 * 1024 * 1024 + 1));
    assert_eq!(c.ended(s).expect_err("big").code, ErrorCode::TooLarge);
    let s = c.open("fs", "read", &read_args("~/f", 0, 64 * 1024 * 1024));
    let (_, data, end) = c.drain(s);
    assert_eq!(data, b"x");
    end.expect("exactly 64 MiB is allowed");
    let s = c.open("fs", "read", &json!({"path": "~/f"}));
    assert_eq!(
        c.ended(s).expect_err("no length").code,
        ErrorCode::BadRequest
    );
}

#[test]
fn if_match_stops_a_read_of_a_file_that_changed_before_any_data() {
    let home = Home::new();
    let file = home.path().join("f");
    fs::write(&file, b"first version").expect("file");
    let mut c = home.conn();

    let s = c.open("fs", "read", &read_args("~/f", 0, 100));
    let (msgs, data, end) = c.drain(s);
    end.expect("first read");
    assert_eq!(data, b"first version");
    let identity = json!({"size": msgs[0]["size"], "mtime_ms": msgs[0]["mtime_ms"]});

    let same = |c: &mut Conn| {
        let mut args = read_args("~/f", 0, 100);
        args["if_match"] = identity.clone();
        let s = c.open("fs", "read", &args);
        c.drain(s)
    };
    let (msgs, data, end) = same(&mut c);
    assert_eq!(
        (msgs.len(), data.as_slice()),
        (1, b"first version".as_slice())
    );
    end.expect("unchanged file reads");

    // Same size, different time.
    set_mtime(
        &file,
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000),
    );
    let (msgs, data, end) = same(&mut c);
    assert!(
        msgs.is_empty() && data.is_empty(),
        "nothing before the error"
    );
    assert_eq!(end.expect_err("changed").code, ErrorCode::Changed);

    // Different size.
    fs::write(&file, b"second, longer version").expect("rewrite");
    let (msgs, data, end) = same(&mut c);
    assert!(msgs.is_empty() && data.is_empty());
    assert_eq!(end.expect_err("changed").code, ErrorCode::Changed);
}

#[test]
fn a_3_mb_file_streams_whole_and_matches_its_sha256() {
    let home = Home::new();
    let content = pseudo_random(3 * 1024 * 1024 + 123, 42);
    fs::write(home.path().join("big.bin"), &content).expect("file");
    let mut c = home.conn();
    let s = c.open("fs", "read", &read_args("~/big.bin", 0, 64 * 1024 * 1024));
    let (msgs, data, end) = c.drain(s);
    assert_eq!(msgs[0]["size"], content.len());
    assert_eq!(end.expect("ends well")["eof"], true);
    assert_eq!(data.len(), content.len());
    assert_eq!(sha256_hex(&data), sha256_hex(&content));

    // The same bytes in two ranges, as a resumed download asks for them.
    let half = 1_500_000u64;
    let s = c.open("fs", "read", &read_args("~/big.bin", 0, half));
    let (_, first, _) = c.drain(s);
    let s = c.open(
        "fs",
        "read",
        &read_args("~/big.bin", half, 64 * 1024 * 1024),
    );
    let (_, rest, end) = c.drain(s);
    assert_eq!(end.expect("ends well")["eof"], true);
    assert_eq!(sha256_hex(&[first, rest].concat()), sha256_hex(&content));
}

#[test]
fn watch_reports_every_path_at_once_then_changes_and_stops_on_reset() {
    let home = Home::new();
    let file = home.path().join("watched");
    fs::write(&file, b"one").expect("file");
    let mut c = home.conn();
    let s = c.open(
        "fs",
        "watch",
        &json!({"paths": ["~/watched", "~/later"], "interval_ms": 500}),
    );
    let first = c.msg(s);
    assert_eq!(
        (
            first["path"].clone(),
            first["exists"].clone(),
            first["size"].clone()
        ),
        (json!("~/watched"), json!(true), json!(3))
    );
    assert!(first["mtime_ms"].is_i64());
    let second = c.msg(s);
    assert_eq!(second, json!({"path": "~/later", "exists": false}));

    fs::write(&file, b"three!").expect("modify");
    let changed = c.msg(s);
    assert_eq!(
        (changed["path"].clone(), changed["size"].clone()),
        (json!("~/watched"), json!(6))
    );

    fs::write(home.path().join("later"), b"hi").expect("create");
    let created = c.msg(s);
    assert_eq!(created["path"], "~/later");
    assert_eq!(created["exists"], true);

    fs::remove_file(&file).expect("remove");
    assert_eq!(c.msg(s), json!({"path": "~/watched", "exists": false}));

    c.reset(s);
    // Two polls later nothing more arrives for the reset stream, and the
    // session still answers.
    fs::write(&file, b"back").expect("recreate");
    assert!(
        c.try_item(s, Duration::from_millis(1300)).is_none(),
        "a reset watch stays quiet"
    );
    assert!(c.call("fs", "stat", &json!({"path": "~/watched"})).is_ok());
}

#[test]
fn watch_refuses_too_many_paths_and_a_fast_interval() {
    let home = Home::new();
    let mut c = home.conn();
    let paths: Vec<String> = (0..33).map(|i| format!("~/p{i}")).collect();
    let s = c.open("fs", "watch", &json!({"paths": paths, "interval_ms": 1000}));
    assert_eq!(
        c.ended(s).expect_err("33 paths").code,
        ErrorCode::BadRequest
    );
    let s = c.open(
        "fs",
        "watch",
        &json!({"paths": ["~/x"], "interval_ms": 100}),
    );
    assert_eq!(c.ended(s).expect_err("fast").code, ErrorCode::BadRequest);
    let s = c.open("fs", "watch", &json!({"paths": [], "interval_ms": 1000}));
    assert_eq!(c.ended(s).expect_err("none").code, ErrorCode::BadRequest);
    let s = c.open(
        "fs",
        "watch",
        &json!({"paths": ["relative"], "interval_ms": 1000}),
    );
    assert_eq!(
        c.ended(s).expect_err("relative").code,
        ErrorCode::BadRequest
    );
}

// ---------------------------------------------------------------- transfer

fn inbox(home: &Path) -> PathBuf {
    home.join(".herdr-mobile/inbox")
}

fn reserve(c: &mut Conn, key: &str, name: &str) -> String {
    c.call("transfer", "reserve", &json!({"key": key, "name": name}))
        .expect("reserve")["path"]
        .as_str()
        .expect("path")
        .to_string()
}

fn put_args(path: &str, content: &[u8]) -> Value {
    json!({"path": path, "size": content.len(), "sha256": sha256_hex(content)})
}

fn mode_of(p: &Path) -> u32 {
    fs::metadata(p).expect("metadata").permissions().mode() & 0o7777
}

#[test]
fn reserve_names_the_file_in_the_inbox_by_utc_time_and_the_key_hash() {
    let home = Home::new();
    let mut c = home.conn();
    let path = reserve(&mut c, "abc", "Bản vẽ (v2).dwg");
    let rest = path
        .strip_prefix(&format!("{}/", inbox(home.path()).display()))
        .expect("under the inbox");
    let (folder, leaf) = rest.split_once('/').expect("folder and file");
    assert_eq!(folder, "a9993e364706", "first 12 hex of sha1(\"abc\")");
    let bytes = leaf.as_bytes();
    assert!(bytes[..8].iter().all(u8::is_ascii_digit), "{leaf}");
    assert_eq!(bytes[8], b'-');
    assert!(bytes[9..15].iter().all(u8::is_ascii_digit), "{leaf}");
    assert_eq!(&leaf[15..], "-Bản_vẽ__v2_.dwg");
    assert_eq!(mode_of(&inbox(home.path())), 0o700);
    assert_eq!(mode_of(&inbox(home.path()).join(folder)), 0o700);
    assert_eq!(mode_of(&home.path().join(".herdr-mobile")), 0o700);
    assert!(
        !Path::new(&path).exists(),
        "reserving does not create the file"
    );

    let hostile = reserve(&mut c, "abc", "../../.ssh/authorized_keys");
    assert!(hostile.ends_with("-authorized_keys"));
    assert_eq!(Path::new(&hostile).parent(), Path::new(&path).parent());
}

#[test]
fn a_5_mb_upload_lands_with_the_right_bytes_and_mode_0600() {
    let home = Home::new();
    let content = pseudo_random(5 * 1024 * 1024 + 17, 99);
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "photo.bin");
    let s = c.open("transfer", "put", &put_args(&path, &content));
    assert_eq!(c.msg(s), json!({"have": 0}));
    c.send_data(s, &content);
    c.end(s);
    let end = c.ended(s).expect("upload ends well");
    assert_eq!(end, json!({"path": path, "size": content.len()}));

    let final_path = Path::new(&path);
    assert_eq!(
        sha256_hex(&fs::read(final_path).expect("final")),
        sha256_hex(&content)
    );
    assert_eq!(mode_of(final_path), 0o600);
    let leftovers: Vec<_> = fs::read_dir(final_path.parent().expect("dir"))
        .expect("list")
        .map(|e| e.expect("entry").file_name())
        .collect();
    assert_eq!(leftovers.len(), 1, "no .part or .meta left: {leftovers:?}");
}

#[test]
fn an_upload_replaces_an_existing_file_of_that_name() {
    let home = Home::new();
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "a.txt");
    for content in [b"first".as_slice(), b"second, longer".as_slice()] {
        let s = c.open("transfer", "put", &put_args(&path, content));
        assert_eq!(c.msg(s)["have"], 0);
        c.send_data(s, content);
        c.end(s);
        c.ended(s).expect("ends well");
        assert_eq!(fs::read(&path).expect("final"), content);
    }
}

#[test]
fn an_upload_cut_off_after_2_mb_resumes_from_what_the_host_kept() {
    let home = Home::new();
    let content = pseudo_random(5 * 1024 * 1024, 1234);
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "big.bin");
    let args = put_args(&path, &content);

    let s = c.open("transfer", "put", &args);
    assert_eq!(c.msg(s)["have"], 0);
    let sent = 2 * 1024 * 1024;
    c.send_data(s, &content[..sent]);
    let part = PathBuf::from(format!("{path}.part"));
    wait_for_len(&part, 1024 * 1024);
    c.drop_link();

    let kept = fs::metadata(&part).expect("the partial file stays").len();
    assert!(kept >= 1024 * 1024 && kept <= sent as u64, "kept {kept}");
    assert!(!Path::new(&path).exists());
    assert_eq!(mode_of(&part), 0o600);

    let mut c = home.conn();
    let (s, have) = put_again(&mut c, &args);
    assert!(
        have >= kept && have <= sent as u64,
        "have {have}, kept {kept}"
    );
    assert_eq!(
        fs::metadata(&part).expect("part").len(),
        have,
        "the host resumes exactly where its file ends"
    );
    c.send_data(s, &content[usize::try_from(have).expect("fits")..]);
    c.end(s);
    c.ended(s).expect("resumed upload ends well");

    assert_eq!(
        sha256_hex(&fs::read(&path).expect("final")),
        sha256_hex(&content)
    );
    assert_eq!(mode_of(Path::new(&path)), 0o600);
    assert!(!part.exists());
    assert!(!Path::new(&format!("{path}.meta")).exists());
}

#[test]
fn a_upload_that_was_complete_but_never_ended_finishes_on_the_next_try() {
    let home = Home::new();
    let content = pseudo_random(300_000, 5);
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "all.bin");
    let args = put_args(&path, &content);
    let s = c.open("transfer", "put", &args);
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &content);
    // Wait until the host has written it all: it grants credit as it reads,
    // and the file on disk is the proof.
    wait_for_len(&PathBuf::from(format!("{path}.part")), content.len() as u64);
    c.drop_link();

    let mut c = home.conn();
    let (s, have) = put_again(&mut c, &args);
    assert_eq!(have, content.len() as u64);
    c.end(s);
    c.ended(s)
        .expect("verified and renamed without a byte more");
    assert_eq!(fs::read(&path).expect("final"), content);
}

#[test]
fn a_partial_file_of_another_upload_is_not_resumed() {
    let home = Home::new();
    let first = pseudo_random(1_000_000, 1);
    let second = pseudo_random(1_000_000, 2); // same size, other content
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "x.bin");

    let s = c.open("transfer", "put", &put_args(&path, &first));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &first[..600_000]);
    wait_for_len(&PathBuf::from(format!("{path}.part")), 400_000);
    c.drop_link();

    let mut c = home.conn();
    let (s, have) = put_again(&mut c, &put_args(&path, &second));
    assert_eq!(have, 0, "another digest starts over");
    c.send_data(s, &second);
    c.end(s);
    c.ended(s).expect("ends well");
    assert_eq!(fs::read(&path).expect("final"), second);
}

/// Opens `put` on a fresh connection after the old one was dropped. The old
/// session's handler may still be winding down in this process, in which case
/// the host says `busy` (retryable): try again until it has let go.
fn put_again(c: &mut Conn, args: &Value) -> (u32, u64) {
    let deadline = std::time::Instant::now() + WAIT;
    loop {
        let s = c.open("transfer", "put", args);
        match c.item(s) {
            Item::Msg(v) => return (s, v["have"].as_u64().expect("have")),
            Item::End(v) => {
                let e = WireError::from_end(&v).expect("only an error ends before the first MSG");
                assert_eq!(e.code, ErrorCode::Busy, "{e:?}");
                assert!(
                    std::time::Instant::now() < deadline,
                    "the old handler never let go"
                );
                std::thread::yield_now();
            }
            other => panic!("unexpected {other:?}"),
        }
    }
}

fn assert_nothing_left(path: &str) {
    assert!(!Path::new(path).exists(), "no final file");
    assert!(!Path::new(&format!("{path}.part")).exists(), "no .part");
    assert!(!Path::new(&format!("{path}.meta")).exists(), "no .meta");
}

#[test]
fn a_corrupted_tail_is_changed_and_leaves_no_file() {
    let home = Home::new();
    let content = pseudo_random(2 * 1024 * 1024, 77);
    let mut bad = content.clone();
    *bad.last_mut().expect("bytes") ^= 0xFF;
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "corrupt.bin");
    let s = c.open("transfer", "put", &put_args(&path, &content));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &bad);
    c.end(s);
    assert_eq!(c.ended(s).expect_err("mismatch").code, ErrorCode::Changed);
    assert_nothing_left(&path);

    // A fresh try after the failure starts from nothing and can succeed.
    let s = c.open("transfer", "put", &put_args(&path, &content));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &content);
    c.end(s);
    c.ended(s).expect("a clean retry works");
}

#[test]
fn an_upload_with_too_few_or_too_many_bytes_is_changed_and_leaves_no_file() {
    let home = Home::new();
    let content = pseudo_random(100_000, 3);
    let mut c = home.conn();

    let short = reserve(&mut c, "k", "short.bin");
    let s = c.open("transfer", "put", &put_args(&short, &content));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &content[..60_000]);
    c.end(s);
    assert_eq!(c.ended(s).expect_err("short").code, ErrorCode::Changed);
    assert_nothing_left(&short);

    let long = reserve(&mut c, "k", "long.bin");
    let s = c.open("transfer", "put", &put_args(&long, &content));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &[content.clone(), vec![0u8; 10]].concat());
    c.end(s);
    assert_eq!(c.ended(s).expect_err("long").code, ErrorCode::Changed);
    assert_nothing_left(&long);
}

#[test]
fn put_refuses_paths_that_are_not_reserved_inbox_paths_and_touches_nothing() {
    let home = Home::new();
    let other_home = Home::new();
    let mut c = home.conn();
    let good = reserve(&mut c, "k", "ok.txt");
    let good_path = Path::new(&good);
    let folder = good_path.parent().expect("folder").to_path_buf();
    let leaf = good_path
        .file_name()
        .and_then(|l| l.to_str())
        .expect("leaf")
        .to_string();
    let content = b"payload";
    let outside = tempfile::tempdir().expect("outside");

    let escape = format!("{}/../{leaf}", folder.display());
    let deep_escape = format!("{}/../../../escaped.txt", folder.display());
    let sub = format!("{}/sub/{leaf}", folder.display());
    let foreign = format!(
        "{}/.herdr-mobile/inbox/a9993e364706/{leaf}",
        other_home.path().display()
    );
    let bad = [
        escape,
        deep_escape,
        sub,
        foreign,
        format!("{}/not-stamped.txt", folder.display()),
        format!("{}/{leaf}.part", folder.display()),
        format!("{}/20261005-090807-.hidden", folder.display()),
        format!("{}/escaped.txt", outside.path().display()),
        "/etc/passwd".to_string(),
        "~/.herdr-mobile/inbox/a9993e364706/20261005-090807-x".to_string(),
        format!("{}\0", good),
        format!(
            "{}/.herdr-mobile/keepers/20261005-090807-x",
            home.path().display()
        ),
        format!(
            "{}/.herdr-mobile/inbox/short/20261005-090807-x",
            home.path().display()
        ),
    ];
    for path in &bad {
        let s = c.open("transfer", "put", &put_args(path, content));
        let e = c.ended(s).expect_err(path);
        assert_eq!(e.code, ErrorCode::BadRequest, "{path:?}");
    }
    assert_eq!(fs::read_dir(outside.path()).expect("list").count(), 0);
    assert_eq!(fs::read_dir(other_home.path()).expect("list").count(), 0);
    assert!(!home.path().join("escaped.txt").exists());
    assert!(!home
        .path()
        .parent()
        .expect("parent")
        .join("escaped.txt")
        .exists());
    assert_eq!(
        fs::read_dir(&folder).expect("list").count(),
        0,
        "nothing was created in the folder"
    );
}

#[test]
fn put_refuses_an_inbox_reached_through_a_link() {
    let home = Home::new();
    let outside = tempfile::tempdir().expect("outside");
    let mut c = home.conn();
    let good = reserve(&mut c, "k", "ok.txt");
    let folder = Path::new(&good).parent().expect("folder").to_path_buf();
    let leaf = Path::new(&good)
        .file_name()
        .and_then(|l| l.to_str())
        .expect("leaf")
        .to_string();
    // The session folder becomes a link to a folder outside the inbox.
    fs::remove_dir(&folder).expect("remove folder");
    symlink(outside.path(), &folder).expect("link");

    let s = c.open("transfer", "put", &put_args(&good, b"data"));
    assert_eq!(
        c.ended(s).expect_err("linked folder").code,
        ErrorCode::BadRequest
    );
    assert_eq!(fs::read_dir(outside.path()).expect("list").count(), 0);
    let e = c
        .call("transfer", "reserve", &json!({"key": "k", "name": &leaf}))
        .expect_err("reserve through a link");
    assert_eq!(e.code, ErrorCode::BadRequest);
}

/// An upload cut off halfway, resumed on a new connection, then a sweep, in
/// a home whose inbox lives at `real_inbox` behind a link the user made.
fn linked_inbox_round_trip(home: &Home, real_inbox: &Path) {
    let content = pseudo_random(3 * 1024 * 1024, 7);
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "big.bin");
    assert!(
        path.starts_with(&format!("{}/", inbox(home.path()).display())),
        "the app is handed a path under its home: {path}"
    );
    let folder = Path::new(&path).parent().expect("folder");
    let real_folder = real_inbox.join(folder.file_name().expect("folder name"));
    assert!(
        real_folder.is_dir(),
        "the folders were made behind the link"
    );
    let args = put_args(&path, &content);

    let s = c.open("transfer", "put", &args);
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, &content[..1024 * 1024]);
    wait_for_len(&PathBuf::from(format!("{path}.part")), 512 * 1024);
    c.drop_link();

    let mut c = home.conn();
    let (s, have) = put_again(&mut c, &args);
    assert!(have >= 512 * 1024, "resumed from {have}");
    c.send_data(s, &content[usize::try_from(have).expect("fits")..]);
    c.end(s);
    c.ended(s).expect("the resumed upload ends well");
    let leaf = Path::new(&path).file_name().expect("leaf");
    let landed = real_folder.join(leaf);
    assert_eq!(
        sha256_hex(&fs::read(&landed).expect("landed behind the link")),
        sha256_hex(&content)
    );
    assert_eq!(mode_of(&landed), 0o600);

    // The real path is accepted too (it is the same inbox).
    let real_path = real_folder
        .canonicalize()
        .expect("canonical")
        .join(leaf)
        .to_string_lossy()
        .into_owned();
    let again = b"second";
    let s = c.open("transfer", "put", &put_args(&real_path, again));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, again);
    c.end(s);
    c.ended(s).expect("the canonical path is the same inbox");
    assert_eq!(fs::read(&landed).expect("replaced"), again);

    // The sweep reaches the files behind the link as well.
    let old = real_folder.join("old-file");
    fs::write(&old, b"x").expect("old");
    set_mtime(&old, SystemTime::now() - Duration::from_secs(30 * 86_400));
    let r = c
        .call("transfer", "sweep", &json!({}))
        .expect("sweep through the link");
    assert_eq!(r, json!({"removed": 1}));
    assert!(!old.exists());
    assert!(landed.exists(), "a fresh file stays");
}

#[test]
fn uploads_and_sweeps_work_when_the_state_folder_is_a_link() {
    let home = Home::new();
    let store = tempfile::tempdir().expect("store");
    let real = store.path().join("herdr-mobile");
    fs::create_dir(&real).expect("real");
    symlink(&real, home.path().join(".herdr-mobile")).expect("link");
    linked_inbox_round_trip(&home, &real.join("inbox"));
}

#[test]
fn uploads_and_sweeps_work_when_the_inbox_is_a_link() {
    let home = Home::new();
    let store = tempfile::tempdir().expect("store");
    let real = store.path().join("inbox-on-the-data-disk");
    fs::create_dir(&real).expect("real");
    fs::create_dir(home.path().join(".herdr-mobile")).expect("state");
    symlink(&real, inbox(home.path())).expect("link");
    linked_inbox_round_trip(&home, &real);
}

#[test]
fn a_link_at_the_session_folder_is_refused_even_behind_a_linked_inbox() {
    let home = Home::new();
    let store = tempfile::tempdir().expect("store");
    let outside = tempfile::tempdir().expect("outside");
    let real = store.path().join("inbox");
    fs::create_dir(&real).expect("real");
    fs::create_dir(home.path().join(".herdr-mobile")).expect("state");
    symlink(&real, inbox(home.path())).expect("link");
    let mut c = home.conn();
    let good = reserve(&mut c, "k", "ok.txt");
    let folder = real.join(
        Path::new(&good)
            .parent()
            .and_then(Path::file_name)
            .expect("name"),
    );
    fs::remove_dir(&folder).expect("remove folder");
    symlink(outside.path(), &folder).expect("link");

    let s = c.open("transfer", "put", &put_args(&good, b"data"));
    assert_eq!(
        c.ended(s).expect_err("linked folder").code,
        ErrorCode::BadRequest
    );
    assert_eq!(fs::read_dir(outside.path()).expect("list").count(), 0);
}

#[test]
fn put_refuses_a_link_planted_as_the_final_name() {
    let home = Home::new();
    let outside = tempfile::tempdir().expect("outside");
    let decoy = outside.path().join("decoy");
    fs::write(&decoy, b"precious").expect("decoy");
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "x.bin");
    symlink(&decoy, &path).expect("planted link");
    let s = c.open("transfer", "put", &put_args(&path, b"new content"));
    assert_eq!(
        c.ended(s).expect_err("a link as the target").code,
        ErrorCode::BadRequest
    );
    assert_eq!(fs::read(&decoy).expect("decoy"), b"precious");
    assert!(fs::symlink_metadata(&path)
        .expect("still there")
        .file_type()
        .is_symlink());
}

/// `put` keeps `.part` and `.meta` leaves for its own companions, so a
/// reserved name must never end that way: `weights.ckpt.meta` is an ordinary
/// attachment and used to fail every upload.
#[test]
fn attachments_named_like_the_upload_companions_reserve_and_upload() {
    let home = Home::new();
    let mut c = home.conn();
    for name in ["x.meta", "weights.ckpt.meta", "y.part", "archive.tar.part"] {
        let path = reserve(&mut c, "k", name);
        let content = name.as_bytes();
        let s = c.open("transfer", "put", &put_args(&path, content));
        assert_eq!(c.msg(s)["have"], 0, "{name}");
        c.send_data(s, content);
        c.end(s);
        c.ended(s).unwrap_or_else(|e| panic!("{name}: {e:?}"));
        assert_eq!(fs::read(&path).expect("final"), content, "{name}");
    }
}

#[test]
fn put_never_writes_through_a_link_planted_as_the_partial_file() {
    let home = Home::new();
    let outside = tempfile::tempdir().expect("outside");
    let decoy = outside.path().join("decoy");
    fs::write(&decoy, b"precious").expect("decoy");
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "x.bin");
    symlink(&decoy, format!("{path}.part")).expect("planted link");
    let content = b"new content";
    let s = c.open("transfer", "put", &put_args(&path, content));
    assert_eq!(c.msg(s)["have"], 0);
    c.send_data(s, content);
    c.end(s);
    c.ended(s).expect("ends well");
    assert_eq!(fs::read(&decoy).expect("decoy"), b"precious");
    assert_eq!(fs::read(&path).expect("final"), content);
}

#[test]
fn put_checks_its_arguments_before_creating_anything() {
    let home = Home::new();
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "x.bin");
    let too_big =
        json!({"path": path, "size": 2u64 * 1024 * 1024 * 1024 + 1, "sha256": "ab".repeat(32)});
    let s = c.open("transfer", "put", &too_big);
    assert_eq!(c.ended(s).expect_err("2 GiB + 1").code, ErrorCode::TooLarge);
    for sha in ["", "xyz", &"g".repeat(64), &"a".repeat(63)] {
        let s = c.open(
            "transfer",
            "put",
            &json!({"path": path, "size": 1, "sha256": sha}),
        );
        assert_eq!(
            c.ended(s).expect_err(sha).code,
            ErrorCode::BadRequest,
            "{sha:?}"
        );
    }
    let s = c.open("transfer", "put", &json!({"path": path, "size": 1}));
    assert_eq!(c.ended(s).expect_err("no sha").code, ErrorCode::BadRequest);
    assert_nothing_left(&path);
}

#[test]
fn a_second_upload_of_the_same_target_while_one_runs_is_busy() {
    let home = Home::new();
    let content = pseudo_random(10_000, 8);
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "x.bin");
    let first = c.open("transfer", "put", &put_args(&path, &content));
    assert_eq!(c.msg(first)["have"], 0);
    let second = c.open("transfer", "put", &put_args(&path, &content));
    let e = c.ended(second).expect_err("busy");
    assert_eq!(e.code, ErrorCode::Busy);
    assert!(e.retryable);
    c.send_data(first, &content);
    c.end(first);
    c.ended(first).expect("the first upload is unharmed");
    assert_eq!(fs::read(&path).expect("final"), content);
}

#[test]
fn sweep_removes_old_inbox_files_and_never_touches_anything_outside() {
    let home = Home::new();
    let day = Duration::from_secs(86_400);
    let now = SystemTime::now();
    let folder = inbox(home.path()).join("aaaaaaaaaaaa");
    fs::create_dir_all(&folder).expect("folder");
    let plant = |path: &Path, age: Duration| {
        fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
        fs::write(path, b"x").expect("file");
        set_mtime(path, now - age);
    };
    plant(&folder.join("old-20d"), day * 20);
    plant(&folder.join("old-15d"), day * 15);
    plant(&folder.join("new-3d"), day * 3);
    plant(&folder.join("20260101-000000-x.bin.part"), day * 2);
    plant(&folder.join("20260101-000000-x.bin.meta"), day * 2);
    plant(
        &inbox(home.path()).join("bbbbbbbbbbbb/old-only-file"),
        day * 40,
    );
    // Not ours to remove.
    let outside = tempfile::tempdir().expect("outside");
    let decoy = outside.path().join("decoy");
    plant(&decoy, day * 90);
    symlink(&decoy, folder.join("old-link")).expect("link inside the inbox");
    symlink(outside.path(), inbox(home.path()).join("cccccccccccc")).expect("linked folder");
    plant(&home.path().join("notes.txt"), day * 90);
    plant(&home.path().join(".herdr-mobile/keepers/state"), day * 90);
    plant(&inbox(home.path()).join("not-a-hash/old"), day * 90);
    plant(&inbox(home.path()).join("top-level-old"), day * 90);

    let mut c = home.conn();
    let r = c
        .call(
            "transfer",
            "sweep",
            &json!({"max_age_days": 14, "max_files": 200}),
        )
        .expect("sweep");
    assert_eq!(r, json!({"removed": 5}));

    assert!(!folder.join("old-20d").exists() && !folder.join("old-15d").exists());
    assert!(!folder.join("20260101-000000-x.bin.part").exists());
    assert!(!folder.join("20260101-000000-x.bin.meta").exists());
    assert!(
        !inbox(home.path()).join("bbbbbbbbbbbb").exists(),
        "an emptied folder goes"
    );
    assert!(folder.join("new-3d").exists());
    assert_eq!(fs::read(&decoy).expect("decoy"), b"x");
    assert!(fs::symlink_metadata(folder.join("old-link")).is_ok());
    assert!(fs::symlink_metadata(inbox(home.path()).join("cccccccccccc")).is_ok());
    for kept in [
        home.path().join("notes.txt"),
        home.path().join(".herdr-mobile/keepers/state"),
        inbox(home.path()).join("not-a-hash/old"),
        inbox(home.path()).join("top-level-old"),
    ] {
        assert!(kept.exists(), "{kept:?} must stay");
    }

    // The defaults are 14 days and 200 files; a cap is a cap.
    plant(&folder.join("older-a"), day * 30);
    plant(&folder.join("older-b"), day * 31);
    plant(&folder.join("older-c"), day * 32);
    let r = c
        .call("transfer", "sweep", &json!({"max_files": 2}))
        .expect("capped sweep");
    assert_eq!(r, json!({"removed": 2}));
    assert!(
        folder.join("older-a").exists(),
        "oldest first: the two oldest went"
    );
    let r = c
        .call("transfer", "sweep", &json!({}))
        .expect("default sweep");
    assert_eq!(r, json!({"removed": 1}));
}

#[test]
fn sweep_with_no_inbox_is_nothing_and_not_an_error() {
    let home = Home::new();
    let mut c = home.conn();
    assert_eq!(
        c.call("transfer", "sweep", &json!({})).expect("sweep"),
        json!({"removed": 0})
    );
    assert!(
        !home.path().join(".herdr-mobile").exists(),
        "a sweep creates nothing"
    );
}

#[test]
fn files_written_through_the_inbox_are_owned_by_the_user_alone() {
    let home = Home::new();
    let mut c = home.conn();
    let path = reserve(&mut c, "k", "private.txt");
    let s = c.open("transfer", "put", &put_args(&path, b"secret"));
    c.msg(s);
    c.send_data(s, b"secret");
    c.end(s);
    c.ended(s).expect("ends well");
    let meta = fs::metadata(&path).expect("final");
    assert_eq!(meta.mode() & 0o077, 0, "no group or other access");
}

// ---------------------------------------------------------------- thumb

fn gradient_rgb(w: u32, h: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            v.extend([(x * 255 / w) as u8, (y * 255 / h) as u8, 128]);
        }
    }
    v
}

fn jpeg_bytes(w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, 85)
        .encode(
            &gradient_rgb(w, h),
            w as u16,
            h as u16,
            jpeg_encoder::ColorType::Rgb,
        )
        .expect("encode");
    out
}

fn png_bytes(w: u32, h: u32, noise: bool) -> Vec<u8> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, w, h);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().expect("header");
    let data = if noise {
        pseudo_random((w * h * 3) as usize, 7)
    } else {
        gradient_rgb(w, h)
    };
    writer.write_image_data(&data).expect("data");
    writer.finish().expect("end");
    out
}

fn webp_bytes(w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    image_webp::WebPEncoder::new(&mut out)
        .encode(&gradient_rgb(w, h), w, h, image_webp::ColorType::Rgb8)
        .expect("webp");
    out
}

/// Opens `fs.thumb`, reads it whole: (first MSG, JPEG bytes) or the END error.
fn thumb(c: &mut Conn, args: &Value) -> Result<(Value, Vec<u8>), WireError> {
    let s = c.open("fs", "thumb", args);
    let (msgs, data, end) = c.drain(s);
    end?;
    assert_eq!(msgs.len(), 1, "one MSG: {msgs:?}");
    Ok((msgs[0].clone(), data))
}

fn jpeg_size(bytes: &[u8]) -> (u32, u32) {
    assert_eq!(&bytes[..3], &[0xFF, 0xD8, 0xFF], "JPEG magic");
    assert_eq!(&bytes[bytes.len() - 2..], &[0xFF, 0xD9], "JPEG end marker");
    let mut d = jpeg_decoder::Decoder::new(bytes);
    d.decode().expect("the thumbnail decodes");
    let info = d.info().expect("info");
    (u32::from(info.width), u32::from(info.height))
}

#[test]
fn a_thumbnail_is_one_msg_then_the_jpeg_then_end() {
    let home = Home::new();
    let source = jpeg_bytes(1600, 1200);
    let path = home.path().join("cat.jpg");
    fs::write(&path, &source).expect("write");
    let meta = fs::metadata(&path).expect("meta");
    let mut c = home.conn();
    let (msg, data) = thumb(&mut c, &json!({"path": "~/cat.jpg"})).expect("thumb");
    assert_eq!(msg["format"], "jpeg");
    assert_eq!(
        (msg["width"].clone(), msg["height"].clone()),
        (json!(256), json!(192))
    );
    assert_eq!(msg["size"], source.len());
    assert_eq!(msg["source_size"], source.len());
    assert_eq!(
        msg["mtime_ms"].as_i64().expect("mtime"),
        meta.mtime() * 1000 + meta.mtime_nsec() / 1_000_000
    );
    assert_eq!(jpeg_size(&data), (256, 192));
    assert!(data.len() < source.len() / 10, "{} bytes", data.len());
}

#[test]
fn png_and_webp_work_and_max_px_and_quality_are_clamped() {
    let home = Home::new();
    fs::write(home.path().join("a.png"), png_bytes(500, 400, false)).expect("png");
    fs::write(home.path().join("b.webp"), webp_bytes(500, 400)).expect("webp");
    fs::write(home.path().join("big.jpg"), jpeg_bytes(2000, 1500)).expect("jpeg");
    let mut c = home.conn();
    for name in ["a.png", "b.webp"] {
        let (msg, data) = thumb(&mut c, &json!({"path": format!("~/{name}"), "max_px": 100}))
            .unwrap_or_else(|e| panic!("{name}: {e:?}"));
        assert_eq!(
            (msg["width"].clone(), msg["height"].clone()),
            (json!(100), json!(80)),
            "{name}"
        );
        assert_eq!(jpeg_size(&data), (100, 80), "{name}");
    }
    // Never upscaled, even when asked for more than the picture has.
    let (msg, _) = thumb(&mut c, &json!({"path": "~/a.png", "max_px": 1024})).expect("big max");
    assert_eq!(
        (msg["width"].clone(), msg["height"].clone()),
        (json!(500), json!(400))
    );
    // Clamped: 5 -> 32, 99999 -> 1024.
    let (msg, _) = thumb(&mut c, &json!({"path": "~/big.jpg", "max_px": 5})).expect("tiny");
    assert_eq!(msg["width"], 32);
    let (msg, _) = thumb(&mut c, &json!({"path": "~/big.jpg", "max_px": 99999})).expect("huge");
    assert_eq!(msg["width"], 1024);
    // Quality is clamped and changes the size.
    let low = thumb(
        &mut c,
        &json!({"path": "~/big.jpg", "max_px": 512, "quality": 1}),
    )
    .expect("q1")
    .1;
    let high = thumb(
        &mut c,
        &json!({"path": "~/big.jpg", "max_px": 512, "quality": 500}),
    )
    .expect("q500")
    .1;
    assert!(low.len() < high.len(), "{} vs {}", low.len(), high.len());
}

#[test]
fn if_match_that_differs_is_changed_before_anything_is_decoded() {
    let home = Home::new();
    let path = home.path().join("p.jpg");
    fs::write(&path, jpeg_bytes(400, 300)).expect("write");
    let meta = fs::metadata(&path).expect("meta");
    let mtime = meta.mtime() * 1000 + meta.mtime_nsec() / 1_000_000;
    let mut c = home.conn();
    let ok = json!({"path": "~/p.jpg", "if_match": {"size": meta.len(), "mtime_ms": mtime}});
    thumb(&mut c, &ok).expect("matching identity");
    for want in [
        json!({"size": meta.len() + 1, "mtime_ms": mtime}),
        json!({"size": meta.len(), "mtime_ms": mtime + 1}),
    ] {
        let s = c.open("fs", "thumb", &json!({"path": "~/p.jpg", "if_match": want}));
        let e = c.ended(s).expect_err("changed");
        assert_eq!(e.code, ErrorCode::Changed);
    }
}

#[test]
fn thumbnail_errors_use_the_closed_codes() {
    let home = Home::new();
    fs::write(home.path().join("notes.txt"), b"hello, not a picture").expect("text");
    fs::create_dir(home.path().join("dir")).expect("dir");
    fs::write(
        home.path().join("pic.heic"),
        b"\x00\x00\x00\x18ftypheic....",
    )
    .expect("heic");
    {
        let f = File::create(home.path().join("huge.jpg")).expect("huge");
        f.set_len(65 * 1024 * 1024).expect("sparse");
    }
    let mut c = home.conn();
    let code = |c: &mut Conn, p: &str| thumb(c, &json!({"path": p})).expect_err(p);
    let e = code(&mut c, "~/notes.txt");
    assert_eq!(e.code, ErrorCode::Failed);
    assert!(e.message.starts_with("unsupported image"), "{}", e.message);
    let e = code(&mut c, "~/pic.heic");
    assert_eq!(e.code, ErrorCode::Failed);
    assert!(e.message.starts_with("unsupported image"), "{}", e.message);
    assert_eq!(code(&mut c, "~/dir").code, ErrorCode::NotAFile);
    assert_eq!(code(&mut c, "~/missing.jpg").code, ErrorCode::NotFound);
    assert_eq!(code(&mut c, "~/huge.jpg").code, ErrorCode::TooLarge);
    assert_eq!(code(&mut c, "relative.jpg").code, ErrorCode::BadRequest);
    let s = c.open("fs", "thumb", &json!({"max_px": 100}));
    assert_eq!(c.ended(s).expect_err("no path").code, ErrorCode::BadRequest);
    if !is_root() {
        let locked = home.path().join("locked.jpg");
        fs::write(&locked, jpeg_bytes(64, 64)).expect("jpeg");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");
        let e = code(&mut c, "~/locked.jpg");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).expect("restore");
        assert_eq!(e.code, ErrorCode::Permission);
    }
    // The session is fine after all of that.
    assert_eq!(
        c.call("fs", "stat", &json!({"path": "~"})).expect("stat")["kind"],
        "dir"
    );
}

#[test]
fn a_picture_over_64_megapixels_is_too_large_over_the_wire_too() {
    let home = Home::new();
    // A header that claims 9000x8000; the data is never read.
    let mut ihdr = 9000u32.to_be_bytes().to_vec();
    ihdr.extend(8000u32.to_be_bytes());
    ihdr.extend([8, 2, 0, 0, 0]);
    let chunk = |kind: &[u8; 4], data: &[u8]| -> Vec<u8> {
        let mut body = kind.to_vec();
        body.extend(data);
        let mut crc = !0u32;
        for &b in &body {
            crc ^= u32::from(b);
            for _ in 0..8 {
                crc = if crc & 1 == 1 {
                    (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >> 1
                };
            }
        }
        let mut out = (data.len() as u32).to_be_bytes().to_vec();
        out.extend(&body);
        out.extend((!crc).to_be_bytes());
        out
    };
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.extend(chunk(b"IHDR", &ihdr));
    bytes.extend(chunk(b"IDAT", &[0x78, 0x9C]));
    fs::write(home.path().join("wall.png"), bytes).expect("write");
    let mut c = home.conn();
    let e = thumb(&mut c, &json!({"path": "~/wall.png"})).expect_err("too large");
    assert_eq!(e.code, ErrorCode::TooLarge);
}

#[test]
fn a_reset_thumbnail_stops_and_the_session_carries_on() {
    let home = Home::new();
    // Noise does not compress: a decode that takes a few read calls.
    fs::write(home.path().join("noise.png"), png_bytes(1500, 1500, true)).expect("png");
    let mut c = home.conn();
    let s = c.open("fs", "thumb", &json!({"path": "~/noise.png", "max_px": 64}));
    c.reset(s);
    // Whatever the host had already queued on the stream is dropped; the next
    // call on the same connection proves it is not stuck decoding.
    let ok = c
        .call("fs", "stat", &json!({"path": "~/noise.png"}))
        .expect("stat");
    assert_eq!(ok["kind"], "file");
    let (msg, _) = thumb(&mut c, &json!({"path": "~/noise.png", "max_px": 64})).expect("again");
    assert_eq!(msg["width"], 64);
}

// ---------------------------------------------------------------- search

fn search(c: &mut Conn, args: &Value) -> (Vec<Value>, Result<Value, WireError>) {
    let s = c.open("fs", "search", args);
    let (msgs, data, end) = c.drain(s);
    assert!(data.is_empty(), "search sends no DATA");
    (msgs, end)
}

fn found(msgs: &[Value]) -> Vec<Value> {
    msgs.iter()
        .flat_map(|m| m["entries"].as_array().expect("entries").clone())
        .collect()
}

fn found_names(msgs: &[Value]) -> Vec<String> {
    found(msgs)
        .iter()
        .map(|e| e["name"].as_str().expect("name").to_string())
        .collect()
}

fn touch(p: &Path) {
    fs::create_dir_all(p.parent().expect("parent")).expect("dirs");
    fs::write(p, b"x").expect("file");
}

#[test]
fn search_finds_by_name_breadth_first_and_ends_with_the_summary() {
    let home = Home::new();
    touch(&home.path().join("p/src/deep/Report-final.txt"));
    touch(&home.path().join("p/src/report.md"));
    touch(&home.path().join("p/REPORT"));
    touch(&home.path().join("p/other.txt"));
    touch(&home.path().join("p/node_modules/report.js"));
    touch(&home.path().join("p/.git/report"));
    touch(&home.path().join("p/.hidden-report"));
    let mut c = home.conn();
    let (msgs, end) = search(&mut c, &json!({"root": "~/p", "query": "report"}));
    let names = found_names(&msgs);
    assert_eq!(
        names,
        ["REPORT", "report.md", "Report-final.txt"],
        "shallow first, no ignored, no hidden"
    );
    let end = end.expect("ends well");
    assert_eq!(end["truncated"], false);
    assert_eq!(end["skipped_dirs"], 0);
    assert!(end["scanned"].as_u64().expect("scanned") >= 6);
    assert!(end["elapsed_ms"].is_u64());
    let first = &found(&msgs)[0];
    assert_eq!(first["kind"], "file");
    assert_eq!(first["size"], 1);
    assert_eq!(
        first["path"],
        home.path().join("p/REPORT").to_string_lossy().as_ref()
    );

    // hidden and an empty ignore list reach the rest.
    let (msgs, _) = search(
        &mut c,
        &json!({"root": "~/p", "query": "report", "hidden": true, "ignore": []}),
    );
    assert_eq!(found_names(&msgs).len(), 6);
}

#[test]
fn search_filters_by_kind_and_age_and_reports_links_without_following_them() {
    let home = Home::new();
    touch(&home.path().join("t/old.log"));
    touch(&home.path().join("t/new.log"));
    fs::create_dir(home.path().join("t/logs")).expect("dir");
    symlink(home.path().join("t"), home.path().join("t/logs/loop")).expect("loop");
    symlink(home.path().join("t/logs"), home.path().join("t/logs-link")).expect("link");
    set_mtime(
        &home.path().join("t/old.log"),
        SystemTime::now() - Duration::from_secs(30 * 86400),
    );
    let mut c = home.conn();
    let (msgs, end) = search(
        &mut c,
        &json!({"root": "~/t", "kind": "file", "modified_within_s": 3600}),
    );
    end.expect("ends well");
    assert_eq!(found_names(&msgs), ["new.log"]);
    let (msgs, _) = search(&mut c, &json!({"root": "~/t", "kind": "dir"}));
    assert_eq!(found_names(&msgs), ["logs"]);
    // The loop terminates; the links are links and nothing below them shows up.
    let (msgs, end) = search(&mut c, &json!({"root": "~/t"}));
    let end = end.expect("terminates");
    let all = found(&msgs);
    let kind = |n: &str| {
        all.iter()
            .find(|e| e["name"] == n)
            .map(|e| e["kind"].clone())
    };
    assert_eq!(kind("loop"), Some(json!("link")));
    assert_eq!(kind("logs-link"), Some(json!("link")));
    assert_eq!(all.len(), 5);
    assert_eq!(end["scanned"], 5);
}

#[test]
fn search_max_results_truncates_and_big_results_come_in_batches_of_at_most_100() {
    let home = Home::new();
    for i in 0..350 {
        touch(&home.path().join(format!("m/f{i:03}.txt")));
    }
    let mut c = home.conn();
    let (msgs, end) = search(&mut c, &json!({"root": "~/m", "query": ".txt"}));
    end.expect("ends well");
    assert_eq!(found(&msgs).len(), 350);
    assert!(msgs
        .iter()
        .all(|m| m["entries"].as_array().expect("entries").len() <= 100));
    assert_eq!(
        msgs[0]["entries"].as_array().expect("entries").len(),
        1,
        "the first entry leaves alone"
    );
    let (msgs, end) = search(&mut c, &json!({"root": "~/m", "max_results": 40}));
    assert_eq!(found(&msgs).len(), 40);
    assert_eq!(end.expect("ends well")["truncated"], true);
}

#[test]
fn search_root_errors_and_bad_arguments_are_typed() {
    let home = Home::new();
    touch(&home.path().join("file"));
    let mut c = home.conn();
    let code = |c: &mut Conn, args: Value| search(c, &args).1.expect_err("error").code;
    assert_eq!(
        code(&mut c, json!({"root": "~/missing"})),
        ErrorCode::NotFound
    );
    assert_eq!(
        code(&mut c, json!({"root": "~/file"})),
        ErrorCode::NotADirectory
    );
    assert_eq!(
        code(&mut c, json!({"root": "relative"})),
        ErrorCode::BadRequest
    );
    assert_eq!(
        code(&mut c, json!({"root": "~", "kind": "nope"})),
        ErrorCode::BadRequest
    );
    assert_eq!(code(&mut c, json!({"query": "x"})), ErrorCode::BadRequest);
    if !is_root() {
        let locked = home.path().join("locked");
        fs::create_dir(&locked).expect("dir");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).expect("chmod");
        let c1 = code(&mut c, json!({"root": "~/locked"}));
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).expect("restore");
        assert_eq!(c1, ErrorCode::Permission);
    }
}

#[test]
fn search_counts_unreadable_folders_instead_of_failing() {
    if is_root() {
        return;
    }
    let home = Home::new();
    touch(&home.path().join("s/open/a.txt"));
    touch(&home.path().join("s/shut/b.txt"));
    let shut = home.path().join("s/shut");
    fs::set_permissions(&shut, fs::Permissions::from_mode(0o000)).expect("chmod");
    let mut c = home.conn();
    let (msgs, end) = search(&mut c, &json!({"root": "~/s", "kind": "file"}));
    fs::set_permissions(&shut, fs::Permissions::from_mode(0o755)).expect("restore");
    assert_eq!(found_names(&msgs), ["a.txt"]);
    assert_eq!(end.expect("ends well")["skipped_dirs"], 1);
}

#[test]
fn a_reset_search_stops_and_the_session_carries_on() {
    let home = Home::new();
    for d in 0..40 {
        for f in 0..50 {
            touch(&home.path().join(format!("w/d{d:02}/f{f:02}")));
        }
    }
    let mut c = home.conn();
    let s = c.open("fs", "search", &json!({"root": "~/w", "max_results": 2000}));
    // Wait for the first results, then cancel.
    let first = c.msg(s);
    assert!(!first["entries"].as_array().expect("entries").is_empty());
    c.reset(s);
    let ok = c
        .call("fs", "stat", &json!({"path": "~/w"}))
        .expect("stat after the reset");
    assert_eq!(ok["kind"], "dir");
    // A new search on the same connection runs to its end.
    let (msgs, end) = search(
        &mut c,
        &json!({"root": "~/w", "kind": "file", "max_results": 2000}),
    );
    end.expect("ends well");
    assert_eq!(found(&msgs).len(), 2000);
}
