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
- **UI-thread budget.** The pane must stay smooth while an agent streams ~140 KB
  per refresh. Network, crypto and JSON decoding belong in the transport
  isolate (`IsolateTransport`, created only through `createSshTransport`);
  never construct `SshTransport` on the main isolate. Keep cipher preference in
  `sshAlgorithms` (GCM is ~30x slower in dartssh2); `ssh_algorithms_test.dart`
  guards it. Never add a looping animation (they keep the GPU busy forever).
- **Measure on a phone, not a desktop.** Frame stalls only showed up on a real
  device: profile build (`flutter build apk --profile`), real touch input
  (`adb shell input swipe`), and a controllable load, e.g. a herdr pane running
  a script that streams coloured output. `build.gradle.kts` signs profile builds
  with the release key so they install over the shipped app.
- Android builds opt out of Impeller (`AndroidManifest.xml`) because it measured
  slower than Skia on a Mali-G72 phone. Do not remove that without re-measuring.
- **Design system, not Material.** UI is built from `ui/core/` (`tokens`,
  `controls`, `rows`, `glyphs`, `chrome`; see `docs/DESIGN.md`). Do not use
  `Card`, `ListTile`, `ExpansionTile`, `NavigationBar`, FAB, Material buttons,
  `SegmentedButton`, `AlertDialog`, `PopupMenuButton`, `AppBar`, `InkWell` or
  `Icons.*` in `lib/ui`; colours come from `context.ds`, text from `Type.*`,
  icons from Lucide. Check a screen by rendering it with
  `test/support/shot.dart` in light and dark, with worst-case data (long names,
  one item, zero items, Vietnamese diacritics), and look at the PNG.
- **Edge to edge.** `main()` enables `SystemUiMode.edgeToEdge` and `app.dart`
  wraps every route in one `AnnotatedRegion` using `AppTheme.systemBars`. Do not
  use Flutter's stock `SystemUiOverlayStyle.light/dark` (no status bar colour:
  OEM grey shows through; forces a black navigation bar). Lists with an explicit
  `padding:` on pushed screens must add `MediaQuery.paddingOf(context).bottom`
  themselves (only default-padded lists get the inset automatically).
- **Pane width is not ours to set.** herdr's socket API cannot resize a pane's
  terminal (`pane.resize` only moves split ratios; real size follows the last
  attached TUI client, over an internal versioned protocol). Phone width is
  handled client-side: pinch zoom, and a wrap mode that re-flows
  `recent_unwrapped` reads.
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
