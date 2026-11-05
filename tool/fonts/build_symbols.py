#!/usr/bin/env python3
"""Builds HerdrSymbols: the symbols agents' TUIs draw that JetBrains Mono lacks.

    pip install fonttools                                  # once
    python3 tool/fonts/build_symbols.py                    # Debian's fonts-noto-core
    python3 tool/fonts/build_symbols.py --src DIR          # or a directory of Noto TTFs

Why: Claude Code draws `⏵⏵ auto mode on`, `⏺`, `⎿` and the `✻ ✳ ✢ ✽` spinner;
JetBrains Mono (the app's mono font) has none of them, and on the owner's phone
the system fallback did not cover them either, so the card preview showed
`▯▯ auto mode on`. This font is the mono styles' `fontFamilyFallback`
(`monoFallback` in `ui/core/tokens.dart`).

It takes, from Noto Sans Symbols 2, then Noto Sans Symbols, then Noto Sans
Math (all SIL OFL 1.1, see `app/assets/fonts/HerdrSymbols-OFL.txt`), every
code point in RANGES that JetBrains Mono does not have. Each glyph is put on
JetBrains Mono's 600-unit advance, because a terminal row is one paragraph and a
wider fallback glyph would push every later column out of the grid: a glyph
whose ink is wider than the cell is scaled down about its centre (what kitty and
WezTerm do), and every glyph is centred in the cell. Vertical metrics copy
JetBrains Mono's, so a fallback glyph never makes a line taller. No hinting and
no layout tables: the glyphs are drawn one by one.

The font is committed, so building the app never needs Python.
"""
import argparse
import pathlib

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
MONO = ROOT / 'app/assets/fonts/JetBrainsMono-Regular.ttf'
OUT = ROOT / 'app/assets/fonts/HerdrSymbols.ttf'
FAMILY = 'HerdrSymbols'
SOURCES = ['NotoSansSymbols2-Regular.ttf', 'NotoSansSymbols-Regular.ttf', 'NotoSansMath-Regular.ttf']

# Blocks agents' TUIs draw from (box drawing and block elements are already
# complete in JetBrains Mono, and the terminal paints them itself).
RANGES = [
    (0x2190, 0x21FF),  # arrows: ↻ ↺ ↯ ↵
    (0x2300, 0x23FF),  # misc technical: ⏵ ⏸ ⏺ ⏹ ⎿ ⏱
    (0x25A0, 0x25FF),  # geometric shapes: ◐ ◑ ◒ ◓ ◼ ◻
    (0x2600, 0x261F),  # misc symbols: ★ ☆ ☐ ☑ ☒ (not the chess, weather and zodiac
    (0x2690, 0x26AF),  # rest of the block, a third of the font for nothing): ⚙ ⚑
    (0x2700, 0x27BF),  # dingbats: ✻ ✳ ✢ ✽ ✦ ✔ ✘ ✖ ➤
    (0x27F0, 0x27FF),  # supplemental arrows: ⟳ ⟲
    (0x2800, 0x28FF),  # braille: spinners ⠋ ⠙ ⠹
    (0x2B00, 0x2B2F),  # misc symbols and arrows: ⬆ ⬇ ⬢ ⬤
    (0x2B50, 0x2B59),  # ⭐ ⭘ (the rest of the block is arrows no agent draws)
    (0x29C9, 0x29C9),  # ⧉ (open in a new window)
]

PAD = 20  # font units kept clear on each side of a scaled glyph's ink


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default='/usr/share/fonts/truetype/noto', help='directory holding the Noto TTFs')
    args = ap.parse_args()

    mono = TTFont(MONO)
    have = set(mono.getBestCmap())
    upm = mono['head'].unitsPerEm
    advance = mono['hmtx']['M'][0]
    hhea, os2 = mono['hhea'], mono['OS/2']

    sources = [TTFont(pathlib.Path(args.src) / s) for s in SOURCES]
    for s in sources:
        assert s['head'].unitsPerEm == upm, 'sources must share the mono font units per em'

    names, glyphs, metrics, cmap = ['.notdef'], {}, {}, {}
    glyphs['.notdef'] = TTGlyphPen(None).glyph()
    metrics['.notdef'] = (advance, 0)
    for lo, hi in RANGES:
        for cp in range(lo, hi + 1):
            if cp in have:
                continue
            for src in sources:
                gname = src.getBestCmap().get(cp)
                if gname is None:
                    continue
                gs = src.getGlyphSet()
                bp = BoundsPen(gs)
                gs[gname].draw(bp)
                if bp.bounds is None:
                    break  # a blank glyph: leave it to the next font in line
                x0, y0, x1, y1 = bp.bounds
                scale = min(1.0, (advance - 2 * PAD) / (x1 - x0))
                cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                # Scale about the ink's centre, then centre it in the cell.
                t = (scale, 0, 0, scale, advance / 2 - cx * scale, cy - cy * scale)
                pen = TTGlyphPen(None)
                gs[gname].draw(TransformPen(pen, t))
                name = f'u{cp:04X}'
                names.append(name)
                glyphs[name] = pen.glyph()
                cmap[cp] = name
                break

    fb = FontBuilder(upm, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    glyf = fb.font['glyf']
    for n in names:
        g = glyf[n]
        g.recalcBounds(glyf)
        metrics[n] = (advance, getattr(g, 'xMin', 0))
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=hhea.ascent, descent=hhea.descent, lineGap=hhea.lineGap)
    fb.setupNameTable({
        'familyName': FAMILY,
        'styleName': 'Regular',
        'copyright': 'Copyright 2016-2018 Google LLC (Noto Sans Symbols, Symbols 2, Math). '
                     'Subset and re-spaced for herdr-mobile.',
        'licenseDescription': 'This Font Software is licensed under the SIL Open Font License, Version 1.1.',
        'licenseInfoURL': 'https://openfontlicense.org',
    })
    fb.setupOS2(
        sTypoAscender=os2.sTypoAscender, sTypoDescender=os2.sTypoDescender, sTypoLineGap=os2.sTypoLineGap,
        usWinAscent=os2.usWinAscent, usWinDescent=os2.usWinDescent, xAvgCharWidth=advance,
    )
    fb.setupPost(keepGlyphNames=False, isFixedPitch=1)
    fb.save(str(OUT))
    print(f'{OUT.relative_to(ROOT)}: {len(cmap)} code points, {OUT.stat().st_size} bytes')


if __name__ == '__main__':
    main()
