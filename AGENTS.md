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
