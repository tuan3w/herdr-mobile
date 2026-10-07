#!/usr/bin/env python3
"""Collect what this person has typed to coding agents into corpus/messages.jsonl.

Sources (each optional; missing ones are skipped):
  claude history  ~/.claude/history.jsonl            every prompt typed in Claude Code (the big one)
  codex history   ~/.codex/history.jsonl
  omp sessions    ~/.omp/agent/sessions/**/*.jsonl   user messages, attribution "user" (omp keeps no
                                                     history file; its history.db drops repeats)

One line per message: {"t": epoch seconds, "src": ..., "session": ..., "text": ...}, oldest
first. Repeats are KEPT: "continue" typed 300 times is the signal a phrase predictor lives on.
Only the same message seen through two sources at the same moment is dropped. Text is NFC
(Vietnamese typed on macOS can arrive decomposed; Dart has no String.normalize, so the
harness assumes NFC and the app must make it so, see README).

Dropped: pasted blobs and logs (over 1500 chars, over 25 lines), slash commands, image
placeholders, text the agent harness injected into the user turn.

The output is the owner's private writing: it goes to corpus/, which is gitignored. This
script prints counts only, never a message.

Also writes corpus/lexicon-en.tsv and corpus/lexicon-vi.tsv (the 50k most frequent words and
Vietnamese syllables of OpenSubtitles, hermitdave/FrequencyWords): the stand-in for "a keyboard
that knows nothing about you". Skipped with --no-lexicon.

  python3 extract_corpus.py [--no-lexicon]
"""
import datetime
import glob
import json
import os
import re
import sys
import unicodedata
import urllib.request

HOME = os.path.expanduser("~")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus")
LEXICON = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{l}/{l}_50k.txt"

MAX_CHARS, MAX_LINES = 1500, 25

# Text the harness injected into the user turn, not something the person typed.
INJECTED = re.compile(
    r"^\s*(<(command-|local-command|system-reminder|task-notification|user-prompt-submit-hook)"
    r"|Caveat:|\[Request interrupted|This session is being continued)",
)
PLACEHOLDER = re.compile(r"\[(Image|Pasted text|Pasted image|\.\.\.Truncated)[^\]]*\]")


def iso_to_epoch(stamp):
    try:
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return 0.0


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return ""
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


def jsonl(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def claude_history():
    for j in jsonl(f"{HOME}/.claude/history.jsonl") if os.path.exists(f"{HOME}/.claude/history.jsonl") else ():
        if j.get("pastedContents"):
            continue
        yield j.get("timestamp", 0) / 1000.0, "claude", j.get("project") or "", j.get("display") or ""


def codex_history():
    path = f"{HOME}/.codex/history.jsonl"
    for j in jsonl(path) if os.path.exists(path) else ():
        yield float(j.get("ts", 0)), "codex", j.get("session_id") or "", j.get("text") or ""


def omp_sessions():
    for path in glob.glob(f"{HOME}/.omp/agent/sessions/**/*.jsonl", recursive=True):
        for j in jsonl(path):
            m = j.get("message")
            if j.get("type") != "message" or not isinstance(m, dict) or m.get("role") != "user":
                continue
            if m.get("attribution") not in (None, "user"):
                continue
            yield iso_to_epoch(j.get("timestamp")), "omp", os.path.basename(path), text_of(m.get("content"))


def keep(text):
    return (
        text
        and len(text) <= MAX_CHARS
        and text.count("\n") < MAX_LINES
        and not text.startswith("/")
        and not INJECTED.match(text)
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    rows, seen, per_src = [], set(), {}
    for source in (claude_history, codex_history, omp_sessions):
        for t, src, session, text in source():
            text = unicodedata.normalize("NFC", PLACEHOLDER.sub("", text)).strip()
            if not keep(text):
                continue
            key = (text, int(t // 30))
            if key in seen:
                continue
            seen.add(key)
            per_src[src] = per_src.get(src, 0) + 1
            rows.append({"t": t, "src": src, "session": session, "text": text})
    rows.sort(key=lambda r: r["t"])
    with open(os.path.join(OUT, "messages.jsonl"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"{len(rows)} messages -> {OUT}/messages.jsonl  {per_src}")

    if "--no-lexicon" in sys.argv:
        return
    for lang in ("en", "vi"):
        path = os.path.join(OUT, f"lexicon-{lang}.tsv")
        if not os.path.exists(path):
            with urllib.request.urlopen(LEXICON.format(l=lang), timeout=60) as r:
                words = unicodedata.normalize("NFC", r.read().decode("utf-8"))
            with open(path, "w", encoding="utf-8") as f:
                f.write(words)
        print(f"lexicon -> {path}")


if __name__ == "__main__":
    main()
