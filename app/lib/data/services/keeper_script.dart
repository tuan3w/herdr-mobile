/// The host-side keeper (`docs/AGENT_SESSIONS.md`, "The keeper"): one python3
/// file, standard library only, python 3.6+. `keeper_command.dart` fills
/// [keeperRoutesSlot] with `agentRoutes` and installs the result once per host
/// as `~/.herdr-mobile/keeper-<version>.py`.
///
/// Subcommands: `probe`, `list`, `start --agent ID --cwd DIR`, `attach ID`,
/// `kill ID`, `follow PATH [--from N]`, `history AGENT [CWD]`. It is plain python:
/// `python3 keeper-<version>.py list`.
library;

/// Where `keeper_command.dart` puts the JSON route table.
const keeperRoutesSlot = '@@ROUTES@@';

const keeperPython = r'''
"""herdr-keeper: owns one ACP agent process so it outlives the phone's SSH link.

Subcommands: probe | list | start --agent ID --cwd DIR | attach ID [--z] | kill ID
| follow PATH [--from N] | history AGENT [CWD].
Single file, python 3.6+, standard library only. Design: docs/AGENT_SESSIONS.md.
"""
import base64
import collections
import errno
import json
import os
import re
import select
import stat
import sys
import time
import zlib


def load_daemon_modules():
    """Imports what every command but `follow` uses. `follow` (the chat of an
    agent in a pane) is waited for on every open and uses none of them;
    `traceback` alone pulls in a dozen modules, about 30 ms of a start on the
    machine this was measured on (python 3.14, desktop)."""
    global glob, secrets, selectors, signal, socket, subprocess, traceback
    import glob
    import secrets
    import selectors
    import signal
    import socket
    import subprocess
    import traceback

ROUTES = json.loads(r"""@@ROUTES@@""")

ID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
ID_RE = re.compile(r"^[a-z0-9]{3,32}$")

EX_USAGE = 64
EX_GONE = 66
EX_EXITED = 67
EX_MISSING = 69
EX_FAILED = 70
EX_NOPYTHON = 78

KEEP_EXITED = 24 * 3600
INIT_TIMEOUT = 120
MAX_CLIENT_LINE = 32 * 1024 * 1024
MAX_AGENT_LINE = 64 * 1024 * 1024
MAX_CLIENT_OUT = 64 * 1024 * 1024
DIAG_MAX = 1024 * 1024
DIAG_KEEP = 256 * 1024
HELD = ("session/request_permission", "elicitation/create")
SESSION_BUSY = -32003
CHUNKS = ("agent_message_chunk", "agent_thought_chunk", "user_message_chunk")
INIT_ID = "keeper-init"

# `history`: what the agent remembers (session/list), bounded so the line stays small.
HISTORY_PAGES = 5
HISTORY_MAX = 200
HISTORY_REQUEST = 30
HISTORY_TITLE = 300


def envint(name, default):
    try:
        v = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return v if v > 0 else default


LOG_BYTES = envint("HERDR_KEEPER_LOG_BYTES", 16 * 1024 * 1024)
LOG_COUNT = envint("HERDR_KEEPER_LOG_MESSAGES", 20000)
# The newest turns whose tool detail the log cuts last (a turn is a user message and its answer).
LOG_FULL_TURNS = envint("HERDR_KEEPER_FULL_TURNS", 3)
# What a replay should cost: past it the oldest turns lose their tool detail.
LOG_SOFT_BYTES = envint("HERDR_KEEPER_LOG_SOFT_BYTES", 1536 * 1024)
# Files of a keeper that has no record yet are not stale before this many seconds.
ORPHAN_AFTER = envint("HERDR_KEEPER_ORPHAN_SECONDS", INIT_TIMEOUT + 30)

# `follow`: a session log read for the phone (see cmd_follow).
FOLLOW_TAIL = 192 * 1024
FOLLOW_TAIL_MIN = 16 * 1024
FOLLOW_TAIL_MAX = 8 * 1024 * 1024
FOLLOW_CUT = 16 * 1024
FOLLOW_RAW = 2048
FOLLOW_LINE = 4 * 1024 * 1024
FOLLOW_READ = 1024 * 1024
FOLLOW_POLL = 0.25
# (seconds without growth, poll interval from then on): a quiet log is looked
# at less often, any growth goes back to the base interval.
FOLLOW_BACKOFF = ((60, 1.0), (600, 2.0))
FOLLOW_BINARY_TYPES = ("image", "base64", "audio", "input_audio", "input_image", "binary")
FOLLOW_BINARY_KEYS = ("data", "base64", "bytes", "b64_json", "blob")
FOLLOW_B64 = re.compile(r"^[A-Za-z0-9+/=_-]+$")


def now_ms():
    return int(time.time() * 1000)


def fail(code, text):
    sys.stderr.write("herdr-mobile: " + text + "\n")
    sys.stderr.flush()
    sys.exit(code)


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"))


def enc(obj):
    return (dumps(obj) + "\n").encode("ascii")


def trunc(text, n):
    text = str(text)
    return text if len(text) <= n else text[: n - 1] + "\u2026"


# -- host ------------------------------------------------------------------


def home_dir():
    return os.path.expanduser("~")


def state_dir():
    base = os.path.join(home_dir(), ".herdr-mobile")
    d = os.path.join(base, "keepers")
    for p in (base, d):
        try:
            os.mkdir(p, 0o700)
        except OSError as e:
            if e.errno != errno.EEXIST:
                raise
    os.chmod(d, 0o700)
    return d


def search_dirs():
    h = home_dir()
    found = []

    def add(d):
        if d and d not in found and os.path.isdir(d):
            found.append(d)

    for d in os.environ.get("PATH", "").split(":"):
        add(d)
    for d in (
        os.path.join(h, ".local", "bin"),
        os.path.join(h, ".local", "share", "herdr-mobile", "acp-adapters", "node_modules", ".bin"),
        os.path.join(h, ".bun", "bin"),
        os.path.join(h, ".cargo", "bin"),
        os.path.join(h, ".npm-global", "bin"),
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ):
        add(d)
    for d in sorted(glob.glob(os.path.join(h, ".nvm", "versions", "node", "*", "bin")), reverse=True):
        add(d)
    return found


def which(name, dirs):
    for d in dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def route_by_id(rid):
    for r in ROUTES:
        if r["id"] == rid:
            return r
    return None


def resolve(route, dirs):
    b = which(route["binary"], dirs)
    if b:
        return [b] + list(route.get("args") or [])
    pkg = route.get("npx")
    if pkg:
        n = which("npx", dirs)
        if n:
            return [n, "-y", pkg]
    return None


# -- records on disk -------------------------------------------------------


def write_json(name, data):
    tmp = "%s.tmp%d" % (name, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(data).encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, name)


def read_info(kid):
    try:
        with open(kid + ".json", "rb") as f:
            d = json.loads(f.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def unlink(name):
    try:
        os.unlink(name)
    except OSError:
        pass


def remove_keeper(kid):
    for ext in (".json", ".sock", ".log"):
        unlink(kid + ext)


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def is_keeper_pid(pid):
    """True when pid runs this script: never signal a recycled pid."""
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read()
    except OSError:
        cmd = None
    if cmd is None:
        try:
            cmd = subprocess.check_output(["ps", "-o", "command=", "-p", str(pid)], stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            return False
    return b"keeper-" in cmd and b".py" in cmd


def sock_alive(kid):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(kid + ".sock")
        return True
    except OSError:
        return False
    finally:
        s.close()


def mark_stale(info):
    """A keeper whose process or socket is gone: record it as exited."""
    kid = info["id"]
    info["state"] = "exited"
    info["pending"] = 0
    info["turn_active"] = False
    info.setdefault("exit_reason", "The keeper process is gone (killed, or the host restarted).")
    info["exited_at"] = now_ms()
    try:
        write_json(kid + ".json", info)
    except OSError:
        pass
    unlink(kid + ".sock")


def scan():
    """All keepers on disk, stale ones marked exited, expired ones removed."""
    out = []
    now = now_ms()
    names = os.listdir(".")
    for name in names:
        if not name.endswith(".json"):
            continue
        kid = name[:-5]
        if not ID_RE.match(kid):
            continue
        info = read_info(kid)
        if info is None or info.get("id") != kid:
            continue
        if info.get("state") != "exited":
            if not (pid_alive(info.get("pid")) and sock_alive(kid)):
                mark_stale(info)
        if info.get("state") == "exited":
            at = info.get("exited_at") or info.get("started_at") or 0
            if now - at > KEEP_EXITED * 1000:
                remove_keeper(kid)
                continue
        out.append(info)
    known = set(i["id"] for i in out)
    horizon = time.time() - ORPHAN_AFTER
    for name in names:
        stem, dot, ext = name.rpartition(".")
        if dot and ext in ("sock", "log") and stem not in known:
            try:
                if os.path.getmtime(name) < horizon and not os.path.exists(stem + ".json"):
                    unlink(name)
            except OSError:
                pass
        elif ".json.tmp" in name:
            try:
                if os.path.getmtime(name) < horizon:
                    unlink(name)
            except OSError:
                pass
    out.sort(key=lambda i: i.get("started_at") or 0, reverse=True)
    return out


# -- redaction -------------------------------------------------------------

# The text is cut to 300 characters before any of these runs, and the prefixes
# are bounded, so a hostile 100 KB line costs microseconds, not seconds. The
# tails of a secret are not bounded: a cut would leave part of it showing.
_SECRET_KV = re.compile(
    r"(?i)\b([A-Za-z0-9_.-]{0,40}(?:token|secret|passw(?:or)?d|api[_-]?key|auth|credential|private[_-]?key)[A-Za-z0-9_.-]{0,40})"
    r"(\s{0,3}[=:]\s{0,3}|\s{1,3})(\"[^\"]*\"|'[^']*'|\S+)"
)
_BEARER = re.compile(r"(?i)\b(bearer|basic)\s{1,3}[A-Za-z0-9._~+/=-]{6,}")
_USERINFO = re.compile(r"(?i)(\b[a-z][a-z0-9+.-]{0,20}://)[^/\s:@]{1,100}:[^/\s@]+@")
_LONG = re.compile(r"\b(?=[A-Za-z0-9_-]{0,300}\d)(?=[A-Za-z0-9_-]{0,300}[A-Za-z])[A-Za-z0-9_-]{28,}\b")
_KNOWN = re.compile(r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})")


def redact_line(text):
    """First non-empty line, secrets masked, short: safe to hand to a hook."""
    line = ""
    if isinstance(text, str):
        for part in text[:2000].splitlines():
            if part.strip():
                line = part.strip()[:300]
                break
    line = _USERINFO.sub(r"\1***@", line)
    line = _BEARER.sub(lambda m: m.group(1) + " ***", line)
    line = _SECRET_KV.sub(lambda m: m.group(1) + m.group(2) + "***", line)
    line = _KNOWN.sub("***", line)
    line = _LONG.sub("***", line)
    return trunc(re.sub(r"\s+", " ", line), 120)


# -- the replay log --------------------------------------------------------

# What the log keeps of a session for `session/load`, grouped in turns. A turn
# is a user message and everything up to the next one (a `user_message_chunk`
# after agent activity opens the next turn; updates that only restate session
# state are not activity). When the log passes its bounds it gives up detail
# before it gives up turns: the heavy parts of the oldest tool calls are cut
# away first (the row stays: title, kind, status, locations), and only then
# are whole turns dropped, oldest first. The newest turn is never cut or
# dropped, nor is a turn a waiting request is about.

AMBIENT = (
    "available_commands_update", "current_mode_update", "config_option_update",
    "session_info_update", "usage_update",
)
TOOLS = ("tool_call", "tool_call_update")
FINISHED = ("completed", "failed", "cancelled")
OUTPUT_META = ("terminal_output_delta", "terminal_output", "terminal_input", "mcp_output_delta")
INPUT_KEYS = ("command", "file_path", "filePath", "path", "file", "pattern", "url", "query")
TOOL_KEYS = (
    "sessionUpdate", "toolCallId", "title", "kind", "status", "locations", "name",
    "content", "rawInput", "rawOutput", "_meta",
)


def update_of(msg):
    p = msg.get("params")
    u = p.get("update") if isinstance(p, dict) else None
    return u if isinstance(u, dict) else None


def kind_of(entry):
    u = update_of(entry["o"])
    return u.get("sessionUpdate") if u else None


def parent_tag(u):
    m = u.get("_meta")
    cc = m.get("claudeCode") if isinstance(m, dict) else None
    p = cc.get("parentToolUseId") if isinstance(cc, dict) else None
    return p if isinstance(p, str) and p else None


def trim_input(v):
    """What names a call in a row (its command or path) out of a tool's input."""
    if isinstance(v, str):
        return v[:300]
    if isinstance(v, dict):
        out = {}
        for k in INPUT_KEYS:
            if isinstance(v.get(k), str):
                out[k] = v[k][:300]
        return out or None
    return None


def trim_content(items):
    if not isinstance(items, list):
        return []
    return [
        it for it in items
        if isinstance(it, dict) and (it.get("type") == "terminal" or len(dumps(it)) <= 400)
    ]


def trim_meta(m):
    out = {}
    for k, v in m.items():
        if k in OUTPUT_META:
            continue
        if len(dumps(v)) > 2000:
            if k == "claudeCode" and isinstance(v, dict):
                # Claude's copy of the whole result lives here; the subagent tag must stay.
                v = dict((a, b) for a, b in v.items() if a in ("toolName", "parentToolUseId"))
            else:
                continue
        out[k] = v
    return out


def trim_tool(u):
    """(update without its heavy parts, whether anything was left out)."""
    small = {}
    for k, v in u.items():
        if k == "rawOutput":
            continue
        if k == "rawInput":
            if v is not None:
                v = trim_input(v)
                if v is None:
                    continue
            small[k] = v
        elif k == "content":
            small[k] = trim_content(v) if v is not None else None
        elif k == "_meta":
            small[k] = trim_meta(v) if isinstance(v, dict) else v
        elif k == "title" and isinstance(v, str):
            small[k] = v[:500]
        elif k == "locations" and isinstance(v, list):
            small[k] = v[:20]
        elif k in TOOL_KEYS or len(dumps(v)) <= 2000:
            small[k] = v
    return small, len(dumps(small)) < len(dumps(u))


def fold_tool(into, small):
    """Lays a later update of a call over the merged one, as a reader would."""
    for k, v in small.items():
        if k == "sessionUpdate":
            if v == "tool_call":
                into[k] = v
        elif k == "_meta" and isinstance(v, dict) and isinstance(into.get("_meta"), dict):
            into["_meta"] = dict(into["_meta"], **dict((str(a), b) for a, b in v.items()))
        else:
            into[k] = v


class Turn(object):
    __slots__ = ("seq", "e", "n", "user", "act", "slim", "cut", "tools")

    def __init__(self, seq):
        self.seq = seq
        self.e = collections.deque()
        self.n = 0
        self.user = False
        self.act = False
        self.slim = False  # its heavy parts were looked at
        self.cut = False  # and something was left out
        self.tools = set()


class ReplayLog(object):
    def __init__(self, max_bytes, max_entries, full_turns, soft_bytes=None):
        self.max_bytes = max_bytes  # hard: past it (or max_entries) turns are dropped
        self.max_entries = max_entries
        self.full_turns = full_turns
        self.soft_bytes = min(soft_bytes, max_bytes) if soft_bytes else max_bytes
        self.turns = collections.OrderedDict()
        self.last = None
        self.carry = {}  # the last state update of each kind a dropped turn held
        self.bytes = 0
        self.count = 0
        self.next_seq = 0
        self.scan = 0  # the oldest turn the trim pass has not looked at
        self.late = []  # turns it skipped because a request waits on them
        self.dropped = 0  # turns dropped, ever
        self.trimmed = 0  # turns held that had detail cut

    def entries(self):
        for e in list(self.carry.values()):
            yield e
        for t in list(self.turns.values()):
            for e in list(t.e):
                yield e

    def replay(self, since=None):
        """(entry, turn seq) in replay order: what restates state first, then
        the turns from `since` on (all of them when it is None)."""
        for e in list(self.carry.values()):
            yield e, None
        for t in list(self.turns.values()):
            if since is not None and t.seq < since:
                continue
            for e in list(t.e):
                yield e, t.seq

    def over(self):
        return self.bytes > self.max_bytes or self.count > self.max_entries

    @staticmethod
    def mergeable(a, b):
        pa, pb = a.get("params"), b.get("params")
        if not (isinstance(pa, dict) and isinstance(pb, dict)) or pa.get("sessionId") != pb.get("sessionId"):
            return False
        ua, ub = pa.get("update"), pb.get("update")
        if not (isinstance(ua, dict) and isinstance(ub, dict)):
            return False
        kind = ua.get("sessionUpdate")
        if kind not in CHUNKS or kind != ub.get("sessionUpdate") or ua.get("messageId") != ub.get("messageId"):
            return False
        for u in (ua, ub):
            if not set(u.keys()) <= set(["sessionUpdate", "content", "messageId"]):
                return False
            c = u.get("content")
            if not (isinstance(c, dict) and c.get("type") == "text" and isinstance(c.get("text"), str) and set(c.keys()) <= set(["type", "text"])):
                return False
        return True

    def add(self, msg, size, waiting):
        """Appends one update (`waiting()`: ids of the tool calls a pending
        request is about). O(1) amortized: trimming and dropping touch each
        entry once. Returns the entry that now holds `msg` (the one it merged
        into, or a new one), for `remove`."""
        u = update_of(msg)
        kind = u.get("sessionUpdate") if u else None
        t = self.last
        if t is None or (kind == "user_message_chunk" and t.act):
            t = Turn(self.next_seq)
            self.next_seq += 1
            self.turns[t.seq] = t
            self.last = t
        if kind == "user_message_chunk":
            t.user = True
        elif kind not in AMBIENT:
            t.act = True
        if kind in TOOLS and isinstance(u.get("toolCallId"), str):
            t.tools.add(u["toolCallId"])
        prev = t.e[-1] if t.e else None
        if prev is not None and size + prev["n"] <= min(262144, self.max_bytes // 4) and self.mergeable(prev["o"], msg):
            prev["o"]["params"]["update"]["content"]["text"] += msg["params"]["update"]["content"]["text"]
            prev["n"] += size
            entry = prev
        else:
            entry = {"o": msg, "n": size}
            t.e.append(entry)
            self.count += 1
        t.n += size
        self.bytes += size
        if self.bytes > self.soft_bytes or self.over():
            self.enforce(waiting)
        return entry

    def remove(self, entry):
        """Takes `entry` (as `add` returned it) back out: the user message of a
        prompt the agent refused. The counters follow it. A turn left with no
        entry goes; one left with no user message (only what the agent streamed
        meanwhile) joins the turn before it, since it belongs to that one's
        activity. False when the entry is not in the log (dropped meanwhile)."""
        for t in reversed(self.turns.values()):
            for i, e in enumerate(t.e):
                if e is entry:
                    del t.e[i]
                    t.n -= e["n"]
                    self.bytes -= e["n"]
                    self.count -= 1
                    self.mend(t)
                    return True
        return False

    def mend(self, t):
        """Settles turn `t` after an entry left it."""
        kinds = [kind_of(x) for x in t.e]
        t.user = "user_message_chunk" in kinds
        t.act = any(k != "user_message_chunk" and k not in AMBIENT for k in kinds)
        if t.e and t.user:
            return
        before = None
        for s in self.turns.values():
            if s is t:
                break
            before = s
        if t.e and before is not None:
            before.e.extend(t.e)
            before.n += t.n
            before.act = before.act or t.act
            before.tools |= t.tools
            before.slim = before.slim and t.slim
            if t.cut:
                if before.cut:
                    self.trimmed -= 1
                before.cut = True
        elif t.e:
            return  # the first turn: it stays, as one that opens with no user message
        elif t.cut:
            self.trimmed -= 1
        del self.turns[t.seq]
        if self.last is t:
            self.last = before

    def enforce(self, waiting):
        pinned = waiting()
        # The soft budget is what a replay costs the phone: old detail goes
        # as soon as it is passed, and nothing else (no turn is dropped for it).
        while self.bytes > self.soft_bytes:
            if not self.trim_next(pinned):
                break
        while self.over():
            if not (self.trim_next(pinned) or self.drop_next(pinned) or self.cut_oldest()):
                break

    def trim_next(self, pinned):
        """Cuts the heavy parts out of the oldest turn not yet cut: outside
        the newest `full_turns` first. False when there is none to cut."""
        self.late = [s for s in self.late if s in self.turns]
        for s in self.late:
            t = self.turns[s]
            if not (t.tools & pinned):
                self.late.remove(s)
                self.slim_turn(t)
                return True
        limit = self.next_seq - self.full_turns
        while self.scan < limit:
            t = self.turns.get(self.scan)
            self.scan += 1
            if t is None or t.slim:
                continue
            if t is self.last or (t.tools & pinned):
                self.late.append(t.seq)
                continue
            self.slim_turn(t)
            return True
        # Then the newest turns, oldest first, but never the newest: they keep
        # their detail for as long as the budget allows, and a cut turn is
        # still a turn of the conversation, which dropping it is not.
        recent = []
        for t in reversed(self.turns.values()):
            recent.append(t)
            if len(recent) >= self.full_turns:
                break
        for t in reversed(recent):
            if t is not self.last and not t.slim and not (t.tools & pinned):
                self.slim_turn(t)
                return True
        return False

    def slim_turn(self, t):
        t.slim = True
        finished = set()
        for e in t.e:
            u = update_of(e["o"])
            if u and u.get("sessionUpdate") in TOOLS and u.get("status") in FINISHED and isinstance(u.get("toolCallId"), str):
                finished.add(u["toolCallId"])
        out = collections.deque()
        merged = {}  # a finished call becomes one entry: [entry, update, cut, tag]
        touched = []
        for e in t.e:
            u = update_of(e["o"])
            if u is None or u.get("sessionUpdate") not in TOOLS:
                out.append(e)
                continue
            small, hit = trim_tool(u)
            tid = u.get("toolCallId")
            m = merged.get(tid) if isinstance(tid, str) and tid in finished else None
            if m is not None:
                fold_tool(m[1], small)
                m[2] = m[2] or hit
                m[3] = m[3] or parent_tag(u)
                continue
            msg = {
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": e["o"]["params"].get("sessionId"), "update": small},
            }
            ne = {"o": msg, "n": 0}
            rec = [ne, small, hit, parent_tag(u)]
            if isinstance(tid, str) and tid in finished:
                merged[tid] = rec
            touched.append(rec)
            out.append(ne)
        any_cut = False
        for ne, small, hit, tag in touched:
            if tag and parent_tag(small) != tag:
                meta = dict(small["_meta"]) if isinstance(small.get("_meta"), dict) else {}
                cc = dict(meta["claudeCode"]) if isinstance(meta.get("claudeCode"), dict) else {}
                cc["parentToolUseId"] = tag
                meta["claudeCode"] = cc
                small["_meta"] = meta
            if hit:
                any_cut = True
                meta = dict(small["_meta"]) if isinstance(small.get("_meta"), dict) else {}
                meta["herdr"] = {"trimmed": True}
                small["_meta"] = meta
            ne["n"] = len(dumps(ne["o"]))
        n = sum(e["n"] for e in out)
        self.bytes += n - t.n
        self.count += len(out) - len(t.e)
        t.e, t.n = out, n
        if any_cut and not t.cut:
            t.cut = True
            self.trimmed += 1

    def keep_state(self, e):
        """An entry that leaves the log but restates session state (the mode,
        the command list) is remembered: the last of each kind still replays."""
        k = kind_of(e)
        if k in AMBIENT and e["n"] <= 65536:
            self.carry[k] = e

    def drop_next(self, pinned):
        """Drops the oldest turn that is not the newest and that no waiting
        request is about, whole. False when there is none."""
        for t in self.turns.values():
            if t is self.last:
                return False
            if t.tools & pinned:
                continue
            for e in t.e:
                self.keep_state(e)
            del self.turns[t.seq]
            self.bytes -= t.n
            self.count -= len(t.e)
            if t.user or t.act:
                self.dropped += 1
            if t.cut:
                self.trimmed -= 1
            return True
        return False

    def cut_oldest(self):
        """Last resort, when what is left (the newest turn, a waiting one) is
        over the bounds by itself: the oldest entry that is not a user
        message, never the newest entry. False when there is none."""
        for t in self.turns.values():
            keep = []
            while t.e and kind_of(t.e[0]) == "user_message_chunk":
                keep.append(t.e.popleft())
            ok = len(t.e) > 1 or (len(t.e) == 1 and t is not self.last)
            if ok:
                e = t.e.popleft()
                self.keep_state(e)
                self.bytes -= e["n"]
                self.count -= 1
                t.n -= e["n"]
                if not t.cut:
                    t.cut = True
                    self.trimmed += 1
            t.e.extendleft(reversed(keep))
            if ok:
                return True
        return False


# -- the keeper daemon -----------------------------------------------------


class Chan(object):
    """A file descriptor the selector watches, with a write buffer."""

    def __init__(self, kind, fd, sock=None, reads=True):
        self.kind = kind
        self.fd = fd
        self.sock = sock
        self.reads = reads
        self.ev = 0
        self.rbuf = bytearray()
        self.wbuf = bytearray()
        self.discard = False
        self.closed = False
        self.closing = 0.0
        self.born = time.time()
        self.active = False
        self.live = False


class Keeper(object):
    def __init__(self, agent, cwd, argv, dirs, report_fd):
        self.agent = agent
        self.cwd = cwd
        self.argv = argv
        self.dirs = dirs
        self.report_fd = report_fd
        self.reported = False
        self.id = None
        self.started = now_ms()
        self.sel = selectors.DefaultSelector()
        self.listener = None
        self.proc = None
        self.ain = None
        self.aout = None
        self.aerr = None
        self.logfd = None
        self.logsize = 0
        self.err_tail = collections.deque(maxlen=20)
        self.conns = set()
        self.client = None
        self.next_out = 1
        self.next_kid = 1
        self.routes = {}
        self.pending = collections.OrderedDict()
        self.fwd = {}
        self.log = ReplayLog(LOG_BYTES, LOG_COUNT, LOG_FULL_TURNS, LOG_SOFT_BYTES)
        # Names this log: its turn numbers mean nothing to a client that holds
        # another (a keeper that started over counts from 0 again).
        self.epoch = secrets.token_hex(6)
        self.session_id = None
        self.setup = None
        self.title = None
        self.last_event_at = None
        self.stash = None
        self.sent = {}
        self.unseen_end = None
        self.bg_level = None
        self.init_result = None
        self.init_deadline = time.time() + INIT_TIMEOUT
        self.state = "starting"
        self.exit_code = None
        self.exit_reason = None
        self.exited_at = None
        self.dirty = False
        self.last_save = 0.0
        self.hooks = []
        self.got_signal = False
        self.terminating = False
        self.term_deadline = 0.0
        self.out_eof_at = None
        self.done = False

    # -- setup

    def claim(self):
        for _ in range(50):
            kid = "".join(secrets.choice(ID_ALPHABET) for _ in range(6))
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.bind(kid + ".sock")
            except OSError as e:
                s.close()
                if e.errno == errno.EADDRINUSE:
                    continue
                raise
            os.chmod(kid + ".sock", 0o600)
            s.listen(16)
            s.setblocking(False)
            self.id = kid
            self.listener = Chan("listen", s.fileno(), sock=s)
            # A record from the first moment: `list` sees the keeper and `kill`
            # can reach it while the agent is still starting (npx can take a
            # minute), and no sweep takes its files for orphans.
            self.save()
            return
        raise RuntimeError("could not find a free keeper id")

    def spawn(self):
        env = dict(os.environ)
        env["PATH"] = ":".join(self.dirs)
        self.proc = subprocess.Popen(
            self.argv,
            cwd=self.cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=0,
            close_fds=True,
            start_new_session=True,
            preexec_fn=_default_signals,
        )
        self.ain = Chan("ain", self.proc.stdin.fileno(), reads=False)
        self.aout = Chan("aout", self.proc.stdout.fileno())
        self.aerr = Chan("aerr", self.proc.stderr.fileno())
        for ch in (self.ain, self.aout, self.aerr):
            os.set_blocking(ch.fd, False)
        self.update_reg(self.aout)
        self.update_reg(self.aerr)
        self.save()

    def info(self):
        d = {
            "id": self.id,
            "agent": self.agent,
            "cwd": self.cwd,
            "state": self.state,
            "started_at": self.started,
            "pid": os.getpid(),
            "pending": len(self.pending),
            "turn_active": self.state != "exited" and self.busy(),
            "unseen_done": self.unseen_end is not None,
        }
        if self.proc is not None:
            d["agent_pid"] = self.proc.pid
        if self.session_id:
            d["session_id"] = self.session_id
        if self.title:
            d["title"] = self.title
        if self.last_event_at:
            d["last_event_at"] = self.last_event_at
        if self.exit_code is not None:
            d["exit_code"] = self.exit_code
        if self.exit_reason:
            d["exit_reason"] = self.exit_reason
        if self.exited_at:
            d["exited_at"] = self.exited_at
        return d

    def save(self):
        try:
            write_json(self.id + ".json", self.info())
        except OSError as e:
            self.dlog("could not write the record: %s" % e)
        self.dirty = False
        self.last_save = time.time()

    def report(self, obj):
        if self.reported:
            return
        self.reported = True
        try:
            os.write(self.report_fd, enc(obj))
        except OSError:
            pass
        try:
            os.close(self.report_fd)
        except OSError:
            pass

    # -- diagnostics

    def dlog(self, text):
        if self.logfd is None:
            return
        line = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), str(text).replace("\n", " ")[:2000])
        data = line.encode("utf-8", "replace")
        try:
            os.write(self.logfd, data)
        except OSError:
            return
        self.logsize += len(data)
        if self.logsize > DIAG_MAX:
            try:
                keep = os.pread(self.logfd, DIAG_KEEP, max(0, self.logsize - DIAG_KEEP))
                cut = keep.find(b"\n")
                keep = keep[cut + 1:] if cut >= 0 else keep
                os.ftruncate(self.logfd, 0)
                os.write(self.logfd, keep)
                self.logsize = len(keep)
            except OSError:
                self.logsize = 0

    # -- channel plumbing

    def update_reg(self, ch):
        if ch.closed:
            return
        ev = 0
        if ch.reads:
            ev |= selectors.EVENT_READ
        if ch.wbuf:
            ev |= selectors.EVENT_WRITE
        if ev == ch.ev:
            return
        if ch.ev == 0:
            self.sel.register(ch.fd, ev, ch)
        elif ev == 0:
            self.sel.unregister(ch.fd)
        else:
            self.sel.modify(ch.fd, ev, ch)
        ch.ev = ev

    def put(self, ch, data):
        if ch is None or ch.closed or ch.closing:
            return
        if not ch.wbuf:
            try:
                n = os.write(ch.fd, data)
                data = data[n:]
            except (BlockingIOError, InterruptedError):
                pass
            except OSError:
                self.drop(ch, "write failed")
                return
        if data:
            ch.wbuf += data
            if ch.kind == "conn" and len(ch.wbuf) > MAX_CLIENT_OUT:
                self.drop(ch, "client too slow")
                return
        self.update_reg(ch)

    def flush(self, ch):
        if not ch.wbuf:
            self.update_reg(ch)
            return
        try:
            n = os.write(ch.fd, bytes(ch.wbuf[:262144]))
            del ch.wbuf[:n]
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            self.drop(ch, "write failed")
            return
        if not ch.wbuf and ch.closing:
            self.drop(ch, "closed")
            return
        self.update_reg(ch)

    def drop(self, ch, why):
        if ch.closed:
            return
        if ch.kind == "conn":
            self.close_conn(ch, why)
            return
        ch.closed = True
        if ch.ev:
            try:
                self.sel.unregister(ch.fd)
            except (KeyError, ValueError, OSError):
                pass
            ch.ev = 0

    def pump(self, ch, limit):
        """New complete lines on ch and whether it reached EOF."""
        try:
            data = os.read(ch.fd, 262144)
        except (BlockingIOError, InterruptedError):
            return [], False
        except OSError:
            return [], True
        if not data:
            return [], True
        if ch.discard:
            i = data.find(b"\n")
            if i < 0:
                return [], False
            data = data[i + 1:]
            ch.discard = False
        ch.rbuf += data
        if b"\n" in data:
            parts = bytes(ch.rbuf).split(b"\n")
            ch.rbuf = bytearray(parts.pop())
            lines = parts
        else:
            lines = []
        if len(ch.rbuf) > limit:
            ch.rbuf = bytearray()
            ch.discard = True
            self.dlog("dropped a %s line over %d bytes" % (ch.kind, limit))
            if ch.kind == "conn":
                self.close_conn(ch, "line too long")
        return lines, False

    # -- clients

    def accept(self):
        for _ in range(8):
            try:
                s, _addr = self.listener.sock.accept()
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                return
            if len(self.conns) >= 16:
                s.close()
                continue
            s.setblocking(False)
            ch = Chan("conn", s.fileno(), sock=s)
            self.conns.add(ch)
            self.update_reg(ch)

    def close_conn(self, ch, why):
        if ch.closed:
            return
        ch.closed = True
        if ch.ev:
            try:
                self.sel.unregister(ch.fd)
            except (KeyError, ValueError, OSError):
                pass
            ch.ev = 0
        try:
            ch.sock.close()
        except OSError:
            pass
        self.conns.discard(ch)
        if self.client is ch:
            self.client = None
        for info in self.pending.values():
            if info.get("conn") is ch:
                info["conn"] = None
        for kid in [k for k, v in self.fwd.items() if v["conn"] is ch]:
            v = self.fwd.pop(kid)
            self.send_agent({
                "jsonrpc": "2.0", "id": v["aid"],
                "error": {"code": -32000, "message": "The client went away before it answered."},
            })

    def evict(self, old, reason):
        self.put(old, enc({"jsonrpc": "2.0", "method": "_herdr/evicted", "params": {"reason": reason}}))
        if old.closed:
            return
        old.reads = False
        old.closing = time.time()
        if old.ev & selectors.EVENT_READ:
            self.update_reg(old)
        if not old.wbuf:
            self.close_conn(old, "evicted")
        if self.client is old:
            self.client = None

    def adopt(self, conn):
        if self.client is conn:
            return
        if self.client is not None:
            self.evict(self.client, "Another device attached to this session.")
        self.client = conn
        conn.active = True
        conn.live = False

    def on_client_line(self, conn, line):
        line = line.strip()
        if not line:
            return
        try:
            msg = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            self.dlog("client sent a line that is not JSON: %s" % trunc(line.decode("utf-8", "replace"), 200))
            return
        if not isinstance(msg, dict) or not ("method" in msg or "id" in msg):
            self.dlog("client sent a JSON line that is not a JSON-RPC message")
            return
        if self.client is not conn:
            self.adopt(conn)
        method = msg.get("method")
        has_id = "id" in msg
        if isinstance(method, str):
            if has_id:
                self.on_client_request(conn, msg)
            else:
                self.on_client_notification(conn, msg)
        elif has_id:
            self.on_client_answer(conn, msg)

    def on_client_request(self, conn, msg):
        method = msg["method"]
        params = msg.get("params")
        if method == "initialize" and self.init_result is not None:
            self.put(conn, enc({"jsonrpc": "2.0", "id": msg["id"], "result": self.init_result}))
            return
        if (
            method in ("session/load", "session/resume")
            and self.session_id is not None
            and isinstance(params, dict)
            and params.get("sessionId") == self.session_id
        ):
            self.serve_held(conn, msg)
            return
        oid = self.next_out
        self.next_out += 1
        route = {"conn": conn, "id": msg["id"], "method": method, "params": params, "oid": oid}
        self.routes[oid] = route
        if method.startswith("session/") and method != "session/list":
            conn.live = True
        if method == "session/prompt":
            route["prompt"] = True
            self.begin_turn(params, oid)
        out = dict(msg)
        out["jsonrpc"] = "2.0"
        out["id"] = oid
        self.send_agent(out)
        if route.get("prompt"):
            self.save()

    def on_client_notification(self, conn, msg):
        if msg["method"] == "$/cancel_request":
            p = msg.get("params")
            target = p.get("requestId") if isinstance(p, dict) else None
            for oid, r in self.routes.items():
                if r["conn"] is conn and r["id"] == target and type(r["id"]) is type(target):
                    self.send_agent({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": oid}})
                    break
            return
        out = dict(msg)
        out["jsonrpc"] = "2.0"
        self.send_agent(out)

    def on_client_answer(self, conn, msg):
        rid = msg.get("id")
        info = None
        if isinstance(rid, str):
            info = self.pending.pop(rid, None)
            if info is not None:
                self.save()
            else:
                info = self.fwd.pop(rid, None)
        if info is None:
            self.dlog("ignored an answer to %r: nothing waits for it (already answered?)" % (rid,))
            return
        out = {"jsonrpc": "2.0", "id": info["aid"]}
        if "error" in msg:
            out["error"] = msg["error"]
        else:
            out["result"] = msg.get("result")
        self.send_agent(out)

    def replay_since(self, msg):
        """The turn a `session/load` asks the replay to start from
        (`_meta.herdr.since`), when this log is the one it was counted in and
        still has that turn; None otherwise (the whole log is replayed)."""
        p = msg.get("params")
        m = p.get("_meta") if isinstance(p, dict) else None
        h = m.get("herdr") if isinstance(m, dict) else None
        s = h.get("since") if isinstance(h, dict) else None
        if not isinstance(s, dict) or s.get("epoch") != self.epoch:
            return None
        turn = s.get("turn")
        if type(turn) is not int or turn not in self.log.turns:
            return None
        return turn

    def serve_held(self, conn, msg):
        # A prompt just sent has no update yet: the replay must still show it
        # (a refusal takes it back out of the log, see end_turn).
        self.flush_stash()
        replay = msg["method"] == "session/load"
        sid = self.session_id
        if replay:
            since = self.replay_since(msg)
            if since is not None:
                # The phone holds every turn before this one: only this turn
                # and the ones after it follow, and it must start from what it
                # holds (this notice comes before the first update).
                self.put(conn, enc({"jsonrpc": "2.0", "method": "_herdr/replay", "params": {"sessionId": sid, "from": since}}))
            turn = None
            for e, seq in self.log.replay(since):
                p = e["o"].get("params")
                if not (isinstance(p, dict) and p.get("sessionId") == sid):
                    continue
                o = e["o"]
                if seq is not None and seq != turn:
                    # The first line of each turn names it (and this log), so the
                    # phone's saved copy can be cut where a turn begins and
                    # `since` asked for from there.
                    turn = seq
                    p = dict(p)
                    m = dict(p["_meta"]) if isinstance(p.get("_meta"), dict) else {}
                    m["herdr"] = {"epoch": self.epoch, "turn": seq}
                    p["_meta"] = m
                    o = dict(o)
                    o["params"] = p
                self.put(conn, enc(o))
        result = dict(self.setup) if isinstance(self.setup, dict) else {}
        if replay:
            # What the log gave up, for an app that knows to say so (others ignore `_meta.herdr`).
            meta = dict(result["_meta"]) if isinstance(result.get("_meta"), dict) else {}
            meta["herdr"] = {"droppedTurns": self.log.dropped, "trimmedTurns": self.log.trimmed}
            result["_meta"] = meta
        if self.bg_level is not None:
            self.put(conn, self.bg_level + b"\n")
        self.put(conn, enc({"jsonrpc": "2.0", "id": msg["id"], "result": result}))
        conn.live = True
        if self.busy():
            self.put(conn, self.state_update(sid, "running", None))
        elif self.unseen_end is not None:
            self.put(conn, self.state_update(sid, "idle", self.unseen_end.get("stop")))
        if self.unseen_end is not None:
            self.unseen_end = None
            self.save()
        for info in list(self.pending.values()):
            self.issue(conn, info)

    def issue(self, conn, info):
        info["conn"] = conn
        self.put(conn, enc({"jsonrpc": "2.0", "id": info["kid"], "method": info["method"], "params": info["params"]}))

    @staticmethod
    def state_update(sid, state, stop):
        upd = {"sessionUpdate": "state_update", "state": state}
        if stop:
            upd["stopReason"] = stop
        return enc({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})

    def busy(self):
        return any(r.get("prompt") for r in self.routes.values())

    # -- the agent

    def send_agent(self, obj):
        if self.ain is not None and not self.ain.closed:
            self.put(self.ain, enc(obj))

    def on_agent_line(self, raw):
        raw = raw.strip()
        if not raw:
            return
        text = raw.decode("utf-8", "replace")
        try:
            msg = json.loads(text)
        except ValueError:
            self.dlog("agent wrote a line that is not JSON: %s" % trunc(text, 200))
            return
        if not isinstance(msg, dict):
            self.dlog("agent wrote JSON that is not an object: %s" % trunc(text, 200))
            return
        method = msg.get("method")
        has_id = "id" in msg
        if isinstance(method, str):
            if has_id:
                self.on_agent_request(msg)
            else:
                self.on_agent_notification(msg, raw)
        elif has_id:
            self.on_agent_response(msg)
        else:
            self.dlog("agent wrote a message with no method and no id: %s" % trunc(text, 200))

    def on_agent_notification(self, msg, raw):
        method = msg["method"]
        c = self.client
        if method == "session/update":
            self.note_update(msg, len(raw))
            if c is not None and c.live:
                self.put(c, raw + b"\n")
        elif method == "$/cancel_request":
            p = msg.get("params")
            target = p.get("requestId") if isinstance(p, dict) else None
            for kid, info in list(self.pending.items()):
                if info["aid"] == target and type(info["aid"]) is type(target):
                    del self.pending[kid]
                    self.save()
                    if info.get("conn") is not None and not info["conn"].closed:
                        self.put(info["conn"], enc({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": kid}}))
                    return
            for kid, v in list(self.fwd.items()):
                if v["aid"] == target and type(v["aid"]) is type(target):
                    del self.fwd[kid]
                    self.put(v["conn"], enc({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": kid}}))
                    return
        elif method == "_claude/sdkMessage":
            # Claude's live background tasks are a level, not a log entry: the
            # last one is kept so a client that attaches later still gets it.
            if b"background_tasks_changed" in raw:
                self.bg_level = raw
            if c is not None and c.live:
                self.put(c, raw + b"\n")
        elif c is not None and c.live:
            self.put(c, raw + b"\n")

    def on_agent_request(self, msg):
        method = msg["method"]
        aid = msg["id"]
        c = self.client
        kid = "kp%d" % self.next_kid
        self.next_kid += 1
        if method in HELD:
            info = {"kid": kid, "aid": aid, "method": method, "params": msg.get("params"), "conn": None}
            self.pending[kid] = info
            self.save()
            self.hook("blocked", self.summarize(msg))
            if c is not None and c.live:
                self.issue(c, info)
            return
        if c is not None and c.live:
            self.fwd[kid] = {"aid": aid, "conn": c}
            out = dict(msg)
            out["id"] = kid
            self.put(c, enc(out))
            return
        self.send_agent({
            "jsonrpc": "2.0", "id": aid,
            "error": {"code": -32000, "message": "No client is attached to answer %s." % method},
        })

    def on_agent_response(self, msg):
        rid = msg["id"]
        if rid == INIT_ID:
            self.on_init_response(msg)
            return
        route = self.routes.pop(rid, None) if isinstance(rid, int) else None
        if route is None:
            self.dlog("agent answered an id nobody asked: %r" % (rid,))
            return
        method = route["method"]
        ok = "error" not in msg
        if ok and method in ("session/new", "session/load", "session/resume"):
            self.note_session(route, msg.get("result"))
        elif ok and method == "session/set_config_option":
            res = msg.get("result")
            if isinstance(res, dict) and isinstance(res.get("configOptions"), list) and isinstance(self.setup, dict):
                self.setup["configOptions"] = res["configOptions"]
        elif ok and method == "session/set_mode":
            p = route.get("params")
            modes = self.setup.get("modes") if isinstance(self.setup, dict) else None
            if isinstance(modes, dict) and isinstance(p, dict) and isinstance(p.get("modeId"), str):
                modes["currentModeId"] = p["modeId"]
        conn = route["conn"]
        if route.get("prompt"):
            self.end_turn(route, msg)
            self.save()
        if not conn.closed and conn is self.client:
            out = dict(msg)
            out["id"] = route["id"]
            self.put(conn, enc(out))

    def note_session(self, route, result):
        p = route.get("params")
        if route["method"] == "session/new":
            sid = result.get("sessionId") if isinstance(result, dict) else None
        else:
            sid = p.get("sessionId") if isinstance(p, dict) else None
        if not isinstance(sid, str) or not sid:
            return
        if self.session_id is None:
            self.session_id = sid
            self.setup = dict(result) if isinstance(result, dict) else {}
            self.save()
        elif sid == self.session_id and isinstance(result, dict) and result:
            self.setup = dict(result)

    # -- events and turns

    def note_update(self, msg, size):
        p = msg.get("params")
        upd = p.get("update") if isinstance(p, dict) else None
        if not isinstance(upd, dict):
            return
        kind = upd.get("sessionUpdate")
        self.last_event_at = now_ms()
        self.dirty = True
        if kind == "session_info_update" and "title" in upd:
            t = upd.get("title")
            self.title = t[:300] if isinstance(t, str) and t else None
            self.dirty = True
        if self.stash is not None:
            if kind == "user_message_chunk":
                self.stash = None
            else:
                self.flush_stash()
        self.log_add(msg, size)

    def begin_turn(self, params, oid):
        self.flush_stash()
        if not isinstance(params, dict) or not isinstance(params.get("prompt"), list):
            return
        blocks = []
        for b in params["prompt"]:
            if not isinstance(b, dict):
                continue
            if b.get("type") != "text" and len(json.dumps(b)) > 20000:
                b = {"type": "text", "text": "[%s omitted]" % b.get("type", "attachment")}
            blocks.append(b)
        sid = params.get("sessionId")
        if blocks and isinstance(sid, str):
            self.stash = {"sid": sid, "blocks": blocks, "mid": "keeper-" + secrets.token_hex(6), "oid": oid}

    def flush_stash(self):
        st = self.stash
        if st is None:
            return
        self.stash = None
        logged = self.sent.setdefault(st["oid"], [])
        for b in st["blocks"]:
            upd = {"sessionUpdate": "user_message_chunk", "content": b, "messageId": st["mid"]}
            m = {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": st["sid"], "update": upd}}
            e = self.log_add(m, len(json.dumps(m)))
            if e is not None and not any(x is e for x in logged):
                logged.append(e)

    def shrink(self, msg, size):
        """A session/update too big for the log, cut to what a replay needs: a
        message chunk keeps a head, a tool call keeps its title and status and
        says its output was left out. (stub, size), or None for an update with
        no use in a replay."""
        p = msg.get("params")
        upd = p.get("update") if isinstance(p, dict) else None
        if not isinstance(upd, dict):
            return None
        kind = upd.get("sessionUpdate")
        small = {"sessionUpdate": kind}
        if kind in CHUNKS:
            if "messageId" in upd:
                small["messageId"] = upd["messageId"]
            c = upd.get("content")
            head = ""
            if isinstance(c, dict) and c.get("type") == "text" and isinstance(c.get("text"), str):
                head = c["text"][: max(50, LOG_BYTES // 16)]
            note = "[%d bytes omitted]" % size
            small["content"] = {"type": "text", "text": head + "\n" + note if head else note}
        elif kind in ("tool_call", "tool_call_update"):
            for key in ("toolCallId", "status", "kind"):
                if key in upd:
                    small[key] = upd[key]
            if isinstance(upd.get("title"), str):
                small["title"] = upd["title"][:500]
            small["content"] = [{"type": "content", "content": {"type": "text", "text": "[output of %d bytes omitted]" % size}}]
        else:
            return None
        stub = {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": p.get("sessionId"), "update": small}}
        n = len(json.dumps(stub))
        return (stub, n) if n <= LOG_BYTES else None

    def log_add(self, msg, size):
        """Appends to the log (merging into the last entry when it can). Returns
        the entry that now holds `msg`, or None when it was dropped."""
        if size > LOG_BYTES:
            # One update must never push the whole log out.
            small = self.shrink(msg, size)
            self.dlog("a session/update of %d bytes is over the log bound%s" % (size, "" if small else ": dropped"))
            if small is None:
                return None
            msg, size = small
        return self.log.add(msg, size, self.waiting_tools)

    def retract(self, oid):
        """Takes back the user message logged (or still stashed) for the prompt
        `oid`."""
        st = self.stash
        if st is not None and st["oid"] == oid:
            self.stash = None
        for e in self.sent.pop(oid, ()):
            self.log.remove(e)

    def waiting_tools(self):
        """Ids of the tool calls a pending request is about: their turns stay."""
        ids = set()
        for info in self.pending.values():
            p = info.get("params")
            tc = p.get("toolCall") if isinstance(p, dict) else None
            tid = tc.get("toolCallId") if isinstance(tc, dict) else None
            if isinstance(tid, str):
                ids.add(tid)
        return ids

    def end_turn(self, route, msg):
        err = msg.get("error")
        if isinstance(err, dict) and err.get("code") == SESSION_BUSY:
            # The agent took nothing (it runs a turn of its own): the message
            # must not be in the log, or a replay shows it once per attempt.
            self.retract(route.get("oid"))
        else:
            self.flush_stash()
            self.sent.pop(route.get("oid"), None)
        res = msg.get("result")
        stop = res.get("stopReason") if isinstance(res, dict) else None
        if not isinstance(stop, str):
            stop = None
        conn = route["conn"]
        if not conn.closed and conn is self.client:
            self.unseen_end = None
            return
        params = route.get("params")
        sid = params.get("sessionId") if isinstance(params, dict) else None
        c = self.client
        if c is not None and c.live and isinstance(sid, str):
            self.put(c, self.state_update(sid, "idle", stop))
            self.unseen_end = None
        else:
            self.unseen_end = {"stop": stop}
        if c is None:
            self.hook("done", ("Turn finished (%s)" % stop) if stop else "Turn finished")

    # -- alerts

    def summarize(self, msg):
        """The text an alert is about (cut, not yet redacted)."""
        p = msg.get("params")
        p = p if isinstance(p, dict) else {}
        if msg["method"] == "session/request_permission":
            tc = p.get("toolCall")
            text = (tc.get("title") or tc.get("kind")) if isinstance(tc, dict) else None
            return text if isinstance(text, str) and text else "permission request"
        text = p.get("message")
        return text if isinstance(text, str) and text else "question"

    def hook(self, event, text):
        path = os.environ.get("HERDR_KEEPER_ON_BLOCKED") or os.path.join(home_dir(), ".herdr-mobile", "on-blocked")
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            return
        if len(self.hooks) >= 4:
            self.dlog("alert hook skipped: four are still running")
            return
        env = dict(os.environ)
        env.update({
            "KEEPER_ID": self.id,
            "KEEPER_AGENT": self.agent,
            "KEEPER_CWD": self.cwd,
            "KEEPER_TITLE": redact_line(self.title or ""),
            "KEEPER_EVENT": event,
            "KEEPER_SUMMARY": redact_line(text),
        })
        try:
            p = subprocess.Popen(
                [path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=env, close_fds=True, start_new_session=True, preexec_fn=_default_signals,
            )
        except Exception as e:
            self.dlog("alert hook failed to start: %s" % e)
            return
        self.hooks.append((p, time.time()))

    def reap_hooks(self):
        keep = []
        for p, t0 in self.hooks:
            if p.poll() is not None:
                continue
            if time.time() - t0 > 5:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                self.dlog("alert hook killed after 5 s")
            keep.append((p, t0))
        self.hooks = keep

    # -- start and end

    def on_init_response(self, msg):
        res = msg.get("result")
        if "error" in msg or not isinstance(res, dict):
            err = msg.get("error")
            text = err.get("message") if isinstance(err, dict) else "no result"
            self.fail_start("the agent refused initialize: %s" % text, EX_FAILED)
            return
        caps = res.get("agentCapabilities")
        if not isinstance(caps, dict):
            caps = {}
            res["agentCapabilities"] = caps
        caps["loadSession"] = True
        self.init_result = res
        self.state = "running"
        self.update_reg(self.listener)
        self.save()
        self.report({"ok": True, "info": self.info()})

    def fail_start(self, text, code):
        tail = "\n".join(self.err_tail)
        self.kill_group(signal.SIGKILL)
        # Clean up first: `start` exits when it hears the report, and nothing
        # may be left on disk by then.
        remove_keeper(self.id)
        self.report({"ok": False, "code": code, "error": text + ("\n" + tail if tail else "")})
        self.done = True

    def kill_group(self, sig):
        if self.proc is None:
            return
        try:
            os.killpg(self.proc.pid, sig)
        except OSError:
            pass

    def finish(self, code, reason):
        """The agent is gone: record why, tell the client, leave."""
        self.state = "exited"
        self.exit_code = code
        self.exit_reason = reason
        self.exited_at = now_ms()
        for info in self.pending.values():
            self.dlog("pending %s %s cancelled: the agent exited" % (info["method"], info["kid"]))
        self.pending.clear()
        self.fwd.clear()
        self.routes.clear()
        c = self.client
        if c is not None and not c.closed:
            data = bytes(c.wbuf) + enc({
                "jsonrpc": "2.0", "method": "_herdr/agent_exited",
                "params": {"exitCode": code, "reason": reason},
            })
            try:
                c.sock.setblocking(True)
                c.sock.settimeout(2)
                c.sock.sendall(data)
            except OSError:
                pass
        for ch in list(self.conns):
            self.close_conn(ch, "agent exited")
        self.save()
        unlink(self.id + ".sock")
        self.done = True

    def on_agent_exit(self, rc):
        for ch in (self.aout, self.aerr):
            for _ in range(64):
                lines, eof = self.pump(ch, MAX_AGENT_LINE)
                self.handle_agent_lines(ch, lines)
                if eof or not lines:
                    break
        self.kill_group(signal.SIGKILL)
        code = rc if rc >= 0 else 128 - rc
        if self.init_result is None:
            self.fail_start("the agent exited (code %d) before it answered initialize" % code, EX_FAILED)
            return
        if self.terminating:
            reason = "Ended on request."
        elif rc < 0:
            reason = "The agent was killed by signal %d." % -rc
        elif rc == 0:
            reason = "The agent exited."
        else:
            reason = "The agent exited with code %d." % rc
            if self.err_tail:
                reason += " " + trunc(self.err_tail[-1], 200)
        self.finish(code, reason)

    def handle_agent_lines(self, ch, lines):
        if ch.kind == "aout":
            for ln in lines:
                self.on_agent_line(ln)
        else:
            for ln in lines:
                text = ln.decode("utf-8", "replace").rstrip()
                if text:
                    self.err_tail.append(trunc(text, 300))
                    self.dlog("agent: " + text)

    def readable(self, ch):
        if ch.kind == "listen":
            self.accept()
        elif ch.kind == "conn":
            lines, eof = self.pump(ch, MAX_CLIENT_LINE)
            for ln in lines:
                if ch.closed:
                    break
                self.on_client_line(ch, ln)
            if eof and not ch.closed:
                self.close_conn(ch, "client left")
        else:
            lines, eof = self.pump(ch, MAX_AGENT_LINE)
            self.handle_agent_lines(ch, lines)
            if eof:
                self.drop(ch, "eof")
                if ch.kind == "aout":
                    self.out_eof_at = time.time()

    def tick(self):
        t = time.time()
        self.reap_hooks()
        for ch in list(self.conns):
            if ch.closing and t - ch.closing > 5:
                self.close_conn(ch, "did not drain")
            elif not ch.active and not ch.closing and t - ch.born > 30:
                self.close_conn(ch, "idle")
        if self.got_signal and not self.terminating:
            self.terminating = True
            self.term_deadline = t + 3
            self.kill_group(signal.SIGTERM)
        if self.terminating and t > self.term_deadline:
            self.kill_group(signal.SIGKILL)
        if self.init_result is None and not self.terminating and t > self.init_deadline:
            self.fail_start("the agent did not answer initialize within %d s" % INIT_TIMEOUT, EX_FAILED)
            return
        if self.dirty and t - self.last_save >= 1 and self.init_result is not None:
            self.save()
        rc = self.proc.poll()
        if rc is None and self.out_eof_at is not None and t - self.out_eof_at > 5:
            self.kill_group(signal.SIGKILL)
            self.out_eof_at = t
        if rc is not None:
            self.on_agent_exit(rc)

    def run(self):
        self.send_agent(init_request(INIT_ID, self.agent))
        while not self.done:
            for key, mask in self.sel.select(0.25):
                ch = key.data
                if ch.closed:
                    continue
                if mask & selectors.EVENT_WRITE:
                    self.flush(ch)
                if mask & selectors.EVENT_READ and not ch.closed:
                    self.readable(ch)
                if self.done:
                    break
            if not self.done:
                self.tick()


def init_request(rid, agent, air=True):
    """The `initialize` request of the keeper. [air] adds the JetBrains
    capability some routes need for their session features; `history` leaves
    it out."""
    caps = {
        "fs": {"readTextFile": False, "writeTextFile": False},
        "terminal": False,
        "elicitation": {"form": {}},
        "session": {"configOptions": {"boolean": {}}},
    }
    route = route_by_id(agent)
    air_caps = route.get("air") if route else None
    if air and air_caps:
        caps["_meta"] = {"jetbrains": {"air": {"version": 1, "capabilities": list(air_caps)}}}
    return {
        "jsonrpc": "2.0", "id": rid, "method": "initialize",
        "params": {
            "protocolVersion": 1,
            "clientCapabilities": caps,
            "clientInfo": {"name": "herdr-keeper", "title": "herdr keeper", "version": "1"},
        },
    }


def _default_signals():
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)


# -- subcommands -----------------------------------------------------------


def cmd_probe():
    dirs = search_dirs()
    print(dumps({"routes": [r["id"] for r in ROUTES if resolve(r, dirs)]}))


def cmd_list():
    os.chdir(state_dir())
    print(dumps(scan()))


def cmd_start(agent, cwd):
    route = route_by_id(agent)
    if route is None:
        fail(EX_USAGE, "unknown agent: " + agent)
    cwd = os.path.abspath(os.path.expanduser(cwd))
    if not os.path.isdir(cwd):
        fail(EX_GONE, "the folder does not exist on this host: " + cwd)
    if not os.access(cwd, os.R_OK | os.X_OK):
        fail(EX_GONE, "the folder cannot be opened on this host: " + cwd)
    dirs = search_dirs()
    argv = resolve(route, dirs)
    if argv is None:
        want = route["binary"] + (" or npx" if route.get("npx") else "")
        fail(EX_MISSING, "%s is not installed on this host (looked for %s)" % (route["id"], want))
    sd = state_dir()
    os.chdir(sd)
    r, w = os.pipe()
    pid = os.fork()
    if pid > 0:
        os.close(w)
        buf = b""
        deadline = time.time() + INIT_TIMEOUT + 20
        while b"\n" not in buf:
            left = deadline - time.time()
            if left <= 0:
                break
            ready, _, _ = select.select([r], [], [], left)
            if not ready:
                break
            chunk = os.read(r, 65536)
            if not chunk:
                break
            buf += chunk
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        try:
            rep = json.loads(buf.decode("utf-8", "replace").strip().splitlines()[0])
        except (ValueError, IndexError):
            fail(EX_FAILED, "the keeper did not start (no answer from the new process)")
        if rep.get("ok"):
            print(dumps(rep["info"]))
            sys.stdout.flush()
            sys.exit(0)
        fail(int(rep.get("code") or EX_FAILED), str(rep.get("error") or "the keeper did not start"))
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    os.close(r)
    daemon(agent, cwd, argv, dirs, w)


def daemon(agent, cwd, argv, dirs, report_fd):
    os.umask(0o077)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    k = Keeper(agent, cwd, argv, dirs, report_fd)
    signal.signal(signal.SIGTERM, lambda *_: setattr(k, "got_signal", True))
    signal.signal(signal.SIGINT, lambda *_: setattr(k, "got_signal", True))
    try:
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        if devnull > 2:
            os.close(devnull)
        k.claim()
        k.logfd = os.open(k.id + ".log", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        k.dlog("keeper %s: %s in %s" % (k.id, " ".join(argv), cwd))
        try:
            k.spawn()
        except OSError as e:
            remove_keeper(k.id)
            k.report({"ok": False, "code": EX_MISSING, "error": "could not run %s: %s" % (argv[0], e)})
            os._exit(0)
        k.run()
    except BaseException:
        text = traceback.format_exc()
        k.dlog("keeper crashed: " + text)
        k.kill_group(signal.SIGKILL)
        if not k.reported:
            if k.id:
                remove_keeper(k.id)
            k.report({"ok": False, "code": EX_FAILED, "error": "the keeper crashed: " + trunc(text.strip().splitlines()[-1], 300)})
        elif k.id and k.state != "exited":
            k.state = "exited"
            k.exit_reason = "The keeper crashed."
            k.exited_at = now_ms()
            k.save()
            unlink(k.id + ".sock")
    os._exit(0)


def check_id(kid):
    if not ID_RE.match(kid or ""):
        fail(EX_USAGE, "not a keeper id: " + str(kid))


# `attach --z`: what goes to the phone is cut into the complete lines the keeper
# wrote, and a batch of at least ATTACH_ZIP_MIN bytes travels as ONE line
# `Z<base64 of zlib data>`: all batches are one zlib stream, each ended with a
# sync flush so the phone can inflate it as it arrives. The replay of a long
# thread is plain JSON text and shrinks ~10x (base64 costs a third of that
# back); a small message (a streamed word) is cheaper as it is, and stays so.
ATTACH_ZIP_MIN = 512


def zip_batch(z, data):
    return b"Z" + base64.b64encode(z.compress(data) + z.flush(zlib.Z_SYNC_FLUSH)) + b"\n"


def cmd_attach(kid, zipped=False):
    check_id(kid)
    os.chdir(state_dir())
    info = read_info(kid)
    if info is None:
        fail(EX_GONE, "no such keeper: " + kid)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(kid + ".sock")
    except OSError:
        info = read_info(kid) or info
        if info.get("state") != "exited":
            mark_stale(info)
            info = read_info(kid) or info
        fail(EX_EXITED, "keeper %s: %s" % (kid, info.get("exit_reason") or "the agent has exited."))
    s.setblocking(True)
    z = zlib.compressobj(6) if zipped else None
    held = b""
    while True:
        ready, _, _ = select.select([0, s], [], [])
        if 0 in ready:
            data = os.read(0, 65536)
            if not data:
                break
            try:
                s.sendall(data)
            except OSError:
                break
        if s in ready:
            data = s.recv(65536)
            if z is not None:
                held += data
                cut = held.rfind(b"\n") + 1
                if data and not cut:
                    continue
                whole, held = held[:cut], held[cut:]
                if not data:
                    whole += held  # the keeper hung up in the middle of a line
                data_out = zip_batch(z, whole) if len(whole) >= ATTACH_ZIP_MIN else whole
            else:
                data_out = data
            if not data and not data_out:
                break
            try:
                view = memoryview(data_out)
                while view:
                    n = os.write(1, view)
                    view = view[n:]
            except OSError:
                break
            if not data:
                break
    s.close()


def cmd_kill(kid):
    check_id(kid)
    os.chdir(state_dir())
    info = read_info(kid)
    if info is None:
        fail(EX_GONE, "no such keeper: " + kid)
    pid = info.get("pid")
    if info.get("state") != "exited" and pid_alive(pid) and is_keeper_pid(pid):
        os.kill(pid, signal.SIGTERM)
        deadline = time.time() + 6
        while pid_alive(pid) and time.time() < deadline:
            time.sleep(0.05)
        if pid_alive(pid):
            apid = info.get("agent_pid")
            if isinstance(apid, int) and apid > 1:
                try:
                    os.killpg(apid, signal.SIGKILL)
                except OSError:
                    pass
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    remove_keeper(kid)
    print(dumps({"ok": True}))


# -- history -----------------------------------------------------------------


class HistoryFailed(Exception):
    """The agent could not say what it remembers; the text is for stderr."""


class AgentTalk(object):
    """One agent process for a short conversation: JSON-RPC lines both ways,
    nothing on disk, always torn down by [close]."""

    def __init__(self, argv, cwd, dirs):
        self.argv = argv
        self.cwd = cwd
        self.dirs = dirs
        self.proc = None
        self.fd = -1
        self.buf = b""
        self.seq = 0

    def spawn(self):
        env = dict(os.environ)
        env["PATH"] = ":".join(self.dirs)
        self.proc = subprocess.Popen(
            self.argv,
            cwd=self.cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            bufsize=0,
            close_fds=True,
            start_new_session=True,
            preexec_fn=_default_signals,
        )
        self.fd = self.proc.stdout.fileno()

    def send(self, obj):
        try:
            os.write(self.proc.stdin.fileno(), enc(obj))
        except OSError:
            raise HistoryFailed("the agent closed its input")

    def read_message(self, deadline, what):
        """The next JSON object the agent printed; anything else is skipped."""
        while True:
            i = self.buf.find(b"\n")
            if i >= 0:
                line, self.buf = self.buf[:i], self.buf[i + 1:]
                try:
                    msg = json.loads(line.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if isinstance(msg, dict):
                    return msg
                continue
            if len(self.buf) > MAX_AGENT_LINE:
                raise HistoryFailed("the agent sent a line that is too long")
            left = deadline - time.time()
            if left <= 0:
                raise HistoryFailed("the agent did not answer %s in time" % what)
            ready, _, _ = select.select([self.fd], [], [], min(left, 1.0))
            if not ready:
                continue
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise HistoryFailed("the agent exited before it answered %s" % what)
            self.buf += chunk

    def call(self, method, params, timeout):
        """The answer to one request. Notifications are dropped; a request of
        the agent's own gets 'method not found' so it never waits on us."""
        self.seq += 1
        rid = "keeper-history-%d" % self.seq
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while True:
            msg = self.read_message(deadline, method)
            if "method" in msg:
                if "id" in msg:
                    self.send({
                        "jsonrpc": "2.0", "id": msg["id"],
                        "error": {"code": -32601, "message": "not supported while listing sessions"},
                    })
                continue
            if msg.get("id") == rid:
                return msg

    def close(self):
        """Ends the agent's process group: SIGTERM, 2 s, SIGKILL, reaped."""
        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        p = self.proc
        if p is None:
            return
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except OSError:
            pass
        end = time.time() + 2
        while p.poll() is None and time.time() < end:
            time.sleep(0.02)
        if p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.wait()
        try:
            p.stdout.close()
        except Exception:
            pass


def _history_item(raw, cwd):
    """One session of a session/list answer cut to what the phone shows, or
    None when it has no id."""
    if not isinstance(raw, dict):
        return None
    sid = raw.get("sessionId")
    if not isinstance(sid, str) or not sid:
        return None
    where = raw.get("cwd")
    if not isinstance(where, str):
        where = cwd
    if where is None:
        return None
    item = {"sessionId": sid, "cwd": where}
    title = raw.get("title")
    if isinstance(title, str) and title.strip():
        item["title"] = trunc(title.strip(), HISTORY_TITLE)
    at = raw.get("updatedAt")
    if isinstance(at, str) and at:
        item["updatedAt"] = at
    meta = raw.get("_meta")
    count = meta.get("messageCount") if isinstance(meta, dict) else None
    if isinstance(count, int) and not isinstance(count, bool):
        item["_meta"] = {"messageCount": count}
    return item


def _history_ask(talk, agent, cwd):
    """The one line `history` prints, or HistoryFailed."""
    msg = talk.call("initialize", init_request("keeper-history-init", agent, False)["params"], INIT_TIMEOUT)
    res = msg.get("result")
    if "error" in msg or not isinstance(res, dict):
        err = msg.get("error")
        raise HistoryFailed("%s: %s" % (agent, err.get("message") if isinstance(err, dict) else "no result"))
    caps = res.get("agentCapabilities")
    caps = caps if isinstance(caps, dict) else {}
    sc = caps.get("sessionCapabilities")
    sc = sc if isinstance(sc, dict) else {}
    answer = {
        "agent": agent,
        "list": sc.get("list") is not None,
        "load": caps.get("loadSession") is True,
        "resume": sc.get("resume") is not None,
        "more": False,
        "sessions": [],
    }
    if not answer["list"]:
        return answer
    found = []
    cursor = None
    for _ in range(HISTORY_PAGES):
        params = {}
        if cwd is not None:
            params["cwd"] = cwd
        if cursor:
            params["cursor"] = cursor
        msg = talk.call("session/list", params, HISTORY_REQUEST)
        res = msg.get("result")
        if "error" in msg or not isinstance(res, dict):
            err = msg.get("error")
            raise HistoryFailed("%s: %s" % (agent, err.get("message") if isinstance(err, dict) else "no result"))
        rows = res.get("sessions")
        for raw in rows if isinstance(rows, list) else []:
            item = _history_item(raw, cwd)
            if item is None:
                continue
            if len(found) >= HISTORY_MAX:
                answer["more"] = True
                break
            found.append(item)
        nxt = res.get("nextCursor")
        cursor = nxt if isinstance(nxt, str) and nxt else None
        if cursor is None or answer["more"]:
            break
    if cursor is not None:
        answer["more"] = True
    # ISO timestamps sort as text; newest first, unknown last, ties keep the agent's order.
    found.sort(key=lambda s: s.get("updatedAt") or "", reverse=True)
    answer["sessions"] = found
    return answer


def cmd_history(agent, cwd):
    """Asks [agent] (briefly run, no keeper, no session) what it remembers:
    prints one JSON line `{"agent","list","load","resume","more","sessions"}`
    (see HISTORY_*). [cwd], when given, limits the list to that folder; without
    it the agent runs in the home folder and lists every folder. Touches no
    keeper file; the agent is torn down on every path."""
    route = route_by_id(agent)
    if route is None:
        fail(EX_USAGE, "unknown agent: " + agent)
    if cwd is None:
        where = home_dir()
    else:
        cwd = where = os.path.abspath(os.path.expanduser(cwd))
        if not os.path.isdir(cwd):
            fail(EX_GONE, "the folder does not exist on this host: " + cwd)
        if not os.access(cwd, os.R_OK | os.X_OK):
            fail(EX_GONE, "the folder cannot be opened on this host: " + cwd)
    dirs = search_dirs()
    argv = resolve(route, dirs)
    if argv is None:
        want = route["binary"] + (" or npx" if route.get("npx") else "")
        fail(EX_MISSING, "%s is not installed on this host (looked for %s)" % (route["id"], want))

    def stop(signum, frame):
        sys.exit(128 + signum)

    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)
    talk = AgentTalk(argv, where, dirs)
    answer = None
    problem = None
    try:
        try:
            talk.spawn()
            answer = _history_ask(talk, agent, cwd)
        except HistoryFailed as e:
            problem = str(e)
        except OSError as e:
            problem = "could not run %s: %s" % (argv[0], e)
    finally:
        talk.close()
    if problem is not None:
        fail(EX_FAILED, problem)
    try:
        sys.stdout.write(dumps(answer) + "\n")
        sys.stdout.flush()
    except (OSError, ValueError):
        pass


# -- follow ------------------------------------------------------------------


class Gone(Exception):
    """The reader of stdout has gone away."""


def put(data):
    view = memoryview(data)
    try:
        while view:
            n = os.write(1, view)
            view = view[n:]
    except OSError:
        raise Gone()


def cut_str(s):
    """[s] cut to its first FOLLOW_CUT bytes (UTF-8) and a note, if longer."""
    if len(s) * 4 <= FOLLOW_CUT:
        return s
    b = s.encode("utf-8", "replace")
    if len(b) <= FOLLOW_CUT:
        return s
    head = b[:FOLLOW_CUT].decode("utf-8", "ignore")
    return "%s... [%d bytes cut]" % (head, len(b) - len(head.encode("utf-8")))


def scrub(v):
    """[v] with every long string cut and every binary payload dropped; the
    structure stays, so the result is JSON of the same shape."""
    if isinstance(v, str):
        return cut_str(v)
    if isinstance(v, list):
        return [scrub(x) for x in v]
    if not isinstance(v, dict):
        return v
    binary = v.get("type") in FOLLOW_BINARY_TYPES
    out = {}
    for k, x in v.items():
        if isinstance(x, str):
            n = len(x)
            if (binary and n > 256) or (
                k in FOLLOW_BINARY_KEYS and n > 1024 and FOLLOW_B64.match(x[:256])
            ):
                x = "[%d bytes of data not sent]" % n
            elif n > 256 and x.startswith("data:") and "," in x[:128]:
                x = x[: x.index(",") + 1] + "[%d bytes of data not sent]" % n
            else:
                x = cut_str(x)
        else:
            x = scrub(x)
        out[cut_str(k)] = x
    return out


# What omp writes into an assistant message for itself, which `OmpLogMapper`
# never reads: the token accounting and the provider's answer envelope (a base64
# `thinkingSignature` of 0.5-2 KB does not deflate at all). A key the mapper
# starts to read MUST leave this list.
FOLLOW_MESSAGE_NOISE = ("usage", "contextSnapshot", "responseId", "credentialId", "duration", "ttft", "completedAt", "api", "provider", "errorId")


def slim(o):
    """[o], an omp log entry as parsed, without what the phone never reads
    (see FOLLOW_MESSAGE_NOISE), or None for an entry that is only bookkeeping
    (`credential_pin`). Anything that is not shaped like omp's is left as it is.
    Only assistant messages lose the envelope keys: other roles may carry keys
    of the same names."""
    if not isinstance(o, dict):
        return o
    t = o.get("type")
    if t == "credential_pin":
        return None
    m = o.get("message") if t == "message" else None
    if isinstance(m, dict):
        if m.get("role") == "assistant":
            for k in FOLLOW_MESSAGE_NOISE:
                m.pop(k, None)
            c = m.get("content")
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "thinking":
                        b.pop("thinkingSignature", None)
        d = m.get("details")
        if isinstance(d, dict):
            # a second copy of the text of a file read, for omp's own screen
            d.pop("displayContent", None)
    return o


def follow_record(raw):
    """One log line (bytes) as the compact UTF-8 JSON the phone gets, or None
    for a blank line or a line the phone has no use for (see slim). Whatever is
    not JSON becomes {"raw": first 2 KB}."""
    if not raw.strip():
        return None
    try:
        obj = slim(json.loads(raw.decode("utf-8")))
        if obj is None:
            return None
        out = json.dumps(scrub(obj), ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    except (ValueError, RecursionError):
        out = json.dumps(
            {"raw": raw[:FOLLOW_RAW].decode("utf-8", "replace")},
            ensure_ascii=False, separators=(",", ":"),
        )
    return out.encode("utf-8", "replace")


class Follower(object):
    """Reads complete lines of one file and prints `<endOffset>\t<json>`
    records. `pos` is the offset after the last line consumed; the bytes of a
    line still waiting for its newline are held in `buf`, never printed."""

    def __init__(self, path, frm, poll=FOLLOW_POLL, idle_exit=0, clock=time.monotonic, tail=FOLLOW_TAIL, zipped=False):
        self.path = path
        self.frm = frm
        self.tail = tail
        self.poll = poll
        self.idle_exit = idle_exit
        self.clock = clock
        self.last_growth = clock()
        self.fd = os.open(path, os.O_RDONLY)
        self.ident = None
        self.pos = self.read_pos = 0
        self.buf = bytearray()
        self.total = 0
        self.over = False
        self.skip = False
        self.out = []
        self.watch = True
        # `--z`: what is sent is cut into whole records and a batch of at least
        # ATTACH_ZIP_MIN bytes travels as one `Z<base64 of zlib data>` line of
        # one zlib stream, as in `attach --z` (the log of a long chat shrinks
        # ~3x; a record or two stays as it is).
        self.z = zlib.compressobj(6) if zipped else None

    def emit(self, data):
        if self.z is not None and len(data) >= ATTACH_ZIP_MIN:
            data = zip_batch(self.z, data)
        put(data)

    def byte_at(self, offset):
        return os.pread(self.fd, 1, offset)

    def start_tail(self, size, marker):
        """Begin at the last self.tail bytes, after a newline."""
        start = max(0, size - self.tail)
        self.skip = start > 0
        if self.skip:
            start -= 1
        self.pos = self.read_pos = start
        self.restart_line()
        if marker:
            self.emit(b"R\t%d\n" % start)

    def restart_line(self):
        self.buf = bytearray()
        self.total = 0
        self.over = False

    def begin(self):
        st = os.fstat(self.fd)
        self.ident = (st.st_dev, st.st_ino)
        frm = self.frm
        if frm is None:
            self.start_tail(st.st_size, False)
        elif frm <= st.st_size and (frm == 0 or self.byte_at(frm - 1) == b"\n"):
            self.pos = self.read_pos = frm
        else:
            # the file is not the one the offset came from
            self.start_tail(st.st_size, True)

    def check(self):
        """One stat. True when there is something to read: the file grew, or
        it shrank or was replaced and starts over."""
        try:
            st = os.stat(self.path)
        except OSError:
            return False
        if (st.st_dev, st.st_ino) == self.ident and st.st_size >= self.read_pos:
            return st.st_size > self.read_pos
        fd = os.open(self.path, os.O_RDONLY)
        os.close(self.fd)
        self.fd = fd
        st = os.fstat(fd)
        self.ident = (st.st_dev, st.st_ino)
        self.start_tail(st.st_size, True)
        self.last_growth = self.clock()
        return True

    def pump(self):
        while True:
            data = os.pread(self.fd, FOLLOW_READ, self.read_pos)
            if not data:
                return
            self.read_pos += len(data)
            self.last_growth = self.clock()
            self.feed(data)
            if self.out:
                self.emit(b"".join(self.out))
                self.out = []

    def feed(self, data):
        n = len(data)
        start = 0
        while start < n:
            i = data.find(b"\n", start)
            end = n if i < 0 else i
            k = end - start
            if k:
                self.total += k
                if self.total > FOLLOW_LINE:
                    # too long to ship: counted, not kept
                    self.over = True
                    self.buf = bytearray()
                elif not (self.skip or self.over):
                    self.buf += data[start:end]
            if i < 0:
                return
            self.pos += self.total + 1
            if self.skip:
                self.skip = False
            else:
                if self.over:
                    rec = json.dumps({"raw": "[line of %d bytes not sent]" % self.total}).encode("ascii")
                else:
                    rec = follow_record(bytes(self.buf))
                if rec is not None:
                    self.out.append(b"%d\t%s\n" % (self.pos, rec))
            self.restart_line()
            start = i + 1

    def interval(self):
        """Seconds to the next look at the file: the base poll while it grows,
        longer the longer it has been quiet."""
        idle = self.clock() - self.last_growth
        slow = 0.0
        for after, every in FOLLOW_BACKOFF:
            if idle >= after:
                slow = every
        return max(self.poll, slow)

    def wait(self, seconds):
        """Sleeps [seconds]; False when stdin was closed (the phone went
        away)."""
        if self.watch:
            try:
                ready = select.select([0], [], [], seconds)[0]
                if not ready:
                    return True
                if not os.read(0, 4096):
                    return False
                return True
            except (OSError, ValueError):
                self.watch = False
        time.sleep(seconds)
        return True

    def run(self):
        self.begin()
        self.pump()
        # Everything the file held is sent: the phone is up to date (an empty
        # log or a resume at its end sends no record, and would otherwise have
        # to guess from the silence).
        self.emit(b"C\t%d\n" % self.pos)
        while self.wait(self.interval()):
            if self.idle_exit and self.clock() - self.last_growth >= self.idle_exit:
                return
            if self.check():
                self.pump()


def follow_target(path):
    """The real path of [path], which must be an absolute .jsonl file under
    $HOME that this user can read; fails with exit 66 otherwise."""
    if not path or not os.path.isabs(path) or not path.endswith(".jsonl"):
        fail(EX_GONE, "not an absolute path to a .jsonl file: " + trunc(path, 200))
    real = os.path.realpath(path)
    home = os.path.realpath(home_dir()).rstrip("/") + "/"
    if not real.startswith(home) or not real.endswith(".jsonl"):
        fail(EX_GONE, "not a log file in your home folder: " + trunc(path, 200))
    try:
        st = os.stat(real)
    except OSError as e:
        fail(EX_GONE, "cannot read %s: %s" % (trunc(path, 200), e.strerror or e))
    if not stat.S_ISREG(st.st_mode) or not os.access(real, os.R_OK):
        fail(EX_GONE, "not a readable file: " + trunc(path, 200))
    return real


def cmd_follow(path, frm, poll=FOLLOW_POLL, idle_exit=0, tail=FOLLOW_TAIL, zipped=False):
    """Prints the tail of the log (or what follows byte [frm]), then every
    complete line appended later, one record per line: `<endOffset>\t<json>`
    (long strings and binary payloads cut), `R\t<offset>` when the file
    shrank or was replaced (what follows starts at that offset), `C\t<offset>`
    once, when the file's content up to that offset has been sent, or
    `E\t<message>` before exiting 70 when reading fails. Ends when stdout or
    stdin closes, or after [idle_exit] seconds (0: never) without growth.
    The file is looked at every [poll] seconds, less often while it is quiet."""
    real = follow_target(path)
    try:
        Follower(real, frm, poll, idle_exit, tail=tail, zipped=zipped).run()
    except Gone:
        pass
    except OSError as e:
        try:
            put(("E\t%s\n" % trunc(str(e.strerror or e).replace("\n", " "), 300)).encode("utf-8", "replace"))
        except Gone:
            pass
        sys.exit(EX_FAILED)


def main(argv):
    if not argv:
        fail(EX_USAGE, "usage: probe | list | start --agent ID --cwd DIR | attach ID [--z] | kill ID | follow PATH [--z] [--from N] [--poll-ms N] [--idle-exit S] [--tail-bytes N] | history AGENT [CWD]")
    cmd, rest = argv[0], argv[1:]
    if cmd != "follow":
        load_daemon_modules()
    try:
        if cmd == "probe":
            cmd_probe()
        elif cmd == "list":
            cmd_list()
        elif cmd == "start":
            opts = {}
            i = 0
            while i + 1 < len(rest) and rest[i] in ("--agent", "--cwd"):
                opts[rest[i]] = rest[i + 1]
                i += 2
            if i != len(rest) or "--agent" not in opts or "--cwd" not in opts:
                fail(EX_USAGE, "usage: start --agent ID --cwd DIR")
            cmd_start(opts["--agent"], opts["--cwd"])
        elif cmd == "history" and len(rest) in (1, 2) and rest[0] and (len(rest) == 1 or rest[1]):
            cmd_history(rest[0], rest[1] if len(rest) == 2 else None)
        elif cmd == "follow" and rest:
            opts = {}
            i = 1
            zipped = False
            while i < len(rest):
                if rest[i] == "--z":
                    zipped = True
                    i += 1
                elif i + 1 < len(rest) and rest[i] in ("--from", "--poll-ms", "--idle-exit", "--tail-bytes") and rest[i + 1].isdigit():
                    opts[rest[i]] = int(rest[i + 1])
                    i += 2
                else:
                    break
            if i != len(rest):
                fail(EX_USAGE, "usage: follow PATH [--z] [--from N] [--poll-ms N] [--idle-exit S] [--tail-bytes N]")
            poll = max(20, min(opts.get("--poll-ms", int(FOLLOW_POLL * 1000)), 60000)) / 1000.0
            tail = max(FOLLOW_TAIL_MIN, min(opts.get("--tail-bytes", FOLLOW_TAIL), FOLLOW_TAIL_MAX))
            cmd_follow(rest[0], opts.get("--from"), poll, opts.get("--idle-exit", 0), tail, zipped)
        elif cmd == "attach" and len(rest) in (1, 2) and (len(rest) == 1 or rest[1] == "--z"):
            cmd_attach(rest[0], len(rest) == 2)
        elif cmd == "kill" and len(rest) == 1:
            cmd_kill(rest[0])
        else:
            fail(EX_USAGE, "unknown command: " + cmd)
    except OSError as e:
        fail(EX_FAILED, "%s: %s" % (cmd, e))


if __name__ == "__main__":
    main(sys.argv[1:])
''';
