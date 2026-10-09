// Renders the "Read this agent as a chat" confirmation to PNGs for review
// (light and dark, text scale 1 and 1.6, a machine with a long name). Off by
// default; it writes files:
//
//   CONNECT_SHOTS=1 flutter test test/ui/connect_chat_shots_test.dart
//
// Output: $CONNECT_SHOTS_DIR (default /tmp/connect_shots)/<claude|codex>-<light|dark>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/pane/connect_chat.dart';

import '../support/create_harness.dart';
import '../support/fake_transport.dart';
import '../support/shot.dart';

void main() {
  if (Platform.environment['CONNECT_SHOTS'] == null) {
    test('connect shots are off (set CONNECT_SHOTS=1)', () {}, skip: 'set CONNECT_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['CONNECT_SHOTS_DIR'] ?? '/tmp/connect_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  for (final target in ['claude', 'codex']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('$target ${brightness.name} x$scale', (tester) async {
          final h = await CreateHarness.create([
            (
              profile: profileOf('a', 'Máy trạm văn phòng Hà Nội, tầng 12 — phòng thí nghiệm AI (workstation-long-name)'),
              snapshot: snapshotJson(
                workspaces: const [(id: 'w1', label: 'api')],
                panes: [(id: 'w1:p0', ws: 'w1', agent: target, status: 'idle')],
              ),
            ),
          ], waitOnline: false);
          final machine = h.connection('a');
          final name = '$target-${brightness.name}${scale == 1.0 ? '' : '-x$scale'}';
          await shoot(
            tester,
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showConnectChat(context, machine, 'w1:p0', target),
                  child: const Text('open'),
                ),
              ),
            ),
            '$out/$name.png',
            brightness: brightness,
            observers: [ToastRouteObserver()],
            wrap: (app) => MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: app,
            ),
            pump: (tester) async {
              await tester.tap(find.text('open'));
              for (var i = 0; i < 6; i++) {
                await Future<void>.value();
                await tester.pump(const Duration(milliseconds: 100));
              }
            },
          );
          await tester.pumpWidget(const SizedBox());
          h.dispose();
        });
      }
    }
  }
}
