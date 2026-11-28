// Renders the `Made in this session` sheet to PNGs for review, one per tab
// (Apps, Pages, Media, Docs, Links) with the tab switch showing. Apps: one server
// with four pages and a launch command, a long launch command, a running app, a
// database port, and an app with no known launch. Media: real thumbnails of
// pictures from a fake machine, a video and a picture a tool returned. Links: a
// pull request, a release and four said links (a tailnet dashboard, a long label, a Vietnamese label, a very long address). Light and dark at 412x892, and 320x640 at text
// scale 1.6. Off by default; it writes files:
//
//   MADE_SHOTS=1 flutter test test/ui/session_made_shots_test.dart
//
// Output: $MADE_SHOTS_DIR (default /tmp/made_shots)/<tab>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:image/image.dart' as img;

import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/fake_webview.dart' show emptyFleet, withFleet;
import '../support/shot.dart' show loadAppFonts, shoot;

TranscriptItem _say(String text) =>
    TranscriptMessage(key: 'm$text', role: MessageRole.agent, blocks: [TextBlock(text)]);

TranscriptItem _launch(String command) => TranscriptTool(
  ToolCall(
    toolCallId: 't$command',
    kind: ToolKind.execute,
    status: ToolStatus.completed,
    rawInput: {'command': command},
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

TranscriptItem _printed(String command, String output) => TranscriptTool(
  ToolCall(
    toolCallId: 't$command',
    kind: ToolKind.execute,
    status: ToolStatus.completed,
    rawInput: {'command': command},
    output: ToolOutput(text: output, exited: true, exitCode: 0),
  ),
);
Uint8List _png(int hue) {
  final image = img.Image(width: 96, height: 72);
  for (final p in image) {
    p.setRgb((60 + p.x * 2 + hue) % 256, (200 - p.y * 2 + hue) % 256, (90 + hue * 3) % 256);
  }
  return Uint8List.fromList(img.encodePng(image));
}

const _base = '/home/dev/payments-api';

void main() {
  if (Platform.environment['MADE_SHOTS'] == null) {
    test('made shots are off (set MADE_SHOTS=1)', () {}, skip: 'set MADE_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['MADE_SHOTS_DIR'] ?? '/tmp/made_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final cases = [
    (Brightness.light, const Size(412, 892), 1.0),
    (Brightness.dark, const Size(412, 892), 1.0),
    (Brightness.light, const Size(320, 640), 1.6),
  ];
  // (tab, picture name, what the machine's helper says): the Apps tab as a
  // machine with no helper (unknown), where every server listens, and where
  // none does; the Pages tab with a file the machine says is gone.
  const variants = [
    ('Apps', 'apps-unknown', _Host.none),
    ('Apps', 'apps-running', _Host.running),
    ('Apps', 'apps-stopped', _Host.stopped),
    ('Pages', 'pages-gone', _Host.gone),
    ('Media', 'media', _Host.none),
    ('Docs', 'docs', _Host.none),
    ('Links', 'links', _Host.none),
  ];
  for (final (brightness, size, scale) in cases) {
    for (final (tab, name, host) in variants) {
      final tag = '${brightness.name}-${size.width.round()}x${size.height.round()}${scale == 1.0 ? '' : '-x$scale'}';
      testWidgets('$name: $tag', (tester) async {
        final fleet = emptyFleet();
        addTearDown(fleet.dispose);
        final fs = FakeFs();
        for (var i = 0; i < 8; i++) {
          fs.addFile('$_base/screenshots/shot_${i + 1}.png', _png(i * 23));
        }
        for (final n in ['index.html', 'review.html', 'failures.html']) {
          fs.addFile('$_base/reports/$n', '<h1>x</h1>');
        }
        for (final n in ['plan.md', 'findings.pdf']) {
          fs.addFile('$_base/notes/$n', 'x');
        }
        final transport = FakeTransport()..fs = fs;
        if (host != _Host.none) {
          final up = host == _Host.running ? const {8765, 8790, 8792, 3000} : const <int>{};
          transport.onHostCall = (service, method, args) async => {
            'results': [
              for (final item in (args['items']! as List).cast<Map<String, Object?>>())
                if (item['path'] case final String path)
                  {'id': item['id'], 'exists': !(host == _Host.gone && path.endsWith('failures.html'))}
                else
                  {'id': item['id'], 'listening': up.contains(item['port'])},
            ],
          };
          // A watch that stays open, as the host's does while nothing changes.
          transport.onHostMessages = (service, method, args) =>
              (StreamController<Object?>()..add({
                    'listeners': [
                      for (final p in up) {'family': 4, 'addr': '127.0.0.1', 'port': p},
                    ],
                  }))
                  .stream;
        }
        final machine = MachineConnection(
          profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
          api: HerdrApi(transport),
          backoff: (_) => const Duration(hours: 1),
          pollInterval: const Duration(hours: 1),
        );
        final session = FakeAgentSession(
          state: AgentSessionState(
            's',
            items: [
              _launch('cd /w && nohup python label_server.py --port 8765 > log 2>&1 &'),
              _say('http://localhost:8765/failures'),
              _say('http://localhost:8765/review'),
              _say('http://localhost:8765/synth'),
              _say('http://localhost:8765/'),
              _say('http://localhost:8765/label'),
              _launch(
                'cd /w && uv run --with torch python -m training.reconstruct_finetune_evaluate --port 8790 --config configs/arcface/finetune_reconstruct_with_a_very_long_name.yaml',
              ),
              _say('Evaluation dashboard http://localhost:8790/'),
              _say('Tiến độ huấn luyện http://localhost:8792/'),
              _say('The database is on http://localhost:5432/'),
              _say('http://localhost:3000/ and http://localhost:3000/settings/profile?tab=security'),
              _wrote('$_base/reports/index.html'),
              _wrote('$_base/reports/review.html'),
              _wrote('$_base/reports/failures.html'),
              _wrote('$_base/notes/plan.md'),
              _wrote('$_base/notes/findings.pdf'),
              for (var i = 1; i <= 8; i++) _say('I saved screenshots/shot_$i.png'),
              _say('I saved renders/walkthrough.mp4'),
              TranscriptTool(
                ToolCall(
                  toolCallId: 'browser',
                  title: 'Screenshot',
                  kind: ToolKind.other,
                  status: ToolStatus.completed,
                  content: [ToolContentBlock(ImageBlock(data: base64Encode(_png(5)), mimeType: 'image/png'))],
                ),
              ),
              _printed(
                'gh pr create --title "feat(observed): send while the agent works"',
                'https://github.com/tuan3w/herdr-mobile/pull/93\n',
              ),
              _printed('gh release create v0.1.51', 'https://github.com/tuan3w/herdr-mobile/releases/tag/v0.1.51\n'),
              _say('Dashboard: http://100.87.64.16:8792 (LAN: http://192.168.0.108:8792/runs?tab=overview)'),
              _say(
                'Curves are in [the sweep: Swift 1.5 27B, rows27 sampling, 5 seeds](https://wandb.ai/suneye/qwen-warp/runs/ab12cd)',
              ),
              _say(
                'Tiến độ: [bảng điều khiển huấn luyện](https://kaggle.com/competitions/gemma-4-developer-agent/submissions)',
              ),
              _say(
                'Paper https://arxiv.org/abs/2401.00001 and https://huggingface.co/Qwen/Qwen3-27B-Instruct-AWQ-INT4-quantized-with-a-very-long-name/blob/main/config.json?download=true&revision=refs%2Fpr%2F12',
              ),
            ],
          ),
          machine: machine,
          key: 'm/shots-$name',
        );
        session.setBackground(
          BackgroundWork(
            tasks: const [
              BackgroundTask(
                id: 'bg1',
                kind: BackgroundKind.shell,
                status: BackgroundStatus.running,
                title: 'vite --port 3000',
              ),
            ],
          ),
        );
        await shoot(
          tester,
          Scaffold(body: SessionBar(session: session)),
          '$out/$name-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => withFleet(fleet, app),
          pump: (t) async {
            await t.tap(find.text('Made'));
            await t.pump(const Duration(milliseconds: 600));
            // Thumbnails are read and decoded on the engine's real clock.
            await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
            await t.pump(const Duration(milliseconds: 300));
            await t.ensureVisible(find.text(tab));
            await t.pump(const Duration(milliseconds: 100));
            await t.tap(find.text(tab));
            await t.pump(const Duration(milliseconds: 600));
            // Thumbnails are read three at a time and decoded on the engine's real clock.
            for (var i = 0; i < 40 && tab == 'Media'; i++) {
              await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
              await t.pump(const Duration(milliseconds: 100));
            }
          },
        );
      });
    }
  }
}

enum _Host { none, running, stopped, gone }
