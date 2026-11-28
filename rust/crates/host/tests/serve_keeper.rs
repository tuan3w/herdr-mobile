//! The `keeper` service on the real `herdr-host serve` binary, driven over its
//! pipes with the `wire` crate as the client, the way the app drives it. The
//! agent a keeper starts is a scripted `omp` (testkit's `fake-acp-agent`).
//!
//! Hermetic: its own HOME, no herdr, `HERDR_MOBILE_NO_PANE=1`; every process it
//! starts is stopped by pid. Every wait has a timeout, so a bug fails the test
//! instead of hanging it.

use keeper::records::{is_valid_id, Info, State, StateDir};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use wire::{
    read_frame, write_frame, ClientHello, ClientInfo, ErrorCode, Flags, Frame, HerdrHello,
    HostHello, Inflater, Kind, WireError, MAGIC,
};

const WAIT: Duration = Duration::from_secs(30);
const WINDOW: i64 = 1 << 20;
const MAX_DATA: usize = 32 * 1024;

// ---- the machine ----

/// An isolated machine: a home and a `bin` with a scripted `omp`.
struct Machine {
    _dir: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
    started: Vec<i64>,
}

impl Machine {
    fn new() -> Machine {
        let dir = tempfile::tempdir().expect("a temp dir");
        let home = dir.path().join("home");
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&home).expect("home");
        std::fs::create_dir_all(&bin).expect("bin");
        let omp = bin.join("omp");
        std::fs::write(
            &omp,
            format!(
                "#!/bin/sh\nexec '{}' \"$@\"\n",
                testkit::bin("fake-acp-agent").display()
            ),
        )
        .expect("omp");
        Command::new("chmod")
            .arg("755")
            .arg(&omp)
            .status()
            .expect("chmod");
        Machine {
            _dir: dir,
            home,
            bin,
            started: Vec::new(),
        }
    }

    /// `serve` the way the app starts it: only the scripted bin and the system
    /// on PATH (the real PATH holds the owner's real agents), no herdr.
    fn serve(&self) -> Serve {
        let path = format!("{}:/usr/bin:/bin", self.bin.display());
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_herdr-host"));
        cmd.arg("serve")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .env("HOME", &self.home)
            .env("PATH", path)
            .env("HERDR_MOBILE_NO_PANE", "1");
        for k in [
            "HERDR_SOCKET_PATH",
            "HERDR_ENV",
            "HERDR_PANE_ID",
            "HERDR_TAB_ID",
            "HERDR_WORKSPACE_ID",
            "HERDR_BIN_PATH",
        ] {
            cmd.env_remove(k);
        }
        Serve::start(cmd)
    }

    /// Starts a keeper over `serve`, remembering its pids for cleanup.
    fn start(&mut self, serve: &mut Serve, cwd: &Path) -> Info {
        let info = serve
            .call(
                "keeper",
                "start",
                json!({"agent": "omp", "cwd": cwd.to_string_lossy()}),
            )
            .expect("start answers");
        self.started.extend(
            ["pid", "agent_pid"]
                .iter()
                .filter_map(|k| info[*k].as_i64()),
        );
        serde_json::from_value(info).expect("start answers a keeper record")
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        for pid in &self.started {
            let _ = Command::new("kill").arg(pid.to_string()).status();
        }
        // Wait for each to be gone: a condition, not a guess at how long it takes.
        let end = Instant::now() + Duration::from_secs(5);
        for pid in &self.started {
            while Command::new("kill")
                .args(["-0", &pid.to_string()])
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
                && Instant::now() < end
            {
                std::thread::yield_now();
            }
        }
    }
}

// ---- the wire client ----

/// What the host sent, with payloads inflated.
#[derive(Debug)]
enum Ev {
    Msg(u32, Value),
    Data(u32, Vec<u8>),
    End(u32, Value),
    Reset(u32, Value),
    Eof,
}

impl Ev {
    fn stream(&self) -> Option<u32> {
        match self {
            Ev::Msg(s, _) | Ev::Data(s, _) | Ev::End(s, _) | Ev::Reset(s, _) => Some(*s),
            Ev::Eof => None,
        }
    }
}

type Credit = Arc<(Mutex<HashMap<u32, i64>>, Condvar)>;

struct Serve {
    child: Child,
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    events: Receiver<Ev>,
    held: VecDeque<Ev>,
    credit: Credit,
    next_stream: u32,
}

impl Serve {
    fn start(mut cmd: Command) -> Serve {
        let mut child = cmd.spawn().expect("spawn herdr-host serve");
        let mut stdin = child.stdin.take().expect("stdin");
        let mut stdout = child.stdout.take().expect("stdout");
        let mut magic = [0u8; 14];
        std::io::Read::read_exact(&mut stdout, &mut magic).expect("the magic comes first");
        assert_eq!(&magic, MAGIC);
        let hello = ClientHello {
            proto: 1,
            client: ClientInfo {
                name: "test".into(),
                version: "0".into(),
            },
            herdr: HerdrHello::default(),
        };
        write_frame(
            &mut stdin,
            &Frame::json(Kind::Hello, 0, &serde_json::to_value(hello).expect("hello")),
        )
        .expect("send hello");
        let f = read_frame(&mut stdout)
            .expect("a frame")
            .expect("a host hello");
        let host: HostHello = serde_json::from_slice(&f.payload).expect("host hello");
        assert!(
            host.services.get("keeper").is_some_and(|s| s.available),
            "the keeper service is offered: {:?}",
            host.services
        );
        let stdin = Arc::new(Mutex::new(Some(stdin)));
        let credit: Credit = Arc::new((Mutex::new(HashMap::new()), Condvar::new()));
        let (tx, events) = channel();
        {
            let stdin = Arc::clone(&stdin);
            let credit = Arc::clone(&credit);
            std::thread::spawn(move || {
                let mut inflaters: HashMap<u32, Inflater> = HashMap::new();
                let mut consumed: HashMap<u32, usize> = HashMap::new();
                while let Ok(Some(f)) = read_frame(&mut stdout) {
                    let stream = f.stream;
                    let ev = match f.kind {
                        Kind::Credit => {
                            let n = i64::from(f.credit_bytes().unwrap_or(0));
                            *credit
                                .0
                                .lock()
                                .expect("credit")
                                .entry(stream)
                                .or_insert(WINDOW) += n;
                            credit.1.notify_all();
                            continue;
                        }
                        Kind::Msg | Kind::Data | Kind::End | Kind::Reset => {
                            let wire_len = f.payload.len();
                            let bytes = match f.flags {
                                Flags::None => f.payload.clone(),
                                Flags::Deflate => Inflater::once(&f.payload).expect("inflate"),
                                Flags::DeflateCtx => inflaters
                                    .entry(stream)
                                    .or_default()
                                    .piece(&f.payload)
                                    .expect("inflate piece"),
                            };
                            if matches!(f.kind, Kind::Msg | Kind::Data) {
                                let c = consumed.entry(stream).or_insert(0);
                                *c += wire_len;
                                if *c >= 256 * 1024 {
                                    let grant = u32::try_from(*c).unwrap_or(u32::MAX);
                                    *c = 0;
                                    if let Some(w) = stdin.lock().expect("stdin").as_mut() {
                                        let _ = write_frame(w, &Frame::credit(stream, grant));
                                    }
                                }
                            }
                            let json = || serde_json::from_slice(&bytes).unwrap_or(Value::Null);
                            match f.kind {
                                Kind::Msg => Ev::Msg(stream, json()),
                                Kind::Data => Ev::Data(stream, bytes),
                                Kind::End => Ev::End(stream, json()),
                                _ => Ev::Reset(stream, json()),
                            }
                        }
                        _ => continue,
                    };
                    if tx.send(ev).is_err() {
                        return;
                    }
                }
                let _ = tx.send(Ev::Eof);
            });
        }
        Serve {
            child,
            stdin,
            events,
            held: VecDeque::new(),
            credit,
            next_stream: 1,
        }
    }

    fn write(&self, frame: &Frame) {
        let mut guard = self.stdin.lock().expect("stdin");
        let w = guard.as_mut().expect("stdin is open");
        write_frame(w, frame).expect("write a frame");
        w.flush().expect("flush");
    }

    fn open(&mut self, svc: &str, method: &str, args: Value, zctx: bool) -> u32 {
        let id = self.next_stream;
        self.next_stream += 2;
        self.write(&Frame::json(
            Kind::Open,
            id,
            &json!({"svc": svc, "method": method, "args": args, "zctx": zctx}),
        ));
        id
    }

    /// DATA to the host, waiting for credit as a real client must.
    fn send_data(&self, stream: u32, bytes: &[u8]) {
        for chunk in bytes.chunks(MAX_DATA) {
            let need = i64::try_from(chunk.len()).expect("small");
            let deadline = Instant::now() + WAIT;
            let mut credit = self.credit.0.lock().expect("credit");
            loop {
                let avail = credit.entry(stream).or_insert(WINDOW);
                if *avail >= need {
                    *avail -= need;
                    break;
                }
                let left = deadline
                    .checked_duration_since(Instant::now())
                    .expect("the host grants credit in time");
                credit = self.credit.1.wait_timeout(credit, left).expect("credit").0;
            }
            drop(credit);
            self.write(&Frame::new(Kind::Data, stream, chunk.to_vec()));
        }
    }

    fn end(&self, stream: u32) {
        self.write(&Frame::json(Kind::End, stream, &json!({})));
    }

    fn reset(&self, stream: u32) {
        self.write(&Frame::json(
            Kind::Reset,
            stream,
            &json!({"code": "cancelled", "message": "test"}),
        ));
    }

    /// The next event of `stream`, whatever other streams do meanwhile.
    fn recv(&mut self, stream: u32) -> Ev {
        if let Some(at) = self.held.iter().position(|e| e.stream() == Some(stream)) {
            return self.held.remove(at).expect("position is valid");
        }
        let deadline = Instant::now() + WAIT;
        loop {
            let left = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_default();
            match self.events.recv_timeout(left) {
                Ok(ev) if ev.stream() == Some(stream) => return ev,
                Ok(Ev::Eof) => panic!("serve closed its output while stream {stream} waited"),
                Ok(ev) => self.held.push_back(ev),
                Err(RecvTimeoutError::Timeout) => panic!("stream {stream}: nothing in {WAIT:?}"),
                Err(RecvTimeoutError::Disconnected) => panic!("the reader is gone"),
            }
        }
    }

    /// A `call`: the MSG then `END`, or the error `END` carries.
    fn call(&mut self, svc: &str, method: &str, args: Value) -> Result<Value, WireError> {
        let id = self.open(svc, method, args, false);
        let mut result = None;
        loop {
            match self.recv(id) {
                Ev::Msg(_, v) => result = Some(v),
                Ev::End(_, end) => {
                    return match WireError::from_end(&end) {
                        Some(e) => Err(e),
                        None => Ok(result.expect("a call answers before it ends")),
                    }
                }
                Ev::Reset(_, body) => panic!("{svc}.{method} was reset: {body}"),
                other => panic!("unexpected {other:?}"),
            }
        }
    }

    /// Everything a stream sends as DATA until its `END`, and the `END`.
    fn drain(&mut self, stream: u32) -> (Vec<u8>, Value) {
        let mut data = Vec::new();
        loop {
            match self.recv(stream) {
                Ev::Data(_, d) => data.extend(d),
                Ev::End(_, end) => return (data, end),
                other => panic!("unexpected {other:?}"),
            }
        }
    }

    /// Reads DATA until `done(all bytes so far)`; the stream must not end first.
    fn data_until(&mut self, stream: u32, mut done: impl FnMut(&[u8]) -> bool) -> Vec<u8> {
        let mut data = Vec::new();
        while !done(&data) {
            match self.recv(stream) {
                Ev::Data(_, d) => data.extend(d),
                other => panic!("the stream ended or failed early: {other:?}"),
            }
        }
        data
    }

    /// Closes stdin and waits for `serve` to close its output: the app's
    /// "channel closed", which must come even though keepers live on.
    fn close_and_expect_eof(mut self) {
        self.stdin.lock().expect("stdin").take();
        let deadline = Instant::now() + WAIT;
        loop {
            let left = deadline
                .checked_duration_since(Instant::now())
                .expect("serve closed its output after stdin closed");
            match self.events.recv_timeout(left) {
                Ok(Ev::Eof) => break,
                Ok(_) => {}
                Err(e) => panic!("serve kept its output open after stdin closed: {e}"),
            }
        }
        let status = self.child.wait().expect("serve exits");
        assert_eq!(status.code(), Some(0));
    }
}

impl Drop for Serve {
    fn drop(&mut self) {
        self.stdin.lock().expect("stdin").take();
        // Our own child: ask once, then stop it, so a hang is a failure, not a leak.
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::yield_now();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---- ACP over an attach stream ----

/// The lines of ACP JSON-RPC on one attach stream.
struct Acp {
    stream: u32,
    buf: Vec<u8>,
}

impl Acp {
    fn new(stream: u32) -> Acp {
        Acp {
            stream,
            buf: Vec::new(),
        }
    }

    fn send(&self, serve: &Serve, id: i64, method: &str, params: Value) {
        let line = format!(
            "{}\n",
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        );
        serve.send_data(self.stream, line.as_bytes());
    }

    /// Lines until the response to `id`; its result and every notification met.
    fn response(&mut self, serve: &mut Serve, id: i64) -> (Value, Vec<Value>) {
        let mut notes = Vec::new();
        loop {
            if let Some(at) = self.buf.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = self.buf.drain(..=at).collect();
                let v: Value = serde_json::from_slice(&line).expect("the keeper speaks JSON-RPC");
                if v["id"] == json!(id) && v.get("method").is_none() {
                    assert!(v.get("error").is_none(), "{v}");
                    return (v["result"].clone(), notes);
                }
                notes.push(v);
                continue;
            }
            match serve.recv(self.stream) {
                Ev::Data(_, d) => self.buf.extend(d),
                other => panic!("the attach stream ended before the answer to {id}: {other:?}"),
            }
        }
    }
}

fn viewer_initialize() -> Value {
    json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": "test", "title": "Test", "version": "0"}, "_meta": {"herdr": {"viewer": true}}})
}

fn error_code(r: Result<Value, WireError>) -> ErrorCode {
    r.expect_err("the call fails").code
}

fn text_of(notes: &[Value]) -> Option<String> {
    notes.iter().find_map(|n| {
        n["params"]["update"]["content"]["text"]
            .as_str()
            .map(str::to_string)
    })
}

// ---- tests ----

#[test]
fn probe_offers_the_scripted_agent_by_its_route_id() {
    let machine = Machine::new();
    let mut serve = machine.serve();
    let answer = serve
        .call("keeper", "probe", json!({}))
        .expect("probe answers");
    let routes: Vec<&str> = answer["routes"]
        .as_array()
        .expect("a list of routes")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert!(routes.contains(&"omp"), "{routes:?}");
    assert!(!routes.contains(&"nope"));
}

#[test]
fn a_keeper_is_started_listed_attached_to_detached_from_and_killed_over_one_connection() {
    let mut machine = Machine::new();
    let mut serve = machine.serve();
    let cwd = machine.home.join("proj");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let info = machine.start(&mut serve, &cwd);
    assert!(is_valid_id(&info.id), "{}", info.id);
    assert_eq!(info.agent, "omp");
    assert_eq!(info.state, State::Running);

    // A second `list` shows it, with the same record.
    let listed = serve
        .call("keeper", "list", json!([]))
        .expect("list answers");
    let listed: Vec<Info> = serde_json::from_value(listed).expect("an array of records");
    assert_eq!(listed.iter().filter(|i| i.id == info.id).count(), 1);

    // Attach: the viewer's first lines go out cut in odd places; the answers and
    // the agent's update come back as DATA.
    let a = serve.open("keeper", "attach", json!({"id": info.id}), true);
    let mut acp = Acp::new(a);
    let hello = format!(
        "{}\n",
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": viewer_initialize()})
    );
    let (head, tail) = hello.as_bytes().split_at(17);
    serve.send_data(a, head);
    serve.send_data(a, tail);
    let (init, _) = acp.response(&mut serve, 1);
    assert_eq!(init["protocolVersion"], 1, "{init}");
    acp.send(
        &serve,
        2,
        "session/new",
        json!({"cwd": cwd.to_string_lossy(), "mcpServers": []}),
    );
    let (made, _) = acp.response(&mut serve, 2);
    assert_eq!(made["sessionId"], "sess-1", "{made}");
    acp.send(
        &serve,
        3,
        "session/prompt",
        json!({"sessionId": "sess-1", "prompt": [{"type": "text", "text": "len:hi"}]}),
    );
    let (done, notes) = acp.response(&mut serve, 3);
    assert_eq!(done["stopReason"], "end_turn");
    assert_eq!(text_of(&notes).as_deref(), Some("len=2"), "{notes:?}");

    // Detaching (the client ends its side) ends the stream and leaves the keeper.
    serve.end(a);
    let (_, end) = serve.drain(a);
    assert!(WireError::from_end(&end).is_none(), "a clean end: {end}");
    let still = serve
        .call("keeper", "list", json!({}))
        .expect("list answers");
    let still: Vec<Info> = serde_json::from_value(still).expect("records");
    assert!(
        still
            .iter()
            .any(|i| i.id == info.id && i.state == State::Running),
        "{still:?}"
    );

    // Two attached streams; a kill from a third ends both with a clean END.
    let s1 = serve.open("keeper", "attach", json!({"id": info.id}), true);
    let s2 = serve.open("keeper", "attach", json!({"id": info.id}), false);
    let mut acp1 = Acp::new(s1);
    acp1.send(&serve, 10, "initialize", viewer_initialize());
    let _ = acp1.response(&mut serve, 10);
    let mut acp2 = Acp::new(s2);
    acp2.send(&serve, 11, "initialize", viewer_initialize());
    let _ = acp2.response(&mut serve, 11);
    let killed = serve
        .call("keeper", "kill", json!({"id": info.id}))
        .expect("kill answers");
    assert_eq!(killed, json!({"ok": true}));
    for s in [s1, s2] {
        let (_, end) = serve.drain(s);
        assert!(WireError::from_end(&end).is_none(), "{end}");
    }
    let after = serve
        .call("keeper", "list", json!({}))
        .expect("list answers");
    let after: Vec<Info> = serde_json::from_value(after).expect("records");
    assert!(after.iter().all(|i| i.id != info.id), "{after:?}");
    assert_eq!(
        error_code(serve.call("keeper", "kill", json!({"id": info.id}))),
        ErrorCode::NotFound,
        "a keeper that is gone"
    );
    let gone = serve.open("keeper", "attach", json!({"id": info.id}), true);
    let (_, end) = serve.drain(gone);
    assert_eq!(
        WireError::from_end(&end).map(|e| e.code),
        Some(ErrorCode::NotFound)
    );
}

#[test]
fn a_3_mb_line_sent_in_32_kib_pieces_reaches_the_agent_whole() {
    let mut machine = Machine::new();
    let mut serve = machine.serve();
    let cwd = machine.home.join("proj");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let info = machine.start(&mut serve, &cwd);
    let a = serve.open("keeper", "attach", json!({"id": info.id}), true);
    let mut acp = Acp::new(a);
    acp.send(&serve, 1, "initialize", viewer_initialize());
    let _ = acp.response(&mut serve, 1);
    acp.send(
        &serve,
        2,
        "session/new",
        json!({"cwd": cwd.to_string_lossy(), "mcpServers": []}),
    );
    let _ = acp.response(&mut serve, 2);
    let big = "x".repeat(3_000_000);
    acp.send(
        &serve,
        3,
        "session/prompt",
        json!({"sessionId": "sess-1", "prompt": [{"type": "text", "text": format!("len:{big}")}]}),
    );
    let (_, notes) = acp.response(&mut serve, 3);
    assert_eq!(text_of(&notes).as_deref(), Some("len=3000000"));
}

#[test]
fn an_attach_to_an_agent_that_has_exited_says_so_with_the_reason() {
    let machine = Machine::new();
    let dir = StateDir::create(&machine.home).expect("state dir");
    dir.write(&Info {
        id: "gone42".into(),
        agent: "omp".into(),
        state: State::Exited,
        exit_reason: Some("the agent ended on its own.".into()),
        ..Info::default()
    })
    .expect("a record of a keeper whose agent has exited");
    let mut serve = machine.serve();
    let a = serve.open("keeper", "attach", json!({"id": "gone42"}), true);
    let (data, end) = serve.drain(a);
    assert!(data.is_empty());
    let err = WireError::from_end(&end).expect("an error end");
    assert_eq!(err.code, ErrorCode::AgentExited);
    assert!(
        err.message.contains("the agent ended on its own."),
        "{err:?}"
    );
    assert!(!err.message.starts_with("herdr-mobile:"), "{err:?}");
}

#[test]
fn requests_that_cannot_work_end_with_the_code_the_app_acts_on() {
    let machine = Machine::new();
    let mut serve = machine.serve();
    let mut code = |method: &str, args: Value| error_code(serve.call("keeper", method, args));
    let home = machine.home.to_string_lossy().into_owned();
    // The client sent something that is not a request this service answers.
    assert_eq!(
        code("start", json!({"agent": "nope", "cwd": &home})),
        ErrorCode::BadRequest,
        "an unknown agent"
    );
    assert_eq!(
        code("start", json!({"agent": "omp", "cwd": "a\nb"})),
        ErrorCode::BadRequest,
        "a folder with a newline"
    );
    assert_eq!(
        code("start", json!({"agent": "omp"})),
        ErrorCode::BadRequest,
        "no folder"
    );
    assert_eq!(
        code("kill", json!({"id": "../x"})),
        ErrorCode::BadRequest,
        "not a keeper id"
    );
    assert_eq!(
        code("history", json!({"agent": "nope"})),
        ErrorCode::BadRequest
    );
    // The request is fine; the thing is not there.
    assert_eq!(
        code(
            "start",
            json!({"agent": "omp", "cwd": "/definitely/not/here"})
        ),
        ErrorCode::NotFound,
        "a missing folder"
    );
    assert_eq!(
        code("start", json!({"agent": "omp", "cwd": "~/missing"})),
        ErrorCode::NotFound,
        "`~` is the host's home"
    );
    assert_eq!(
        code("kill", json!({"id": "zzzzzz"})),
        ErrorCode::NotFound,
        "an unknown keeper"
    );
    assert_eq!(
        code(
            "history",
            json!({"agent": "omp", "cwd": "/definitely/not/here"})
        ),
        ErrorCode::NotFound
    );
    // An agent that is not installed: only `omp` has no npx fallback, so this
    // can never start a real agent.
    std::fs::remove_file(machine.bin.join("omp")).expect("remove the scripted omp");
    let elsewhere = [
        "/usr/local/bin/omp",
        "/opt/homebrew/bin/omp",
        "/usr/bin/omp",
        "/bin/omp",
    ]
    .iter()
    .any(|p| Path::new(p).exists());
    if elsewhere {
        eprintln!("an omp is installed on this machine: agent_missing not checked");
    } else {
        assert_eq!(
            code("start", json!({"agent": "omp", "cwd": &home})),
            ErrorCode::AgentMissing
        );
        assert_eq!(
            code("history", json!({"agent": "omp"})),
            ErrorCode::AgentMissing
        );
    }
}

#[test]
fn the_log_streams_refuse_what_the_command_line_refuses() {
    let machine = Machine::new();
    let mut serve = machine.serve();
    let home = machine.home.clone();
    let log = home.join("log.jsonl");
    std::fs::write(&log, "{\"a\":1}\n").expect("log");
    let outside = tempfile::tempdir().expect("outside");
    let elsewhere = outside.path().join("log.jsonl");
    std::fs::write(&elsewhere, "{\"a\":1}\n").expect("log outside");
    let link = home.join("link.jsonl");
    std::os::unix::fs::symlink(&elsewhere, &link).expect("symlink");

    let mut code_of = |method: &str, args: Value| {
        let id = serve.open("keeper", method, args, false);
        let (data, end) = serve.drain(id);
        (data, WireError::from_end(&end).map(|e| e.code))
    };
    for (what, path) in [
        (
            "outside the home folder",
            elsewhere.to_string_lossy().into_owned(),
        ),
        (
            "a link out of the home folder",
            link.to_string_lossy().into_owned(),
        ),
        ("a relative path", "log.jsonl".to_string()),
        (
            "not a .jsonl file",
            home.join("log.txt").to_string_lossy().into_owned(),
        ),
        (
            "a missing file",
            home.join("missing.jsonl").to_string_lossy().into_owned(),
        ),
        (
            "a path that climbs out",
            format!("{}/../../etc/x.jsonl", home.display()),
        ),
    ] {
        let (data, code) = code_of("follow", json!({"path": path, "from": 0, "to": 1}));
        assert_eq!(code, Some(ErrorCode::NotFound), "follow: {what}");
        assert!(data.is_empty(), "follow: {what} sent data");
        let (_, code) = code_of(
            "blob",
            json!({"path": path, "start": 0, "hash": "0123456789abcdef"}),
        );
        assert_eq!(code, Some(ErrorCode::NotFound), "blob: {what}");
    }
    let (_, code) = code_of("follow", json!({"path": "/h/a\nb.jsonl"}));
    assert_eq!(code, Some(ErrorCode::BadRequest), "a newline in the path");
    let (_, code) = code_of(
        "blob",
        json!({"path": log.to_string_lossy(), "start": 0, "hash": "not-hex"}),
    );
    assert_eq!(
        code,
        Some(ErrorCode::BadRequest),
        "a hash that is not 16 hex digits"
    );
    // The same path inside the home folder works.
    let (data, code) = code_of(
        "follow",
        json!({"path": log.to_string_lossy(), "from": 0, "to": 8}),
    );
    assert_eq!(code, None);
    assert!(
        String::from_utf8_lossy(&data).contains("8\t{\"a\":1}"),
        "{data:?}"
    );
}

#[test]
fn follow_streams_a_log_as_it_grows_and_stops_when_the_client_ends_it() {
    let machine = Machine::new();
    let mut serve = machine.serve();
    let log = machine.home.join("session.jsonl");
    std::fs::write(&log, "{\"n\":1}\n{\"n\":2}\n").expect("log");
    let id = serve.open(
        "keeper",
        "follow",
        json!({"path": log.to_string_lossy(), "poll_ms": 20}),
        false,
    );
    // Both lines, then `C`: the phone is up to date at byte 16.
    let first = serve.data_until(id, |d| String::from_utf8_lossy(d).contains("C\t16\n"));
    let text = String::from_utf8_lossy(&first).into_owned();
    assert!(
        text.contains("8\t{\"n\":1}\n") && text.contains("16\t{\"n\":2}\n"),
        "{text}"
    );
    // A line appended later arrives without a new request.
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(&log)
        .expect("open log");
    f.write_all(b"{\"n\":3}\n").expect("append");
    let more = serve.data_until(id, |d| {
        String::from_utf8_lossy(d).contains("24\t{\"n\":3}\n")
    });
    assert!(!more.is_empty());
    // The client says it is done: the stream ends at once, cleanly.
    serve.end(id);
    let (_, end) = serve.drain(id);
    assert!(WireError::from_end(&end).is_none(), "{end}");
}

#[test]
fn blob_returns_the_payload_follow_left_out_by_the_reference_it_left() {
    let machine = Machine::new();
    let mut serve = machine.serve();
    let payload = "QUJD".repeat(300);
    let log = machine.home.join("pics.jsonl");
    let line = format!("{{\"type\":\"image\",\"data\":\"{payload}\"}}\n");
    std::fs::write(&log, &line).expect("log");
    let f = serve.open(
        "keeper",
        "follow",
        json!({"path": log.to_string_lossy(), "from": 0, "to": line.len()}),
        false,
    );
    let (data, end) = serve.drain(f);
    assert!(WireError::from_end(&end).is_none(), "{end}");
    let text = String::from_utf8_lossy(&data).into_owned();
    assert!(
        !text.contains(&payload),
        "follow does not carry the picture"
    );
    let marker = text.split("ref=").nth(1).expect("the note carries a ref");
    let reference: String = marker
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '.')
        .collect();
    let (start, hash) = reference.split_once('.').expect("<start>.<hash>");
    let b = serve.open(
        "keeper",
        "blob",
        json!({"path": log.to_string_lossy(), "start": start.parse::<u64>().expect("start"), "hash": hash}),
        false,
    );
    let (data, end) = serve.drain(b);
    assert!(WireError::from_end(&end).is_none(), "{end}");
    let text = String::from_utf8_lossy(&data).into_owned();
    let body: String = text.lines().filter_map(|l| l.strip_prefix("B\t")).collect();
    assert_eq!(body, payload);
    assert!(text.ends_with(&format!("D\t{}\n", payload.len())), "{text}");
}

#[test]
fn serve_closes_its_output_when_stdin_closes_even_though_a_keeper_it_started_lives_on() {
    let mut machine = Machine::new();
    let mut serve = machine.serve();
    let cwd = machine.home.join("proj");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let info = machine.start(&mut serve, &cwd);
    serve.close_and_expect_eof();
    // The keeper is not tied to the connection: a new connection finds it running.
    let mut again = machine.serve();
    let listed = again
        .call("keeper", "list", json!({}))
        .expect("list answers");
    let listed: Vec<Info> = serde_json::from_value(listed).expect("records");
    assert!(
        listed
            .iter()
            .any(|i| i.id == info.id && i.state == State::Running),
        "{listed:?}"
    );
}

#[test]
fn resetting_an_attach_detaches_without_stopping_the_keeper_and_it_can_be_joined_again() {
    let mut machine = Machine::new();
    let mut serve = machine.serve();
    let cwd = machine.home.join("proj");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let info = machine.start(&mut serve, &cwd);
    let a = serve.open("keeper", "attach", json!({"id": info.id}), true);
    let mut acp = Acp::new(a);
    acp.send(&serve, 1, "initialize", viewer_initialize());
    let _ = acp.response(&mut serve, 1);
    serve.reset(a);
    // The same keeper answers a new attach, once its first client is gone.
    let b = serve.open("keeper", "attach", json!({"id": info.id}), true);
    let mut acp = Acp::new(b);
    acp.send(&serve, 2, "initialize", viewer_initialize());
    let (init, _) = acp.response(&mut serve, 2);
    assert_eq!(init["protocolVersion"], 1, "{init}");
    let listed = serve
        .call("keeper", "list", json!({}))
        .expect("list answers");
    let listed: Vec<Info> = serde_json::from_value(listed).expect("records");
    assert!(
        listed
            .iter()
            .any(|i| i.id == info.id && i.state == State::Running),
        "{listed:?}"
    );
}

#[test]
fn the_follow_command_line_sends_a_bounded_read_whole_even_with_stdin_already_closed() {
    let machine = Machine::new();
    let log = machine.home.join("a.jsonl");
    std::fs::write(&log, "{\"a\":1}\n").expect("log");
    let out = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .args(["follow", &log.to_string_lossy(), "--to", "8"])
        .env("HOME", &machine.home)
        .stdin(Stdio::null())
        .output()
        .expect("follow runs");
    assert_eq!(out.status.code(), Some(0));
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("8\t{\"a\":1}\n"),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
}
