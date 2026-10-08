---
name: herdr-screen-check
description: Prove a herdr-mobile screen with pixels. Render it to PNGs with the real fonts (light and dark, 412 and 320 dp wide, landscape, text scale 1 and 1.6+), feed it realistic and worst-case data, walk its states, look at every image, and report what broke and the fix. Use it before calling any UI change done, and whenever someone asks to check, screenshot, render, stress-test or break a screen, try the worst case, find edge cases, verify a layout, or compare design variants side by side, even if they only ask "does it look right?".
---

# Checking a screen

Desktop runs and green tests don't prove that a screen works for the person
holding the phone. Pixels at phone size do. The app already has the machinery:
`app/test/support/shot.dart` (real Inter, JetBrains Mono and Lucide fonts, a
Galaxy A51 surface: 412x892 at dpr 2.625) and a family of env-gated `*_shots_test.dart`
files under `app/test/ui/`. Use them; don't build a second harness.

Demo data quietly flatters a design: names that fit on one line, one machine,
every field filled in. Your job is to undo that, one field at a time, with data
a real person really produces. Then judge the result the way the person would:
can they tell at a glance what needs them, and can they act?

## 1. Map what the screen shows

List every value the screen renders and where it comes from. Remember the
values people forget: section counts, relative times, status words, the badge,
the subject line, the list itself (its length is a value too).

| Value | Source | Limit | Optional? |
| --- | --- | --- | --- |
| agent title | herdr pane / ACP session | none from herdr: unbounded | no |
| subject (the command) | `PromptInfo.subject` | multi-line, unbounded | yes |

Unbounded is a finding in itself. Pick something long but believable.

Then list the **states**, because a screen is many screens: loading or first
paint (the cached copy, dimmed), live, stale, offline, failed, empty, one, many,
blocked or needs-you, working, done, and the compact layout (landscape plus keyboard).

## 2. Build the data at the boundary

The worst case enters where real data does: through the fakes in
`app/test/support/` (`FakeAgentSession`, `fake_transport.dart`, `fake_fs.dart`,
`turn_fixtures.dart`, `subagent_fixtures.dart`, `omp_ask_fixtures.dart`) or the demo fleet in
`app/screenshot_test/demo_fleet.dart`. Never edit the widget to provoke a break;
that tests your edit, not the screen.

Spread the failures across the first rows, the way real data mixes them: row 1
has the long title, row 2 the Vietnamese workspace, row 3 a one-letter name, and
so on. Pick values from `references/worst-case.md`.

## 3. Render

Extend the nearest existing shots file, or add one in the same shape. Each one is
off by default so the suite stays fast, and writes to `/tmp`:

```dart
// Renders <what> to PNGs for review (light and dark, 412x892 and 320x640,
// text scale 1 and 1.6). Off by default; it writes files:
//
//   FOO_SHOTS=1 flutter test test/ui/foo_shots_test.dart
@TestOn('vm')
library;

void main() {
  if (Platform.environment['FOO_SHOTS'] == null) {
    test('foo shots are off (set FOO_SHOTS=1)', () {}, skip: 'set FOO_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['FOO_SHOTS_DIR'] ?? '/tmp/foo_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });
  // for each case x brightness x size x text scale: shoot(...)
}
```

For a simple widget, `shoot(tester, home, path, brightness:, pump:)` from
`shot.dart` is enough. For a screen that needs sizes, text scale or a keyboard
inset, copy the local `shoot` of `decision_surfaces_shots_test.dart` or
`attach_composer_shots_test.dart`: it sets `tester.view.physicalSize`,
`devicePixelRatio`, `padding` (the status and gesture bars) and wraps the app in
`MediaQuery(textScaler: TextScaler.linear(scale))`.

The matrix, as a minimum:

- **Light and dark.** Plus "dark terminal on paper" when a terminal is visible.
- **412x892** (the reference phone) and **320x640** (the smallest phone supported).
- **Text scale 1.0 and 1.6.** Use 2.0 for chrome that must still fit (the tab bar does).
- **892x412 landscape**, with a keyboard inset, when the screen has a composer
  (the compact layout hides the dock, the palette and the quick phrases).
- The **states** from step 1, not only the happy one.

Run it from `app/` with `flutter` on `PATH`, then **open the PNGs and look at them** with the image
reader. A render you didn't look at proves nothing. When the matrix is large,
open at least one per state and size, plus every image you cite. Say how many you
opened; don't claim you looked at all of them unless you did.

## 4. Look like the person, then like an inspector

First, as the person: one glance at a time.

- Can I tell what needs me in under a second? Is it the loudest thing, and the only loud thing?
- Do I know what will happen if I tap the obvious control? Is the command I'm
  approving visible, whole or behind `Read all`?
- Do I know whether this is live, stale, a saved copy, or offline?
- Is there anything here that I would never read? (That's noise: report it.)

Then as an inspector, look for these signatures:

| What you see | Usual cause | Fix |
| --- | --- | --- |
| Yellow and black overflow stripes, or a `RenderFlex overflowed` in the log | A fixed-width child in a `Row` | `Expanded` or `Flexible` on the text, a fixed size on the glyph |
| A trailing action pushed off or clipped | The middle took all the space | `Flexible` middle, the action outside it |
| A badge or chip wrapped onto two lines | It was allowed to shrink | Keep it intrinsic; decide what yields instead |
| A glyph centred against a 2-line title | Centred on the block | `ListRow` centres the leading widget on the title line |
| Diacritics clipped (Vietnamese) | A tight height plus a clip | Let the text box grow; no clip on text |
| A path cut at the end, so every row looks the same | End ellipsis on a path or host | Middle-truncate, or `cwdTail` |
| A command silently cut | `maxLines` with nothing behind it | `Read all`, or the full text in the sheet |
| Text in `textTertiary`, or contrast below 4.5:1 | The wrong tier | `textSecondary` / `textMuted` |
| "1 agents", "0 need you" | A hand-built plural | A count-aware string |
| A number that jumps width as it updates | Proportional figures | Tabular figures |
| The last row under the gesture bar or the floating tab bar | Explicit `padding:` without the inset | Add `MediaQuery.paddingOf(context).bottom` / the bar's clearance |
| The composer behind the keyboard, or jumping | Pane reading `viewInsets` | `docs/ENGINEERING.md` "Keyboard" |
| A target under 44 dp | A bare `GestureDetector` | `PressBuilder(minTapSize: kMinTap)` |
| A centred empty state jumping as the list loads | The layout differs per state | Top-align it and keep the same frame |
| The same state said three times (outline, wash and badge) | Decoration | Say it once |

## 5. Report, then stop

Part 1, what broke, worst first. **Broken** means unreadable, unreachable or
wrong data. **Ugly** means readable but visibly wrong. **Fragile** means fine now,
but one realistic step from breaking.

| # | Severity | Value | Worst case | What happens | Fix (file:line) | PNG |
| --- | --- | --- | --- | --- | --- | --- |

Every row names a PNG you opened that shows the break, and gives the exact
`file:line` of the code to change (a symbol name alone sends the next person
searching). A break you only inferred from code goes under **Fragile**, marked
"from code, not seen". A finding the owner can't see in an image is a finding
they can't trust.

Part 2, decisions for the owner: breaks with more than one right answer (wrap
or truncate this title? what does a session with no cwd show?). One line each,
with your recommendation.

Part 3, what held up, so nobody "fixes" it.

Give the command that re-renders and the output folder. Fix only what was asked.
After a fix, re-render every state, including the happy one: a fix for the worst
case must not regress the demo.

## 6. Keep the proof

Keep the fixture and the env-gated shots test: they are the regression check
for the next change. When a break could plausibly come back unseen (an
overflow, a lost inset, a list that builds every row), also add a normal widget
test that fails on it. `app/test/ui/worst_case_test.dart` is the model. It
asserts behaviour (no overflow exception, a bounded number of built rows), not
pixels.

## Comparing variants

When a design question is open, build and compare the directions with
`herdr-prototype`; it owns the baseline, the variants and the report. Once the
owner picks one and it is implemented, prove that one through the matrix above.

## What pixels can't tell you

Touch feel, the keyboard, scroll physics and frame time need the phone (see
herdr-motion, section 9). Say which of these remain unchecked instead of
implying the screen is done.
