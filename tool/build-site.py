#!/usr/bin/env python3
"""Rebuild the generated parts of the landing page in site/.

Run from anywhere:  python3 -I tool/build-site.py [--assets]

Always (cheap, no inputs beyond the repo):
  - site/feed.xml            Atom feed of the newest CHANGELOG.md releases
  - site/sitemap.xml         lastmod = newest release date
  - site/index.html          the version number and the "What's new" cards

With --assets (needs Pillow and ffmpeg; the outputs are committed):
  - site/img/*.webp          screenshots cropped to the phone, resized
  - site/img/og.jpg          1200x630 social card
  - site/video/board.*       the board loop (webm + mp4 + poster)

Why committed outputs: GitHub Pages just serves site/, so the deploy needs no
toolchain and a reviewer sees exactly what ships.
"""
import html
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
BASE = "https://tuan3w.github.io/herdr-mobile/"
REPO = "https://github.com/tuan3w/herdr-mobile"


def releases(limit=12):
    text = (ROOT / "CHANGELOG.md").read_text()
    out = []
    for m in re.finditer(r"^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})\n(.*?)(?=^## \[|\Z)", text, re.S | re.M):
        version, date, body = m.groups()
        title = re.search(r"^### (.+)$", body, re.M)
        # First prose paragraph after the headline.
        paras = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip() and not p.lstrip().startswith(("#", ">", "-"))]
        out.append({
            "version": version,
            "date": date,
            "title": title.group(1).strip() if title else f"herdr mobile {version}",
            "summary": re.sub(r"\s+", " ", paras[0]) if paras else "",
        })
        if len(out) == limit:
            break
    return out


def plain(s):
    return re.sub(r"`([^`]*)`", r"\1", s)


def feed(rels):
    updated = f"{rels[0]['date']}T00:00:00Z"
    entries = []
    for r in rels:
        url = f"{REPO}/releases/tag/v{r['version']}"
        entries.append(
            f"  <entry>\n    <title>{html.escape(plain(r['title']))} ({r['version']})</title>\n"
            f"    <link href=\"{url}\"/>\n    <id>{url}</id>\n    <updated>{r['date']}T00:00:00Z</updated>\n"
            f"    <summary>{html.escape(plain(r['summary']))}</summary>\n  </entry>"
        )
    (SITE / "feed.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom">\n'
        f"  <title>herdr mobile releases</title>\n  <link href=\"{BASE}feed.xml\" rel=\"self\"/>\n"
        f"  <link href=\"{BASE}\"/>\n  <id>{BASE}</id>\n  <updated>{updated}</updated>\n"
        "  <author><name>Tuan Nguyen</name></author>\n" + "\n".join(entries) + "\n</feed>\n"
    )


def sitemap(rels):
    (SITE / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"  <url><loc>{BASE}</loc><lastmod>{rels[0]['date']}</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>\n"
        "</urlset>\n"
    )


def page(rels):
    path = SITE / "index.html"
    src = path.read_text()
    v = rels[0]["version"]
    src = re.sub(r'"softwareVersion": "[^"]*"', f'"softwareVersion": "{v}"', src)
    src = re.sub(r"(<span data-version>)[^<]*(</span>)", rf"\g<1>{v}\g<2>", src)
    cards = []
    for r in rels[:3]:
        cards.append(
            f'        <li><a href="{REPO}/releases/tag/v{r["version"]}">'
            f'<time datetime="{r["date"]}">{r["date"]}</time>'
            f'<h3>{html.escape(plain(r["title"]))}</h3>'
            f'<p>{html.escape(plain(r["summary"]))}</p>'
            f'<span class="ver">{r["version"]}</span></a></li>'
        )
    block = "<!--changelog:start-->\n" + "\n".join(cards) + "\n        <!--changelog:end-->"
    src = re.sub(r"<!--changelog:start-->.*?<!--changelog:end-->", lambda _: block, src, flags=re.S)
    path.write_text(src)


def assets():
    from PIL import Image

    img = SITE / "img"
    vid = SITE / "video"
    img.mkdir(parents=True, exist_ok=True)
    vid.mkdir(parents=True, exist_ok=True)
    shots = ROOT / "docs" / "screenshots"

    # Phone screenshots: drop the baked-in caption (the page has real text) and
    # keep the phone. 560 px wide is 2x the 280 px they display at.
    for name in ["board", "chat", "pane", "files", "machines", "new-session", "reply", "links", "tailscale", "image"]:
        im = Image.open(shots / f"{name}.png").convert("RGB")
        im = im.crop((0, 560, im.width, im.height))
        im = im.resize((560, round(im.height * 560 / im.width)), Image.LANCZOS)
        im.save(img / f"{name}.webp", quality=80, method=6)

    hero = Image.open(shots / "hero.png").convert("RGB")
    phones = hero.crop((0, 330, hero.width, hero.height))  # below the baked-in title
    for w in (1600, 800):
        phones.resize((w, round(phones.height * w / phones.width)), Image.LANCZOS).save(
            img / f"hero-{w}.webp", quality=80, method=6)

    og = hero.resize((1200, 750), Image.LANCZOS).crop((0, 0, 1200, 630))
    og.save(img / "og.jpg", quality=86, optimize=True)

    icon = Image.open(ROOT / "app/web/icons/Icon-512.png").convert("RGBA")
    icon.resize((180, 180), Image.LANCZOS).save(SITE / "apple-touch-icon.png")
    icon.resize((192, 192), Image.LANCZOS).save(img / "icon-192.png")
    icon.resize((64, 64), Image.LANCZOS).save(SITE / "favicon.png")

    poster = img / "demo-poster-src.jpg"  # the YouTube thumbnail, fetched once
    if poster.exists():
        p = Image.open(poster).convert("RGB").resize((960, 540), Image.LANCZOS)
        p.save(img / "demo-poster.webp", quality=78, method=6)
        poster.unlink()

    src = ROOT / "local/release-media/0.1.58/clip-whats-new/assets/recording.mp4"
    if src.exists():
        base = ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-an", "-vf", "scale=540:-2,fps=24"]
        subprocess.run(base + ["-c:v", "libvpx-vp9", "-crf", "36", "-b:v", "0", str(vid / "board.webm")], check=True)
        subprocess.run(base + ["-c:v", "libx264", "-crf", "30", "-preset", "slow", "-pix_fmt", "yuv420p",
                               "-movflags", "+faststart", str(vid / "board.mp4")], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-frames:v", "1",
                        "-vf", "scale=540:-2", str(vid / "poster.png")], check=True)
        Image.open(vid / "poster.png").convert("RGB").save(img / "board-poster.webp", quality=80, method=6)
        (vid / "poster.png").unlink()


if __name__ == "__main__":
    if "--assets" in sys.argv:
        assets()
    rels = releases()
    feed(rels)
    sitemap(rels)
    if (SITE / "index.html").exists():
        page(rels)
    print(f"ok: {len(rels)} releases, newest {rels[0]['version']}")
