# Foundations

The general principles behind herdr-design, distilled from Apple's design
talks (*Principles of Great Design*, *Designing Fluid Interfaces*, *The Details
of UI Typography*) and Emil Kowalski's design engineering, and translated for
a phone app that supervises agents. Use them to reason when the method in
SKILL.md doesn't settle a question.

## Apple's eight principles, applied here

1. **Purpose.** Decide what not to build. Every feature spends the person's
   time, attention and trust. Here the budget is a few seconds per glance, so a
   feature that does not answer one of the five questions doesn't belong on the
   main path.
2. **Agency.** Keep the person in control. Offer choices instead of forcing one path.
   Make slips cheap to undo, and confirm only what is truly destructive or irreversible:
   overusing confirmation trains people to tap through it, which is why cheap
   actions get Undo and risky ones get a hold, not a dialog.
3. **Responsibility.** Act in the person's interest, especially with AI. Agents
   run commands on real machines, so show what is approved, never approve silently,
   anticipate the mistaken tap, and cut a feature whose risk outweighs its value.
4. **Familiarity.** Build on what people already know: the back gesture, pull to
   refresh, long press to select, swipe to dismiss, browser-style tabs. Things
   that look the same behave the same and live in the same place. Break a
   familiar pattern only when you can show it is better, and then test it.
5. **Flexibility.** Design for contexts and abilities: one hand, landscape with
   the keyboard, text at 2x, TalkBack, dark and light, a 320 dp phone, a slow
   link. Make the phone the primary context, not a shrunken desktop.
6. **Simplicity, not minimalism.** Remove what is unnecessary so the purpose shows.
   Hiding everything behind one menu looks minimal but isn't simple. Sometimes
   adding context simplifies: `Quiet for 2m` saves a question. Common path
   first, advanced one level down.
7. **Craft.** Nothing is random. Every spacing, timing, colour and word is a
   choice you can defend, and it comes from a token or a stated reason. Jitter,
   misalignment and layouts that break on rotation read as carelessness, and
   carelessness costs trust, which this app cannot afford.
8. **Delight.** It is what you get when the other seven are right, not something added on
   top. Decide the feeling (here: calm, in control, informed) and serve it in
   every decision.

## Feedback

Feedback comes in four kinds: **status** (what is going on), **completion** (it
worked), **warning** (about to go wrong) and **error** (went wrong). Each one should be:

- **Immediate.** It starts on pointer-down, not on release. Latency is where the
  feeling of directness falls off a cliff.
- **Caused.** It is obviously tied to what triggered it, and fires on the real event
  (`sent` when the request was accepted, not on the tap).
- **In harmony.** Visual, haptic and sound fire in the same frame.
- **Useful.** Reserved for moments that matter. Over-feedback trains people to ignore
  all of it.
- **Inline.** Validate in place and keep the space reserved, so an error doesn't move
  the layout.

## Wayfinding

Every screen answers: Where am I? What is here? Where can I go? How do I get
out? Never trap the person: back always works, a sheet can always be dismissed,
and a failure always offers a next step.

## Grouping and mapping

Proximity implies a relationship. Put a control next to what it affects, and
arrange controls the way the things they change are arranged. If a control needs a label to
explain what it does, the mapping is weak. Direct, specific names beat safe
generic ones: `Mark all reviewed`, not `Done`.

## Typography

- Hierarchy comes from size, weight and spacing as a set, not size alone.
  Emphasise with weight, which adds presence without taking room.
- Large titles take negative tracking and tight leading; body text sits near
  zero tracking with comfortable leading. Information-dense rows may tighten.
- Respect the system text size: layouts grow with the text, nothing clips at
  1.6x, and chrome still fits at 2x.
- Numbers that change or are compared use tabular figures.
- Use a monospace face for anything the person must read exactly: commands,
  paths, terminal output.

## Truncation: decide per field

- **Wrap** what identifies a thing (titles; two lines is usually fine).
- **End-truncate** secondary text whose start carries the meaning.
- **Middle-truncate** where items differ at the end (paths, hosts, file names).
- **Clamp** previews so card heights stay predictable, with a way to see more.
- **Never truncate** numbers, durations, or a command being approved without
  `Read all`.

## Taste

Taste is trained, not innate. Study why great tools feel the way they do (Notion,
Linear, Things, Telegram's attach sheet, iOS Control Center), take apart
their interactions, and ask why each detail is there. Look again the next day
with fresh eyes. Unseen details compound: most people never notice any one of
them, and together they are why the app feels trustworthy.
