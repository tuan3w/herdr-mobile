#!/usr/bin/env python3
"""Adapt Noto Sans Mono CJK JP's advances to JetBrains Mono's terminal grid.

Usage: python3 tool/fonts/build_japanese.py REGULAR.otf BOLD.otf
Requires fonttools, also used by build_symbols.py. The input faces are the
unmodified OFL Noto Sans Mono CJK JP fonts from notofonts/noto-cjk/Sans/Mono.
No outlines or Japanese regional glyph substitutions are changed. A derivative
family name is used; the upstream license ships alongside the generated fonts.
"""
import hashlib
import pathlib
import sys

from fontTools.ttLib import TTFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'app/assets/fonts'
INPUT_SHA256 = {
    'Regular': '4d01725be822d144cf9a56ade981e6fb920cd7a610b8fc24cc601a920beea5b9',
    'Bold': 'dfdffe149bc6cbf52860dabd8b8dadbca40ae87a4fbe143b55c0258db2dadfb8',
}


def build(source, weight):
    digest = hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest()
    if digest != INPUT_SHA256[weight]:
        raise ValueError(f'{weight}: unexpected Noto Sans Mono CJK JP input checksum')
    font = TTFont(source)
    mono = TTFont(OUT / 'JetBrainsMono-Regular.ttf')
    target = mono['hmtx'][mono.getBestCmap()[ord('M')]][0] / mono['head'].unitsPerEm
    # Noto Mono's ASCII advance is half an em; CJK glyphs have two cells.
    unit = font['head'].unitsPerEm
    original = font['hmtx'][font.getBestCmap()[ord('M')]][0] / unit
    factor = target / original
    for glyph, (advance, bearing) in list(font['hmtx'].metrics.items()):
        font['hmtx'].metrics[glyph] = (round(advance * factor), bearing)
    font['hhea'].advanceWidthMax = max(a for a, _ in font['hmtx'].metrics.values())
    for record in font['name'].names:
        if record.nameID in {1, 4, 6, 16, 17}:
            name = {1: 'Herdr Japanese', 4: f'Herdr Japanese {weight}',
                    6: f'HerdrJapanese-{weight}', 16: 'Herdr Japanese', 17: weight}[record.nameID]
            record.string = name.encode(record.getEncoding())
    if 'CFF ' in font:
        cff = font['CFF '].cff
        cff.fontNames = [f'HerdrJapanese-{weight}']
        cff.topDictIndex[0].FamilyName = 'Herdr Japanese'
        cff.topDictIndex[0].FullName = f'Herdr Japanese {weight}'
    output = OUT / f'HerdrJapanese-{weight}.otf'
    font.save(output)
    print(f'{output.name}: input sha256={hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest()}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    for source, weight in zip(sys.argv[1:], ['Regular', 'Bold']):
        build(source, weight)
