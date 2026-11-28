import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/ports/ports_sheet.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';

import 'support/fake_transport.dart';
import 'support/fake_webview.dart';
import 'support/shot.dart' show loadAppFonts;

// The Ports sheet as a person uses it: what a row says, which taps open a page
// and which are dimmed with their reason, what the sheet says when the machine
// cannot tell, and that it stops watching when it closes. Pixels are in
// ui/ports_shots_test.dart (PORTS_SHOTS=1).

Map<String, Object?> _l(String addr, int port, {int family = 4, int? pid, String? process}) => {
  'family': family,
  'addr': addr,
  'port': port,
  'pid': ?pid,
  'process': ?process,
};

void main() {
  setUpAll(loadAppFonts);

  late FakeTransport transport;
  late FleetRepository fleet;
  late StreamController<Object?> watch;
  var cancelled = 0;
  var watching = 0;

  setUp(() {
    cancelled = 0;
    watching = 0;
    FakeWebView.install();
    fleet = emptyFleet();
    addTearDown(fleet.dispose);
    transport = FakeTransport()
      ..onHostMessages = (service, method, args) {
        watching++;
        // Every watch the sheet opens is a stream of its own; the test talks to the latest.
        watch = StreamController<Object?>(onCancel: () => cancelled++);
        return watch.stream;
      };
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, {Size size = const Size(412, 892)}) async {
    final machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
      api: HerdrApi(transport),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      withFleet(
        fleet,
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  TextButton(onPressed: () => unawaited(showPortsSheet(context, machine)), child: const Text('open')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Future<void> machineSays(WidgetTester tester, List<Map<String, Object?>> listeners) async {
    watch.add({'listeners': listeners});
    await settle(tester);
  }

  testWidgets('says it is looking until the machine answers, then lists what listens', (tester) async {
    await open(tester);
    expect(find.text('Ports'), findsOneWidget);
    expect(find.text('Looking for open ports…'), findsOneWidget);

    await machineSays(tester, [_l('127.0.0.1', 3000, pid: 4242, process: 'node'), _l('127.0.0.1', 8000)]);

    expect(find.text('Looking for open ports…'), findsNothing);
    expect(find.text('node'), findsOneWidget);
    expect(find.text('localhost:3000 · pid 4242'), findsOneWidget);
    expect(find.text('Port 8000'), findsOneWidget, reason: 'no process name: the port is the name');
    expect(find.text('localhost:8000'), findsOneWidget);
  });

  testWidgets('a tap opens the port as a page through the connection', (tester) async {
    await open(tester);
    await machineSays(tester, [_l('127.0.0.1', 3000, pid: 4242, process: 'node')]);

    await tester.tap(find.text('node'));
    await settle(tester);

    expect(find.byType(WebPreviewScreen), findsOneWidget);
    expect(transport.webBridges.single, isA<PortForward>().having((p) => p.port, 'port', 3000));
  });

  testWidgets('SSH and a database are listed dimmed with what they are, and a tap opens nothing', (tester) async {
    await open(tester);
    await machineSays(tester, [
      _l('0.0.0.0', 22, pid: 811, process: 'sshd'),
      _l('127.0.0.1', 5432, process: 'postgres'),
      _l('192.168.0.108', 8080, process: 'caddy'),
    ]);

    expect(find.text('localhost:22 · pid 811 · SSH · not a web page'), findsOneWidget);
    expect(find.text('localhost:5432 · PostgreSQL · not a web page'), findsOneWidget);
    expect(find.text('192.168.0.108:8080 · Not on localhost'), findsOneWidget);

    for (final name in ['sshd', 'postgres', 'caddy']) {
      await tester.tap(find.text(name));
      await settle(tester);
    }

    expect(find.byType(WebPreviewScreen), findsNothing);
    expect(transport.webBridges, isEmpty);
    expect(find.text('Ports'), findsOneWidget, reason: 'the list stays');
  });

  testWidgets('a port that closes while the sheet is open stays where it was, dimmed, and cannot be opened', (
    tester,
  ) async {
    await open(tester);
    await machineSays(tester, [_l('127.0.0.1', 3000, process: 'node'), _l('127.0.0.1', 5173, process: 'vite')]);
    final before = tester.getTopLeft(find.text('vite')).dy;

    watch.add({
      'opened': [_l('127.0.0.1', 1234, process: 'new')],
      'closed': [_l('127.0.0.1', 3000)],
    });
    await settle(tester);

    expect(tester.getTopLeft(find.text('vite')).dy, before, reason: 'nothing moves under a thumb');
    expect(find.text('localhost:3000 · No longer listening'), findsOneWidget);
    expect(tester.getTopLeft(find.text('new')).dy, greaterThan(before), reason: 'new ports join at the end');
    await tester.tap(find.text('node'));
    await settle(tester);
    expect(find.byType(WebPreviewScreen), findsNothing);
  });

  testWidgets('nothing listening says so', (tester) async {
    await open(tester);
    await machineSays(tester, []);

    expect(find.text('Nothing is listening on this machine.'), findsOneWidget);
  });

  testWidgets('a machine without the agent helper keeps one dimmed row saying what it needs', (tester) async {
    transport = FakeTransport();
    await open(tester);

    expect(find.text('Needs the agent helper on this machine.'), findsOneWidget);
    expect(find.text('Nothing is listening on this machine.'), findsNothing, reason: 'cannot tell is not nothing');
  });

  testWidgets('a machine that cannot list ports says why in the machine’s words', (tester) async {
    transport.onHostMessages = (service, method, args) =>
        Stream.error(const HostException('unavailable', 'needs lsof on this machine'));
    await open(tester);

    expect(find.text('Can’t list ports on this machine.'), findsOneWidget);
    expect(find.text('needs lsof on this machine'), findsOneWidget);
    expect(find.text('Needs the agent helper on this machine.'), findsNothing);
  });

  testWidgets('a lost link says what happened and what to do, and Retry watches again', (tester) async {
    await open(tester);
    await machineSays(tester, [_l('127.0.0.1', 3000, process: 'node')]);
    expect(watching, 1);

    watch.addError(const HostLinkLost('the connection dropped'));
    await settle(tester);

    expect(find.text('Couldn’t list the ports'), findsOneWidget);
    expect(find.textContaining('Lost the connection to devbox'), findsOneWidget);
    expect(find.text('node'), findsNothing, reason: 'a list the machine stopped confirming is not shown');

    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(watching, 2);
    await machineSays(tester, [_l('127.0.0.1', 4000, process: 'bun')]);
    expect(find.text('bun'), findsOneWidget);
    expect(find.text('Couldn’t list the ports'), findsNothing);
  });

  testWidgets('closing the sheet ends the host watch; so does the app going to the background', (tester) async {
    await open(tester);
    await machineSays(tester, [_l('127.0.0.1', 3000, process: 'node')]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);
    expect(cancelled, 1, reason: 'nobody looks: the host stops watching');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(watching, 2, reason: 'back in front, watching again');

    await tester.tapAt(const Offset(200, 20));
    await settle(tester);
    expect(find.text('Ports'), findsNothing);
    expect(cancelled, 2);
  });

  testWidgets('sixty listeners, an 80-character process name and a narrow phone with large text do not overflow', (
    tester,
  ) async {
    await open(tester, size: const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await machineSays(tester, [
      _l(
        '127.0.0.1',
        5173,
        pid: 9120,
        process: 'python3 ${'-m training.reconstruct_finetune_evaluate '.padRight(70, 'x')}',
      ),
      _l('::', 8792, family: 6, pid: 1, process: 'uvicorn'),
      _l('0.0.0.0', 8792, pid: 1, process: 'uvicorn'),
      for (var i = 0; i < 60; i++) _l('127.0.0.1', 9000 + i, pid: 2000 + i),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.text('uvicorn'), findsOneWidget, reason: 'IPv4 and IPv6 are one row');
  });
}
