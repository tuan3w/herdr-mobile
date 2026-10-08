---
name: herdr-prototype
description: Build a throwaway, rendered prototype so a UI or UX question can be discussed on pixels instead of words. Reproduce the owner's complaint with today's code and realistic data, then draw 2-4 directions that each move one axis, render them side by side in light and dark, and report which one wins when and what it costs. Use it whenever the best path is not clear, the owner says "prototype", "mock it up", "show me", "what would it look like", "let's explore", "compare options" or "discuss the UI", or before a non-trivial change to a list, a flow or a screen's information design, even when they never say the word prototype. Pair it with herdr-design (what to decide) and herdr-screen-check (proving the winner).
---

# Prototyping herdr-mobile

A UI discussion in words stays vague: two people picture two different screens.
A prototype puts the same pixels in front of both, makes each option cheap to
reject, and shows what the words hid (a baseline that already looks fine, a
variant that grows the list by half). It is a tool for the conversation, not a
step toward the product: nothing here is shipped or promoted.

Use it when the best path is open. When the owner has already chosen, skip it:
write the `herdr-design` plan table and implement. Use the phone, not this
skill, for questions about touch, scroll feel, the keyboard or frame time.

## The method

### 1. Pin the question

One sentence, in the owner's words, plus the moment (`herdr-design` step 1).
"Lots of idle agents with the same name, I can't tell what each is about or
which to look at." Keep their phrasing: it is what the baseline must reproduce.

### 2. Reproduce it from the code, before drawing

Trace each value the owner complains about to where it comes from, and cite
`file:line`. A complaint often has several causes; each needs its own answer, and
a prototype that fixes the wrong one looks good and changes nothing. The idle
list had three: the title was the program's own terminal title
(`herdr_models.dart`), the subtitle was identical for panes in one folder
(`agents_grouping.dart`), and idle sorted by machine name, not recency.

Then find the rule the product already states for it, in `docs/GUIDE.md`,
`docs/DESIGN.md` or `references/journeys.md`, and quote it with its number or
condition ("Auto: cards up to four agents, compact from five"). A documented
decision with a reason binds the prototype: a variant that breaks one must say
so and why. Also say what the screen is for today in one line ("the Machines
row is setup data: address and version, not health"); the gap between that and
the owner's question is usually the design problem.

### 3. Pick the lowest rung that answers the question

| Rung | What | Use when | Cost |
| --- | --- | --- | --- |
| 1. Stand-ins | Compose the screen from `ui/core` parts (`ListRow`, `StatusGlyph`, `SectionLabel`, `AppChip`, `SliverLargeTitle`) over plain records in a test file | Layout, information design, what to show or fold. Most questions. | Minutes. Touches nothing in `lib/`. |
| 2. Real screen on the demo fleet | `app/screenshot_test/demo_fleet.dart` (`DemoFleet.create`) with `HomeShell`, as `store_shots_test.dart` does | The baseline must be the real screen, or a data change alone shows the effect | Wiring; still no `lib/` change |
| 3. Patched app | The variant needs behaviour, or must be felt on the phone | Gestures, motion, anything pixels can't show | A throwaway worktree and a device build (`docs/DEVELOPMENT.md`) |

Start at rung 1. Say which rung you used, and which parts are stand-ins (a
stand-in for the answer card is fine for a question about the idle list, and
wrong for a question about the card).

Never prototype in the main working tree's `lib/`. It often holds the owner's
unfinished work, and a prototype patch there is one `git stash` away from
destroying it. For rung 3: `git worktree add /tmp/proto-<name>`, and delete it
afterwards. Kill only processes you started, by PID (AGENTS.md).

### 4. Build the baseline first, on the same data

Draw today's behaviour with the data you will use for every variant. Then ask:
does this render show the owner's complaint? If it looks fine, the data is
flattering it; fix the data, not the widget. This is the one check that keeps a
prototype honest, and it is also the most persuasive picture in the report.

### 5. Use realistic, mixed data, and mark what is invented

Spread the awkward cases through the first rows, as real data does
(`herdr-screen-check/references/worst-case.md`). Prefer real captures
(`tool/capture-*.sh`, `docs/screenshots/`) to invented values (AGENTS.md:
"captured, not written").

When a variant depends on a value the app may not be able to get (the person's
last prompt as a title), put "INVENTED" next to that field in the file header
and again in the report. A beautiful variant on data the app can't supply is a
promise, not a design. Whether the data exists is then the first thing to check
before anyone builds it.

### 6. Draw the variants: smallest change first, then directions

At most four variants besides today, the combination included. Five is a menu,
not a discussion: merge or drop the weakest.

1. **The smallest change.** The cheapest edit that might fix the complaint on
   its own (a sort, a label, a default), drawn as its own variant. Every direction
   has to beat it, and without it the credit goes to the wrong idea: a critic of
   my idle-list prototype noticed that every direction also re-sorted idle, so part
   of their gain was the sort, not the titles or the fold. Keep this change out of
   the directions; only the combination may contain it. If you can't name one,
   say so; the problem then isn't cheap.
2. **Up to two directions**, each moving one axis (identity, relevance,
   structure), named by the axis, not "A/B/C". One axis per variant makes the
   trade readable.
3. **One combination** of the pieces that compose, usually the real answer.

Render expandable things open and closed. Skip strawmen: a variant nobody would
choose wastes the discussion. Every variant gets the same data and the same
chrome, so the only difference on screen is the idea.

### 7. Render and look

Copy `assets/variants_shots_template.dart` to `app/test/ui/<topic>_variants_shots_test.dart`
and edit it. It reuses `shoot()` from `test/support/shot.dart` (real fonts, phone
surface), is off unless an env var is set, and draws tall pages whole by resizing
the surface inside `pump`.

```bash
cd app && PATH="$(../tool/flutter-bin.sh):$PATH" TOPIC_VARIANTS=1 \
  flutter test test/ui/<topic>_variants_shots_test.dart
```

`flutter` is not on `PATH` in this repo; `tool/flutter-bin.sh` prints the
right one. Output goes to `/tmp/<topic>_variants/<variant>-<light|dark>.png`.

Open the images. Look at the baseline, every variant, and one dark render. For
the variant you expect to win, also render 320 dp wide at text scale 1.6: long
titles and two-line subtitles break there first. Say how many PNGs you opened.

### 8. Get an independent critique

You built these, so you can no longer see them the way the owner will. Before
you pick, run `herdr-critic` on the PNGs: a fresh reviewer, given the moment and
the images but not your preference. Its glance test (can it say what each row
is?) is the cheapest honest check that a variant works. Record at least one
thing that changed because of it, in the pick, the variants or the caveats. If
its ranking puts your pick low, lead the report with that disagreement and show
both views as the first decision; do not quietly keep your pick.

### 9. Show it as a web page

A chat message can't hold sixteen tall PNGs side by side, and the owner should
not have to hunt through `/tmp`. Turn the renders and the critique into one page:

```bash
python3 .agents/skills/herdr-prototype/assets/make_gallery.py spec.json OUT_DIR PNG_DIR
```

The spec (fields documented at the top of the script) holds the owner's complaint,
the causes with `file:line`, and per variant an idea in one sentence, a few mock
rows that illustrate it, when it wins, what it costs, plus the critic's findings,
the invented data and stand-ins, and the open decisions. The page has Ideas
(cards with the sketch and a thumbnail), Compare (variants side by side, scrolling
together, light and dark, opening at the part that differs), Critic and Decide.
Serve `OUT_DIR` with a named service or a static server you start and stop by
PID, open it, and look at it before you send it: a page you did not open is as
unproven as a PNG you did not look at.

### 10. Report, short

1. What the baseline shows (the complaint, in a picture, with the causes and `file:line`), and the product's documented rule for it quoted in the report itself with its condition or number, not only in the gallery.
2. A table: variant, axis, what it does, when it wins, what it costs.
3. Your pick and the one-line reason, and where the critic's ranking differs and why you stand where you do.
4. Caveats: what is invented, what is a stand-in, what you did not check.
5. The link to the gallery, the command to re-render, and then the questions for the owner, last. The reply you give is this report: it ends with the questions, not with a list of files.

Lead with what they can decide. Do not list everything you rendered.

### 11. After the owner chooses

Delete the losing variants (and the file, once nothing in it is wanted). Then
write the `herdr-design` plan table and implement in `lib/` from `ui/core`.
Don't promote prototype code: stand-ins skip the tap guard, selection,
semantics, staleness and the data layer, which is exactly the work the real
change must do.

## What pixels can't tell you

Touch feel, scroll, the keyboard, frame time, and whether the real data exists.
Name which of these remain unchecked, so a good-looking render is not mistaken
for a decided design.
