#!/usr/bin/env python3
"""A scripted ACP agent for the keeper tests (python 3, standard library).

Speaks JSON-RPC lines on stdio like the real adapters: `initialize`,
`session/new`, `session/prompt` (behaviour chosen by the prompt text),
`session/cancel`, and `session/load`, which it refuses ("unsupported while
live"). Exits on EOF like claude-agent-acp, codex-acp and pi-acp.

Every message it receives is appended to the file in $FAKE_ACP_LOG as one JSON
line `{"recv": {...}}`, so a test can count what reached the agent.

Prompt texts:
  plain         two message chunks, end_turn
  ask           title, a chunk, a permission (id 7001), then a question (id
                "elic-1"), then a chunk saying what was answered, end_turn
  perm:<title>  one permission whose tool title is <title>, then end_turn
  slow          a chunk, then waits for session/cancel and ends `cancelled`
  noise         garbage lines on stdout, then a chunk, end_turn
  die           a permission request, then exits with code 3 (stderr: boom)
  sleep:<s>     a chunk, then ends the turn after <s> seconds
  exit:<n>      exits with code <n> at once
  long:<n>      <n> chunks with distinct message ids, end_turn
  heavy:<tools>:<min KB>:<max KB>:<label>
                a thought, <tools> tool calls with <min>..<max> KB outputs (start,
                progress, finish; a big rawInput each; every fifth an edit with a
                diff), then `answer <label>`, end_turn. `heavyhold:` is the same
                without the answer: the turn stays open until session/cancel.
  big:<n>       a tool call update, then a chunk, each with <n> bytes of output, end_turn
  reply:<text>  one chunk "re: <text>" with its own message id, end_turn
  quiet:<s>     says nothing for <s> seconds, then end_turn
  task:<id>     an `async_task_spawned` (shell, canStop) for <id>, a chunk, end_turn
  sdktask:<id>  Claude's raw `_claude/sdkMessage` `background_tasks_changed` naming <id>
                (a `local_bash`), a chunk, end_turn
  sdkend:<id>   `background_tasks_changed` with no tasks, end_turn
`_session/async_task/stop {asyncTaskId}` answers {stopped: true} and sends an
`async_task_state_update` `stopped` for a task spawned with `task:`, else {stopped: false}.
Busy guard (omp's `AgentBusyError`, `-32003 sessionBusy`): while the file named
by $FAKE_ACP_BUSY_FILE exists, the agent is busy with an autonomous turn of its
own: a prompt gets one chunk of that turn's output and then the error, and is
not taken (nothing of it is "said" afterwards). A file that says "quiet" makes
the agent refuse without that chunk.
Environment: FAKE_ACP_IGNORE_TERM=1 ignores SIGTERM; FAKE_ACP_FAIL_INIT=1
exits with code 5 before answering initialize; FAKE_ACP_INIT_DELAY=<s> waits
that long before answering initialize (a cold `npx -y`); FAKE_ACP_PID_FILE=<file>
gets a line `<pid>\t<cwd>` appended when it answers initialize.
The agent's own store (what survives the process, like omp's session folder):
FAKE_ACP_STORE=<json file> {"sessions": [{sessionId, cwd, title?, updatedAt?,
messageCount?, updates: [session/update payloads]}]}. With it set, initialize
advertises loadSession, sessionCapabilities.list and .resume (FAKE_ACP_CAPS=
list,load,resume narrows it to the listed ones), `session/list` answers from
the file (`cwd` filter, FAKE_ACP_PAGE sessions per page with a `nextCursor`;
FAKE_ACP_LIST_FAIL=1 answers an error, FAKE_ACP_LIST_DELAY=<s> waits first,
FAKE_ACP_LIST_NOISE=1 first sends a garbage line, a notification and a request
(`elicitation/create`, id noise-1) and waits for its answer), `session/load` of a stored id replays
its updates and answers `{}`, and `session/new` records the session (id: the
first free `sess-N`) with every update it sends, so a NEW agent process can
load it later. Without FAKE_ACP_STORE the agent is as before (no list/load).
"""
import json
import os
import signal
import sys
import time

LOG = os.environ.get("FAKE_ACP_LOG")
backlog = []
cancelled = False
replies = 0
spawned = set()


def note(obj):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps(obj) + "\n")


# The agent's own store (FAKE_ACP_STORE): what survives the agent process, like
# omp's ~/.omp/agent/sessions. A JSON file {"sessions": [{sessionId, cwd, title?,
# updatedAt?, messageCount?, updates: [session/update payloads]}]}.
STORE = os.environ.get("FAKE_ACP_STORE")
PAGE = int(os.environ.get("FAKE_ACP_PAGE") or 50)
PID_FILE = os.environ.get("FAKE_ACP_PID_FILE")


def store_read():
    try:
        with open(STORE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data.get("sessions"), list):
        data["sessions"] = []
    return data


def store_write(data):
    tmp = "%s.tmp%d" % (STORE, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, STORE)


def store_find(data, sid):
    for s in data["sessions"]:
        if s.get("sessionId") == sid:
            return s
    return None


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def new_session_id(counter, cwd):
    """`sess-N` as always; with a store, the first N it does not hold yet, and
    the session is recorded there with the folder it was made for."""
    if not STORE:
        return "sess-%d" % counter
    data = store_read()
    n = 1
    while store_find(data, "sess-%d" % n):
        n += 1
    sid = "sess-%d" % n
    data["sessions"].append({
        "sessionId": sid, "cwd": cwd or os.getcwd(), "updatedAt": now_iso(),
        "messageCount": 0, "updates": [], "own": True,
    })
    store_write(data)
    return sid


def store_record(sid, upd):
    """Remembers an update of a session this agent made, in the store."""
    if not STORE:
        return
    data = store_read()
    s = store_find(data, sid)
    if s is None or not s.get("own"):
        return
    s.setdefault("updates", []).append(upd)
    s["updatedAt"] = now_iso()
    s["messageCount"] = sum(
        1 for u in s["updates"] if u.get("sessionUpdate") in ("user_message_chunk", "agent_message_chunk")
    )
    store_write(data)


def capabilities():
    caps = {"loadSession": False, "promptCapabilities": {"image": True}}
    if STORE:
        wanted = (os.environ.get("FAKE_ACP_CAPS") or "list,load,resume").split(",")
        caps["loadSession"] = "load" in wanted
        sc = {}
        if "list" in wanted:
            sc["list"] = {}
        if "resume" in wanted:
            sc["resume"] = {}
        if sc:
            caps["sessionCapabilities"] = sc
    return caps


def list_sessions(rid, params):
    """`session/list` from the store: the `cwd` filter, FAKE_ACP_PAGE per page,
    the cursor is the offset of the next page. FAKE_ACP_LIST_FAIL=1 answers an
    error; FAKE_ACP_LIST_DELAY=<s> waits first; FAKE_ACP_LIST_NOISE=1 first
    prints a garbage line, a notification and a request of its own
    (elicitation/create, id noise-1) and waits for the answer to that request."""
    time.sleep(float(os.environ.get("FAKE_ACP_LIST_DELAY") or 0))
    if os.environ.get("FAKE_ACP_LIST_NOISE"):
        sys.stdout.write("this is not json\n")
        sys.stdout.flush()
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "x", "update": {"sessionUpdate": "current_mode_update"}}})
        send({"jsonrpc": "2.0", "id": "noise-1", "method": "elicitation/create", "params": {"mode": "form", "message": "?"}})
        wait_response("noise-1")
    if os.environ.get("FAKE_ACP_LIST_FAIL"):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "store unreadable"}})
        return
    rows = store_read()["sessions"] if STORE else []
    cwd = params.get("cwd")
    if cwd is not None:
        rows = [s for s in rows if s.get("cwd") == cwd]
    try:
        start = int(params.get("cursor") or 0)
    except ValueError:
        start = 0
    out = []
    for s in rows[start:start + PAGE]:
        row = {"sessionId": s.get("sessionId"), "cwd": s.get("cwd")}
        for k in ("title", "updatedAt"):
            if s.get(k) is not None:
                row[k] = s[k]
        if s.get("messageCount") is not None:
            row["_meta"] = {"messageCount": s["messageCount"], "size": 1}
        out.append(row)
    result = {"sessions": out}
    if start + PAGE < len(rows):
        result["nextCursor"] = str(start + PAGE)
    send({"jsonrpc": "2.0", "id": rid, "result": result})


def load_session(rid, params):
    """`session/load` of a session in the store: its updates are replayed, then
    the answer. Anything else is refused like a live session."""
    s = store_find(store_read(), params.get("sessionId")) if STORE else None
    if s is None:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "session/load is unsupported for a live session"}})
        return
    for upd in s.get("updates") or []:
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": s["sessionId"], "update": upd}})
    send({"jsonrpc": "2.0", "id": rid, "result": {}})


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def read():
    global cancelled
    if backlog:
        return backlog.pop(0)
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        note({"recv": msg})
        if msg.get("method") == "session/cancel":
            cancelled = True
        return msg


def wait_response(rid):
    """Reads until the answer to our request `rid`; other requests wait."""
    skipped = []
    try:
        while True:
            msg = read()
            if msg is None:
                sys.exit(0)
            if "method" not in msg and msg.get("id") == rid:
                return msg
            if msg.get("method") != "session/cancel":
                skipped.append(msg)
    finally:
        backlog[:0] = skipped


def update(sid, upd):
    store_record(sid, upd)
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})


def sdk_level(sid, tasks):
    send({"jsonrpc": "2.0", "method": "_claude/sdkMessage", "params": {"sessionId": sid, "message": {
        "type": "system", "subtype": "background_tasks_changed", "tasks": tasks, "uuid": "u", "session_id": sid}}})



def chunk(sid, text, mid=None):
    u = {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}
    if mid:
        u["messageId"] = mid
    update(sid, u)


def prompt_text(params):
    for b in params.get("prompt") or []:
        if isinstance(b, dict) and b.get("type") == "text":
            return b.get("text", "")
    return ""


def permission(sid, rid, title):
    send({
        "jsonrpc": "2.0", "id": rid, "method": "session/request_permission",
        "params": {
            "sessionId": sid,
            "toolCall": {"toolCallId": "tc-%s" % rid, "title": title, "kind": "execute", "status": "pending"},
            "options": [
                {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
            ],
        },
    })
    return wait_response(rid)


def hold_until_cancel():
    global cancelled
    later = []
    while not cancelled:
        m = read()
        if m is None:
            sys.exit(0)
        if m.get("method") != "session/cancel":
            later.append(m)
    backlog[:0] = later


def heavy(sid, text):
    """heavy:<tools>:<min KB>:<max KB>:<label>: a thought, <tools> tool calls
    (start, progress, finish with 'output of min..max KB', half of them in
    `rawOutput`, half in `content`, each with a big `rawInput`, an edit now and
    then with a diff), then the answer `answer <label>`. `heavyhold:` is the
    same without the answer: the turn stays open until session/cancel."""
    _, tools, lo, hi, label = text.split(":")
    lo, hi = int(lo), int(hi)
    chunk_kind = {"sessionUpdate": "agent_thought_chunk", "messageId": "think-" + label}
    update(sid, dict(chunk_kind, content={"type": "text", "text": "thinking about turn " + label}))
    for i in range(int(tools)):
        tid = "t%s-%d" % (label, i)
        size = (lo + (i * 7919) % (hi - lo + 1)) * 1024
        output = "output of %s: " % tid + "x" * size
        edit = i % 5 == 4
        update(sid, {
            "sessionUpdate": "tool_call", "toolCallId": tid, "title": "Run: step %d of turn %s" % (i, label),
            "kind": "edit" if edit else "execute", "status": "pending",
            "rawInput": {"command": "step %d" % i, "script": "s" * 3000},
            "locations": [{"path": "/work/f%d.txt" % i, "line": 1}],
        })
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "in_progress"})
        done = {"sessionUpdate": "tool_call_update", "toolCallId": tid, "status": "completed"}
        if i % 2:
            done["rawOutput"] = output
        else:
            done["content"] = [{"type": "content", "content": {"type": "text", "text": output}}]
        if edit:
            done["content"] = done.get("content", []) + [
                {"type": "diff", "path": "/work/f%d.txt" % i, "oldText": "a\n" * 500, "newText": "b\n" * 500},
            ]
        update(sid, done)
    if text.startswith("heavy:"):
        chunk(sid, "answer " + label, "answer-" + label)


def prompt(msg):
    global replies
    sid = msg["params"]["sessionId"]
    busy = os.environ.get("FAKE_ACP_BUSY_FILE")
    if busy and os.path.exists(busy):
        with open(busy) as f:
            if f.read().strip() != "quiet":
                chunk(sid, "subagent progress", "own-turn")
        send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32003, "message": "Session is busy"}})
        return
    text = prompt_text(msg["params"])
    store_record(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}})
    stop = "end_turn"
    if text == "plain":
        chunk(sid, "Hel")
        chunk(sid, "lo")
    elif text == "ask":
        update(sid, {"sessionUpdate": "session_info_update", "title": "Fake title"})
        chunk(sid, "thinking")
        p = permission(sid, 7001, "Run: ls -la")
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-7001", "status": "completed"})
        send({
            "jsonrpc": "2.0", "id": "elic-1", "method": "elicitation/create",
            "params": {
                "sessionId": sid, "mode": "form", "message": "Pick one?\nsecond line",
                "requestedSchema": {"type": "object", "properties": {"value": {"type": "string", "enum": ["a", "b"]}}},
            },
        })
        e = wait_response("elic-1")
        chunk(sid, "answered:%s/%s" % (
            (p.get("result") or {}).get("outcome", {}).get("optionId"),
            (e.get("result") or {}).get("action"),
        ))
    elif text.startswith("perm:"):
        permission(sid, 7002, text[5:])
    elif text == "slow":
        chunk(sid, "working")
        hold_until_cancel()
        stop = "cancelled"
    elif text == "noise":
        sys.stdout.write("this is not json\n[1,2,3]\n\n")
        sys.stdout.flush()
        chunk(sid, "after noise")
    elif text == "die":
        send({
            "jsonrpc": "2.0", "id": 7003, "method": "session/request_permission",
            "params": {"sessionId": sid, "toolCall": {"toolCallId": "tc-7003", "title": "Doomed"}, "options": []},
        })
        sys.stderr.write("boom\n")
        sys.stderr.flush()
        os._exit(3)
    elif text.startswith("sleep:"):
        chunk(sid, "sleeping")
        time.sleep(float(text[6:]))
    elif text.startswith("exit:"):
        os._exit(int(text[5:]))
    elif text.startswith("big:"):
        n = int(text[4:])
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "big-1", "status": "completed", "title": "Big output",
                     "content": [{"type": "content", "content": {"type": "text", "text": "y" * n}}]})
        chunk(sid, "z" * n, "mbig")
        chunk(sid, "tail", "mtail")
    elif text.startswith("quiet:"):
        time.sleep(float(text[6:]))
    elif text.startswith("reply:"):
        replies += 1
        chunk(sid, "re: " + text[6:], "reply-%d" % replies)
    elif text.startswith("task:"):
        tid = text[5:]
        spawned.add(tid)
        update(sid, {"sessionUpdate": "async_task_spawned", "asyncTaskId": tid, "name": "sleep 600", "taskType": "shell",
                     "description": "sleep 600", "showInTranscript": False, "canStop": True, "toolCallId": "tc-" + tid})
        chunk(sid, "started " + tid)
    elif text.startswith("sdktask:"):
        sdk_level(sid, [{"task_id": text[8:], "task_type": "local_bash", "description": "sleep 600"}])
        chunk(sid, "started " + text[8:])
    elif text.startswith("sdkend:"):
        sdk_level(sid, [])
    elif text.startswith("long:"):
        for i in range(int(text[5:])):
            chunk(sid, "line %d " % i, "m%d" % i)
    elif text.startswith("heavy:") or text.startswith("heavyhold:"):
        heavy(sid, text)
        if text.startswith("heavyhold:"):
            hold_until_cancel()
            stop = "cancelled"
    send({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": stop}})


def main():
    global cancelled
    if os.environ.get("FAKE_ACP_IGNORE_TERM"):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sessions = 0
    sys.stderr.write("fake agent up\n")
    sys.stderr.flush()
    while True:
        msg = read()
        if msg is None:
            return
        method = msg.get("method")
        if "id" not in msg or method is None:
            continue
        rid = msg["id"]
        if method == "initialize":
            if PID_FILE:
                with open(PID_FILE, "a") as f:
                    f.write("%d\t%s\n" % (os.getpid(), os.getcwd()))
            if os.environ.get("FAKE_ACP_FAIL_INIT"):
                sys.stderr.write("cannot start: no login\n")
                sys.stderr.flush()
                sys.exit(5)
            time.sleep(float(os.environ.get("FAKE_ACP_INIT_DELAY") or 0))
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "fake-acp", "version": "1"},
                "agentCapabilities": capabilities(),
                "authMethods": [],
            }})
        elif method == "session/new":
            sessions += 1
            sid = new_session_id(sessions, (msg.get("params") or {}).get("cwd"))
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "sessionId": sid,
                "modes": {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}]},
            }})
        elif method == "session/load":
            load_session(rid, msg.get("params") or {})
        elif method == "session/prompt":
            cancelled = False
            prompt(msg)
        elif method == "session/list":
            list_sessions(rid, msg.get("params") or {})
        elif method == "_session/async_task/stop":
            tid = (msg.get("params") or {}).get("asyncTaskId")
            stopped = tid in spawned
            if stopped:
                spawned.discard(tid)
                update(msg["params"]["sessionId"], {"sessionUpdate": "async_task_state_update", "asyncTaskId": tid, "state": "stopped"})
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopped": stopped}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown method " + method}})


main()
