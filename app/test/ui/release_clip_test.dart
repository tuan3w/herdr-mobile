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
import 'package:herdr_mobile/ui/shell/home_shell.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/shot.dart';

/// What the demo machines' hooks report, the way `herdr pane report-metadata`
/// and `herdr workspace report-metadata` set it. No emoji: the test fonts
/// cannot draw them.
void _report(DemoFleet h) {
  void pane(String id, Map<String, Object> fields) {
    final t = h.transports[id.substring(0, 1)]!;
    for (final p in t.snapshot['panes'] as List) {
      if ((p as Map<String, dynamic>)['pane_id'] == id) p.addAll(fields);
    }
  }

  void workspace(String machine, String id, Map<String, String> tokens) {
    for (final w in h.transports[machine]!.snapshot['workspaces'] as List) {
      if ((w as Map<String, dynamic>)['workspace_id'] == id) w['tokens'] = tokens;
    }
  }

  pane('c1:p1', {
    'state_labels': {'working': 'Epoch 12 of 40'},
    'tokens': {'loss': 'loss 0.418'},
  });
  pane('b1:p1', {
    'state_labels': {'working': 'Removing 14 of 31 flags'},
  });
  workspace('a', 'a2', {'stage': 'CI 142 of 165 passing'});
  for (final t in h.transports.values) {
    t.emit({'event': 'workspace_metadata_updated'});
  }
}

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.58: what the hooks on your computers report shows on the board, and
  // follows them while the app is open.
  testWidgets('0.1.58 walkthrough', (tester) async {
    final h = await DemoFleet.create(timed: true);
    final rec = ClipRecorder(dir);
    await shoot(
      tester,
      const HomeShell(),
      '$dir/last.png',
      wrap: (app) => demoProviders(h)(rec.wrap(app)),
      pump: (t) async {
        await h.ageStatuses(t);
        await t.pump(const Duration(seconds: 1));
        await rec.hold(t, const Duration(milliseconds: 1000));

        // 1. The hooks report; the board follows. Scrolled to Working first:
        // the labels show there, and the poster must not show a card that
        // needs you.
        rec.chapter(1, 1, 'Your hooks\u2019 labels, on the board');
        await rec.drag(
          t,
          const Offset(206, 700),
          const Offset(0, -460),
          'Scroll to Working',
          over: const Duration(milliseconds: 700),
        );
        await rec.hold(t, const Duration(milliseconds: 600));
        _report(h);
        await rec.hold(t, const Duration(milliseconds: 3200));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    h.dispose();
  });

  // The still: the board with the hooks' labels, on the reference phone.
  testWidgets('0.1.58 still', (tester) async {
    final h = await DemoFleet.create(timed: true);
    await shoot(
      tester,
      const HomeShell(),
      '$dir/still.png',
      wrap: demoProviders(h),
      pump: (t) async {
        await h.ageStatuses(t);
        _report(h);
        for (var i = 0; i < 30; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      },
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    h.dispose();
  });
}
