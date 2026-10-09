#!/usr/bin/env bash
# herdr-ntfy: event hook for pane.agent_status_changed. Posts to an ntfy topic
# when an agent becomes blocked (always) or done (NOTIFY_DONE=1).
#
# herdr runs this once per event with HERDR_PLUGIN_EVENT_JSON set. The decision
# (dedupe, cooldown, message) lives in notify.py; this script loads the config,
# sends the request with curl, and logs failures. It always exits 0.
#
# With HERDR_NTFY_RECHECK_AFTER=<seconds> (set by notify.py, never by herdr) this
# is the one detached re-check of an alert the cooldown held back: it sleeps
# that long, then runs the same steps, and notify.py alerts only if the pane
# still is in that state.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
config_dir=${HERDR_PLUGIN_CONFIG_DIR:-$here}

if ! command -v python3 >/dev/null 2>&1; then
  echo "herdr-ntfy: python3 not found" >&2
  exit 0
fi

if [ -n "${HERDR_NTFY_RECHECK_AFTER:-}" ]; then
  case $HERDR_NTFY_RECHECK_AFTER in *[!0-9]*) exit 0 ;; esac
  sleep "$HERDR_NTFY_RECHECK_AFTER" || exit 0
fi

log() { python3 "$here/notify.py" log "$*" 2>/dev/null || echo "herdr-ntfy: $*" >&2; }

# Read KEY=VALUE lines for the keys we know. Never `source` the file: it is
# data, and values must not be executed. Variables already in the environment win.
load_env() {
  local file=$1 line key value
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case $line in '' | '#'*) continue ;; esac
    line=${line#export }
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    key=${key%"${key##*[![:space:]]}"}
    case $key in
      NTFY_URL | NTFY_TOPIC | NTFY_TOKEN | MACHINE | NOTIFY_DONE | NOTIFY_COOLDOWN) ;;
      *) continue ;;
    esac
    [ -z "${!key+x}" ] || continue
    value=${value#"${value%%[![:space:]]*}"}
    case $value in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
      *) value=${value%%[[:space:]]#*}; value=${value%"${value##*[![:space:]]}"} ;;
    esac
    export "$key=$value"
  done <"$file"
}

load_env "$config_dir/.env"

if [ -z "${NTFY_TOPIC:-}" ]; then
  python3 "$here/notify.py" log-once topic-unset "NTFY_TOPIC is not set; edit $config_dir/.env" 2>/dev/null
  exit 0
fi

request=$(python3 "$here/notify.py" plan) || request=
[ -n "$request" ] || exit 0

if ! err=$(printf '%s' "$request" | curl -q --silent --show-error --fail \
  --connect-timeout 4 --max-time 8 --retry 1 --retry-delay 1 \
  -K - --output /dev/null 2>&1); then
  log "post failed: ${err:-curl exited non-zero}"
  # Give the claim back: the next event for this pane tries again (the
  # cooldown still applies).
  python3 "$here/notify.py" failed 2>/dev/null
fi
exit 0
