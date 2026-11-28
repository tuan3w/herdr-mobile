// Renders the Ports sheet to PNGs for review: the worst case (60 listeners: an
// 80-character process name, a Vietnamese one, no owner, SSH and a database
// dimmed, a LAN-only address, an IPv6 `::` listener beside the IPv4 one, a port
// that closed while the sheet was open), a handful of rows, nothing listening,
// the machine without the agent helper, a machine that cannot list ports, a
// lost link, and the first look. Light and dark at 412x892, and 320x640 at text
// scale 1.6. Off by default; it writes files:
//
//   PORTS_SHOTS=1 flutter test test/ui/ports_shots_test.dart
//
// Output: $PORTS_SHOTS_DIR (default /tmp/ports_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/ports/ports_sheet.dart';

import '../support/fake_transport.dart';
import '../support/fake_webview.dart' show emptyFleet, withFleet;
import '../support/shot.dart' show loadAppFonts, shoot;

Map<String, Object?> _l(String addr, int port, {int family = 4, int? pid, String? process}) => {
  'family': family,
  'addr': addr,
  'port': port,
  'pid': ?pid,
  'process': ?process,
};

/// 60 listeners the way a busy dev machine has them.
List<Map<String, Object?>> _worst() => [
  _l('0.0.0.0', 22, pid: 811, process: 'sshd'),
  _l('::', 22, family: 6),
  _l('127.0.0.1', 3000, pid: 4242, process: 'node'),
  _l('::1', 3000, family: 6, pid: 4242, process: 'node'),
  _l(
    '127.0.0.1',
    5173,
    pid: 9120,
    process: 'python3 -m training.reconstruct_finetune_evaluate_with_a_very_long_name --port 5173 --config',
  ),
  _l('127.0.0.1', 5432, pid: 701, process: 'postgres'),
  _l('192.168.0.108', 8080, pid: 5150, process: 'caddy'),
  _l('127.0.0.1', 8081),
  _l('127.0.0.1', 8790, pid: 9300, process: 'Tiến độ huấn luyện và đánh giá mô hình'),
  _l('::', 8792, family: 6, pid: 9301, process: 'uvicorn'),
  _l('0.0.0.0', 8792, pid: 9301, process: 'uvicorn'),
  for (var i = 0; i < 49; i++) _l('127.0.0.1', 9000 + i * 7, pid: 20000 + i, process: i % 3 == 0 ? null : 'worker-$i'),
];

void main() {
  if (Platform.environment['PORTS_SHOTS'] == null) {
    test('ports shots are off (set PORTS_SHOTS=1)', () {}, skip: 'set PORTS_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['PORTS_SHOTS_DIR'] ?? '/tmp/ports_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final sizes = [
    (Brightness.light, const Size(412, 892), 1.0),
    (Brightness.dark, const Size(412, 892), 1.0),
    (Brightness.light, const Size(320, 640), 1.6),
  ];

  const names = ['worst-case', 'few', 'empty', 'no-helper', 'cannot-list', 'lost-link', 'loading', 'closed-while-open'];

  /// How the machine answers, per case; [watch] is what `ports.watch` sends.
  FakeTransport machineFor(String name, StreamController<Object?> watch) => switch (name) {
    'no-helper' => FakeTransport(),
    'cannot-list' =>
      FakeTransport()
        ..onHostMessages = (s, m, a) => Stream.error(const HostException('unavailable', 'needs lsof on this machine')),
    'lost-link' =>
      FakeTransport()..onHostMessages = (s, m, a) => Stream.error(const HostLinkLost('the connection dropped')),
    _ => FakeTransport()..onHostMessages = (s, m, a) => watch.stream,
  };

  for (final (brightness, size, scale) in sizes) {
    for (final name in names) {
      final tag = '${brightness.name}-${size.width.round()}x${size.height.round()}${scale == 1.0 ? '' : '-x$scale'}';
      testWidgets('$name: $tag', (tester) async {
        final fleet = emptyFleet();
        addTearDown(fleet.dispose);
        final watch = StreamController<Object?>();
        // Not awaited: the close of a stream nobody listened to never completes.
        addTearDown(() => unawaited(watch.close()));
        final machine = MachineConnection(
          profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
          api: HerdrApi(machineFor(name, watch)),
          backoff: (_) => const Duration(hours: 1),
          pollInterval: const Duration(hours: 1),
        );
        switch (name) {
          case 'worst-case':
            watch.add({'listeners': _worst()});
          case 'few':
            watch.add({
              'listeners': [
                _l('127.0.0.1', 3000, pid: 4242, process: 'node'),
                _l('127.0.0.1', 8000),
                _l('0.0.0.0', 22, pid: 811, process: 'sshd'),
              ],
            });
          case 'empty':
            watch.add({'listeners': <Object?>[]});
          case 'closed-while-open':
            watch.add({
              'listeners': [
                _l('127.0.0.1', 3000, pid: 4242, process: 'node'),
                _l('127.0.0.1', 5173, pid: 9120, process: 'vite'),
                _l('127.0.0.1', 8000, pid: 9300, process: 'uvicorn'),
              ],
            });
            watch.add({
              'opened': [_l('127.0.0.1', 8787, pid: 9400, process: 'wrangler')],
              'closed': [_l('127.0.0.1', 5173)],
            });
        }
        await shoot(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => unawaited(showPortsSheet(context, machine)),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          '$out/$name-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => withFleet(
            fleet,
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: app,
              ),
            ),
          ),
          pump: (t) async {
            await t.tap(find.text('open'));
            await t.pump(const Duration(milliseconds: 600));
            await t.pump(const Duration(milliseconds: 300));
          },
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
