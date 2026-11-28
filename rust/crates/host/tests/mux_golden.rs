//! `herdr.mux` and `herdr.events` against answers recorded from the python
//! mux the app used to ship (`fixtures/mux_golden.json`): the same requests
//! must give the same answers once a client has applied rows and delta ops.
//! Compared as decoded JSON, never as bytes.

mod common;

use common::{client_hello, golden, start_fake, Client, Item};
use host::backend::herdr::HerdrBackend;
use host::mux::MuxService;
use host::{Registry, SessionOptions};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use wire::{ErrorCode, Limits};

fn start_session(socket: Option<&Path>) -> (Client<UnixStream>, std::thread::JoinHandle<i32>) {
    let (client_end, server_end) = UnixStream::pair().expect("pair");
    let server_in = server_end.try_clone().expect("clone");
    let registry = Arc::new(Registry::new(vec![Arc::new(MuxService::new(
        HerdrBackend::new(),
    ))]));
    let options = SessionOptions {
        host: wire::HostInfo {
            version: "9.9.9".into(),
            os: "linux".into(),
            arch: "x86_64".into(),
            home: "/home/test".into(),
            hostname: "box".into(),
            user: "tester".into(),
        },
        home: "/home/test".into(),
        limits: Limits::default(),
        stall: Duration::from_secs(60),
        exit_on_write_error: false,
    };
    let server =
        std::thread::spawn(move || host::session::run(server_in, server_end, registry, options));
    let reader = client_end.try_clone().expect("clone");
    let client = Client::connect(reader, client_end, &client_hello(socket));
    (client, server)
}

fn finish(c: Client<UnixStream>, server: std::thread::JoinHandle<i32>) -> i32 {
    let _ = c.out.shutdown(std::net::Shutdown::Write);
    server.join().expect("server joins")
}

/// What the app's `MuxClient` does with a delta or rows answer.
struct Held {
    seq: u64,
    rows: Vec<String>,
}

fn apply_ops(old: &[String], ops: &Value) -> Vec<String> {
    let mut rows = Vec::new();
    for op in ops.as_array().expect("ops are a list") {
        let op = op.as_array().expect("an op is a list");
        if let Some(start) = op[0].as_u64() {
            let (start, count) = (start as usize, op[1].as_u64().expect("count") as usize);
            rows.extend_from_slice(&old[start..start + count]);
        } else {
            rows.extend(op.iter().map(|r| r.as_str().expect("row").to_string()));
        }
    }
    rows
}

fn snapshot_from_rows(rows: &[String]) -> Value {
    let mut lists: HashMap<char, Vec<Value>> = HashMap::new();
    for row in &rows[1..] {
        let letter = row.chars().next().expect("a letter");
        lists
            .entry(letter)
            .or_default()
            .push(serde_json::from_str(&row[1..]).expect("row JSON"));
    }
    let take = |letter: char| Value::Array(lists.get(&letter).cloned().unwrap_or_default());
    json!({"version": &rows[0][1..], "workspaces": take('w'), "tabs": take('t'), "panes": take('p')})
}

/// Rebuilds the whole answer of `request` from `response`, remembering what
/// the next request may name. Returns whether the answer was a delta.
fn resolve(held: &mut HashMap<String, Held>, request: &Value, response: &mut Value) -> bool {
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(method, "pane.read" | "session.snapshot") || response.get("result").is_none() {
        return false;
    }
    let key = format!("{method}{}", host::mux::canonical(&request["params"]));
    let snap = method == "session.snapshot";
    let seq = response["seq"].as_u64();
    let result = response["result"].as_object_mut().expect("result");
    let boxed = result
        .get_mut(if snap { "snapshot" } else { "read" })
        .expect("box");
    let mut was_delta = false;
    let rows: Option<Vec<String>> = if boxed.get("delta").is_some() {
        let basis = held
            .get(&key)
            .expect("a delta answers a request that named a held answer");
        assert_eq!(boxed["delta"]["base"].as_u64(), Some(basis.seq));
        let rows = apply_ops(&basis.rows, &boxed["delta"]["o"]);
        was_delta = true;
        if !snap {
            boxed.as_object_mut().expect("read").remove("delta");
            boxed["text"] = json!(rows.join("\n"));
        }
        Some(rows)
    } else if snap {
        Some(
            boxed["rows"]
                .as_array()
                .expect("rows")
                .iter()
                .map(|r| r.as_str().expect("row").to_string())
                .collect(),
        )
    } else {
        match (boxed.get("text").and_then(Value::as_str), seq) {
            (Some(text), Some(_)) => Some(text.split('\n').map(str::to_string).collect()),
            _ => None,
        }
    };
    if snap {
        *boxed = snapshot_from_rows(rows.as_ref().expect("rows"));
    }
    if let (Some(rows), Some(seq)) = (rows, seq) {
        held.insert(key, Held { seq, rows });
    }
    was_delta
}

#[test]
fn the_recorded_requests_get_the_recorded_answers_once_deltas_are_applied() {
    let golden = golden();
    let dir = tempfile::tempdir().expect("dir");
    let fake = start_fake(&dir.path().join("herdr.sock"), &golden);
    let (mut c, server) = start_session(Some(&fake.path));
    assert!(
        c.hello.services["herdr"].available,
        "{:?}",
        c.hello.services
    );

    let mut args = golden["args"].clone();
    args["session"] = json!("default");
    let id = c.open("herdr", "mux", &args, false);
    assert_eq!(
        c.msg(id),
        json!({"ready": true}),
        "the host says when it is ready"
    );

    let mut held = HashMap::new();
    let mut deltas = 0;
    for step in golden["mux"].as_array().expect("steps") {
        let name = step["name"].as_str().expect("name");
        c.send_msg(id, &step["request"]);
        let mut got = c.msg(id);
        let was_delta = resolve(&mut held, &step["request"], &mut got);
        assert_eq!(got, step["expect"], "step {name:?}");
        assert_eq!(
            was_delta,
            step["delta"].as_bool().expect("delta flag"),
            "step {name:?}: delta or whole"
        );
        deltas += usize::from(was_delta);
    }
    assert!(
        deltas >= 2,
        "the fixture exercises a snapshot delta and a read delta"
    );

    c.end(id);
    assert!(c.ended(id).is_ok());
    assert_eq!(finish(c, server), 0);
    let seen = fake.requests.lock().expect("seen");
    assert!(
        seen.iter().all(|r| r.get("mux_have").is_none()),
        "mux_have is the mux's business, herdr never sees it"
    );
}

#[test]
fn the_recorded_events_arrive_pruned_after_the_ack() {
    let golden = golden();
    let dir = tempfile::tempdir().expect("dir");
    let fake = start_fake(&dir.path().join("herdr.sock"), &golden);
    let (mut c, server) = start_session(Some(&fake.path));
    let events = &golden["events"];
    let args = json!({"session": "default", "subscriptions": events["subscriptions"], "projection": events["projection"]});
    let id = c.open("herdr", "events", &args, true);
    assert_eq!(c.msg(id), events["ack"]);
    for (i, want) in events["events"]
        .as_array()
        .expect("events")
        .iter()
        .enumerate()
    {
        assert_eq!(&c.msg(id), want, "event {i}");
    }
    let subscribe = fake
        .requests
        .lock()
        .expect("seen")
        .iter()
        .find(|r| r["method"] == "events.subscribe")
        .cloned()
        .expect("the host subscribed");
    assert_eq!(
        subscribe["params"],
        json!({"subscriptions": events["subscriptions"]})
    );
    // The client leaving ends the stream (the host hangs up on herdr).
    c.end(id);
    assert!(c.ended(id).is_ok());
    assert_eq!(finish(c, server), 0);
}

/// A herdr that answers every connection's request with a pong carrying the
/// id it was sent, like the real one.
fn start_echo_herdr(path: &Path) {
    let listener = UnixListener::bind(path).expect("bind the echo herdr");
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(conn) = conn else { return };
            std::thread::spawn(move || {
                let mut line = String::new();
                if BufReader::new(&conn).read_line(&mut line).unwrap_or(0) == 0 {
                    return;
                }
                let Ok(request) = serde_json::from_str::<Value>(&line) else {
                    return;
                };
                let answer = json!({"id": request["id"], "result": {"type": "pong"}});
                let _ = (&conn).write_all(format!("{answer}\n").as_bytes());
            });
        }
    });
}

#[test]
fn requests_in_flight_together_each_get_their_own_answer() {
    let dir = tempfile::tempdir().expect("dir");
    let sock = dir.path().join("herdr.sock");
    start_echo_herdr(&sock);
    let (mut c, server) = start_session(Some(&sock));
    let id = c.open("herdr", "mux", &json!({}), false);
    assert_eq!(c.msg(id), json!({"ready": true}));
    let sent: Vec<String> = (0..10).map(|n| format!("p{n}")).collect();
    for request in &sent {
        c.send_msg(id, &json!({"id": request, "method": "ping", "params": {}}));
    }
    let mut got = Vec::new();
    for _ in 0..10 {
        let answer = c.msg(id);
        assert_eq!(answer["result"], json!({"type": "pong"}), "{answer}");
        got.push(answer["id"].as_str().expect("id").to_string());
    }
    got.sort();
    assert_eq!(got, sent, "one answer per request, each with its own id");
    c.end(id);
    assert!(c.ended(id).is_ok());
    assert_eq!(finish(c, server), 0);
}

#[test]
fn a_herdr_that_hangs_up_gives_that_request_a_bridge_error() {
    let golden = golden();
    let dir = tempfile::tempdir().expect("dir");
    // The golden fake has one recorded answer for ping; the second ping finds
    // none and gets a closed connection.
    let fake = start_fake(&dir.path().join("herdr.sock"), &golden);
    let (mut c, server) = start_session(Some(&fake.path));
    let id = c.open("herdr", "mux", &golden["args"], false);
    assert_eq!(c.msg(id), json!({"ready": true}));
    c.send_msg(id, &json!({"id": "m0", "method": "ping", "params": {}}));
    assert_eq!(c.msg(id)["result"]["type"], "pong");
    c.send_msg(id, &json!({"id": "m1", "method": "ping", "params": {}}));
    assert_eq!(
        c.msg(id),
        json!({"id": "m1", "error": {"code": "bridge_error", "message": "herdr closed the connection without answering"}})
    );
    c.end(id);
    assert!(c.ended(id).is_ok());
    assert_eq!(finish(c, server), 0);
}

#[test]
fn without_a_socket_the_hello_says_why_and_opening_the_mux_is_unavailable() {
    let dir = tempfile::tempdir().expect("dir");
    let missing = dir.path().join("herdr.sock");
    let (mut c, server) = start_session(Some(&missing));
    let status = &c.hello.services["herdr"];
    assert!(!status.available);
    let reason = status.reason.clone().expect("a reason");
    assert_eq!(
        reason,
        format!(
            "no herdr socket at {} for session default",
            missing.display()
        )
    );
    for method in ["mux", "events"] {
        let id = c.open(
            "herdr",
            method,
            &json!({"subscriptions": []}),
            method == "events",
        );
        let err = c.ended(id).expect_err("unavailable");
        assert_eq!(err.code, ErrorCode::Unavailable, "{method}");
        assert_eq!(err.message, reason);
    }
    assert_eq!(finish(c, server), 0);
}

#[test]
fn a_bad_args_object_is_a_bad_request_not_a_crash() {
    let golden = golden();
    let dir = tempfile::tempdir().expect("dir");
    let fake = start_fake(&dir.path().join("herdr.sock"), &golden);
    let (mut c, server) = start_session(Some(&fake.path));
    let id = c.open("herdr", "mux", &json!({"projections": 5}), false);
    assert_eq!(c.ended(id).expect_err("bad").code, ErrorCode::BadRequest);
    let id = c.open("herdr", "nope", &json!({}), false);
    assert_eq!(
        c.ended(id).expect_err("unknown").code,
        ErrorCode::UnknownMethod
    );
    assert!(matches!(
        c.try_item(id, Duration::from_millis(50)),
        None | Some(Item::End(_))
    ));
    assert_eq!(finish(c, server), 0);
}
