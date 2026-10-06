# Engineering notes

The facts each subsystem depends on, most of them learned the hard way.
AGENTS.md holds the principles; this file holds the specifics. When you change
a subsystem, update its section in the same change.

## Layering and isolates

- Layering: `ui/` → view models → `data/repositories` → `data/services`.
  Widgets never touch transports. The one exception is the machine form's
  Test, whose view model builds a transport for a profile that isn't saved
  yet (`machine_form_view_model.dart`).
- The pane must stay smooth while an agent streams ~140 KB per refresh.
  Network, crypto and decoding herdr's API answers belong in the transport
  isolate (`IsolateTransport`, created only through `createSshTransport`);
  never construct `SshTransport` on the main isolate. ACP and keeper lines
  are decoded on the UI isolate, in batches (`json_rpc.dart`,
  `ssh_agent_host.dart`).
- Keep cipher preference in `sshAlgorithms` (GCM is ~30x slower in dartssh2);
  `ssh_algorithms_test.dart` guards it.

## Design system

Not Material. UI is built from `ui/core/` (`tokens`, `controls`, `rows`,
`glyphs`, `chrome`, `status_panel`); the system is written up in
`docs/DESIGN.md`.

- Do not use `Card`, `ListTile`, `ExpansionTile`, `NavigationBar`, FAB,
  Material buttons, `SegmentedButton`, `AlertDialog`, `PopupMenuButton`,
  `AppBar`, `InkWell` or `Icons.*` in `lib/ui`. Colours come from `context.ds`,
  text from `Type.*`, icons from Lucide.
- Text uses `textSecondary` or `textMuted` (both >= 4.5:1), never
  `textTertiary` (icons and rings only); status words use
  `blockedText`/`dangerText`.
- Every touch target is >= 44dp (`PressBuilder.minTapSize`; chip rows are
  `AppChip.height`).
- Semantics: leave `semanticLabel` null where the child already has text (it
  merges into one node), set it only for icon-only controls, and mark titles
  as headers (see DESIGN.md "Semantics").
- Check a screen by rendering it with `test/support/shot.dart` in light and
  dark, with worst-case data (long names, one item, zero items, Vietnamese
  diacritics), and look at the PNG.

## Transport and wire format

- herdr's socket takes **one request per connection** and `events.subscribe`
  is the only long-lived herdr channel. Latency comes from not paying a
  connection per request: `SshTransport` multiplexes requests over one
  persistent channel (`mux_client.dart`) and falls back to a channel per
  request only when the mux is unavailable. Never open a channel per call in
  new code.
- **Wire format** (`bridge_command.dart`, `mux_client.dart`):
  - The remote mux script deflates answers over 512 B (`Z<n>\n` + n zlib
    bytes).
  - It cuts snapshots, pane reads and events to the fields the models read
    (`muxProjections`, `eventProjection`, built from
    `snapshotWireFields`/`paneWireFields` in `herdr_models.dart`): add a field
    there when a `fromJson` starts reading it; `herdr_models_test.dart` fails
    otherwise; `paneReadWireFields` likewise.
  - It answers a `pane.read` or `session.snapshot` with row deltas against the
    answer the client names in `mux_have` (a snapshot always travels as rows,
    and the client must keep the script's own row strings: the ops index into
    them).
  - Requests go up as `Q<n>` frames of one zlib stream (`MuxRequestEncoder`,
    used by the SSH channel; the script also takes plain lines).
  - Event subscriptions use `buildEventsCommand` (one zlib stream, `E<n>`
    frames) and fall back to the bridge on exit 78.
  - `benchmark/transfer_bench.dart` measures it; its fake herdr is
    `benchmark/fake_herdr.py`.
- Never read the SSH channel's stream with `await for`/`async*`: the pause per
  chunk cost 40 ms per round trip. Read lines with `splitLines`.
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
- **Never probe a live herdr with mutating methods and empty params**: an empty
  `tab.create` really creates a tab. Use scratch workspaces with a real label,
  `focus: false`, and close them. herdr answers an unknown method with
  `"id":""`; the mux restores the request id (test in
  `bridge_command_test.dart`).

## Frames, motion and haptics

- Never add a looping animation (they keep the GPU busy forever and cost
  battery). The only exception is `BusySpinner` (`ui/core/controls.dart`) for
  work the user is actively waiting on (a saving/testing button, a send in
  flight; it must stop when the work does).
- `KeyboardFrames`' ticker is not a loop: it lives only while the keyboard
  moves (test in `keyboard_frames_test.dart`).
- A `StatusGlyph` is still at rest and settles once (`Motion.settle`, then its
  ticker stops) when its status changes on screen; `step_clock.dart` only
  drives the minute labels.
- Haptics go through `Haptics` (`tick/hold/sent/armed/failed` in
  `ui/core/motion.dart`), never `HapticFeedback` directly.
- Avoid `Opacity`/`AnimatedOpacity`/`FadeTransition` at opacity 1: each is a
  composited layer (wrap only when actually dimmed).
- **Measure on a phone, not a desktop.** Frame stalls only showed up on a real
  device: profile build (`flutter build apk --profile`), real touch input
  (`adb shell input swipe`), and a controllable load, e.g. a herdr pane running
  a script that streams coloured output. `build.gradle.kts` signs profile
  builds with the release key so they install over the shipped app.
- Android builds opt out of Impeller (`AndroidManifest.xml`) because it
  measured slower than Skia on a Mali-G72 phone. Do not remove that without
  re-measuring.

## Keyboard

### One relayout per frame, no rebuilds

The host `Scaffold` resizes the pane every frame of the IME animation. Nothing
under it may rebuild for a height change: `TerminalView` hands its
`LayoutBuilder` the same cached body unless the width or row env changed (test
in `terminal_view_test.dart`). Never read `box.maxHeight` in that builder, and
never make the pane depend on `viewInsets` (`CompactScope` is the one exception
and only notifies when its answer flips). `AnswerDock` (a blocked pane's
question and answers above the key row) is built once by the page and reads no
`viewInsets`; keep it that way.

`chat_bottom_container` was evaluated and not adopted: it swaps the keyboard
with a custom panel (fixed placeholder height, remembered IME height); its
Android half is a closed, obfuscated jitpack AAR that only reports the final
IME height. It does nothing for plain keyboard open/close, which is what costs
us.

### The engine bug and the workaround

On Android 11-14 (API 30-34), Flutter 3.44+ (still in 3.47.6) takes the
navigation bar's height off every animated IME inset unless the window has
`SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION` or `HIDE_NAVIGATION`; `edgeToEdge` now
clears both (`setSystemUiVisibility(0)` + `setDecorFitsSystemWindows(false)`)
and the inset reported once the keyboard settles keeps the bar. The pane ran
48 dp low for the whole opening and snapped on the last frame
(flutter/flutter#190974, #191094).

`MainActivity` keeps the flag set on API 30-34 only (the engine installs the
sync at 30 and stops subtracting at 35; a layout listener and `onPostResume`:
Flutter clears it at start-up and on every resume); it changes no layout, the
window is already under the bar. Remove it when an engine with the fix ships,
and check that `snap_dp` stays ~0.

The "KeyboardAnimationBuilder" hack (a Medium post) pads from the same
`viewInsets` and clamps to a cached height (286.9 on Android, this phone's
short value), which hides the snap and leaves the field 48 dp low;
`flutter_keyboard_controller` (native `WindowInsetsAnimationCompat`) was not
needed once `snap_dp` read 0.8.

### Asking for the keyboard

The composer asks for the keyboard on pointer-down (`_showKeyboard`, test in
`pane_screen_test.dart`): the keyboard app needs ~280 ms from the request to
the first movement, and the finger's press (typically ~100 ms) was pure
waiting. The rest of that wait is the keyboard app's (a bare `TextField` waits
the same on a Samsung Keyboard): do not chase it in the pane.

### KeyboardFrames

Android reports the keyboard once per vsync (~17 positions per opening), but
the frame that an update asks for came a vsync late about every second time,
so 8 of 17 positions were never drawn: the layout stepped at 30 Hz under a
keyboard moving at 60 Hz, and the composer trailed it by 20-26 dp in 6 of 10
recorded openings (the screen recording shows it behind the keyboard for a
frame or two).

`KeyboardFrames` (`ui/core`, mounted once in `app.dart`) keeps a ticker running
while `viewInsets.bottom` changes and for 120 ms after, so the vsync is already
armed: 0 of 17 skipped, and 8 of 11 recorded openings kept the composer within
0.6 dp of its place on every frame (two trailed by 4-8 dp, one started two
frames late and trailed by 25). The cost is drawing at 60 fps while the
keyboard moves: raster p95 of a busy pane went 8.8 -> 14.3 ms (budget 16.7, max
15.2): watch it on slower GPUs. `DartPerformanceMode.latency` while the field
is focused measured nothing.

### `./autoresearch-keyboard.sh` measures the keyboard on a phone

adb to a real device; the header says how, Wi-Fi works and it finds the phone
again when Wireless debugging changes port. It builds the real app tree over an
in-memory herdr as `dev.herdrmobile.herdr_mobile.kbbench`, beside the shipped
app, taps the composer in-app and logs, per keyboard animation, the inset the
layout obeys (`max(viewInsets, viewPadding).bottom`, since the composer sits
above the navigation bar) and build/raster time of every frame
(`app/benchmark/keyboard_device_bench.dart`). `KB_CONTROL=1` runs a bare
`TextField` instead: whatever it shows is not this app's UI. This LAN isolates
Wi-Fi clients (phone to PC and back time out), so the phone is reached over
Tailscale.

## Terminal pane

- **Pane width is not ours to set.** herdr's socket API has no size parameter
  (`pane.resize` only moves split ratios). Geometry belongs to the *clients*:
  the server sizes a tab to the client that views or claims it
  (`tab_geometry_controllers` in herdr's
  `src/server/headless/client_views.rs`, https://github.com/herdrdev/herdr; otherwise the
  foreground client's terminal size), and a client announces its size in the
  endpoint handshake (`surface_size`, `src/protocol/endpoint.rs`, a JSON
  "client-owned shell" contract, generation 1, documented as stable for
  Local/SSH/Cloud). Attaching as such a client would re-lay the tab out for the
  phone's width, and would resize it for a desktop viewer of the same tab; it
  means speaking the shell surface protocol, a different architecture from the
  socket + `pane.read` one used here. Phone width is handled client-side: pinch
  zoom, and a wrap mode that re-flows `recent_unwrapped` reads but leaves table
  and box rows whole (`table_lines.dart`; the view then scrolls sideways for
  them).
- **A pane is drawn in the theme's colours.** The ANSI parser always yields
  `TerminalColors` (dark) values; `TerminalPalette.recolor` maps them to the
  palette of the theme (`context.terminal`, light on paper unless Settings >
  Dark terminal) when a row is prepared, so the dark palette costs nothing.
- **Scrollback is capped by herdr, not by us.** `pane.read` clamps `lines` to
  1000 rows server-side (measured on 0.8.2; `lines.min(1000)` in source) even
  when the pane holds thousands, and the read runs on herdr's main loop (~5 ms,
  ~245 KB for 1000 ANSI rows). `pane.scroll` + `visible` does NOT page history
  (visible ignores the offset) and would move the desktop user's view: never
  use it. The pane view therefore tails 300 rows, reads 1000 only on demand
  while the user is scrolled near the top (relaxed cadence), and keeps rows
  that scroll off in memory (`ScrollbackHistory`, capped) while the screen is
  open. `TerminalDocument` (incremental, per-line memo) replaced
  `AnsiParser`/`WrapMemo`.
- **Links in terminal output**: http(s) URLs and file paths are detected per
  line (`terminal_links.dart`), underlined, and a plain tap opens a sheet (URL:
  open/copy, localhost-type addresses copy-only) or the file viewer. Plain
  `http` is only opened from an explicit tap that shows the URL; the sign-in
  banner path stays https-only.
- **Keys are not a send.** `PaneViewModel.sendKeys` never sets `sending` (a
  tapped hotkey must not disable the key row) and keeps calls in order; only
  `sendLine` is a tracked send.
  - Ctrl/Alt are one-shot latches (`StickyModifiers`, `key_modifiers.dart`):
    `ModifierTypingFormatter` turns the next typed character into a chord and
    keeps it out of the field.
  - herdr's key names have no home/end/pgup/pgdn/delete (`parse_key_combo`);
    `pane.send_text` is the raw route for those.
  - `pane.send_input` brackets text when the pane asks, so a newline in the
    composer does not submit.
- **Slash palette** (`SlashCatalog`, `SlashViewModel`, `SlashPalette`).
  - Shown only for a lone `/word` in an agent pane's composer, loaded on the
    first slash (not at pane open) and re-read after 2 minutes. Hidden in the
    compact (landscape + keyboard) layout.
  - Discovery is SFTP, best effort, never throws.
  - The built-in tables are hand-written per herdr agent label and WILL drift
    from the agents: they only fill the composer, the agent decides on send.
    Add agents to `builtInSlashCommands` and to `SlashCatalog._project/_user`
    (folders) only after checking the agent's own docs.
  - Usage and pins live in `SlashUsage` (`slashUsage.v1` prefs, 40 per agent,
    keyed by lower-case agent label): a bare `/` lists pinned, then the 5 most
    recent, then the catalog, and names the catalog lacks still complete, so an
    agent with no table (omp, pi, ...) still gets a palette.

## Files, photos and attach

### Files are SFTP, never a shell

- File access goes through the transport isolate
  (`statFile/listDirectory/readFile/realPath`, `SftpFiles`). Reads are clamped
  to 8 MB per call (a larger file is read in pieces: `readAll`, which the photo
  viewer calls with 2 MB pieces up to 40 MB, progress and a `ReadCancel`);
  bytes cross the isolate as `TransferableTypedData`.
- A host without the sftp subsystem is reported as `unsupported` after a short
  handshake timeout.
- A remote path reaches a shell only as a validated, single-quoted word: the
  keeper's working folder and follow-log path (`keeper_command.dart`), the
  socket path (`bridge_command.dart`) and the sign-in terminal's `cd`
  (`session_launcher.dart`). Each is injection-tested.
- File screens are pushed BEFORE the host is asked (never `await` SFTP ahead
  of a `push`), one `FileBrowserSession` per walk owns the stack (a breadcrumb
  pops, it never pushes) and the shared options, the viewer polls the file's
  mtime only while it is the screen in front, and thumbnails read at most 3
  files at a time; see `docs/DESIGN.md` "Files".

### Upload

Sending a phone file TO the host is `RemoteFiles.upload` (`makeDirs`,
`remove`, `UploadJob`): read and written inside the transport isolate, only
paths and counters (every 100 ms) cross, one SFTP channel shared with browsing
(the write window shrinks while a listing is in flight), 200 MB cap, 2 at a
time, no resume. The target path always comes from `reserveInboxPath`
(`host_inbox.dart`), never from a name the phone or agent supplied; see
`docs/AGENT_SESSIONS.md` "Sending a phone file to the host".

### One photo viewer

`ui/features/photos/`, `docs/DESIGN.md` "Photo viewer". Every picture (file,
chat, attachment chip, folder grid) opens through
`openPhotoViewer`/`photoViewerRoute`; never add a second image screen. Its
gestures are springs that start from the live value and stop when a finger
lands (no timed tweens, no `InteractiveViewer`); the arithmetic lives in
`photo_math.dart` with pure tests. Decode to ~1.5x the screen first and sharpen
on zoom; hold only the open photo and its neighbours.

### One attach sheet

`ui/features/attach/`, `docs/DESIGN.md` "Attach sheet".

- It is NOT a Material bottom sheet: the content is laid out once at full
  height and moved with transforms (`SheetPosition`), so never size a tab from
  the screen, keep a tab's end clear with `SheetScope.bottomClearance`,
  top-align its empty states and use `SheetScroll` for its scroll view.
- Selection lives in ONE `AttachTray` shared by the tabs; tiles listen to it
  themselves (no per-tile notifier, no grid rebuild per pick).
- Nothing asks the system for the photo permission except the tap on the
  Gallery panel, nothing queries the library in the background, and the
  gallery's thumbnails go through `ThumbCache` (LRU, evictions evict the
  decoded bitmap).
- A phone file is streamed to the host inbox over SFTP
  (`RemoteFiles.upload`), never read whole into memory.

## Board, prompts and actions

- **One-tap answers show what they approve.** `PromptInfo.subject` is the
  command (or path) the agent asks about: mono on the card, in full in the
  sheet. The confirm gate (`command_risk.dart`) reads only the subject, the
  question, the row above it and the option, never scrollback, and names its
  reason on the chip (`Hold to send · pushes to a remote`): a risky answer is
  HELD (`HoldToConfirm`), a tap only shows the hint. Standing grants ("don't
  ask again", "always allow") always need the hold. The semantic tap
  (TalkBack) keeps a two-step prime-then-send path. It is a hint with gaps,
  never the only safeguard: the command stays visible.
- **Prompt fixtures are captured, not written.** `tool/capture-prompt.sh`
  saves a real screen under `app/test/fixtures/prompts/<agent>/`;
  `UPDATE_EXPECTED=1 flutter test test/prompt_corpus_test.dart` writes the
  `.expected`, which you read against the screen. Agents change their prompts
  weekly; a fixture per layout is how a detector change stays honest.
- **Batch actions** (`BoardSelection`, `batch_actions.dart`,
  `batch_actions_sheet.dart`). Selection state is a small notifier only the
  rows and the two bars listen to; it is not restored after a restart. A
  blocked terminal agent is never typed into unless `Send anyway` is on (off by
  default); a blocked agent session never. The confirm sheet is built from
  live data and keeps updating while open.
- **Launch and stay.** `Start` pops back to the opener with a toast;
  `Start and open` replaces the form. A `Duplicate` prefill (`SessionPrefill`)
  persists nothing until Start.
- **The only workspace the phone starts is the sign-in terminal** (`SessionLauncher`,
  used by `auth_panel.dart`): a new herdr workspace in the agent's folder, a plain
  shell. The phone has no form for starting bare terminal workspaces any more (see
  `docs/DESIGN.md` "Starting and duplicating"). Named herdr sessions (separate
  server namespaces) cannot be created through the socket API. It works on every
  herdr version (no `agent.start` dependency); older servers answer unknown
  methods with `HerdrUnsupportedException`.
- **Deep links.** `DeepLinks` (`ui/core/deep_link.dart`) must be registered
  before the `MaterialApp` builds and it handles every pushed route:
  `herdr://agent/<machine>/<pane>`, `herdr://session/<machine>/<keeper>`,
  `herdr://agents`. It turns the home screen to a tab through `HomeTabs`
  (`ui/core/home_tabs.dart`) and goes back with `maybePop` one route at a
  time, never `popUntil`, so a screen's `PopScope` guard is respected.

## Agent sessions (ACP)

### Two session types

Terminal sessions are herdr panes (screen-scraped prompts). Agent sessions
speak ACP and are the phone-first path; omp is the first route (Claude Code,
Codex and pi have unit coverage only, see `docs/AGENT_SESSIONS.md`, which holds
the design, the routes and the keeper).

Layers:

- `data/acp/` is pure Dart (client, models, reducer; `LiveText` only borrows
  `Listenable` from `flutter/foundation`).
- The keeper (`keeper_script.dart`, python3 on the host, installed once per
  host through `keeperInstallCommand`, then short commands) owns the agent
  process so it survives SSH drops.
- `SshAgentHost` runs keeper commands over exec channels on the machine's ONE
  SSH connection (`HerdrTransport.openExec`, never a second connection).
- `AgentSessionRepository` / `AcpAgentSession` are what screens read through
  the `AgentSessionView` / `AgentSessions` interfaces.

Rules:

- Read lines with `splitLines`, never `await for` an SSH channel.
- The app implements `AcpClientHandler` and nothing may allow a permission
  silently, by default or on a timeout (`AcpAgentSession` answers only through
  `answerPermission`/`answerQuestion`, and cancel/end/dispose answer
  `cancelled`).
- A session detaches 90 s after the app is backgrounded (the keeper keeps the
  agent alive) and the repository's list timer runs only while the Agents tab
  is visible.
- The permission card always shows the command and gates standing grants with
  a hold (`command_risk.dart`).
- `SshTransport` pings only an idle link (25 s in the foreground, 330 s in the
  background profile, 10-15 s timeout) and the mux heartbeats every 8 s (300 s
  in the background, skipped while a real answer came within the interval), so a dead link ends every channel within ~35 s in the
  foreground; a refused channel (sshd `MaxSessions`) fails that channel only,
  never the connection.

### Permission safety

`ui/features/agent_session/`. Every string the person sees or the risk rules
read passes `visibleText()`; a long or overflowing command needs `Read all` or
a hold; a new request ignores taps for 450 ms; nothing is cut silently; links
in agent text show their full URL first. The session list comes from ONE short
`list` per machine (30 s while the board is visible); at most 4 sessions per
machine hold an exec channel (waiting ones first, a screen that is open always
wins), because sshd's `MaxSessions` (default 10) is shared with the mux, events
and SFTP.

### Streaming transcript

`ui/features/agent_session/`, `docs/DESIGN.md` "Agent session screen (ACP)".

- The message that is arriving is the ONE live row (`LiveMessageRow`): a chunk
  appends to its `LiveText` in place and rebuilds that row alone; the
  transcript list is planned again (`TranscriptPlan`, from the first changed
  item) only when `state.items` is a new list.
- Never read the text of a live message through `blocks` per frame (it joins),
  never put a per-chunk `setState` on the transcript view, and keep the settled
  rows pixel-identical to the live row (same widgets, `mdBlockGap`): ending a
  message must not move anything.
- Pacing is `RevealPacer` driven by a `Ticker` that exists only while text is
  held back; it snaps (shows everything, no animation) when the message ends,
  the app resumes, a finger goes down on the transcript, the backlog passes
  8 KB, Smooth text (`AppSettings.smoothText`, Settings > Appearance, on by
  default) is off, or the transcript is hidden; text already there when the
  row first shows is history and is not paced; reduced motion reveals whole
  lines. No fade, no caret, no looping animation.
- The view never moves under a finger and never animates its follow; away from
  the end the chevron becomes `N new` (rows finished since the reader left).
- The transcript is a list of turns (`TranscriptPlan` plans from the first TURN
  that changed; a finished turn folds its log to one line, the answer, the
  Changed card and the exceptions stay; the turn that runs shows its log open;
  see `docs/DESIGN.md` "Turns"): the toggles live with the view, the newer
  slivers start at a row found again BY KEY after every plan (an index would
  shift the content when rows come or go above), and a message that was the
  answer and becomes narration changes colour only.
- `StatusLine` (`Running flutter test · 12s`, `Quiet for 2m`) is the only
  liveness indicator and keeps its line when empty so a turn ending slides
  nothing.

### Opening a thread is instant, and a saved copy is never live

- A finger going down on a session row starts the attach (`PreconnectTap` ->
  `AgentSessions.preconnect` -> `AcpAgentSession.warm`; never in the
  background, never past the 4 channels per machine, never on hover).
- The last window of a session's `session/update` lines is kept in private
  **cache files** (`FileTranscriptCache`,
  `data/services/transcript_cache.dart`: versioned, 1 MiB per session and
  5 MiB in all, written atomically in a worker isolate, debounced, at turn end
  / screen release / background, never per chunk, never in prefs) and folded
  by the replay's own reducer (`applyUpdateParams`) into a held state shown
  while the real attach runs (`cachedAsOf`, link strip `Updating…`).
- Requests are not in a log: a saved copy has none, `PromptDock` shows none
  and `answerPermission`/`answerQuestion` ignore everything while `cachedAsOf`
  is set. Do not add anything that answers from a saved copy, and do not
  attach a finished-unseen session to warm it (the keeper clears `unseen_done`
  on load for every device; read its copy instead).

### Background work

`data/acp/background/`, `background_strip.dart`, `background_sheet.dart`.
Stop ends the turn only; jobs are `BackgroundWork`
next to `AgentPhase`, never a new phase. Words come from `waitingOnBackground`,
derived once in the session. Stopping a job is a hold; omp has no stop key, so
its route is a message (`Ask omp to stop`; ids from logs are validated as
data). Claude/Codex declare `asyncTasks` in the keeper's `initialize`, never
`perTaskStopAffordance`.

### Agent traces are captured, not written

`tool/capture-trace.sh <omp|claude|codex|pi|all> [scenario ...]` runs a real
agent on a tiny turn in a scratch directory (stores redirected, permissions
answered by the driver, fixtures redacted; it costs a few cents per turn and
never overwrites without `--force`) and saves every JSON-RPC line with its time
under `app/test/fixtures/traces/<agent>/<scenario>.jsonl`. The live-slot
reducer test, the transcript plan test and the screen replay test
(`agent_session_live_test.dart`) replay them; `python3 tool/trace_cadence.py`
rewrites `CADENCE.md`, which `autoresearch-stream.sh` replays on the phone.

### `./autoresearch-stream.sh` measures streaming on a phone

Same adb rules and the same Tailscale route as `autoresearch-keyboard.sh`; the header
lists the environment: `STREAM_PROFILES`, `STREAM_KB`, `STREAM_ROWS`,
`STREAM_SMOOTH`, `STREAM_NO_BUILD`. It builds
`app/benchmark/stream_device_bench.dart` as a profile APK
(`...herdr_mobile.streambench`) and drives the REAL `AgentSessionScreen` over
`StreamBenchSession` (a fake session that copies `AcpAgentSession`'s data
path: reducer per chunk, one flush per frame, `FrameFlush`) with a 2000-row
transcript under a 20 KB answer arriving at the recorded cadence of omp, claude
and codex. Per case it logs, as `METRIC` lines, build/raster time per frame,
dropped frames, per-chunk cost, the lag between a character arriving and being
painted (`LagProbe` reads the `RenderParagraph`s of the Markdown blocks) and
the drift while following. The budget, on the phone in a profile build: per
chunk < 0.3 ms; per frame build p95 < 4 ms, raster p95 < 8 ms and no dropped
frames; lag <= 250 ms at p95. No phone baseline is recorded yet. Never quote a
desktop number for the phone.

### `benchmark/session_open_bench.dart` measures opening a chat

Real keeper script, sessions tiled from those traces, RTT 40/120 ms link
models, the real `AgentSessionScreen`: `flutter test
benchmark/session_open_bench.dart`. It prints where an open spends its time
(the replay bytes, then 4 round trips); those are desktop numbers, never quote
them for the phone.

## Platform shell

- **Edge to edge.** `main()` enables `SystemUiMode.edgeToEdge` and `app.dart`
  wraps every route in one `AnnotatedRegion` using `AppTheme.systemBars`. Do
  not use Flutter's stock `SystemUiOverlayStyle.light/dark` (no status bar
  colour: OEM grey shows through; forces a black navigation bar). Lists with an
  explicit `padding:` on pushed screens must add
  `MediaQuery.paddingOf(context).bottom` themselves (only default-padded lists
  get the inset automatically). The same builder wraps routes in
  `SafeArea(top: false, bottom: false)` for the side insets, so screens never
  handle left/right themselves.
- **Predictive back.** The manifest sets
  `android:enableOnBackInvokedCallback="true"`. Flutter 3.47 routes the system
  back gesture through the framework, and our Cupertino page transition is
  driven by it. Not verified on a device; if back swipes misbehave, remove it
  first.
- **State that survives a launch**: theme and last root tab (`AppSettings`),
  terminal font and wrap (`TerminalSettings`), and the agent screen in front
  with its view (`AgentScreens` with `PrefsAgentScreensStore`, prefs key
  `frontAgent.v1`, loaded in `main()`; `resumeAgent` puts it back in front
  once, without the slide). A session not listed yet is waited for up to 8 s
  while the board is in front and untouched, then forgotten. The tabs the app
  used to save (legacy `openTabs.v1`) are read once on the first launch after
  the update, carrying the terminal that was in front over, and removed. The
  toggle's view per agent and the drafts live in `AgentScreens` for the app
  run only. Load such state before `runApp`.

## Notifications and the background profile

Notifications are local, optional and off by default (`NotificationSettings`,
`AttentionNotifier`, `LocalNotifier` over `flutter_local_notifications`;
`connectivity_plus` stays on 6.x because the plugin's Linux half needs dbus
0.7).

- A notification is posted on a TRANSITION into blocked (or done, if asked)
  while the app is away; whatever was blocked when the app was left (last
  known state, reachable or not) is never announced.
- `resumed` clears them all, as does a fresh start; an agent seen to leave the
  state cancels its own, but a link blip or an offline machine never does.
- At most 3 per burst, then one summary per kind.
- While enabled and an agent is working or blocked, a quiet `specialUse`
  foreground service ("Watching N agents") keeps the process alive;
  `FleetRepository.keepAliveInBackground` and the session repository's
  equivalent skip the 90 s suspend.
- Back at the app's root moves the task to the background instead of finishing
  while watching (`PopScope` in `HomeShell`, `TaskMover`);
  `MainActivity.onDestroy` stops the service for any non-configuration
  destroy.
- The host-side ntfy plugin (`tool/plugins/herdr-ntfy`, `docs/ALERTS.md`) is an
  optional extra the app no longer mentions.

THE BACKGROUND PROFILE (`HerdrTransport.setBackground(true)` +
`MachineConnection.setBackground`):

- The event stream is status-only (`pane.agent_status_changed` per agent pane +
  structural events; `pane.updated` fires for every spinner frame and would
  keep the radio awake; the pane list is rebuilt from a fresh snapshot because
  a vanished pane id rejects the WHOLE subscription).
- Mux heartbeat 8 s -> 300 s, idle link ping 25 s -> 330 s, safety poll 20 s ->
  4 min (the poll is the liveness test: its answer counts as proof of life, so
  the other two only fire when it stops being answered), session list 4 min on
  the same clock grid as the poll (`AlignedTicker`: one radio wake-up for all
  machines), streaming sessions notify at most every 2 s, a down
  machine is retried at most every 5 min.
- Anything that adds a timer, a subscription or a retry must respect it.

`./autoresearch.sh` measures all of this without a phone
(`app/benchmark/background_bench_test.dart`): the real fleet, connection, SSH
transport, mux and notifier over an in-memory link, on a virtual clock, with
every message metered. Its radio model (a 10 s high-power tail after any packet,
a wake-up worth 2 s more) and its round trip (80 ms) are assumptions, not
measurements: use it to compare changes, and measure the battery on a phone
before quoting a number. `DateTime.now()` is not moved by `fakeAsync`, so any
new clock in this path must be injectable, or the bench (and its tests) see the
machine's time.
