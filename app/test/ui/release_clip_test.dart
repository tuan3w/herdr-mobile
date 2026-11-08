// Records the walkthrough clip of the release being prepared: the real app on
// the invented demo fleet, going through the release's change list, as frames
// plus touches.json for make_clip.sh (skill herdr-changelog). Rewrite the
// script below each release; git keeps the old ones. Off by default; it
// writes files:
//
//   RELEASE_CLIP=1 flutter test test/ui/release_clip_test.dart
//
// Output: $RELEASE_CLIP_DIR (default /tmp/release_clip)/frames/*.png, touches.json,
// and still.png (the release's still).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/clip_recorder.dart';
import '../support/fake_agent_session.dart';
import '../support/shot.dart';

/// A believable file, before and after the agent's edit: a retry loop gets a
/// clock and jitter, every line of it changed.
(String, String) _file() {
  final before = <String>[];
  final after = <String>[];
  for (var i = 0; i < 40; i++) {
    before
      ..add('func (r *Retrier) step$i(ctx context.Context) error {')
      ..add('  return r.do(ctx, $i)')
      ..add('}');
    after
      ..add('func (r *Retrier) step$i(ctx context.Context) error {')
      ..add('  return r.doAt(ctx, r.clock.Now(), $i)')
      ..add('}');
  }
  return (before.join('\n'), after.join('\n'));
}

FakeAgentSession _session() {
  final (before, after) = _file();
  return FakeAgentSession(
    state: stateWith(
      turnActive: true,
      pending: [
        PendingPermission(
          7,
          permissionRequest(
            title: 'Edit services/checkout/retry.go',
            kind: ToolKind.edit,
            rawInput: {'file_path': 'services/checkout/retry.go'},
            content: [
              {'type': 'diff', 'path': 'services/checkout/retry.go', 'oldText': before, 'newText': after},
            ],
          ),
        ),
      ],
    ),
  );
}

Rect _sheet(WidgetTester t) => t.getRect(find.byType(SheetSurface));

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.56: every sheet follows the finger; a long one opens at half and is
  // dragged up to show it all; a flick closes it.
  testWidgets('0.1.56 walkthrough', (tester) async {
    final rec = ClipRecorder(dir);
    await shoot(
      tester,
      AgentSessionScreen(session: _session()),
      '$dir/last.png',
      wrap: rec.wrap,
      pump: (t) async {
        await t.pump(Dwell.tapGuard);
        await rec.hold(t, const Duration(milliseconds: 1000));

        // 1. A long sheet opens at half the screen.
        rec.chapter(1, 3, 'A long sheet opens at half', top: true);
        await rec.tap(t, find.text('Read all'), 'Tap Read all');
        await rec.hold(t, const Duration(milliseconds: 1400));

        // 2. Drag it up to see all of it, then the list scrolls.
        rec.chapter(2, 3, 'Drag up to see all of it', top: true);
        final half = _sheet(t);
        await rec.drag(
          t,
          Offset(half.center.dx, half.top + 40),
          Offset(0, -(half.top - 60)),
          'Drag up',
          over: const Duration(milliseconds: 900),
        );
        await rec.hold(t, const Duration(milliseconds: 1000));
        final full = _sheet(t);
        await rec.drag(
          t,
          Offset(full.center.dx, full.top + 500),
          const Offset(0, -260),
          'Scroll',
          over: const Duration(milliseconds: 700),
        );
        await rec.hold(t, const Duration(milliseconds: 1000));

        // 3. A flick down closes it, however short.
        rec.chapter(3, 3, 'A flick down closes it', top: true);
        final now = _sheet(t);
        await rec.drag(
          t,
          Offset(now.center.dx, now.top + 30),
          const Offset(0, 300),
          'Pull down',
          over: const Duration(milliseconds: 700),
        );
        await rec.hold(t, const Duration(milliseconds: 800));
        final rest = _sheet(t);
        await rec.drag(
          t,
          Offset(rest.center.dx, rest.top + 30),
          const Offset(0, 90),
          'Flick',
          over: const Duration(milliseconds: 100),
          rest: Duration.zero,
        );
        await rec.hold(t, const Duration(milliseconds: 1400));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  // The still: the edit's sheet resting at half, on the reference phone.
  testWidgets('0.1.56 still', (tester) async {
    await shoot(
      tester,
      AgentSessionScreen(session: _session()),
      '$dir/still.png',
      pump: (t) async {
        await t.pump(Dwell.tapGuard);
        await t.tap(find.text('Read all'));
        await t.pumpAndSettle();
      },
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
