#!/usr/bin/env python3
"""Chunk arrival statistics of the recorded ACP traces.

    python3 tool/trace_cadence.py        # rewrites app/test/fixtures/traces/CADENCE.md

Reads app/test/fixtures/traces/<agent>/<scenario>.jsonl (see
tool/capture_trace.py for the format). Numbers are taken at the agent's
stdout, before the keeper, SSH and the app's own batching.
"""
from __future__ import annotations

import json
import math
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRACES = ROOT / "app" / "test" / "fixtures" / "traces"
TEXT = ("agent_message_chunk", "agent_thought_chunk")
# Two chunks closer than this arrived in one read of the pipe: a burst.
BURST_MS = 5.0
# A pause this long splits a stream of text in two segments (the model was
# thinking or a tool ran). Gap statistics and windows are per segment; the
# pauses are counted on their own.
PAUSE_MS = 1000.0
WINDOW_MS = 100.0
# A segment shorter than this says nothing about a rate.
MIN_SPAN_MS = 300.0

Chunk = tuple[float, str, int]


def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def text_chunks(rows: list[dict]) -> list[Chunk]:
    """(t, kind, chars) of every message/thought chunk the agent sent."""
    out = []
    for r in rows:
        m = r["msg"]
        if r["dir"] != "recv" or m.get("method") != "session/update":
            continue
        u = m["params"]["update"]
        if u.get("sessionUpdate") in TEXT:
            c = u.get("content") or {}
            if c.get("type") == "text":
                out.append((r["t"], u["sessionUpdate"], len(c.get("text", ""))))
    return out


def prompt_time(rows: list[dict]) -> float | None:
    for r in rows:
        if r["dir"] == "send" and r["msg"].get("method") == "session/prompt":
            return r["t"]
    return None


def segments(chunks: list[Chunk]) -> list[list[Chunk]]:
    out: list[list[Chunk]] = []
    for c in chunks:
        if out and c[0] - out[-1][-1][0] < PAUSE_MS:
            out[-1].append(c)
        else:
            out.append([c])
    return out


def analyse(streams: list[list[Chunk]]) -> dict:
    """Statistics over the chunks of [streams], each split at pauses."""
    segs = [s for st in streams for s in segments(st)]
    flat = [c for s in segs for c in s]
    sizes = [c[2] for c in flat]
    gaps: list[float] = []
    lumps: list[int] = []  # characters that appear together (one burst)
    burst_lens: list[int] = []
    windows: list[float] = []
    spans = chars_in_spans = 0.0
    for s in segs:
        gaps += [b[0] - a[0] for a, b in zip(s, s[1:])]
        run = [s[0]]
        bursts = []
        for c in s[1:]:
            if c[0] - run[-1][0] <= BURST_MS:
                run.append(c)
            else:
                bursts.append(run)
                run = [c]
        bursts.append(run)
        lumps += [sum(c[2] for c in b) for b in bursts]
        burst_lens += [len(b) for b in bursts]
        span = s[-1][0] - s[0][0]
        if span >= MIN_SPAN_MS:
            n = int(span // WINDOW_MS) + 1
            buckets = [0.0] * n
            for t, _, size in s:
                buckets[int((t - s[0][0]) // WINDOW_MS)] += size
            windows += buckets
            spans += span
            chars_in_spans += sum(c[2] for c in s)
    in_burst = sum(n for n in burst_lens if n > 1)
    mean_gap = statistics.fmean(gaps) if gaps else float("nan")
    sd_gap = statistics.pstdev(gaps) if gaps else float("nan")
    wmean = statistics.fmean(windows) if windows else 0
    return {
        "chunks": len(flat),
        "chars": sum(sizes),
        "size_p50": pct(sizes, 50),
        "size_p95": pct(sizes, 95),
        "size_max": max(sizes, default=0),
        "gap_p50": pct(gaps, 50),
        "gap_p90": pct(gaps, 90),
        "gap_p99": pct(gaps, 99),
        "gap_max": max(gaps, default=float("nan")),
        "pauses": len(segs) - len(streams),
        "burst_share": in_burst / len(flat) if flat else float("nan"),
        "burst_len_max": max(burst_lens, default=0),
        "lump_p50": pct(lumps, 50),
        "lump_p95": pct(lumps, 95),
        "lump_max": max(lumps, default=0),
        "burstiness": (sd_gap - mean_gap) / (sd_gap + mean_gap) if len(gaps) >= 8 and (sd_gap + mean_gap) else float("nan"),
        "win_empty": sum(1 for w in windows if w == 0) / len(windows) if windows else float("nan"),
        "win_cv": statistics.pstdev(windows) / wmean if wmean else float("nan"),
        "cps": chars_in_spans / (spans / 1000) if spans else float("nan"),
    }


def f(x: float, digits: int = 0) -> str:
    if x != x:
        return "-"
    return f"{x:.{digits}f}"


ROWS = [
    ("text chunks", "chunks", 0),
    ("characters", "chars", 0),
    ("chars/chunk p50", "size_p50", 0),
    ("chars/chunk p95", "size_p95", 0),
    ("chars/chunk max", "size_max", 0),
    ("gap p50 (ms)", "gap_p50", 1),
    ("gap p90 (ms)", "gap_p90", 1),
    ("gap p99 (ms)", "gap_p99", 0),
    ("gap max (ms)", "gap_max", 0),
    ("pauses of 1 s or more inside a stream", "pauses", 0),
    ("share of chunks arriving < 5 ms after the previous", "burst_share", 2),
    ("longest burst (chunks)", "burst_len_max", 0),
    ("chars appearing together (burst) p50", "lump_p50", 0),
    ("chars appearing together (burst) p95", "lump_p95", 0),
    ("chars appearing together (burst) max", "lump_max", 0),
    ("burstiness B", "burstiness", 2),
    ("share of 100 ms windows with no text", "win_empty", 2),
    ("chars per 100 ms window, coefficient of variation", "win_cv", 2),
    ("chars/s while flowing", "cps", 0),
]


def main() -> None:
    per_agent: dict[str, dict[str, list[Chunk]]] = {}
    ttft: dict[str, dict[str, float]] = {}
    files = sorted(TRACES.glob("*/*.jsonl"))
    for path in files:
        agent, scenario = path.parent.name, path.stem
        rows = load(path)
        chunks = text_chunks(rows)
        per_agent.setdefault(agent, {})[scenario] = chunks
        pt = prompt_time(rows)
        if chunks and pt is not None:
            ttft.setdefault(agent, {})[scenario] = chunks[0][0] - pt

    agents = sorted(per_agent)
    out = [
        "# Chunk cadence of the recorded traces",
        "",
        "Generated by `python3 tool/trace_cadence.py` from `app/test/fixtures/traces/<agent>/<scenario>.jsonl`;",
        "do not edit by hand. Captured by `tool/capture-trace.sh` on one machine, one run per scenario, tiny",
        "prompts: a sample of how each agent paces its `agent_message_chunk` / `agent_thought_chunk` updates, not",
        "a benchmark of the agents. Claude ran with the owner's own `~/.claude` settings (thinking always on, a",
        "Haiku model chosen through `session/set_config_option`), omp with its default model (Haiku 4.5 for",
        "`thinking`, because Sonnet 5.5 sent no thought text), codex with the model its default config picks for",
        "this ChatGPT Free account. pi was not captured: its login is expired (`docs/AGENT_SESSIONS.md`).",
        "",
        "What is measured: the time a chunk's line was read from the agent's stdout (a pipe on the same machine).",
        "The app sees something else: the keeper merges adjacent text chunks of one message in its replay log,",
        "SSH adds its own batching and latency, and `AcpAgentSession` coalesces notifications per 16 ms. This is",
        "the **source** cadence; the bench replays it at that rate into the real screen.",
        "",
        "Definitions. *Segment*: text chunks with no pause of 1 s or more between them (a tool ran, or the model",
        "thought); gaps and windows are taken inside segments, the pauses are counted. *Gap*: time between two",
        f"consecutive text chunks. *Burst*: a run of chunks each within {BURST_MS:.0f} ms of the one before (one read",
        "of the pipe): what a client that paints on arrival shows at once. *Burstiness B* = (sigma - mu) /",
        "(sigma + mu) of the gaps (Goh and Barabasi): -1 perfectly regular, 0 random, towards 1 bursty; shown from",
        f"8 gaps. *Window*: characters received per {WINDOW_MS:.0f} ms inside a segment of at least {MIN_SPAN_MS:.0f} ms.",
        "",
        "## By agent (every scenario pooled, thoughts and answer together)",
        "",
    ]
    stats = {a: analyse([per_agent[a][s] for s in sorted(per_agent[a]) if per_agent[a][s]]) for a in agents}
    out.append("| | " + " | ".join(agents) + " |")
    out.append("| --- | " + " | ".join("---:" for _ in agents) + " |")
    for label, key, digits in ROWS:
        out.append(f"| {label} | " + " | ".join(f(stats[a][key], digits) for a in agents) + " |")
    out += ["", "Time from `session/prompt` sent to the first text chunk (ms), per scenario:", ""]
    scen = sorted({s for a in ttft for s in ttft[a]})
    out.append("| agent | " + " | ".join(scen) + " |")
    out.append("| --- | " + " | ".join("---:" for _ in scen) + " |")
    for a in agents:
        out.append(f"| {a} | " + " | ".join(f(ttft[a][s]) if s in ttft.get(a, {}) else "-" for s in scen) + " |")
    out += ["", "## By scenario", ""]
    out.append(
        "| agent / scenario | chunks | chars | chars/chunk p50 / p95 / max | gap p50 / p90 / p99 / max (ms) "
        "| pauses >= 1 s | chars per burst p50 / p95 / max | < 5 ms | B | chars/s |"
    )
    out.append("| --- | ---: | ---: | --- | --- | ---: | --- | ---: | ---: | ---: |")
    for agent in agents:
        for scenario in sorted(per_agent[agent]):
            ch = per_agent[agent][scenario]
            if not ch:
                out.append(f"| {agent} / {scenario} | 0 | 0 | - | - | - | - | - | - | - |")
                continue
            s = analyse([ch])
            out.append(
                f"| {agent} / {scenario} | {s['chunks']} | {s['chars']} "
                f"| {f(s['size_p50'])} / {f(s['size_p95'])} / {f(s['size_max'])} "
                f"| {f(s['gap_p50'], 1)} / {f(s['gap_p90'], 1)} / {f(s['gap_p99'])} / {f(s['gap_max'])} "
                f"| {s['pauses']} | {f(s['lump_p50'])} / {f(s['lump_p95'])} / {f(s['lump_max'])} "
                f"| {f(s['burst_share'], 2)} | {f(s['burstiness'], 2)} | {f(s['cps'])} |"
            )
    out.append("")
    (TRACES / "CADENCE.md").write_text("\n".join(out))
    print(f"wrote {TRACES / 'CADENCE.md'} from {len(files)} traces")


if __name__ == "__main__":
    main()
