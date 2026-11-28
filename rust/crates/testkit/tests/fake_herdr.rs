//! `fake-herdr` against what `app/benchmark/fake_herdr.py` did: one JSON request
//! per connection and one line back, seeded content that advances per read, an
//! event stream fed by `bench.emit`. The golden values below were recorded from
//! the python program, so the bytes (not just the shapes) are the same.

mod support;

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;
use support::Proc;
use tempfile::TempDir;

struct Herdr {
    _p: Proc,
    _dir: TempDir,
    sock: std::path::PathBuf,
}

impl Herdr {
    fn start() -> Herdr {
        let dir = tempfile::tempdir().expect("a temp dir");
        let sock = dir.path().join("herdr.sock");
        let p = Proc::spawn(
            &testkit::bin("fake-herdr"),
            &[sock.to_str().expect("utf-8 path")],
            &[],
            None,
        );
        assert_eq!(p.line().as_deref(), Some("READY"));
        Herdr {
            _p: p,
            _dir: dir,
            sock,
        }
    }

    /// One request on its own connection: the raw reply line (with its newline).
    fn raw(&self, request: &str) -> Vec<u8> {
        let mut c = UnixStream::connect(&self.sock).expect("connect");
        c.set_read_timeout(Some(support::WAIT)).expect("timeout");
        c.write_all(request.as_bytes()).expect("write");
        c.write_all(b"\n").expect("write");
        let mut out = Vec::new();
        let mut chunk = [0u8; 65536];
        while !out.ends_with(b"\n") {
            let n = c.read(&mut chunk).expect("read");
            if n == 0 {
                break;
            }
            out.extend_from_slice(&chunk[..n]);
        }
        out
    }

    fn call(&self, request: Value) -> Value {
        serde_json::from_slice(&self.raw(&request.to_string())).expect("a JSON reply")
    }

    fn read(&self, params: Value) -> Value {
        self.call(json!({"id": 1, "method": "pane.read", "params": params}))["result"]["read"]
            .clone()
    }
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[test]
fn replies_are_the_bytes_the_python_program_sent() {
    let h = Herdr::start();
    let snap = h.raw(r#"{"id":1,"method":"session.snapshot"}"#);
    assert_eq!((snap.len(), fnv1a64(&snap)), (55820, 0xc1f5_a659_8ef6_0d63));
    let read = h.raw(r#"{"id":2,"method":"pane.read","params":{"pane_id":"w0:p1","lines":6}}"#);
    assert_eq!(
        String::from_utf8(read).expect("utf-8"),
        concat!(
            r#"{"id":2,"result":{"type":"pane_read","read":{"pane_id":"w0:p1","workspace_id":"w0","tab_id":"w0:t1","source":"recent","format":"plain","text":"#,
            r#""  998 ● ● class agent let if tiếng socket let … ● pane state dẫn Future widget pane widget chào notify \r\n"#,
            r#"  999 const transport await tiếng notify → widget let if ● const socket ✓ if tiếng dẫn widget … dẫn \r\n"#,
            r#"⠋ working (0s)\r\n"#,
            r#"────────────────────────────────────────────────────────────────────────────────────────────────────\r\n"#,
            r#"> \r\ntokens 0  ctx 0%\r\n","truncated":false}}}"#,
            "\n"
        )
    );
    let ansi = h.raw(r#"{"id":3,"method":"pane.read","params":{"pane_id":"w5:p3","lines":40,"strip_ansi":false}}"#);
    assert_eq!((ansi.len(), fnv1a64(&ansi)), (19828, 0x2753_e757_4311_a3dd));
}

#[test]
fn ping_and_unknown_methods_echo_the_id() {
    let h = Herdr::start();
    assert_eq!(
        h.raw(r#"{"id":"abc","method":"ping"}"#),
        b"{\"id\":\"abc\",\"result\":{\"type\":\"pong\",\"version\":\"0.9.3\",\"protocol\":22}}\n"
    );
    let r = h.call(json!({"id": 7, "method": "frobnicate"}));
    assert_eq!(
        r,
        json!({"id": 7, "error": {"code": "invalid_request", "message": "unknown variant `frobnicate`"}})
    );
    // a request without an id is answered with a null one
    assert_eq!(h.call(json!({"method": "ping"}))["id"], Value::Null);
}

#[test]
fn a_connection_that_is_not_json_is_closed_without_a_reply() {
    let h = Herdr::start();
    assert!(h.raw("this is not json").is_empty());
    // and the server is fine afterwards
    assert_eq!(
        h.call(json!({"id": 1, "method": "ping"}))["result"]["type"],
        "pong"
    );
}

#[test]
fn the_snapshot_has_the_size_and_shape_of_herdrs_and_moves_each_time() {
    let h = Herdr::start();
    let first =
        h.call(json!({"id": 1, "method": "session.snapshot"}))["result"]["snapshot"].clone();
    assert_eq!(first["workspaces"].as_array().expect("workspaces").len(), 8);
    assert_eq!(first["tabs"].as_array().expect("tabs").len(), 8);
    assert_eq!(first["panes"].as_array().expect("panes").len(), 40);
    assert_eq!(first["layouts"].as_array().expect("layouts").len(), 8);
    assert_eq!(
        first["agents"].as_array().expect("agents").len(),
        30,
        "every pane with an agent"
    );
    assert_eq!(first["panes"][0]["pane_id"], "w0:p1");
    assert_eq!(first["panes"][3]["agent"], Value::Null);
    assert_eq!(
        first["panes"][3]["terminal_id"],
        format!("term_{:014x}", 3 * 7919)
    );
    let second =
        h.call(json!({"id": 2, "method": "session.snapshot"}))["result"]["snapshot"].clone();
    assert_ne!(
        first, second,
        "pane statuses and counters change with every snapshot"
    );
    assert_eq!(first["panes"][0]["pane_id"], second["panes"][0]["pane_id"]);
    let third_rev = h.call(json!({"id": 3, "method": "session.snapshot"}))["result"]["snapshot"]
        ["panes"][0]["revision"]
        .clone();
    let fourth_rev = h.call(json!({"id": 4, "method": "session.snapshot"}))["result"]["snapshot"]
        ["panes"][0]["revision"]
        .clone();
    assert_eq!(third_rev, json!(5), "4 + 3 / 3");
    assert_eq!(fourth_rev, json!(5));
}

#[test]
fn a_pane_advances_only_when_it_is_read_by_three_rows_per_read() {
    let h = Herdr::start();
    let a = h.read(json!({"pane_id": "w2:p3", "lines": 30}));
    let b = h.read(json!({"pane_id": "w2:p3", "lines": 30}));
    let rows = |r: &Value| -> Vec<String> {
        r["text"]
            .as_str()
            .expect("text")
            .split("\r\n")
            .map(str::to_string)
            .collect()
    };
    let (ra, rb) = (rows(&a), rows(&b));
    // 30 rows + the trailing empty piece of the final CRLF
    assert_eq!(ra.len(), 31);
    // body rows slide up by 3; the last four rows are the footer
    assert_eq!(&ra[3..26], &rb[0..23]);
    assert_ne!(ra[26..30], rb[26..30], "the footer changes on every read");
    assert!(ra[26].contains("working (0s)"));
    assert!(rb[26].contains("working (1s)"));
    // another pane has its own counter and its own text
    let other = h.read(json!({"pane_id": "w3:p3", "lines": 30}));
    assert!(rows(&other)[26].contains("working (0s)"));
    assert_ne!(rows(&other)[0], ra[0]);
    // the same pane in a fresh process starts from the same bytes
    let h2 = Herdr::start();
    assert_eq!(h2.read(json!({"pane_id": "w2:p3", "lines": 30})), a);
}

#[test]
fn pane_read_options() {
    let h = Herdr::start();
    let plain = h.read(json!({"pane_id": "w0:p1", "lines": 5}));
    assert_eq!(plain["format"], "plain");
    assert_eq!(plain["source"], "recent");
    assert_eq!(plain["workspace_id"], "w0");
    assert_eq!(plain["tab_id"], "w0:t1");
    assert_eq!(plain["truncated"], false);
    assert!(!plain["text"].as_str().expect("text").contains('\x1b'));
    let ansi =
        h.read(json!({"pane_id": "w0:p1", "lines": 5, "strip_ansi": false, "source": "visible"}));
    assert_eq!(ansi["format"], "ansi");
    assert_eq!(ansi["source"], "visible");
    assert!(ansi["text"].as_str().expect("text").contains('\x1b'));
    // `lines` defaults to and is capped at 1000
    let all = h.read(json!({"pane_id": "w1:p1"}));
    assert_eq!(
        all["text"].as_str().expect("text").matches("\r\n").count(),
        1000
    );
    let capped = h.read(json!({"pane_id": "w1:p1", "lines": 5000}));
    assert_eq!(
        capped["text"]
            .as_str()
            .expect("text")
            .matches("\r\n")
            .count(),
        1000
    );
    assert_eq!(
        h.read(json!({"pane_id": "w1:p1", "lines": 2}))["text"]
            .as_str()
            .expect("text")
            .matches("\r\n")
            .count(),
        2
    );
    assert_eq!(
        h.read(json!({"pane_id": "w1:p1", "lines": "3"}))["text"]
            .as_str()
            .expect("text")
            .matches("\r\n")
            .count(),
        3
    );
}

#[test]
fn an_unknown_pane_is_an_error() {
    let h = Herdr::start();
    let r = h.call(json!({"id": 9, "method": "pane.read", "params": {"pane_id": "w9:p9"}}));
    assert_eq!(
        r,
        json!({"id": 9, "error": {"code": "pane_not_found", "message": "pane w9:p9 not found"}})
    );
    let r = h.call(json!({"id": 9, "method": "pane.read", "params": {}}));
    assert_eq!(r["error"]["message"], "pane None not found");
}

#[test]
fn subscribers_get_pane_updated_events_for_bench_emit() {
    let h = Herdr::start();
    let mut sub = UnixStream::connect(&h.sock).expect("connect");
    sub.set_read_timeout(Some(support::WAIT)).expect("timeout");
    sub.write_all(b"{\"id\":\"s1\",\"method\":\"events.subscribe\"}\n")
        .expect("write");
    let mut got = Vec::new();
    let mut chunk = [0u8; 65536];
    let mut next_line = |got: &mut Vec<u8>| -> String {
        loop {
            if let Some(i) = got.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = got.drain(..=i).collect();
                return String::from_utf8(line)
                    .expect("utf-8")
                    .trim_end()
                    .to_string();
            }
            let n = sub.read(&mut chunk).expect("read");
            assert!(n > 0, "the subscription stays open");
            got.extend_from_slice(&chunk[..n]);
        }
    };
    assert_eq!(
        next_line(&mut got),
        r#"{"id":"s1","result":{"type":"subscription_started"}}"#
    );
    assert_eq!(
        h.call(json!({"id": 1, "method": "bench.emit", "params": {"count": 3}})),
        json!({"id": 1, "result": {"type": "ok"}})
    );
    for n in 0..3 {
        let ev: Value = serde_json::from_str(&next_line(&mut got)).expect("an event");
        assert_eq!(ev["event"], "pane_updated");
        assert_eq!(ev["data"]["type"], "pane_updated");
        let pane = &ev["data"]["pane"];
        assert_eq!(pane["revision"], 118_000 + n);
        assert_eq!(pane["pane_id"], format!("w{}:p{}", n % 8, n / 8 + 1));
        let spinner = ["⠋", "⠙", "⠹"][n as usize];
        assert!(pane["terminal_title"]
            .as_str()
            .expect("title")
            .contains(spinner));
    }
    // counts continue where they stopped, and a count of 0 emits nothing
    h.call(json!({"id": 2, "method": "bench.emit", "params": {"count": 0}}));
    h.call(json!({"id": 3, "method": "bench.emit"}));
    let ev: Value = serde_json::from_str(&next_line(&mut got)).expect("an event");
    assert_eq!(ev["data"]["pane"]["revision"], 118_003);
    // the event is the size of herdr's (~770 B)
    let line = serde_json::to_string(&ev).expect("json");
    assert!((600..900).contains(&line.len()), "{}", line.len());
    drop(sub);
}

#[test]
fn it_replaces_a_stale_socket_file_and_says_ready_only_when_listening() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let sock = dir.path().join("herdr.sock");
    std::fs::write(&sock, b"stale").expect("a stale file");
    let p = Proc::spawn(
        &testkit::bin("fake-herdr"),
        &[sock.to_str().expect("utf-8")],
        &[],
        None,
    );
    assert_eq!(p.line().as_deref(), Some("READY"));
    assert!(UnixStream::connect(&sock).is_ok());
    // without an argument it fails with usage
    let mut q = Proc::spawn(&testkit::bin("fake-herdr"), &[], &[], None);
    assert_eq!(q.wait().code(), Some(1));
    assert!(q.stderr().contains("usage"));
    assert!(q.line_within(Duration::from_millis(50)).is_none());
}
