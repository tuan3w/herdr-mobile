# Bug classes in herdr-mobile

A prompt for where to look, not a list of findings. An item here is a finding only when you can
name the input that breaks *this* code. The "Seen here" column is real history: bugs that were
in this app, so you know the shape.

| Class | Ask of the code | Seen here |
| --- | --- | --- |
| Identity | Can an id or key be taken over by something else while a cache or registry still holds the old thing? Does a cache hit compare more than the key? | The gallery preview opened the wrong photo (an index used as identity). A host-key pin was lost when the worker that held it was replaced. |
| Stale or saved state | What does a held, cached or saved copy answer after the world changed? Is it ever drawn as live? | The standing-grant check missed "bypass permissions" on a label-only prompt. |
| The gap after an `await` | After each await: is the screen, session or pane still there, and is the answer still for this question? | A failed send after leaving the screen lost the message. A stale machine Test result was applied to edited fields (fixed with a generation token). A stale `/cancel` flag swallowed the next prompt's real error. |
| Lifecycle and cost | Who stops this timer, subscription, listener or retry? Does every add have a matching remove, on every path? Does back-off reset only after real progress? Does it stop when nobody looks? | The connect loop reset its back-off after one good snapshot. Cards kept reading previews while the board was hidden. |
| Data boundaries | Empty, one, many, huge; a character cut by a chunk boundary; an unterminated escape; rounding at a unit edge; unbounded text. | `formatTokens(999500)` rendered "1000k". `KeeperInfo.fromJson` threw on a malformed row. Terminal copy glued rows together. |
| Failure semantics | Is success reported when the last step failed? Is the failure swallowed, retried forever, or classified fatal or not? Does it fail open where it should fail closed? | One exception in a reconcile stopped all machine changes. Boot had no failure path. |
| Guards | Can anything be approved silently, by default or on a timeout? Does the person see the command? Is the guard in proportion? Does a deny-list have a bypass? | IME Send on an empty reply field sent a bare Enter. Observed approvals dropped the detector's hold reason when no open log call matched. |
| Notification and alerts | Can an alert be dropped, doubled or delayed by a cooldown, a flap or a handover? | The ntfy cooldown dropped a second blocked alert. |
| Typed work | Does text survive a failed send, the background, rotation and a re-issued question? Say what cannot be kept (chips). | Typed answers were lost when a question was refused and re-issued. |
| Shared state across clients and machines | One connection per machine, shared. Does a fault in one machine touch another? Two clients on one keeper? | A reconcile exception stopped every machine's changes. |
| UI-thread cost | Decode, crypto or parsing on the UI thread; a rebuild per frame; a list that builds every row. Mark "unmeasured on the phone" unless measured there. | The gallery model re-queried MediaStore on every open. |

## Three habits

- **Read the consumers.** For a new enum value, state or field, read every switch and filter
  that sees it. The value that lands in a default branch is the bug.
- **Look at the shape of the interleaving.** A race finding is two numbered steps, not an
  adjective: "1. send starts; 2. the screen pops; 3. the failure has nowhere to go".
- **Look for the twin.** The same job done a second way is where the fix was missed.
