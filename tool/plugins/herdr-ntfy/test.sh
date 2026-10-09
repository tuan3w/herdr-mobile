#!/usr/bin/env bash
# Tests for the herdr-ntfy plugin. Needs bash, python3, curl.
#
# Part 1 feeds notify.sh sample pane.agent_status_changed payloads (shaped like
# herdr's src/api/schema/events.rs) and captures the POST with a local
# listener. Part 2 drives a real herdr, fully isolated (own socket, config dir,
# HOME and runtime dir under a temp dir), and is skipped when `herdr` is not on
# PATH. Nothing here talks to a running herdr of yours or to the internet.
#
#   tool/plugins/herdr-ntfy/test.sh

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pass=0
failed=0
W=$(mktemp -d /tmp/hn.XXXXXX) || exit 1
listener_pid=
server_pid=

cleanup() {
  [ -z "$server_pid" ] || { iso herdr server stop >/dev/null 2>&1; sleep 0.3; kill "$server_pid" 2>/dev/null; }
  [ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

check() { # description, then a command
  local what=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $what"
  fi
}
eq() { [ "$1" = "$2" ] || { echo "  expected: $2"; echo "  actual:   $1"; return 1; }; }
has() { case $1 in *"$2"*) ;; *) echo "  missing: $2"; echo "  in: $1"; return 1 ;; esac; }
lacks() { case $1 in *"$2"*) echo "  should not contain: $2"; echo "  in: $1"; return 1 ;; esac; }

# --- the fake ntfy server ----------------------------------------------------

cat >"$W/listen.py" <<'PY'
import http.server, json, os, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8")
        failing = os.path.exists(out + ".fail")
        with open(out + (".failed" if failing else ""), "a") as f:
            f.write(json.dumps({"path": self.path, "h": dict(self.headers), "body": body}) + "\n")
        self.send_response(500 if failing else 200)
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
: >"$W/posts.jsonl"
python3 "$W/listen.py" "$W/posts.jsonl" >"$W/port" &
listener_pid=$!
for _ in $(seq 50); do [ -s "$W/port" ] && break; sleep 0.1; done
PORT=$(cat "$W/port")
[ -n "$PORT" ] || { echo "listener did not start"; exit 1; }
# A port nothing listens on.
DEAD_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

# --- helpers over the capture file -------------------------------------------

count() { python3 -c '
import json, sys
print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["path"] == "/" + sys.argv[2]))' "$W/posts.jsonl" "$1"; }
field() { python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows = [r for r in rows if r["path"] == "/" + sys.argv[2]]
row = rows[int(sys.argv[3])]
key = sys.argv[4]
print(row["body"] if key == "body" else row["h"].get(key, "<none>"), end="")' "$W/posts.jsonl" "$@"; }
wait_for() { # topic count seconds
  local i
  for i in $(seq $(($3 * 10))); do
    [ "$(count "$1")" -ge "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

event() { # pane status [agent-key=value ...] -> HERDR_PLUGIN_EVENT_JSON
  python3 - "$@" <<'PY'
import json, sys
pane, status, *extra = sys.argv[1:]
data = {"type": "pane_agent_status_changed", "pane_id": pane,
        "workspace_id": pane.split(":")[0], "agent_status": status, "agent": "claude"}
for item in extra:
    k, v = item.split("=", 1)
    data[k] = v
print(json.dumps({"event": "pane_agent_status_changed", "data": data}))
PY
}

CASE=0
new_case() { # [extra .env lines...]; sets TOPIC, CFG, STATE
  CASE=$((CASE + 1))
  TOPIC=t$CASE
  CFG=$W/c$CASE/cfg
  STATE=$W/c$CASE/state
  mkdir -p "$CFG" "$STATE" "$W/home"
  {
    # Extras first: the first assignment of a key wins.
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'NTFY_URL=http://127.0.0.1:%s\n' "$PORT"
    printf 'NTFY_TOPIC=%s\n' "$TOPIC"
    printf 'MACHINE=Test Box\n'
  } >"$CFG/.env"
}

# Runs the hook like herdr would: a clean environment plus the plugin variables.
hook() { # event-json [VAR=value ...]
  local json=$1
  shift
  env -i PATH="$PATH" HOME="$W/home" \
    HERDR_PLUGIN_CONFIG_DIR="$CFG" HERDR_PLUGIN_STATE_DIR="$STATE" \
    HERDR_BIN_PATH="$W/bin/herdr" FAKE_SCREEN="$W/screen" FAKE_LIVE="$W/live" \
    HERDR_PLUGIN_EVENT=pane.agent_status_changed HERDR_PLUGIN_EVENT_JSON="$json" \
    HERDR_PLUGIN_CONTEXT_JSON='{"workspace_label":"myproj","tab_label":"1","focused_pane_agent":"claude"}' \
    "$@" bash "$here/notify.sh"
}
send() { hook "$(event "$1" "$2")"; } # pane status
logtext() { cat "$STATE/ntfy.log" 2>/dev/null; }

mkdir -p "$W/bin"
cat >"$W/bin/herdr" <<'SH'
#!/bin/sh
# stands in for `herdr pane read`, and for `herdr pane get` when $FAKE_LIVE/<pane>
# holds the status herdr should report ("gone": a pane herdr does not know)
[ -z "${FAKE_HANG:-}" ] || sleep 20
[ "$1 $2" = "pane read" ] && cat "$FAKE_SCREEN" 2>/dev/null
if [ "$1 $2" = "pane get" ] && [ -r "$FAKE_LIVE/$3" ]; then
  live=$(cat "$FAKE_LIVE/$3")
  if [ "$live" = gone ]; then
    echo '{"error":{"code":"pane_not_found","message":"pane not found"},"id":"cli:pane:get"}'
  else
    printf '{"id":"cli:pane:get","result":{"pane":{"agent_status":"%s","pane_id":"%s"}}}\n' "$live" "$3"
  fi
fi
exit 0
SH
chmod +x "$W/bin/herdr"
mkdir -p "$W/live"
: >"$W/screen"

# --- part 1: the script ------------------------------------------------------

echo "== blocked"
new_case
send 'wD:p1' blocked
check "exit 0" eq "$?" 0
check "one post" eq "$(count $TOPIC)" 1
check "title" eq "$(field $TOPIC 0 Title)" "Claude needs you"
check "priority high" eq "$(field $TOPIC 0 Priority)" high
check "tags" eq "$(field $TOPIC 0 Tags)" warning
check "click deep link, percent-encoded" eq "$(field $TOPIC 0 Click)" 'herdr://agent/Test%20Box/wD%3Ap1'
check "body has project and machine" eq "$(field $TOPIC 0 body)" $'myproj\non Test Box'
check "no auth header without a token" eq "$(field $TOPIC 0 Authorization)" '<none>'

echo "== dedupe and cooldown"
new_case 'NOTIFY_COOLDOWN=3'
send 'wD:p1' blocked
check "first block alerts" eq "$(count $TOPIC)" 1
send 'wD:p1' blocked
check "same pane, same state: no repeat" eq "$(count $TOPIC)" 1
send 'wD:p1' working
send 'wD:p1' blocked
check "blocked again inside the cooldown: held back, not lost" eq "$(count $TOPIC)" 1
check "the hold-back and its re-check are logged" has "$(logtext)" 're-check wD:p1 blocked'
send 'wD:p2' blocked
check "another pane is independent" eq "$(count $TOPIC)" 2
check "second pane in the link" eq "$(field $TOPIC 1 Click)" 'herdr://agent/Test%20Box/wD%3Ap2'
check "the held-back alert goes out when the cooldown ends, the pane being still blocked" wait_for $TOPIC 3 10
check "it is for the pane that was held back" eq "$(field $TOPIC 2 Click)" 'herdr://agent/Test%20Box/wD%3Ap1'
sleep 1
check "and goes out once" eq "$(count $TOPIC)" 3

# Several held-back cases at once, so the cooldown is waited for only once.
new_case 'NOTIFY_COOLDOWN=4'
MOVED=$TOPIC
send 'wD:p1' blocked
send 'wD:p1' working
send 'wD:p1' blocked
send 'wD:p1' working
new_case 'NOTIFY_COOLDOWN=4'
MISSED=$TOPIC
printf 'working' >"$W/live/wD:p3"
send 'wD:p3' blocked
send 'wD:p3' working
send 'wD:p3' blocked
new_case 'NOTIFY_COOLDOWN=4'
GONE=$TOPIC
printf 'gone' >"$W/live/wD:p4"
send 'wD:p4' blocked
send 'wD:p4' working
send 'wD:p4' blocked
new_case 'NOTIFY_COOLDOWN=4'
BURST=$TOPIC
for _ in 1 2 3; do
  send 'wD:p1' blocked
  send 'wD:p1' working
done
send 'wD:p1' blocked
check "a burst holding back the same alert starts one re-check" eq "$(logtext | grep -c 're-check wD:p1 blocked')" 1
sleep 6
check "a pane that went back to working is not alerted late" eq "$(count $MOVED)" 1
check "a pane herdr says is not blocked is not alerted late" eq "$(count $MISSED)" 1
check "a pane herdr no longer knows is not alerted late" eq "$(count $GONE)" 1
check "a burst is alerted late once" eq "$(count $BURST)" 2
new_case 'NOTIFY_COOLDOWN=0'
send 'wD:p1' blocked
send 'wD:p1' working
send 'wD:p1' blocked
check "cooldown 0: a new block after working alerts again" eq "$(count $TOPIC)" 2
new_case 'NOTIFY_COOLDOWN=0'
send 'wD:p1' blocked
send 'wD:p1' blocked
check "cooldown 0: the same state twice in a row is still one alert" eq "$(count $TOPIC)" 1
new_case
send 'wD:p1' working
send 'wD:p1' blocked
check "working then blocked: transition alerts" eq "$(count $TOPIC)" 1

echo "== concurrent events"
new_case
racers=
for _ in 1 2 3 4 5 6; do
  send 'wD:p1' blocked &
  racers="$racers $!"
done
wait $racers
check "six racing identical events post once" eq "$(count $TOPIC)" 1

echo "== done"
new_case
send 'wD:p1' done
check "done is silent by default" eq "$(count $TOPIC)" 0
new_case 'NOTIFY_DONE=1'
send 'wD:p1' done
check "NOTIFY_DONE=1: one post" eq "$(count $TOPIC)" 1
check "done title" eq "$(field $TOPIC 0 Title)" "Claude finished"
check "done priority default" eq "$(field $TOPIC 0 Priority)" default
check "done tags" eq "$(field $TOPIC 0 Tags)" white_check_mark
send 'wD:p1' done
check "done does not repeat" eq "$(count $TOPIC)" 1
for s in idle working unknown; do
  new_case 'NOTIFY_DONE=1'
  send 'wD:p1' $s
  check "$s never alerts" eq "$(count $TOPIC)" 0
done

echo "== question line"
new_case
printf 'running\n\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\n\xe2\x94\x82 Allow edit of /home/u/app.py? \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\n  1. Yes\n  2. No\n' >"$W/screen"
send 'wD:p1' blocked
check "last question, box drawing stripped" eq "$(field $TOPIC 0 body)" $'myproj\non Test Box\nAllow edit of /home/u/app.py?'
new_case
printf 'Use key sk-ABCDEFGHIJKLMNOPQRSTUV123456 and token=hunter2value to deploy?\n' >"$W/screen"
send 'wD:p1' blocked
body=$(field $TOPIC 0 body)
check "secrets are redacted" lacks "$body" ABCDEFGHIJ
check "token value redacted" lacks "$body" hunter2value
check "question still shown" has "$body" 'to deploy?'
new_case
printf 'nothing to ask here\n' >"$W/screen"
send 'wD:p1' blocked
check "no question: two-line body" eq "$(field $TOPIC 0 body)" $'myproj\non Test Box'
new_case
printf 'Proceed?\n' >"$W/screen"
start=$(date +%s)
hook "$(event 'wD:p1' blocked)" FAKE_HANG=1
check "hung pane read does not hold the hook" test $(($(date +%s) - start)) -le 8
check "alert still sent without the question" eq "$(field $TOPIC 0 body)" $'myproj\non Test Box'
: >"$W/screen"

echo "== redaction"
while IFS=$'\t' read -r verdict desc got; do
  if [ "$verdict" = ok ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: redaction: $desc"
    echo "  got: $got"
  fi
done < <(python3 - "$here" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import notify

# (description, text, the part that must not survive)
SECRETS = [
    ("Authorization: Bearer in a curl command", "curl -H 'Authorization: Bearer abc123tokenvalue' https://x.example/api?", "abc123tokenvalue"),
    ("Authorization: Bearer on its own", "Authorization: Bearer abc123", "abc123"),
    ("Authorization: Basic", "Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
    ("a bare Bearer token", "send Bearer zzz999yyy now?", "zzz999yyy"),
    ("DB_PASSWORD=", "export DB_PASSWORD=hunter2 first?", "hunter2"),
    ("AWS_SECRET_ACCESS_KEY=", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"),
    ("OPENAI_API_KEY=sk-proj-abc", "OPENAI_API_KEY=sk-proj-abc", "sk-proj-abc"),
    ("--token value", "run deploy --token abc123def now?", "abc123def"),
    ("--api-key value", "run deploy --api-key abc123def now?", "abc123def"),
    ("--password=value", "run deploy --password=pw1x now?", "pw1x"),
    ("quoted value with spaces", 'PASSWORD="my secret pw" ok?', "my secret pw"),
    ("password: value", "password: hunter2", "hunter2"),
    ("token in a query string", "GET /v1/items?token=abc123def&x=1", "abc123def"),
    ("userinfo in a database URL", "connect to postgres://user:pw@host/db?", "user:pw"),
    ("a token as userinfo in a git URL", "git clone https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/o/r.git?", "ghp_abcdefghij"),
    ("Slack webhook", "post to https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX?", "T00000000"),
    ("Discord webhook", "post to https://discord.com/api/webhooks/123456789/abcDEF_ghi-jkl?", "abcDEF_ghi"),
    ("sk- key", "Use sk-abcdefgh12345678 now?", "abcdefgh12345678"),
    ("GitHub token", "Use ghp_abcdefghijklmnopqrstuvwxyz0123456789 now?", "ghp_abcdefghij"),
    ("GitHub fine-grained token", "Use github_pat_11ABCDEFG0abcdefghijklmno_abcdef now?", "11ABCDEFG0"),
    ("Slack token", "Use xoxb-123456789012-abcdefghijkl now?", "123456789012"),
    ("AWS access key id", "Use AKIAIOSFODNN7EXAMPLE now?", "AKIAIOSFODNN7"),
    ("Google API key", "Use AIzaSyA1234567890abcdefghijklmnopqrstuv now?", "AIzaSyA1234"),
    ("JWT", "Use eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U now?", "eyJhbGci"),
    ("40 hex characters", "Use 9fceb02d0ae598e95dc970b74767f19372d61af8 now?", "9fceb02d0ae598e9"),
    ("a long base64 blob", "Use dGhpcyBpcyBhIHZlcnkgbG9uZyBiYXNlNjQgc3RyaW5n/QUJDRA== now?", "dGhpcyBpcyBhIHZlcnkg"),
    ("a long mixed identifier", "Use a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8 now?", "a1b2c3d4e5f6g7h8"),
]
# Ordinary questions must come through untouched.
PLAIN = [
    "Allow edit of /home/u/app.py?",
    "Do you want to run npm install in the project?",
    "Overwrite app/test/deep_link_test.dart with the new version?",
    "Run `git push origin main`?",
    "Continue with 3 of 12 files?",
    "Use https://example.com/docs/page?id=2 as the source?",
    "Open /Users/Alice/Projects/App2/Sources/Models/Thing.swift?",
    "Open /home/dev/workspace/herdr-mobile/app/lib/ui/core/deep_link.dart?",
    "Which keyboard layout should I use?",
    "Is the Authorization header required here?",
    "Delete the 3 foreign-key constraints?",
    "Apply the change at 14:30 to main.py?",
]
for desc, text, secret in SECRETS:
    out = notify.redact(text)
    if secret in out or "***" not in out:
        print("bad\t%s\t%s" % (desc, out))
    else:
        print("ok\t" + desc)
for text in PLAIN:
    out = notify.redact(text)
    print("ok\tordinary text survives: " + text if out == text else "bad\tordinary text changed: %s\t%s" % (text, out))
PY
)

echo "== names and encoding"
new_case 'MACHINE=Mac/mini é'
send 'wD:p1' blocked
check "machine encoded in link" eq "$(field $TOPIC 0 Click)" 'herdr://agent/Mac%2Fmini%20%C3%A9/wD%3Ap1'
new_case
hook "$(event 'wD:p1' blocked display_agent=Trợ-lý)"
decoded=$(python3 -c '
import email.header, sys
print(str(email.header.make_header(email.header.decode_header(sys.argv[1]))), end="")' "$(field $TOPIC 0 Title)")
check "non-ASCII title is RFC 2047" eq "$decoded" "Trợ-lý needs you"
check "header itself is ASCII" test -z "$(field $TOPIC 0 Title | LC_ALL=C tr -d '\0-\177')"
new_case
hook "$(event 'wD:p1' blocked agent=omp)"
check "lowercase agent name is capitalised" eq "$(field $TOPIC 0 Title)" "Omp needs you"

echo "== config"
new_case 'NTFY_TOKEN=tk_secret123'
send 'wD:p1' blocked
check "token goes in Authorization" eq "$(field $TOPIC 0 Authorization)" 'Bearer tk_secret123'
all="$(field $TOPIC 0 Title)|$(field $TOPIC 0 Click)|$(field $TOPIC 0 body)|$(field $TOPIC 0 Tags)"
check "token is not in the notification" lacks "$all" tk_secret123

new_case
{
  printf '# comment\r\n\r\n'
  printf 'export NTFY_URL="http://127.0.0.1:%s"\r\n' "$PORT"
  printf 'NTFY_TOPIC=%s   # trailing comment\r\n' "$TOPIC"
  printf "MACHINE='Quoted Box'\n"
  printf 'UNKNOWN_KEY=whatever\n'
} >"$CFG/.env"
send 'wD:p1' blocked
check ".env: CRLF, export, quotes, comments" eq "$(field $TOPIC 0 Click)" 'herdr://agent/Quoted%20Box/wD%3Ap1'

new_case "MACHINE=\$(touch $W/pwned)"
send 'wD:p1' blocked
check ".env values are data, never executed" test ! -e "$W/pwned"
check ".env value kept literally" eq "$(field $TOPIC 0 Click)" 'herdr://agent/%24%28touch%20'"${W//\//%2F}"'%2Fpwned%29/wD%3Ap1'

new_case
hook "$(event 'wD:p1' blocked)" MACHINE=FromEnv
check "process environment beats .env" eq "$(field $TOPIC 0 Click)" 'herdr://agent/FromEnv/wD%3Ap1'

new_case
sed -i '/^MACHINE=/d' "$CFG/.env"
send 'wD:p1' blocked
host=$(python3 -c 'import socket; print(socket.gethostname())')
check "MACHINE defaults to the hostname" has "$(field $TOPIC 0 Click)" "herdr://agent/$host/"

new_case
printf 'NTFY_URL=http://127.0.0.1:%s/\nNTFY_TOPIC=%s\n' "$PORT" "$TOPIC" >"$CFG/.env"
send 'wD:p1' blocked
check "trailing slash on NTFY_URL is fine" eq "$(count $TOPIC)" 1

echo "== failure never blocks herdr"
new_case
printf 'NTFY_TOPIC=../etc/x\nNTFY_URL=http://127.0.0.1:%s\n' "$PORT" >"$CFG/.env"
send 'wD:p1' blocked
check "bad topic: exit 0" eq "$?" 0
check "bad topic: nothing posted" eq "$(count ../etc/x)" 0
check "bad topic: logged" has "$(logtext)" 'NTFY_TOPIC must'

new_case
printf 'NTFY_URL=http://127.0.0.1:%s\n' "$PORT" >"$CFG/.env"
send 'wD:p1' blocked
check "no topic: exit 0" eq "$?" 0
check "no topic: logged" has "$(logtext)" 'NTFY_TOPIC is not set'

new_case
printf 'NTFY_URL=file:///etc/passwd\nNTFY_TOPIC=%s\n' "$TOPIC" >"$CFG/.env"
send 'wD:p1' blocked
check "non-http URL refused" has "$(logtext)" 'NTFY_URL must be an http(s) URL'

new_case
printf 'NTFY_URL=http://127.0.0.1:%s\nNTFY_TOPIC=%s\n' "$DEAD_PORT" "$TOPIC" >"$CFG/.env"
start=$(date +%s)
send 'wD:p1' blocked
rc=$?
check "unreachable server: exit 0" eq "$rc" 0
check "unreachable server: quick" test $(($(date +%s) - start)) -le 15
check "unreachable server: logged" has "$(logtext)" 'post failed'

new_case
hook 'not json'
check "garbage event: exit 0" eq "$?" 0
hook ''
check "empty event: exit 0" eq "$?" 0
check "garbage event: logged" has "$(logtext)" 'ignored'
check "garbage event: nothing posted" eq "$(count $TOPIC)" 0

new_case
printf 'NTFY_TOPIC=%s\nNTFY_URL=http://127.0.0.1:%s\n' "$TOPIC" "$PORT" >"$CFG/.env"
mkdir -p "$STATE/panes"
printf 'not json' >"$STATE/panes/wD_p1.json"
send 'wD:p1' blocked
check "corrupt state file is replaced, alert goes out" eq "$(count $TOPIC)" 1

echo "== a failed post is retried"
new_case 'NOTIFY_COOLDOWN=0'
touch "$W/posts.jsonl.fail"
send 'wD:p1' blocked
check "server error: exit 0" eq "$?" 0
check "server error: nothing accepted" eq "$(count $TOPIC)" 0
check "server error: it was tried (and retried once by curl)" eq "$(wc -l <"$W/posts.jsonl.failed" | tr -d ' ')" 2
check "server error: logged" has "$(logtext)" 'post failed'
rm -f "$W/posts.jsonl.fail" "$W/posts.jsonl.failed"
send 'wD:p1' blocked
check "the next event for the same state delivers" eq "$(count $TOPIC)" 1
send 'wD:p1' blocked
check "and then it is deduped as before" eq "$(count $TOPIC)" 1

new_case 'NOTIFY_COOLDOWN=3'
touch "$W/posts.jsonl.fail"
send 'wD:p1' blocked
rm -f "$W/posts.jsonl.fail" "$W/posts.jsonl.failed"
send 'wD:p1' blocked
check "after a failure the cooldown still holds (a down server is not hammered)" eq "$(count $TOPIC)" 0
check "cooldown is the stated reason" has "$(logtext)" 'cooldown'
check "the failed alert is sent when the cooldown ends, with no further event" wait_for $TOPIC 1 10

new_case 'NOTIFY_COOLDOWN=0'
touch "$W/posts.jsonl.fail"
send 'wD:p1' blocked
rm -f "$W/posts.jsonl.fail" "$W/posts.jsonl.failed"
send 'wD:p1' working
send 'wD:p1' blocked
check "failure then working then blocked: exactly one alert" eq "$(count $TOPIC)" 1

new_case
out=$(HERDR_PLUGIN_STATE_DIR="$STATE" python3 - "$here" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import notify
notify.record_status("p", "blocked", time.time())
notify.record_status("p", "working", time.time())
notify.release_claim("p", "blocked")  # the pane moved on: nothing to give back
_, _, path = notify._locked_pane("p")
print(notify._load(path)["seen"])
PY
)
check "a late failure does not rewind a pane that moved on" eq "$out" working

echo "== topic strength"
# No NTFY_URL means the public ntfy.sh. The proxy points at a dead port so a
# regression fails fast instead of posting to the internet.
NOPROXY=(https_proxy="http://127.0.0.1:$DEAD_PORT" http_proxy="http://127.0.0.1:$DEAD_PORT" ALL_PROXY="http://127.0.0.1:$DEAD_PORT")
new_case
printf 'NTFY_TOPIC=guessable\n' >"$CFG/.env"
hook "$(event 'wD:p1' blocked)" "${NOPROXY[@]}"
hook "$(event 'wD:p2' blocked)" "${NOPROXY[@]}"
check "short topic on public ntfy.sh: refused, reason logged" has "$(logtext)" 'only 9 characters'
check "short topic on public ntfy.sh: no post was attempted" lacks "$(logtext)" 'post failed'
check "the refusal is logged once, not per event" eq "$(logtext | grep -c 'only 9 characters')" 1
new_case
printf 'NTFY_TOPIC=guessable\n' >"$CFG/.env"
hook "$(event 'wD:p1' blocked)" "${NOPROXY[@]}"
hook "$(event 'wD:p1' working)" "${NOPROXY[@]}"
hook "$(event 'wD:p1' blocked)" "${NOPROXY[@]}"
check "the pane's state is still tracked while the config is refused" has "$(cat "$STATE"/panes/wD_p1.json)" '"seen": "blocked"'

while IFS=$'\t' read -r verdict desc; do
  if [ "$verdict" = ok ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: topic strength: $desc"
  fi
done < <(python3 - "$here" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import notify

def verdict(env):
    for key in ("NTFY_URL", "NTFY_TOPIC", "NTFY_TOKEN"):
        os.environ.pop(key, None)
    os.environ.update(env)
    try:
        notify.load_config()
        return True
    except notify.ConfigError:
        return False

r15, r16 = "a" * 15, "a" * 16
cases = [
    ("default URL, 15 characters: refused", {"NTFY_TOPIC": r15}, False),
    ("default URL, 16 characters: accepted", {"NTFY_TOPIC": r16}, True),
    ("explicit ntfy.sh with a trailing slash: still public", {"NTFY_URL": "https://ntfy.sh/", "NTFY_TOPIC": r15}, False),
    ("ntfy.sh in capitals over http: still public", {"NTFY_URL": "http://NTFY.SH", "NTFY_TOPIC": r15}, False),
    ("a token makes a short topic fine", {"NTFY_TOPIC": "abc", "NTFY_TOKEN": "tk_1234"}, True),
    ("own server, short topic: fine", {"NTFY_URL": "https://ntfy.example.com", "NTFY_TOPIC": "abc"}, True),
    ("LAN server, one character: fine", {"NTFY_URL": "http://127.0.0.1:8080", "NTFY_TOPIC": "x"}, True),
    ("a lookalike host is not ntfy.sh", {"NTFY_URL": "https://ntfy.sh.example.org", "NTFY_TOPIC": "abc"}, True),
    ("a topic with a slash is refused everywhere", {"NTFY_URL": "http://127.0.0.1:8080", "NTFY_TOPIC": "a/b"}, False),
    ("no topic is refused", {"NTFY_URL": "http://127.0.0.1:8080"}, False),
]
for desc, env, want in cases:
    print(("ok" if verdict(env) == want else "bad") + "\t" + desc)
PY
)

echo "== a body that starts with @"
new_case
hook "$(event 'wD:p1' blocked)" HERDR_PLUGIN_CONTEXT_JSON='{"workspace_label":"@/etc/hostname","tab_label":"1"}'
check "@-title is sent literally, curl reads no file" eq "$(field $TOPIC 0 body)" $'@/etc/hostname\non Test Box'
new_case
hook "$(event 'wD:p1' blocked)" HERDR_PLUGIN_CONTEXT_JSON='{"workspace_label":"proj","tab_label":"@/etc/hostname"}'
check "@ later in the body is fine too" eq "$(field $TOPIC 0 body)" $'proj · @/etc/hostname\non Test Box'

echo "== manifest"
manifest=$(cat "$here/herdr-plugin.toml")
check "hooks pane.agent_status_changed" has "$manifest" 'on = "pane.agent_status_changed"'
check "declares min_herdr_version" has "$manifest" 'min_herdr_version = "0.7.0"'

# --- part 2: a real, isolated herdr -------------------------------------------

iso() { # run a command with an environment that cannot reach any other herdr
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_BIN_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_PLUGIN_ID \
    HOME="$W/e2e/home" XDG_CONFIG_HOME="$W/e2e/cfg" XDG_RUNTIME_DIR="$W/e2e/run" \
    HERDR_SOCKET_PATH="$W/e2e/h.sock" SHELL=/bin/sh "$@"
}
pane_of() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])'; }

echo "== isolated herdr"
if ! command -v herdr >/dev/null 2>&1; then
  echo "SKIP: herdr is not on PATH (end-to-end part not run)"
else
  mkdir -p "$W/e2e/home" "$W/e2e/cfg/herdr" "$W/e2e/run"
  printf 'onboarding = false\n' >"$W/e2e/cfg/herdr/config.toml"
  iso setsid herdr server </dev/null >"$W/e2e/server.out" 2>&1 &
  server_pid=$!
  for _ in $(seq 100); do [ -S "$W/e2e/h.sock" ] && break; sleep 0.1; done
  check "isolated server is up" test -S "$W/e2e/h.sock"
  link=$(iso herdr plugin link "$here" 2>&1)
  check "plugin links (manifest accepted by herdr)" has "$link" '"plugin_id":"herdr-mobile.ntfy"'
  check "no manifest warnings" lacks "$link" '"warnings"'
  cdir=$(iso herdr plugin config-dir herdr-mobile.ntfy)
  check "config dir is inside the sandbox" has "$cdir" "$W/e2e/cfg"
  printf 'NTFY_URL=http://127.0.0.1:%s\nNTFY_TOPIC=e2e\nMACHINE=Test Box\nNOTIFY_DONE=1\nNOTIFY_COOLDOWN=5\n' "$PORT" >"$cdir/.env"

  p1=$(iso herdr workspace create --label myproj --no-focus | pane_of)
  iso herdr pane run "$p1" "echo 'Allow edit of foo.py?'" >/dev/null
  for _ in $(seq 50); do
    iso herdr pane read "$p1" --source visible | grep -qx 'Allow edit of foo.py?' && break
    sleep 0.1
  done
  iso herdr pane report-agent "$p1" --source t --agent claude --state working >/dev/null
  iso herdr pane report-agent "$p1" --source t --agent claude --state blocked >/dev/null
  check "blocked reaches the listener" wait_for e2e 1 6
  check "e2e title" eq "$(field e2e 0 Title)" "Claude needs you"
  check "e2e click" eq "$(field e2e 0 Click)" "herdr://agent/Test%20Box/${p1//:/%3A}"
  check "e2e body has workspace, machine, question" eq "$(field e2e 0 body)" $'myproj\non Test Box\nAllow edit of foo.py?'
  iso herdr pane report-agent "$p1" --source t --agent claude --state blocked >/dev/null
  sleep 1
  check "e2e: repeated blocked report does not repeat" eq "$(count e2e)" 1
  iso herdr pane report-agent "$p1" --source t --agent claude --state working >/dev/null
  iso herdr pane report-agent "$p1" --source t --agent claude --state blocked >/dev/null
  sleep 1
  check "e2e: blocked again inside the cooldown is held back" eq "$(count e2e)" 1
  check "e2e: it goes out when the cooldown ends" wait_for e2e 2 12
  check "e2e: for the same pane" eq "$(field e2e 1 Click)" "herdr://agent/Test%20Box/${p1//:/%3A}"

  p2=$(iso herdr workspace create --label second --no-focus | pane_of)
  iso herdr pane report-agent "$p2" --source t --agent codex --state working >/dev/null
  iso herdr pane report-agent "$p2" --source t --agent codex --state idle >/dev/null
  check "finished (done) reaches the listener" wait_for e2e 3 6
  check "e2e done title" eq "$(field e2e 2 Title)" "Codex finished"
  check "e2e done link" eq "$(field e2e 2 Click)" "herdr://agent/Test%20Box/${p2//:/%3A}"
  logs=$(iso herdr plugin log list --plugin herdr-mobile.ntfy)
  check "herdr recorded the hook runs as succeeded" has "$logs" '"status":"succeeded"'
  check "no hook failed" lacks "$logs" '"status":"failed"'
fi

echo
echo "passed: $pass, failed: $failed"
[ "$failed" -eq 0 ]
