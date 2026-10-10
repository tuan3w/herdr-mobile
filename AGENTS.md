# herdr-mobile

The best way to run coding agents from a phone, wherever you are. One app shows
every agent on every machine, says the moment one needs you, lets you answer
safely in seconds, and then lets you put the phone away.

This file holds what should outlast any feature: who the app is for, the
principles every change is judged by, and the few rules that do real damage
when forgotten. Everything specific lives in `docs/`, next to what it describes.

## Who it is for

A **supervisor, not a pair-programmer.** Someone whose agents work on their
machines while they are elsewhere, with seconds of attention, one hand and a
flaky radio. Every time they pick up the phone they ask, in order:

1. **Does anything need me?**
2. **Is everything alive and on track?**
3. **What did it do?**
4. **Steer it:** correct, redirect, stop, start.
5. **Can I trust it?** The agent, and what this app shows.

A screen, a row, a word or an animation that answers none of these is noise.
Design the journey, not the screen: start from the person's moment, trace
every step to the end, and remove what does not serve them (skill
`herdr-design`).

## Product principles

1. **Attention is the product.** What needs the person is the loudest thing on any
   screen, and the only loud thing. Everything else is quiet, and nothing moves at rest.
2. **Bring the action to the information.** Answer from the board, the dock or the
   notification. Outcome first, process one tap down, raw detail deeper.
3. **Safe by construction.** Nothing is ever approved silently, by default
   or on a timeout. The person sees what they approve (the command itself). Risk
   is met with a proportionate guard:
   - a tap for what is cheap,
   - Undo for slips,
   - a hold for what is risky or irreversible,
   - a confirm sheet with live data for bulk actions.

   Nothing moves under the thumb and accepts a tap at once.
4. **Honest about what the phone knows.** Stale is shown as stale, a saved copy is
   never live and never answers anything, offline says offline, and a failure says what
   happened and what to do next. Never fake progress or liveness.
5. **Instant.** Feedback starts on pointer-down. Push the screen first, then ask the
   host. Paint the last known state at once. A wait the person can see is a
   design defect.
6. **One of each, everywhere.** One toast, one sheet, one photo viewer, one attach
   sheet, one guard, one spinner. The same thing has the same look, name, place and
   gesture on every surface. Two patterns for one job means migrating to one.
7. **Never a dead end, never a silent loss.** Unavailable things stay, dimmed, with
   their reason. Typed text survives failures. Nothing is cut without saying so.
8. **Respect the battery and the radio.** Every timer, subscription, poll and retry
   is a cost to the person. It stops when nobody looks and follows the background
   profile.
9. **Every detail is defended.** Each spacing, timing, colour and word comes from a
   token or a reason you can state. Craft is how a tool earns trust.

## Engineering principles

1. **Measure on a phone, not a desktop.** Frame stalls, the keyboard and
   streaming only show up on a real device: a profile build, real touch
   (`adb shell input swipe`), a controllable load. Never quote a desktop number
   for the phone, and mark what wasn't measured as unverified.
2. **The UI thread belongs to the person.** Network, crypto and herdr API decoding run
   in the transport isolate (`createSshTransport`). Nothing rebuilds per frame
   that does not have to. The pane stays smooth while an agent streams
   ~140 KB per refresh.
3. **Layering:** `ui/` → view models → `data/repositories` → `data/services`.
   Widgets never touch transports (the machine form's Test is the one exception).
4. **One connection per machine, shared.** Requests go over one multiplexed channel
   and never one per call. A fault in one machine never touches another.
5. **Fail loud and classify.** Every `HerdrTransportException` says whether it is
   `fatal` (stop retrying, surface `LinkState.attention`).
6. **Anything typed into a remote shell is validated or quoted**, with an
   injection test. A remote path reaches a shell only as a validated,
   single-quoted word.
7. **Captured, not written.** Prompt screens and agent traces come from real agents
   (`tool/capture-prompt.sh`, `tool/capture-trace.sh`), because agents change
   weekly.
8. **Tests catch what a person would notice:** behaviour, boundaries,
   transitions and errors. Don't pin wording, wiring or incidental defaults.
   For UI, look at the render with worst-case data (skill `herdr-screen-check`).
9. **Clean cutover.** Migrate every caller and delete what the change made
   obsolete, giving the reason next to the rule. Update a doc only when the
   change makes what it says wrong (see "Writing things down").
10. **Protocol facts come from `docs/herdr-api.schema.json`** (`herdr api
    schema`), not from memory.

## Rules that do real damage when forgotten

- **Never kill a process you did not start.** This machine runs the owner's
  other work (training runs, agents, herdr itself). No `pkill -f`, `killall` or
  name/pattern kills, ever: a `pkill -f "python3 -"` cleanup once killed a
  77-minute GPU training run that happened to be a python3 process. Keep the
  PID of what you spawn and kill that PID. Subagents get this rule in their
  task text.
- **Never probe a live herdr with mutating methods and empty params.** An empty
  `tab.create` really creates a tab. Use scratch workspaces with a real label,
  `focus: false`, and close them afterwards.
- **Versions.** The line is fixed at 0.1.x: ship patch bumps only (0.1.1,
  0.1.2, ...) and never bump the minor or major unless the owner says so.
  Bump `version:` in `app/pubspec.yaml` and `appVersion` in
  `app/lib/data/app_info.dart` together (a test fails when they disagree).
  Each release increments the `+N` build number by one. It is the Android
  versionCode: it must only increase and stay above 5036 (the last build
  before the line restarted at 0.1.0), or Android refuses the update ("App not
  installed").
- **Releases ship ONE universal ARM APK**, with a `CHANGELOG.md` entry whose
  section becomes the release notes (see "Releasing").
- Android opts out of Impeller, because it measured slower than Skia on a Mali-G72.
  Don't remove that without measuring again (`docs/ENGINEERING.md`).

## Skills

| Use for | Skill |
| --- | --- |
| Any product or UX decision: a feature, a flow, copy, what to show or hide, a review | `herdr-design` |
| Animation, gestures, haptics, scroll behaviour, frame budget | `herdr-motion` |
| Rendering a screen to PNGs with worst-case data, proving a UI change | `herdr-screen-check` |
| A design question with no clear answer: a throwaway rendered prototype of 2-4 directions to discuss | `herdr-prototype` |
| An independent critique of rendered screens or a prototype, from a reviewer who has not seen your pick | `herdr-critic` |

The skills are the project's own, in `.agents/skills/` (linked into
`.claude/skills/` and `.pi/skills/`). Edit them like code.

## Commands

```bash
cd app && flutter analyze && flutter test   # Flutter 3.47 on PATH
```

`tool/check.sh [--quick]` runs pub get, analyze and the tests in one command; run it
before yielding (`HERDR_FLUTTER_BIN` points it at another Flutter). On the
phone, `./autoresearch-keyboard.sh` measures the keyboard and `./autoresearch-stream.sh`
measures streaming; `./autoresearch.sh` needs no phone and measures what watching
agents costs the radio (virtual time, modelled). Each script's header says how to run it.

## Commits

Semantic (Conventional Commits) subjects: `type(scope): summary`, imperative,
lower case, no full stop, about 70 characters. Why: the history is the
changelog's source and the way to find what broke a thing; "Fix two tests that
failed when the machine was busy" and "Show pictures taken while the app runs"
cannot be filtered, `fix(test):` and `feat(gallery):` can.

- **Types:** `feat` (the person notices something new), `fix` (a bug the person
  could hit), `perf`, `refactor` (no behaviour change), `test`, `docs`, `build`
  (pubspec, Gradle, tool scripts), `ci`, `chore` (everything else).
- **Scope** is the area, not the file: `observed`, `claude`, `codex`, `omp`,
  `pane`, `board`, `ssh`, `keeper`, `settings`, `update`. Leave it out when a
  change spans many.
- **Breaking** a stored format or a wire contract: `!` after the type
  (`feat(keeper)!:`) and a `BREAKING CHANGE:` line in the body.
- **Body** says why, and what was measured or left unverified, when the subject
  cannot. One logical change per commit; do not mix a fix with a reformat.
- **Release commits** are `chore(release): x.y.z, <headline>`. The tag, not the
  subject, is what `release.yml` reads.

## Releasing

1. Bump the version (see "Versions") and add a `## [x.y.z] - date` section at
   the top of `CHANGELOG.md`: what the person notices, not the commits.
2. `tool/check.sh`, then commit and tag: `git tag vX.Y.Z && git push origin main vX.Y.Z`.
3. `.github/workflows/release.yml` checks the tag against pubspec, runs the
   checks, builds and signs the APK, and publishes it with `SHA256SUMS` and
   the changelog section as notes. Without the signing secrets it skips, and
   the APK is built and uploaded by hand the same way (`docs/DEVELOPMENT.md`).

## Writing things down

This file changes rarely. Keep it that way. Only add a rule here if it applies to
every change, or if forgetting it would do damage.

- **Facts go next to what they describe.** A hard-won fact about a subsystem goes in that
  subsystem's doc in `docs/`. Read the doc before you change the subsystem, and
  fix it when your change makes it wrong.
- **`docs/DESIGN.md` is the design system, not a changelog.** It holds the tokens,
  the shared components and the rules every screen follows. Update it when one of
  those changes; a screen-level tweak (a label, a spacing, one screen's behaviour)
  does not belong there. Why: logging every tweak made it 1,500 lines nobody reads.
- **Give the reason next to the rule,** ideally with the failure that taught it.
  A rule without a reason gets deleted by the next person who doesn't understand it.
- **Mark what was not measured or run** (unverified, desktop only), so a claim
  never outlives its evidence.
