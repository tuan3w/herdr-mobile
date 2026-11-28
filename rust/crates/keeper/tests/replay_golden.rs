//! The Rust replay log against frozen decisions of the original python one.
//!
//! `tests/fixtures/replay_golden.json` was recorded once from the python
//! `ReplayLog` (the keeper's reference implementation, since deleted) on seeded
//! random sessions; the file is the oracle and nothing is generated at test
//! time. Each scenario is a list of operations (add a message, remove an
//! earlier one) with the counters the python log had after every step, the
//! entries it held at the end (message and size, in replay order) and what it
//! replayed from a few `since` points. This replays the operations and compares
//! all of it.
//!
//! The recording ran seeds 0..60; a full set is 14 MB of seeded text, so the
//! committed file keeps nine of them (seeds 6, 7, 15, 31, 44, 45, 57, 58, 59:
//! all four byte budgets, entry caps 12/40/200/5000, one to three full turns,
//! with and without a soft budget, every one of them dropping or trimming
//! entries) to stay under 1 MB.
//!
//! The recorder (`tool/gen-replay-fixtures.py`, which loaded the python
//! `ReplayLog` out of `keeper_script.dart`) is in git history, last present at
//! the commit before this file replaced `replay_differential.rs`.

use keeper::replay_log::ReplayLog;
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;

fn golden() -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/replay_golden.json");
    let raw = std::fs::read(&path).expect("the golden fixture is committed");
    serde_json::from_slice(&raw).expect("the golden fixture is JSON")
}

fn stat(log: &ReplayLog) -> Value {
    serde_json::json!({
        "bytes": log.bytes(), "count": log.count(), "dropped": log.dropped(),
        "trimmed": log.trimmed(), "turns": log.turn_count(), "next_seq": log.next_seq(),
    })
}

#[test]
fn the_rust_log_makes_the_same_decisions_as_the_python_one() {
    let scenarios = golden();
    assert!(scenarios.len() >= 9);
    for sc in &scenarios {
        let seed = &sc["seed"];
        let p = &sc["params"];
        let n = |k: &str| usize::try_from(p[k].as_u64().expect("a number")).expect("fits");
        let mut log = ReplayLog::new(
            n("max_bytes"),
            n("max_entries"),
            p["full_turns"].as_u64().expect("number"),
            p["soft_bytes"]
                .as_u64()
                .map(|s| usize::try_from(s).expect("fits")),
        );
        let mut ids: Vec<Option<u64>> = Vec::new();
        for (i, (op, want)) in sc["ops"]
            .as_array()
            .expect("ops")
            .iter()
            .zip(sc["steps"].as_array().expect("steps"))
            .enumerate()
        {
            let mut expect = want.clone();
            if let Some(target) = op.get("remove") {
                let id = ids[usize::try_from(target.as_u64().expect("index")).expect("fits")]
                    .expect("an add");
                let ok = log.remove(id);
                assert_eq!(
                    Some(ok),
                    expect["removed"].as_bool(),
                    "seed {seed} op {i}: remove"
                );
                expect.as_object_mut().expect("object").remove("removed");
                ids.push(None);
            } else {
                let waiting: HashSet<String> = op["waiting"]
                    .as_array()
                    .expect("waiting")
                    .iter()
                    .filter_map(|w| w.as_str().map(str::to_string))
                    .collect();
                let size = usize::try_from(op["size"].as_u64().expect("size")).expect("fits");
                ids.push(Some(log.add(op["add"].clone(), size, || waiting)));
            }
            assert_eq!(stat(&log), expect, "seed {seed} op {i}: counters");
        }
        let got: Vec<Value> = log
            .replay(None)
            .map(|(e, seq)| serde_json::json!([e.msg, e.size, seq]))
            .collect();
        let want = sc["final"].as_array().expect("final");
        assert_eq!(got.len(), want.len(), "seed {seed}: entries held");
        for (k, (g, w)) in got.iter().zip(want).enumerate() {
            assert_eq!(g, w, "seed {seed}: entry {k}");
        }
        for (since, want) in sc["since"].as_object().expect("since") {
            let from: u64 = since.parse().expect("a number");
            let got: Vec<Value> = log
                .replay(Some(from))
                .map(|(e, seq)| serde_json::json!([e.msg, seq]))
                .collect();
            assert_eq!(
                &Value::Array(got),
                want,
                "seed {seed}: replay since {since}"
            );
        }
    }
}
