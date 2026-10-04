#!/usr/bin/env python3
"""A deterministic stand-in for herdr's API socket, for transfer_bench.dart.

One JSON request per connection, one JSON line back (like the real socket).
Serves `ping`, `session.snapshot` and `pane.read`. Payloads have the shape and
size of what herdr 0.9.3 sends (snapshot: workspaces, tabs, panes, layouts and
agents, ~680 B per pane; pane.read: ANSI rows). Content is seeded, and a pane
advances only when it is read, so a sequential client sees the same bytes in
every run.

usage: fake_herdr.py SOCKET_PATH   (prints READY when listening)
"""
import json
import os
import random
import re
import socket
import sys
import threading

WORKSPACES = 8
PANES = 40
SLIDE = 3  # rows a pane's output moves between two reads
FOOTER = 4  # rows at the bottom that change on every read

WORDS = (
    "final class return await import const if else struct fn let match Future "
    "String widget paint herdr agent pane socket transport notify state "
    "Xin\u00a0chào tiếng\u00a0Việt đường\u00a0dẫn ✓ ● → …"
).split()

SESSION = (
    "/home/user/.omp/agent/sessions/--media-user-data-workspace-project--/"
    "2026-10-02T23-33-15-235Z_01a0fef6-ff63-7588-ad24-4d9497a89aed.jsonl"
)


def pane_ids():
    out = []
    for i in range(PANES):
        w = i % WORKSPACES
        out.append(("w%d" % w, "w%d:t1" % w, "w%d:p%d" % (w, i // WORKSPACES + 1)))
    return out


PANE_LIST = pane_ids()
STATUSES = ["idle", "working", "blocked", "done"]


def snapshot(seq):
    r = random.Random(seq)
    panes, agents = [], []
    for n, (w, t, p) in enumerate(PANE_LIST):
        status = STATUSES[(n + (seq if n % 7 == seq % 7 else 0)) % 4]
        title = "π > Task %d %s" % (n, "Ý tưởng mới" if n % 5 == 0 else "refactor the thing")
        pane = {
            "pane_id": p,
            "terminal_id": "term_%014x" % (n * 7919),
            "workspace_id": w,
            "tab_id": t,
            "focused": n == 3,
            "cwd": "/media/user/data/workspace/project%d" % (n % WORKSPACES),
            "foreground_cwd": "/media/user/data/workspace/project%d" % (n % WORKSPACES),
            "agent": ["omp", "claude", "codex", None][n % 4],
            "terminal_title": title,
            "terminal_title_stripped": title,
            "agent_status": status,
            "agent_session": {
                "source": "herdr:omp",
                "agent": "omp",
                "kind": "path",
                "value": SESSION,
            },
            "scroll": {"offset_from_bottom": 0, "max_offset_from_bottom": 95, "viewport_rows": 28},
            "revision": 4 + seq // 3,
        }
        panes.append(pane)
        if pane["agent"]:
            agents.append({
                "terminal_id": pane["terminal_id"],
                "agent": pane["agent"],
                "terminal_title": title,
                "terminal_title_stripped": title,
                "agent_status": status,
                "screen_detection_skipped": True,
                "agent_session": pane["agent_session"],
                "workspace_id": w,
                "tab_id": t,
                "pane_id": p,
                "focused": pane["focused"],
                "state_change_seq": 7 + seq,
                "cwd": pane["cwd"],
                "foreground_cwd": pane["foreground_cwd"],
                "revision": pane["revision"],
            })
    workspaces = [{
        "workspace_id": "w%d" % w, "number": w + 1, "label": ["research", "herdr-mobile", "Dự án", "infra"][w % 4],
        "focused": w == 0, "pane_count": PANES // WORKSPACES, "tab_count": 1,
        "active_tab_id": "w%d:t1" % w, "agent_status": "working",
    } for w in range(WORKSPACES)]
    tabs = [{
        "tab_id": "w%d:t1" % w, "workspace_id": "w%d" % w, "number": 1, "label": "1",
        "focused": w == 0, "pane_count": PANES // WORKSPACES, "agent_status": "working",
    } for w in range(WORKSPACES)]
    layouts = []
    for w in range(WORKSPACES):
        ids = [p for (ww, _, p) in PANE_LIST if ww == "w%d" % w]
        layouts.append({
            "workspace_id": "w%d" % w, "tab_id": "w%d:t1" % w, "zoomed": False,
            "area": {"x": 0, "y": 0, "width": 120, "height": 40},
            "focused_pane_id": ids[0],
            "panes": [{"pane_id": i, "focused": k == 0,
                       "rect": {"x": 46 * (k % 2), "y": 20 * (k // 2), "width": 46, "height": 20}}
                      for k, i in enumerate(ids)],
            "splits": [{"id": "split_%d_root" % k, "direction": "right", "ratio": 0.3857143,
                        "rect": {"x": 0, "y": 0, "width": 120, "height": 40}} for k in range(len(ids) - 1)],
        })
    return {
        "version": "0.9.3", "protocol": 22,
        "focused_workspace_id": "w0", "focused_tab_id": "w0:t1", "focused_pane_id": "w0:p1",
        "workspaces": workspaces, "tabs": tabs, "panes": panes,
        "layouts": layouts, "agents": agents,
    }


def body_row(pane, absolute):
    r = random.Random(pane * 1000003 + absolute)
    b = ["\x1b[2m%5d \x1b[0m" % absolute]
    cells = 6
    if r.randrange(6) == 0:
        b.insert(0, "\x1b[48;2;20;60;30m")
    if absolute % 11 < 3:
        return "\x1b[38;5;244m┌%s┐\x1b[0m" % ("─" * 94)
    while cells < 100:
        w = WORDS[r.randrange(len(WORDS))]
        if r.random() < 0.9:
            b.append("\x1b[38;2;%d;%d;%dm" % (r.randrange(256), r.randrange(256), r.randrange(256)))
        b.append(w + " ")
        cells += len(w) + 1
        if r.random() < 0.6:
            b.append("\x1b[0m")
    return "".join(b)


def footer_rows(pane, step):
    return [
        "\x1b[38;5;75m%s\x1b[0m working (%ds)" % ("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[step % 10], step),
        "\x1b[2m" + "─" * 100 + "\x1b[0m",
        "> ",
        "\x1b[2mtokens %d  ctx %d%%\x1b[0m" % (step * 37, step % 100),
    ]


STATE = {}  # pane id -> reads so far
LOCK = threading.Lock()
ESC = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def pane_read(params):
    pid = params.get("pane_id")
    index = next((i for i, (_, _, p) in enumerate(PANE_LIST) if p == pid), None)
    if index is None:
        return {"error": {"code": "pane_not_found", "message": "pane %s not found" % pid}}
    with LOCK:
        step = STATE.get(pid, 0)
        STATE[pid] = step + 1
    lines = min(int(params.get("lines") or 1000), 1000)
    newest = 1000 + step * SLIDE
    rows = [body_row(index, a) for a in range(newest - lines + FOOTER, newest)] + footer_rows(index, step)
    rows = rows[-lines:]
    if params.get("strip_ansi", True):
        rows = [ESC.sub("", x) for x in rows]
    return {"result": {"type": "pane_read", "read": {
        "pane_id": pid, "workspace_id": pid.split(":")[0], "tab_id": pid.split(":")[0] + ":t1",
        "source": params.get("source", "recent"), "format": "ansi" if not params.get("strip_ansi", True) else "plain",
        "text": "\r\n".join(rows) + "\r\n", "truncated": False,
    }}}


SEQ = [0]


def handle(conn):
    try:
        b = b""
        while b"\n" not in b:
            d = conn.recv(65536)
            if not d:
                return
            b += d
        req = json.loads(b)
        m, p = req.get("method"), req.get("params") or {}
        if m == "ping":
            out = {"result": {"type": "pong", "version": "0.9.3", "protocol": 22}}
        elif m == "session.snapshot":
            with LOCK:
                SEQ[0] += 1
                seq = SEQ[0]
            out = {"result": {"type": "session_snapshot", "snapshot": snapshot(seq)}}
        elif m == "pane.read":
            out = pane_read(p)
        else:
            out = {"error": {"code": "invalid_request", "message": "unknown variant `%s`" % m}}
        out = dict(id=req.get("id"), **out)  # herdr writes the id first
        conn.sendall(json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
    finally:
        conn.close()


def main():
    path = sys.argv[1]
    if os.path.exists(path):
        os.unlink(path)
    s = socket.socket(socket.AF_UNIX)
    s.bind(path)
    s.listen(64)
    print("READY", flush=True)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
