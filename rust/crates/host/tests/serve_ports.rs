//! `ports` and `made` through the real `herdr-host serve` on pipes, with
//! sockets this test binds itself. Every wait is bounded by the client's
//! timeout, so a bug fails the test instead of hanging it.

mod common;

use common::{client_hello, Client, Item};
use serde_json::{json, Value};
use std::net::TcpListener;
use std::process::{Child, ChildStdin, Command, Stdio};
use wire::{ErrorCode, WireError};

struct Serve {
    client: Client<ChildStdin>,
    child: Child,
    _home: tempfile::TempDir,
}

impl Drop for Serve {
    fn drop(&mut self) {
        // This test started the child; this is the only process it ends.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn serve() -> Serve {
    let home = tempfile::tempdir().expect("home");
    let mut child = Command::new(env!("CARGO_BIN_EXE_herdr-host"))
        .arg("serve")
        .env("HOME", home.path())
        .env_remove("HERDR_SOCKET_PATH")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn herdr-host serve");
    let stdin = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");
    let client = Client::connect(stdout, stdin, &client_hello(None));
    Serve {
        client,
        child,
        _home: home,
    }
}

impl Serve {
    /// One call: its MSG, or the error it ended with.
    fn call(&mut self, svc: &str, method: &str, args: &Value) -> Result<Value, WireError> {
        let id = self.client.open(svc, method, args, false);
        match self.client.item(id) {
            Item::Msg(v) => {
                self.client.ended(id)?;
                Ok(v)
            }
            Item::End(v) => Err(WireError::from_end(&v).expect("an END without a MSG is an error")),
            other => panic!("unexpected {other:?}"),
        }
    }

    fn ports_available(&self) -> bool {
        self.client.hello.services["ports"].available
    }
}

fn bound() -> (TcpListener, u16) {
    let l = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = l.local_addr().expect("addr").port();
    (l, port)
}

/// A port nothing listens on right now.
fn closed_port() -> u16 {
    bound().1
}

fn has_port(listeners: &Value, port: u16) -> bool {
    listeners
        .as_array()
        .is_some_and(|a| a.iter().any(|l| l["port"] == port))
}

#[test]
fn the_hello_says_which_mechanism_lists_ports() {
    let s = serve();
    let ports = &s.client.hello.services["ports"];
    if cfg!(target_os = "linux") {
        assert!(ports.available);
        assert_eq!(ports.extra["source"], "proc");
    }
    assert!(s.client.hello.services["made"].available);
}

#[cfg(target_os = "linux")]
#[test]
fn list_finds_a_socket_this_test_bound_and_names_this_process_as_its_owner() {
    let (_listener, port) = bound();
    let mut s = serve();
    let out = s.call("ports", "list", &json!({})).expect("list");
    assert_eq!(out["source"], "proc");
    let mine = out["listeners"]
        .as_array()
        .expect("array")
        .iter()
        .find(|l| l["port"] == port)
        .expect("the bound port is listed");
    assert_eq!(mine["family"], 4);
    assert_eq!(mine["addr"], "127.0.0.1");
    assert_eq!(mine["pid"], std::process::id());
    assert!(!mine["process"].as_str().expect("process name").is_empty());
    assert!(!mine["user"].as_str().expect("user").is_empty());
}

#[test]
fn watch_sends_the_list_then_only_what_opened_and_closed() {
    let (_first, first_port) = bound();
    let mut s = serve();
    if !s.ports_available() {
        return;
    }
    let id = s
        .client
        .open("ports", "watch", &json!({"interval_ms": 1000}), false);
    let initial = s.client.msg(id);
    assert!(has_port(&initial["listeners"], first_port), "{initial}");

    // Bound only after the watch started, so it can only arrive as a change.
    let (second, second_port) = bound();
    loop {
        let change = s.client.msg(id);
        assert!(
            change.get("listeners").is_none(),
            "after the first message only changes: {change}"
        );
        if has_port(&change["opened"], second_port) {
            break;
        }
    }
    drop(second);
    loop {
        let change = s.client.msg(id);
        if has_port(&change["closed"], second_port) {
            assert!(!has_port(&change["opened"], second_port));
            break;
        }
    }
    s.client.end(id);
    // Changes already in flight may arrive before the END.
    loop {
        match s.client.item(id) {
            Item::Msg(_) => {}
            Item::End(v) => {
                assert!(
                    WireError::from_end(&v).is_none(),
                    "a watch ends cleanly: {v}"
                );
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
}

#[test]
fn watch_refuses_an_interval_under_one_second() {
    let mut s = serve();
    if !s.ports_available() {
        return;
    }
    let id = s
        .client
        .open("ports", "watch", &json!({"interval_ms": 999}), false);
    assert_eq!(
        s.client.ended(id).expect_err("refused").code,
        ErrorCode::BadRequest
    );
}

#[test]
fn probe_sees_open_and_closed_loopback_ports_and_refuses_everything_else() {
    let (_listener, port) = bound();
    let gone = closed_port();
    let mut s = serve();
    assert_eq!(
        s.call("ports", "probe", &json!({"port": port}))
            .expect("probe")["open"],
        true
    );
    assert_eq!(
        s.call(
            "ports",
            "probe",
            &json!({"port": port, "host": "127.0.0.1"})
        )
        .expect("probe")["open"],
        true
    );
    assert_eq!(
        s.call("ports", "probe", &json!({"port": gone}))
            .expect("probe")["open"],
        false
    );
    for args in [
        json!({"port": port, "host": "8.8.8.8"}),
        json!({"port": port, "host": "localhost"}),
        json!({"port": port, "host": "example.com"}),
        json!({"port": 0}),
        json!({"port": 65536}),
        json!({"host": "127.0.0.1"}),
    ] {
        let e = s
            .call("ports", "probe", &args)
            .expect_err(&args.to_string());
        assert_eq!(e.code, ErrorCode::BadRequest, "{args}");
    }
}

#[test]
fn verify_answers_a_mixed_batch_with_facts() {
    let dir = tempfile::tempdir().expect("dir");
    std::fs::write(dir.path().join("index.html"), b"<html>").expect("write");
    std::fs::create_dir(dir.path().join("dist")).expect("mkdir");
    let base = dir.path().to_string_lossy().into_owned();
    let (_listener, port) = bound();
    let gone = closed_port();
    let mut s = serve();
    let out = s
        .call(
            "made",
            "verify",
            &json!({"items": [
                {"id": "file", "path": format!("{base}/index.html")},
                {"id": "missing", "path": format!("{base}/nope")},
                {"id": "dir", "path": format!("{base}/dist")},
                {"id": "open", "port": port},
                {"id": "closed", "port": gone},
            ]}),
        )
        .expect("verify");
    let r = &out["results"];
    assert_eq!(r[0]["id"], "file");
    assert_eq!(r[0]["exists"], true);
    assert_eq!(r[0]["kind"], "file");
    assert_eq!(r[0]["size"], 6);
    assert!(r[0]["mtime_ms"].as_i64().expect("mtime") > 0);
    assert_eq!(r[1], json!({"id": "missing", "exists": false}));
    assert_eq!(r[2]["kind"], "dir");
    if s.ports_available() {
        assert_eq!(r[3]["listening"], true, "{}", r[3]);
        assert_eq!(r[4], json!({"id": "closed", "listening": false}));
        #[cfg(target_os = "linux")]
        {
            assert_eq!(r[3]["pid"], std::process::id());
            assert!(r[3]["process"].is_string());
        }
    }
}

#[test]
fn verify_refuses_too_many_items_relative_paths_and_ambiguous_items() {
    let mut s = serve();
    let many: Vec<Value> = (0..201).map(|i| json!({"id": i, "path": "/"})).collect();
    let e = s
        .call("made", "verify", &json!({"items": many}))
        .expect_err("too many");
    assert_eq!(e.code, ErrorCode::TooLarge);

    let at_limit: Vec<Value> = (0..200).map(|i| json!({"id": i, "path": "/"})).collect();
    let out = s
        .call("made", "verify", &json!({"items": at_limit}))
        .expect("200 is fine");
    assert_eq!(out["results"].as_array().expect("results").len(), 200);

    for item in [
        json!({"id": 1, "path": "relative/file"}),
        json!({"id": 1, "path": "/tmp", "port": 80}),
        json!({"id": 1}),
    ] {
        let e = s
            .call(
                "made",
                "verify",
                &json!({"items": [{"id": 0, "path": "/"}, item.clone()]}),
            )
            .expect_err(&item.to_string());
        assert_eq!(e.code, ErrorCode::BadRequest, "{item}");
    }
}

#[test]
fn verify_expands_tilde_to_the_home_serve_runs_in() {
    let mut s = serve();
    // The test's HOME is an empty temp dir.
    let out = s
        .call(
            "made",
            "verify",
            &json!({"items": [{"id": 1, "path": "~"}, {"id": 2, "path": "~/absent"}]}),
        )
        .expect("verify");
    assert_eq!(out["results"][0]["kind"], "dir");
    assert_eq!(out["results"][1]["exists"], false);
}
