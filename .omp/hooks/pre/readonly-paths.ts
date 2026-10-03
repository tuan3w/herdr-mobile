// Keep reference material read-only. `third_party/` holds upstream clones used
// for reading only; `.agents/skills/` is installed from flutter/agent-plugins
// and is refreshed by `npx skills`, not hand-edited.
import { resolve, sep } from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

// <root>/.omp/hooks/pre/<this file>
const ROOT = resolve(import.meta.dir, "..", "..", "..");
const EDIT_TOOLS: Record<string, true> = { edit: true, write: true, ast_edit: true };
const PROTECTED = ["third_party", ".agents/skills"].map((p) => resolve(ROOT, p));

export function isProtected(path: string): boolean {
  const abs = resolve(ROOT, path);
  return PROTECTED.some((dir) => abs === dir || abs.startsWith(dir + sep));
}

function touched(input: Record<string, unknown> | undefined): string[] {
  if (!input) return [];
  const out = new Set<string>();
  if (typeof input.path === "string") out.add(input.path);
  if (Array.isArray(input.paths)) {
    for (const p of input.paths) if (typeof p === "string") out.add(p);
  }
  for (const value of Object.values(input)) {
    if (typeof value !== "string") continue;
    for (const m of value.matchAll(/^\[([^\]\n#]+)#[0-9A-Fa-f]{4}\]/gm)) out.add(m[1]);
  }
  return [...out];
}

export default function hook(pi: HookAPI): void {
  pi.on("tool_call", async (event) => {
    if (!Object.hasOwn(EDIT_TOOLS, event.toolName)) return;
    const hit = touched(event.input as Record<string, unknown>).find(isProtected);
    if (!hit) return;
    return {
      block: true,
      reason:
        `${hit} is read-only reference material (third_party/ clones, installed skills). ` +
        "Change app/ or docs/ instead; refresh skills with `npx skills add`.",
    };
  });
}
