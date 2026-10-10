# Proving a finding

A claim you did not try to break is a guess. This is how to try, without touching the tree
the owner is working in.

## Why a clean copy

The main tree often holds unfinished work and may not compile. A verifier therefore never runs
tests there, never stashes, checks out, resets or formats it, and kills only processes it
started, by PID (`AGENTS.md`: a `pkill -f` once killed a 77-minute training run). A copy made
with `git archive` has no `.git`, so there is nothing to peek at and nothing to damage.

## Commands

```bash
W=/tmp/hm-review-<id>; rm -rf "$W"; mkdir -p "$W"
git archive <rev> app tool | tar -x -C "$W"   # <rev>: HEAD, a commit, a branch. No .git: nothing to peek at.
# To check a working-tree change, copy the changed files over the archive:
cp <repo>/app/lib/<changed>.dart "$W/app/lib/<changed>.dart"
cd "$W/app" && export PATH="$(<repo>/tool/flutter-bin.sh):$PATH"   # flutter on PATH may be too old for this repo
flutter pub get && flutter test test/<file>.dart --plain-name "<test name>"
```

Write the throwaway test in `$W/app/test/`, never in the repo. A pure function or a parser
needs no harness: a ten-line test that feeds it the trigger is enough.

## Where the fakes are (`app/test/support/`)

| Fake | Use |
| --- | --- |
| `CreateHarness.create([(profile:, snapshot:)])` | machines on a scripted `HerdrStub` |
| `h.stubs[id].snapshot` | a mutable map; change it, then `await machine.refresh()` |
| `FakeLogSource`, `ObservedRig` | observed (log-following) sessions |
| `FakeFs` | files on a host |
| `fake_transport.dart`: `snapshotJson(...)`, `FakeTransport` | a herdr that answers what you script |
| `FakeAgentSession` | a chat screen's session |
| `app/test/ui/worst_case_test.dart` | the model for UI breaks |

## What counts as `ran`

A test that fails on the old code with the symptom the finding names, and passes when the one
line is changed. Keep the failing output in the report. A test that fails for another reason
(a missing import, a bad fixture) proves nothing: fix the test, not the finding.

## What cannot be reproduced on a desktop

SSH to a real host, keyboard insets, frame stalls, battery, device storage, MediaStore. The status
is then `read` or `lead`, never `ran`. Write "needs the phone" next to it.

## After

Delete the copy (`rm -rf "$W"`) unless the owner asked for the test. Name the test file's path in
the report so it can be copied into `app/test/` if a fix is wanted.
