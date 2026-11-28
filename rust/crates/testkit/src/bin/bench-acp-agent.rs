//! A scripted ACP agent for benchmark/session_open_bench.dart.
//!
//! Speaks JSON-RPC lines on stdio like the real adapters. `session/prompt` plays
//! the file named by $BENCH_SEED: one `session/update` object per line, sent as
//! fast as the pipe takes them, then ends the turn. The keeper in front of it
//! logs them, which is what a later `session/load` replays.

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use testkit::pyjson::{dumps, COMPACT};

fn fail(message: &str) -> ! {
    eprintln!("bench-acp-agent: {message}");
    std::process::exit(1);
}

fn send(out: &mut impl Write, value: &Value) {
    let line = dumps(value, COMPACT);
    if writeln!(out, "{line}").and_then(|()| out.flush()).is_err() {
        std::process::exit(1);
    }
}

/// The seed file as python's text mode reads it: universal newlines, one entry per line.
fn seed_lines(path: &str) -> Vec<String> {
    let raw = std::fs::read(path).unwrap_or_else(|e| fail(&format!("{path}: {e}")));
    let text = String::from_utf8_lossy(&raw)
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    text.split_inclusive('\n')
        .map(|l| l.strip_suffix('\n').unwrap_or(l).to_string())
        .collect()
}

fn main() {
    let stdin = io::stdin();
    let mut out = io::stdout().lock();
    let mut buf = Vec::new();
    let mut input = stdin.lock();
    loop {
        buf.clear();
        match input.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let line = String::from_utf8_lossy(&buf);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let msg: Value =
            serde_json::from_str(line).unwrap_or_else(|e| fail(&format!("bad json: {e}")));
        let (Some(method), Some(rid)) = (
            msg.get("method").and_then(Value::as_str),
            msg.get("id").filter(|id| !id.is_null()),
        ) else {
            continue;
        };
        match method {
            "initialize" => send(
                &mut out,
                &json!({"jsonrpc": "2.0", "id": rid, "result": {
                    "protocolVersion": 1,
                    "agentInfo": {"name": "bench-agent", "version": "1"},
                    "agentCapabilities": {"loadSession": false, "promptCapabilities": {"image": true, "embeddedContext": true}},
                    "authMethods": [],
                }}),
            ),
            "session/new" => send(
                &mut out,
                &json!({"jsonrpc": "2.0", "id": rid, "result": {
                    "sessionId": "bench-session",
                    "modes": {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}]},
                }}),
            ),
            "session/prompt" => {
                let sid = msg["params"]["sessionId"]
                    .as_str()
                    .unwrap_or_else(|| fail("session/prompt without a sessionId"));
                let seed =
                    std::env::var("BENCH_SEED").unwrap_or_else(|_| fail("BENCH_SEED is not set"));
                let mut batch = String::new();
                for upd in seed_lines(&seed) {
                    batch.push_str(&format!(
                        "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{sid}\",\"update\":{upd}}}}}\n"
                    ));
                }
                if out
                    .write_all(batch.as_bytes())
                    .and_then(|()| out.flush())
                    .is_err()
                {
                    std::process::exit(1);
                }
                send(
                    &mut out,
                    &json!({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}}),
                );
            }
            other => send(
                &mut out,
                &json!({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": format!("unknown method {other}")}}),
            ),
        }
    }
}
