# Design language

herdr mobile is deliberately **not Material**. The reference points are Notion
mobile (warm paper, flat rows, bold page titles, soft tinted tiles and chips,
a floating bottom bar) and Linear mobile (near-black ink, a surface ladder,
hairlines, status as shape, one accent used sparingly).

## Principles

1. **Content is the interface.** No cards around list items: flat rows divided
   by hairlines. Containers (the terminal, banners, sheets) are the exception.
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
   intent delay) and is a soft tint or a 0.96–0.98 scale. No ink splashes.
7. **Motion is quiet.** Under 300 ms, `Motion.easeOut`, transform/opacity only,
   interruptible, reduced-motion respected, never a looping animation.
8. **Icons are Lucide** (thin line, 1.5 px), not Material icons.

## Tokens (`ui/core/tokens.dart`)

| | Paper (light) | Ink (dark) |
| --- | --- | --- |
| `bg` | `#FBFBFA` | `#0D0E10` |
| `surface` | `#FFFFFF` | `#16171A` |
| `fill` / `fillPressed` | `#F1F0EE` / `#E8E7E4` | `#1C1D21` / `#25262B` |
| `hairline` | `#EAE9E6` | `#24262A` |
| `text` / secondary / tertiary | `#37352F` / `#787774` / `#ABA9A4` | `#ECEDEF` / `#8D9098` / `#5C5F67` |
| `accent` | `#5E6AD2` | `#5E6AD2` (text uses `accentText`) |
| blocked / working / done / danger | `#E5732A` `#D29A00` `#2E9F63` `#D44C47` | `#F2994A` `#F2C94C` `#4CB782` `#EB5757` |

Spacing is a 4pt grid; page gutter is 20. Radii: tile 7, control 9, panel 12,
sheet 18, pills fully round. Rows are at least 56 high; touch targets 44+.

Type (`Type.*`): `largeTitle` 32/700/-0.9, `title` 20/600, `barTitle` 16/600,
`row` 16/500, `body` 15, `secondary` 13.5, `label` 13/500, `button` 15/600,
`caption` 12/500. Counts use tabular figures. Terminal text is JetBrains Mono.

## Components (`ui/core/`)

| File | Provides |
| --- | --- |
| `tokens.dart` | `Ds` (colours, via `context.ds`), `Gap`, `Radii`, `Type` |
| `theme.dart` | `AppTheme.light/dark`, `systemBars`, `TerminalColors`, `monoFamily` |
| `glyphs.dart` | `StatusGlyph`, `LinkDot`, `IconTile`, status/link colour + label extensions |
| `rows.dart` | `ListRow`, `SectionLabel`, `Collapse`, `Hairline`, `EmptyState`, `cwdTail` |
| `controls.dart` | `PressBuilder`, `AppButton`, `CircleButton`, `AppChip`, `Segmented`, `LabeledField` |
| `chrome.dart` | `SliverLargeTitle`, `FloatingTabBar`, `showAppSheet`, `showActionSheet`, `showConfirmSheet` |
| `motion.dart` | easing/duration tokens, `Pressable` |

## Checking a screen

`test/support/shot.dart` renders a widget on a Galaxy-A51-sized surface with the
real fonts and writes a PNG. Look at it in light and dark, with realistic data
and with worst-case data (long names, one-letter names, zero and one item,
Vietnamese diacritics), before calling a screen done.
