Here is what I found while chasing the crash on reconnect.

**Symptom:** the app throws `Bad state: No element` when the SSH channel closes during `pane.read`.

Stack (trimmed):

```
Unhandled Exception: Bad state: No element
#0      List.first (dart:core-patch/growable_array.dart:343:5)
#1      MuxClient._onFrame (package:herdr_mobile/data/services/mux_client.dart:212:31)
#2      _RootZone.runUnaryGuarded (dart:async/zone.dart:1594:10)

#3      _BroadcastStreamController.add (dart:async/broadcast_stream_controller.dart:253:5)
```

Line 212 reads `pending.first` without checking that a request is still waiting. The channel can deliver a late frame after `close()` completed all waiters.

Root cause, in one sentence:  
a late `E<n>` frame arrives after the queue was cleared.

Fix (4 lines):

```diff
-    final req = pending.first;
+    if (pending.isEmpty) return;
+    final req = pending.first;
```

Other things I noticed, not fixed:

- The log line `connection reset by peer` is printed twice (once per isolate).
- `lib/ui/core/terminal_links.dart:77` builds a `RegExp` on every call, a long pattern: `https?://[^\s<>"'`)\]]+(?:\([^\s<>"'`)]*\)[^\s<>"'`)\]]*)*` that could be a `static final`.
- A very long unbroken token: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.

Logs for the failing run: see ![screenshot of the failure](https://example.com/shots/crash.png) and the report at <https://example.com/reports/2026-10-05>.

Arabic note for the translator: النص العربي **غامق** هنا و `code` ثم نص آخر.

Tabs and odd whitespace:	a tab, two  spaces, and a trailing hard break  
next line after the break.

Done. Run `flutter test test/mux_client_test.dart` to confirm; it should print `+42: All tests passed!`.
