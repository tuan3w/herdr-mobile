# UI/UX, read from code

`herdr-design` decides what a screen should be; this file only says how to find the problems
in a diff without rendering it. Every row you produce from it is "from code, not seen" until
`herdr-screen-check` has rendered it.

1. **Find the journey step.** Which of the person's five questions does the changed UI serve
   (needs me / alive / what did it do / steer / trust)? Open `herdr-design/references/journeys.md`
   for the surfaces that share the concept. If it serves none, it is a noise candidate.
2. **Never / Instead sweep, changed files only.** Run these and read the hits. A hit is a
   candidate, not a finding.
   - `grep -nE "InkWell|ListTile|AlertDialog|SnackBar|AppBar|NavigationBar|PopupMenuButton|SegmentedButton|ExpansionTile|FloatingActionButton|Icons\." <files>`
   - `grep -nE "Color\(0x|Colors\." <files>`
   - `grep -nE "textTertiary" <files>`
   - `grep -nE "copyWith\(fontSize" <files>`
   - `grep -nE "GestureDetector" <files>`, then check `minTapSize: kMinTap` or an enclosing
     `PressBuilder`.
   - `grep -nE "HapticFeedback|\.repeat\(|Curves\.|Duration\(milliseconds" <files>`: motion rules
     belong to `herdr-motion`; list the hits and hand off.
3. **State coverage.** For each screen or row the change touches, find the branch for: loading
   or first paint (cached, dimmed), live, stale, offline, failed, empty, one, many, compact
   layout. A state with no branch is a finding. Unavailable things must stay, dimmed, with
   their reason. A failure must say what happened and what to do next.
4. **Honesty.** A value shown without freshness; a saved copy that answers or acts; "running"
   where "was running" is true; liveness drawn from a timer instead of from the host.
5. **Guard proportion.** Cheap = tap. Slip = tap + Undo. Risky, irreversible or a standing grant
   = hold. Bulk = confirm sheet with live data. Check `tapGuard` on anything that appears under
   the thumb. Check that the command or path being approved is shown whole or behind `Read all`.
6. **Parity table.** When the changed concept appears on more than one surface (board card,
   triage sheet, pane answer dock, session prompt dock, notification), build the table
   `herdr-design` describes. Fill every cell from that surface's own code, not from the shared
   widget. An empty or differing cell is a finding unless a reason is written down.
7. **Words.** Sentence case, outcome first, numbers with units, a correct plural, no apology,
   recovery stated. Cut text: `maxLines` or ellipsis with nothing behind it; paths ellipsised
   at the end.
8. **Hand off.** List what only pixels or the phone can settle (overflow at 320 dp and text
   scale 1.6, contrast, the keyboard, touch feel) and name the skill that settles it. Mark each
   such row "from code, not seen".
