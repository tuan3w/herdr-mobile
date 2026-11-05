# Design language

herdr mobile is deliberately **not Material**. The reference points are Notion
mobile (warm paper, flat rows, bold page titles, soft tinted tiles and chips,
floating pills) and Linear mobile (near-black ink, a surface ladder,
hairlines, status as shape, one accent used sparingly). Telegram Android is the
bar for craft (its source was read for values and behaviours, never copied:
it is GPL-2 and herdr writes its own code).

This file is the **system**: principles, hierarchy, tokens, motion, haptics,
words, the kit, and the rules every screen follows. What one screen does lives
in `docs/screens/` (list at the end). A rule here gives its reason; a rule
without one gets deleted by the next person who does not understand it.

## Principles

1. **Content is the interface.** No cards around list items: flat rows divided
   by hairlines. Containers (the terminal, panels, sheets, the agent card that
   holds answers) are the exception.
2. **Type does the hierarchy.** Inter, size + weight + tracking as one token.
   A screen never sets a weight; it picks the role (`Type.label` or
   `Type.labelStrong`). Sentence case, never letterspaced caps.
3. **One accent** (`Ds.accent`). It marks the selected chip or segment, the one
   primary action, links and the focused field. Colour otherwise means status.
4. **Status is a shape first**, colour second (`StatusGlyph`): needs you =
   filled with a bar, working = half full, done = check, idle = empty ring,
   unknown = dashed ring; a call, run or plan step that ended without being
   done adds failed = danger disc with a cross and cancelled = quiet ring with
   a slash (`StatusGlyph.failed`, `.cancelled`: not agent statuses, so
   `AgentStatus` is unchanged). Readable without colour. A machine's link
   (`LinkDot`) follows the same rule: online is a quiet filled dot in
   `textTertiary` (health is not news; a green dot on every machine was
   decoration), connecting a ring in the working colour, offline or off a
   quiet ring, and a link that needs the person a blocked ring with a dot.
   `LinkDot.live` (filled, done colour) marks something running now.
5. **Hairlines, not elevation.** One physical pixel. The one shadow is
   `Ds.floatShadow`, for the floating bars and pills (two layers on paper; on ink a faint light ring, because a black shadow vanishes on near-black). Transient messages are on
   the inverse surface instead. No backdrop blur: a full-screen blur pass per
   frame is too expensive on a mid-range GPU (Telegram's own fallback is a flat
   colour). Chrome text stops growing at `kBarTextScale` (1.15).
6. **Press, don't ripple.** Feedback starts on pointer-down, at once (a scroll
   that takes over cancels it): a soft tint (`Ds.pressTint`) or a scale from
   `PressScale`. Waiting for the gesture arena showed nothing for a quick tap.
7. **Motion is quiet** (see Motion). Nothing moves at rest; durations, curves
   and springs come from `motion.dart`.
8. **Icons are Lucide, and ours where they sit as peers** (24 grid, stroke 2,
   round caps). One object has one icon everywhere: an agent is
   `HerdrIcons.agents`, a machine `HerdrIcons.machines`. Sizes come from
   `IconSize`.
9. **Everything is reachable.** 44 x 44 targets even where the painted shape is
   smaller; every control has one accessible name.
10. **Say it once; tint, don't outline.** A state is named in one place on a
    row and once in a screen's summary. Controls are tints, never rings. The
    one outline is the armed edge (`Ds.armedEdge`): a primed risky answer, and
    an agent swipe's peek once letting go opens it, because what acts next
    must not be missed under the thumb.

## Hierarchy

What the person looks at first, in order. Review a screen against these; "every
element has the same weight" is a fail.

1. **One loud thing.** At rest only "needs you" uses a status colour on text or
   a fill (the question wash, the count badge). Working and done are a glyph's
   shape and colour, nothing more.
2. **The accent budget.** Selected chips or segments; at
   most one primary (accent-filled) `AppButton` per region, last or lowest;
   `TextAction`s and links; the focused input. Never decoration.
3. **Surface levels.** `bg` is the page; `fill` is controls and panels inside
   content; `surface` is raised (sheets, inputs, floating bars, the agent
   card); `inverseSurface` is a transient message (toast, tooltip). Only a
   floating lane carries `floatShadow`.
4. **Weights.** w400 for cells and reading text, w500 for the names of things
   (`Type.row`: agents, machines, files), w600 for labels, buttons and the
   `Strong` roles, w700 only for `largeTitle`, `h1` and `badge`. Entities read
   heavier than the actions around them (Telegram's chat names vs its settings
   rows).
5. **Say it once.** A row says its status with the glyph. Its trailing time is
   the time alone (`4m`), weighted and coloured by the status (`blockedText`
   w600 when it needs you, `textMuted` otherwise); a screen reader still hears
   the words. The rule covers only what the glyph already says: a quiet
   working agent reads `quiet 14m`, because the working glyph does not say
   quiet. A screen's status line and its section headers are the summary,
   and say a count once (the board's needs-you count is in its status line,
   not its header: the count said four times on one screen was noise).
6. **Header budget.** A top bar holds at most two trailing actions, ⋯
   included (`AppTopBar` asserts it): a third truncated the title, which is
   what the person is answering for. The leading slot holds Back, or on home
   the machines chip (status first, the way to Machines second); it takes
   what the actions leave and shrinks before they move.
7. **Spacing says what belongs together.** `Gap.xl` between groups, `Gap.md`
   inside a group, `Gap.xs` / `Gap.sm` inside an element.
8. **A leading tile must carry information.** The same tile on every row (a
   server icon on every machine) says nothing and goes.

## Tokens (`ui/core/tokens.dart`)

Three tiers: a private palette (the hex values), the roles a screen reads
(`Ds`, `Type`, `Mono`, `Gap`, `Radii`, `IconSize`), and component metrics that
exist only where two or more components share a value (`FloatingBar`,
`RowMetrics`). A new visual token needs two call sites and a one-line reason.
A named timer or spring (`Dwell`, `Springs`) may have one call site: it is
named by its role, so every timing lives in `motion.dart` and is tuned there.
`tool/design_lint.dart` keeps raw values out of screens.

### Colour roles

| Role | Paper | Ink | Use |
| --- | --- | --- | --- |
| `bg` | `#FBFBFA` | `#0D0E10` | page |
| `surface` | `#FFFFFF` | `#16171A` | raised: sheets, inputs, floating bars |
| `fill` / `fillPressed` | `#F1F0EE` / `#E8E7E4` | `#1C1D21` / `#25262B` | controls, panels in content |
| `hairline` | `#EAE9E6` | `#24262A` | dividers |
| `border` | `#D3D1CC` | `#3A3D44` | decorative outline: diagram boxes, table rules, quote bars |
| `controlBorder` | `#8F8E8A` | `#60646D` | the edge of a field or picker (3:1 on `surface`, WCAG 1.4.11) |
| `text` | `#37352F` | `#ECEDEF` | titles, values |
| `textSecondary` | `#5F5E5A` | `#8D9098` | subtitles, labels, unselected segments |
| `textMuted` | `#6E6D69` | `#868993` | meta lines, counts, helper text |
| `textTertiary` | `#8F8E8A` | `#6A6D75` | icons, chevrons, rings: never text |
| `accent` / `accentText` | `#5E6AD2` / `#4B57BE` | `#5E6AD2` / `#9AA3F2` | the accent; as text |
| `blocked` / `working` / `done` / `danger` | `#CC5A1E` `#B07F00` `#258A53` `#D44C47` | `#F2994A` `#F2C94C` `#4CB782` `#EB5757` | status shapes |
| `blockedText` / `dangerText` | `#A84A13` / `#B5342F` | `#F2994A` / `#F26B6B` | status words |
| `pressTint` | black 4.3% | white 4.3% | a pressed row on any surface |
| `inverseSurface` / `onInverse` / `inverseAccent` | `#2B2A27` / `#F1F1EF` / `#AAB2F5` | `#2A2B30` / `#F1F1EF` / `#AAB2F5` | toasts, tooltips |

Getters: `wash(c)` (12% paper / 16% ink: a state's panel, strip or primed
chip), `washPressed(c)`, `armedEdge(c)` (55%), `blockedWash` (the question),
`accentWash` / `accentWashPressed` (selected segment, chip, row), `accentPressed`,
`faint` (grabbers), `skeleton`, `photoScrim` / `onPhoto`, `addedText`, `onStatus`,
`selection` (selected text), `linkUnderline` (a Markdown link's underline).
`Ds.fade(c, t)` scales a colour's own opacity, for what is drawn in paint (a
dimmed control, a glyph's ring). A count badge fills with `blockedText`, not
`blocked`: white on the paper shape colour is 4.2:1, under the 4.5 an 11 pt
number needs.

Contrast is asserted by `test/ui/core_controls_test.dart`, so a token change
says what it broke: the three text tiers reach 4.5:1 on `bg`, `surface` and
`fill`, on a pressed row and on the accent wash; status words reach 4.5:1 on
their wash, pressed too (why paper `blockedText` is `#A84A13`, a shade darker
than it was); toast text and its action reach 4.5:1 on `inverseSurface`;
status shapes reach 3:1 on `bg`. Stale data dims a whole row once, never its
glyph as well.

### Type (`Type`, `Mono`)

| Role | Size / height / weight | Use |
| --- | --- | --- |
| `largeTitle` | 32 / 1.18 / 700 | page title |
| `title` | 20 / 1.25 / 600 | sheet heading |
| `barTitle` | 16 / 1.25 / 600 | top bar title |
| `row` | 16 / 1.3 / 500 | the name of a thing |
| `cell` | 16 / 1.3 / 400 | an action or setting row |
| `input` | 16 / 1.3 / 400 | typed text |
| `body` | 15 / 1.45 / 400 | reading text |
| `compact` | 14.5 / 1.4 / 400 | reading text in sheets and notices |
| `prompt` | 14 / 1.35 / 500 | the question an agent asks |
| `answer` | 14.5 / 1.25 / 600 | an answer chip, a panel title |
| `button` / `buttonCompact` | 15 / 600, 13.5 / 600 | buttons, segments |
| `secondary` / `secondaryStrong` | 13.5 / 400, 500 | subtitles; log lines |
| `label` / `labelStrong` | 13 / 500, 600 | chips; section headers, text actions |
| `caption` / `captionStrong` | 12 / 500, 600 | small meta; diff marks |
| `count` | 12 / 600, tabular | a count beside a label |
| `badge` | 11 / 700, tabular | the number in a count badge |
| `h1` / `h2` / `h3` | 22 / 700, 18.5 / 600, 16 / 600 | Markdown headings |
| `bodyStrong` | 15 / 600 | a Markdown heading below level 3 |

Mono (JetBrains Mono, ligatures off): `Mono.small` 11.5 (log tails, ids),
`Mono.base` 12.5 (commands, paths, code), `Mono.input`
13.5 (typed shell text, key caps, a question's subject: what an answer
approves is the largest thing on its wash), `Mono.preview` 11 (a card's terminal
preview). The terminal keeps its own user-sized style. Counts use tabular
figures. Mono and the terminal fall back to `HerdrSymbols` (`monoFallback`):
the symbols agents' TUIs draw that JetBrains Mono lacks (`⏵ ⏸ ⏺ ⎿ ✻ ✳ ☐ ☒`,
braille spinners), subset from Noto onto the mono cell by
`tool/fonts/build_symbols.py` (OFL, about 50 KB in the APK). Why: the phone's
own fallback drew Claude Code's `⏵⏵ auto mode on` as `▯▯ auto mode on`.

### Space, radius, icons

- `Gap`: `hair` 2 (optical nudges, two stacked lines), `xs` 4, `sm` 8, `md` 12,
  `lg` 16, `xl` 24, `xxl` 32; page gutter 20. Off-grid values (6, 10, 14...)
  snapped to it.
- `Radii`: `xs` 6 (tiles, thumbnails, tooltips), `sm` 10 (controls, chips,
  pressed rows, the question wash), `md` 14 (panels, the agent card, toasts),
  `lg` 20 (sheets), `pill`. Eleven radii within 5 dp of each other collapsed to
  these: one-dp steps were invisible and drifted. A nested shape takes the outer
  radius minus the inset.
- `IconSize`: `inline` 14, `row` 16 (and every chevron), `bar` 18, `lead` 20
  (a row's status glyph), `nav` 24 (the batch bar, the attach sheet's bars), `empty` 28, `hero` 48.
- **Drawn icons** (`HerdrIcons`, `herdr_icons.dart`, generated with its font by
  `tool/icons/build_icons.py`): the selection bar, the Settings gear, the agent
  and machine everywhere, Stop (`stop`; `stopMark`, its square alone, inside a
  round button: the composer), Reviewed (`reviewed`, a check in Stop's ring), a message or a chat (`message`), browsing a
  machine's files (`folder`, lighter than Lucide's open folder, which had four
  times the ink of the `⋯` beside it), and the `Made` list (a glyph per kind: a window with a
  pulse for a server, a window with text for a page, a picture, a document; a
  sparkle on the chip), the picture wherever one is the content (`picture`,
  `pictureOff` for one that cannot be shown, `pictures` for the gallery; a file
  TYPE in a file list stays Lucide's `fileImage`), and the Settings groups (look, notifications and
  notifications off, storage, about, update, also on its Download; Agents uses the agent). Why: Lucide draws on one grid with no keylines, so
  peers in one bar differed in weight (its `server` enclosed 1.7x the area of
  its `bot` and popped out of the (since removed) tab bar; its 14-unit `x` sank next to
  `circleStop`). Ours keep Lucide's grammar, fit keylines, and are balanced by
  `--measure`: peers in one bar keep their squint (what stays dark after a
  1.5 dp blur) within about 1.5. An open shape (`close`) cannot enclose much;
  it is drawn larger instead. Draw a new glyph only for a peer set or an
  object of the app; generic actions stay Lucide.
- **Failure or caution.** `circleAlert` says something failed (a send, a read,
  a copy, a link that needs attention); `triangleAlert` says look before you
  act (a held answer, a risk under a question, an unencrypted link, a
  dangerous mode, a secret field, a Markdown warning). Why: a failed answer
  and a primed one (waiting for its hold) both showed the triangle, and
  failures elsewhere used either icon, so the triangle could not tell "look
  before you act" from "this broke".
- Rows are at least 56 high; `ListRow` text starts at 64 (gutter 20 + 32
  leading column + 12). A small leading widget is centred on the title line.

## Motion (`ui/core/motion.dart`)

The curve is `Motion.easeOut` (`Cubic(.23, 1, .32, 1)`, Telegram's
`EASE_OUT_QUINT`). An exit runs it forward too (`Motion.curved`,
`Motion.easeOutExit`): a reversed ease-out is an ease-in, which delays the
moment the person watches. Material 3 accelerates exits; herdr deliberately
does not.

| Token | ms | Use |
| --- | --- | --- |
| `press` / `release` | 100 / 180 | a control under the finger (`Motion.pressing`) |
| `fade` | 120 | an opacity-only change: the batch bar and the selection header coming and going, reduced-motion page |
| `standard` | 200 | a state change, a small element |
| `expand` | 220 | a section opening, a scroll the app makes |
| `settle` | 240 | a one-shot draw-in: glyph, badge arriving, a number rolling |
| `sheetIn` / `sheetOut` | 250 / 190 | sheets, toasts, floating lanes |
| `page` | 260 | push and pop (the Cupertino slide, shortened) |
| `draw` / `brand` | 320 / 420 | `DrawCheck`, the brand mark: rare moments |
| `holdFill` / `holdSnapBack` | 550 / 200 | hold to confirm: fills slow, snaps back fast |

Distances: `Motion.travel` 16 (a floating thing entering), `enterScale` .97
(nothing starts below .9), `rollTravel` .3 of the font size.
`PressScale`: `panel` .985, `button` .97, `chip` .96, `icon` .92; rows and keys
do not scale (a key is pressed a hundred times a day).
`Springs` (anything a finger hands over): `carry` 420 / .88, `settle` 420 / 1,
`recoil` and `out` (swipe to review);
critically damped unless the gesture carried momentum, and then ratio >= .85.
`Dwell` holds the timers (tap guard 450, hold intent 150, confirm window 4 s,
key repeat 320 / 45, toasts 1.5 / 2.75 / 5 s, spinner delay 120).

Rules: nothing loops (`BusySpinner` is the one exception, only while the person
waits on work they started, and only after `Dwell.spinnerDelay`); nothing
animates at rest or for agent-driven updates beyond one settle; transform and
opacity only (an element's own height may `AnimatedSize`); no `Opacity` left at
1; every animation starts from the live value and can be interrupted; reduced
motion (`Motion.reduced`, `Motion.of`) drops movement and keeps fades. Overshoot
on release (Telegram's `ButtonBounce`) is not used: bounce only where a gesture
carried momentum.

### The working glyph is still; the settle

A working agent's `StatusGlyph` is a half-filled ring: it says "working" by
shape, like every other status. It used to turn in 8 steps at 4 a second; with a
board of agents that was constant noise to look at and a timer plus a repaint
per glyph to pay for in battery, so nothing animates at rest. The one motion is
the **settle**: when the status of a glyph already on screen changes, the old
shape fades and the new one is drawn in once (`Motion.settle`: a ring sweeps
round, the check and the bar are stroked, the dot lands) and a needs-you or done
glyph sends one faint ring outward; then the ticker stops. A glyph built with
its status never animates, and reduced motion skips it. (A card that changed
status used to get an accent wash, `Motion.arrival`; it went with the Cards
density: the one card on the board is the waiting agent in front, which never
changes status in place.) A card resizes with `AnimatedSize` when its
question appears or is answered instead of snapping: a height change the person
did not cause must not jump the rows under their thumb.

## Haptics (`Haptics`)

| Call | Means | Fired |
| --- | --- | --- |
| `tick` | a tap, a selection, a step | with the visual, on the causal event |
| `hold` | a long press registered; a pinch reached the end of its range | when it registers |
| `sent` | something went out | when it was accepted, never on the tap |
| `armed` | a risky answer is primed; a new question arrived | `ArrivalCue` alone, rate-limited (one per 2 s, none for 3 s after start) |
| `failed` | something failed, or a guarded action was refused | on the refusal |

A toast's kind fires its own haptic; callers do not. Never `HapticFeedback`.

## Components (`ui/core/`, one import: `kit.dart`)

One of each. Two patterns for one job means migrating to one, in the same
change. Status: **stable** = a catalog entry, a semantics test and this row.

| Component | File | Job | Replaced |
| --- | --- | --- | --- |
| `PressBuilder` | `press.dart` | every tappable: press feedback, 44 dp hit, one semantics node | `InkWell`, raw `GestureDetector` taps |
| `AppButton`, `CircleButton` | `buttons.dart` | buttons; round icon buttons (`mark`: a quiet accent dot on the disc for something worth a look, never a count: the update on the Settings gear) | Material buttons |
| `TextAction` | `text_action.dart` | a word to tap (`Read all`, `Mark reviewed`) | six text-link styles; one exception, the board's `N more…` under its answer chips (`reply_chips.dart`): it is a row of that stack, with the chips' height and fill, and it greys out while an answer is in flight, which a `TextAction` cannot |
| `AppChip` | `chips.dart` | filter, tag, pick-one; selected = accent wash; `enabled: false` keeps an unavailable choice, at half strength, untappable | outlined chips, an `Opacity` over a chip |
| `Segmented` | `segmented.dart` | "this or that": one capsule that travels | two chips used as a switch |
| `AppSwitch`, `SwitchRow` | `switch.dart` | on/off | |
| `LabeledField`, `SearchField` | `fields.dart`, `search_field.dart` | a field with its label and reserved error line; search with clear | four search fields |
| `KeyCap` | `key_cap.dart` | a terminal key (no scale, repeat) | two key buttons |
| `SelectMark` | `select_mark.dart` | selected / its number | three marks |
| `CountBadge`, `RollText` | `count_badge.dart`, `roll_text.dart` | a count; a number that rolls when it changes | `PopOnRise`, hand-drawn badges |
| `StatusGlyph`, `LinkDot`, `IconTile` | `glyphs.dart` | status as shape | |
| `ListRow`, `PressRow`, `SectionLabel`, `Caret`, `Collapse`, `Hairline`, `EmptyState` | `rows.dart` | rows, the one pressable row, headers, the one disclosure mark | 45 hand-built rows, six carets, `FormSectionHeader` |
| `RowList` / `RowColumn` + `RowSpec` | `row_kit.dart` | settings-style lists declared as data; dividers from neighbours | per-screen padding and `divider:` flags |
| `Panel`, `FoldPanel` | `panel.dart` | a group in content; a group that folds | eleven hand-made containers |
| `StatusStrip`, `StatusPanel` | `status_panel.dart` | a state in one line; a state that needs a sentence (tint, no outline) | |
| `QuestionWash`, `AnswerChip` | `question_wash.dart`, `answer_chip.dart` | what an agent asks; an answer, held when risky, quiet when it declines (no fill: a fill read as another yes; a small leading ✕ in `textSecondary`, so it still reads as an answer to tap) | six washes, five chips |
| `HoldToConfirm` | `hold_confirm.dart` | the hold guard | |
| `AppTopBar`, `AppBackButton` | `top_bar.dart` | every top bar | seven bars, twelve Backs |
| `SliverLargeTitle` | `large_title.dart` | a root or list page's title | |
| `showAppSheet`, `SheetScaffold`, `SheetTitle`, `SheetGrabber`, `showActionSheet`, `showConfirmSheet` | `sheets.dart` | every sheet: four kinds (actions, list, message, form); a confirm sheet takes `hold: true` and its danger button is then a `HoldToConfirm` (a tap says how; a screen reader activates twice), for what deletes something outside the app | 23 sheets with their own paddings |
| `FloatingBar*`, `BottomStackTransition` | `bottom_stack.dart` | the bottom stack (below) | |
| `FloatingPill` | `floating_pill.dart` | a pill over content (jump to latest, changed on disk) | three pills |
| `showToast`, `Toaster`, `ToastShelf`, `ToastCard` | `toast.dart` | the one transient message (`ToastCard` is its picture, for the catalog) | `SnackBar` |
| `copyText` | `clipboard.dart` | the one way to copy (below) | ten copy sites |
| `BusySpinner`, `LoadingRow`, `Skeleton` | `spinner.dart`, `loading_row.dart`, `skeleton.dart` | waiting | |
| `ProgressLine` | `progress_line.dart` | how far a transfer of known size is (a picture or a video being copied to the phone); it fills and nothing else | the photo loader's own bar |
| `VideoStage`, `VideoSeekBar` | `video_stage.dart` | the one place a video is shown: tap pauses, the end offers Play again, marks only while paused; the seek bar and the time | the release clip's own stage |
| `AppRefresh` | `refresh.dart` | pull to refresh (a 2 px ring, no disc) | |
| `FormSection`, `FormPanel`, `FormActionBar` | `form_sections.dart` | forms | |
| `DrawCheck`, `BrandMark` | `draw_check.dart`, `brand_mark.dart` | the two rare drawn moments | |

**Rows.** Fold secondary facts into one subtitle line (`whereLine`) rather than
stacking a third line. A row that simply opens its target has no trailing
chevron (every agent and pane row would carry one); a chevron stays where it
tells something: a folder against a file, a drill-in from Settings. Chevrons
are `IconSize.row`. Status is news, not decoration: a tool call in a session
shows its glyph only while it waits, runs, fails or was cancelled, never for a
plain success.

**Segmented.** A slim `ds.fill` pill, no border, no shadow (owner: borders are
noise; a hairline pill, tried first, was), with one `accentWash` capsule under
the chosen cell: one look for every switch (the tab bar had it too, until it went). The capsule
slides (`Motion.standard`, a jump under reduced motion) and one number, its
place, drives it and every label's colour, so a label warms as the capsule
arrives and cools as it leaves; the weight never changes. No press scale; a
selection haptic only on a real change. Cells are equal when every label fits
with its icon; else equal with the words alone (an icon is decoration, a word
is the option); else the row scrolls sideways with cells as wide as their
labels and keeps the chosen one in view, so a label is never cut. With the real
font four kinds already scroll on phones under about 400 dp, so the scroll is
the ordinary case there. A rebuild (a new count arrives) leaves the row where
the person dragged it; it brings the chosen cell into view only when the choice
or the width changes. A value that is none of the options shows no capsule and
no selected cell; no options draw nothing; a parent with no width to share gets
a pill as wide as its content. A count is `textMuted` beside an unchosen label
and takes the chosen label's `accentText` on the capsule. Chips (`AppChip`)
stay for "show only this" on a list, where nothing is always selected.

**Brand mark** (`brand_mark.dart`). A lowercase h whose stem rises into a
shepherd's crook, holding one orange dot: herdr is the one who herds, and the
app's job is the one agent that needs you. It is drawn in ink tokens
(`Ds.ink.bg` tile, `Ds.ink.text` stroke, `Ds.ink.blocked` dot) in every theme,
because it is the app icon, not a status. The crook curls outward: over the
shoulder it read as an R at 56 dp. One geometry (`BrandGeometry`) feeds the
launcher icon, its Android 13 monochrome layer, the notification icon
(`ic_stat_herdr.xml`), the iOS and web icons and the first-run screen; the
files are rendered from it by `screenshot_test/brand_assets_test.dart`, then
`dart run flutter_launcher_icons`, so they cannot drift. It replaced a teal and
amber hub-and-spokes mark whose colours were in no token, that had no themed
layer and that blurred into a blob in the status bar. `BrandMark` (the first-run
screen) draws itself once over `Motion.brand` the way a hand writes it: the
stem rises into the crook, the shoulder follows, the dot lands. It is the
rarest moment in the app, so it gets the ceremony; reduced motion shows it
finished. On ink the tile meets the page and the bare mark stands alone, which
is intended.

Renderers live outside the kit: `ui/render/markdown/` (one Markdown renderer,
`docs/screens/markdown.md`) and `ui/render/terminal/`. Non-visual helpers
(`TapGuardState`, `SettleGate`, `StepClock`, `DeepLinks`) live in
`ui/support/`.

### Toasts

One system, on the root overlay. `showToast(context, message, {kind, action,
duration, groupKey, groupMessage})`; after an `await` capture `Toaster.of`
first.

- **Look.** `inverseSurface`, `Radii.md`, at least 48 high, 12 from the sides
  (the floating bar's margin), at most 480 wide; text `Type.body` in
  `onInverse`, the action `Type.button` in `inverseAccent`; a check or alert
  mark for `success` / `failed`. No outline, no shadow. Why: the old card was
  `surface` with the input outline and read as a text field; under Android's
  own black "Copied" toast it looked like a second, white system.
- **Place.** 8 above the highest `ToastShelf` (the board's batch bar, a
  form's action bar, a composer region), or 8 above the bottom inset; it glides
  when a shelf moves. A shelf counts only while its route is showing.
- **Motion.** It rises from behind the bar it stands on (clipped to its own
  place), `sheetIn` / `sheetOut`, no fade; reduced motion fades.
- **Time.** `ToastTiming`: 1.5 s under 20 characters, 2.75 s longer, 5 s with an
  action or a failure (Telegram's ladder). The clock starts once it is in place
  and stops while a finger is on it. No caller passes its own `duration`: the
  ladder already gives a failure and an action 5 s (the old 6 s batch result
  and 8 s unsent prompt went with it).
- **Gestures.** A sideways swipe puts it away (a third of its width or a fling);
  without an action a tap does too. A sheet opening puts it away.
- **Replacing.** The same `groupKey` joins in place (`Marked 3 reviewed`, one
  Undo for all; the clock restarts); a toast that timed out or is leaving is
  not joined. Any other message takes over while the old one leaves.
- The text is a live region: a screen reader says it once when it appears.
- The card carries its own transparent `Material`, or text takes the fallback
  yellow underline (the root overlay is above every `Scaffold`); any widget put
  on the root overlay needs the same. Nothing builds a `SnackBar`.

### Copy

`copyText(context, text, what: 'Path copied', caveat: ...)` is the one way to
copy (the lint rule `clipboard` enforces it). From Android 13 the system shows
its own confirmation for every copy, so the app says `what` only where it does
not (`SystemClipboard.confirms`); a `caveat` (`Only the first 1 MB was copied`)
and a refusal are always said. Why: one tap gave two toasts, one black and one
white (owner). Telegram gates every copy the same way
(`AndroidUtilities.shouldShowClipboardToast`). A copy button may also turn into
a check for `Dwell.copied`: the feedback stays where the eye is.

## Bottom stack and navigation

**Home has no bar under it.** Home is the Agents board; Machines and Settings
are pages pushed over it from its header (the machines chip on the left, the
gear on the right; `HomePages`, `docs/screens/board.md`), with Back in their
bars. Why (owner decision): most of the time the person cares about agents,
not machines; home is the app, chrome costs focus, and the tab bar (Agents,
Machines, Settings) covered the end of the list. A screen never adds a
permanent bottom bar; the bottom belongs to the content.

The bottom of a screen is lanes, from the bottom edge up, each present only
while it has content: the inset; **Dock**, 56 (on home, the batch bar while the
board picks, and nothing otherwise; a form's action bar; the attach sheet's
bars); **Toast**. (A **Pin** lane, the board's triage pill, sat between them;
it went when the board's status line took the count, since it only repeated
it. The tab bar sat in the Dock at rest; it went with the tabs.) Every gap is
8. Every floating lane goes through `FloatingBarSlot` (12 from the sides plus
the inset, centred, at most 312), with `surface`, a hairline, `floatShadow`
and round ends. `FloatingBar.clearance` is the Dock's height and margins plus
the inset; a list under a Dock ends `clearance + 8`, and a list with nothing
under it ends `Gap.xl` above the inset. `FloatingBarScrim` fades rows out
above the Dock; its solid lower half takes taps, so nothing is tapped beside
the pill by accident.

One motion for every lane: up from `Motion.travel` with a fade in, `sheetIn`;
the reverse, `sheetOut`; a fade only under reduced motion. The batch bar and
the selection header come and go with a `Motion.fade`. The shadow is soft on
the phone; `flutter test` paints a `BoxShadow` without its blur unless
`debugDisableShadows` is off (`bottom_bars_shots_test.dart` turns it off),
which once read as a hard band.

**Pages.** A push is the Cupertino slide at `Motion.page` with edge-swipe back
(a `Motion.fade` cross-fade under reduced motion). The native launch window is
paper in day and night (the chosen theme is not readable before Flutter
starts).

## Words

One word per concept, everywhere. The layer that builds them is
`lib/data/words/` (pure Dart: notifications use it too).

| Concept | Word | Never |
| --- | --- | --- |
| an agent kind | `agentName(id)`: `Claude Code`, `Codex`, `omp`, `pi` | the raw id |
| a pane with no agent | `Shell` | terminal, pane, agent |
| the person is needed | `Needs you`, `needs you`, `needYou(n)` | Waiting for you |
| a computer | `machine` (`host` only for the Host field and the SSH key) | server, this device |
| ending a turn | `Stop`, `Stopping…`, `Stopped` | Interrupt |
| trying again | `Retry` | Try again |
| going somewhere | `Open` | View |
| revealing in place | `Show` / `Hide`; `Show more` / `Show less` | Show fewer |
| background work | `job`, `subagent`; `Background work` as a title | |
| a finished agent | `done` | finished |
| cancelling | `Cancel` alone only closes the open dialog; otherwise `Cancel <noun>` | |

- **Where line**: `whereLine()` composes `agent · machine · folder`, dropping
  what the title already says.
- **Numbers**: `countOf(n, 'agent')`, never a hand-built plural (`1 subagents`
  shipped that way). Tabular figures.
- **Time**: `Elapsed.compact` (`12s`, `4m`, `1h 05m`, `3d`) beside a name;
  `Elapsed.words` in a sentence; `formatAgo` (`4m ago`, `Yesterday`, `3 Oct`);
  `formatWhen` (`Today 14:02`; in a sentence `on 3 Oct at 14:02`). Nothing else
  formats time.
- **Voice**: plain, short, specific, sentence case; outcome first, joined by a
  middle dot (`Hold to send · pushes to a remote`); say what happened and what
  to do next, never `Something went wrong`; no apology, exclamation or
  cuteness; curly apostrophes (`Couldn’t`); `…` only for something in progress
  or a menu item that opens more, and `N more` for overflow.

## Touch targets

44 x 44 minimum, always. `PressBuilder(minTapSize: kMinTap)` enlarges the hit
box around a smaller painted shape: `CircleButton` (40), compact `AppButton`
(36), `AppChip` (32, `AppChip.height` = 44 for a chip row), `KeyCap` (36) and
each `Segmented` option. Lay these out at 44.

## Semantics

One node per control, announced once. `PressBuilder` rules, which every control
follows:

- `semanticLabel: null`: the visible texts inside merge into one label.
- `semanticLabel` set: it replaces everything inside it, so icon-only controls
  say their name exactly once. Never set it on something that also contains the
  same text.
- The button role is announced only when the control can be activated
  (`button:` overrides for dimmed buttons).
- `selected` marks segments and chips. A count badge or a mark is spoken
  ("Settings, update available").
- Page titles, section labels, sheet titles and empty-state titles are
  headings. `LabeledField` names its field by the label.
- Collapsed content is excluded from semantics, focus and hit testing.

## Layout and state

- `MaterialApp.builder` wraps every route in `SafeArea(top: false, bottom:
  false)`: side insets are cleared once; screens handle top and bottom.
- `LabeledField` reserves one line below the input for helper or error text: an
  error never moves the field underneath.
- Restoration (`restorationScopeId: 'herdr'`) is opt-in per field and never for
  keys or passwords (it is written to disk in the clear). One exception, kept
  out of it: a key generated in the machine form and not saved yet is held as a
  draft in the keychain (`MachineRepository.holdKeyDraft`) and only a flag is
  restorable. The person copies its public half and goes to the machine; if
  Android reclaims the app meanwhile, the installed key's private half would
  otherwise be gone. The draft is dropped on Save, Discard, a hand edit of the
  key field, and when a form opens afresh. A pasted key is not held: it exists
  where it came from.
- A form with unsaved input asks before Back discards it; a failure ends its
  spinner, says what happened and keeps the input.
- Sheets read colours from the theme, so a theme switch restyles one that is
  open. The theme switches instantly (a cross-fade rebuilt every screen per
  frame). The terminal follows the theme (`TerminalPalette`), see
  `docs/screens/agent-screens.md`.

## Enforcement

`tool/design_lint.dart` runs in `tool/check.sh` and CI. Rules: `raw-color`,
`raw-type`, `raw-alpha`, `raw-radius`, `raw-duration`, `raw-curve`,
`raw-spring`, `raw-size` (screens), `raw-haptic`, `clipboard`, `material`,
`voice` (curly apostrophes, contractions), `modal-sheet`, `spinner` (`BusySpinner` only), `loop`, `kit-import` (features
import `kit.dart` only) and `layer` (the kit imports nothing above it;
renderers import no feature; `data/words` is pure Dart). Rules match across
lines, so a wrapped argument list is checked whole. A size used once in a
screen is a named constant with a one-line reason, not a literal. A line that
must keep a raw value says why: `// design-lint: allow(<rule>) <reason>` on
that line or the one above. `--report` counts findings per rule and folder;
`app/test/design_lint_test.dart` proves the rules on planted violations.

## Catalog and checking a screen

- **The catalog.** Every kit component in its states, light and dark, at text
  scale 1 and 1.6 (`ui/features/kit/kit_catalog.dart`). On the phone: hold
  `Version …` in Settings to open the Kit screen. As PNGs:
  `KIT_SHOTS=1 flutter test test/ui/kit_catalog_shots_test.dart` writes
  `/tmp/kit_catalog/`.
- **A screen.** `test/support/shot.dart` renders on a Galaxy-A51-sized surface
  with the real fonts. Each area has an env-gated `*_shots_test.dart`; look at
  light and dark, 412 and 320 dp wide, text scale 1 and 1.6, with worst-case
  data (skill `herdr-screen-check`).

## Review checklist

- The design lint is clean, and the new pattern is a kit component with a
  catalog entry, or uses one.
- PNGs at 412 and 320 dp x1.6, light and dark, opened and looked at.
- Which hierarchy rule the change relies on, and which noise it removed.
- Behaviour that only a phone shows (touch, keyboard, frames) is checked on one
  or marked unverified.

## Screens

- `docs/screens/board.md`: the Agents board (home and its header), answering, needs you, selection,
  starting.
- `docs/screens/agent-screens.md`: one agent per screen, the pane and its bar,
  composers, the terminal.
- `docs/screens/session.md`: the agent session screen.
- `docs/screens/attach.md`, `photos.md`, `files.md`, `markdown.md`.
- `docs/screens/web.md`: a page from a machine shown in herdr.
- `docs/screens/settings.md`: Settings, updates, home's pages, failed links, what
  survives a launch.
