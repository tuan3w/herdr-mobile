# herdr mobile

A Flutter client for [herdr](https://herdr.dev) — see every coding agent across
all your machines, know the moment one needs you, and reply from your phone.

```
phone ──SSH──▶ machine A ── one multiplexed channel ──▶ herdr socket
      ──SSH──▶ machine B ── …
```

No relay, no public ports, no account. The app authenticates over SSH (key or
password) and keeps **one persistent channel per machine** that carries every
request (a tiny relay script on the host; needs `python3`). Hosts without it
fall back to `herdr remote-api-bridge` (herdr ≥ 0.9), then `socat`/`python3`,
one channel per request: slower, same behaviour. Each machine has its own
connection, backoff and reconnect; one machine failing never affects another.

## Features

- Multiple machines; add / edit / disable / remove, with **Test connection**
  (shows herdr version, workspace count and the host key before you trust it).
- Agents board across all machines, grouped by urgency
  (blocked → working → done → idle) with a badge for what needs you.
- Machine browser: workspaces → tabs → panes.
- Live pane view in colour (truecolor/256/16, bold/dim/italic/underline),
  virtualized so a long scrollback stays at full frame rate. Type a line or
  send keys (esc, tab, ctrl+c, arrows, enter). Updates arrive on activity,
  not by polling, and stop while the app is in the background.
- Built for phone networks: switching Wi-Fi/cellular or losing signal is
  detected (machines show "No network" and reconnect within a second of
  returning), a half-dead connection is noticed in under ~15 s, and the last
  state paints instantly on launch, dimmed until it is fresh.
- Event-driven updates (`events.subscribe`) with a slow poll as a backstop.
- Host keys pinned on first use; a changed key is a hard stop.
- Secrets live in the platform keychain, never in preferences.

## Install (Android)

Download the APK for your device from the repo's *Releases* page
(`arm64-v8a` for almost every modern phone), allow installs from unknown
sources, and open it. Verify the download against `SHA256SUMS`.

## Performance

Measured against a live herdr over SSH to localhost (so network latency is
zero and everything shown is overhead the app controls):

| | before | after |
| --- | --- | --- |
| `ping` round-trip, p50 | 49 ms | 0.9 ms |
| `pane.read` (300 lines), p50 | 65 ms | 16 ms |
| `session.snapshot`, p50 | 83 ms | 39 ms |
| session refetches in 15 s, busy agents | 33 | 1 |
| UI notifications in 15 s, busy agents | 35 | 2 |

Two things did most of the work: one multiplexed channel instead of a shell
plus two process spawns per request, and recognising that a `pane_updated`
event carries the whole pane, so spinner churn needs no refetch at all.

## Layout

```
app/lib/
  data/
    models/         herdr_models.dart, machine_profile.dart
    services/       herdr_transport.dart (interface), ssh_transport.dart,
                    mux_client.dart (persistent request channel),
                    bridge_command.dart, herdr_api.dart,
                    network_monitor.dart, snapshot_cache.dart
    repositories/   machine_repository.dart   saved machines + secrets
                    machine_connection.dart   one machine: snapshot + reconnect
                    fleet_repository.dart     all machines, merged agent list
  ui/
    core/           theme, motion tokens, shared widgets, ansi parser,
                    terminal view
    features/       agents/, machines/, pane/   (views + view models)
    shell/          bottom navigation
docs/herdr-api.schema.json   protocol schema, from `herdr api schema` (0.8.2)
third_party/                 reference clones (not part of the build)
.agents/skills/              Flutter + Dart skills (flutter/agent-plugins) and
                             design/motion skills (emilkowalski/skills)
```

Architecture follows the `flutter-apply-architecture-best-practices` skill:
views → `ChangeNotifier` view models → repositories → services.

## Develop

Requires Flutter ≥ 3.47 (Dart ≥ 3.13).

```bash
cd app
flutter pub get
flutter analyze
flutter test                 # unit tests
flutter run                  # device / emulator
flutter run -d linux         # desktop, handy for iterating
```

### Reference clones

`third_party/` is git-ignored. To recreate it (read-only references used while
building the app; not build inputs):

```bash
cd third_party
git clone https://github.com/herdrdev/herdr
git clone https://github.com/dcolinmorgan/herdr-remote
git clone https://github.com/jerryfane/herdrup
git clone https://github.com/flutter/agent-plugins
git clone https://github.com/emilkowalski/skills
```

### Android release build

```bash
export ANDROID_HOME=/path/to/android-sdk   # platforms;android-36, build-tools;36.0.0
cd app
flutter build apk --release --split-per-abi
```

Release signing reads `app/android/key.properties` (git-ignored):

```properties
storeFile=/abs/path/release.jks
storePassword=…
keyAlias=herdr-mobile
keyPassword=…
```

Without it the build falls back to the debug key, which is fine for
`flutter run --release` but must not be published. Keep the keystore backed up:
an update only installs over an earlier release if it is signed with the same key.

### Requirements on each remote machine

- sshd reachable from the phone (LAN, VPN or tailnet recommended).
- herdr running. herdr ≥ 0.9 is best; older builds need `socat` or `python3`
  and use the default session unless you set the socket path in *Advanced*.

### Known limits

- Windows herdr hosts are not supported (the bridge is a POSIX shell script).
- Pane output is read-only text: no cursor or mouse, and one screenful of
  scrollback (the last 300 lines).
- Private keys are pasted in; there is no file picker yet.
- Push notifications need a relay and are out of scope; the app updates live
  while open and on resume.
