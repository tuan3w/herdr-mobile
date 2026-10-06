#!/usr/bin/env python3
"""Records a real ACP agent's stdio, line by line, with timestamps.

Driver of `tool/capture-trace.sh` (read its header). It speaks ACP v1 to the
agent the way the app's client does (`app/lib/data/acp/acp_client.dart`:
`initialize` with form elicitation and no fs/terminal, `session/new`,
`session/prompt`) and writes EVERY JSON-RPC line in both directions to

    app/test/fixtures/traces/<agent>/<scenario>.jsonl     one object per line:
        {"t": 1234.567, "dir": "recv" | "send", "msg": {...JSON-RPC...}}
    app/test/fixtures/traces/<agent>/<scenario>.meta.json  how it was captured

`t` is milliseconds on the monotonic clock since the agent process was
spawned; `recv` is a line the agent wrote (as the client read it), `send` a
line the client wrote. Agent stderr is not recorded.

Safety, in this order:
  * the agent runs in a fresh scratch directory (a tiny git repo under /tmp),
    never in a real project;
  * omp and codex get their stores redirected to temp dirs (the login is
    copied or reached through omp's auth broker; codex's access token has days
    left, so the copy is never refreshed). Claude's store is NOT redirected:
    its access token rotates on refresh, and a refreshed copy would invalidate
    the owner's login. Its project folder for the scratch directory is
    removed afterwards;
  * permission requests are answered here, never by default: allow-once only
    when the tool's command / paths stay inside the scratch directory and the
    scenario expects an approval; everything else is rejected and noted in
    the meta file;
  * the child's environment loses ORCA_*, HERDR_*, CLAUDECODE and OMPCODE (the
    owner's status hooks would report this process as a live pane);
  * fixtures are redacted (home -> $HOME, user and host names, emails, tokens)
    and long config option lists are cut, see `redact` and `trim`.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "app" / "test" / "fixtures" / "traces"
HOME = str(Path.home())
SCRATCH_ALIAS = "/tmp/scratch"
MAX_BYTES = 200 * 1024
KEEP_OPTIONS = 24

SAFE_ECHO = "echo hello-from-scratch"

PROMPTS = {
    "markdown": (
        "Do not use any tools and do not read any files. Write a short answer in "
        "Markdown about how a small Python project could be laid out. It must "
        "contain: one `##` heading; a bulleted list with a nested sub-list; a "
        "table with a header and 3 rows; a fenced python code block directly "
        "after a line that cites `src/main.py:12`; a sentence with **bold** text "
        "and `inline code`; and one [link](https://example.com/docs). Under 25 lines."
    ),
    "tools": (
        f"Read the file notes.txt in the current directory, then run the shell command `{SAFE_ECHO}`, "
        "then tell me in one sentence what each of them gave."
    ),
    "plan": (
        "Use your todo/plan tool to write a 3-step plan for adding a --verbose "
        "flag to src/main.py, then mark the steps done one by one WITHOUT editing "
        "any file. Finish with one line."
    ),
    "thinking": (
        "Think hard before answering, no tools: three switches outside a closed room "
        "control three bulbs inside, you may enter once. How do you find which switch "
        "controls which bulb? Answer in at most three sentences."
    ),
    "permission": (
        "Run the shell command `mkdir made-by-agent` in the current directory, "
        "then say it is done in one line."
    ),
    "subagent": (
        "Use the Task tool to start one subagent whose job is to run `ls` and "
        "report the file names it sees. Then answer with the names in one line."
    ),
    "ask": (
        "Use your ask tool to ask me which colour I prefer, with the options red "
        "and blue, then say what I chose in one word."
    ),
}

# What each agent can do. `approve` scenarios expect a permission to be allowed.
AGENTS = {
    "omp": {
        "cmd": ["omp", "acp"],
        "scenarios": ["markdown", "tools", "plan", "thinking", "permission", "ask"],
        "approve": {"permission", "tools"},
        "settle": 1.5,
        "thinking_model": "claude-haiku-4-5",
    },
    "claude": {
        "cmd": ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
        "scenarios": ["markdown", "tools", "plan", "thinking", "subagent", "permission"],
        "approve": {"permission", "subagent", "tools"},
        "settle": 4.0,
        "model": "haiku",
    },
    "codex": {
        "cmd": ["npx", "-y", "@agentclientprotocol/codex-acp"],
        "scenarios": ["markdown", "tools", "plan", "thinking", "permission"],
        "approve": {"permission", "tools"},
        "settle": 1.5,
    },
    "pi": {
        "cmd": ["npx", "-y", "pi-acp"],
        "scenarios": ["markdown", "tools", "plan"],
        "approve": {"tools"},
        "settle": 1.5,
    },
}


class Skip(Exception):
    """The agent cannot be captured here (login missing, process refuses)."""


# --- redaction ------------------------------------------------------------

_USER = os.environ.get("USER") or Path.home().name
_HOST = socket.gethostname()
_PATTERNS = [
    (re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"), "<jwt>"),
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"), "<token>"),
    (re.compile(r"(?i)bearer [A-Za-z0-9._~+/=-]{12,}"), "Bearer <token>"),
    (re.compile(r"\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{16,}"), "<token>"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "user@example.com"),
]


def redact(text: str, scratch: str, extra: list[str]) -> str:
    text = text.replace(scratch, SCRATCH_ALIAS)
    text = text.replace(os.path.realpath(scratch), SCRATCH_ALIAS)
    for path in extra:
        text = text.replace(path, "$HOME/.agent-store")
    text = text.replace(HOME, "$HOME")
    for pat, repl in _PATTERNS:
        text = pat.sub(repl, text)
    for word in {_USER, _HOST}:
        if len(word) >= 3:
            text = re.sub(re.escape(word), "user" if word == _USER else "host", text)
    return text


def trim(msg: object) -> int:
    """Cuts config option lists (omp lists ~780 models) to [KEEP_OPTIONS]
    entries, the selected one kept. Returns how many entries went."""
    cut = 0
    if isinstance(msg, dict):
        for key, value in list(msg.items()):
            if key == "options" and isinstance(value, list) and len(value) > KEEP_OPTIONS:
                sel = msg.get("currentValue")
                keep = value[:KEEP_OPTIONS]
                for o in value[KEEP_OPTIONS:]:
                    if isinstance(o, dict) and sel is not None and o.get("value") == sel:
                        keep.append(o)
                cut += len(value) - len(keep)
                msg[key] = keep
            else:
                cut += trim(value)
    elif isinstance(msg, list):
        for item in msg:
            cut += trim(item)
    return cut


# --- the safety gate on permission requests -------------------------------

_DENY_CMD = re.compile(
    r"\b(sudo|rm\s+-[a-z]*r|curl|wget|ssh|scp|nc|git\s+push|chmod|chown|kill|pkill|dd|mkfs)\b"
)


def _inside(path: str, scratch: str) -> bool:
    if not path:
        return True
    if path.startswith("~") or ".." in Path(path).parts:
        return False
    p = Path(path)
    if not p.is_absolute():
        return True
    real = os.path.realpath(path)
    return real == scratch or real.startswith(scratch + os.sep) or path == "/dev/null"


def command_text(raw: object) -> str:
    if isinstance(raw, dict):
        c = raw.get("command", raw.get("cmd"))
        if isinstance(c, list):
            return " ".join(map(str, c))
        if isinstance(c, str):
            return c
    return ""


def tool_paths(call: dict) -> list[str]:
    paths = []
    for loc in call.get("locations") or []:
        if isinstance(loc, dict) and isinstance(loc.get("path"), str):
            paths.append(loc["path"])
    raw = call.get("rawInput")
    if isinstance(raw, dict):
        for k in ("path", "file_path", "filePath", "cwd", "dir", "notebook_path"):
            if isinstance(raw.get(k), str):
                paths.append(raw[k])
    return paths


def decide(request: dict, scratch: str, allow: bool) -> tuple[dict, str]:
    """(JSON-RPC result, note). Allow-once only inside the scratch directory."""
    params = request.get("params") or {}
    call = params.get("toolCall") or {}
    options = params.get("options") or []

    def pick(*kinds: str):
        for o in options:
            if o.get("kind") in kinds:
                return o.get("optionId")
        return None

    reason = ""
    cmd = command_text(call.get("rawInput"))
    kind = call.get("kind")
    if not allow:
        reason = "scenario does not expect an approval"
    elif kind in ("fetch", "delete", "move"):
        reason = f"kind {kind} is never allowed"
    elif cmd and _DENY_CMD.search(cmd):
        reason = "command matches the deny list"
    elif any(not _inside(p, scratch) for p in tool_paths(call)):
        reason = "a path leaves the scratch directory"
    elif any(not _inside(tok, scratch) for tok in re.findall(r"(?<![\w.$-])/[^\s'\";|&<>]+", cmd)):
        reason = "the command names a path outside the scratch directory"
    elif re.search(r"(~|\$HOME|\.\./)", cmd):
        reason = "the command reaches for the home directory or a parent"
    elif kind not in ("read", "execute", "edit", "search", "think", "other", None):
        reason = f"unexpected kind {kind}"
    elif "exit_plan" in json.dumps(call).lower() or (call.get("title") or "").lower().startswith("ready to code"):
        reason = "plan approval is not part of any scenario"
    if not reason:
        opt = pick("allow_once")
        if opt:
            return {"outcome": {"outcome": "selected", "optionId": opt}}, f"allowed once: {cmd or call.get('title')}"
        reason = "no allow_once option offered"
    opt = pick("reject_once")
    note = f"rejected ({reason}): {cmd or call.get('title')}"
    if opt:
        return {"outcome": {"outcome": "selected", "optionId": opt}}, note
    return {"outcome": {"outcome": "cancelled"}}, note


def elicitation_answer(params: dict) -> dict:
    schema = (params or {}).get("requestedSchema") or {}
    content = {}
    for name, prop in (schema.get("properties") or {}).items():
        if isinstance(prop.get("enum"), list) and prop["enum"]:
            content[name] = prop["enum"][0]
        elif isinstance(prop.get("oneOf"), list) and prop["oneOf"]:
            content[name] = prop["oneOf"][0].get("const")
        elif prop.get("type") == "boolean":
            content[name] = True
        elif prop.get("type") in ("number", "integer"):
            content[name] = 1
        else:
            content[name] = "red"
    return {"action": "accept", "content": content}


# --- environment per agent -------------------------------------------------

def prepare_env(agent: str, scratch: str, tmp: Path) -> tuple[dict, list[str]]:
    env = {
        k: v
        for k, v in os.environ.items()
        if not re.match(r"(ORCA_|HERDR_|CLAUDECODE|CLAUDE_CODE_|OMPCODE|ORCA)", k)
    }
    env["CI"] = "1"
    stores: list[str] = []
    if agent == "omp":
        store = tmp / "omp-agent"
        store.mkdir()
        env["PI_CODING_AGENT_DIR"] = str(store)
        stores.append(str(store))
        src = Path(HOME) / ".omp" / "agent"
        # A consistent copy of the credential/settings database (the owner's
        # omp keeps it open in WAL mode): the sqlite backup API reads it live.
        if (src / "agent.db").exists():
            with sqlite3.connect(f"file:{src / 'agent.db'}?mode=ro", uri=True) as a:
                b = sqlite3.connect(store / "agent.db")
                a.backup(b)
                b.close()
        if (src / "config.yml").exists():
            shutil.copy(src / "config.yml", store / "config.yml")
    elif agent == "codex":
        store = tmp / "codex-home"
        store.mkdir()
        env["CODEX_HOME"] = str(store)
        stores.append(str(store))
        auth = Path(HOME) / ".codex" / "auth.json"
        if not auth.exists():
            raise Skip("no ~/.codex/auth.json: log in with `codex login`")
        shutil.copy(auth, store / "auth.json")
        os.chmod(store / "auth.json", 0o600)
        # No model line: the owner's pick (a model this account lacks) must not leak in.
        (store / "config.toml").write_text(f'[projects."{scratch}"]\ntrust_level = "trusted"\n')
    elif agent == "claude":
        if not (Path(HOME) / ".claude" / ".credentials.json").exists() and not env.get("ANTHROPIC_API_KEY"):
            raise Skip("no ~/.claude/.credentials.json: log in with `claude`")
    elif agent == "pi":
        store = tmp / "pi-agent"
        store.mkdir()
        env["PI_CODING_AGENT_DIR"] = str(store)
        stores.append(str(store))
        raise Skip("pi's login is expired (docs/AGENT_SESSIONS.md); not worked around")
    return env, stores


def make_scratch() -> str:
    d = os.path.realpath(tempfile.mkdtemp(prefix="herdr-trace-"))
    files = {
        "README.md": "# scratch\n\nA tiny repo for ACP traces.\n",
        "notes.txt": "The build is green.\nNext step: ship it.\n",
        "src/main.py": "def main():\n    print('hello')\n\n\nif __name__ == '__main__':\n    main()\n",
    }
    for rel, body in files.items():
        p = Path(d) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)
    git = ["git", "-c", "user.name=trace", "-c", "user.email=trace@example.com"]
    subprocess.run(["git", "init", "-q"], cwd=d, check=True)
    subprocess.run(["git", "add", "-A"], cwd=d, check=True)
    subprocess.run([*git, "commit", "-q", "-m", "scratch"], cwd=d, check=True)
    return d


# --- the session ------------------------------------------------------------

class Recorder:
    def __init__(self, proc: subprocess.Popen, scratch: str, extra: list[str]):
        self.proc = proc
        self.scratch = scratch
        self.extra = extra
        self.t0 = time.monotonic()
        self.rows: list[dict] = []
        self.inbox: "queue.Queue[tuple[float, str | None]]" = queue.Queue()
        self.stderr = bytearray()
        self.cut = 0
        self.notes: list[str] = []
        self._id = 0
        threading.Thread(target=self._read_out, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def now(self) -> float:
        return (time.monotonic() - self.t0) * 1000.0

    def _read_out(self):
        for raw in self.proc.stdout:
            self.inbox.put((self.now(), raw.decode("utf-8", "replace").rstrip("\r\n")))
        self.inbox.put((self.now(), None))

    def _read_err(self):
        for raw in self.proc.stderr:
            self.stderr += raw
            del self.stderr[:-8192]

    def _keep(self, t: float, direction: str, line: str):
        if not line.strip():
            return
        try:
            msg = json.loads(redact(line, self.scratch, self.extra))
        except json.JSONDecodeError:
            self.notes.append(f"non-JSON line from the agent at {t:.0f} ms, dropped")
            return
        self.cut += trim(msg)
        self.rows.append({"t": round(t, 3), "dir": direction, "msg": msg})

    def send(self, obj: dict):
        line = json.dumps(obj, separators=(",", ":"))
        t = self.now()
        self.proc.stdin.write((line + "\n").encode())
        self.proc.stdin.flush()
        self._keep(t, "send", line)

    def request(self, method: str, params: dict) -> int:
        self._id += 1
        self.send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        return self._id

    def wait_for(self, rid: int, timeout: float, on_request=None):
        """Pumps agent lines until the response to [rid]; returns its result."""
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise TimeoutError(f"no answer to request {rid} in {timeout:.0f} s")
            try:
                t, line = self.inbox.get(timeout=min(left, 1.0))
            except queue.Empty:
                if self.proc.poll() is not None and self.inbox.empty():
                    raise Skip(f"agent exited ({self.proc.returncode}): {self.stderr.decode('utf-8', 'replace')[-400:]}")
                continue
            if line is None:
                raise Skip(f"agent closed stdout: {self.stderr.decode('utf-8', 'replace')[-400:]}")
            self._keep(t, "recv", line)
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "method" in msg and "id" in msg:
                if on_request:
                    on_request(msg)
            elif msg.get("id") == rid and "method" not in msg:
                if "error" in msg:
                    raise RuntimeError(json.dumps(msg["error"])[:400])
                return msg.get("result")

    def drain(self, seconds: float, on_request=None):
        """Keeps recording for [seconds] after the turn (late updates)."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                t, line = self.inbox.get(timeout=0.2)
            except queue.Empty:
                continue
            if line is None:
                return
            self._keep(t, "recv", line)
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "method" in msg and "id" in msg and on_request:
                on_request(msg)
                end = max(end, time.monotonic() + 1.0)


def pick_option(options: list[dict], *prefer: str) -> object:
    values = [o.get("value") for o in options if isinstance(o, dict)]
    for want in prefer:
        for o in options:
            if isinstance(o, dict) and want in f"{o.get('value')} {o.get('name')}".lower():
                return o.get("value")
    return values[-1] if values else None


def capture(agent: str, scenario: str, force: bool, timeout: float) -> str:
    spec = AGENTS[agent]
    out = FIXTURES / agent / f"{scenario}.jsonl"
    if out.exists() and not force:
        return f"{agent}/{scenario}: exists (use --force)"
    tmp = Path(tempfile.mkdtemp(prefix="herdr-trace-stores-"))
    scratch = make_scratch()
    proc = None
    try:
        env, stores = prepare_env(agent, scratch, tmp)
        proc = subprocess.Popen(
            spec["cmd"], cwd=scratch, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        rec = Recorder(proc, scratch, stores)
        decisions: list[str] = []

        def on_request(msg: dict):
            method = msg.get("method")
            if method == "session/request_permission":
                result, note = decide(msg, scratch, scenario in spec["approve"])
                decisions.append(note)
                print(f"  permission: {note}", file=sys.stderr)
                rec.send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
            elif method == "elicitation/create":
                decisions.append("answered a form with its first option")
                rec.send({"jsonrpc": "2.0", "id": msg["id"], "result": elicitation_answer(msg.get("params"))})
            else:
                rec.send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "Method not found"}})

        init = rec.wait_for(
            rec.request("initialize", {
                "protocolVersion": 1,
                "clientCapabilities": {
                    "fs": {"readTextFile": False, "writeTextFile": False},
                    "terminal": False,
                    "elicitation": {"form": {}},
                },
                "clientInfo": {"name": "herdr-mobile", "title": "herdr mobile", "version": "0"},
            }),
            180,
        )
        if init.get("authMethods") and agent in ("codex",) and not (Path(HOME) / ".codex" / "auth.json").exists():
            raise Skip("agent asks for sign-in")
        setup = rec.wait_for(rec.request("session/new", {"cwd": scratch, "mcpServers": []}), 180, on_request)
        sid = setup["sessionId"]
        options = setup.get("configOptions") or []

        def set_option(config_id: str, value: object):
            res = rec.wait_for(
                rec.request("session/set_config_option", {"sessionId": sid, "configId": config_id, "value": value}),
                60, on_request,
            )
            return (res or {}).get("configOptions") or options

        chosen = {}
        wanted = (spec.get("thinking_model") if scenario == "thinking" else None) or spec.get("model")
        if wanted:
            for o in options:
                if o.get("id") == "model" and isinstance(o.get("options"), list):
                    v = pick_option(o["options"], wanted)
                    if v is not None and v != o.get("currentValue"):
                        options = set_option("model", v)
                        chosen["model"] = v
        if scenario == "thinking":
            for o in options:
                if o.get("category") == "thought_level" or o.get("id") in ("thinking", "effort", "thought_level", "reasoning_effort"):
                    if isinstance(o.get("options"), list):
                        v = pick_option(o["options"], "high", "medium")
                        if v is not None and v != o.get("currentValue"):
                            options = set_option(o["id"], v)
                            chosen[o["id"]] = v
        prompt_at = rec.now()
        stop = None
        try:
            rid = rec.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": PROMPTS[scenario]}]})
            stop = (rec.wait_for(rid, timeout, on_request) or {}).get("stopReason")
        except TimeoutError:
            rec.send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}})
            rec.notes.append(f"turn cancelled after {timeout:.0f} s")
            stop = "timeout"
        rec.drain(spec["settle"], on_request)
        try:
            proc.stdin.close()
        except OSError:
            pass
        for _ in range(50):
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        _terminate(proc)

        text = "".join(json.dumps(r, separators=(",", ":"), ensure_ascii=False) + "\n" for r in rec.rows)
        size = len(text.encode())
        if size > MAX_BYTES:
            raise RuntimeError(f"{agent}/{scenario}: {size} bytes > {MAX_BYTES}; shorten the prompt")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        ver = init.get("agentInfo") or {}
        meta = {
            "agent": agent,
            "scenario": scenario,
            "prompt": PROMPTS[scenario],
            "command": " ".join(spec["cmd"]),
            "agentInfo": ver,
            "capturedOn": time.strftime("%Y-%m-%d"),
            "promptSentAtMs": round(prompt_at, 3),
            "stopReason": stop,
            "lines": len(rec.rows),
            "bytes": size,
            "optionsCut": rec.cut,
            "configChosen": chosen,
            "permissionDecisions": [redact(d, scratch, stores) for d in decisions],
            "notes": rec.notes,
        }
        out.with_suffix(".meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
        return f"{agent}/{scenario}: {len(rec.rows)} lines, {size} bytes, stop={stop}"
    finally:
        if proc and proc.poll() is None:
            _terminate(proc)
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(scratch, ignore_errors=True)
        if agent == "claude":
            slug = re.sub(r"[^A-Za-z0-9]", "-", scratch)
            shutil.rmtree(Path(HOME) / ".claude" / "projects" / slug, ignore_errors=True)


def _terminate(proc: subprocess.Popen):
    """Ends the agent we spawned, and its process group (our own PID only)."""
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=4)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("agent", choices=[*AGENTS, "all"])
    ap.add_argument("scenarios", nargs="*", help="default: every scenario of the agent")
    ap.add_argument("--force", action="store_true", help="overwrite existing fixtures")
    ap.add_argument("--timeout", type=float, default=240, help="seconds per turn")
    args = ap.parse_args()
    agents = list(AGENTS) if args.agent == "all" else [args.agent]
    failed = 0
    for agent in agents:
        for scenario in args.scenarios or AGENTS[agent]["scenarios"]:
            if scenario not in AGENTS[agent]["scenarios"]:
                print(f"{agent}/{scenario}: not a scenario of {agent}, skipped")
                continue
            print(f"capturing {agent}/{scenario} ...", file=sys.stderr)
            try:
                print(capture(agent, scenario, args.force, args.timeout))
            except Skip as e:
                print(f"{agent}/{scenario}: SKIPPED: {e}")
                break  # same cause for every scenario of this agent
            except Exception as e:  # noqa: BLE001 - report and go on
                failed += 1
                print(f"{agent}/{scenario}: FAILED: {type(e).__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
