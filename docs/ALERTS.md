# Alerts

Two ways to be told when an agent needs you. The first is built into the app
and is the one to use; the second is an optional extra for a phone that is
asleep or out of reach of your machines.

## 1. Local notifications (in the app, off by default)

Settings > Notifications > **Notify me when an agent needs me**. Everything
happens on the phone: no relay, no account, nothing leaves the device.

- A notification appears when an agent **becomes** blocked on a question (a
  terminal agent or an agent session). **Also when an agent finishes** is a
  second, separate switch.
- It is posted only while the app is away. **Opening the app clears every
  notification** (also any left from a previous run of the app), and one is
  cancelled as soon as its agent is seen to stop needing you (you answered
  somewhere else, the pane closed). A link blip or an offline machine does
  **not** withdraw it: you were told, and it stays until you open the app or
  the agent leaves the state.
- Whatever was already blocked when you left the app (last known state, also
  on machines that were unreachable) is not announced. At most three
  notifications per burst; more become one summary (`N agents need you`, and a
  separate `N agents finished`). An agent that flaps is announced at most once
  a minute.
- Tap: `herdr://agent/<machine>/<pane>` (terminal agent),
  `herdr://session/<machine>/<keeper>` (agent session) or `herdr://agents`
  (the summary: the Agents tab). Cold start and running app both work. A
  link that cannot be followed says why over the screen in front, closes
  nothing (a half-filled form stays), and its toast opens the tab where the
  next step is (Machines or Agents).
- Android 13+ asks for the notification permission when you turn it on; if you
  say no the switch stays off and says why.
- **Answer from the notification.** For a terminal agent whose question the app
  understands, the notification shows the question and the command (through
  `visibleText`) and carries up to two buttons, only for options that are not
  gated (never `needsConfirm`, never a standing grant; a command over 640
  characters gets none). A press is forwarded to the main isolate, which
  re-reads the pane and sends only if it is still blocked on the same question
  (a digest of the question and options) and the option is still one-tap; the
  press is spent before sending, so it cannot send twice. Otherwise nothing is
  sent and an `Answer not sent` notice says so (its tap opens the agent). This
  needs the main isolate alive, i.e. the Watching service running; after a
  swipe-away the press only yields that notice. Not yet seen on a phone.

**What keeps it working while the phone is locked.** Nothing can notice an
agent changing state without a live connection, and Android freezes a
background app. So while notifications are on **and at least one agent is
working or blocked**, the app runs a quiet foreground service (type
`specialUse`): a minimum-importance **"Watching N agents"** notice, whose second
line reads **"2 need you · 3 working"** (zero parts left out; it changes only
when the count of agents or of blocked ones does, through the existing 2 s
debounce), that Android
requires for it. Android generally lets a running foreground service keep its
network access in Doze (platform behaviour; not yet measured on this phone).
While it runs the connections are not dropped after 90 s, and they go quiet:

- the event stream becomes **status changes only** (`pane.agent_status_changed`
  per agent pane plus structural events). `pane.updated`, which fires for
  every spinner frame and keystroke of a busy agent, is dropped: against a real
  herdr 0.9.3, 150 lines of output caused 150 events with the full
  subscription and none with the status-only one;
- the mux heartbeat goes from 8 s to 300 s, the idle link ping from 25 s to
  330 s, and the safety-net poll from 20 s to 4 min (its answer is the
  liveness test);
- agent sessions are listed every 4 min and a streaming session updates the app
  at most every 2 s; a machine that is down is retried at most every 5 min.

Returning to the app restores the live view. When nothing is working or
blocked, or you switch the setting off, the service stops and the old rule
(drop after 90 s) applies.

Limits, plainly:

- Swiping the app away from the recents list stops the service and the
  watching. Back at the root of the app moves it to the background instead of
  closing it while watching is on; with nothing watched, Back exits as before.
- Android 12+ may refuse to start a foreground service from the background;
  the app starts it while you are still in the app and retries on the next
  lifecycle change. A refusal is not retried in a loop.
- A dead link in the background is noticed within a few minutes (about 2.5 with
  the CPU awake, longer if the phone sleeps deeply), not seconds. Over
  Tailscale the tunnel keeps its own NAT mapping alive; over a direct
  connection through carrier NAT an idle mapping can expire between
  heartbeats, which costs a reconnect and any event that happened meanwhile
  until the next beat notices.
- It costs battery while agents work (a radio wake every couple of minutes plus
  one wake per status change). Not measured yet: use `adb shell dumpsys
  batterystats` with the setting on and off.

## 2. Optional: a host plugin that posts to ntfy

The app itself holds no connection when it is not watching, so a phone that is
off, in deep Doze without the service, or away from a network cannot be told
by the app. For that the alert can come from the **machine**: a herdr plugin
there posts to an [ntfy](https://ntfy.sh) topic when an agent becomes blocked
(or finished), and the ntfy app on your phone shows it. The app does not know
about this path any more (Settings has no ntfy rows); the plugin and its tap
link still work.

```
herdr (host) -- agent_status_changed --> herdr-ntfy plugin --POST--> ntfy topic
                                                                       |
phone: ntfy app  <-----------------------------------------------------+
   |  tap: herdr://agent/<machine>/<pane-id>
   v
herdr mobile opens that pane
```

## Install

On the phone: install the ntfy app (Google Play or F-Droid) and subscribe to a
topic (see [Topic hygiene](#topic-hygiene)).

On every machine that runs herdr (0.7.0 or newer; needs `bash`, `python3` and
`curl` 7.43 or newer):

**1. Copy the plugin and link it.** This works from any checkout and needs
nothing published. The plugin runs from the folder you link, so keep it there.

```sh
# from a clone of this repo, on your computer:
scp -r tool/plugins/herdr-ntfy me@the-machine:herdr-ntfy

# on the machine:
herdr plugin link ~/herdr-ntfy
CONFIG_DIR="$(herdr plugin config-dir herdr-mobile.ntfy)"
cat > "$CONFIG_DIR/.env" <<'EOF'
NTFY_TOPIC=put-a-long-random-topic-here
MACHINE=Mac mini
EOF
chmod 600 "$CONFIG_DIR/.env"
```

On the machine you work from, `herdr plugin link tool/plugins/herdr-ntfy` links
the clone itself. To update, copy the folder again; to remove,
`herdr plugin unlink herdr-mobile.ntfy`.

**2. Or install from GitHub**, once `tool/plugins/herdr-ntfy` is pushed to the
repository you name (herdr clones it and keeps its own copy):

```sh
herdr plugin install tuan3w/herdr-mobile/tool/plugins/herdr-ntfy
```

Then write the `.env` as above (`herdr plugin config-dir herdr-mobile.ntfy`
prints where).

`MACHINE` must be the **name the machine has in herdr mobile** (Machines tab).
Nothing needs restarting: herdr reads the plugin and its `.env` on every event.
The same steps work on a headless server.

## Config keys

Read from `$HERDR_PLUGIN_CONFIG_DIR/.env` (plain `KEY=VALUE` lines; `#`
comments, `export`, and single or double quotes are accepted; the file is data,
never executed). A variable already in herdr's environment wins over the file.

| Key | Default | Meaning |
| --- | --- | --- |
| `NTFY_TOPIC` | none (required) | Topic to post to. 1-64 characters of `A-Z a-z 0-9 _ -`; **at least 16 on the public ntfy.sh** unless `NTFY_TOKEN` is set or `NTFY_URL` is your own server. |
| `NTFY_URL` | `https://ntfy.sh` | ntfy server, `http://` or `https://`. |
| `NTFY_TOKEN` | none | ntfy access token, sent as `Authorization: Bearer`. |
| `MACHINE` | this host's name | The machine's name in herdr mobile. Used in the tap link and the message. |
| `NOTIFY_DONE` | off | `1` also alerts when an agent finishes. Blocked always alerts. |
| `NOTIFY_COOLDOWN` | `30` | Seconds before the same pane may alert again for the same state. An alert the cooldown holds back is sent when it ends, if the pane is still in that state (see "What an alert contains"). |

## What an alert contains

| Part | Blocked | Done |
| --- | --- | --- |
| Title | `<agent> needs you` | `<agent> finished` |
| Priority / tags | `high` / `warning` | `default` / `white_check_mark` |
| Body | project (herdr workspace and tab), `on <machine>`, and the question on the pane's screen when there is one | project, `on <machine>` |
| Tap (`Click`) | `herdr://agent/<machine>/<pane-id>`, percent-encoded | same |

The question is the last line ending in `?` among the pane's visible lines,
cut to 140 characters. Credential-looking text is replaced with `***` first:
`Authorization:`/`Bearer` values; `NAME=value` and `NAME: value` where the name
holds token, secret, password, key or credential (`DB_PASSWORD=`,
`AWS_SECRET_ACCESS_KEY=`); `--token value` style flags; `user:pw@` in URLs;
Slack and Discord webhook URLs; `sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`,
`AIza` and JWT shapes; and hex or base64 runs of 32 or more characters. It
errs toward hiding, but it is best effort: **anything on the pane's screen can
end up in the notification, and ntfy's server sees it**. The ntfy token and
topic are never part of the message.

An alert fires on a **transition** into the state, once per pane and state: a
second event for a pane that is already blocked sends nothing, and a pane that
goes back to working and blocks again inside the cooldown is **held back, not
dropped**. The pane stays blocked and herdr sends no further event, so the hook
that held it back also starts one detached `notify.sh` for that pane (more
holds for the same alert start none), which sleeps until the cooldown ends and
alerts once if the pane is still in that state: the last event says so and
`herdr pane get` agrees (when herdr cannot be asked, the events decide). A pane
that went back to working, is gone, or alerted in the meantime sends nothing.
A cooldown over 10 minutes holds an alert back without this re-check. Done
follows herdr's own meaning: a finished agent nobody has looked at yet.

Why: a hold-back used to record the pane as already blocked, and a pane that
stays blocked sends no further event, so a blocked agent whose alert fell in
the cooldown (a quick retry loop, a restart) never alerted at all. The sleeper
has no stdin/stdout/stderr to herdr, is one per pane, never starts another, and
exits silently when its state directory is gone.

The plugin never holds herdr up. It posts with a 4 s connect and 8 s total
limit (one retry), exits 0 whatever happens, and logs problems to
`ntfy.log` in the plugin state directory (on Linux
`~/.local/state/herdr/plugins/herdr-mobile.ntfy/`; the file is trimmed at 64 KB).
`herdr plugin log list --plugin herdr-mobile.ntfy` shows each run.

If a post fails (server down, 5xx), the pane's state is given back, so the next
event for that pane tries again; the cooldown still applies, so a server that
is down is tried once per cooldown rather than once per event, and an event
that arrives inside the cooldown is held back and sent when it ends, like any
other. There is no queue: a failure with no later event for that pane is not
retried.

## The tap

`herdr://agent/<machine>/<pane-id>` opens that agent as a tab, the same as
tapping its card. `<machine>` is matched against your saved machines by label
(any case), then by host, then by id. Both parts are percent-encoded (`w1:p2`
travels as `w1%3Ap2`).

If the link cannot be followed the app shows a short message over the board:
no such machine, the machine is switched off, the pane is gone, or the machine
did not answer within 8 s. A machine that is still reconnecting when you tap is
waited for; a pane its last snapshot (cached from before) has opens at once.

## Topic hygiene

On the public ntfy.sh anyone who knows a topic name can read it and post to it.
The topic is the only secret. The plugin therefore **refuses to post** to
ntfy.sh with a topic shorter than 16 characters, unless `NTFY_TOKEN` is set or
`NTFY_URL` points at another server; it logs why, once, to `ntfy.log`.

- Use a long random topic, for example `herdr-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)`.
  Do not reuse it, share screenshots of it, or commit the `.env`.
- Better: a self-hosted ntfy, or an ntfy.sh account with a reserved topic and an
  access token (`NTFY_TOKEN`, from the ntfy account settings), so the topic needs
  authentication to read or write.
- Each alert carries project and machine names and possibly a line of the
  agent's question. If that is too much to send to a server you do not run,
  self-host ntfy.

## Limits

- Needs ntfy: an app on the phone and a topic. Alerts are only as timely as its
  delivery. ntfy.sh from the Google Play build is delivered through Google's push
  service; a self-hosted server, or the F-Droid build, makes the ntfy app keep
  its own connection to your server (see the ntfy docs on Android delivery and
  `upstream-base-url`). That connection is ntfy's, not herdr mobile's.
- The host must be running herdr when the agent changes state. Hooks only run in
  a live herdr server; nothing is queued while it is down.
- The plugin reacts to herdr's detected state. Blocked means herdr recognised an
  approval or question UI on the pane; an agent herdr does not recognise never
  alerts.
- A desktop user looking at the pane still gets the alert. Turn `NOTIFY_DONE` off
  if finished-agent alerts are noise.
- Opening a link whose machine is unknown, switched off or unreachable leaves
  the app on whichever tab it was on (it does not switch to Agents).
- If Android restarts the app's process, the launch link is delivered again and
  re-opens that agent once.

## Testing

Host side, without touching a running herdr or the network:

```sh
tool/plugins/herdr-ntfy/test.sh
```

It feeds sample `pane.agent_status_changed` payloads to the script and checks
the captured POST (title, priority, tags, link, body, dedupe, cooldown, races,
redaction, config parsing, failure paths), then, when `herdr` is on PATH, starts
an isolated herdr (own socket, config directory, HOME and runtime directory
under `/tmp`), links the plugin, and drives real status changes with
`herdr pane report-agent` against a local listener.

By hand, against your own topic, using a scratch workspace so no real agent is
touched:

```sh
herdr workspace create --label ntfy-test --no-focus     # prints the new pane id
herdr pane report-agent <pane-id> --source test --agent claude --state working
herdr pane report-agent <pane-id> --source test --agent claude --state blocked
herdr pane release-agent <pane-id> --source test --agent claude
herdr workspace close <workspace-id>
```

Then check the ntfy app. To test the tap without waiting for an alert, open
`herdr://agent/<machine>/<pane-id>` on the phone (for example
`adb shell am start -a android.intent.action.VIEW -d 'herdr://agent/Mac%20mini/w1%3Ap1'`).
