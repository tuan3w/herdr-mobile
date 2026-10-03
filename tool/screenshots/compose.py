#!/usr/bin/env python3
"""Compose marketing screenshots from raw app renders.

Input:  PNGs written by `app/screenshot_test/store_shots_test.dart` into RAW_DIR
        (412x892 dp at pixel ratio 3 = 1236x2676), named `<slug>_<light|dark>.png`.
Output: docs/screenshots/<slug>.png (one phone per image, headline above) and
        docs/screenshots/hero.png (three phones).

Usage: tool/screenshots/compose.py [RAW_DIR] [OUT_DIR]
Needs Pillow. Fonts come from app/assets/fonts (Inter), so output is reproducible.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "app" / "assets" / "fonts"
RAW = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/herdr_raw")
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "docs" / "screenshots"

W, H = 1290, 2796
SS = 2  # supersampling for the frame and gradients (anti-aliased edges)

PAPER = {"bg_top": (251, 251, 250), "bg_bottom": (240, 238, 233), "text": (55, 53, 47),
         "muted": (120, 119, 116), "glow": (94, 106, 210)}
INK = {"bg_top": (13, 14, 16), "bg_bottom": (22, 23, 34), "text": (236, 237, 239),
       "muted": (141, 144, 152), "glow": (94, 106, 210)}

# slug -> (theme of the slide, headline, sub line)
SLIDES: dict[str, tuple[str, str, str]] = {
    "agents": ("dark", "Every agent.\nOne glance.", "See which one needs you, across all your machines."),
    "needs-you": ("light", "Know the moment\nit needs you.", "Status you can read without colour."),
    "pane": ("dark", "Answer from\nyour pocket.", "A real terminal, drawn cell by cell."),
    "reply": ("light", "Reply in\none thumb.", "Quick keys for the prompts agents ask."),
    "machines": ("dark", "All your\nmachines.", "Over SSH. No relay, no account."),
    "tailscale": ("light", "Tailscale SSH,\nbuilt in.", "Approve a sign-in without leaving the app."),
}


# Slides that reuse another render (slug -> raw name).
SOURCE = {"needs-you": "agents"}


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / name), size)


def gradient(size, top, bottom):
    w, h = size
    col = Image.linear_gradient("L").resize((w, h))
    a = Image.new("RGB", (w, h), top)
    b = Image.new("RGB", (w, h), bottom)
    return Image.composite(b, a, col)


def glow(size, color, center, radius, alpha):
    w, h = size
    layer = Image.new("RGBA", (w, h), color + (0,))
    d = ImageDraw.Draw(layer)
    d.ellipse([center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius],
              fill=color + (int(255 * alpha),))
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.45))


def rounded_mask(size, radius):
    m = Image.new("L", (size[0] * SS, size[1] * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, m.width - 1, m.height - 1], radius * SS, fill=255)
    return m.resize(size, Image.LANCZOS)


def status_bar(img: Image.Image, dark: bool) -> None:
    """Faux Android status bar: time, punch-hole camera, signal, wifi, battery."""
    w = img.width
    s = w / 1236
    ink = (236, 237, 239) if dark else (55, 53, 47)
    d = ImageDraw.Draw(img, "RGBA")
    f = font("Inter-SemiBold.ttf", int(41 * s))
    d.text((int(78 * s), int(30 * s)), "9:41", font=f, fill=ink)
    cx, cy, r = w // 2, int(52 * s), int(21 * s)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(8, 8, 9))
    # battery
    bx, by, bw, bh = w - int(150 * s), int(38 * s), int(66 * s), int(33 * s)
    d.rounded_rectangle([bx, by, bx + bw, by + bh], int(9 * s), outline=ink, width=max(2, int(3 * s)))
    d.rounded_rectangle([bx + int(6 * s), by + int(6 * s), bx + int(bw * 0.78), by + bh - int(6 * s)],
                        int(4 * s), fill=ink)
    d.rounded_rectangle([bx + bw + int(3 * s), by + int(10 * s), bx + bw + int(8 * s), by + bh - int(10 * s)],
                        int(2 * s), fill=ink)
    # signal bars
    sx = w - int(290 * s)
    for i in range(4):
        h_i = int((10 + i * 7) * s)
        d.rounded_rectangle([sx + i * int(13 * s), by + bh - h_i, sx + i * int(13 * s) + int(8 * s), by + bh],
                            int(2 * s), fill=ink)
    # wifi (three arcs and a dot)
    wx, wy = w - int(215 * s), by + bh
    for k, rad in enumerate((int(34 * s), int(23 * s), int(12 * s))):
        d.arc([wx - rad, wy - rad, wx + rad, wy + rad], 225, 315, fill=ink, width=max(2, int(4 * s)))
    d.ellipse([wx - int(3 * s), wy - int(4 * s), wx + int(3 * s), wy + int(2 * s)], fill=ink)
    # gesture pill
    pw, ph = int(380 * s), int(11 * s)
    d.rounded_rectangle([w // 2 - pw // 2, img.height - int(34 * s), w // 2 + pw // 2, img.height - int(34 * s) + ph],
                        ph // 2, fill=ink + (200,))


def phone(screen: Image.Image, dark: bool, screen_w: int) -> Image.Image:
    """The raw render inside a bezel, with a shadow baked into the alpha."""
    scale = screen_w / screen.width
    scr = screen.convert("RGB").resize((screen_w, int(screen.height * scale)), Image.LANCZOS)
    status_bar(scr, dark)
    bez = int(screen_w * 0.022)
    r_screen = int(screen_w * 0.085)
    r_outer = r_screen + bez
    ow, oh = scr.width + 2 * bez, scr.height + 2 * bez
    # body
    body = Image.new("RGBA", (ow * SS, oh * SS), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    bd.rounded_rectangle([0, 0, ow * SS - 1, oh * SS - 1], r_outer * SS, fill=(14, 14, 16, 255))
    bd.rounded_rectangle([SS, SS, ow * SS - 1 - SS, oh * SS - 1 - SS], (r_outer - 1) * SS,
                         outline=(88, 90, 100, 255), width=SS * 3)
    body = body.resize((ow, oh), Image.LANCZOS)
    mask = rounded_mask(scr.size, r_screen)
    body.paste(scr, (bez, bez), mask)
    # side buttons
    btn = ImageDraw.Draw(body)
    bh = int(oh * 0.075)
    btn.rounded_rectangle([ow - 3, int(oh * 0.20), ow, int(oh * 0.20) + bh], 2, fill=(40, 40, 44, 255))
    btn.rounded_rectangle([ow - 3, int(oh * 0.30), ow, int(oh * 0.30) + int(bh * 1.6)], 2, fill=(40, 40, 44, 255))
    return body


def drop_shadow(canvas: Image.Image, sprite: Image.Image, xy, blur, offset, alpha):
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = sprite.getchannel("A").point(lambda v: int(v * alpha))
    layer = Image.new("RGBA", sprite.size, (0, 0, 0, 255))
    layer.putalpha(a)
    shadow.paste(layer, (xy[0], xy[1] + offset), layer)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))


def background(theme: dict, size=(W, H)) -> Image.Image:
    bg = gradient(size, theme["bg_top"], theme["bg_bottom"]).convert("RGBA")
    bg.alpha_composite(glow(size, theme["glow"], (size[0] // 2, int(size[1] * 0.20)), int(size[0] * 0.55),
                            0.20 if theme is INK else 0.13))
    bg.alpha_composite(glow(size, theme["glow"], (int(size[0] * 0.92), int(size[1] * 0.86)), int(size[0] * 0.5),
                            0.10 if theme is INK else 0.07))
    return bg


def text_block(canvas, theme, headline: str, sub: str, y: int) -> int:
    d = ImageDraw.Draw(canvas)
    f = font("Inter-Bold.ttf", 118)
    fs = font("Inter-Regular.ttf", 48)
    for line in headline.split("\n"):
        w = d.textlength(line, font=f)
        # Inter has no variable tracking here: tighten by drawing per glyph.
        track = -3.2
        total = w + track * (len(line) - 1)
        x = (canvas.width - total) / 2
        for ch in line:
            d.text((x, y), ch, font=f, fill=theme["text"])
            x += d.textlength(ch, font=f) + track
        y += 132
    y += 22
    w = d.textlength(sub, font=fs)
    d.text(((canvas.width - w) / 2, y), sub, font=fs, fill=theme["muted"])
    return y + 70


def slide(slug: str) -> Image.Image | None:
    theme_name, headline, sub = SLIDES[slug]
    src = RAW / f"{SOURCE.get(slug, slug)}_{theme_name}.png"
    if not src.exists():
        print(f"skip {slug}: {src} missing")
        return None
    theme = INK if theme_name == "dark" else PAPER
    canvas = background(theme)
    bottom = text_block(canvas, theme, headline, sub, 190)
    sprite = phone(Image.open(src), theme_name == "dark", 980)
    xy = ((W - sprite.width) // 2, bottom + 64)
    drop_shadow(canvas, sprite, xy, blur=60, offset=40, alpha=0.55 if theme is INK else 0.30)
    canvas.alpha_composite(sprite, xy)
    return canvas.convert("RGB")


def hero() -> Image.Image | None:
    picks = [("agents", "light"), ("agents", "dark"), ("pane", "dark")]
    shots = []
    for slug, tone in picks:
        p = RAW / f"{slug}_{tone}.png"
        if not p.exists():
            print(f"skip hero: {p} missing")
            return None
        shots.append((Image.open(p), tone == "dark"))
    hw, hh = 2400, 1500
    theme = INK
    canvas = background(theme, (hw, hh))
    d = ImageDraw.Draw(canvas)
    title = font("Inter-Bold.ttf", 120)
    sub = font("Inter-Regular.ttf", 46)
    t = "herdr mobile"
    track = -3.0
    total = sum(d.textlength(c, font=title) + track for c in t) - track
    x = (hw - total) / 2
    for ch in t:
        d.text((x, 110), ch, font=title, fill=theme["text"])
        x += d.textlength(ch, font=title) + track
    s = "Your terminal agents, from your pocket."
    d.text(((hw - d.textlength(s, font=sub)) / 2, 262), s, font=sub, fill=theme["muted"])
    screen_w = 620
    sprites = [phone(img, dark, screen_w) for img, dark in shots]
    gap = 90
    total_w = sum(s.width for s in sprites) + gap * (len(sprites) - 1)
    x0 = (hw - total_w) // 2
    top = 420
    for i, sp in enumerate(sprites):
        y = top + (0 if i == 1 else 70)
        drop_shadow(canvas, sp, (x0, y), blur=50, offset=34, alpha=0.6)
        canvas.alpha_composite(sp, (x0, y))
        x0 += sp.width + gap
    return canvas.convert("RGB")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for slug in SLIDES:
        img = slide(slug)
        if img:
            img.save(OUT / f"{slug}.png", optimize=True)
            print("wrote", OUT / f"{slug}.png")
    h = hero()
    if h:
        h.save(OUT / "hero.png", optimize=True)
        print("wrote", OUT / "hero.png")


if __name__ == "__main__":
    main()
