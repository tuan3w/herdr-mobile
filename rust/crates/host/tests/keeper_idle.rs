//! A client attached during a long agent turn sends nothing and must stay attached; a connection
//! that never sends a valid line must be closed. Checked against the real `herdr-host` keeper with
//! the scripted agent, and with a short idle limit (`HERDR_KEEPER_IDLE_MS`) so the keeper's sweep
//! is observed without a 30 s wait.
//!
//! Hermetic: its own HOME, no herdr, `HERDR_MOBILE_NO_PANE=1`; the keeper it starts is stopped by
//! pid. Every wait is a read with a timeout, so a bug fails the test instead of hanging it.

use acp::{Id, Message};
use keeper::records::StateDir;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The keeper's idle limit for this test: short, and far below `READ_LIMIT`.
const IDLE_MS: &str = "300";
/// How long a read may wait for something the keeper must do (a close, an update).
const READ_LIMIT: Duration = Duration::from_secs(15);

struct Host {
    _dir: tempfile::TempDir,
    home: PathBuf,
    started: Vec<i64>,
}

impl Host {
    fn new() -> Host {
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
        Host {
            _dir: dir,
            home,
            started: Vec::new(),
        }
    }

    fn start(&mut self, cwd: &Path) -> String {
        let path = format!("{}:/usr/bin:/bin", self._dir.path().join("bin").display());
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_herdr-host"));
        cmd.args(["start", "--agent", "omp", "--cwd"])
            .arg(cwd)
            .stdin(Stdio::null())
            .env("HOME", &self.home)
            .env("PATH", path)
            .env("HERDR_MOBILE_NO_PANE", "1")
            .env(keeper::spawn::IDLE_CLIENT_ENV, IDLE_MS);
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
        let out = cmd.output().expect("herdr-host runs");
        assert!(
            out.status.success(),
            "start failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let info: Value =
            serde_json::from_slice(out.stdout.split(|b| *b == b'\n').next().expect("a line"))
                .expect("start prints one JSON line");
        self.started.extend(
            ["pid", "agent_pid"]
                .iter()
                .filter_map(|k| info[*k].as_i64()),
        );
        info["id"].as_str().expect("an id").to_string()
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        for pid in &self.started {
            let _ = Command::new("kill").arg(pid.to_string()).status();
        }
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

/// A connection to the keeper's socket: a line writer and a line reader with a read timeout.
struct Conn {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Conn {
    fn open(dir: &StateDir, id: &str) -> Conn {
        let stream = dir.connect(id).expect("the keeper listens on <id>.sock");
        stream
            .set_read_timeout(Some(READ_LIMIT))
            .expect("a timeout guards the test");
        Conn {
            writer: stream.try_clone().expect("clone"),
            reader: BufReader::new(stream),
        }
    }

    fn send(&mut self, line: &str) {
        writeln!(self.writer, "{line}").expect("write");
    }

    /// The next line; `None` when the keeper closed the connection. A timeout is a failure.
    fn line(&mut self) -> Option<String> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => None,
            Ok(_) => Some(line),
            Err(e) => panic!("the keeper neither answered nor closed within {READ_LIMIT:?}: {e}"),
        }
    }

    /// Reads until the response to `id`; every other line on the way is returned too.
    fn until_response(&mut self, id: i64) -> Vec<Message> {
        let mut seen = Vec::new();
        loop {
            let line = self.line().expect("the keeper closed the connection");
            let msg = Message::parse(line.trim()).expect("the keeper speaks JSON-RPC");
            let done = matches!(&msg, Message::Response { id: Id::Num(n), .. } if *n == id);
            seen.push(msg);
            if done {
                return seen;
            }
        }
    }
}

fn initialize(id: i64) -> String {
    Message::request(
        id,
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": "test", "version": "0"}}),
    )
    .to_line()
}

fn new_session(id: i64, cwd: &Path) -> String {
    Message::request(
        id,
        "session/new",
        json!({"cwd": cwd.to_string_lossy(), "mcpServers": []}),
    )
    .to_line()
}

fn has_update(lines: &[Message], text: &str) -> bool {
    lines.iter().any(|m| match m {
        Message::Notification { method, params } => {
            method == "session/update" && params["update"]["content"]["text"] == text
        }
        _ => false,
    })
}

#[test]
fn a_silent_attached_client_stays_and_a_connection_that_never_speaks_goes() {
    let mut host = Host::new();
    let cwd = host.home.join("proj");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let id = host.start(&cwd);
    let dir = StateDir::create(&host.home).expect("the state dir");

    // The phone: attaches to the session, then says nothing while the agent works.
    let mut phone = Conn::open(&dir, &id);
    phone.send(&initialize(1));
    phone.until_response(1);
    phone.send(&new_session(2, &cwd));
    phone.until_response(2);

    // A connection that never sends a valid line (garbage, and JSON that is not JSON-RPC).
    let mut junk = Conn::open(&dir, &id);
    junk.send("this is not json");
    junk.send(r#"{"neither":"method nor id"}"#);
    // The keeper closes it: the read ends with EOF (a timeout panics). `born + limit` is later
    // than the phone's one line plus the limit, so by now the phone has been silent for longer
    // than the limit too.
    assert_eq!(
        junk.line(),
        None,
        "a connection with no valid line is closed"
    );

    // Another client drives a turn; the silent phone must still get the update.
    let mut driver = Conn::open(&dir, &id);
    driver.send(&initialize(1));
    driver.until_response(1);
    driver.send(&new_session(2, &cwd));
    driver.until_response(2);
    driver.send(
        &Message::request(
            3,
            "session/prompt",
            json!({"sessionId": "sess-1", "prompt": [{"type": "text", "text": "reply:hi"}]}),
        )
        .to_line(),
    );
    driver.until_response(3);

    // The phone still reads the update, without having sent anything since `initialize`.
    let mut seen = Vec::new();
    while !has_update(&seen, "re: hi") {
        let line = phone
            .line()
            .expect("the silent phone was dropped: its view would freeze");
        seen.push(Message::parse(line.trim()).expect("the keeper speaks JSON-RPC"));
    }
}
