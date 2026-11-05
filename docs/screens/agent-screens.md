# Agent screens and the pane

One agent per screen, the pane, its bar and terminal, and the composers they share.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

## One agent per screen

An agent screen shows one agent: a terminal pane's terminal (`PaneScreen`) or
its chat (an agent session, or an omp, Claude Code or Codex pane followed through its log). Every
way in opens it through `openAgent` (`agents/agent_navigation.dart`): the
board, notifications and links, the start forms, Duplicate, past sessions and
the agent screens themselves. An agent already in front in that view is left
as it is. Why: the pane used to have browser-style tabs, and they held
terminals only (an agent the app can read opens as a chat by default, agent sessions were
always pushed screens), so they were a second, partial list of agents beside
the board, with its own count and order. The board is the
one scan surface; an agent screen is for one agent.

- **A swipe walks what wants the person** (the triage walk,
  `agent_navigation.dart`). Inside an agent screen (over the terminal panel,
  or the chat's transcript) a swipe left goes to the next stop of the walk,
  a swipe right retraces it. The walk is the agent in front, then the board's
  Needs you and then its Done, in the board's own order (`AttentionSet`:
  what can be reached first, longest waiting first, panes and sessions
  mixed). Working and idle agents are not on it; the title's switcher
  reaches them. The order is frozen at the first swipe (or the first `Next
  agent` / `Previous agent`, the screen's accessibility actions, which walk
  the same stops) and kept with the navigator, since every step replaces the
  route; opening an agent any other way, or Back to the board, ends it. An
  agent that stopped needing the person meanwhile stays on the walk (its
  card shows what it is now); one the board no longer lists is skipped. Why
  frozen: the order used to be read from the board at every swipe, so
  answering the agent in front moved it from Needs you to Working and a
  swipe back did not return where the person came from; and walking every
  agent took many swipes to reach the one that needed them.
- **The swipe shows who is next before it goes** (`AgentPeekCard`,
  `agent_peek.dart`). While the finger moves, a card with the agent as the
  board's row shows it (status glyph, title, one line of what it asks or last
  said, `agent · machine · folder`, time in state, and its place in the walk,
  `2 of 4`) comes in from the side the finger moves toward, driven by the
  finger and fully in by 96 dp (1.5x the commit distance: it is a reveal at
  the edge, not an object under the finger, so at 64 dp two thirds of it
  already show), centred on the content's height. It leads with the glyph and the
  title on the side it enters from (the previous agent's card is laid out
  right to left). The screen under it does not move. The line is the
  question it waits on (a pane's prompt, a session's request), else its last
  terminal row or last sentence, only from what is already in memory
  (`PanePreviews.known`, the session's transcript), else nothing: nothing is
  read for a peek (battery and radio). On a short content area it drops
  lines, least needed first. Past 64 dp the card takes a faint accent tint
  and the armed edge (`Ds.armedEdge`), its place reads `Let go to open`, and
  a `tick` says letting go will go there; coming back under it ticks again. Letting go goes if the travel, with the
  fling's speed projected (`Springs.projectSheet`), passes 64 dp, so a quick
  flick is still instant; otherwise the card springs back
  (`Springs.settle`, from where it is, with the finger's speed) and nothing
  happens. It goes to the agent the card showed; one the board no longer
  lists is not opened (a `tick`). The card fades as the next screen slides in. Under reduced motion
  the card does not slide: it sits in its place and fades in with the
  finger's travel. Why: an instant switch felt great, but nobody knew what
  came next, and there was no way to back out.
- **What counts as the swipe** (`AgentSwipeDetector`, `agent_swipe.dart`):
  one finger the whole time (a second one is a pinch), 22 dp sideways (past
  the touch slop) within 450 ms of touching down, with under 40% as much
  vertical travel, and not a finger that first went more than 24 dp
  vertically (a scroll, for the rest of the touch). From then on there is no
  time limit: the finger drives the card. Turning vertical, a second finger
  or anything under the finger scrolling takes the card back and nothing
  happens.
  Why the numbers: a long-press selection starts at 500 ms, so a selection
  drag is never a swipe, and a scroll that drifts is not either.
- **What never triggers it.** A touch that starts within 24 dp of the
  screen's sides: the system back gestures live there. Anything under the
  finger that scrolled sideways during the touch (a code block, a table, a
  terminal wider than the screen with wrap off): that swipe is theirs, and a
  scrollable claims the drag at the touch slop, before the swipe is
  recognised. A slanted drag that the transcript or the terminal scrolls
  with is a scroll: the card goes back, or never shows. The detector listens to raw pointers and never joins the
  gesture arena, so scrolling, link taps, selection and pinch zoom behave
  exactly as without it.
- **The ends.** Past the walk's last stop a quiet card says `All caught up`
  and how many agents work on without the person (`All caught up · 3
  working`); before its first, `No previous agent`. It comes in against
  resistance and never arms, and letting go springs it back with a `tick`.
  The `Next agent` / `Previous agent` accessibility actions tick and say the
  same words out loud. Why: the walk does not wrap round, so the person
  feels where it ends instead of landing back on the first agent without
  noticing, and its end is the answer to "does anything need me".
- **Chat and Terminal are one agent's two views, switched from its menu.** An
  agent with both (a pane the app can follow through its log) has `Show terminal` in the
  chat's `Session options` and `Show chat` in the terminal's `Pane options`.
  It swaps the view in place, and the choice is remembered for that agent for
  the app run: the board and the swipe open it in that view after. Settings >
  `Open agents as` stays the default for an agent with no choice yet; a
  pane whose agent has no chat opens its terminal and offers no `Show chat`. A
  Claude Code or Codex pane that herdr reports no session for offers `Read as chat…`
  in its terminal's options, always (not only after a look for the log failed): it installs herdr's hook for that agent
  on the machine after one confirmation (`connect_chat.dart`), which makes
  the agent report its session.
  Why: the old `Terminal` action replaced the chat, and nothing in the
  terminal led back to it. It then became a
  two-icon toggle in every bar, 88 dp that the title needed, for something
  done a few times a day; the menu costs one more tap and gives the bar back.
- **The title is the agent switcher** (`agents/agent_switcher.dart`), in the
  chat's bar and the terminal's alike. A small chevron follows the title and,
  while other agents need the person, their count (`CountBadge`, the board's
  Needs you less the agent in front; nothing at 0, nothing moves). A tap opens
  one sheet (`showAppSheet`) listing every agent the board lists, in the
  board's sections and order, each row its status glyph, task title and a line
  naming where it runs: the folder, or for agents on one machine whose folders
  share a name (worktrees of one repo) the folder and branch
  (`web-app · fix/login-redirect`, `agent_identity.dart`), then the agent kind
  (and the machine with several). The agent in front says `Here` and does
  nothing; another row replaces the screen, as the board opens it, so Back
  still lands on the board; the last row, `All agents on the board`, goes
  back. The screen reader hears `Switch agent, <title>, 2 other agents need
  you`. It reads only what is in memory: the board's lists and the branches a
  machine already read (`MachineConnection.branchOf`); a branch never read
  leaves the folder alone, and nothing is fetched for the sheet (battery). The
  bar rebuilds only when the count changes. Why: the swipe reaches one agent at
  a time and only the ones that want the person; from inside a chat the person
  needs "does anything else need me" and a way to any agent, without giving
  the title's room to a second bar. The session overview, which the chat's
  title used to open, stays in `Session options`.
- **Drafts are kept per agent** for the app run (`AgentScreens.keepDraft`),
  shared by the agent's chat and terminal. Why: a swipe and the view switch replace
  the screen, so what is typed must live outside it; with tabs, a draft in a
  hidden tab was lost past six live panes and closing a tab dropped it.
- **Back always goes to the board** (where the person came from). A swipe,
  the switcher and the view switch replace the screen in front instead of
  pushing, and a
  notification or a link replaces the agent screen in front, if one is. Why:
  walking ten agents must not leave ten screens to back out of.
- **Motion.** A swipe replaces the route: the new screen slides a short way
  (0.2 of the width) and fades in over `Motion.standard`, from the side the
  finger came from, while the screen under it stays still (no parallax). The
  toggle only fades, over `Motion.fade`: the same agent, so nothing slides.
  Under reduced motion a swipe is that fade. At launch the screen is back at
  once (below, "What survives a launch"). Once in, the route is a page like
  any other: Back and the edge swipe use the page transition.

## Pane bar

One bar of about 56 dp (`AppTopBar`): back, status glyph and title over
`agent · machine`, then files and `Pane options` (`⋯`), never more than two
actions. Why: a third circle cut the title. The options are the one way to the
pane's actions: `Show chat` (for an agent with both views), `Wrap lines`,
`Duplicate`, `Copy title`, `Copy pane id <id>` (the raw id lives there, not in the bar). The title
is the agent switcher (above), and nothing else hides behind it: no long press,
no pull-down.
Where a blocked pane's prompt is
understood, the question and up to three answers plus `N more` dock above the
key row (`AnswerDock`). The dock is hidden in the compact and short layouts.

The answer dock shows the question in two lines and the command (`subject`)
in mono in two more (`QuestionWash`, compact); `Read all` opens the rest when
either is cut.

The dock's answers take no tap and are dimmed for `tapGuard` each time the dock
appears (the pane turns blocked, its screen opens by a tap, a swipe or the
toggle, the link comes back)
and each time its question changes, a new question after `Sent` included
(`TapGuardState`, checked in the chip and again in the handler). Why: the dock
comes up right above the key row and the composer, so the thumb is already
there, pressing Enter or typing, when it arrives; without the guard that press
answered whatever question had just slid under it.

While the dock shows a question, a bare Enter does not reach the pane: the key
row's Enter and the keyboard's send on an empty composer press nothing, give a
tick and toast `Pick an answer above`. Why: in the agent's menu Enter accepts
the highlighted option, so it would answer past the dock's hold on a risky
option and past its guard. Arrows, Esc and a Ctrl/Alt Enter still go through
(deliberate moves in the menu), typed text still sends as a line, and with no
dock (compact or short layout, or a prompt the app does not understand) Enter
is left alone.

**Terminal jump pill** (`terminal_jump.dart`, in `TerminalView`). Away from the
newest row it is the round chevron (`Jump to latest`); when rows arrive after
the reader left (net rows added at the end, so rows the read window drops from
the top do not count, nor a redraw in place) it is a pill, `3 new lines`,
`99+ new` past 99, counted from zero each time they leave and reset on
reaching the end. A pane that turns blocked while they are away makes it
`Needs you` with the blocked glyph (one already blocked when they left is
not news; the dock shows it); that wins over the count. A tap fires `Haptics.tick`
and scrolls to the end: `Motion.easeOut` over `Motion.expand` when under 3
viewports away, an instant jump otherwise and under reduced motion. It is a
compact `FloatingPill`: it comes and goes with opacity and scale (from
`Motion.enterScale`, over `Motion.release`; a fade only under reduced motion)
and keeps its words while fading out.

**Live edge** (`live_edge.dart`, bottom of the terminal panel, inside the
outline). A 2 px rule: accent-tinted when the last read brought new output
(`PaneViewModel.streaming`), `hairline` when it found nothing new. While the
link is down or a read failed, the text dims to the closed-pane alpha (0.6)
and the rule is `danger` (read failed) or `textMuted` (link down only) with
a label `stale · 12s`, seconds since `PaneViewModel.lastRead` (then `1m`,
`1h`). One timer a second redraws that label, only while stale and on
screen; a live pane has no timer and no ticker. The
screen reader hears `Output is stale` once. A closed pane is dimmed, not stale.


## Composers

- **Send haptics follow the outcome; a failed send loses nothing.** One
  contract for both composers: `sent` fires when the message was taken and
  `failed` when it was not, never before the outcome is known (a session
  composer that buzzed `sent` and cleared the field before an observed agent's
  send failed left the person with neither the text nor a true signal). The
  pane composer keeps its text until the request is accepted (the tap itself
  already ticked). A failed send's banner stays through the reads that
  follow, until a send succeeds or Retry is pressed; text typed while a send
  was in flight is kept. The session composer empties at once (an ACP prompt
  is taken the moment it starts, and its turn is not waited for:
  `AgentSessionView.sendBlocks` completes with whether the message was kept)
  and on a failure puts the text and attachments back, ahead of anything typed
  or attached meanwhile.
- **Quick phrases**: a row of chips above the composers (pane and agent
  session), shown while the field is focused and empty, never in the compact
  layout. A tap fills the field and never sends. Edited in Settings; prefs key
  `quickPhrases.v1`, 12 phrases of at most 80 characters. Up to 3 learned
  chips (`SentPhrases`, key `sentPhrases.v1`) follow the person's own list, or
  lead the shipped defaults while the list is untouched: a message really
  sent beats a guess, and an edited list never moves. A message is learned
  only from text sent to an agent (never a line typed into a shell), after
  its second send, one line, no address, no token of 24+ characters, 300
  remembered at most. Why: replayed on a year of one person's messages, 14% were
  exact repeats and these chips finish 5% of messages in one tap, twice the
  defaults (`tool/predict-eval`); what a person types can hold secrets, hence
  each limit.
- **Dictation** (`ui/features/dictation/`): the mic takes Send's place in both
  composers (agent session, and a pane that has an agent) while the box is
  empty and the link is live: the same 36 dp disc, neutral at rest, the accent
  while it listens, and it stays the stop button while it listens although the
  box now holds the words (the button never turns into Send under the thumb
  mid-sentence). What is heard goes into the box at the cursor and never
  sends: the person reads it and presses Send, as with a quick-phrase chip. A
  long press picks the language: English and Tiếng Việt always have a row, dimmed
  with the reason when the phone's speech service lacks them; the choice is kept
  (`dictation.language.v1`). Not offered for a line typed into a shell. Why: a
  phone is faster to speak to than to type on, one-handed, and a wrong word
  sent to an agent is worse than a wrong word in the box.
- **Zoom detents**: pinch-zooming the terminal ticks at each whole font size
  and gives a firmer `hold` at the minimum and maximum.

## The terminal follows the theme

A pane is drawn on paper in the light theme and on ink in the dark one
(`TerminalPalette.light/dark`, `context.terminal`); Settings > Look > Dark
terminal keeps it dark on paper. The ANSI parser always yields the dark
`TerminalColors`; `TerminalPalette.recolor` turns a row's runs into the
palette's when the row is prepared (the dark palette returns the run itself, so
it costs nothing). On paper, the 16 ANSI colours are darker hues that reach
4.5:1 on white, text with a background of its own and no colour picks the
default that reads on it, and any text below 3.5:1 against its background is
pulled toward black, so a TUI that chose pale greys for a dark screen stays
readable.

## Wrap keeps tables whole

Wrap re-flows prose to the phone's width. A row of a table or a box (line
characters, a markdown or ASCII table: `table_lines.dart`) is never cut, since
cut in pieces it means nothing; when one is wider than the view, the view
scrolls sideways for it, and the agent swipe stands aside, as it does for
anything that scrolls sideways.
