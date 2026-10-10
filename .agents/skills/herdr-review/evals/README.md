# herdr-review evals

Ten replay cases. Each is a real finding of `docs/REVIEW-2026-10-09.md` (or, for `b6`, a bug found
on 2026-10-10): the reviewer is given the code as it was before the fix and must find the bug.

- A case's copy is `git archive <base_rev> app tool` extracted to `/tmp/hm-replay/<name>`. It has no
  history and no docs, so the fix and the review cannot be looked up. `b6` uses `a3b14ea`, which
  still has the bug (the fix was uncommitted).
- Run each case twice, with and without the skill (`herdr-review/SKILL.md` as the skill path), and
  compare. `evals.json` holds the prompts; the `with_skill` prompt adds the skill path.
- Score by file, line range and keywords, as `expectations` says: `file` plus `alt_locations` give
  the places the finding may be reported (the maintainability cases are about copies), the line
  range gets 15 lines of slack, and at least two `keywords` must appear in the finding's text.
- Priority is scored against the known priority: more than one level above it is inflation.
- Lenses: `bug` (b1 to b6), `ux` (u1, u2), `maint` (m1, m2). Three lenses are measured, but the
  bug lens has most cases.
- These findings are held out of the skill's references on purpose. Do not add a case's bug to
  `references/` or `SKILL.md`; when a case is "learned", replace it with a new replay.
