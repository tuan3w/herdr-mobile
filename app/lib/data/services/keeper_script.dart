/// The host-side keeper (`docs/AGENT_SESSIONS.md`, "The keeper"): one python3
/// file, standard library only, python 3.6+. `keeper_command.dart` fills
/// [keeperRoutesSlot] with `agentRoutes` and installs the result once per host
/// as `~/.herdr-mobile/keeper-<version>.py`.
///
/// Subcommands: `probe`, `list`, `start --agent ID --cwd DIR`, `attach ID`,
/// `kill ID`, `view ID`, `follow PATH [--from N]`, `history AGENT [CWD]`. It
/// is plain python: `python3 keeper-<version>.py list`. `view` runs only on
/// the host, in the herdr pane a keeper opens for its session.
library;

/// Where `keeper_command.dart` puts the JSON route table.
const keeperRoutesSlot = '@@ROUTES@@';

const keeperPython = r'''
"""herdr-keeper: owns one ACP agent process so it outlives the phone's SSH link.

Subcommands: probe | list | start --agent ID --cwd DIR | attach ID [--z] | kill ID
| view ID | follow PATH [--from N] | history AGENT [CWD].
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
# What gives Claude Code a login without the macOS Keychain (see
# Keeper.keychain_login).
CLAUDE_ENV_LOGINS = (
    "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
)

# The umask this process got from the person's login (sshd's session; for a
# launchd job, the one `start` read, see start_via_launchd). The keeper itself
# runs at 077 (daemon): its own files are private. What it spawns for the
# person, the agent and every tool the agent runs, gets this one back
# (_default_signals): with 077 inherited, each file an agent wrote was
# unreadable to the person's group, unlike one written from their own shell.
# Read once at import, before anything changes the umask, and defined here so
# a process that never runs daemon() (AgentTalk) has a value too.
def read_umask():
    mask = os.umask(0o077)
    os.umask(mask)
    return mask


LOGIN_UMASK = read_umask()


# On macOS a keeper of an agent that reads its login from the Keychain is
# started as a launchd job of the person's desktop session instead of as a
# child of sshd: macOS opens the login Keychain only to processes of that
# session (see start_in_desktop_session).
LAUNCHD_PREFIX = "dev.herdrmobile.keeper"
LAUNCHD_LABEL = re.compile(r"^dev\.herdrmobile\.keeper\.[0-9a-f]{12}$")
LAUNCHD_TIMEOUT = 10
# The job's label in a keeper that runs as one (cmd_daemon); None otherwise.
DESKTOP_LABEL = None

# Shared sessions (docs/AGENT_SESSIONS.md): the keeper's own file, which herdr
# runs as `view` in the pane the keeper opens for the session.
SCRIPT = os.path.abspath(globals().get("__file__") or sys.argv[0])
PANE_WORKSPACE = "Phone sessions"
# Seconds a herdr command may take; the first one is also the "is a server
# running" probe, and the tab close runs while `kill` waits.
HERDR_TIMEOUT = 10
HERDR_PROBE_TIMEOUT = 3
HERDR_OUT_MAX = 4 * 1024 * 1024
# `view` in herdr's agent list: the source of its reports.
HERDR_SOURCE = "herdr-mobile"
VIEW_CLIENT = "herdr-mobile-view"

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


def launchd_bootout(label, wait=True):
    """Unloads the launchd job [label] of this person's desktop session; its
    process, when it still runs, gets SIGTERM. Best effort, never raises."""
    if not LAUNCHD_LABEL.match(label or ""):
        return
    argv = ["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), label)]
    try:
        p = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            close_fds=True, start_new_session=True,
        )
        if wait:
            p.wait(timeout=LAUNCHD_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        pass


def remove_keeper(kid):
    info = read_info(kid)
    label = info.get("launchd") if info else None
    if isinstance(label, str):
        launchd_bootout(label, wait=False)
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
    info["clients"] = 0
    info.setdefault("exit_reason", "The keeper process is gone (killed, or the host restarted).")
    info["exited_at"] = now_ms()
    try:
        write_json(kid + ".json", info)
    except OSError:
        pass
    unlink(kid + ".sock")


def starting_alive(info):
    """A keeper still waiting for its agent's `initialize` answer. It does not
    accept connections yet (the backlog of its socket is 16), so a probe cannot
    tell it from a dead one: the 16th probe was refused and the keeper marked
    exited while it was alive and kill skipped it. Only its process says. A
    start that outlives the init timeout by 30 s is not starting any more (the
    keeper ends it itself), so a record that old is probed like any other."""
    if info.get("state") != "starting" or not pid_alive(info.get("pid")):
        return False
    began = info.get("started_at")
    return not isinstance(began, (int, float)) or now_ms() - began < (INIT_TIMEOUT + 30) * 1000


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
        if info.get("state") != "exited" and not starting_alive(info):
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
            last = self.last
            if last is not None and self.bulk(last):
                # The turn in flight is what fills the log (omp sends an update
                # for every beat and chunk of a long command). The turns before it
                # are a sliver, so dropping them frees next to nothing and only
                # loses the conversation: it eats its own oldest entries instead.
                if self.trim_next(pinned) or self.cut_oldest(last):
                    continue
                break
            if not (self.trim_next(pinned) or self.drop_next(pinned) or self.cut_oldest()):
                break

    def bulk(self, t):
        """Whether turn `t` alone is over a bound, or, past the entry bound,
        holds more than half of what that bound allows: dropping the turns
        before it cannot be what makes room."""
        if t.n > self.max_bytes or len(t.e) > self.max_entries:
            return True
        return self.count > self.max_entries and len(t.e) * 2 > self.max_entries

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

    def cut_oldest(self, only=None):
        """Last resort, when what is left (the newest turn, a waiting one) is
        over the bounds by itself: the oldest entry that is not a user
        message, never the newest entry; of the turn `only` when given, else
        of the oldest turn that has one. False when there is none."""
        for t in ([only] if only is not None else self.turns.values()):
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


def answer_of(info, msg):
    """What a client answered to the held request `info`, in words for the
    other clients (`_herdr/resolved`): the chosen option's name ('cancelled'
    when none was chosen), or a question's action."""
    res = None if "error" in msg else msg.get("result")
    res = res if isinstance(res, dict) else {}
    if info["method"] == "elicitation/create":
        a = res.get("action")
        return a if isinstance(a, str) and a else "cancel"
    out = res.get("outcome")
    out = out if isinstance(out, dict) else {}
    oid = out.get("optionId")
    if out.get("outcome") != "selected" or not isinstance(oid, str):
        return "cancelled"
    p = info.get("params")
    options = p.get("options") if isinstance(p, dict) else None
    for o in options if isinstance(options, list) else []:
        if isinstance(o, dict) and o.get("optionId") == oid and isinstance(o.get("name"), str):
            return o["name"]
    return oid


def herdr_result(out):
    """`.result` of what a herdr CLI command printed ({} when it is not that)."""
    try:
        d = json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        return {}
    r = d.get("result") if isinstance(d, dict) else None
    return r if isinstance(r, dict) else {}


def view_runnable(path):
    """True when `python3 '<path>' view ID` is safe to type into a shell: the
    path is one single-quoted word."""
    return bool(path) and os.path.isabs(path) and "'" not in path and not any(ord(c) < 0x20 or ord(c) == 0x7F for c in path)



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
        self.born = time.time()
        # A client connection: `active` once it sent a JSON-RPC line, `live`
        # once it gets the session's events (after its load).
        self.active = False
        self.live = False
        # Who it is (its `initialize`): the name the other clients are told
        # when it answers a request, and whether it is a `view` (a terminal,
        # which does not count as having seen a turn end).
        self.label = "another client"
        self.viewer = False
        # When it last sent something (Keeper.touches): a request only one
        # client can answer goes to the one used last.
        self.touched = 0


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
        self.touches = 0
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
        # The herdr pane a `view` client said it shows this session in.
        self.pane_id = None
        # Claude Code on macOS keeps its login in the login Keychain, which
        # macOS does not open for an SSH session (the phone starts every
        # keeper over SSH): without a login in the environment it answers
        # "Please run /login" however often the person signs in. The phone
        # says so when the agent asks for a login.
        self.keychain_login = sys.platform == "darwin" and agent == "claude" and not DESKTOP_LABEL and not any(
            os.environ.get(k) for k in CLAUDE_ENV_LOGINS)
        # The pane the keeper opens in herdr (open_pane): the herdr binary,
        # the command in flight and the tab, closed when the session is ended.
        self.herdr = None
        self.herdr_job = None
        self.pane_tab = None
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
            "clients": sum(1 for c in self.conns if c.active and not c.closed),
        }
        if self.proc is not None:
            d["agent_pid"] = self.proc.pid
        if self.session_id:
            d["session_id"] = self.session_id
        if self.title:
            d["title"] = self.title
        if self.pane_id:
            d["pane_id"] = self.pane_id
        if self.keychain_login:
            d["login"] = "keychain"
        if DESKTOP_LABEL:
            d["launchd"] = DESKTOP_LABEL
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
        if ch is None or ch.closed:
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
        if ch.active:
            self.dirty = True
        for info in self.pending.values():
            info["conns"].discard(ch)
        for kid in [k for k, v in self.fwd.items() if v["conn"] is ch]:
            v = self.fwd.pop(kid)
            self.send_agent({
                "jsonrpc": "2.0", "id": v["aid"],
                "error": {"code": -32000, "message": "The client went away before it answered."},
            })

    def clients(self):
        """The clients that get the session's events: attached and loaded.
        Every one is equal (docs/AGENT_SESSIONS.md, "Shared sessions")."""
        return [c for c in self.conns if c.live and not c.closed]

    def broadcast(self, data, skip=None):
        for c in self.clients():
            if c is not skip:
                self.put(c, data)

    def answerer(self):
        """The client a request only one can answer goes to (`fs/*`, an
        extension): the phone used last, else any client; None when none is
        there."""
        cs = self.clients()
        if not cs:
            return None
        return max(cs, key=lambda c: (not c.viewer, c.touched))

    def introduce(self, conn, params):
        """Who a client is, from its `initialize`: the label the others are
        told when it answers (`clientInfo.title`, else `name`), whether it is a
        `view` (`_meta.herdr.viewer`) and the herdr pane it shows the session
        in (`_meta.herdr.pane`, kept until another `view` names one)."""
        if not isinstance(params, dict):
            return
        ci = params.get("clientInfo")
        if isinstance(ci, dict):
            for key in ("title", "name"):
                v = ci.get(key)
                if isinstance(v, str) and v.strip():
                    conn.label = trunc(v.strip(), 80)
                    break
        m = params.get("_meta")
        h = m.get("herdr") if isinstance(m, dict) else None
        if not isinstance(h, dict):
            return
        conn.viewer = h.get("viewer") is True
        pane = h.get("pane")
        if conn.viewer and isinstance(pane, str) and pane and pane != self.pane_id:
            self.pane_id = pane[:200]
            self.dirty = True

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
        # A connection counts with its first valid line: garbage and a
        # connect-and-close probe never do.
        if not conn.active:
            conn.active = True
            self.dirty = True
        self.touches += 1
        conn.touched = self.touches
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
        if method == "initialize":
            self.introduce(conn, params)
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
            self.begin_turn(params, oid, conn)
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
        held = False
        if isinstance(rid, str):
            info = self.pending.pop(rid, None)
            if info is not None:
                held = True
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
        if held:
            self.settle(info, conn, msg)

    def settle(self, info, by, msg):
        """The first answer won: every other client given the request is told
        who answered and what (`_herdr/resolved`), then its copy is taken back
        (`$/cancel_request`), so nothing vanishes without a reason."""
        others = [c for c in list(info["conns"]) if c is not by and not c.closed]
        if not others:
            return
        kid = info["kid"]
        note = enc({
            "jsonrpc": "2.0", "method": "_herdr/resolved",
            "params": {"requestId": kid, "by": by.label, "answer": answer_of(info, msg)},
        })
        cancel = enc({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": kid}})
        for c in others:
            self.put(c, note)
            self.put(c, cancel)

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
        # (a refusal takes it back out of the log, see end_turn). The replay
        # brings it to this client; the others get it live.
        self.flush_stash(skip=conn)
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
        # "Seen" means a phone saw it: a `view` client does not count.
        if self.unseen_end is not None and not conn.viewer:
            self.unseen_end = None
            self.save()
        for info in list(self.pending.values()):
            self.issue(conn, info)

    def issue(self, conn, info):
        info["conns"].add(conn)
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
        if method == "session/update":
            self.note_update(msg, len(raw))
            self.broadcast(raw + b"\n")
        elif method == "$/cancel_request":
            p = msg.get("params")
            target = p.get("requestId") if isinstance(p, dict) else None
            for kid, info in list(self.pending.items()):
                if info["aid"] == target and type(info["aid"]) is type(target):
                    del self.pending[kid]
                    self.save()
                    data = enc({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": kid}})
                    for c in list(info["conns"]):
                        self.put(c, data)
                    return
            for kid, v in list(self.fwd.items()):
                if v["aid"] == target and type(v["aid"]) is type(target):
                    del self.fwd[kid]
                    self.put(v["conn"], enc({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": kid}}))
                    return
        else:
            # Claude's live background tasks are a level, not a log entry: the
            # last one is kept so a client that attaches later still gets it.
            if method == "_claude/sdkMessage" and b"background_tasks_changed" in raw:
                self.bg_level = raw
            self.broadcast(raw + b"\n")

    def on_agent_request(self, msg):
        method = msg["method"]
        aid = msg["id"]
        # The prompt this request is about comes first, for the clients that
        # did not send it (an agent may ask before it says anything).
        self.flush_stash()
        kid = "kp%d" % self.next_kid
        self.next_kid += 1
        if method in HELD:
            # Every client gets it under the same id; the first answer wins
            # (settle). `conns`: the clients that were given it.
            info = {"kid": kid, "aid": aid, "method": method, "params": msg.get("params"), "conns": set()}
            self.pending[kid] = info
            self.save()
            self.hook("blocked", self.summarize(msg))
            for c in self.clients():
                self.issue(c, info)
            return
        c = self.answerer()
        if c is not None:
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
        if not conn.closed:
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

    def begin_turn(self, params, oid, conn):
        self.flush_stash()
        sid = params.get("sessionId") if isinstance(params, dict) else None
        if isinstance(sid, str):
            # The other clients see the prompt start; its message follows
            # when it is logged (flush_stash), its end in end_turn.
            self.broadcast(self.state_update(sid, "running", None), skip=conn)
        if not isinstance(params, dict) or not isinstance(params.get("prompt"), list):
            return
        blocks = []
        for b in params["prompt"]:
            if not isinstance(b, dict):
                continue
            if b.get("type") != "text" and len(json.dumps(b)) > 20000:
                b = {"type": "text", "text": "[%s omitted]" % b.get("type", "attachment")}
            blocks.append(b)
        if blocks and isinstance(sid, str):
            self.stash = {"sid": sid, "blocks": blocks, "mid": "keeper-" + secrets.token_hex(6), "oid": oid, "conn": conn}

    def flush_stash(self, skip=None):
        """Logs the message of the prompt just sent and shows it to the other
        clients (the one that sent it shows its own; [skip] gets it from a
        replay)."""
        st = self.stash
        if st is None:
            return
        self.stash = None
        logged = self.sent.setdefault(st["oid"], [])
        for b in st["blocks"]:
            upd = {"sessionUpdate": "user_message_chunk", "content": b, "messageId": st["mid"]}
            m = {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": st["sid"], "update": upd}}
            data = enc(m)
            e = self.log_add(m, len(data) - 1)
            if e is not None and not any(x is e for x in logged):
                logged.append(e)
            for c in self.clients():
                if c is not st["conn"] and c is not skip:
                    self.put(c, data)

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
        refused = isinstance(err, dict) and err.get("code") == SESSION_BUSY
        if refused:
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
        params = route.get("params")
        sid = params.get("sessionId") if isinstance(params, dict) else None
        if isinstance(sid, str):
            # The other clients saw this prompt start (begin_turn): they see it
            # end. A refused prompt never ran: they see the state as it is.
            if not refused:
                self.broadcast(self.state_update(sid, "idle", stop), skip=conn)
            if self.busy():
                self.broadcast(self.state_update(sid, "running", None), skip=conn)
            elif refused:
                self.broadcast(self.state_update(sid, "idle", None), skip=conn)
        # "Seen" and the `done` alert are about the phone: a `view` client
        # (a terminal) does not count as having seen the end.
        if any(not c.viewer for c in self.clients()):
            self.unseen_end = None
            return
        self.unseen_end = {"stop": stop}
        if not any(c.active and not c.viewer and not c.closed for c in self.conns):
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
        self.open_pane()

    # -- the herdr pane

    def open_pane(self):
        """Shows the session in herdr on this computer (docs/AGENT_SESSIONS.md,
        "Shared sessions"): a tab in the workspace `Phone sessions` (made when
        missing, never focused) running `view`, which reports the session to
        herdr. A chain of herdr commands that tick polls, never waited for; no
        herdr, no server or any failure: logged, and nothing else changes."""
        if os.environ.get("HERDR_MOBILE_NO_PANE") == "1" or os.path.exists(os.path.join(home_dir(), ".herdr-mobile", "no-panes")):
            return
        herdr = os.environ.get("HERDR_MOBILE_HERDR") or which("herdr", self.dirs)
        if not herdr:
            return
        if not view_runnable(SCRIPT):
            self.dlog("no herdr pane: the script path cannot be typed into a shell: %r" % SCRIPT)
            return
        self.herdr = herdr
        # Also the probe: a herdr with no server running fails here, at once.
        self.herdr_call(["workspace", "list"], self.pane_workspaces, HERDR_PROBE_TIMEOUT)

    def pane_label(self):
        route = route_by_id(self.agent) or {}
        return "%s \u00b7 %s" % (route.get("label") or self.agent, os.path.basename(self.cwd.rstrip("/")) or self.cwd)

    def pane_workspaces(self, out):
        res = herdr_result(out)
        for w in (res.get("workspaces") if isinstance(res.get("workspaces"), list) else []):
            if isinstance(w, dict) and w.get("label") == PANE_WORKSPACE and isinstance(w.get("workspace_id"), str):
                self.herdr_call(
                    ["tab", "create", "--workspace", w["workspace_id"], "--cwd", self.cwd, "--label", self.pane_label(), "--no-focus"],
                    lambda o: self.pane_made(o, False),
                )
                return
        # A new workspace comes with a tab and a pane: this session takes them.
        self.herdr_call(
            ["workspace", "create", "--label", PANE_WORKSPACE, "--cwd", self.cwd, "--no-focus"],
            lambda o: self.pane_made(o, True),
        )

    def pane_made(self, out, rename):
        res = herdr_result(out)
        tab = res.get("tab") if isinstance(res.get("tab"), dict) else {}
        pane = res.get("root_pane") if isinstance(res.get("root_pane"), dict) else {}
        tid, pid = tab.get("tab_id"), pane.get("pane_id")
        if not (isinstance(tid, str) and tid and isinstance(pid, str) and pid):
            self.dlog("no herdr pane: herdr named no tab and pane: %s" % trunc(out.decode("utf-8", "replace"), 300))
            return
        self.pane_tab = tid
        after = (lambda _o: self.herdr_call(["tab", "rename", tid, self.pane_label()], None)) if rename else None
        self.herdr_call(["pane", "run", pid, "python3 '%s' view %s" % (SCRIPT, self.id)], after)
        self.dlog("herdr pane %s (tab %s) shows the session" % (pid, tid))

    def herdr_call(self, args, then, timeout=HERDR_TIMEOUT):
        """Starts one herdr command; tick calls [then] with its stdout when it
        exits 0 (herdr_poll)."""
        try:
            p = subprocess.Popen(
                [self.herdr] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                close_fds=True, start_new_session=True,
            )
        except (OSError, ValueError) as e:  # ValueError: an argument the locale cannot encode
            self.dlog("herdr %s did not start: %s" % (" ".join(args[:2]), e))
            return
        for f in (p.stdout, p.stderr):
            os.set_blocking(f.fileno(), False)
        self.herdr_job = {"p": p, "args": args, "then": then, "out": bytearray(), "err": bytearray(), "deadline": time.time() + timeout}

    def herdr_poll(self):
        job = self.herdr_job
        if job is None:
            return
        p = job["p"]
        rc = p.poll()
        for f, buf in ((p.stdout, job["out"]), (p.stderr, job["err"])):
            while len(buf) < HERDR_OUT_MAX:
                try:
                    data = os.read(f.fileno(), 65536)
                except OSError:
                    break
                if not data:
                    break
                buf += data
        if rc is None:
            if time.time() < job["deadline"]:
                return
            self.herdr_stop()
        else:
            self.herdr_job = None
            p.stdout.close()
            p.stderr.close()
        name = "herdr " + " ".join(job["args"][:2])
        if rc is None:
            self.dlog("%s did not answer in time" % name)
        elif rc != 0:
            self.dlog("%s failed (%d): %s" % (name, rc, trunc(bytes(job["err"]).decode("utf-8", "replace").strip(), 300)))
        elif job["then"] is not None:
            job["then"](bytes(job["out"]))

    def herdr_stop(self):
        """Ends the herdr command in flight (it was started by this keeper)."""
        job = self.herdr_job
        if job is None:
            return
        self.herdr_job = None
        p = job["p"]
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        p.stdout.close()
        p.stderr.close()

    def close_pane(self):
        """The session was ended on request: its tab goes too. (An agent that
        exits on its own leaves it: the terminal says why.)"""
        self.herdr_stop()
        if not (self.herdr and self.pane_tab):
            return
        try:
            subprocess.run(
                [self.herdr, "tab", "close", self.pane_tab], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, close_fds=True, timeout=HERDR_PROBE_TIMEOUT,
            )
        except (OSError, subprocess.SubprocessError) as e:
            self.dlog("herdr tab close failed: %s" % e)

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
        """The agent is gone: record why, tell the clients, leave."""
        self.state = "exited"
        self.exit_code = code
        self.exit_reason = reason
        self.exited_at = now_ms()
        for info in self.pending.values():
            self.dlog("pending %s %s cancelled: the agent exited" % (info["method"], info["kid"]))
        self.pending.clear()
        self.fwd.clear()
        self.routes.clear()
        note = enc({
            "jsonrpc": "2.0", "method": "_herdr/agent_exited",
            "params": {"exitCode": code, "reason": reason},
        })
        for c in list(self.conns):
            if c.closed or not c.active:
                continue
            try:
                c.sock.setblocking(True)
                c.sock.settimeout(2)
                c.sock.sendall(bytes(c.wbuf) + note)
            except OSError:
                pass
        for ch in list(self.conns):
            self.close_conn(ch, "agent exited")
        if self.terminating:
            self.close_pane()
        else:
            self.herdr_stop()
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
        self.herdr_poll()
        for ch in list(self.conns):
            if not ch.active and t - ch.born > 30:
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
    """preexec of everything the keeper starts for the person: default signal
    handling and the umask of the login (the keeper's own is 077)."""
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.umask(LOGIN_UMASK)


# -- subcommands -----------------------------------------------------------


def cmd_probe():
    dirs = search_dirs()
    print(dumps({"routes": [r["id"] for r in ROUTES if resolve(r, dirs)]}))


def cmd_list():
    os.chdir(state_dir())
    print(dumps(scan()))


def start_in_desktop_session(agent):
    """Whether the keeper of [agent] is started as a job of the person's
    desktop session: on macOS, for Claude Code, which keeps its login in the
    login Keychain. sshd's children cannot open it (errSecInteractionNotAllowed),
    so a keeper started from the phone's SSH session answered "Please run
    /login" however often the person signed in; Zed has no such problem because
    it starts the agent from the desktop app. Not when the environment already
    holds a login (a token needs no Keychain), and not under
    HERDR_MOBILE_NO_LAUNCHD (tests)."""
    return (
        sys.platform == "darwin"
        and agent == "claude"
        and not os.environ.get("HERDR_MOBILE_NO_LAUNCHD")
        and not any(os.environ.get(k) for k in CLAUDE_ENV_LOGINS)
    )


def launchctl(args):
    """The finished `launchctl` process, or None when it could not be run or
    did not finish."""
    try:
        return subprocess.run(
            ["launchctl"] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=LAUNCHD_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def start_via_launchd(agent, cwd):
    """Runs the keeper as a launchd job of the person's desktop session
    (`gui/<uid>`) and waits for its report. The job is `daemon` with this
    process's whole environment, so it behaves as a keeper started here; its
    report comes back in a file, as there is no pipe to a job. Returns the
    report, or None when that cannot be done (nobody is logged in at the
    desktop, launchctl refused): the caller then starts the keeper the usual
    way. The job outlives this SSH session like any daemon, and unloads
    itself when the keeper ends (daemon_exit)."""
    import plistlib
    domain = "gui/%d" % os.getuid()
    p = launchctl(["print", domain])
    if p is None or p.returncode != 0:
        return None
    tok = secrets.token_hex(6)
    label = "%s.%s" % (LAUNCHD_PREFIX, tok)
    sd = os.getcwd()
    report = os.path.join(sd, "start-%s.report" % tok)
    plist = os.path.join(sd, "start-%s.plist" % tok)
    env = dict(os.environ)
    env["HERDR_KEEPER_LABEL"] = label
    env["HERDR_KEEPER_REPORT"] = report
    # The job starts with launchd's umask, not the login's.
    env["HERDR_KEEPER_UMASK"] = "%o" % LOGIN_UMASK
    job = {
        "Label": label,
        "ProgramArguments": [sys.executable, SCRIPT, "daemon", "--agent", agent, "--cwd", cwd],
        "EnvironmentVariables": env,
        "WorkingDirectory": sd,
        "RunAtLoad": True,
        "KeepAlive": False,
        "StandardOutPath": os.devnull,
        "StandardErrorPath": os.devnull,
    }
    # The environment can hold a token: the file is private and gone once
    # launchd has read it.
    try:
        fd = os.open(plist, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            plistlib.dump(job, f)
        p = launchctl(["bootstrap", domain, plist])
    except (OSError, ValueError):
        p = None
    finally:
        unlink(plist)
    if p is None or p.returncode != 0:
        unlink(report)
        return None
    began = time.time()
    deadline = began + INIT_TIMEOUT + 20
    checked = began
    gone = False
    rep = None
    while time.time() < deadline:
        try:
            with open(report, "rb") as f:
                text = f.read(65536)
        except OSError:
            text = b""
        if b"\n" in text:
            try:
                rep = json.loads(text.decode("utf-8", "replace").splitlines()[0])
            except ValueError:
                rep = {"ok": False, "code": EX_FAILED, "error": "the keeper's answer was not understood"}
            break
        if gone:
            rep = {"ok": False, "code": EX_FAILED, "error": "the keeper did not start (its job ended without an answer)"}
            break
        if time.time() - began > 3 and time.time() - checked >= 1:
            checked = time.time()
            q = launchctl(["print", "%s/%s" % (domain, label)])
            gone = q is not None and (q.returncode != 0 or b"state = running" not in q.stdout)
        time.sleep(0.05)
    if rep is None:
        rep = {"ok": False, "code": EX_FAILED, "error": "the keeper did not start (no answer from the new process)"}
    unlink(report)
    if not rep.get("ok"):
        launchd_bootout(label)
    return rep


def cmd_daemon(agent, cwd):
    """The keeper process of the job `start_via_launchd` loaded. Nobody types
    this: it needs the job's label and report path in its environment."""
    global DESKTOP_LABEL, LOGIN_UMASK
    label = os.environ.pop("HERDR_KEEPER_LABEL", "")
    report = os.environ.pop("HERDR_KEEPER_REPORT", "")
    umask = os.environ.pop("HERDR_KEEPER_UMASK", "")
    if not LAUNCHD_LABEL.match(label) or not report:
        fail(EX_USAGE, "daemon is started by start")
    DESKTOP_LABEL = label
    try:
        LOGIN_UMASK = int(umask, 8) & 0o777
    except ValueError:
        pass
    os.chdir(state_dir())
    fd = os.open(report, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    route = route_by_id(agent)
    dirs = search_dirs()
    argv = resolve(route, dirs) if route else None
    if argv is None:
        os.write(fd, enc({"ok": False, "code": EX_MISSING, "error": "%s is not installed on this host" % agent}))
        os.close(fd)
        daemon_exit()
    daemon(agent, cwd, argv, dirs, fd)


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
    if start_in_desktop_session(agent):
        rep = start_via_launchd(agent, cwd)
        if rep is not None:
            if rep.get("ok"):
                print(dumps(rep["info"]))
                sys.stdout.flush()
                sys.exit(0)
            fail(int(rep.get("code") or EX_FAILED), str(rep.get("error") or "the keeper did not start"))
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


def daemon_exit():
    """The end of a keeper process; one that runs as a launchd job unloads
    the job first, or launchd would keep listing it."""
    if DESKTOP_LABEL:
        launchd_bootout(DESKTOP_LABEL, wait=False)
    os._exit(0)


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
            daemon_exit()
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
    daemon_exit()


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
    except OSError as e:
        info = read_info(kid) or info
        if info.get("state") != "exited":
            pid = info.get("pid")
            if e.errno != errno.ENOENT and pid_alive(pid) and pid != os.getpid() and is_keeper_pid(pid):
                # Alive but not taking connections: still starting its agent,
                # or with a full backlog. Not gone, so not marked exited.
                fail(EX_FAILED, "keeper %s is busy (still starting its agent?); try again in a moment" % kid)
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
    # The record's state does not decide: a keeper marked exited by a failed
    # probe (see scan) can be alive, and forgetting its record would orphan it.
    if pid != os.getpid() and pid_alive(pid) and is_keeper_pid(pid):
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


# -- view: the session in a terminal ------------------------------------------

# What a terminal must not be sent from an agent's text: control characters
# (escape sequences could rewrite the screen); newlines and tabs stay.
VIEW_CONTROL = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f]")
VIEW_NUMBER = re.compile(r"^[0-9]{1,4}$")
# `view` on a terminal: SGR codes of its styles, from the 16 basic colours so
# the terminal's theme decides how they look. Not used when NO_COLOR is set.
VIEW_STYLE = {"dim": "2", "bold": "1", "accent": "36", "ok": "32", "bad": "31", "warn": "33;1"}
# The narrowest `view` wraps to: a pane can be squeezed to almost nothing.
VIEW_MIN_COLS = 20


def short_host():
    return socket.gethostname().split(".")[0] or "this computer"


def one_line(text, n=200):
    """The first line of [text], without control characters, cut to [n]."""
    if not isinstance(text, str):
        return ""
    for line in text.splitlines():
        line = VIEW_CONTROL.sub("", line).strip()
        if line:
            return trunc(line, n)
    return ""


def permission_options(params):
    options = params.get("options") if isinstance(params, dict) else None
    return [o for o in (options if isinstance(options, list) else []) if isinstance(o, dict) and isinstance(o.get("optionId"), str)]


def char_width(ch):
    """Columns [ch] takes in a terminal: 0 for a combining mark, 2 for a wide
    character (CJK, most emoji), else 1."""
    if ord(ch) < 0x300:
        return 1
    if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(text):
    return sum(char_width(c) for c in text)


def fit(text, width, tail=False):
    """[text] cut to [width] columns with an ellipsis where it was cut: its end,
    or its start when [tail] (what was typed last stays in sight)."""
    if text_width(text) <= width:
        return text
    out, w = [], 0
    for ch in (reversed(text) if tail else text):
        cw = char_width(ch)
        if w + cw > width - 1:
            break
        out.append(ch)
        w += cw
    return "\u2026" + "".join(reversed(out)) if tail else "".join(out) + "\u2026"


def wrap_rows(text, width):
    """[text] (one line) cut into rows of at most [width] columns, at spaces
    where it can be: [(offset of the row in text, row)], at least one; a
    trailing empty row when [text] ends in the spaces of a break. Greedy, so
    every row but the last stays the same however [text] grows: `view` writes
    the finished rows of a line still streaming and keeps the last one live.
    width None: one row."""
    if width is None or len(text) * 2 <= width or text_width(text) <= width:
        return [(0, text)]
    rows = []
    start, n = 0, len(text)
    while True:
        w, i, brk, word = 0, start, -1, False
        while i < n:
            cw = char_width(text[i])
            if w + cw > width:
                break
            if text[i] == " ":
                if word:
                    brk = i
            else:
                word = True
            w += cw
            i += 1
        if i >= n:
            rows.append((start, text[start:]))
            return rows
        end = i if text[i] == " " or brk < 0 else brk
        if end <= start:
            end = start + 1  # a character wider than the row
        rows.append((start, text[start:end].rstrip(" ")))
        start = end
        while start < n and text[start] == " ":
            start += 1
        if start >= n:
            rows.append((n, ""))
            return rows


def final_rows(text, width):
    """The rows of a finished line (no trailing empty row)."""
    rows = [r for _, r in wrap_rows(text, width)]
    if len(rows) > 1 and not rows[-1]:
        rows.pop()
    return rows


def call_command(tc):
    """What a waiting tool call will run or touch, whole, as the agent sent it:
    its command (a string or argv words), else its path; "" when it names
    neither."""
    raw = tc.get("rawInput") if isinstance(tc, dict) else None
    if not isinstance(raw, dict):
        return ""
    v = raw.get("command") or raw.get("cmd")
    if isinstance(v, list) and v and all(isinstance(x, str) for x in v):
        # Codex wraps a shell command as [bash, -lc, script]: the script is it.
        v = v[-1] if len(v) == 3 and v[1] in ("-c", "-lc") else " ".join(shlex.quote(x) for x in v)
    if not isinstance(v, str) or not v.strip():
        v = raw.get("file_path") or raw.get("path")
    if not isinstance(v, str):
        return ""
    return VIEW_CONTROL.sub("", v.replace("\t", "    ")).strip("\n")


def home_short(path):
    h = home_dir()
    if path == h:
        return "~"
    return "~" + path[len(h):] if path.startswith(h + "/") else path


class HerdrReport(object):
    """`view` in herdr's agent list (`pane report-agent`): only from inside a
    herdr pane, only on a change, never waited for. One command runs at a
    time; a state that changes while it runs replaces the one waiting to go
    (the ones in between are stale)."""

    def __init__(self, agent, resume):
        env = os.environ
        self.bin = env.get("HERDR_BIN_PATH")
        self.pane = env.get("HERDR_PANE_ID")
        self.on = env.get("HERDR_ENV") == "1" and bool(self.bin) and bool(self.pane)
        self.agent = agent
        self.resume = resume
        self.last = None
        self.want = None
        self.proc = None
        self.t0 = 0.0
        self.seq = 0

    def next_seq(self):
        # herdr ignores a report whose number is not above the last one it
        # took from this source, across restarts of `view` too: the clock.
        self.seq = max(int(time.time() * 1000000), self.seq + 1)
        return str(self.seq)

    def busy(self):
        return self.proc is not None or self.want is not None

    def set(self, state, sid):
        if not self.on or (state, sid) == self.last:
            return
        self.last = (state, sid)
        self.want = self.last
        self.poll()

    def poll(self):
        if self.proc is not None:
            if self.proc.poll() is None:
                if time.time() - self.t0 < HERDR_PROBE_TIMEOUT:
                    return
                self.stop()
            self.proc = None
        if self.want is None:
            return
        state, sid = self.want
        self.want = None
        argv = [
            self.bin, "pane", "report-agent", self.pane, "--source", HERDR_SOURCE, "--agent", self.agent,
            "--state", state, "--seq", self.next_seq(),
        ]
        if sid:
            argv += ["--agent-session-id", sid]
        if self.resume:
            argv += ["--"] + self.resume
        self.proc = self.spawn(argv)

    def spawn(self, argv):
        self.t0 = time.time()
        try:
            return subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                close_fds=True, start_new_session=True,
            )
        except (OSError, ValueError):
            return None

    def stop(self):
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except OSError:
            pass
        self.proc.wait()

    def settle(self):
        if self.proc is None:
            return
        try:
            self.proc.wait(timeout=HERDR_PROBE_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.stop()
        self.proc = None

    def release(self):
        """`view` leaves: the pane is no agent any more."""
        if not self.on or self.last is None:
            return
        self.settle()
        self.proc = self.spawn([
            self.bin, "pane", "release-agent", self.pane, "--source", HERDR_SOURCE, "--agent", self.agent,
            "--seq", self.next_seq(),
        ])
        self.settle()


class View(object):
    """`view ID`: the session in a terminal, the keeper's own client in the
    herdr pane it opens (Keeper.open_pane; docs/AGENT_SESSIONS.md, "Shared
    sessions"). It prints the conversation into the scrollback (thoughts left
    out, a finished tool call as one row), sends what is typed as a prompt,
    answers a waiting permission by its number, says that a question is
    answered on the phone, and reports the session's state to herdr. It
    answers no request the person did not pick.

    On a terminal ([tty]) it wraps rows itself and keeps a live area under the
    scrollback: the row of a message still streaming, a status row, and the
    input row, which it echoes itself so arriving output never splits what is
    being typed. Nothing above the live area is redrawn, so the terminal's own
    scroll and copy keep working. Elsewhere (a pipe) it writes plain lines: no
    colour, no live area, input read line by line."""

    def __init__(self, kid, tty=False):
        self.kid = kid
        self.tty = tty
        self.color = tty and not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"
        self.sock = None
        self.rbuf = b""
        self.ibuf = b""
        self.next_id = 0
        self.calls = {}
        self.sid = None
        self.loaded = False
        self.t0 = time.time()
        self.load_at = 0.0
        self.waited = False
        self.running = False
        self.mine = None
        self.mine_text = ""
        self.waiting = collections.OrderedDict()
        self.resolved = set()
        self.tools = collections.OrderedDict()  # calls not finished: id -> title
        self.tools_done = set()
        self.done = False
        # The screen. [cols]: the width rows are wrapped to (None: not wrapped).
        self.cols = None
        self.out = []
        self.live = 0  # rows the live area takes on the screen now
        self.dirty = False  # the live area changed
        self.block = None  # what was written last: you, agent, tool, card, note
        self.cur = None  # (chunk kind, messageId) of the message being written
        self.line = ""  # its last row, still growing (live on a terminal)
        self.first = True  # its next row is its first
        self.gap = False  # a blank row is owed before its next row
        # What is being typed (terminal only).
        self.input = ""
        self.esc = ""
        self.paste = False
        # The keeper's files are named relative to its folder; `run` leaves it
        # for the session's own, which herdr then shows as the pane's folder.
        self.dir = os.getcwd()
        info = read_info(kid) or {}
        title = info.get("title")
        self.title = title if isinstance(title, str) and title.strip() else None
        self.asked = None  # the first thing the person asked: a name until the agent gives one
        self.named = None  # the terminal title last set
        route = route_by_id(info.get("agent") or "") or {}
        resume = ["python3", SCRIPT, "view", kid] if view_runnable(SCRIPT) else None
        self.label = route.get("label") or info.get("agent") or "agent"
        self.cwd = info.get("cwd") or ""
        # Not the bare agent name: herdr knows `omp`, `codex` and `pi` as its
        # own agents, and its guide asks integrations not to use their names.
        self.herdr = HerdrReport(self.label + " \u00b7 phone", resume)

    # -- the terminal

    def style(self, name, text):
        if not self.color or not name or not text:
            return text
        return "\x1b[%sm%s\x1b[0m" % (VIEW_STYLE[name], text)

    def resize(self):
        try:
            cols = os.get_terminal_size(1).columns
        except OSError:
            cols = 80
        # One column spare: a row that fills the width leaves the cursor
        # waiting to wrap, and the live area's row count would be off by one.
        self.cols = max(VIEW_MIN_COLS, cols) - 1
        self.dirty = True
        if self.cur is not None and self.line:
            line, self.line = self.line, ""
            self.put_text(line, False)

    def width(self, lead):
        return None if self.cols is None else self.cols - lead

    def erase(self):
        """Clears the live area; the cursor is on its last row."""
        if self.live:
            self.out.append(("\x1b[%dA" % (self.live - 1) if self.live > 1 else "") + "\r\x1b[J")
            self.live = 0

    def emit(self, rows):
        """[rows] into the scrollback, above the live area."""
        self.erase()
        for r in rows:
            self.out.append(r + "\n")

    def record(self):
        """The keeper's record now ({} once it is gone)."""
        return read_info(os.path.join(self.dir, self.kid)) or {}

    def name(self):
        """What the terminal (and so herdr's pane row, on every computer) is
        titled: the session's title, else what was asked first, never the
        command that runs this."""
        return one_line(self.title or self.asked or "", 120) or "%s session" % self.label

    def flush(self):
        if self.tty and not self.done and self.name() != self.named:
            self.named = self.name()
            self.out.append("\x1b]0;%s\x07" % self.named)
        if self.tty and (self.out or self.dirty or (self.done and self.live)):
            self.erase()
            if not self.done:
                rows, back = self.live_rows()
                self.out.append("\n".join(rows))
                if back:
                    self.out.append("\r\x1b[%dC" % back)
                self.live = len(rows)
        self.dirty = False
        if not self.out:
            return
        data, self.out = "".join(self.out), []
        try:
            sys.stdout.buffer.write(data.encode("utf-8", "replace"))
            sys.stdout.flush()
        except OSError:
            self.done = True

    def live_rows(self):
        """(the live area's rows, the column to put the cursor back to or 0
        to leave it after the last row)."""
        rows = []
        if self.cur is not None and self.line:
            rows.append(self.text_row(self.line))
        rows.append("")  # the input is not part of the conversation above it
        status = self.status()
        if status:
            rows.append(status)
        mark = self.style("accent" if self.loaded else "dim", "\u203a") + " "
        if self.input:
            rows.append(mark + fit(self.input.replace("\n", "\u23ce "), self.cols - 2, tail=True))
            return rows, 0
        if not self.loaded:
            rows.append(mark)
            return rows, 0
        hint = "Message %s \u00b7 /cancel stops it \u00b7 /quit leaves" % self.label
        rows.append(mark + self.style("dim", fit(hint, self.cols - 2)))
        return rows, 2

    def status(self):
        """The status row: what the session does now, or None when it rests."""
        if not self.loaded:
            text = "Waiting for the phone to open the session" if self.waited else "Opening the session"
            return self.style("dim", fit("\u25cc " + text, self.cols))
        if self.waiting:
            n = len(self.waiting)
            what = "%d requests" % n if n > 1 else (
                "Question" if next(iter(self.waiting.values()))[0] == "elicitation/create" else "Permission")
            head = "\u25b2 Needs you"
            return self.style("warn", head) + self.style("dim", fit(" \u00b7 " + what, self.cols - len(head)))
        if self.running or self.mine is not None:
            head = "\u25d0 Working"
            tools = list(self.tools.values())
            rest = fit(" \u00b7 " + tools[-1], self.cols - len(head)) if tools else ""
            return self.style("accent", head) + self.style("dim", rest)
        return None

    def text_row(self, row):
        """A row of the message being written: the person's are marked and bold."""
        if self.cur[0] == "user":
            return (self.style("accent", "\u203a") + " " if self.first else "  ") + self.style("bold", row)
        return row

    def rows(self, text, style=None, head=None, head_style=None, indent=0):
        """[text] wrapped, each row indented by [indent] columns and the first
        led by [head] and a space, the rest lined up under it."""
        lead = indent + (text_width(head) + 1 if head else 0)
        out = []
        for line in text.split("\n"):
            for r in final_rows(line, self.width(lead)):
                if head and not out:
                    pad = " " * indent + self.style(head_style or style, head) + " "
                else:
                    pad = " " * lead
                out.append(pad + self.style(style, r))
        return out

    def start(self, kind):
        """Opens a block: a blank row between blocks, none between the rows of
        tool calls or of notes."""
        if self.block is not None and not (kind == self.block and kind in ("tool", "note")):
            self.emit([""])
        self.block = kind

    def say(self, text, style="dim", head=None, head_style=None):
        """[text] as a note of its own."""
        self.end_text()
        self.start("note")
        self.emit(self.rows(text, style, head, head_style))

    def end(self, reason):
        if reason is None:
            info = self.record()
            reason = info.get("exit_reason") if info.get("state") == "exited" else None
        reason = one_line(reason, 300).rstrip(". ") or "the keeper closed the connection"
        self.say("Session ended: %s." % reason, None, "\u25a0", "bad")
        self.done = True

    def put_row(self, row):
        """A finished row of the message being written. Blank rows are kept
        only between rows, one at most."""
        if not row.strip():
            if not self.first:
                self.gap = True
            return
        if self.gap:
            self.emit([""])
            self.gap = False
        self.emit([self.text_row(row)])
        self.first = False

    def put_text(self, text, final):
        """A line of the message being written: all its rows when [final],
        else all but the last, which stays live in [line]."""
        rows = wrap_rows(text, self.width(2 if self.cur[0] == "user" else 0))
        if final:
            if len(rows) > 1 and not rows[-1][1]:
                rows.pop()
        else:
            self.line = text[rows[-1][0]:]
            rows = rows[:-1]
        for _, r in rows:
            self.put_row(r)

    def end_text(self):
        if self.cur is None:
            return
        if self.line:
            line, self.line = self.line, ""
            self.put_text(line, True)
        self.cur = None
        self.gap = False
        self.dirty = True

    def keep(self, text):
        """[text], which was not sent, goes back to the input row."""
        if self.tty and not self.input:
            self.input = text
            self.dirty = True

    # -- the keeper

    def send(self, obj):
        try:
            self.sock.sendall(enc(obj))
        except OSError:
            self.end(None)

    def call(self, method, params, what):
        self.next_id += 1
        self.calls[self.next_id] = what
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        return self.next_id

    def try_load(self):
        """Loads the keeper's session once it has one (the phone opens it just
        after the start)."""
        self.load_at = 0.0
        info = self.record()
        if info.get("state") == "exited":
            self.end(info.get("exit_reason") or "the agent exited")
            return
        sid = info.get("session_id")
        if isinstance(sid, str) and sid:
            self.sid = sid
            self.call("session/load", {"sessionId": sid, "cwd": info.get("cwd") or "/", "mcpServers": []}, "load")
            return
        if not self.waited and time.time() - self.t0 >= 3:
            self.waited = True
            self.dirty = True
            if not self.tty:
                self.say("Waiting for the phone to open the session.")
        self.load_at = time.time() + (1.0 if self.waited else 0.5)

    def feed(self, data):
        self.rbuf += data
        lines = self.rbuf.split(b"\n")
        self.rbuf = lines.pop()
        for ln in lines:
            if self.done:
                return
            try:
                msg = json.loads(ln.decode("utf-8", "replace"))
            except ValueError:
                continue
            if not isinstance(msg, dict):
                continue
            method = msg.get("method")
            if isinstance(method, str):
                if "id" in msg:
                    self.on_request(msg)
                else:
                    p = msg.get("params")
                    self.on_notification(method, p if isinstance(p, dict) else {})
            elif "id" in msg:
                self.on_response(msg)

    def on_response(self, msg):
        what = self.calls.pop(msg.get("id"), None)
        err = msg.get("error")
        text = one_line(err.get("message") if isinstance(err, dict) else "") or "an error"
        if what == "init":
            if err is not None:
                self.end("the keeper refused this terminal (%s)" % text)
            else:
                self.try_load()
        elif what == "load":
            if err is not None:
                self.end("the session did not open (%s)" % text)
                return
            self.loaded = True
            self.dirty = True
            if not self.tty:
                self.say("Type a message and Enter to send it. /cancel stops the agent, /quit leaves.")
        elif what == "prompt":
            self.mine = None
            sent, self.mine_text = self.mine_text, ""
            if isinstance(err, dict) and err.get("code") == SESSION_BUSY:
                self.say("The agent is busy; not sent.", None, "\u2717", "bad")
                self.keep(sent)
            elif err is not None:
                self.say("Not sent: %s." % text.rstrip("."), None, "\u2717", "bad")
                self.keep(sent)
            else:
                res = msg.get("result")
                self.turn_end(res.get("stopReason") if isinstance(res, dict) else None)

    def on_notification(self, method, p):
        if method == "session/update":
            u = p.get("update")
            if p.get("sessionId") == self.sid and isinstance(u, dict):
                self.on_update(u)
        elif method == "_herdr/resolved":
            kid = p.get("requestId")
            if isinstance(kid, str):
                self.resolved.add(kid)
            self.say("Answered in %s: %s." % (one_line(p.get("by")) or "another client", one_line(p.get("answer")) or "?"),
                     "dim", "\u2713", "ok")
        elif method == "$/cancel_request":
            kid = p.get("requestId")
            if isinstance(kid, str) and self.waiting.pop(kid, None) is not None and kid not in self.resolved:
                self.say("The agent withdrew its request.")
            self.dirty = True
        elif method == "_herdr/agent_exited":
            self.end(p.get("reason") or "the agent exited")

    def on_update(self, u):
        kind = u.get("sessionUpdate")
        if kind == "agent_message_chunk":
            self.chunk("agent", u)
        elif kind == "user_message_chunk":
            self.chunk("user", u)
        elif kind in ("tool_call", "tool_call_update"):
            self.tool(u)
        elif kind == "state_update":
            if u.get("state") == "running":
                self.running = True
                self.dirty = True
            elif u.get("state") == "idle":
                self.turn_end(u.get("stopReason"))
        elif kind == "session_info_update" and "title" in u:
            t = u.get("title")
            self.title = t if isinstance(t, str) and t.strip() else None

    def chunk(self, kind, u):
        c = u.get("content")
        if not isinstance(c, dict):
            return
        text = c.get("text") if c.get("type") == "text" else None
        text = VIEW_CONTROL.sub("", text) if isinstance(text, str) else "[%s]" % one_line(c.get("type"), 40)
        key = (kind, u.get("messageId"))
        if key != self.cur:
            self.end_text()
            self.start("you" if kind == "user" else "agent")
            self.cur = key
            self.first = True
        if kind == "user" and self.asked is None and text.strip():
            self.asked = text
        parts = (self.line + text.replace("\t", "    ")).split("\n")
        self.line = ""
        for part in parts[:-1]:
            self.put_text(part, True)
        self.put_text(parts[-1], False)
        self.dirty = True

    def tool(self, u):
        """A call shows as one row when it finishes (the status row names it
        while it runs): the scrollback is never rewritten."""
        tid = u.get("toolCallId")
        if not isinstance(tid, str) or tid in self.tools_done:
            return
        title = one_line(u.get("title"), 300)
        if tid not in self.tools:
            self.end_text()
            self.tools[tid] = title or one_line(u.get("kind")) or "tool"
        elif title:
            self.tools[tid] = title
        status = u.get("status")
        if status in ("completed", "failed"):
            self.tools_done.add(tid)
            title = self.tools.pop(tid)
            if status == "completed":
                self.tool_row(title, "dim", "\u2713", "ok")
            else:
                self.tool_row(title + " \u00b7 failed", None, "\u2717", "bad")
        self.dirty = True

    def tool_row(self, text, style, head, head_style):
        self.end_text()
        self.start("tool")
        self.emit(self.rows(text, style, head, head_style))

    def turn_end(self, stop):
        self.running = False
        self.end_text()
        # A call the turn ended without: said once, and a late word on it is
        # not news.
        for tid, title in self.tools.items():
            self.tools_done.add(tid)
            self.tool_row(title + " \u00b7 no result", "dim", "\u25cc", "dim")
        self.tools.clear()
        if isinstance(stop, str) and stop and stop != "end_turn":
            self.say("Turn ended: %s." % one_line(stop.replace("_", " "), 60))
        self.dirty = True

    def on_request(self, msg):
        method, kid = msg["method"], msg["id"]
        p = msg.get("params")
        if method in HELD and isinstance(kid, str) and isinstance(p, dict):
            if kid in self.waiting:
                return
            self.waiting[kid] = (method, p)
            self.end_text()
            self.start("card")
            self.dirty = True
            if method == "elicitation/create":
                rows = self.rows("Question \u00b7 " + (one_line(p.get("message"), 300) or "(no text)"), "bold", "\u25b2", "warn")
                rows += self.rows("Answer this on the phone.", "dim", indent=2)
                self.emit(rows)
                return
            tc = p.get("toolCall") if isinstance(p.get("toolCall"), dict) else {}
            title = one_line(tc.get("title"), 300) or one_line(tc.get("kind")) or "(no title)"
            rows = self.rows("Permission \u00b7 " + title, "bold", "\u25b2", "warn")
            command = call_command(tc)
            if command and command not in title:
                rows += self.rows(command, None, indent=2)
            for i, o in enumerate(permission_options(p), 1):
                rows += self.rows(one_line(o.get("name")) or one_line(o["optionId"]), None, str(i), "bold", indent=2)
            if len(self.permissions()) == 1:
                rows += self.rows("Type a number and Enter to answer.", "dim", indent=2)
            else:
                rows += self.rows("More than one request waits: answer them on the phone.", "dim", indent=2)
            self.emit(rows)
            return
        self.send({"jsonrpc": "2.0", "id": kid, "error": {"code": -32601, "message": "A terminal view does not answer %s." % method}})

    def permissions(self):
        return [(k, w[1]) for k, w in self.waiting.items() if w[0] == "session/request_permission"]

    # -- the person

    def on_line(self, text):
        text = text.strip()
        if not text:
            return
        self.dirty = True
        if text == "/quit":
            self.done = True
            return
        if text == "/cancel":
            if self.sid:
                self.send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": self.sid}})
                self.say("Asked the agent to stop.")
            return
        perms = self.permissions()
        if VIEW_NUMBER.match(text) and len(perms) == 1:
            kid, p = perms[0]
            options = permission_options(p)
            n = int(text)
            if not 1 <= n <= len(options):
                self.say("There is no option %d." % n, None, "\u2717", "bad")
                return
            o = options[n - 1]
            self.send({"jsonrpc": "2.0", "id": kid, "result": {"outcome": {"outcome": "selected", "optionId": o["optionId"]}}})
            del self.waiting[kid]
            self.say("Answered: %s." % (one_line(o.get("name")) or o["optionId"]), "dim", "\u2713", "ok")
            return
        if not self.loaded:
            self.say("The session is not open yet; not sent.", None, "\u2717", "bad")
            self.keep(text)
            return
        # The keeper shows a prompt to the other clients; its sender shows its own.
        self.end_text()
        self.start("you")
        self.emit(self.rows(text, "bold", "\u203a", "accent"))
        self.mine_text = text
        if self.asked is None:
            self.asked = text
        self.mine = self.call("session/prompt", {"sessionId": self.sid, "prompt": [{"type": "text", "text": text}]}, "prompt")

    def keys(self, s):
        """What was typed on a terminal (decoded): edits the input row; Enter
        sends it. Inside a bracketed paste, a newline is part of the message."""
        s, self.esc = self.esc + s, ""
        i, n = 0, len(s)
        while i < n and not self.done:
            c = s[i]
            i += 1
            self.dirty = True
            if c == "\x1b":
                if i >= n:
                    self.esc = c  # the rest of the sequence comes with the next read
                    break
                if s[i] not in "[O":
                    continue  # a lone Esc, or Alt with the key that follows
                j = i + 1
                if s[i] == "[":
                    while j < n and not ("\x40" <= s[j] <= "\x7e"):
                        j += 1
                if j >= n:
                    self.esc = s[i - 1:]
                    break
                seq = s[i + 1:j + 1]
                if seq == "200~":
                    self.paste = True
                elif seq == "201~":
                    self.paste = False
                i = j + 1  # arrows and other keys: not used
            elif self.paste:
                if c == "\r" and i < n and s[i] == "\n":
                    continue
                if c in "\r\n":
                    self.input += "\n"
                elif c == "\t":
                    self.input += "    "
                elif c >= " " and not "\x7f" <= c <= "\x9f":
                    self.input += c
            elif c in "\r\n":
                text, self.input = self.input, ""
                self.on_line(text)
            elif c in "\x7f\x08":
                self.input = self.input[:-1]
            elif c == "\x15":  # Ctrl-U
                self.input = ""
            elif c == "\x17":  # Ctrl-W
                self.input = re.sub(r"\S*\s*$", "", self.input)
            elif c == "\x03":  # Ctrl-C: clears what is typed, else leaves
                if self.input:
                    self.input = ""
                else:
                    self.done = True
            elif c == "\x04":  # Ctrl-D on an empty row leaves
                if not self.input:
                    self.done = True
            elif c == "\t":
                self.input += "    "
            elif c >= " " and not "\x7f" <= c <= "\x9f":
                self.input += c

    def report(self):
        if not self.loaded:
            return
        if self.waiting:
            state = "blocked"
        elif self.running or self.mine is not None:
            state = "working"
        else:
            state = "idle"
        self.herdr.set(state, self.sid)

    def run(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(self.kid + ".sock")
        except OSError:
            s.close()
            self.end(None)
            self.flush()
            return
        self.sock = s
        try:
            os.chdir(self.cwd)
        except OSError:
            pass  # the folder is gone: the keeper's still works
        meta = {"viewer": True}
        if os.environ.get("HERDR_PANE_ID"):
            meta["pane"] = os.environ["HERDR_PANE_ID"]
        self.call("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {},
            "clientInfo": {"name": VIEW_CLIENT, "title": "Terminal on " + short_host(), "version": "1"},
            "_meta": {"herdr": meta},
        }, "init")
        saved = wake = decoder = None
        if self.tty:
            # The terminal stops echoing and editing: the input row does both,
            # and Ctrl-C and Ctrl-D are keys. A resize wakes the loop.
            saved = termios.tcgetattr(0)
            mode = termios.tcgetattr(0)
            mode[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG | termios.IEXTEN)
            mode[6][termios.VMIN] = 1
            mode[6][termios.VTIME] = 0
            termios.tcsetattr(0, termios.TCSADRAIN, mode)
            wake, poke = os.pipe()
            os.set_blocking(wake, False)
            os.set_blocking(poke, False)

            def on_winch(signum, frame):
                try:
                    os.write(poke, b"!")
                except OSError:
                    pass
            signal.signal(signal.SIGWINCH, on_winch)
            decoder = codecs.getincrementaldecoder("utf-8")("replace")
            self.out.append("\x1b[?2004h")  # bracketed paste
            self.resize()
        # Which session this is, above everything the session shows.
        self.start("note")
        where = home_short(self.cwd)
        head = self.style("bold", self.label)
        if where:
            head += self.style("dim", fit(" \u00b7 " + where, (self.cols or 10 ** 6) - text_width(self.label)))
        self.emit([head])
        stdin_open = True
        try:
            while not self.done:
                self.flush()
                if self.done:
                    break
                fds = [s] + ([0] if stdin_open else []) + ([wake] if wake is not None else [])
                timeout = 0.2 if (self.load_at or self.herdr.busy()) else None
                ready, _, _ = select.select(fds, [], [], timeout)
                if wake is not None and wake in ready:
                    try:
                        os.read(wake, 4096)
                    except OSError:
                        pass
                    self.resize()
                if s in ready:
                    try:
                        data = s.recv(262144)
                    except OSError:
                        data = b""
                    if not data:
                        self.end(None)
                        break
                    self.feed(data)
                if 0 in ready and not self.done:
                    data = os.read(0, 65536)
                    if not data:
                        # stdin closed (Ctrl-D): leave the session running.
                        stdin_open = False
                        self.done = True
                    elif decoder is not None:
                        self.keys(decoder.decode(data))
                    else:
                        self.ibuf += data
                        lines = self.ibuf.split(b"\n")
                        self.ibuf = lines.pop()
                        for ln in lines:
                            if not self.done:
                                self.on_line(ln.decode("utf-8", "replace"))
                if self.load_at and time.time() >= self.load_at and not self.done:
                    self.try_load()
                self.report()
                self.herdr.poll()
        except KeyboardInterrupt:
            pass
        finally:
            self.done = True
            self.flush()
            if saved is not None:
                try:
                    # The bracketed paste off, and the title back to the shell's.
                    sys.stdout.buffer.write(b"\x1b[?2004l\x1b]0;\x07")
                    sys.stdout.flush()
                except OSError:
                    pass
                try:
                    termios.tcsetattr(0, termios.TCSADRAIN, saved)
                except (termios.error, OSError):
                    pass  # the terminal is gone (the pane closed)
            s.close()
            self.herdr.release()


def cmd_view(kid):
    global codecs, shlex, termios, unicodedata
    import codecs
    import shlex
    import unicodedata
    check_id(kid)
    os.chdir(state_dir())
    if read_info(kid) is None:
        fail(EX_GONE, "no such keeper: " + kid)
    # A closed pane (SIGHUP) or a kill still tells herdr the agent left.
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))
    tty = os.isatty(0) and os.isatty(1)
    if tty:
        import termios
    View(kid, tty).run()


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
        fail(EX_USAGE, "usage: probe | list | start --agent ID --cwd DIR | attach ID [--z] | kill ID | view ID | follow PATH [--z] [--from N] [--poll-ms N] [--idle-exit S] [--tail-bytes N] | history AGENT [CWD]")
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
        elif cmd == "view" and len(rest) == 1:
            cmd_view(rest[0])
        elif cmd == "daemon" and len(rest) == 4 and rest[0] == "--agent" and rest[2] == "--cwd":
            cmd_daemon(rest[1], rest[3])
        else:
            fail(EX_USAGE, "unknown command: " + cmd)
    except OSError as e:
        fail(EX_FAILED, "%s: %s" % (cmd, e))


if __name__ == "__main__":
    main(sys.argv[1:])
''';
