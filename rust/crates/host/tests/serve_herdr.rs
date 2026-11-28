//! The real `herdr-host serve` binary on pipes with a fake herdr socket in a
//! tempdir `HOME`/`XDG_CONFIG_HOME`: the `herdr` service offered in the HELLO
//! according to whether a socket is there, and `herdr.mux` / `herdr.events`
//! answering through it.

mod common;

use common::{client_hello, golden, start_fake, Client};
use serde_json::{json, Value};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};
use wire::ErrorCode;

struct Serve {
    child: Child,
    client: Client<ChildStdin>,
}

fn serve(home: &Path, xdg: &Path, session: &str) -> Serve {
    let mut child = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("serve")
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", xdg)
        .env_remove("HERDR_SOCKET_PATH")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn herdr-host serve");
    let stdin = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");
    let mut hello = client_hello(None);
    hello.herdr.session = session.to_string();
    let client = Client::connect(stdout, stdin, &hello);
    Serve { child, client }
}

impl Serve {
    /// Closes stdin and returns the exit code, killing the process (our own
    /// child) if it does not leave within the deadline.
    fn finish(self) -> Option<i32> {
        let Self { mut child, client } = self;
        drop(client);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(status) = child.try_wait().expect("wait") {
                return status.code();
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn step<'a>(golden: &'a Value, name: &str) -> &'a Value {
    golden["mux"]
        .as_array()
        .expect("steps")
        .iter()
        .find(|s| s["name"] == name)
        .unwrap_or_else(|| panic!("no step {name}"))
}

#[test]
fn herdr_mux_and_events_work_through_the_real_binary() {
    let golden = golden();
    let home = tempfile::tempdir().expect("home");
    let xdg = home.path().join("xdg");
    let fake = start_fake(&xdg.join("herdr/herdr.sock"), &golden);
    let mut s = serve(home.path(), &xdg, "default");
    let status = &s.client.hello.services["herdr"];
    assert!(status.available, "{status:?}");

    let c = &mut s.client;
    let mux = c.open("herdr", "mux", &golden["args"], false);
    assert_eq!(c.msg(mux), json!({"ready": true}));
    let ping = step(&golden, "ping");
    c.send_msg(mux, &ping["request"]);
    assert_eq!(c.msg(mux), ping["expect"]);

    let events = &golden["events"];
    let args =
        json!({"subscriptions": events["subscriptions"], "projection": events["projection"]});
    let feed = c.open("herdr", "events", &args, true);
    assert_eq!(c.msg(feed), events["ack"]);
    for want in events["events"].as_array().expect("events") {
        assert_eq!(&c.msg(feed), want);
    }
    assert!(fake.requests.lock().expect("seen").len() >= 2);
    assert_eq!(s.finish(), Some(0));
}

#[test]
fn a_named_session_is_found_under_sessions_and_the_default_one_is_not_confused_with_it() {
    let golden = golden();
    let home = tempfile::tempdir().expect("home");
    let xdg = home.path().join("xdg");
    let _fake = start_fake(&xdg.join("herdr/sessions/work/herdr.sock"), &golden);
    let s = serve(home.path(), &xdg, "work");
    assert!(s.client.hello.services["herdr"].available);
    assert_eq!(s.finish(), Some(0));

    let s = serve(home.path(), &xdg, "default");
    let status = &s.client.hello.services["herdr"];
    assert!(!status.available);
    assert_eq!(
        status.reason.as_deref(),
        Some(
            format!(
                "no herdr socket at {}/herdr/herdr.sock for session default",
                xdg.display()
            )
            .as_str()
        )
    );
    assert_eq!(s.finish(), Some(0));
}

#[test]
fn with_no_herdr_socket_the_hello_says_why_and_the_mux_is_unavailable() {
    let home = tempfile::tempdir().expect("home");
    let xdg = home.path().join("xdg");
    let mut s = serve(home.path(), &xdg, "default");
    let reason = {
        let status = &s.client.hello.services["herdr"];
        assert!(!status.available);
        status.reason.clone().expect("a reason")
    };
    assert!(reason.starts_with("no herdr socket at "), "{reason}");
    assert!(reason.ends_with("for session default"), "{reason}");

    let id = s.client.open("herdr", "mux", &json!({}), false);
    let err = s.client.ended(id).expect_err("unavailable");
    assert_eq!(err.code, ErrorCode::Unavailable);
    assert_eq!(err.message, reason);
    assert_eq!(s.finish(), Some(0));
}

#[test]
fn the_catalog_lists_the_herdr_service() {
    let out = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("api")
        .output()
        .expect("api");
    let catalog: Value = serde_json::from_slice(&out.stdout).expect("catalog JSON");
    let herdr = catalog["services"]
        .as_array()
        .and_then(|s| s.iter().find(|s| s["name"] == "herdr"))
        .expect("a herdr service");
    let methods: Vec<&str> = herdr["methods"]
        .as_array()
        .expect("methods")
        .iter()
        .filter_map(|m| m["name"].as_str())
        .collect();
    assert_eq!(methods, ["mux", "events"]);
}

/// A herdr socket whose `events.subscribe` answers with `ack` and then the
/// `lines`, and stays open.
fn start_feed(path: &Path, lines: Vec<String>) {
    use std::io::{BufRead, BufReader, Write};
    std::fs::create_dir_all(path.parent().expect("dir")).expect("socket dir");
    let listener = std::os::unix::net::UnixListener::bind(path).expect("bind");
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(conn) = conn else { return };
            let lines = lines.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(&conn);
                let mut request = String::new();
                if reader.read_line(&mut request).unwrap_or(0) == 0 {
                    return;
                }
                let mut out = &conn;
                let _ = out.write_all(
                    b"{\"id\":\"events\",\"result\":{\"type\":\"subscription_started\"}}\n",
                );
                for line in &lines {
                    let _ = out.write_all(format!("{line}\n").as_bytes());
                }
                let mut rest = String::new();
                while reader.read_line(&mut rest).unwrap_or(0) > 0 {
                    rest.clear();
                }
            });
        }
    });
}

#[test]
fn coalesce_ms_collapses_a_burst_of_identical_pane_updates_and_keeps_order_around_other_events() {
    let pane = |n: usize, status: &str| {
        json!({"event": "pane_updated", "data": {"type": "pane_updated", "pane": {
            "pane_id": "w1:p1", "agent_status": status,
            "terminal_title": format!("spinner {n}"), "revision": 100 + n,
        }}})
        .to_string()
    };
    let status = |what: &str| {
        json!({"event": what, "data": {"type": what, "pane_id": "w1:p1", "agent_status": "idle"}})
            .to_string()
    };
    let mut lines: Vec<String> = (0..10).map(|n| pane(n, "working")).collect();
    lines.push(status("pane_agent_status_changed"));
    lines.push(pane(11, "idle"));
    lines.push(pane(12, "idle"));
    lines.push(status("pane_closed"));

    let home = tempfile::tempdir().expect("home");
    let xdg = home.path().join("xdg");
    start_feed(&xdg.join("herdr/herdr.sock"), lines);
    let mut s = serve(home.path(), &xdg, "default");
    let projection =
        json!({"event": true, "data": {"pane": {"pane_id": true, "agent_status": true}}});
    // 5 s: far longer than the test runs, so only the rules below can send.
    let args = json!({
        "subscriptions": [{"type": "pane.updated"}],
        "projection": projection,
        "coalesce_ms": 5000,
    });
    let c = &mut s.client;
    let feed = c.open("herdr", "events", &args, true);
    assert_eq!(
        c.msg(feed),
        json!({"id": "events", "result": {"type": "subscription_started"}})
    );
    let upd = |status: &str| json!({"event": "pane_updated", "data": {"pane": {"pane_id": "w1:p1", "agent_status": status}}});
    // ten identical updates are one (the leading edge)
    assert_eq!(c.msg(feed), upd("working"));
    // the status event is not delayed (the projection cut its data to {}); nothing was held
    assert_eq!(
        c.msg(feed),
        json!({"event": "pane_agent_status_changed", "data": {}})
    );
    // two identical updates inside the window are held; the next event flushes the latest first
    assert_eq!(c.msg(feed), upd("idle"));
    assert_eq!(c.msg(feed), json!({"event": "pane_closed", "data": {}}));
    assert!(
        c.try_item(feed, Duration::from_millis(300)).is_none(),
        "nothing else: 14 events in, 4 out"
    );
    assert_eq!(s.finish(), Some(0));
}

#[test]
fn a_held_pane_update_is_sent_when_its_window_ends_without_another_event() {
    let pane = |n: usize| {
        json!({"event": "pane_updated", "data": {"pane": {"pane_id": "w1:p1", "terminal_title": format!("t{n}")}}})
            .to_string()
    };
    let home = tempfile::tempdir().expect("home");
    let xdg = home.path().join("xdg");
    start_feed(
        &xdg.join("herdr/herdr.sock"),
        vec![pane(1), pane(2), pane(3)],
    );
    let mut s = serve(home.path(), &xdg, "default");
    let args = json!({"subscriptions": [], "coalesce_ms": 100});
    let c = &mut s.client;
    let feed = c.open("herdr", "events", &args, true);
    c.msg(feed);
    let title = |v: &Value| v["data"]["pane"]["terminal_title"].clone();
    assert_eq!(title(&c.msg(feed)), json!("t1"));
    // t2 is replaced by t3 while held; the host wakes at the deadline (no
    // other event arrives) and sends the latest.
    assert_eq!(title(&c.msg(feed)), json!("t3"));
    assert!(c.try_item(feed, Duration::from_millis(300)).is_none());
    assert_eq!(s.finish(), Some(0));
}

#[test]
fn a_bad_coalesce_ms_is_a_bad_request() {
    let home = tempfile::tempdir().expect("home");
    let xdg = home.path().join("xdg");
    start_feed(&xdg.join("herdr/herdr.sock"), Vec::new());
    let mut s = serve(home.path(), &xdg, "default");
    let id = s.client.open(
        "herdr",
        "events",
        &json!({"subscriptions": [], "coalesce_ms": "fast"}),
        true,
    );
    let err = s.client.ended(id).expect_err("bad args");
    assert_eq!(err.code, ErrorCode::BadRequest);
    assert_eq!(s.finish(), Some(0));
}
