# herdr-mobile — agent notes

Flutter client for herdr. Read `README.md` first for architecture and layout.

## Skills

Flutter and Dart skills from `flutter/agent-plugins` are installed in
`.agents/skills/` (see `skills-lock.json`). Use them:
`flutter-apply-architecture-best-practices` before structural changes,
`flutter-add-widget-test` / `dart-add-unit-test` before adding tests,
`flutter-fix-layout-issues` for overflow errors.
Upstream source is cloned at `third_party/agent-plugins`.

## Rules of the road

- Layering is strict: `ui/` → view models → `data/repositories` →
  `data/services`. Widgets never touch transports.
- herdr's socket takes **one request per connection**; `events.subscribe` is
  the only long-lived channel. Never assume a persistent request channel.
- Every `HerdrTransportException` must say whether it is `fatal`; fatal means
  stop retrying and surface `LinkState.attention`.
- Remote commands are built in `bridge_command.dart`. Anything interpolated
  into the remote shell (session name, socket path) must stay validated or
  quoted; there are tests for injection.
- Event handling is a **throttle**, not a debounce — busy agents emit events
  continuously (see `machine_connection_test.dart`).
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
