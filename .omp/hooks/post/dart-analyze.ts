// After the agent edits/writes a Dart file (or pubspec.yaml), run
// `dart analyze` on it and hand any findings straight back as trusted
// context. Silent when clean, so it adds no noise to a healthy edit loop.
//
// Never reformats: a formatter run would invalidate the edit tool's line
// anchors for the file the agent is still working on.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const run = promisify(execFile);

// <root>/.omp/hooks/post/<this file>
const ROOT = resolve(import.meta.dir, "..", "..", "..");
const APP = join(ROOT, "app");
const EDIT_TOOLS: Record<string, true> = { edit: true, write: true, ast_edit: true };
const MAX_LINES = 20;

/**
 * The SDK bin dir `tool/flutter-bin.sh` picks (HERDR_FLUTTER_BIN, else the
 * first Flutter whose Dart fits app/pubspec.yaml), asked once per process. An
 * older `dart` on PATH reports the repo's own syntax as errors. Undefined when
 * none fits: the hook then stays quiet rather than report a wrong SDK's noise.
 */
let bin: Promise<string | undefined> | undefined;
function flutterBin(): Promise<string | undefined> {
  bin ??= run(join(ROOT, "tool", "flutter-bin.sh"), [], { cwd: ROOT, timeout: 30_000 }).then(
    ({ stdout }) => stdout.trim() || undefined,
    () => undefined,
  );
  return bin;
}

/** Paths an edit-ish tool call touched, from derived fields and hashline headers. */
export function editedPaths(input: Record<string, unknown> | undefined): string[] {
  if (!input) return [];
  const found = new Set<string>();
  if (typeof input.path === "string") found.add(input.path);
  if (Array.isArray(input.paths)) {
    for (const p of input.paths) if (typeof p === "string") found.add(p);
  }
  for (const value of Object.values(input)) {
    if (typeof value !== "string") continue;
    // hashline: "[path/to/file.dart#1A2B]"
    for (const m of value.matchAll(/^\[([^\]\n#]+)#[0-9A-Fa-f]{4}\]/gm)) found.add(m[1]);
  }
  return [...found];
}

/** Dart files inside app/ worth analyzing. */
export function analyzable(paths: string[]): string[] {
  return paths
    .map((p) => resolve(ROOT, p))
    .filter((abs) => abs.startsWith(`${APP}/`) && abs.endsWith(".dart") && existsSync(abs));
}

export interface Finding {
  severity: string;
  code: string;
  file: string;
  line: string;
  col: string;
  message: string;
}

/** Parses `dart analyze --format=machine`: SEV|TYPE|CODE|FILE|LINE|COL|LEN|MESSAGE */
export function parseMachine(out: string): Finding[] {
  const findings: Finding[] = [];
  for (const line of out.split("\n")) {
    const parts = line.split("|");
    if (parts.length < 8) continue;
    const [severity, , code, file, ln, col, , ...msg] = parts;
    findings.push({ severity, code, file, line: ln, col, message: msg.join("|") });
  }
  return findings;
}

export function render(findings: Finding[]): string {
  const rank: Record<string, number> = { ERROR: 0, WARNING: 1, INFO: 2 };
  const sorted = [...findings].sort(
    (a, b) => (rank[a.severity] ?? 3) - (rank[b.severity] ?? 3),
  );
  const lines = sorted.slice(0, MAX_LINES).map((f) => {
    const rel = relative(ROOT, f.file);
    return `${rel}:${f.line}:${f.col} ${f.severity.toLowerCase()} ${f.code} - ${f.message}`;
  });
  const more = sorted.length - lines.length;
  if (more > 0) lines.push(`… and ${more} more`);
  return lines.join("\n");
}

export default function hook(pi: HookAPI): void {
  pi.on("tool_result", async (event) => {
    if (event.isError || !Object.hasOwn(EDIT_TOOLS, event.toolName)) return;
    const files = analyzable(editedPaths(event.input as Record<string, unknown>));
    if (files.length === 0) return;

    const sdk = await flutterBin();
    if (!sdk) {
      pi.logger?.warn?.("dart-analyze hook: no Flutter whose Dart fits app/pubspec.yaml (run tool/flutter-bin.sh)");
      return;
    }
    const env = { ...process.env, PATH: `${sdk}:${process.env.PATH ?? ""}` };
    let stdout = "";
    try {
      ({ stdout } = await run("dart", ["analyze", "--format=machine", ...files], {
        cwd: APP,
        env,
        timeout: 60_000,
      }));
    } catch (err) {
      // dart analyze exits non-zero when it finds issues; its report is on stdout.
      const e = err as { stdout?: string; code?: string | number; message: string };
      if (typeof e.stdout !== "string" || e.stdout === "") {
        pi.logger?.warn?.(`dart-analyze hook could not run: ${e.message}`);
        return;
      }
      stdout = e.stdout;
    }

    const findings = parseMachine(stdout);
    if (findings.length === 0) return;
    return {
      additionalContext:
        `dart analyze reported ${findings.length} issue(s) in the file(s) you just edited. ` +
        `Fix them before moving on:\n${render(findings)}`,
    };
  });
}
