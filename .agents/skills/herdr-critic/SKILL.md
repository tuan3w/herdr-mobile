---
name: herdr-critic
description: An independent design critique of rendered screens or a prototype, done by a fresh reviewer who sees only the pixels, the person's moment and the project's rules, never the builder's pick. Use it before presenting prototype directions to the owner, after a UI change has been rendered, and whenever someone asks for a critique, a second opinion, "what's wrong with this", "tear it apart", "which one is better" or a design review of screenshots, even if they don't say critic. It exists because the person who built a design is the worst judge of it.
---

# Critiquing a design

Whoever built a screen has already decided it works. They know what each row
means, which variant they like and why, so they read the pixels with that
knowledge and miss what a person holding the phone would not see. A critique
is useful only when it comes from someone who has none of it. So the whole
method is about keeping the critic's view clean, then using what it says.

This skill judges what is on screen. `herdr-design` decides what the design
should be, `herdr-prototype` makes the options, `herdr-screen-check` proves the
chosen one at every size. The critic runs between those: after the pixels
exist, before anyone is told which is best.

## 1. Give the critic only what a user would have

Pass: the PNG paths, one sentence for the moment ("on the train, glancing at
the board to see which of my 16 agents to look at"), and the five questions of
`herdr-design`. Add the rules to judge against: the "Never / Instead" table in
`herdr-design` and `docs/DESIGN.md`.

Withhold: your recommendation, your reasoning, which variant is "today", and
which fields are invented or stand-ins, until it has written its first reading.
Knowing the winner makes a critic look for reasons to agree. Then tell it which
render is the baseline and what is invented or a stand-in, and ask it to
re-read with that. Comparing against today is part of the job. A finding that
only exists because a stand-in is cruder than the real widget (a truncated
command on a plain row, where the real card shows three lines) is the
builder's artefact: drop it, and say in the report that you did.

Spawn it as a read-only subagent (`reviewer`, or `scout` if images are all it
needs) so it has a fresh context. `reviewer` answers in its fixed code-review
schema: read the PNG name in `file_path` and the table fields in `body`. Put
these lines in its task text: it must not edit files; it must not kill any
process; it cites a PNG for every finding. If you have no subagents, do the
pass yourself, and write your glance-test answers down before rereading your
own report.

## 2. What the critic does, in order

1. **Glance test, per image, before anything else.** In three seconds: what
   needs me? what is each row? which would I open first? Write the answers
   down. Where the critic cannot say what a row is, that is the finding, and it
   is more reliable than any rule.
2. **Five questions, per variant.** Does anything need me, is everything on
   track, what did it do, can I steer, can I trust it. Say which each variant
   answers faster or slower than today, and what it costs (taps, reading,
   height, risk).
3. **Noise ledger.** The same fact said twice, decoration, a label for the
   obvious, an option on the main path that few need. Mark keep or remove.
4. **Rules, as far as pixels show.** The Never / Instead table: touch targets,
   status by shape and colour, text tiers and contrast, no raw ids where a name
   exists, nothing cut without saying so. Say "from code, not seen" for the rest.
5. **Honesty.** Is anything shown that the app may not know? A stale value, a
   saved copy, or an invented field drawn as if live is a finding.
6. **Steel-man the baseline.** What does today do well that a variant loses? A
   list that got shorter may have hidden what it should show.
7. **Rank, then say what would flip it.** Without being told the builder's pick,
   order the variants and give the one fact that would change the order.

## 3. What comes back

Findings, worst first, in the form `herdr-design` uses for reviews:

| # | Severity | Journey step | What the person experiences | Why it matters | Change | PNG |
| --- | --- | --- | --- | --- | --- | --- |

Severity is Broken, Friction, Noise, Inconsistent or Polish. Then the glance-test
answers, the ranking, what the builder probably missed, and the decisions that
have more than one right answer. Default to flagging; praise only what should
not be "fixed". Keep it short: ten findings that matter beat thirty.

## 4. Use it honestly

Compare the critic's ranking with yours. If they differ, say so in the report
and say why you still stand where you do, or move. Never drop a finding because
it is inconvenient; a finding you disagree with goes under "decisions for the
owner" with both views.

A critique cannot judge feel, touch, motion or whether the real data exists.
Name those as unchecked, as `herdr-screen-check` does.
