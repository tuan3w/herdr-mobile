//! `fake-acp-agent` against the behaviours of the python program it replaces
//! (`app/test/support/fake_acp_agent.py`): the prompt scripts, the environment
//! switches, the log, the store, the exit codes. Run over stdio like the keeper
//! runs an agent.

mod support;

use serde_json::{json, Value};
use std::path::Path;
use std::time::{Duration, Instant};
use support::Proc;
use tempfile::TempDir;

struct Agent {
    p: Proc,
    dir: TempDir,
    next: i64,
}

impl Agent {
    fn start(env: &[(&str, &str)]) -> Agent {
        let dir = tempfile::tempdir().expect("a temp dir");
        let log = dir.path().join("log");
        let log = log.to_str().expect("utf-8 path").to_string();
        let mut all = vec![("FAKE_ACP_LOG", log.as_str())];
        all.extend_from_slice(env);
        let p = Proc::spawn(&testkit::bin("fake-acp-agent"), &[], &all, Some(dir.path()));
        Agent { p, dir, next: 1 }
    }

    /// Sends a request; returns its id.
    fn ask(&mut self, method: &str, params: Value) -> i64 {
        let id = self.next;
        self.next += 1;
        self.p
            .send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        id
    }

    /// Everything up to and including the answer to request `id`.
    fn until_answer(&self, id: i64) -> Vec<Value> {
        self.p.until(|m| m.get("method").is_none() && m["id"] == id)
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.ask(method, params);
        self.until_answer(id).pop().expect("an answer")
    }

    fn init(&mut self) -> Value {
        self.call("initialize", json!({}))
    }

    /// initialize + session/new; the session id.
    fn session(&mut self) -> String {
        self.init();
        let r = self.call("session/new", json!({"cwd": "/w"}));
        r["result"]["sessionId"]
            .as_str()
            .expect("a session id")
            .to_string()
    }

    fn prompt_req(&mut self, sid: &str, text: &str) -> i64 {
        self.ask(
            "session/prompt",
            json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]}),
        )
    }

    /// A whole turn that needs no client answer.
    fn turn(&mut self, sid: &str, text: &str) -> Vec<Value> {
        let id = self.prompt_req(sid, text);
        self.until_answer(id)
    }

    fn answer(&mut self, id: Value, result: Value) {
        self.p
            .send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
    }

    fn cancel(&mut self, sid: &str) {
        self.p.send(
            &json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}}),
        );
    }

    fn logged(&self) -> Vec<Value> {
        read_log(&self.dir.path().join("log"))
    }
}

fn read_log(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str::<Value>(l).expect("a JSON log line"))
        .collect()
}

fn updates(msgs: &[Value]) -> Vec<Value> {
    msgs.iter()
        .filter(|m| m["method"] == "session/update")
        .map(|m| m["params"]["update"].clone())
        .collect()
}

fn chunk_texts(msgs: &[Value]) -> Vec<String> {
    updates(msgs)
        .iter()
        .filter(|u| u["sessionUpdate"] == "agent_message_chunk")
        .filter_map(|u| u["content"]["text"].as_str().map(str::to_string))
        .collect()
}

fn stop_reason(msgs: &[Value]) -> &str {
    msgs.last().expect("a message")["result"]["stopReason"]
        .as_str()
        .expect("a stop reason")
}

#[test]
fn the_wire_spelling_is_pythons() {
    let mut a = Agent::start(&[]);
    a.p.send_raw("{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\", \"params\": {}}\n");
    assert_eq!(
        a.p.line().expect("a line"),
        r#"{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": 1, "agentInfo": {"name": "fake-acp", "version": "1"}, "agentCapabilities": {"loadSession": false, "promptCapabilities": {"image": true}}, "authMethods": []}}"#
    );
    a.p.send_raw(
        "{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"session/new\", \"params\": {}}\n",
    );
    assert_eq!(
        a.p.line().expect("a line"),
        r#"{"jsonrpc": "2.0", "id": 2, "result": {"sessionId": "sess-1", "modes": {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}]}}}"#
    );
    a.p.send_raw("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"reply:é\"}]}}\n");
    assert_eq!(
        a.p.line().expect("a line"),
        r#"{"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "re: \u00e9"}, "messageId": "reply-1"}}}"#
    );
    assert_eq!(
        a.p.line().expect("a line"),
        r#"{"jsonrpc": "2.0", "id": 3, "result": {"stopReason": "end_turn"}}"#
    );
}

#[test]
fn it_says_it_is_up_on_stderr_and_exits_on_eof() {
    let mut a = Agent::start(&[]);
    a.init();
    assert_eq!(a.p.stderr(), "fake agent up\n");
    a.p.close_stdin();
    assert!(a.p.wait().success());
    assert!(a.p.line().is_none(), "nothing more on stdout");
}

#[test]
fn a_plain_turn_is_two_chunks_and_end_turn() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    assert_eq!(sid, "sess-1");
    let msgs = a.turn(&sid, "plain");
    assert_eq!(chunk_texts(&msgs), ["Hel", "lo"]);
    assert_eq!(msgs.len(), 3);
    assert_eq!(stop_reason(&msgs), "end_turn");
    // session ids count up per process without a store
    let second = a.call("session/new", json!({}));
    assert_eq!(second["result"]["sessionId"], "sess-2");
}

#[test]
fn unknown_prompt_texts_say_nothing_and_unknown_methods_are_refused() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    assert_eq!(a.turn(&sid, "no such script").len(), 1);
    let r = a.call("nope/nope", json!({}));
    assert_eq!(
        r["error"],
        json!({"code": -32601, "message": "unknown method nope/nope"})
    );
    let r = a.call("session/load", json!({"sessionId": sid}));
    assert_eq!(r["error"]["code"], -32000);
    assert_eq!(
        r["error"]["message"],
        "session/load is unsupported for a live session"
    );
    let r = a.call("session/list", json!({}));
    assert_eq!(r["result"], json!({"sessions": []}));
}

#[test]
fn every_message_it_gets_is_logged_but_garbage_is_not() {
    let mut a = Agent::start(&[]);
    a.p.send_raw("not json\n\n   \n");
    let sid = a.session();
    a.turn(&sid, "plain");
    a.p.send(&json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}}));
    a.call("nope", json!({}));
    let log = a.logged();
    let methods: Vec<&str> = log
        .iter()
        .map(|l| l["recv"]["method"].as_str().expect("method"))
        .collect();
    assert_eq!(
        methods,
        [
            "initialize",
            "session/new",
            "session/prompt",
            "session/cancel",
            "nope"
        ]
    );
    assert!(log
        .iter()
        .all(|l| l.as_object().is_some_and(|o| o.len() == 1)));
}

#[test]
fn ask_waits_for_the_permission_and_the_question() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "ask");
    let seen = a.p.until(|m| m["method"] == "session/request_permission");
    let kinds: Vec<String> = updates(&seen)
        .iter()
        .map(|u| u["sessionUpdate"].as_str().expect("kind").to_string())
        .collect();
    assert_eq!(kinds, ["session_info_update", "agent_message_chunk"]);
    assert_eq!(updates(&seen)[0]["title"], "Fake title");
    let perm = seen.last().expect("the request");
    assert_eq!(perm["id"], 7001);
    assert_eq!(perm["params"]["toolCall"]["toolCallId"], "tc-7001");
    assert_eq!(perm["params"]["toolCall"]["title"], "Run: ls -la");
    assert_eq!(perm["params"]["options"][0]["optionId"], "allow");
    assert_eq!(perm["params"]["options"][1]["optionId"], "reject");
    // nothing else happens until the answer
    assert!(a.p.line_within(Duration::from_millis(200)).is_none());
    a.answer(
        json!(7001),
        json!({"outcome": {"outcome": "selected", "optionId": "allow"}}),
    );
    let seen = a.p.until(|m| m["method"] == "elicitation/create");
    assert_eq!(updates(&seen)[0]["status"], "completed");
    let q = seen.last().expect("the question");
    assert_eq!(q["id"], "elic-1");
    assert_eq!(q["params"]["message"], "Pick one?\nsecond line");
    assert_eq!(
        q["params"]["requestedSchema"]["properties"]["value"]["enum"],
        json!(["a", "b"])
    );
    a.answer(json!("elic-1"), json!({"action": "accept"}));
    let rest = a.until_answer(id);
    assert_eq!(chunk_texts(&rest), ["answered:allow/accept"]);
}

#[test]
fn ask_names_what_was_not_answered_like_python_does() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "ask");
    a.p.until(|m| m["method"] == "session/request_permission");
    a.answer(json!(7001), json!({}));
    a.p.until(|m| m["method"] == "elicitation/create");
    a.p.send(&json!({"jsonrpc": "2.0", "id": "elic-1", "error": {"code": 1, "message": "no"}}));
    assert_eq!(chunk_texts(&a.until_answer(id)), ["answered:None/None"]);
}

#[test]
fn a_request_that_arrives_while_it_waits_is_kept_for_later() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "ask");
    a.p.until(|m| m["method"] == "session/request_permission");
    let other = a.ask("later/thing", json!({}));
    a.answer(json!(7001), json!({"outcome": {"optionId": "reject"}}));
    a.p.until(|m| m["method"] == "elicitation/create");
    a.answer(json!("elic-1"), json!({"action": "decline"}));
    let rest = a.until_answer(id);
    assert_eq!(chunk_texts(&rest), ["answered:reject/decline"]);
    // the held request is served after the turn
    let held = a.until_answer(other);
    assert_eq!(held.last().expect("an answer")["error"]["code"], -32601);
}

#[test]
fn perm_asks_one_permission_with_the_title() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "perm:Delete everything");
    let seen = a.p.until(|m| m["method"] == "session/request_permission");
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0]["id"], 7002);
    assert_eq!(seen[0]["params"]["toolCall"]["title"], "Delete everything");
    a.answer(json!(7002), json!({"outcome": {"optionId": "allow"}}));
    assert_eq!(stop_reason(&a.until_answer(id)), "end_turn");
}

#[test]
fn slow_and_quiet_end_cancelled_after_session_cancel() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "slow");
    let seen = a.p.until(|m| m["method"] == "session/update");
    assert_eq!(chunk_texts(&seen), ["working"]);
    assert!(
        a.p.line_within(Duration::from_millis(200)).is_none(),
        "the turn stays open"
    );
    a.cancel(&sid);
    assert_eq!(stop_reason(&a.until_answer(id)), "cancelled");
    // quiet says nothing at all
    let id = a.prompt_req(&sid, "quiet");
    assert!(a.p.line_within(Duration::from_millis(200)).is_none());
    a.cancel(&sid);
    let msgs = a.until_answer(id);
    assert_eq!(msgs.len(), 1);
    assert_eq!(stop_reason(&msgs), "cancelled");
    // a cancel from before the next prompt does not end it
    a.cancel(&sid);
    let msgs = a.turn(&sid, "plain");
    assert_eq!(stop_reason(&msgs), "end_turn");
}

#[test]
fn noise_prints_garbage_lines_first() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    a.prompt_req(&sid, "noise");
    assert_eq!(a.p.line().expect("a line"), "this is not json");
    assert_eq!(a.p.line().expect("a line"), "[1,2,3]");
    assert_eq!(a.p.line().expect("a line"), "");
    let m = a.p.msg();
    assert_eq!(m["params"]["update"]["content"]["text"], "after noise");
}

#[test]
fn die_asks_then_exits_with_code_3_and_boom() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    a.prompt_req(&sid, "die");
    let m = a.p.msg();
    assert_eq!(m["id"], 7003);
    assert_eq!(m["method"], "session/request_permission");
    assert_eq!(m["params"]["toolCall"]["title"], "Doomed");
    assert_eq!(a.p.wait().code(), Some(3));
    assert!(a.p.stderr().ends_with("boom\n"));
}

#[test]
fn exit_n_exits_with_n_at_once() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    a.prompt_req(&sid, "exit:7");
    assert_eq!(a.p.wait().code(), Some(7));
    assert!(a.p.line().is_none());
}

#[test]
fn sleep_says_one_chunk_then_waits_that_long() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let start = Instant::now();
    let msgs = a.turn(&sid, "sleep:0.3");
    assert!(start.elapsed() >= Duration::from_millis(300));
    assert_eq!(chunk_texts(&msgs), ["sleeping"]);
}

#[test]
fn long_sends_n_chunks_with_distinct_message_ids() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let msgs = a.turn(&sid, "long:4");
    let ups = updates(&msgs);
    let ids: Vec<&str> = ups
        .iter()
        .map(|u| u["messageId"].as_str().expect("id"))
        .collect();
    assert_eq!(ids, ["m0", "m1", "m2", "m3"]);
    assert_eq!(
        chunk_texts(&msgs),
        ["line 0 ", "line 1 ", "line 2 ", "line 3 "]
    );
}

#[test]
fn big_and_picture_and_reply() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let msgs = a.turn(&sid, "big:1000");
    let ups = updates(&msgs);
    assert_eq!(ups.len(), 3);
    assert_eq!(ups[0]["toolCallId"], "big-1");
    assert_eq!(ups[0]["content"][0]["content"]["text"], "y".repeat(1000));
    assert_eq!(ups[1]["content"]["text"], "z".repeat(1000));
    assert_eq!(ups[1]["messageId"], "mbig");
    assert_eq!(ups[2]["messageId"], "mtail");

    let msgs = a.turn(&sid, "picture:10");
    let ups = updates(&msgs);
    assert_eq!(ups[0]["content"]["type"], "image");
    assert_eq!(ups[0]["content"]["mimeType"], "image/png");
    assert_eq!(ups[0]["content"]["data"], "QUJDQUJDQU");
    assert_eq!(ups[1]["messageId"], "after-pic");

    let first = updates(&a.turn(&sid, "reply:hi"));
    let second = updates(&a.turn(&sid, "reply:there"));
    assert_eq!(first[0]["content"]["text"], "re: hi");
    assert_eq!(first[0]["messageId"], "reply-1");
    assert_eq!(second[0]["content"]["text"], "re: there");
    assert_eq!(second[0]["messageId"], "reply-2");
}

#[test]
fn heavy_plays_thoughts_tools_and_the_answer() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let msgs = a.turn(&sid, "heavy:6:1:3:A");
    let ups = updates(&msgs);
    assert_eq!(ups.len(), 1 + 6 * 3 + 1);
    assert_eq!(ups[0]["sessionUpdate"], "agent_thought_chunk");
    assert_eq!(ups[0]["messageId"], "think-A");
    assert_eq!(ups[0]["content"]["text"], "thinking about turn A");
    let starts: Vec<&Value> = ups
        .iter()
        .filter(|u| u["sessionUpdate"] == "tool_call")
        .collect();
    assert_eq!(starts.len(), 6);
    assert_eq!(starts[0]["toolCallId"], "tA-0");
    assert_eq!(starts[0]["title"], "Run: step 0 of turn A");
    assert_eq!(starts[0]["kind"], "execute");
    assert_eq!(starts[4]["kind"], "edit");
    assert_eq!(
        starts[0]["rawInput"]["script"]
            .as_str()
            .expect("script")
            .len(),
        3000
    );
    let done: Vec<&Value> = ups
        .iter()
        .filter(|u| u["sessionUpdate"] == "tool_call_update" && u["status"] == "completed")
        .collect();
    assert_eq!(done.len(), 6);
    // even tools carry the output in `content`, odd ones in `rawOutput`
    let text0 = done[0]["content"][0]["content"]["text"]
        .as_str()
        .expect("text");
    assert!(text0.starts_with("output of tA-0: x"));
    assert_eq!(text0.len(), "output of tA-0: ".len() + 1024); // 1 KB + (0 * 7919) % 3 KB
    assert!(done[1]["rawOutput"]
        .as_str()
        .expect("raw")
        .starts_with("output of tA-1: x"));
    assert!(done[1].get("content").is_none());
    // the fifth tool is an edit and carries a diff after its output
    let diff = &done[4]["content"][1];
    assert_eq!(diff["type"], "diff");
    assert_eq!(diff["oldText"], "a\n".repeat(500));
    assert_eq!(diff["newText"], "b\n".repeat(500));
    let last = ups.last().expect("an update");
    assert_eq!(last["content"]["text"], "answer A");
    assert_eq!(last["messageId"], "answer-A");
}

#[test]
fn heavyhold_has_no_answer_and_waits_for_cancel() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "heavyhold:2:1:1:B");
    let seen = a.p.until(|m| {
        m["method"] == "session/update"
            && m["params"]["update"]["toolCallId"] == "tB-1"
            && m["params"]["update"]["status"] == "completed"
    });
    assert_eq!(seen.len(), 1 + 2 * 3);
    assert!(a.p.line_within(Duration::from_millis(200)).is_none());
    a.cancel(&sid);
    let rest = a.until_answer(id);
    assert_eq!(rest.len(), 1);
    assert_eq!(stop_reason(&rest), "cancelled");
}

#[test]
fn tasks_can_be_stopped_once() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let msgs = a.turn(&sid, "task:abc");
    let ups = updates(&msgs);
    assert_eq!(ups[0]["sessionUpdate"], "async_task_spawned");
    assert_eq!(ups[0]["asyncTaskId"], "abc");
    assert_eq!(ups[0]["taskType"], "shell");
    assert_eq!(ups[0]["canStop"], true);
    assert_eq!(ups[0]["toolCallId"], "tc-abc");
    assert_eq!(chunk_texts(&msgs), ["started abc"]);
    let msgs = {
        let id = a.ask(
            "_session/async_task/stop",
            json!({"sessionId": sid, "asyncTaskId": "abc"}),
        );
        a.until_answer(id)
    };
    assert_eq!(
        updates(&msgs)[0],
        json!({"sessionUpdate": "async_task_state_update", "asyncTaskId": "abc", "state": "stopped"})
    );
    assert_eq!(
        msgs.last().expect("an answer")["result"],
        json!({"stopped": true})
    );
    let again = a.call(
        "_session/async_task/stop",
        json!({"sessionId": sid, "asyncTaskId": "abc"}),
    );
    assert_eq!(again["result"], json!({"stopped": false}));
    let unknown = a.call(
        "_session/async_task/stop",
        json!({"sessionId": sid, "asyncTaskId": "zzz"}),
    );
    assert_eq!(unknown["result"], json!({"stopped": false}));
}

#[test]
fn sdk_tasks_are_raw_claude_messages() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let msgs = a.turn(&sid, "sdktask:t9");
    assert_eq!(msgs[0]["method"], "_claude/sdkMessage");
    let m = &msgs[0]["params"]["message"];
    assert_eq!(m["subtype"], "background_tasks_changed");
    assert_eq!(
        m["tasks"],
        json!([{"task_id": "t9", "task_type": "local_bash", "description": "sleep 600"}])
    );
    assert_eq!(m["session_id"], sid);
    assert_eq!(chunk_texts(&msgs), ["started t9"]);
    let msgs = a.turn(&sid, "sdkend:t9");
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0]["params"]["message"]["tasks"], json!([]));
}

#[test]
fn cursor_ask_question_returns_the_answer_as_sorted_json() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "cursor-ask");
    let req =
        a.p.until(|m| m["method"] == "cursor/ask_question")
            .pop()
            .expect("request");
    assert_eq!(req["id"], "cur-ask");
    assert_eq!(req["params"]["sessionId"], sid);
    assert_eq!(req["params"]["questions"][0]["id"], "q1");
    assert_eq!(req["params"]["questions"][1]["allowMultiple"], true);
    // the session id is the last key of the params, as python appended it
    let keys: Vec<&String> = req["params"].as_object().expect("params").keys().collect();
    assert_eq!(keys.last().expect("a key"), &"sessionId");
    a.answer(json!("cur-ask"), json!({"outcome": {"outcome": "answered", "answers": [{"questionId": "q1", "selectedOptionIds": ["red"]}]}, "é": 1}));
    let rest = a.until_answer(id);
    assert_eq!(
        chunk_texts(&rest),
        [
            r#"got:{"outcome": {"answers": [{"questionId": "q1", "selectedOptionIds": ["red"]}], "outcome": "answered"}, "\u00e9": 1}"#
        ]
    );
    assert_eq!(updates(&rest)[0]["messageId"], "cur-ask-got");
}

#[test]
fn cursor_ask_empty_plan_and_a_refused_call() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "cursor-ask-empty");
    let req =
        a.p.until(|m| m["method"] == "cursor/ask_question")
            .pop()
            .expect("request");
    assert_eq!(req["params"]["questions"], json!([]));
    a.p.send(
        &json!({"jsonrpc": "2.0", "id": "cur-ask", "error": {"code": -32601, "message": "no"}}),
    );
    assert_eq!(chunk_texts(&a.until_answer(id)), ["got:null"]);

    let id = a.prompt_req(&sid, "cursor-plan");
    let req =
        a.p.until(|m| m["method"] == "cursor/create_plan")
            .pop()
            .expect("request");
    assert_eq!(req["id"], "cur-plan");
    assert_eq!(req["params"]["name"], "Refactor tabs");
    assert_eq!(req["params"]["todos"][0]["id"], "t1");
    a.answer(json!("cur-plan"), json!({"accepted": true}));
    let rest = a.until_answer(id);
    assert_eq!(chunk_texts(&rest), [r#"got:{"accepted": true}"#]);
    assert_eq!(updates(&rest)[0]["messageId"], "cur-plan-got");
}

#[test]
fn cursor_plan_todos_updates_todos_after_the_plan_is_answered() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let id = a.prompt_req(&sid, "cursor-plan-todos");
    let req =
        a.p.until(|m| m["method"] == "cursor/create_plan")
            .pop()
            .expect("request");
    assert_eq!(req["params"]["todos"].as_array().expect("todos").len(), 2);
    a.answer(json!("cur-plan"), json!({"accepted": false}));
    let msgs = a.until_answer(id);
    assert_eq!(msgs[0]["method"], "cursor/update_todos");
    assert_eq!(msgs[0]["params"]["merge"], true);
    assert_eq!(msgs[0]["params"]["todos"][0]["status"], "completed");
    assert!(msgs[0].get("id").is_none());
    assert_eq!(chunk_texts(&msgs), [r#"got:{"accepted": false}"#]);
}

#[test]
fn cursor_todos_and_tasks() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    let msgs = a.turn(&sid, "cursor-todos");
    assert_eq!(msgs[0]["method"], "cursor/update_todos");
    assert_eq!(msgs[0]["params"]["merge"], false);
    assert_eq!(
        msgs[0]["params"]["todos"].as_array().expect("todos").len(),
        3
    );
    assert_eq!(msgs[1]["params"]["merge"], true);
    assert_eq!(
        msgs[1]["params"]["todos"][1],
        json!({"id": "4", "content": "Test", "status": "pending"})
    );
    assert_eq!(chunk_texts(&msgs), ["todos sent"]);

    let msgs = a.turn(&sid, "cursor-task");
    let ups = updates(&msgs);
    assert_eq!(ups[0]["title"], "Task: Explore codebase");
    assert_eq!(ups[0]["rawInput"]["subagentType"], "explore");
    assert_eq!(ups[1]["status"], "completed");
    let task = msgs
        .iter()
        .find(|m| m["method"] == "cursor/task")
        .expect("the notification");
    assert_eq!(task["params"]["toolCallId"], "tc-task");
    assert_eq!(
        task["params"]["subagentType"],
        json!({"custom": "reviewer"})
    );
    assert_eq!(task["params"]["durationMs"], 1234);

    let msgs = a.turn(&sid, "cursor-task-bad");
    let task = msgs
        .iter()
        .find(|m| m["method"] == "cursor/task")
        .expect("the notification");
    assert_eq!(task["params"]["toolCallId"], 7);
    assert_eq!(chunk_texts(&msgs), ["task sent"]);
}

#[test]
fn busy_file_makes_every_prompt_busy() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let busy = dir.path().join("busy");
    let busy_path = busy.to_str().expect("utf-8").to_string();
    let mut a = Agent::start(&[("FAKE_ACP_BUSY_FILE", &busy_path)]);
    let sid = a.session();
    // no file: a normal turn
    assert_eq!(chunk_texts(&a.turn(&sid, "plain")), ["Hel", "lo"]);
    std::fs::write(&busy, "working\n").expect("write");
    let msgs = a.turn(&sid, "plain");
    assert_eq!(chunk_texts(&msgs), ["subagent progress"]);
    assert_eq!(updates(&msgs)[0]["messageId"], "own-turn");
    assert_eq!(
        msgs.last().expect("an answer")["error"],
        json!({"code": -32003, "message": "Session is busy"})
    );
    std::fs::write(&busy, "quiet\n").expect("write");
    let msgs = a.turn(&sid, "plain");
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0]["error"]["code"], -32003);
    std::fs::remove_file(&busy).expect("remove");
    assert_eq!(chunk_texts(&a.turn(&sid, "plain")), ["Hel", "lo"]);
}

#[test]
fn auth_is_required_until_authenticate() {
    let mut a = Agent::start(&[("FAKE_ACP_AUTH", "login")]);
    let init = a.init();
    assert_eq!(
        init["result"]["authMethods"],
        json!([{"id": "login", "name": "Login"}])
    );
    let r = a.call("session/new", json!({}));
    assert_eq!(
        r["error"],
        json!({"code": -32000, "message": "Authentication required"})
    );
    let r = a.call("authenticate", json!({"methodId": "login"}));
    assert_eq!(r["result"], json!({}));
    let r = a.call("session/new", json!({}));
    assert_eq!(r["result"]["sessionId"], "sess-1");
}

#[test]
fn authenticate_failures() {
    let mut a = Agent::start(&[("FAKE_ACP_AUTH", "login"), ("FAKE_ACP_AUTH_FAIL", "1")]);
    a.init();
    let r = a.call("authenticate", json!({}));
    assert_eq!(r["error"]["code"], -32602);
    assert_eq!(r["error"]["message"], "Invalid params");
    assert!(r["error"]["data"]["message"]
        .as_str()
        .expect("message")
        .contains("https://cursor.com/loginDeepControl?challenge=abc123"));

    let mut a = Agent::start(&[("FAKE_ACP_AUTH", "login"), ("FAKE_ACP_AUTH_UNKNOWN", "1")]);
    a.init();
    let r = a.call("authenticate", json!({}));
    assert_eq!(
        r["error"],
        json!({"code": -32601, "message": "Method not found"})
    );

    let mut a = Agent::start(&[("FAKE_ACP_AUTH", "login"), ("FAKE_ACP_AUTH_EXIT", "1")]);
    a.init();
    a.ask("authenticate", json!({}));
    assert_eq!(a.p.wait().code(), Some(4));
    assert!(a.p.stderr().ends_with("signed out\n"));
}

#[test]
fn fail_init_exits_5_before_answering() {
    let mut a = Agent::start(&[("FAKE_ACP_FAIL_INIT", "1")]);
    a.ask("initialize", json!({}));
    assert_eq!(a.p.wait().code(), Some(5));
    assert!(a.p.stderr().ends_with("cannot start: no login\n"));
    assert!(a.p.line().is_none(), "no answer");
}

#[test]
fn init_delay_waits_before_answering() {
    let mut a = Agent::start(&[("FAKE_ACP_INIT_DELAY", "0.3")]);
    let start = Instant::now();
    a.init();
    assert!(start.elapsed() >= Duration::from_millis(300));
}

#[test]
fn pid_file_gets_pid_and_cwd_per_initialize() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let pid_file = dir.path().join("pids");
    let pid_path = pid_file.to_str().expect("utf-8").to_string();
    let mut a = Agent::start(&[("FAKE_ACP_PID_FILE", &pid_path)]);
    a.init();
    a.init();
    let written = std::fs::read_to_string(&pid_file).expect("the pid file");
    let lines: Vec<&str> = written.lines().collect();
    assert_eq!(lines.len(), 2);
    let want = format!("{}\t{}", a.p.child.id(), a.dir.path().display());
    // the agent's cwd may be spelled through a symlink (macOS /var -> /private/var)
    let (pid, cwd) = lines[0].split_once('\t').expect("pid TAB cwd");
    assert_eq!(pid, a.p.child.id().to_string(), "{want}");
    assert_eq!(
        std::fs::canonicalize(cwd).expect("cwd exists"),
        std::fs::canonicalize(a.dir.path()).expect("dir exists")
    );
}

#[test]
fn ignore_term_survives_sigterm() {
    let mut a = Agent::start(&[("FAKE_ACP_IGNORE_TERM", "1")]);
    a.init();
    let pid = a.p.child.id().to_string();
    let status = std::process::Command::new("kill")
        .args(["-TERM", &pid])
        .status()
        .expect("kill runs");
    assert!(status.success());
    // still serving after the signal was delivered (the answer proves it ran past it)
    let r = a.call("nope", json!({}));
    assert_eq!(r["error"]["code"], -32601);
    assert!(a.p.child.try_wait().expect("wait").is_none());
    a.p.close_stdin();
    assert!(a.p.wait().success());
}

#[test]
fn without_ignore_term_sigterm_ends_it() {
    let mut a = Agent::start(&[]);
    a.init();
    let pid = a.p.child.id().to_string();
    assert!(std::process::Command::new("kill")
        .args(["-TERM", &pid])
        .status()
        .expect("kill")
        .success());
    assert!(!a.p.wait().success());
}

fn store_with(path: &str, sessions: Value) {
    std::fs::write(path, json!({"sessions": sessions}).to_string()).expect("write the store");
}

fn stored(n: usize) -> Value {
    (0..n)
        .map(|i| {
            json!({"sessionId": format!("old-{i}"), "cwd": format!("/w{}", i % 2), "title": format!("T{i}"),
                   "updatedAt": format!("2026-01-0{}T00:00:00Z", i + 1), "messageCount": i,
                   "updates": [{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("said {i}")}}]})
        })
        .collect::<Vec<_>>()
        .into()
}

#[test]
fn a_store_adds_list_load_and_resume_capabilities() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = dir
        .path()
        .join("store.json")
        .to_str()
        .expect("utf-8")
        .to_string();
    let caps = |env: &[(&str, &str)]| {
        let mut all = vec![("FAKE_ACP_STORE", store.as_str())];
        all.extend_from_slice(env);
        Agent::start(&all).init()["result"]["agentCapabilities"].clone()
    };
    assert_eq!(
        caps(&[]),
        json!({"loadSession": true, "promptCapabilities": {"image": true}, "sessionCapabilities": {"list": {}, "resume": {}}})
    );
    assert_eq!(
        caps(&[("FAKE_ACP_CAPS", "list")]),
        json!({"loadSession": false, "promptCapabilities": {"image": true}, "sessionCapabilities": {"list": {}}})
    );
    assert_eq!(
        caps(&[("FAKE_ACP_CAPS", "load")]),
        json!({"loadSession": true, "promptCapabilities": {"image": true}})
    );
}

#[test]
fn session_list_filters_by_cwd_and_pages() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = dir
        .path()
        .join("store.json")
        .to_str()
        .expect("utf-8")
        .to_string();
    store_with(&store, stored(5));
    let mut a = Agent::start(&[("FAKE_ACP_STORE", &store), ("FAKE_ACP_PAGE", "2")]);
    a.init();
    let r = a.call("session/list", json!({}));
    let ids = |r: &Value| -> Vec<String> {
        r["result"]["sessions"]
            .as_array()
            .expect("sessions")
            .iter()
            .map(|s| s["sessionId"].as_str().expect("id").to_string())
            .collect()
    };
    assert_eq!(ids(&r), ["old-0", "old-1"]);
    assert_eq!(r["result"]["nextCursor"], "2");
    assert_eq!(
        r["result"]["sessions"][1],
        json!({"sessionId": "old-1", "cwd": "/w1", "title": "T1", "updatedAt": "2026-01-02T00:00:00Z", "_meta": {"messageCount": 1, "size": 1}})
    );
    let r = a.call("session/list", json!({"cursor": "2"}));
    assert_eq!(ids(&r), ["old-2", "old-3"]);
    assert_eq!(r["result"]["nextCursor"], "4");
    let r = a.call("session/list", json!({"cursor": "4"}));
    assert_eq!(ids(&r), ["old-4"]);
    assert!(r["result"].get("nextCursor").is_none());
    let r = a.call("session/list", json!({"cwd": "/w1"}));
    assert_eq!(ids(&r), ["old-1", "old-3"]);
    assert!(r["result"].get("nextCursor").is_none());
    let r = a.call("session/list", json!({"cursor": "not a number"}));
    assert_eq!(ids(&r), ["old-0", "old-1"]);
}

#[test]
fn session_load_replays_stored_updates_and_refuses_unknown_ids() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = dir
        .path()
        .join("store.json")
        .to_str()
        .expect("utf-8")
        .to_string();
    store_with(&store, stored(3));
    let mut a = Agent::start(&[("FAKE_ACP_STORE", &store)]);
    a.init();
    let id = a.ask("session/load", json!({"sessionId": "old-2", "cwd": "/w0"}));
    let msgs = a.until_answer(id);
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0]["params"]["sessionId"], "old-2");
    assert_eq!(msgs[0]["params"]["update"]["content"]["text"], "said 2");
    assert_eq!(msgs[1]["result"], json!({}));
    let r = a.call("session/load", json!({"sessionId": "nope"}));
    assert_eq!(
        r["error"]["message"],
        "session/load is unsupported for a live session"
    );
    // the loaded session was not changed
    assert_eq!(
        read_store(&store)["sessions"][2]["updates"]
            .as_array()
            .expect("updates")
            .len(),
        1
    );
}

fn read_store(path: &str) -> Value {
    serde_json::from_slice(&std::fs::read(path).expect("the store")).expect("JSON store")
}

#[test]
fn a_new_session_is_recorded_and_a_new_process_can_load_it() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = dir
        .path()
        .join("store.json")
        .to_str()
        .expect("utf-8")
        .to_string();
    store_with(
        &store,
        json!([{"sessionId": "sess-1", "cwd": "/taken", "updates": []}]),
    );
    let sid = {
        let mut a = Agent::start(&[("FAKE_ACP_STORE", &store)]);
        a.init();
        let r = a.call("session/new", json!({"cwd": "/made"}));
        let sid = r["result"]["sessionId"].as_str().expect("id").to_string();
        assert_eq!(sid, "sess-2", "the first free sess-N");
        let msgs = a.turn(&sid, "reply:remember me");
        assert_eq!(chunk_texts(&msgs), ["re: remember me"]);
        sid
    };
    let data = read_store(&store);
    let rec = &data["sessions"][1];
    assert_eq!(rec["sessionId"], sid);
    assert_eq!(rec["cwd"], "/made");
    assert_eq!(rec["own"], true);
    assert_eq!(rec["messageCount"], 2); // the person's text and the agent's chunk
    assert_eq!(
        rec["updates"][0],
        json!({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "reply:remember me"}})
    );
    assert_eq!(rec["updates"][1]["messageId"], "reply-1");
    assert!(rec["updatedAt"].as_str().expect("time").ends_with('Z'));
    let mut b = Agent::start(&[("FAKE_ACP_STORE", &store)]);
    b.init();
    let id = b.ask("session/load", json!({"sessionId": sid}));
    let msgs = b.until_answer(id);
    assert_eq!(msgs.len(), 3);
    assert_eq!(
        msgs[1]["params"]["update"]["content"]["text"],
        "re: remember me"
    );
    // another process's sessions are not recorded into
    let r = b.call("session/new", json!({}));
    assert_eq!(r["result"]["sessionId"], "sess-3");
}

#[test]
fn list_switches_fail_delay_and_noise() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let store = dir
        .path()
        .join("store.json")
        .to_str()
        .expect("utf-8")
        .to_string();
    store_with(&store, stored(1));

    let mut a = Agent::start(&[("FAKE_ACP_STORE", &store), ("FAKE_ACP_LIST_FAIL", "1")]);
    a.init();
    let r = a.call("session/list", json!({}));
    assert_eq!(
        r["error"],
        json!({"code": -32000, "message": "store unreadable"})
    );

    let mut a = Agent::start(&[("FAKE_ACP_STORE", &store), ("FAKE_ACP_LIST_DELAY", "0.3")]);
    a.init();
    let start = Instant::now();
    a.call("session/list", json!({}));
    assert!(start.elapsed() >= Duration::from_millis(300));

    let mut a = Agent::start(&[("FAKE_ACP_STORE", &store), ("FAKE_ACP_LIST_NOISE", "1")]);
    a.init();
    let id = a.ask("session/list", json!({}));
    assert_eq!(a.p.line().expect("a line"), "this is not json");
    let note = a.p.msg();
    assert_eq!(note["method"], "session/update");
    assert_eq!(note["params"]["sessionId"], "x");
    let request = a.p.msg();
    assert_eq!(request["id"], "noise-1");
    assert_eq!(request["method"], "elicitation/create");
    assert!(
        a.p.line_within(Duration::from_millis(200)).is_none(),
        "it waits for the answer"
    );
    a.answer(json!("noise-1"), json!({"action": "cancel"}));
    let r = a.until_answer(id).pop().expect("the list");
    assert_eq!(r["result"]["sessions"][0]["sessionId"], "old-0");
}

#[test]
fn len_counts_the_characters_of_a_prompt_of_any_size() {
    let mut a = Agent::start(&[]);
    let sid = a.session();
    assert_eq!(chunk_texts(&a.turn(&sid, "len:hi")), ["len=2"]);
    assert_eq!(chunk_texts(&a.turn(&sid, "len:é→")), ["len=2"]);
    let big = format!("len:{}", "x".repeat(3_000_000));
    assert_eq!(chunk_texts(&a.turn(&sid, &big)), ["len=3000000"]);
}

#[test]
fn initialize_reports_descriptors_umask_and_chosen_variables_into_files() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().expect("a temp dir");
    let file = |name: &str| dir.path().join(name).to_str().expect("utf-8").to_string();
    let (fds, umask, vars) = (file("fds.json"), file("umask"), file("env.json"));
    let mut a = Agent::start(&[
        ("FAKE_ACP_FDS_FILE", &fds),
        ("FAKE_ACP_UMASK_FILE", &umask),
        ("FAKE_ACP_ENV_FILE", &vars),
        ("FAKE_ACP_ENV_KEYS", "HERDR_KEEPER_UMASK,HERDR_KEEPER_LABEL"),
        ("HERDR_KEEPER_UMASK", "27"),
    ]);
    a.init();
    let seen: Vec<i64> =
        serde_json::from_slice(&std::fs::read(&fds).expect("fds file")).expect("JSON");
    assert_eq!(
        seen,
        [0, 1, 2],
        "a fresh child holds stdin, stdout, stderr only"
    );
    let mode = std::fs::metadata(&umask)
        .expect("umask file")
        .permissions()
        .mode()
        & 0o777;
    assert!(mode != 0, "created with the process umask applied");
    let env: Value =
        serde_json::from_slice(&std::fs::read(&vars).expect("env file")).expect("JSON");
    assert_eq!(
        env,
        json!({"HERDR_KEEPER_UMASK": "27", "HERDR_KEEPER_LABEL": null})
    );
}

#[test]
fn gate_waits_for_its_file_and_a_title_follows_session_new_on_request() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let gate = dir.path().join("gate");
    let gate_path = gate.to_str().expect("utf-8").to_string();
    let mut a = Agent::start(&[
        ("FAKE_ACP_GATE", &gate_path),
        ("FAKE_ACP_TITLE_ON_NEW", "1"),
    ]);
    a.init();
    let id = a.ask("session/new", json!({"cwd": "/w"}));
    let msgs = a.until_answer(id);
    assert_eq!(msgs.len(), 1);
    let titled = a.p.msg();
    assert_eq!(
        titled["params"]["update"],
        json!({"sessionUpdate": "session_info_update", "title": "Fake title"})
    );
    let id = a.prompt_req("sess-1", "gate");
    assert!(
        a.p.line_within(Duration::from_millis(200)).is_none(),
        "the gate is shut"
    );
    std::fs::write(&gate, "").expect("open the gate");
    assert_eq!(stop_reason(&a.until_answer(id)), "end_turn");
}
