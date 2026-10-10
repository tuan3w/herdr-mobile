---
name: herdr-review
description: Review herdr-mobile code for bugs, UI/UX problems and maintainability, and reproduce every serious finding before reporting it. Use it whenever someone asks to review, audit, check, look over, find bugs in, "is this safe to commit/merge/release" or "what's wrong with" a diff, a commit, a branch, uncommitted changes, or a named area (a subsystem, a directory, a file), and before committing or releasing non-trivial work, even if they only say "take a look". For a change it reviews the diff and what the diff can break; for an area it runs a multi-lens sweep. UI is judged from code; for rendered judgement it hands off to herdr-screen-check and herdr-critic.
---

# Reviewing herdr-mobile

A review is worth the bugs it finds that the owner would otherwise ship. It fails in two ways:
the reviewer reads what the code is *meant* to do (the author's view), and it reports guesses as
facts. The 2026-10-09 review (22 reviewers) is the proof: re-verification found none of its
findings wrong, but several P1 labels were P2 or P3 "once you ask who can trigger them", and
about 240 findings were never checked at all. So: read what the code does, name the input that
breaks it, then prove it before you say it.

This skill reads code. `herdr-design` decides what a screen should be, `herdr-screen-check` and
`herdr-critic` judge pixels, `herdr-motion` judges movement. Where a finding needs pixels, say
"from code, not seen" and name the skill that settles it.

## 1. Pin what is reviewed

- **A change** (default): "my changes", a commit, a branch, uncommitted work. The base is the
  commit it started from (`HEAD` for uncommitted work).
- **An area** (only when asked): a subsystem, directory or "audit X". Go to section 6.
- The working tree often holds other people's unfinished work: the owner's, or another agent's.
  On 2026-10-10 it did not compile. Review only the files that belong to the change, list the
  other modified files as out of scope, and never stash, checkout, reset or format the tree.
- Run `scripts/review_packet.sh [base]`. It lists the changed files in risk order, the tests and
  docs that name each one, and type names the change removed that are still referenced. It is
  the plan; it is not the review.
- Read the intent: the commit message, the plan, the owner's words. Behaviour that is intended
  is not a finding, unless it breaks a principle in `AGENTS.md` (then it is a decision for the
  owner).

## 2. Read around the diff, not only in it

The bug is usually in what the diff assumes about code it did not touch. For each changed symbol:

- Its callers (`xd://lsp` references, else grep) and what they assume.
- Every consumer of a value the change adds (an enum member, a state, a wire field, a setting).
  Read each switch and filter. A new value that falls into a default branch is the classic miss.
- Its twin: the same job done elsewhere (`AGENTS.md`, product principle 6). A fix applied to one
  copy and not the other is a bug.
- The doc of the subsystem in `docs/` (`AGENTS.md`: read it before changing the subsystem).
- The test beside it, and what it actually pins.
- What the change deleted: callers of removed things, comments and docs that now say something false.

## 3. Three lenses on every changed file

Go through them in order; bugs first, because polish on wrong behaviour is decoration.

| Lens | Question | Reference |
| --- | --- | --- |
| **A. Bugs** | What input or state makes this code do the wrong thing, and who hits it? | `references/bug-classes.md` |
| **B. UI/UX, from code** | Which of the person's five questions does this serve, and where does it lie, strand or surprise them? | `references/ux-from-code.md` |
| **C. Maintainability** | Will the next change break because of this, or will the next reader be misled? | `references/maintainability.md` |

Read the reference of a lens when the diff touches its ground: the bug classes for any logic,
the UI reference for anything under `lib/ui`, the maintainability reference for any change that
adds, copies, renames or deletes code.

## 4. What counts as a finding

A finding has all of these; without them it is a **lead** (confidence under 0.5, listed apart):

1. **Trigger:** the concrete input, state or sequence. "Might", "could", "consider" is not one.
2. **Who:** which person or run reaches it, and how often. A bug only a hand-edited file can
   reach is P3 however bad it looks.
3. **Evidence:** `file:line` and the code quoted exactly as it is on that line.
4. **Confidence:** 0 to 1, from section 5: `ran` 0.9 and up, `read` 0.5 to 0.8, `lead` below 0.5.

Priority, by what happens to the person:

- **P1:** silent approval, data loss, a security hole, a freeze, a dead end with no way out.
- **P2:** visibly wrong behaviour, a likely leak, typed work lost, a stale value shown as live.
- **P3:** rare, narrow, or maintainability.

UI/UX findings use `herdr-design`'s words as well: Broken, Friction, Noise, Inconsistent, Polish.

**Not findings:** behaviour the commit message or plan states as intended; code the change did
not touch and does not depend on; a decision `docs/DESIGN.md` records with a reason (reopen it
only with new evidence, and say what the evidence is); style no rule states; missing comments or
types; anything you only suspect (that is a lead).

## 5. Prove it before you report it

Every P1 and P2 bug claim, and any other claim the owner would act on, gets one more step:

1. **Try to break it with a throwaway test or script, in a clean copy.** Never in the main tree
   (it may not compile, and it holds unfinished work): `references/reproduce.md` has the commands.
2. **Record how it was checked:**
   - `ran`: the test or script failed on this code in the way the finding says.
   - `read`: traced by reading every step; nothing ran. Say why it could not run.
   - `lead`: not verified. Never stated as a fact.
3. **Set the priority after, not before.** Ask who can trigger it. Move it down when the trigger
   needs something no person or run produces; keep a down-rated finding listed so the owner
   sees the call.
4. **Say what you could not check.** Frame stalls, battery, the keyboard, touch feel and anything
   that depends on the real host or phone are unmeasured until measured on the phone
   (`AGENTS.md`, engineering principle 1). Name them; never quote a desktop number for the phone.

If you have subagents, verify with a fresh one that is given the finding (symptom, `file:line`,
trigger) and not your severity reasoning, so it tests the claim instead of agreeing with it. If
you have none, do it yourself and write the reproduction down before you re-read your own report.

## 6. Area sweeps (only when asked)

A sweep is for a subsystem or a release: the owner has asked for breadth, so spend it.

- **Round 1: split by ground,** following the layering (`ui/` → view models → `data/repositories`
  → `data/services`): `data/services`; `data/repositories`; `data/acp` and `data/observed`;
  `ui/features` by feature group; `tool/`, Android and CI; `keeper_script.dart`. One read-only
  reviewer each (`reviewer`; `scout` when only reading is needed). A small area gets one
  reviewer per lens instead.
- **Round 2: split by lens,** only when round 1 was dense: lifecycle, error handling,
  performance, security, tests and docs, terminal rendering. Tell each reviewer the findings
  already known (`docs/REVIEW-*.md`, round 1) and to skip them, so round 2 finds new ground.
- **Put these lines in every reviewer's task text:** it must not edit files; it must not kill any
  process (`AGENTS.md`: never kill a process you did not start); it cites `file:line` and quotes
  the code; it gives the trigger and a confidence for every finding; at most ten findings.
- **Then verify** with section 5, one fresh `task` agent per P1/P2 finding (small ones may share
  an agent), each in its own copy. Merge duplicates. A claim the verifiers could not confirm
  goes under leads.

## 7. Report

Short and ranked: ten findings that matter beat thirty. Findings first, praise only for what
should not be "fixed". Use this shape:

1. **Verdict:** `Block` (a P1, or a P2 the change introduced), `Approve with conditions` (list
   them), or `Approve`. One line why.
2. **Bugs, worst first:**

   | # | Pri | Class | Trigger and who | Evidence (`file:line`, code) | Checked | Fix |
   | --- | --- | --- | --- | --- | --- | --- |

   `Checked` is `ran`, `read` or `lead`, with the command or test name for `ran`.
3. **UI/UX, from code,** in `herdr-design`'s table (journey step, what the person experiences,
   why it matters, change, `file:line`), each marked "from code, not seen" unless a render was
   opened.
4. **Maintainability:** the same table; each row says what breaks later.
5. **Leads:** unverified, with the check that would settle each.
6. **Decisions for the owner:** questions with more than one right answer, with your
   recommendation; any documented decision you think should be reopened, with the evidence.
7. **Not checked** (phone, frames, real host, pixels) and **what held up**, so nobody "fixes" it.

Fix only if asked. When asked: fix the confirmed findings, keep each reproduction as a
regression test that fails before and passes after (`AGENTS.md`: tests catch what a person would
notice; delete tests that pin wording or wiring), and run `tool/check.sh`.

## What a review can't tell you

Touch feel, scroll physics, the keyboard, frame time, battery and radio cost, and whether the
host's real data has the shape the code assumes. Say which of these remain unchecked instead of
implying the change is safe.

## Never / Instead

| Never | Instead |
| --- | --- |
| "This might race" with no sequence | The two interleaved steps, in order, or a lead |
| P1 because it looks bad | P1 because of what happens to the person, after asking who can trigger it |
| A finding on a changed line only | Read callers, consumers of added values, and the twin |
| Reproduce in the main working tree | A clean copy in `/tmp` (`references/reproduce.md`) |
| Stash, checkout or format to get a clean tree | Review only the files in scope; list the rest as out of scope |
| Praise or "looks good overall" | The checked list under "what held up" |
| Re-argue a decision `docs/DESIGN.md` documents | New evidence, or leave it |
| "Fixed" without a test that failed first | A reproduction kept as a regression test |
