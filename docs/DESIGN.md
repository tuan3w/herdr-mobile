# Design language

herdr mobile is deliberately **not Material**. The reference points are Notion
mobile (warm paper, flat rows, bold page titles, soft tinted tiles and chips,
a floating bottom bar) and Linear mobile (near-black ink, a surface ladder,
hairlines, status as shape, one accent used sparingly).

## Principles

1. **Content is the interface.** No cards around list items: flat rows divided
   by hairlines. Containers (the terminal, status panels, sheets) are the
   exception.
2. **Type does the hierarchy.** Inter, size + weight + tracking as a set.
   Large bold page titles; sentence-case section labels, never letterspaced caps.
3. **One accent** (`Ds.accent`, lavender-blue). Colour otherwise means status.
4. **Status is a shape first**, colour second (`StatusGlyph`): needs you =
   filled with a bar, working = half full, done = check, idle = empty ring,
   unknown = dashed ring. Readable without colour.
5. **Hairlines, not elevation.** One physical pixel. The only shadow is the
   floating tab bar. No backdrop blur (a full-screen blur pass per frame is too
   expensive on mid-range GPUs).
6. **Press, don't ripple.** Feedback starts on pointer-down (after the scroll
   intent delay) and is a soft tint or a 0.92–0.98 scale. No ink splashes.
7. **Motion is quiet.** Under 300 ms, `Motion.easeOut`, transform/opacity only,
   interruptible, reduced-motion respected. Never a looping animation, with one
   exception: `BusySpinner` (below).
8. **Icons are Lucide** (thin line, 1.5 px), not Material icons.
9. **Everything is reachable.** Touch targets are at least 44 x 44 even where the
   painted shape is smaller; every control has one accessible name.

## Tokens (`ui/core/tokens.dart`)

| | Paper (light) | Ink (dark) |
| --- | --- | --- |
| `bg` | `#FBFBFA` | `#0D0E10` |
| `surface` | `#FFFFFF` | `#16171A` |
| `fill` / `fillPressed` | `#F1F0EE` / `#E8E7E4` | `#1C1D21` / `#25262B` |
| `hairline` (dividers) | `#EAE9E6` | `#24262A` |
| `border` (input outline) | `#D3D1CC` | `#3A3D44` |
| `text` | `#37352F` | `#ECEDEF` |
| `textSecondary` | `#5F5E5A` | `#8D9098` |
| `textMuted` | `#6E6D69` | `#868993` |
| `textTertiary` (icons only) | `#8F8E8A` | `#6A6D75` |
| `accent` | `#5E6AD2` | `#5E6AD2` (text uses `accentText` `#4B57BE` / `#9AA3F2`) |
| blocked / working / done / danger (shapes) | `#CC5A1E` `#B07F00` `#258A53` `#D44C47` | `#F2994A` `#F2C94C` `#4CB782` `#EB5757` |
| `blockedText` / `dangerText` | `#AD4C14` / `#B5342F` | `#F2994A` / `#F26B6B` |

Spacing is a 4pt grid; page gutter is 20. Radii (`Radii`): tile 7, control 9,
row 10, segmented track 11, panel 12, empty-state tile 14, sheet 18, pills fully
round. Rows are at least 56 high.

### Three text tiers, and what each is for

| Tier | Use | Paper on bg / fill | Ink on bg / fill |
| --- | --- | --- | --- |
| `text` | titles, values | 11.8 / 10.8 | 16.5 / 14.4 |
| `textSecondary` | subtitles, field labels, unselected tab label, section labels | 6.3 / 5.7 | 6.1 / 5.3 |
| `textMuted` | meta lines (cwd, third lines), chip counts, helper text, placeholders | 5.0 / 4.6 | 5.5 / 4.8 |
| `textTertiary` | **icons, chevrons, status rings, decoration only** | 3.2 (not text) | 3.7 (not text) |

Text never uses `textTertiary`; it does not reach 4.5:1. Status in words uses
`blockedText` / `dangerText` (paper 5.3 / 5.8 on bg, 4.7 / 5.0 on their own 12%
tint; ink 8.7 / 6.5, 7.3 / 5.8 on tint). The status *shape* colours
(`blocked`, `working`, `done`, `danger`, `textTertiary` ring) reach 3:1 on `bg`
(paper 4.0 / 3.5 / 4.2 / 4.1 / 3.2, ink all above 3.7) and the mark drawn on a
filled glyph or badge is `ds.onStatus` (white on paper, `bg` on ink: at least
3.5 on paper fills and 7.7 on ink fills). The ratios were computed from the hex values above and
are asserted by `test/ui/core_controls_test.dart`; change a token and the test
tells you what broke. Stale (offline) data dims the whole row once; do not dim
its glyph as well.

Type (`Type.*`): `largeTitle` 32/700/-0.9, `title` 20/600, `barTitle` 16/600,
`row` 16/500, `body` 15, `secondary` 13.5, `label` 13/500, `button` 15/600,
`caption` 12/500. Counts use tabular figures. Terminal text is JetBrains Mono
(`monoFamily`).

## Components (`ui/core/`)

| File | Provides |
| --- | --- |
| `tokens.dart` | `Ds` (colours, via `context.ds`), `Gap`, `Radii`, `Type` |
| `theme.dart` | `AppTheme.light/dark`, `systemBars`, `TerminalColors`, `monoFamily`, the 300 ms page transition |
| `glyphs.dart` | `StatusGlyph`, `LinkDot`, `IconTile`, status/link `color` (shapes), `textColor` (words) and `label` extensions |
| `rows.dart` | `ListRow`, `SectionLabel`, `Collapse`, `Hairline`, `EmptyState`, `cwdTail` |
| `controls.dart` | `PressBuilder`, `AppButton`, `CircleButton`, `AppChip`, `Segmented`, `LabeledField`, `BusySpinner`, `kMinTap` |
| `chrome.dart` | `SliverLargeTitle`, `FloatingTabBar`, `AppRefresh`, `showAppSheet`, `showActionSheet`, `showConfirmSheet` |
| `status_panel.dart` | `StatusStrip` (one line), `StatusPanel` (multi-line), `StatusTint` |
| `motion.dart` | easing/duration tokens, `tapFeedback` |

### Rows

`ListRow` text starts at 64 (gutter 20 + 32 leading column + 12 gap). A small
leading widget (a status glyph) is centred on the **title line**, not the block;
pass `leadingOnTitle: false` for a tall tile. Titles wrap to two lines
(`titleMaxLines`). Fold secondary facts into one subtitle line
(`claude · payments-api`) rather than stacking a third line.

### Status strips and panels

`StatusStrip` is the default for a connection or state notice: ~48 high, tint,
`LinkDot` or glyph, the name, the state in a quieter tone, an optional compact
action. Stack several above a list without pushing it off screen. `StatusPanel`
is for states that need a sentence (an error message, a sign-in to approve);
both share `StatusTint` (12% tint, faint outline in the state colour).

### Pull to refresh

`AppRefresh`: no white disc; a 2 px ring in `textSecondary` over the page
background, `elevation: 0`. `edgeOffset` is `SliverLargeTitle.extent(context,
hasSubtitle:, bottomHeight:)`, so the ring appears just below the pinned header
and never over the first row.

### Busy spinner (the one looping animation)

`BusySpinner` is a round-capped 2 px ring, 14 px in buttons and the composer's
send. It is allowed only for work the user is actively waiting on (a button that
is saving or testing, a send in flight) and must disappear when that work
ends. It is never decoration and never part of a resting screen. Everything
else, including "working" agents, is static.

## Touch targets

44 x 44 minimum, always. `PressBuilder(minTapSize: kMinTap)` enlarges the hit
box around a smaller painted shape: `CircleButton` (40), compact `AppButton`
(36), `AppChip` (32, `AppChip.height` = 44 for a chip row; pass it as
`SliverLargeTitle.bottomHeight`) and each `Segmented` option (the track is 44
high). The layout box grows with the hit box, so lay these out at 44.

## Semantics

One node per control, announced once. `PressBuilder` rules, which every
control above follows:

- `semanticLabel: null` (default): the visible texts inside merge into one label
  (a `ListRow` reads "Needs you, title, claude · solo"). Use this wherever the
  child already says what it is.
- `semanticLabel` set: it **replaces** everything inside it, so icon-only
  controls (`CircleButton`, quick keys, send) say their name exactly once. Never
  set it on something that also contains the same text.
- The button role is announced only when the control can be activated; a plain
  `SectionLabel` or non-tappable row is plain text (`button:` overrides this for
  dimmed buttons).
- `selected` marks tabs, segments and filter chips. The tab badge is spoken
  ("Agents, 2 need you").
- Page titles, section labels, sheet titles and empty-state titles are headings
  (`Semantics(header: true)`). `LabeledField` names its text field by the
  label; the visible label text is excluded so it is not read twice.
- Collapsed content (`Collapse` while closing, `SliverLargeTitle.bottom` once
  hidden) is excluded from semantics, focus and hit testing.

## Layout and state

- `MaterialApp.builder` wraps every route in `SafeArea(top: false, bottom:
  false)`, so side insets (landscape navigation bar, cutouts) are cleared once.
  Screens handle top and bottom themselves.
- `LabeledField` always reserves one line below the input for helper or
  validation text; an error appearing never moves the field underneath.
- `MaterialApp(restorationScopeId: 'herdr')` is set. Screens opt in with
  `restorationId` (e.g. `LabeledField(restorationId:)`) for non-secret input;
  never restore keys, passwords or passphrases.
- Sheets read colours from the theme, so a light/dark switch while one is open
  restyles it. The sheet body scrolls when it does not fit.

## Checking a screen

`test/support/shot.dart` renders a widget on a Galaxy-A51-sized surface with the
real fonts and writes a PNG. Look at it in light and dark, with realistic data
and with worst-case data (long names, one-letter names, zero and one item,
Vietnamese diacritics), before calling a screen done.
