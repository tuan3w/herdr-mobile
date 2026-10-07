# Development

## Setup

Requires Flutter ≥ 3.47 (Dart ≥ 3.13) with `flutter` on `PATH`.

## Commands

```bash
cd app
flutter pub get
flutter analyze
flutter test                 # unit tests
flutter run                  # device / emulator
flutter run -d linux         # desktop, handy for iterating
```

`tool/check.sh [--quick]` runs pub get, analyze and the tests in one command
(`--quick` skips the tests); run it before yielding. It uses `flutter` from
`PATH`; set `HERDR_FLUTTER_BIN` to an SDK's `bin` directory to override.
The tests run one file per core (`flutter test -j`, whose default is half the
cores: most files wait on processes and timers, so half left the CPU idle);
`HERDR_TEST_JOBS` overrides. A keeper test file stays under ~30 s so none of
them ends the run waiting alone: split a file that grows past that.

## Code layout

```
app/lib/
  main.dart, boot.dart  start-up: system bars, stores the first frame needs,
                        loaded before runApp
  app.dart              app root: routes, theme, edge-to-edge wrapper, deep
                        links, KeyboardFrames
  data/
    app_info.dart   version shown in Settings > About (repeats pubspec.yaml;
                    test/app_info_test.dart fails when they disagree)
    models/         herdr_models.dart (and its wire field lists),
                    machine_profile.dart, pane previews, remote files, slash
                    commands
    acp/            Agent Client Protocol client, pure Dart: JSON-RPC over
                    newline-delimited JSON, models, the session reducer;
                    background/ (background jobs), subagents/, turns/
                    (a transcript as turns, changes, diffs)
    decision/       pure rules for what the person is asked to judge: mode
                    danger, permission evidence, text hygiene, composer chips
    observed/       observed sessions: an agent in a herdr pane (omp first)
                    shown as a chat, read from its own session log
    streaming/      when a session flushes to its listeners, and RevealPacer
                    (how much arrived text to show now)
    services/       transports: herdr_transport.dart (interface),
                    ssh_transport.dart, isolate_transport.dart,
                    transport_factory.dart, mux_client.dart (persistent
                    request channel, frame reader), bridge_command.dart
                    (remote scripts: bridge, mux, events); herdr_api.dart;
                    the keeper (keeper_script.dart, keeper_command.dart,
                    ssh_agent_host.dart); SFTP (sftp_files.dart,
                    remote_files.dart); images and the phone's gallery;
                    notifications (local_notifier.dart, task_mover.dart);
                    caches (snapshot_cache.dart, transcript_cache.dart,
                    thumb_cache.dart); network_monitor.dart
    repositories/   machine_repository.dart   saved machines + secrets
                    machine_connection.dart   one machine: snapshot + reconnect
                    fleet_repository.dart     all machines, merged agent list
                    agent_session_repository.dart, acp_agent_session.dart,
                    observed_session(s).dart  agent sessions
                    app_settings.dart, terminal_settings.dart,
                    notification_settings.dart, agent_screens.dart, ...
                                              saved settings and state
                    command_risk.dart, prompt_detector.dart, slash_catalog.dart,
                    batch_actions.dart, host_inbox.dart, session_launcher.dart,
                    attention_notifier.dart, ...
  ui/
    core/           design system (tokens, theme, motion, controls, rows,
                    glyphs, chrome, status_panel), the terminal view (ansi.dart,
                    terminal_document.dart, a cell grid with backgrounds and box
                    drawing painted per row, snapped to device pixels:
                    terminal_cells.dart, box_drawing.dart; line_wrap.dart,
                    table_lines.dart, terminal_links.dart, pinch to zoom),
                    markdown/ (the chat's Markdown), keyboard_frames.dart,
                    deep_link.dart
    features/       views + view models, one folder per screen family:
                    agents/          the board, batch actions, opening an
                                     agent and switching between agents
                                     (agent_navigation.dart: openAgent, the
                                     Show terminal / Show chat row;
                                     agent_swipe.dart)
                    agent_session/   an agent (ACP) session: transcript,
                                     composer, permission and question docks
                    attach/          the attach sheet
                    create/          new agent session, machine actions
                                     (rename, close), start-form helpers
                    files/           SFTP file browser and viewer
                    history/         past sessions of an agent
                    machines/        machine list and form
                    pane/            a terminal pane: the bar (pane_bar.dart),
                                     key row, slash palette, answer dock
                    photos/          the one photo viewer
                    settings/
    shell/          home_shell.dart (the three root tabs: Agents, Machines,
                    Settings, floating tab bar), arrival_cue.dart (one haptic
                    when another agent starts waiting)
app/test/                    unit and widget tests; support/ (fakes, shot.dart),
                             fixtures/ (prompts, traces, omp_logs)
app/benchmark/               benchmarks: transfer_bench.dart (bytes on the wire,
                             fake_herdr.py), pane_bench.dart, startup_bench.dart,
                             session_open_bench.dart (+ session_open_aot.dart,
                             open_cache_bench_test.dart,
                             session_open_wire_bench_test.dart: bytes and round
                             trips of an open, any desktop;
                             observed_open_bench_test.dart: the same for a chat
                             of an agent in a herdr pane), upload_bench.dart,
                             upload_real_bench.dart, background_bench_test.dart
                             (virtual time); on a phone:
                             keyboard_device_bench.dart, stream_device_bench.dart
app/screenshot_test/         demo fleet rendered for docs/screenshots
autoresearch.sh              battery and network of watching agents (no phone)
autoresearch-open.sh         open-a-chat time on slow links, modelled (no phone)
autoresearch-keyboard.sh     keyboard bench on a phone (adb)
autoresearch-stream.sh       streaming bench on a phone (adb)
docs/GUIDE.md                using the app
docs/ARCHITECTURE.md         how the app is put together
docs/DESIGN.md               the design system
docs/AGENT_SESSIONS.md       terminal sessions and ACP agent sessions, the keeper
docs/ALERTS.md               local notifications, and the optional ntfy host plugin
docs/ENGINEERING.md          per-subsystem facts
docs/herdr-api.schema.json   protocol schema, from `herdr api schema` (0.8.2)
docs/screenshots/            store screenshots (tool/screenshots/run.sh)
tool/check.sh                analyze + tests
tool/capture-prompt.sh       capture a prompt fixture from a real screen
tool/capture-trace.sh        capture an agent trace (capture_trace.py)
tool/trace_cadence.py        rewrites the traces' CADENCE.md
tool/screenshots/            renders and frames the store screenshots
tool/md-bench/               Markdown engine bench-off, not part of the app
tool/plugins/herdr-ntfy/     optional herdr plugin: posts to ntfy when an agent needs you
.agents/skills/              the project's own skills: herdr-design, herdr-motion,
                             herdr-screen-check (and skill-creator)
```

Architecture: views → `ChangeNotifier` view models → repositories → services.

## Screenshots

`tool/screenshots/run.sh` regenerates `docs/screenshots/*.png`: it renders the
demo fleet (`app/screenshot_test/store_shots_test.dart`) through the real
widgets (real fonts, phone-sized surface, light and dark), then frames each
render in a device mock-up with a headline (`tool/screenshots/compose.py`).
Needs Flutter on `PATH` and Pillow (`pip install pillow`).

## Agent hooks

In `.omp/hooks/`:

- `post/dart-analyze.ts` — after `edit`/`write`/`ast_edit` touches a `.dart`
  file under `app/`, runs `dart analyze` on it and feeds findings back as
  context. Silent when clean. Never formats (would break edit anchors). Uses
  `dart` from `HERDR_FLUTTER_BIN` when set, else from `PATH`.

## Android release build

```bash
export ANDROID_HOME=/path/to/android-sdk   # platforms;android-36, build-tools;36.0.0
cd app
flutter build apk --release --target-platform android-arm,android-arm64
```

Release signing reads `app/android/key.properties` (git-ignored):

```properties
storeFile=/abs/path/release.jks
storePassword=…
keyAlias=herdr-mobile
keyPassword=…
```

Without it a release or profile build **fails** (it used to fall back to the
debug key, which made APKs that look like releases but cannot update the real
app). For a build you will not publish, pass
`--android-project-arg=allowDebugSigning=true`; the benchmark builds
(`appIdSuffix`) are exempt because they install beside the real app. Keep the
keystore backed up: an update only installs over an earlier release if it is
signed with the same key.
