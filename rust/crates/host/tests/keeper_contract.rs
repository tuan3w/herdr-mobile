//! What `herdr-tui` and the app rely on from the keeper, checked against the real thing: the
//! built `herdr-host` binary run with a scripted agent. A change that breaks the desk client or the
//! phone fails here, so the viewer is updated with it instead of finding out in use.
//!
//! Hermetic: its own HOME, no herdr (`HERDR_*` removed, `HERDR_MOBILE_NO_PANE=1`), and every process
//! it starts is stopped by pid. The scripted agent is testkit's `fake-acp-agent`.

use acp::{Id, Message};
use keeper::records::{is_valid_id, State, StateDir};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// An isolated machine: a home, a `bin` with a scripted `omp`, and the built
/// `herdr-host` keeper. The keeper is the Rust binary; the agent it starts is
/// the scripted `omp` (testkit's `fake-acp-agent`, not the keeper).
struct Host {
    _dir: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
    keeper: PathBuf,
    started: Vec<i64>,
}

impl Host {
    fn new() -> Host {
        // The keeper under test is the binary cargo built for this crate.
        let keeper = PathBuf::from(env!("CARGO_BIN_EXE_herdr-host"));
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
        std::process::Command::new("chmod")
            .arg("755")
            .arg(&omp)
            .status()
            .expect("chmod");
        Host {
            _dir: dir,
            home,
            bin,
            keeper,
            started: Vec::new(),
        }
    }

    /// Runs a keeper command the way `herdr-tui` does: no herdr, no second pane.
    fn run(&self, args: &[&str]) -> std::process::Output {
        // Never a real agent: `claude`, `codex` and `pi` have an npx fallback that would download and
        // start one. Only the scripted `omp`, or a name that is refused before anything starts.
        if let Some(at) = args.iter().position(|a| *a == "--agent") {
            assert!(
                matches!(args.get(at + 1), Some(&"omp" | &"nope")),
                "a contract test must not start a real agent: {args:?}"
            );
        }
        // Only the scripted bin and the system: the real PATH holds the owner's real agents.
        let path = format!("{}:/usr/bin:/bin", self.bin.display());
        let mut cmd = Command::new(&self.keeper);
        cmd.args(args)
            .stdin(Stdio::null())
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
        cmd.output().expect("herdr-host runs")
    }

    fn start(&mut self, cwd: &Path) -> Value {
        let out = self.run(&["start", "--agent", "omp", "--cwd", &cwd.to_string_lossy()]);
        assert!(
            out.status.success(),
            "start failed ({:?}): {}",
            out.status.code(),
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
        info
    }
}

impl Drop for Host {
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

/// Reads lines until the response to `id`, collecting every notification on the way.
fn exchange(reader: &mut impl BufRead, id: i64) -> (Value, Vec<Message>) {
    let mut notes = Vec::new();
    loop {
        let mut line = String::new();
        assert!(
            reader.read_line(&mut line).expect("the keeper answers") > 0,
            "the keeper closed the connection"
        );
        match Message::parse(line.trim()).expect("the keeper speaks JSON-RPC") {
            Message::Response {
                id: Id::Num(n),
                outcome,
            } if n == id => return (outcome.expect("no error"), notes),
            other => notes.push(other),
        }
    }
}

#[test]
fn start_gives_what_the_viewer_reads_and_a_session_round_trips_through_the_keeper() {
    let mut host = Host::new();
    let cwd = host.home.join("proj");
    std::fs::create_dir_all(&cwd).expect("cwd");
    let info = host.start(&cwd);

    // `start` prints the keeper's record: what `herdr-tui` reads to attach.
    let id = info["id"].as_str().expect("an id").to_string();
    assert!(is_valid_id(&id), "{id}");
    assert_eq!(info["agent"], "omp");
    assert!(
        info["pid"].as_i64().is_some() && info["state"] == "running",
        "{info}"
    );

    // The wire: initialize as a viewer, create the session, prompt, get the update and the answer.
    let dir = StateDir::create(&host.home).expect("the state dir");
    let stream = dir.connect(&id).expect("the keeper listens on <id>.sock");
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .expect("a timeout guards the test");
    let mut writer = stream.try_clone().expect("clone");
    let mut reader = BufReader::new(stream);
    let mut send = |m: &Message| writeln!(writer, "{}", m.to_line()).expect("write");

    send(&Message::request(
        1,
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": "herdr-tui", "title": "Terminal on test", "version": "0"}, "_meta": {"herdr": {"viewer": true}}}),
    ));
    let (init, _) = exchange(&mut reader, 1);
    assert_eq!(init["protocolVersion"], 1, "{init}");

    send(&Message::request(
        2,
        "session/new",
        json!({"cwd": cwd.to_string_lossy(), "mcpServers": []}),
    ));
    let (made, _) = exchange(&mut reader, 2);
    assert_eq!(made["sessionId"], "sess-1", "{made}");

    send(&Message::request(
        3,
        "session/prompt",
        json!({"sessionId": "sess-1", "prompt": [{"type": "text", "text": "reply:hi"}]}),
    ));
    let (done, notes) = exchange(&mut reader, 3);
    assert_eq!(done["stopReason"], "end_turn");
    let chunk = notes.iter().find_map(|m| match m {
        Message::Notification { method, params } if method == "session/update" => params["update"]
            ["content"]["text"]
            .as_str()
            .map(str::to_string),
        _ => None,
    });
    assert_eq!(
        chunk.as_deref(),
        Some("re: hi"),
        "the agent's update reaches the viewer: {notes:?}"
    );

    // The record the phone and `herdr-tui attach` use: the session id, set by whoever created it.
    let record = dir.read(&id).expect("the record");
    assert_eq!(record.session_id.as_deref(), Some("sess-1"), "{record:?}");
    assert_eq!(record.state, State::Running);
    assert_eq!(record.agent, "omp");
}

#[test]
fn the_exit_codes_the_viewer_maps_to_words_are_the_ones_the_keeper_gives() {
    let host = Host::new();
    let code = |args: &[&str]| host.run(args).status.code();
    assert_eq!(
        code(&["start", "--agent", "nope", "--cwd", "/tmp"]),
        Some(keeper::exit::USAGE),
        "an unknown agent"
    );
    assert_eq!(
        code(&["start", "--agent", "omp", "--cwd", "/definitely/not/here"]),
        Some(keeper::exit::GONE),
        "a missing folder"
    );
    // An agent that is not installed. Only `omp` has no npx fallback, so this can never start a
    // real agent: the scripted one is taken away first.
    std::fs::remove_file(host.bin.join("omp")).expect("remove the scripted omp");
    assert_eq!(
        code(&["start", "--agent", "omp", "--cwd", "/tmp"]),
        Some(keeper::exit::MISSING),
        "an agent that is not installed"
    );
    assert_eq!(code(&[]), Some(keeper::exit::USAGE), "no command");
}

#[test]
fn the_keeper_lists_the_agents_it_can_run_by_the_ids_the_viewer_offers() {
    let host = Host::new();
    let out = host.run(&["probe"]);
    assert!(out.status.success());
    let probe: Value = serde_json::from_slice(&out.stdout).expect("probe prints JSON");
    // The keeper found the scripted omp, and every agent it reports is one of ours: the route table
    // it was built with names the same agents as ours. (Others appear when `npx` is installed.)
    let known: Vec<String> = keeper::routes::all().into_iter().map(|r| r.id).collect();
    let routes: Vec<&str> = probe["routes"]
        .as_array()
        .expect("a list")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert!(routes.contains(&"omp"), "{probe}");
    assert!(
        routes.iter().all(|r| known.iter().any(|k| k == r)),
        "{probe}"
    );
}

/// The app's agent table, read from its Dart source: `(id, binary, npx package, args)`.
fn dart_routes() -> Vec<(String, String, Option<String>, Vec<String>)> {
    let src = std::fs::read_to_string(repo().join("app/lib/data/acp/agent_host.dart"))
        .expect("agent_host.dart");
    let table = src
        .split("const agentRoutes")
        .nth(1)
        .expect("the route table");
    let field = |chunk: &str, key: &str| -> Option<String> {
        let rest = chunk.split(&format!("{key}: '")).nth(1)?;
        Some(rest.split('\'').next()?.to_string())
    };
    table
        .split("AgentRoute(")
        .skip(1)
        .filter_map(|chunk| {
            let chunk = chunk.split("AgentRoute(").next()?;
            let args = chunk
                .split("args: [")
                .nth(1)
                .and_then(|a| a.split(']').next())
                .map(|a| {
                    a.split(',')
                        .filter_map(|x| {
                            x.trim()
                                .strip_prefix('\'')
                                .and_then(|x| x.strip_suffix('\''))
                                .map(str::to_string)
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some((
                field(chunk, "id")?,
                field(chunk, "binary")?,
                field(chunk, "npxPackage"),
                args,
            ))
        })
        .collect()
}

#[test]
fn our_agent_table_is_the_apps() {
    let ours: Vec<_> = keeper::routes::all()
        .into_iter()
        .map(|r| (r.id, r.binary, r.npx, r.args))
        .collect();
    assert_eq!(ours, dart_routes(), "rust/crates/keeper/routes.json and agentRoutes in agent_host.dart must list the same agents; update routes.json");
}
