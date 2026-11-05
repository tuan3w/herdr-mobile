---
name: herdr-changelog
description: Writes and checks herdr-mobile's release notes and makes their media. It writes the `## [Unreleased]` bullets for a feat or fix change; at release time it rewrites them into the `## [x.y.z]` section (headline, one-paragraph outcome, Try-it tip cards, short bullets, Fixed), renders a still of each new screen and records a portrait walkthrough clip of the whole change list on the real app, framed with HyperFrames, then uploads the media to the GitHub release. Use it whenever a release is being prepared, the version is bumped, a feat or fix commit lands, or someone asks for a changelog, release notes, what's new or patch notes, even if they don't name the skill.
---

# Writing herdr-mobile's release notes

## 1. Who reads it

The supervisor from `AGENTS.md`: someone whose agents work while they are
elsewhere, with seconds of attention. They read the notes in three places:

- the GitHub release (the section verbatim, via `tool/release-notes.sh`);
- the in-app update sheet (`showUpdateSheet`, `update_group.dart`), read on
  the way to Download and Install. It opens on the walkthrough's poster (a tap
  plays the clip inside the app), draws `> [!TIP]` as a card, and shows any
  other image only as a quiet "Image: alt · host" chip: the poster is the one
  picture it fetches;
- the in-app history (`What's new` under Settings > About), the whole file bundled with the app.

They want to know what they will notice, and where to find it so they can try
it. Never the commits: the `CHANGELOG.md` header says each section is "what
changed for the person", and `AGENTS.md` "Releasing" says "what the person
notices, not the commits".

## 2. Two moments

- **A feat or fix commit** adds bullets under `## [Unreleased]` (create the
  heading at the top if it is missing). One bullet per thing the person notices,
  written by the rules in section 4. No headline, no tips and no media yet.
- **A release** rewrites `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD` in
  the format of section 5, and makes the media (section 6). The `### headline` is also the release commit's subject, in lower
  case: `chore(release): x.y.z, <headline>`.

## 3. Gather (release moment)

```bash
git describe --tags --abbrev=0                       # the previous release, e.g. v0.1.14
git log --no-merges --format='%h %s%n%b' <tag>..HEAD
```

- Keep `feat`, `fix` and `perf` commits. Drop `refactor`, `test`, `docs`,
  `build`, `ci` and `chore` unless the body says the person notices something.
- Drop a commit together with its `Revert "…"`. A feature that landed and was
  reverted inside the range never reached anyone: it gets no word, not even
  "removed".
- When a subject does not say what the person sees, read the diff
  (`git show <hash> -- app/lib`) until you can say it.
- Check both ways: every `## [Unreleased]` bullet must trace to a surviving
  commit, and every person-visible commit must be covered by a bullet. A bullet
  without a commit is a promise the build doesn't keep; a commit without a
  bullet is a change the person meets unannounced.

## 4. Writing rules

Each rule comes from the house style of `CHANGELOG.md`; keep its reason in mind
when a case doesn't fit.

- **UI labels in backticks, exactly as in `app/lib`.** `Storage`, `Clear cache`,
  `Copy link`. The person looks for those letters on screen; a paraphrase
  ("the open button") sends them hunting. Grep the label as a quoted string and
  read the widget that shows it, so you name the place too.
- **Agent names:** Claude Code, Codex, omp, pi, dsh. Never `claude`, never "the AI".
- **Times** look like the app shows them: `4m`, `1h 05m`, `4m ago`.
- **A fix says what went wrong in the person's terms, then "no longer…"**:
  "A picture in a chat larger than about 100 KB no longer vanishes when the
  chat reconnects."
  Name the real cause and place; a fix line that blames the wrong screen
  plants a false memory.
- **State platform conditions:** "on Android 13 and later". A claim true on one
  phone and false on another is a bug report waiting to happen.
- **Mark what was not verified,** as the README does for Codex ("its approvals
  are unverified") and 0.1.1 did for benchmarks ("a phone was not measured").
- **Numbers with units, outcome first:** "a 600-message chat was 1.5 MB, it is
  172 KB".
- **No file names, widget names, commit hashes, PR numbers, `lib/` paths or the
  word "refactor".** They mean nothing to the person and date the note.
- **One word per thing in a section:** "your browser" (not also "the phone's
  browser"), "Files" (not also "the file viewer"), "a pane". A tip is followed
  by mapping its words onto the screen; three names for one place breaks that.

## 5. The release section (outcome-cards)

The owner chose this format after a rendered comparison of five on the real
sheet. It answers what's new, where to try it and what got fixed on the first
screen of the sheet without scrolling, where today's long bullets hid the
path in the last clause of a nine-line bullet.

```markdown
## [0.1.15] - 2026-10-17

[![Watch what's new · 3 changes · 0:14 · 5.2 MB](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.15/0.1.15-whats-new.jpg)](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.15/0.1.15-whats-new.mp4)

### Pictures are downloaded once

A picture you looked at is kept on the phone, so opening it again, going
back to one in the viewer or returning to a folder no longer downloads it.

> [!TIP]
> Try it: in Settings, open `Storage` to see how much is kept, and `Clear cache` to free it.

- At most 192 MB is kept; the oldest pictures go first. Folder thumbnails are
  kept as small copies too.
- Chats of agents running in a terminal (Claude Code, omp) show your pictures
  as a quiet line with the size and type. Tap it to load the picture; a
  failure says why and offers a retry. A picture larger than about 3 MB stays
  a line of text.

![Settings with the Storage group open, showing 38 MB kept and Clear cache](https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.15/0.1.15-pictures-kept.png)

**Fixed**

- A picture in a chat larger than about 100 KB, yours or the agent's, no
  longer vanishes when the chat reconnects.
```

- **The headline** names the outcome in the person's words, sentence case.
  Usually one per release; a release with two unrelated themes may have two
  `###` blocks, each in this shape.
- **The paragraph** is one or two sentences: what the person can now do. It
  replaces the old habit of opening with a nine-line bullet.
- **Bullets** are the rest of what they notice, one line or two each. Keep the
  facts that answer "can I trust it" (what Back does, what happens when the
  connection drops, conditions such as "even with notifications off"):
  shortening must not drop a recovery promise.
- **Fixes** go under one `**Fixed**` at the end of the section, never inside a
  headline block and never as a tip.
- **Wrap lines at about 78 characters,** as the file does. The sheet parses
  with soft breaks as spaces, so wrapping is safe.

### Try-it tips

- `> [!TIP]` followed by `> Try it: <path>`. Both the in-app sheet and GitHub
  draw it as a card, so it is the one thing that stands out at a glance. Keep
  the "Try it:" prefix: any reader that drops the card chrome still reads it
  as a step.
- Only for something new that the person has to find. A fix, a speed-up or a
  change they meet anyway gets none. At most 3 per release; more is a manual.
- Put each card right after the fact it teaches (the first one right after the
  paragraph), so it shows up on the first screen.
- The path starts where the person already is ("in a pane", "in Files") and
  uses only labels you found as quoted strings in `app/lib`, after reading the
  widget that shows them. When the control is an icon with a tooltip, give the
  shape and the label: "the `⋯` at the top (`File options`)".
- Don't name a label the app no longer has (the old name of something a
  release renamed): the person cannot find it, and the label check cannot
  verify it.

## 6. Media: the walkthrough leads, a still per headline

- **The walkthrough leads the section.** Its line comes first, above the
  first `###`: a poster image that links to the clip,
  `[![Watch what's new · N changes · m:ss · X MB](…/<version>-whats-new.jpg)](…/<version>-whats-new.mp4)`.
  GitHub draws it as a clickable poster; the update sheet draws the poster
  with a play mark and plays the clip in the app on a tap. The owner chose
  "the clip leads" from a rendered comparison of five placements. The label
  says what it is and what it costs, because the sheet shows it on the
  control: nothing of the video loads before that tap.
- Each `###` block ends with exactly one still (`![alt](…png)`), named
  `<version>-<slug>.png`. In the sheet a still is a chip; on GitHub it
  illustrates what was just read.
- Fixes get no media.

Work in `local/release-media/<version>/`. `/local/` is git-ignored: media never
enter git, so the repo doesn't grow with every release; they live on the
GitHub release.

The `<slug>` is the headline in 2–4 kebab-case words: `pictures-kept`.

### The still: the real screen, rendered

1. Find the screen's shots test: `grep -l '<WidgetOrLabel>' app/test/ui/*_shots_test.dart app/screenshot_test/*.dart`.
   Its header comment gives the command and the env var. The store shots
   (`app/screenshot_test/store_shots_test.dart`) use the invented demo fleet,
   so nothing private can show.
2. No test shows the new state? Add one the way `herdr-screen-check` says
   (env-gated, `shoot()` from `test/support/shot.dart`, demo data) and keep it:
   it is the screen's regression proof too.
3. Render, open the PNG and look: the new thing must be visible without
   explanation, light theme, 412 dp wide. Copy it to
   `local/release-media/<version>/<version>-<slug>.png` (under 1.5 MB).
4. The alt text describes what the picture shows, in a sentence that makes
   sense alone: the sheet shows only that text.

### The walkthrough clip: the change list, used on the phone

One portrait clip (1080×1920, for people watching on their phones) goes
through the release's change list in order, one chapter per change the person
can see. It shows real use: the real widgets tapped and dragged at a person's
pace, never a title-card video. People skip intros and want to see the thing
working.

1. **Script it.** Rewrite `app/test/ui/release_clip_test.dart` for this
   release. It drives the real app on the invented demo fleet
   (`screenshot_test/demo_fleet.dart`) with `ClipRecorder`
   (`test/support/clip_recorder.dart`):
   - `chapter(i, total, label)` starts each change. The label is the change in
     a few words, the way the section says it. Pass `top: true` when the
     change appears low on screen (a toast, a sheet): the chapter card then
     sits at the top instead of covering it.
   - `tap`, `longPress` and `drag` follow the Try-it path, each with a short
     step label.
   - `hold` gives the person time to see the result land: about 1–1.5 s,
     0.5 s between steps, roughly 3 s per change. The owner found 30 s for
     six changes slow. End something that would linger the way a person
     would (swipe a toast away) instead of waiting it out.
   - Order the chapters as the section orders its bullets, tips first. Leave
     out what the person can't see (speed-ups, fixes).
2. **Record:** `cd app && RELEASE_CLIP=1 flutter test test/ui/release_clip_test.dart`
   writes `/tmp/release_clip/frames/` and `touches.json`. Encode the frames:
   `ffmpeg -framerate 30 -i /tmp/release_clip/frames/%05d.png -vf crop=1080:2338:0:0 -c:v libx264 -pix_fmt yuv420p -crf 18 -g 30 /tmp/release_clip/recording.mp4`.
   Look at a contact sheet of it (one frame per second) before going on:
   a toast left over from the last chapter or a screen that never settled
   shows there.
3. **Frame it** (needs network: the template loads GSAP from a CDN):
   ```bash
   .agents/skills/herdr-changelog/scripts/make_clip.sh --version <version> --slug whats-new \
     --recording /tmp/release_clip/recording.mp4 --touches /tmp/release_clip/touches.json \
     --headline '<the first ### headline>' [--poster-at S]
   ```
   The template in `assets/clip/` fades straight into the footage. It shows
   the chapter label with a progress mark (`2/6`). It eases the camera in
   toward each touch, and draws an accent ring that presses on a tap and
   follows a drag. Step captions sit in a pill clear of the player's controls.
   The clip ends on the last frame with "herdr mobile <version>". It is
   silent, at most 80 s and 30 MB. It also writes the poster,
   `<version>-whats-new.jpg`: a frame of the clip, 720 px wide, at most 80 KB
   (the one picture the update sheet fetches without a tap).
4. **Look at it:** extract a frame from a few chapters
   (`ffmpeg -ss <t> -i <clip> -frames:v 1 /tmp/f.png`) and open them. Check
   that the captions are readable at half size, the ring sits on what was
   touched, and the zoom never cuts off the thing that changed. Open the
   poster too: it must not show a "needs you" card, an orange mark or a
   waiting question. On a supervisor's screen that reads as a real agent
   needing them (the first default poster did exactly that). Pick a calm
   frame with `--poster-at` instead.

**What a test cannot draw** has to come from the phone: the page viewer's
WebView (a platform view renders nothing in a test), Android's own UI (the
system copy confirmation, notifications) and behaviour that needs a real host
or network. Record such a change on the phone, framed the same way, and link it
as its headline block's one phone clip:

1. Install the release build. Use a machine whose name is fine to publish and
   a scratch workspace with a real label; close it afterwards (AGENTS.md: never
   probe a live herdr with empty params). Nothing private on screen.
2. `.agents/skills/herdr-changelog/scripts/record_clip.sh local/release-media/<version>/raw-<slug>.mp4 30`.
   It sets a clean status bar and visible touches, records until you press
   Enter, and restores both on exit.
3. Open the contact sheet it writes (`raw-<slug>.sheet.png`). Anything private
   means you record again. Never blur it away silently.
4. `make_clip.sh --version <version> --slug <slug> --recording local/release-media/<version>/raw-<slug>.mp4 --headline '<headline>' --caption 'Try it: <the tip path>'`.

No phone connected and a change only the phone can show? Leave that change
out of the walkthrough and give it the still. Never record a mock-up in its
place. When nothing in the release can be recorded or rendered truthfully,
ship it without media: no walkthrough line, no stills. Run the check with
`--no-media="<why>"` and put the same reason in the release commit's body.
0.1.21 was such a release: its one change was a video playing, and a test
cannot draw video.

### Upload, after the release workflow

`release.yml` creates the release from the tag. Wait for it, then attach the
media and check that every link resolves:

```bash
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh release upload v<version> local/release-media/<version>/<version>-*.{png,jpg,mp4}
python3 .agents/skills/herdr-changelog/scripts/check_changelog.py <version> --remote
```

Don't create the release yourself before the workflow does. The in-app updater
reads the latest release and expects its APK there.
Extra assets are safe: the updater picks its download by exact name
(`herdr-mobile-<version>.apk`) and its line in `SHA256SUMS`.

Checked on v0.1.20: GitHub serves every release file as a download
(`Content-Disposition: attachment`, `application/octet-stream`), whatever
type it was uploaded with. Images in the notes still show on the release page
(the browser decodes them; checked), but a browser saves an `.mp4` instead of
playing it. So the update sheet plays the clip itself (`clip_player.dart`), and
on GitHub the poster is a link that downloads the clip.

## 7. Check

```bash
python3 .agents/skills/herdr-changelog/scripts/check_changelog.py <version>      # release
python3 .agents/skills/herdr-changelog/scripts/check_changelog.py unreleased     # a feat/fix commit
```

Fix every finding before committing. It checks:

- `heading` and `order`: the shape of section 5;
- `jargon`: hashes, file names, `lib/`, "refactor", PR numbers, CamelCase
  widget names;
- `tip`: the "Try it:" prefix and at most 3 cards;
- `label`: every backticked label in a tip is a quoted string in `app/lib`;
- `version`: `app/pubspec.yaml` is at the version being released;
- `media`: the walkthrough line first with its poster and clip, one still per
  headline, at most one phone clip per headline, named right, text of 4 words
  or more, the poster under 80 KB, files present locally (`--remote`:
  reachable on the release).

It cannot judge whether a bullet is true, whether every commit is covered, or
whether a tip's path really works. Do those by reading (section 3) and by
following each tip in the walkthrough script, which fails when a label is gone.

Then commit `CHANGELOG.md` and the version bump in the release commit. The media stay out of git.
