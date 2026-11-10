#!/usr/bin/env python3
"""Rebuild the generated parts of the landing page in site/.

Run from anywhere:  python3 -I tool/build-site.py [--assets]

Always (cheap, no inputs beyond the repo):
  - site/feed.xml            Atom feed of the newest CHANGELOG.md releases
  - site/sitemap.xml         lastmod = newest release date
  - site/index.html          the version number and the latest-release line

With --assets (needs Pillow and ffmpeg; the outputs are committed):
  - site/img/*.webp          the app's renders, resized (needs HERDR_RAW_DIR)
  - site/video/*, og.jpg     the film, transcoded (needs HERDR_FILM=<rendered mp4>)

Why committed outputs: GitHub Pages just serves site/, so the deploy needs no
toolchain and a reviewer sees exactly what ships.
"""
import html
import os
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


GUIDES = ["guides/approve-claude-code-from-android/", "guides/ways-to-approve-claude-code-from-your-phone/"]


def sitemap(rels):
    day = rels[0]["date"]
    urls = [f"  <url><loc>{BASE}</loc><lastmod>{day}</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>"]
    for g in GUIDES:
        urls.append(f"  <url><loc>{BASE}{g}</loc><lastmod>2026-11-10</lastmod><changefreq>monthly</changefreq><priority>0.8</priority></url>")
    (SITE / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(urls) + "\n</urlset>\n"
    )


def page(rels):
    path = SITE / "index.html"
    src = path.read_text()
    v = rels[0]["version"]
    src = re.sub(r'"softwareVersion": "[^"]*"', f'"softwareVersion": "{v}"', src)
    src = re.sub(r"(<span data-version>)[^<]*(</span>)", rf"\g<1>{v}\g<2>", src)
    r = rels[0]
    latest = (f'<a href="{REPO}/releases/tag/v{r["version"]}">{r["version"]} · {html.escape(plain(r["title"]))}</a>')
    src = re.sub(r"<!--latest:start-->.*?<!--latest:end-->", lambda _: f"<!--latest:start-->{latest}<!--latest:end-->", src, flags=re.S)
    path.write_text(src)


def assets():
    from PIL import Image

    img = SITE / "img"
    vid = SITE / "video"
    img.mkdir(parents=True, exist_ok=True)
    vid.mkdir(parents=True, exist_ok=True)

    # Screens: the renders `tool/screenshots/run.sh` makes from the demo fleet through the real
    # widgets (raw, unframed, light and dark). The page frames them in CSS.
    # Regenerate them first:  cd app && HERDR_RAW_DIR=/tmp/herdr_raw flutter test screenshot_test/store_shots_test.dart
    raw = Path(os.environ.get("HERDR_RAW_DIR", "/tmp/herdr_raw"))
    for name in ["board", "chat", "pane", "links", "reply", "files", "image", "new-session", "machines", "tailscale", "browser"]:
        for theme in ("light", "dark"):
            im = Image.open(raw / f"{name}_{theme}.png").convert("RGB")
            im = im.resize((620, round(im.height * 620 / im.width)), Image.LANCZOS)
            im.save(img / f"{name}-{theme}.webp", quality=78, method=6)

    icon = Image.open(ROOT / "app/web/icons/Icon-512.png").convert("RGBA")
    icon.resize((180, 180), Image.LANCZOS).save(SITE / "apple-touch-icon.png")
    icon.resize((192, 192), Image.LANCZOS).save(img / "icon-192.png")
    icon.resize((64, 64), Image.LANCZOS).save(SITE / "favicon.png")

    # The film: render site-film/ with HyperFrames (see site-film/README.md), then pass the mp4.
    film = os.environ.get("HERDR_FILM")
    if film:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", film, "-an", "-vf", "scale=1280:-2,fps=30",
                        "-c:v", "libx264", "-crf", "27", "-preset", "slow", "-pix_fmt", "yuv420p",
                        "-movflags", "+faststart", str(vid / "herdr-mobile.mp4")], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", film, "-an", "-vf", "scale=1280:-2,fps=30",
                        "-c:v", "libvpx-vp9", "-crf", "36", "-b:v", "0", str(vid / "herdr-mobile.webm")], check=True)
        frame = vid / "frame.png"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "1.9", "-i", film, "-frames:v", "1", str(frame)], check=True)
        f = Image.open(frame).convert("RGB")
        f.resize((1280, 720), Image.LANCZOS).save(vid / "poster.webp", quality=80, method=6)
        f.resize((1200, 675), Image.LANCZOS).crop((0, 22, 1200, 652)).save(img / "og.jpg", quality=86, optimize=True)
        frame.unlink()


if __name__ == "__main__":
    if "--assets" in sys.argv:
        assets()
    rels = releases()
    feed(rels)
    sitemap(rels)
    if (SITE / "index.html").exists():
        page(rels)
    print(f"ok: {len(rels)} releases, newest {rels[0]['version']}")
