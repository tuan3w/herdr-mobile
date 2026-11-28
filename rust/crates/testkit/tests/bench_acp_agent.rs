//! `bench-acp-agent` against `app/benchmark/support/bench_acp_agent.py`.

mod support;

use serde_json::{json, Value};
use support::Proc;

fn start(seed: &std::path::Path) -> Proc {
    Proc::spawn(
        &testkit::bin("bench-acp-agent"),
        &[],
        &[("BENCH_SEED", seed.to_str().expect("utf-8 path"))],
        None,
    )
}

#[test]
fn it_answers_the_handshake_and_plays_the_seed_on_prompt() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let seed = dir.path().join("seed.jsonl");
    std::fs::write(
        &seed,
        "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"héllo\"}}\n{\"sessionUpdate\":\"x\"}\n",
    )
    .expect("write the seed");
    let mut p = start(&seed);

    p.send(&json!({"id": 1, "method": "initialize"}));
    assert_eq!(
        p.line().expect("a line"),
        r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"bench-agent","version":"1"},"agentCapabilities":{"loadSession":false,"promptCapabilities":{"image":true,"embeddedContext":true}},"authMethods":[]}}"#
    );
    p.send(&json!({"id": 2, "method": "session/new", "params": {"cwd": "/x"}}));
    assert_eq!(
        p.line().expect("a line"),
        r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"bench-session","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"}]}}}"#
    );
    p.send(&json!({"id": 3, "method": "session/prompt", "params": {"sessionId": "bench-session", "prompt": []}}));
    // every seed line is one update, written verbatim after the session id; the turn then ends
    assert_eq!(
        p.line().expect("a line"),
        r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"bench-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"héllo"}}}}"#
    );
    assert_eq!(
        p.line().expect("a line"),
        r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"bench-session","update":{"sessionUpdate":"x"}}}"#
    );
    assert_eq!(
        p.line().expect("a line"),
        r#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#
    );
    p.close_stdin();
    assert!(p.wait().success());
}

#[test]
fn it_ignores_blank_lines_notifications_and_null_ids_and_refuses_unknown_methods() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let seed = dir.path().join("seed.jsonl");
    std::fs::write(&seed, "").expect("write the seed");
    let mut p = start(&seed);
    p.send_raw("\n   \n");
    p.send(&json!({"method": "session/cancel", "params": {}}));
    p.send(&json!({"id": null, "method": "ping"}));
    p.send(&json!({"id": 5}));
    p.send(&json!({"id": "é", "method": "zzz"}));
    let m: Value = p.msg();
    assert_eq!(
        m,
        json!({"jsonrpc": "2.0", "id": "é", "error": {"code": -32601, "message": "unknown method zzz"}})
    );
    // python's json.dumps escapes non-ASCII in what the agent writes itself
    p.send(&json!({"id": "é", "method": "zzz"}));
    assert!(p.line().expect("a line").contains("\"id\":\"\\u00e9\""));
}

#[test]
fn an_empty_seed_still_ends_the_turn() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let seed = dir.path().join("seed.jsonl");
    std::fs::write(&seed, "").expect("write the seed");
    let mut p = start(&seed);
    p.send(&json!({"id": 1, "method": "session/prompt", "params": {"sessionId": "s"}}));
    assert_eq!(
        p.line().expect("a line"),
        r#"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#
    );
}
