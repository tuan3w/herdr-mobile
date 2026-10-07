# predict-eval

Replay harness for ideas that make typing to an agent faster on a phone. Not part of the app:
it decides what the app should build, with the person's own writing as evidence.

## The moment it is built around

Someone away from their desk, one hand, seconds of attention, an agent waiting. They send a
short message: median 40 characters in the author's own history, half of all messages 40 or
fewer. So the question is not "how many keystrokes do long prompts save" but "how often can
this person answer with one tap, and how little noise does the strip add while they type".
Hence the columns:

| column | what it answers |
|---|---|
| keys saved % | key presses not needed, taps and wrong-space backspaces paid for |
| answered by taps % | messages finished with no typing at all: the supervisor's best case |
| noisy words / 100 | words where a chip was on screen and the person did not use it. Attention is the product: a chip that is not used is a cost |
| flips / 100 | the first chip changed while one word was typed. A chip that moves under the thumb is a mis-tap (AGENTS.md: "nothing moves under the thumb") |
| chips on screen % | how much of the time the strip is lit |

Latency is this computer's; it says nothing about a phone (unverified there).

## Run

```bash
python3 extract_corpus.py            # corpus/messages.jsonl + the two word lists; prints counts only
export PATH="$HOME/.cache/flutter-3.47.6/bin:$PATH"   # any Dart >= 3.13
dart pub get && dart test
dart run bin/eval.dart                                     # English / Telex, all ideas, τ 0.1 0.25 0.4
dart run bin/eval.dart --style bare --only none,generic-words,ngram,ngram-fold
dart run bin/eval.dart --notice 0.5 --tap-cost 2 --slots 2  # a more pessimistic person
```

`corpus/` is gitignored: it is the owner's private writing. Add messages to
`corpus/messages.jsonl` (`{"t": epoch, "text": "..."}`, NFC, oldest first) to test a language the
history does not cover; Vietnamese is a slice of its own in the report.

## The simulated person

- Types the finished message one character at a time (the text to be typed is the truth).
- At each position the idea offers up to `--slots` chips. If one is **exactly** right and saves
  more keys than its tap costs, they tap it, with probability `--notice` per word. They never tap a
  wrong chip, so wrong chips cost attention (noisy, flips), not keys. That is an upper bound.
- Learns online: each message is predicted using only the messages before it, then learned.
- `--style telex`: Vietnamese costs Telex keys (`việt` = `vieejt` = 6 keys). English is 1 per char.
  `--style bare`: the person skips marks (`khong`), 1 key per char; a chip answers with the marked word.
  `--style chars`: 1 key per character.
- A word chip adds a space after itself; if the text wanted a comma there, a backspace is charged.

## Ideas in the table

| idea | what it is |
|---|---|
| none | the phone keyboard alone |
| chips-default | today's app: the 4 hand-written quick phrases above an empty composer |
| phrase | whole-message completion from messages already sent (≥ 2 times, ≤ 80 chars): `ru` → `run the tests` |
| generic-words | word completion from a static English+Vietnamese frequency list: **a keyboard that knows nothing about you**. The honest baseline: the system keyboard already does this |
| ngram | personal word trigram over what was sent, smoothed down to that list (omp's model) |
| ngram-nextword | the same, also predicting the word after a space |
| ngram-fold | the same, matching words without marks (`kho` → `không`) |
| blend, blend-nextword | phrase + ngram chips in one strip, likeliest first |

Add an idea: implement `Predictor` (`lib/predictor.dart`), register it in `bin/eval.dart`. A
language model (omp's SmolLM2-135M) would be one more `Predictor` fed from a subprocess.

## What the app took from it

On the author's year of messages (9,246, English, desktop) word completion saved 22% of key
presses at a 1-key tap and 6-9% at a pessimistic 1.5-2 keys with half the chips noticed, against
13% and 3-5% for a keyboard that knows nothing about the person: a few points over what the
system keyboard already does, and noisy. So the app took the `phrase` idea instead
(`SentPhrases`, learned chips beside the quick phrases: 5% of messages in one tap, twice the
hand-written defaults) and a mic button (`docs/ENGINEERING.md` "Dictation"). Word completion is
not built; the tap cost on a real phone decides it.

## What this does not measure

- **A phone.** Real keyboard, real thumb, the system keyboard's own strip and autocorrect, the
  cost of looking up at the strip. `--tap-cost` is an assumption; sweep it.
- **Voice.** Needs audio and a word error rate, not text. See the notes in the conversation that
  produced this harness; it is a separate evaluation.
- **Desktop vs phone text.** The corpus is what was typed on a desktop to coding agents. Phone
  messages are probably shorter and more often replies.
- **Shift.** Capital letters cost nothing here.
- **Unaccented Vietnamese detection.** A message is `vi` only with two or more marked words.

## Privacy rules any real version must keep

Learning from sent text puts secrets in a model. The rules the harness already follows are
requirements for the app: learn on the phone only; never learn code, paths or words touching
`/ \ @ _ = : …`; a word outside the dictionary needs 2 sightings; a message needs 2 sends before it
can be offered; nothing learned leaves the device or enters a backup unencrypted.

Dart has no `String.normalize`: the app must receive NFC text (Android keyboards send it) or
carry its own normalizer before using any of this.
