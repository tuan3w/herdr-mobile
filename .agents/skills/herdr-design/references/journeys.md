# The app as a whole: journeys

These are the jobs a person comes to the app for, each traced as the moment, the
ideal shape, and what must hold on every surface it touches. It describes
intent, not code. The code moves on, so trace the current path in the code
(search for the screen or symbol) and compare it with the shape here. When the
shape itself changes, update this file.

## Surfaces, by role

| Role | Surfaces |
| --- | --- |
| Overview | the Agents board (every agent on every machine, by what it needs), the Machines tab |
| Attention | the needs-you notification, the in-app arrival haptic, the badge, the triage pill and sheet |
| Answer | the board card's chips, the reply sheet, the pane's answer dock, the session's prompt dock, the notification's buttons |
| Follow | an agent screen: the terminal pane (live edge, jump pill) or the agent session (transcript, status line, overview, background strip), the swipe to the next agent in the board's order, the options' `Show terminal` / `Show chat` |
| Steer | the composers, the key row, the slash and command palettes, quick phrases, the attach sheet, mode and model |
| Start | the `+` (Agents tab, machine screen), the new agent session form, Duplicate, past sessions |
| Review | the done section, swipe to review, Mark all reviewed, the Changed card, the file viewer, the photo viewer |
| Set up | the machine form (keys, Tailscale, connection test), Settings |
| Trouble | status strips and panels, stale dimming, the session link strip, Retry |
| Away | the background profile, the Watching notice, notifications |

## Words: one object, one name

Machine, workspace, tab (herdr's own: a workspace holds tabs, a tab holds
panes), pane, agent, agent session, turn, subagent, job.
`Needs you` (blocked), working, done, idle; reviewed / to review; stale,
offline, saved copy. Use these words everywhere: in the UI, the
notifications, the docs and the code. Before adding a word, check whether one of
these already means it.

## The journeys

### 1. An agent needs me

- **Moment.** Away from the desk, a notification or a haptic. They want to know what it asks,
  whether the safe answer is obvious, and to answer and leave.
- **Ideal shape.** Trigger → the question and the exact command, in one place →
  one tap (safe) or one hold (risky) → a confirmation they can feel → the
  next waiting agent comes up without a search → `All clear` → leave.
- **Must hold on every surface** (card, sheet, dock, session dock, notification):
  - the same question and the same command, with the same truncation rules;
  - the same gate, with the reason on the chip;
  - a guard against a tap that was meant for what was there before;
  - `sent` only when it really went, and an honest failure with Retry.
- **Watch for:**
  - a surface with a weaker guard or less evidence than the others;
  - a walk through waiting agents that skips one kind of agent;
  - a notification that lands somewhere other than where the question is.

### 2. Glance: is everything all right?

- **Moment.** A habit check, many times a day, a second or two.
- **Ideal shape.** Open → the board says, without scrolling or reading: how many
  need me, what is working and for how long, what finished, and which machines
  are unreachable → close. Zero taps.
- **Must hold:**
  - counts agree everywhere (badge, pill, sections, the Machines tab, notifications);
  - stale data looks stale;
  - a fresh launch paints the last state at once and doesn't announce the
    catch-up as news.
- **Watch for:** two counts of the same thing computed differently, and strips that flash
  during a normal connect.

### 3. Follow a working agent

- **Moment.** Something is running and they want to know whether it's on track, or
  to watch a part they care about.
- **Ideal shape.** One tap → it opens instantly, where it was → what it is
  doing now and for how long → what changed since they last looked → jump to the
  latest when they want it → swipe to the next agent, or back.
- **Switching.** One agent per screen; the board is the only list of agents.
  A quick sideways swipe inside the screen goes to the next (or previous) agent
  in the board's order, needs-you first, replacing the screen, so Back always
  lands on the board. An agent with both views has `Show terminal` in the
  chat's options and `Show chat` in the terminal's options; it swaps the view
  in place, and the view chosen and an unsent draft stay with the agent for
  the app run. Launch reopens the agent screen that was in front.
- **Must hold:**
  - nothing moves under a finger;
  - a stream never stutters the UI;
  - "quiet for 2m" style honesty when stuck;
  - the terminal pane and the agent session offer the same jump and since-you-left
    behaviour;
  - the swipe never takes a gesture from content that scrolls sideways or from
    the system's edge back gesture; at either end nothing moves, and it says so.

### 4. Steer it

- **Moment.** Correct, add an instruction, answer a free-text question, stop it.
- **Ideal shape.** Type or pick (a phrase, a slash command, a key) → send →
  felt when it went → the text is kept if it didn't. Stop is always within reach and
  never where Send was a moment ago.
- **Must hold:**
  - both composers (terminal and session) share the same send feedback, failure path,
    guard on Stop, and palette behaviour;
  - keys are not a send (the key row never disables input);
  - attachments upload visibly and never block typing.

### 5. Start new work

- **Moment.** An idea strikes away from the desk: run an agent on machine X in folder Y.
- **Ideal shape.** `+` → machine (defaulted), folder (remembered), agent,
  optional first message → Start (stay, with a toast to open it) or Start and
  open → it runs.
- **Must hold:** one start form, and the same `+` everywhere: on the Agents tab
  and a machine's screen it starts an agent session (the machine's own screen
  has that machine chosen); on the Machines tab it adds a machine. Same icon,
  same corner, no menu in between. Nothing is saved until Start. A pane's
  Duplicate and a session's Duplicate open the same form, prefilled.

### 6. Review finished work

- **Moment.** Agents finished while they were away. They want the outcome and to clear the list.
- **Ideal shape.** The done section → the answer and what changed, at a glance →
  open a changed file in one tap → mark it reviewed (swipe, tap, or all at once) →
  one Undo covers what they just did.
- **Must hold:** review is per device and never touches herdr's own state. Every way
  of reviewing can be undone the same way.

### 7. Set up a machine

- **Moment.** Rare, deliberate, often at a desk with a computer next to the
  phone.
- **Ideal shape.** Add → the fewest fields → a key generated on the phone and the one
  command for the host, copied → test, and see the host key before trusting
  it → a success that is felt once.
- **Must hold:** secrets go only to the keychain; a host key is pinned, and a changed
  key is a hard stop that offers a real way forward.

### 8. Something is wrong

- **Moment.** A machine is unreachable, the network changed, a key was refused.
- **Ideal shape.** The state named in plain words, where they look → what to do,
  as a button → automatic recovery whenever possible → the person never has to
  understand SSH to recover.
- **Must hold:**
  - every error state has a next step that can actually succeed;
  - the same machine trouble reads the same on the board, the Machines tab and
    the machine screen.

### 9. Away from the phone

- **Moment.** The phone is in a pocket for an hour while agents work.
- **Ideal shape.** Silence while all is well → one notification when something
  starts waiting (or finishes, if asked) → answer from it when it is safe →
  everything clears when they come back.
- **Must hold:**
  - off by default;
  - only transitions are announced, and what was already waiting is never announced again;
  - bursts collapse into a summary;
  - the background profile is respected;
  - the person can see that watching is on.

### 10. Act on many at once

- **Moment.** Several agents need the same thing: interrupt them, message them, close them.
- **Ideal shape.** Long-press to select → choose the action → a confirm sheet built
  from live data that names the targets and the skips → one result toast.
- **Must hold:** a blocked agent is never typed into unless the person
  explicitly allows it. Results name what failed and why.

### 11. Make it mine

- **Moment.** Set it up once, rarely revisited.
- **Ideal shape.** A few settings that matter (theme, density, terminal font and
  wrap, quick phrases, notifications), applied at once.
- **Must hold:** a setting that also appears in place (wrap, density) is the same
  setting in both places.

## Seams that recur

These are the ways a whole app drifts as features are added one by one. Look
for them in every review:

- **Twins:** two components doing one job (two composers, two palettes, two
  jump buttons, two forms) that slowly diverge in guards, haptics and words.
- **Uneven coverage:** a guard, a haptic, an Undo or a reason that one surface
  has and its twin lacks.
- **Counts that disagree** between the badge, the pill, the sections and the
  notifications.
- **Dead ends:** an error whose only action can't succeed, or a link that lands
  on the wrong tab.
- **A second system creeping back:** a `SnackBar`, a dialog, or a second viewer.
- **Doc drift:** `docs/DESIGN.md` stating a rule or token the code no longer
  follows. Fix whichever one is wrong in the same change.
