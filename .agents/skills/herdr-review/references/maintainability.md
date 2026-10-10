# Maintainability

The test is the six-month one: will the next change break because of this, or will the next
reader be misled? Everything here is P3 unless it hides a bug, and then it is reported as the
bug. Each item has a `check:`, the grep or read that finds it.

- **Two patterns for one job** (principle 6, "migrate to one"). check: grep for a sibling of any
  helper the change adds (shell-quote, escape-strip, diff, truncate, format helpers). A new one
  is a finding when an existing one does the job. A copy that missed a fix is a bug, not a
  style issue.
- **Layering** (`ui/` → view models → `data/repositories` → `data/services`; widgets never touch
  transports; the machine form's Test is the only exception). check: imports in changed files
  (`ui/core` importing `ui/features`; a widget importing `data/services`).
- **Clean cutover** (rule 9). check: callers of anything removed or renamed; names containing
  `deprecated`, `legacy`, `compat`, `old`; a re-export or alias; comments that name something
  that no longer exists.
- **God-class growth.** check: a file over 1,500 lines that grew (`AcpAgentSession`,
  `ObservedAgentSession`, `keeper_script.dart`): did the change add a second responsibility that
  belongs in its own type?
- **Values without a reason** (principle 9: every spacing, timing, colour and word comes from a
  token or a reason). check: raw `Color`, `Duration`, bare numeric thresholds, and error-message
  strings used as conditions.
- **Comments and docs that lie.** check: comments in changed functions that describe the old
  behaviour; a doc in `docs/` that names the changed behaviour (`AGENTS.md`: fix the doc when the
  change makes it wrong; `docs/DESIGN.md` only for system rules).
- **Conditional side effects.** check: a branch that skips a side effect its sibling branch
  performs; a log or toast that says something happened on a path that skipped it.
- **Swallowed errors.** check: `catch (_)`, `on Object`, `.catchError((_)`, `unawaited(` with no
  comment saying why the failure is fine.
- **Dead code.** check: unused imports, assigned-never-read locals, commented-out blocks,
  parameters nothing passes.
- **Tests that do not catch anything** (rule 8). check: tests that pin copy or wording, wiring,
  mock echoes or incidental defaults (delete or rewrite them); wall-clock budgets
  (load-dependent); full-suite tests that write files to `/tmp`; a test that cannot fail. Also
  the reverse: a fix with no test that fails before it.
