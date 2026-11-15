// Records the walkthrough clip of the release being prepared: the real widgets
// going through the release's change list, as frames plus touches.json for
// make_clip.sh (skill herdr-changelog). Rewrite the script below each release;
// git keeps the old ones. Off by default; it writes files:
//
//   RELEASE_CLIP=1 flutter test test/ui/release_clip_test.dart
//
// Output: $RELEASE_CLIP_DIR (default /tmp/release_clip)/frames/*.png, touches.json,
// and still.png (the release's still).
//
// 0.1.67: the chat of an agent that made a video, screenshots, pictures, a page
// and a pull request, and the `Made` sheet that lists them. The agent, the
// machine and every name are invented (no demo-fleet machine has a session
// that made anything).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:image/image.dart' as img;

import '../support/clip_recorder.dart';
import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/fake_webview.dart' show emptyFleet, withFleet;
import '../support/shot.dart';

const _base = '/home/dev/web-shop';

Uint8List _png(int hue) {
  final image = img.Image(width: 96, height: 72);
  for (final p in image) {
    p.setRgb((60 + p.x * 2 + hue * 5) % 256, (200 - p.y * 2 + hue * 5) % 256, (90 + hue * 3) % 256);
  }
  return Uint8List.fromList(img.encodePng(image));
}

TranscriptItem _run(String command, {String? output}) => TranscriptTool(
  ToolCall(
    toolCallId: 't$command',
    kind: ToolKind.execute,
    status: ToolStatus.completed,
    rawInput: {'command': command},
    output: output == null ? null : ToolOutput(text: output, exited: true, exitCode: 0),
  ),
);

TranscriptItem _wrote(String path) => TranscriptTool(
  ToolCall(
    toolCallId: 't$path',
    kind: ToolKind.edit,
    status: ToolStatus.completed,
    content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
  ),
);

FakeAgentSession _session() {
  final fs = FakeFs();
  for (var i = 0; i < 5; i++) {
    fs.addFile('$_base/screenshots/checkout_${i + 1}.png', _png(i * 9));
  }
  fs.addFile('$_base/reports/coverage.html', '<h1>x</h1>');
  fs.addFile('$_base/renders/checkout-demo.mp4', 'x');
  fs.addFile('$_base/notes/checkout-plan.md', 'x');
  final machine = MachineConnection(
    profile: const MachineProfile(id: 'm', label: 'build-box', host: 'h', username: 'u'),
    api: HerdrApi(FakeTransport()..fs = fs),
    backoff: (_) => const Duration(hours: 1),
    pollInterval: const Duration(hours: 1),
  );
  return FakeAgentSession(
    state: stateWith(
      items: [
        userMsg('u1', 'Record a demo of the new checkout and open a pull request.'),
        _run(
          'cd web-shop && npm run dev',
          output: '  VITE v5.2.0  ready in 312 ms\n\n  ➜  Local:   http://localhost:5173/\n',
        ),
        _wrote('$_base/notes/checkout-plan.md'),
        _wrote('$_base/reports/coverage.html'),
        for (var i = 1; i <= 5; i++) agentMsg('s$i', 'I saved screenshots/checkout_$i.png'),
        agentMsg('v', 'I saved renders/checkout-demo.mp4'),
        TranscriptTool(
          ToolCall(
            toolCallId: 'browser',
            title: 'Screenshot',
            kind: ToolKind.other,
            status: ToolStatus.completed,
            content: [ToolContentBlock(ImageBlock(data: base64Encode(_png(31)), mimeType: 'image/png'))],
          ),
        ),
        _run(
          'gh pr create --title "feat(checkout): one-tap pay"',
          output: 'https://github.com/acme/web-shop/pull/412\n',
        ),
        agentMsg('done', 'The demo is rendered and the pull request is open.'),
      ],
    ),
    machine: machine,
    cwd: _base,
    title: 'web-shop',
    key: 'm/clip',
  );
}

Future<void> _decode(WidgetTester t) async {
  // Thumbnails are read and decoded on the engine's real clock.
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
  await t.pump(const Duration(milliseconds: 100));
}

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(() async {
    await loadAppFonts();
    Directory(dir).createSync(recursive: true);
  });

  // 0.1.67: Made lists the video, the screenshots and the pull request.
  testWidgets('0.1.67 walkthrough', (tester) async {
    final fleet = emptyFleet();
    addTearDown(fleet.dispose);
    final session = _session();
    final rec = ClipRecorder(dir);
    await shoot(
      tester,
      AgentSessionScreen(key: ObjectKey(session), session: session),
      '$dir/last.png',
      wrap: (app) => withFleet(fleet, rec.wrap(app)),
      pump: (t) async {
        await rec.hold(t, const Duration(milliseconds: 1000));

        rec.chapter(1, 1, 'Everything the agent made, in one sheet', top: true);
        await rec.tap(t, find.text('Made'), 'Open Made');
        await rec.hold(t, const Duration(milliseconds: 1200));
        await rec.tap(t, find.text('Media'), 'Media: pictures, a video, a screenshot');
        await _decode(t);
        await rec.hold(t, const Duration(milliseconds: 1500));
        await rec.tap(t, find.text('Links'), 'Links: the pull request');
        await rec.hold(t, const Duration(milliseconds: 1800));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  // The still: the Media tab, on the reference phone.
  testWidgets('0.1.67 still', (tester) async {
    final fleet = emptyFleet();
    addTearDown(fleet.dispose);
    final session = _session();
    await shoot(
      tester,
      AgentSessionScreen(key: ObjectKey(session), session: session),
      '$dir/still.png',
      wrap: (app) => withFleet(fleet, app),
      pump: (t) async {
        await t.tap(find.text('Made'));
        // A route's animation starts at the first frame: pump frames, not one long step.
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 60));
        }
        // The switch answers a press that lasts a frame or two, not a same-frame tap.
        final press = await t.startGesture(t.getCenter(find.text('Media')));
        await t.pump(const Duration(milliseconds: 120));
        await press.up();
        for (var i = 0; i < 14; i++) {
          await t.pump(const Duration(milliseconds: 60));
        }
        await _decode(t);
        await t.pump(const Duration(milliseconds: 500));
      },
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
