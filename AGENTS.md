# herdr-mobile — agent notes

Flutter client for herdr. Read `README.md` first for architecture and layout.

## Skills

Flutter and Dart skills from `flutter/agent-plugins` are installed in
`.agents/skills/` (see `skills-lock.json`). Use them:
`flutter-apply-architecture-best-practices` before structural changes,
`flutter-add-widget-test` / `dart-add-unit-test` before adding tests,
`flutter-fix-layout-issues` for overflow errors.
Upstream source is cloned at `third_party/agent-plugins`.

Design/motion skills from `emilkowalski/skills` (clone: `third_party/skills`)
set the quality bar for UI. Both sets are pinned to their GitHub sources in
`skills-lock.json`; refresh with `npx skills add <owner/repo> --skill '*' --agent universal --yes`.

| Use for | Skill |
| --- | --- |
| Any UI polish or critique; the main bar | `emil-design-eng` |
| Motion decisions, then strict review | `animate`, `review-animations` |
| Audit existing motion / find where motion belongs | `improve-animations`, `find-animation-opportunities` |
| Precise wording when describing motion | `animation-vocabulary` |
| Fluid-motion and interface principles | `apple-design` |
| Worst-case data (long names, huge counts, empty lists) | `break-ui` |
| Touch feel, safe areas, "test on real hardware" | `mobile-native` (principles only) |
| Performance rules of thumb | `third_party/skills/performance-cheatsheet.md` |

These skills are written for web (CSS, React). Translate, don't copy:
`cubic-bezier(0.23, 1, 0.32, 1)` → `Cubic(0.23, 1, 0.32, 1)`; animate
transform/opacity (`AnimatedScale`, `FadeTransition`, `SlideTransition`), not
layout; virtualize long lists (`ListView.builder`); isolate repaints with
`RepaintBoundary`; UI motion stays under ~300 ms; never animate frequent or
keyboard-driven actions.

Not applicable to this Flutter app: `animate-expo` (React Native),
`write-swift`, `pick-ui-library` and `ask-sonner` (web libraries). The
installed `prototype` skill shares its name with a global `prototype` skill;
check which one loads before relying on it.

## Rules of the road

- Layering is strict: `ui/` → view models → `data/repositories` →
  `data/services`. Widgets never touch transports.
- herdr's socket takes **one request per connection** and `events.subscribe`
  is the only long-lived herdr channel. Latency comes from not paying a
  connection per request: `SshTransport` multiplexes requests over one
  persistent channel (`mux_client.dart`) and falls back to a channel per
  request only when the mux is unavailable. Never open a channel per call in
  new code.
- **Wire format** (`bridge_command.dart`, `mux_client.dart`): the remote mux
  script deflates answers over 512 B (`Z<n>\n` + n zlib bytes), cuts snapshots,
  pane reads and events to the fields the models read (`muxProjections`,
  `eventProjection`, built from `snapshotWireFields`/`paneWireFields` in
  `herdr_models.dart`: add a field there when a `fromJson` starts reading it;
  `herdr_models_test.dart` fails otherwise), and answers a `pane.read` with row
  deltas against the answer the client names in `mux_have`. Event subscriptions
  use `buildEventsCommand` (one zlib stream, `E<n>` frames) and fall back to
  the bridge on exit 78. `benchmark/transfer_bench.dart` measures it; its fake
  herdr is `benchmark/fake_herdr.py`. Never read the SSH channel's stream with
  `await for`/`async*`: the pause per chunk cost 40 ms per round trip.
- Every `HerdrTransportException` must say whether it is `fatal`; fatal means
  stop retrying and surface `LinkState.attention`.
- Remote commands are built in `bridge_command.dart`. Anything interpolated
  into the remote shell (session name, socket path) must stay validated or
  quoted; there are tests for injection.
- Event handling is a **throttle**, not a debounce — busy agents emit events
  continuously (see `machine_connection_test.dart`).
- Every `events.subscribe` entry must be valid without parameters: herdr
  rejects the WHOLE subscription if one is invalid (`pane.agent_status_changed`
  needs a `pane_id`), which makes the connection flap. `herdr_api_test.dart`
  checks the list against the schema.
- Releases ship ONE universal ARM APK. The `+N` build number in `pubspec.yaml`
  is the Android versionCode: it must only increase and stay above 4002 (the
  highest code the old per-ABI APKs used), or Android refuses the update as a
  downgrade ("App not installed").
- **Version line is fixed at 0.4.x.** Ship changes as patch bumps only
  (0.4.1, 0.4.2, ...): never bump the minor or major (no 0.5.0, 1.0.0)
  unless the owner says so. Each release still increments `+N` by one.
- **UI-thread budget.** The pane must stay smooth while an agent streams ~140 KB
  per refresh. Network, crypto and JSON decoding belong in the transport
  isolate (`IsolateTransport`, created only through `createSshTransport`);
  never construct `SshTransport` on the main isolate. Keep cipher preference in
  `sshAlgorithms` (GCM is ~30x slower in dartssh2); `ssh_algorithms_test.dart`
  guards it. Never add a looping animation (they keep the GPU busy forever and
  cost battery); the only exception is `BusySpinner` (`ui/core/controls.dart`)
  for work the user is actively waiting on (a saving/testing button, a send in
  flight; it must stop when the work does). A working agent's `StatusGlyph` is
  a still half ring; `step_clock.dart` only drives the minute labels. Avoid
  `Opacity`/`AnimatedOpacity`/`FadeTransition` at
  opacity 1: each is a composited layer (wrap only when actually dimmed).
- **Measure on a phone, not a desktop.** Frame stalls only showed up on a real
  device: profile build (`flutter build apk --profile`), real touch input
  (`adb shell input swipe`), and a controllable load, e.g. a herdr pane running
  a script that streams coloured output. `build.gradle.kts` signs profile builds
  with the release key so they install over the shipped app.
- Android builds opt out of Impeller (`AndroidManifest.xml`) because it measured
  slower than Skia on a Mali-G72 phone. Do not remove that without re-measuring.
- **Design system, not Material.** UI is built from `ui/core/` (`tokens`,
  `controls`, `rows`, `glyphs`, `chrome`, `status_panel`; see `docs/DESIGN.md`).
  Do not use `Card`, `ListTile`, `ExpansionTile`, `NavigationBar`, FAB,
  Material buttons, `SegmentedButton`, `AlertDialog`, `PopupMenuButton`,
  `AppBar`, `InkWell` or `Icons.*` in `lib/ui`; colours come from `context.ds`,
  text from `Type.*`, icons from Lucide. Text uses `textSecondary` or
  `textMuted` (both >= 4.5:1), never `textTertiary` (icons and rings only);
  status words use `blockedText`/`dangerText`. Every touch target is >= 44dp
  (`PressBuilder.minTapSize`; chip rows are `AppChip.height`). Semantics: leave
  `semanticLabel` null where the child already has text (it merges into one
  node), set it only for icon-only controls, and mark titles as headers (see
  DESIGN.md "Semantics"). Check a screen by rendering it with
  `test/support/shot.dart` in light and dark, with worst-case data (long names,
  one item, zero items, Vietnamese diacritics), and look at the PNG.
- **Keys are not a send.** `PaneViewModel.sendKeys` never sets `sending` (a
  tapped hotkey must not disable the key row) and keeps calls in order; only
  `sendLine` is a tracked send. Ctrl/Alt are one-shot latches (`StickyModifiers`,
  `key_modifiers.dart`): `ModifierTypingFormatter` turns the next typed
  character into a chord and keeps it out of the field. herdr's key names have
  no home/end/pgup/pgdn/delete (`parse_key_combo`); `pane.send_text` is the raw
  route for those. `pane.send_input` brackets text when the pane asks, so a
  newline in the composer does not submit.
- **Edge to edge.** `main()` enables `SystemUiMode.edgeToEdge` and `app.dart`
  wraps every route in one `AnnotatedRegion` using `AppTheme.systemBars`. Do not
  use Flutter's stock `SystemUiOverlayStyle.light/dark` (no status bar colour:
  OEM grey shows through; forces a black navigation bar). Lists with an explicit
  `padding:` on pushed screens must add `MediaQuery.paddingOf(context).bottom`
  themselves (only default-padded lists get the inset automatically). The same
  builder wraps routes in `SafeArea(top: false, bottom: false)` for the side
  insets, so screens never handle left/right themselves.
- The manifest sets `android:enableOnBackInvokedCallback="true"` (predictive
  back). Flutter 3.47 routes the system back gesture through the framework, and
  our Cupertino page transition is driven by it. Not verified on a device; if
  back swipes misbehave, remove it first.
- **Pane width is not ours to set.** herdr's socket API has no size parameter
  (`pane.resize` only moves split ratios). Geometry belongs to the *clients*:
  the server sizes a tab to the client that views or claims it
  (`tab_geometry_controllers` in `third_party/herdr/src/server/headless/
  client_views.rs`, otherwise the foreground client's terminal size), and a
  client announces its size in the endpoint handshake (`surface_size`,
  `src/protocol/endpoint.rs`, a JSON "client-owned shell" contract, generation 1,
  documented as stable for Local/SSH/Cloud). Attaching as such a client would
  re-lay the tab out for the phone's width, and would resize it for a desktop
  viewer of the same tab; it means speaking the shell surface protocol, a
  different architecture from the socket + `pane.read` one used here. Phone
  width is handled client-side: pinch zoom, and a wrap mode that re-flows
  `recent_unwrapped` reads but leaves table and box rows whole
  (`table_lines.dart`; the view then scrolls sideways for them).
- **A pane is drawn in the theme's colours.** The ANSI parser always yields
  `TerminalColors` (dark) values; `TerminalPalette.recolor` maps them to the
  palette of the theme (`context.terminal`, light on paper unless Settings >
  Dark terminal) when a row is prepared, so the dark palette costs nothing.
- **State that survives a launch**: theme and last root tab (`AppSettings`),
  terminal font and wrap (`TerminalSettings`), open pane tabs, their order,
  the active one and whether the tab screen was open (`OpenTabs` with
  `PrefsOpenTabsStore`, loaded in `main()`; the app puts the tab screen back
  in front once). Load such state before `runApp`.
- **Keyboard animation = one relayout per frame, no rebuilds.** The host
  `Scaffold` resizes the pane every frame of the IME animation. Nothing under
  it may rebuild for a height change: `TerminalView` hands its `LayoutBuilder`
  the same cached body unless the width or row env changed (test in
  `terminal_view_test.dart`). Never read `box.maxHeight` in that builder, and
  never make the pane depend on `viewInsets` (`CompactScope` is the one
  exception and only notifies when its answer flips). `chat_bottom_container`
  was evaluated and not adopted: it swaps the keyboard with a custom panel
  (fixed placeholder height, remembered IME height); its Android half is a
  closed, obfuscated jitpack AAR that only reports the final IME height. It does
  nothing for plain keyboard open/close, which is what costs us.
- **Scrollback is capped by herdr, not by us.** `pane.read` clamps `lines` to
  1000 rows server-side (measured on 0.8.2; `lines.min(1000)` in source) even
  when the pane holds thousands, and the read runs on herdr's main loop (~5 ms,
  ~245 KB for 1000 ANSI rows). `pane.scroll` + `visible` does NOT page history
  (visible ignores the offset) and would move the desktop user's view: never use
  it. The pane view therefore tails 300 rows, reads 1000 only on demand while
  the user is scrolled near the top (relaxed cadence), and keeps rows that
  scroll off in memory (`ScrollbackHistory`, capped) while the screen is open.
  `TerminalDocument` (incremental, per-line memo) replaced `AnsiParser`/`WrapMemo`.
- **Never probe a live herdr with mutating methods and empty params**: an empty
  `tab.create` really creates a tab. Use scratch workspaces with a real label,
  `focus: false`, and close them. herdr answers an unknown method with
  `"id":""`; the mux restores the request id (test in `bridge_command_test.dart`).
- **Files are SFTP, never a shell.** File access goes through the transport
  isolate (`statFile/listDirectory/readFile/realPath`, `SftpFiles`), reads are
  clamped to 8 MB per call, bytes cross the isolate as `TransferableTypedData`.
  A host without the sftp subsystem is reported as `unsupported` after a short
  handshake timeout. Remote paths are never interpolated into a shell command;
  the one exception is the new-session launcher's `cd`, which quotes every
  segment and is injection-tested.
- **Links in terminal output**: http(s) URLs and file paths are detected per
  line (`terminal_links.dart`), underlined, and a plain tap opens a sheet (URL:
  open/copy, localhost-type addresses copy-only) or the file viewer. Plain
  `http` is only opened from an explicit tap that shows the URL; the sign-in
  banner path stays https-only.
- **New sessions** = new workspace (+ optional agent command typed into its
  root pane). Named herdr sessions (separate server namespaces) cannot be
  created through the socket API. Launch works on every herdr version (no
  `agent.start` dependency); older servers answer unknown methods with
  `HerdrUnsupportedException`.
- Reference clients in `third_party/` (herdr-remote, herdrup) and herdr source
  (`third_party/herdr`) are read-only references, not build inputs.
- Protocol facts: `docs/herdr-api.schema.json` (`herdr api schema`).

## Commands

```bash
export PATH=/media/fatman/data/sdks/flutter/bin:$PATH
cd app && flutter analyze && flutter test
```

## Agent hooks (`.omp/hooks/`)

- `post/dart-analyze.ts` — after `edit`/`write`/`ast_edit` touches a `.dart`
  file under `app/`, runs `dart analyze` on it and feeds findings back as
  context. Silent when clean. Never formats (would break edit anchors).
- `pre/readonly-paths.ts` — blocks edits under `third_party/` and
  `.agents/skills/`.
- `tool/check.sh [--quick]` — analyze + tests in one command; run before
  yielding. Flutter SDK is found via `HERDR_FLUTTER_BIN` or the default
  `/media/fatman/data/sdks/flutter/bin`.
