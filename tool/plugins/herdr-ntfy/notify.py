#!/usr/bin/env python3
"""herdr-ntfy: decide whether a pane.agent_status_changed event deserves a push.

`notify.py plan` reads HERDR_PLUGIN_EVENT_JSON, updates the dedupe state and
prints a curl config (for `curl -K -`) on stdout when a notification is due.
It prints nothing when there is nothing to send. notify.sh does the POST.

Python 3.6+ standard library only. Never raises: any error is logged to the
plugin state dir and the process exits 0 so herdr is never held up.
"""

import base64
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import time
import traceback
from urllib.parse import quote, urlsplit

WANTED = ("blocked", "done")
DEFAULT_COOLDOWN = 30
STATE_TTL = 7 * 24 * 3600
LOG_LIMIT = 64 * 1024
QUESTION_MAX = 140
MIN_PUBLIC_TOPIC = 16
TOPIC_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_NAME = r"[\w.-]*(?:token|secret|passw(?:or)?d|key|credential)[\w.-]*"
# Applied in order. Credentials in a question line end up on a lock screen and
# on ntfy's server, so each shape below is replaced, not just flagged.
REDACTIONS = [
    # Authorization: Bearer x / Basic x / Token x, then a bare "Bearer x".
    (re.compile(r"(?i)\b(authorization)(\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s,;\"']+"),
     r"\1\2***"),
    (re.compile(r"(?i)\b(bearer)\s+[^\s,;\"']+"), r"\1 ***"),
    # NAME=value / NAME: value where the name holds a credential word
    # (DB_PASSWORD=, AWS_SECRET_ACCESS_KEY=, --api-key=, token: ...).
    (re.compile(r"(?i)(%s)(\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)" % _NAME), r"\1\2***"),
    # --flag value
    (re.compile(r"(?i)((?<!\w)--?%s)(\s+)(?!-)[^\s,;]+" % _NAME), r"\1\2***"),
    # scheme://user:password@host
    (re.compile(r"(?i)([a-z][a-z0-9+.-]*://)[^\s/@]+@"), r"\1***@"),
    # webhook URLs carry the secret in the path
    (re.compile(r"(?i)(https?://hooks\.slack\.com/)\S+"), r"\1***"),
    (re.compile(r"(?i)(https?://(?:discord(?:app)?\.com)/api/webhooks/)\S+"), r"\1***"),
    # well-known token shapes
    (re.compile(r"\bsk[-_][A-Za-z0-9_-]{8,}"), "***"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}"), "***"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "***"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{8,}"), "***"),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{12,}"), "***"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{20,}"), "***"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"), "***"),
    # long hex (hashes, keys) and long mixed identifiers with a digit
    (re.compile(r"\b[0-9A-Fa-f]{32,}\b"), "***"),
    (re.compile(r"(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}"), "***"),
]
# base64 keeps "+" and "/", which paths also have: see _blob.
BASE64_RE = re.compile(
    r"(?=[A-Za-z0-9+/]*\d)(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])[A-Za-z0-9+/]{32,}={0,2}"
)
BORDER = " \t\u2502\u2503|\u256d\u256e\u2570\u256f\u2500\u2501>\u276f\u203a*"


def state_dir():
    path = os.environ.get("HERDR_PLUGIN_STATE_DIR")
    if not path:
        base = os.environ.get("XDG_STATE_HOME") or os.path.join(
            os.path.expanduser("~"), ".local", "state"
        )
        path = os.path.join(base, "herdr-ntfy")
    os.makedirs(path, exist_ok=True)
    return path


def log(message):
    """Append to ntfy.log in the state dir; keep the tail when it grows."""
    try:
        path = os.path.join(state_dir(), "ntfy.log")
        try:
            if os.path.getsize(path) > LOG_LIMIT:
                with open(path, "rb") as handle:
                    handle.seek(-LOG_LIMIT // 2, os.SEEK_END)
                    tail = handle.read()
                with open(path, "wb") as handle:
                    handle.write(tail[tail.find(b"\n") + 1:])
        except OSError:
            pass
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("%s %s\n" % (stamp, message))
    except Exception:
        pass


def cooldown_seconds():
    raw = os.environ.get("NOTIFY_COOLDOWN", "").strip()
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_COOLDOWN
    return max(0, value)


def pane_file(directory, pane_id):
    # Pane ids look like "wD:p1"; keep the file name boring.
    return os.path.join(directory, re.sub(r"[^A-Za-z0-9_.-]", "_", pane_id) + ".json")


def prune(directory, now):
    try:
        for entry in os.scandir(directory):
            if entry.name.endswith(".json") and now - entry.stat().st_mtime > STATE_TTL:
                os.unlink(entry.path)
    except OSError:
        pass


def _locked_pane(pane_id):
    """(lock file, state path) for a pane, with the lock held until the file closes.

    herdr starts one hook process per event and bursts of events for one pane
    overlap, so every read-modify-write of the state happens under this lock.
    """
    root = state_dir()
    panes = os.path.join(root, "panes")
    os.makedirs(panes, exist_ok=True)
    lock = open(os.path.join(root, "lock"), "a+")
    fcntl.flock(lock, fcntl.LOCK_EX)
    return lock, panes, pane_file(panes, pane_id)


def _load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            saved = json.load(handle)
        return saved if isinstance(saved, dict) else {}
    except (OSError, ValueError):
        return {}


def _store(path, saved):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(saved, handle)
    os.replace(tmp, path)


def record_status(pane_id, status, now, claim=True):
    """Remember `status` for the pane; return why not to notify, or None.

    With `claim`, a None answer also marks the alert as taken: racing events
    see it and stay quiet, and the cooldown starts. If the POST then fails,
    release_claim() gives the state back so the next event can try again.
    """
    lock, panes, path = _locked_pane(pane_id)
    with lock:
        prune(panes, now)
        saved = _load(path)
        previous = saved.get("seen")
        sent = saved.get("sent") if isinstance(saved.get("sent"), dict) else {}
        saved["seen"] = status
        reason = None
        if status not in WANTED:
            reason = "status %s is not alertable" % status
        elif previous == status:
            reason = "already %s" % status
        elif status == "done" and os.environ.get("NOTIFY_DONE", "").strip() != "1":
            reason = "NOTIFY_DONE is not 1"
        else:
            last = sent.get(status)
            if isinstance(last, (int, float)) and 0 <= now - last < cooldown_seconds():
                reason = "cooldown (%ds left)" % (cooldown_seconds() - (now - last))
        if reason is None and claim:
            sent[status] = now
            saved["prev_seen"] = previous
        saved["sent"] = sent
        _store(path, saved)
    return reason


def release_claim(pane_id, status):
    """The alert claimed by record_status() was not delivered.

    The pane goes back to what it was before, so the next event for the same
    state is a transition again. The claim time stays: it is the cooldown, so a
    server that is down is tried once per cooldown, not once per event.
    """
    lock, _, path = _locked_pane(pane_id)
    with lock:
        saved = _load(path)
        if saved.get("seen") != status:
            return  # the pane moved on; a later event owns the state
        previous = saved.pop("prev_seen", None)
        if previous is None:
            saved.pop("seen", None)
        else:
            saved["seen"] = previous
        _store(path, saved)
        log("post failed for %s %s: will try again on the next event" % (pane_id, status))


def _blob(match):
    """A base64-looking run is a secret, unless it is shaped like a path."""
    text = match.group(0)
    return text if text.count("/") * 10 > len(text) else "***"


def redact(text):
    """Best effort: replace anything that looks like a credential with ***.

    Errs toward redacting; an ordinary question has none of these shapes.
    """
    for pattern, replacement in REDACTIONS:
        text = pattern.sub(replacement, text)
    return BASE64_RE.sub(_blob, text)


def log_once(key, message):
    """Log `message` unless this `key` was already logged since the last good run."""
    try:
        marker = os.path.join(state_dir(), "once-" + re.sub(r"[^A-Za-z0-9_-]", "_", key))
        if os.path.exists(marker):
            return
        open(marker, "w").close()
    except OSError:
        pass
    log(message)


def clear_once():
    try:
        for entry in os.scandir(state_dir()):
            if entry.name.startswith("once-"):
                os.unlink(entry.path)
    except OSError:
        pass


def question_line(pane_id):
    """The last question on the pane's screen, or '' when none is cheap to find."""
    herdr = os.environ.get("HERDR_BIN_PATH") or "herdr"
    try:
        out = subprocess.run(
            [herdr, "pane", "read", pane_id, "--source", "visible", "--lines", "40"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        ).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""
    for raw in reversed(out.splitlines()):
        line = raw.strip(BORDER).strip()
        if line.endswith("?") and len(line) > 3:
            line = redact(line)
            if len(line) > QUESTION_MAX:
                line = line[: QUESTION_MAX - 1].rstrip() + "\u2026"
            return line
    return ""


def named(label):
    text = str(label or "").strip()
    return "" if not text or text.isdigit() else text


def agent_name(data, context):
    raw = data.get("display_agent") or data.get("agent") or context.get("focused_pane_agent")
    name = str(raw or "").strip() or "agent"
    return name[:1].upper() + name[1:] if name.islower() else name


def header_value(text):
    """HTTP header text; RFC 2047 when it is not plain ASCII (ntfy decodes it)."""
    text = " ".join(text.split())
    try:
        text.encode("ascii")
        return text
    except UnicodeEncodeError:
        return "=?UTF-8?B?%s?=" % base64.b64encode(text.encode("utf-8")).decode("ascii")


def curl_quote(text):
    out = text.replace("\\", "\\\\").replace('"', '\\"')
    return out.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")


class ConfigError(Exception):
    """The .env cannot produce a notification. `key` names the problem for log_once."""

    def __init__(self, key, message):
        super().__init__(message)
        self.key = key
        self.message = message


def load_config():
    base = (os.environ.get("NTFY_URL") or "https://ntfy.sh").strip().rstrip("/")
    topic = (os.environ.get("NTFY_TOPIC") or "").strip()
    token = (os.environ.get("NTFY_TOKEN") or "").strip()
    machine = (os.environ.get("MACHINE") or "").strip() or socket.gethostname()
    if not TOPIC_RE.match(topic):
        raise ConfigError("topic", "NTFY_TOPIC must be 1-64 characters of A-Z a-z 0-9 _ -")
    if not re.match(r"^https?://[^\s\"]+$", base):
        raise ConfigError("url", "NTFY_URL must be an http(s) URL")
    if token and not re.match(r"^[A-Za-z0-9_.~+/=-]+$", token):
        raise ConfigError("token", "NTFY_TOKEN has unexpected characters")
    public = (urlsplit(base).hostname or "").lower() == "ntfy.sh"
    if public and not token and len(topic) < MIN_PUBLIC_TOPIC:
        raise ConfigError(
            "weak-topic",
            "NTFY_TOPIC is only %d characters. On the public ntfy.sh the topic is the only "
            "secret: use at least %d random characters, or set NTFY_TOKEN, or point NTFY_URL "
            "at your own server. Nothing is sent until then." % (len(topic), MIN_PUBLIC_TOPIC),
        )
    return {"base": base, "topic": topic, "token": token, "machine": machine}


def build_request(config, data, context, status, pane_id):
    machine = config["machine"]
    agent = agent_name(data, context)
    workspace = named(context.get("workspace_label"))
    tab = named(context.get("tab_label"))
    project = workspace or named(data.get("title")) or str(data.get("workspace_id") or "")
    if workspace and tab:
        project = "%s \u00b7 %s" % (workspace, tab)
    lines = [redact(project), "on %s" % machine]
    if status == "blocked":
        question = question_line(pane_id)
        if question:
            lines.append(question)
    body = "\n".join(line for line in lines if line)

    blocked = status == "blocked"
    title = "%s needs you" % agent if blocked else "%s finished" % agent
    click = "herdr://agent/%s/%s" % (quote(machine, safe=""), quote(pane_id, safe=""))

    config_lines = [
        'url = "%s"' % curl_quote("%s/%s" % (config["base"], config["topic"])),
        'header = "Title: %s"' % curl_quote(header_value(title)),
        'header = "Priority: %s"' % ("high" if blocked else "default"),
        'header = "Tags: %s"' % ("warning" if blocked else "white_check_mark"),
        'header = "Click: %s"' % curl_quote(click),
    ]
    if config["token"]:
        config_lines.append('header = "Authorization: Bearer %s"' % curl_quote(config["token"]))
    # data-raw, never data-binary/data: those read a file when the body starts
    # with "@", and the body begins with a workspace title any program can set.
    config_lines.append('data-raw = "%s"' % curl_quote(body))
    return "\n".join(config_lines) + "\n"


def read_event():
    """(event data, pane id, status) from HERDR_PLUGIN_EVENT_JSON, or None."""
    try:
        data = json.loads(os.environ.get("HERDR_PLUGIN_EVENT_JSON", ""))["data"]
        return data, str(data["pane_id"]), str(data["agent_status"]).lower()
    except (ValueError, KeyError, TypeError):
        return None


def plan():
    event = read_event()
    if event is None:
        log("ignored: HERDR_PLUGIN_EVENT_JSON is missing or has no pane_id/agent_status")
        return ""
    data, pane_id, status = event
    try:
        context = json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or "{}")
        if not isinstance(context, dict):
            context = {}
    except ValueError:
        context = {}

    config = problem = None
    try:
        config = load_config()
    except ConfigError as error:
        problem = error
    # Even with a broken config the pane's state is tracked, so fixing the
    # config does not suppress the next real transition.
    reason = record_status(pane_id, status, time.time(), claim=problem is None)
    if reason:
        log("skip %s %s: %s" % (pane_id, status, reason))
        return ""
    if problem is not None:
        log_once(problem.key, "not sent: " + problem.message)
        return ""
    clear_once()
    log("notify %s %s" % (pane_id, status))
    return build_request(config, data, context, status, pane_id)


def failed():
    """The POST for this event did not go through: let the next event try again."""
    event = read_event()
    if event is None:
        return
    _, pane_id, status = event
    release_claim(pane_id, status)


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "plan":
        try:
            sys.stdout.buffer.write(plan().encode("utf-8", "replace"))
        except Exception:
            detail = traceback.format_exc().strip()
            sys.stderr.write(detail + "\n")
            log("error: " + detail.replace("\n", " | "))
    elif command == "failed":
        try:
            failed()
        except Exception:
            log("error: " + traceback.format_exc().strip().replace("\n", " | "))
    elif command == "log":
        log(" ".join(argv[2:]))
    elif command == "log-once" and len(argv) > 2:
        log_once(argv[2], " ".join(argv[3:]))
    else:
        sys.stderr.write("usage: notify.py plan | failed | log MESSAGE | log-once KEY MESSAGE\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
