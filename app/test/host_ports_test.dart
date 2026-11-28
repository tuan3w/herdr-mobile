@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/host_ports.dart';

import 'support/fake_transport.dart';
import 'support/process_host.dart';

// The machine's ports and "made" facts, asked of the REAL `herdr-host serve`:
// this test process listens on ports of its own and the helper must see them,
// with this process as the owner (Linux: /proc says so).
//
// Needs the binary: `cd rust && cargo build --release -p host`, or
// HERDR_HOST_BIN=/path/to/herdr-host.

File _binary() {
  final fromEnv = Platform.environment['HERDR_HOST_BIN'];
  if (fromEnv != null && fromEnv.isNotEmpty) return File(fromEnv);
  final root = File('test/host_ports_test.dart').absolute.parent.parent.parent.path;
  return File('$root/rust/target/release/herdr-host');
}

void main() {
  final bin = _binary();
  final skip = bin.existsSync()
      ? false
      : 'build the host first: cd rust && cargo build --release -p host (or set HERDR_HOST_BIN)';
  late Directory home;
  final started = <HostProcess>[];

  setUp(() => home = Directory.systemTemp.createTempSync('host_ports'));

  tearDown(() {
    for (final p in started) {
      p.close();
    }
    started.clear();
    home.deleteSync(recursive: true);
  });

  Future<HostPorts> ports() async {
    final p = await ProcessHostProcess.start(
      bin.path,
      ['serve'],
      environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
      workingDirectory: home.path,
    );
    started.add(p);
    final link = await HostLink.connect(p, version: appVersion);
    return HostPorts(LinkTransport(() async => link));
  }

  Future<ServerSocket> listen() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(socket.close);
    return socket;
  }

  /// This test process owns the port, where the platform can say who owns it.
  final owned = Platform.isLinux;

  test('list finds a port this process listens on, with this process as its owner', () async {
    final socket = await listen();
    final found = (await (await ports()).list()).where((l) => l.port == socket.port).toList();

    expect(found, hasLength(1));
    expect(found.single.addr, '127.0.0.1');
    expect(found.single.family, 4);
    if (owned) expect(found.single.pid, pid);
  }, skip: skip);

  test('watch starts with the full list, then shows a port that opens and drops one that closes', () async {
    final watch = (await ports()).watch(interval: const Duration(seconds: 1));
    var latest = <PortListener>[];
    var updates = 0;
    final sub = watch.listen((l) {
      latest = l;
      updates++;
    });
    addTearDown(sub.cancel);
    await eventually(() => updates > 0, reason: 'the first full list');

    final socket = await listen();
    final port = socket.port;
    await eventually(() => latest.any((l) => l.port == port), reason: 'the port that opened after the watch started');
    if (owned) expect(latest.firstWhere((l) => l.port == port).pid, pid);

    await socket.close();
    await eventually(() => !latest.any((l) => l.port == port), reason: 'the port that closed');
  }, skip: skip);

  test('verifyMade answers files and ports in one batch, each by its own id', () async {
    final socket = await listen();
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final file = File('${home.path}/report.html')..writeAsStringSync('<h1>x</h1>');

    final checks = await (await ports()).verifyMade([
      MadeProbe.path('file', file.path),
      MadeProbe.path('missing', '${home.path}/nope.html'),
      MadeProbe.path('home', '~/report.html'),
      MadeProbe.port('up', socket.port),
      MadeProbe.port('down', closedPort),
    ]);
    final byId = {for (final c in checks) c.id: c};

    expect(byId['file']!.exists, isTrue);
    expect(byId['file']!.kind, 'file');
    expect(byId['file']!.size, 10);
    expect(byId['missing']!.exists, isFalse);
    expect(byId['home']!.exists, isTrue, reason: '~ is the host’s home');
    expect(byId['up']!.listening, isTrue);
    if (owned) expect(byId['up']!.pid, pid);
    expect(byId['down']!.listening, isFalse);
  }, skip: skip);

  test('more probes than the host takes at once are asked in several calls and answered in order', () async {
    final probes = [for (var i = 0; i < 450; i++) MadeProbe.path('p$i', '${home.path}/missing$i')];
    final checks = await (await ports()).verifyMade(probes);

    expect(checks.map((c) => c.id), probes.map((p) => p.id));
    expect(checks.every((c) => c.exists == false), isTrue);
  }, skip: skip);

  group('a machine without the agent helper', () {
    // FakeTransport answers the way the app's transport does when the helper
    // cannot be had: `unavailable`.
    test('every question is HostUnsupported, never an empty answer', () async {
      final host = HostPorts(FakeTransport());

      await expectLater(host.list(), throwsA(isA<HostUnsupported>()));
      await expectLater(host.watch(), emitsError(isA<HostUnsupported>()));
      await expectLater(host.verifyMade([const MadeProbe.port('a', 3000)]), throwsA(isA<HostUnsupported>()));
    });

    test('says it is the helper that is missing, as opposed to a machine that cannot look', () async {
      final host = HostPorts(FakeTransport());
      final missing = await host.list().then<Object?>((_) => null, onError: (Object e) => e);
      expect((missing! as HostUnsupported).helperMissing, isTrue);

      final transport = FakeTransport()
        ..onHostCall = (service, method, args) async =>
            throw const HostException('unavailable', 'needs lsof on this machine');
      final cannot = await HostPorts(transport).list().then<Object?>((_) => null, onError: (Object e) => e);
      expect((cannot! as HostUnsupported).helperMissing, isFalse);
      expect((cannot as HostUnsupported).reason, 'needs lsof on this machine');
    });
  });

  group('failures that are not "unsupported" stay what they are', () {
    test('a lost link and other host errors pass through', () async {
      final transport = FakeTransport()
        ..onHostCall = (service, method, args) async => throw const HostLinkLost('the connection dropped');
      await expectLater(HostPorts(transport).list(), throwsA(isA<HostLinkLost>()));

      transport.onHostCall = (service, method, args) async =>
          throw const HostException('timeout', 'slow', retryable: true);
      await expectLater(
        HostPorts(transport).verifyMade([const MadeProbe.port('a', 3000)]),
        throwsA(isA<HostException>().having((e) => e.code, 'code', 'timeout')),
      );
    });
  });

  group('the watch, from scripted host messages', () {
    test('rebuilds the list from the first full message and the opened/closed changes after it', () async {
      final messages = StreamController<Object?>();
      final transport = FakeTransport()..onHostMessages = (service, method, args) => messages.stream;
      final lists = <List<String>>[];
      final sub = HostPorts(transport).watch().listen((l) => lists.add([for (final x in l) '${x.addr}:${x.port}']));
      addTearDown(sub.cancel);

      Map<String, Object?> l(String addr, int port, {int family = 4}) => {'family': family, 'addr': addr, 'port': port};
      messages.add({
        'listeners': [l('127.0.0.1', 8000), l('::', 3000, family: 6)],
      });
      messages.add({
        'opened': [l('0.0.0.0', 5173)],
        'closed': [l('127.0.0.1', 8000)],
      });
      await eventually(() => lists.length == 2);

      expect(lists[0], [':::3000', '127.0.0.1:8000']);
      expect(lists[1], [':::3000', '0.0.0.0:5173']);
    });

    test('cancelling ends the host stream at once, even while no change is coming', () async {
      var cancelled = false;
      final messages = StreamController<Object?>(onCancel: () => cancelled = true);
      final transport = FakeTransport()..onHostMessages = (service, method, args) => messages.stream;
      final sub = HostPorts(transport).watch().listen((_) {});
      messages.add({'listeners': <Object?>[]});
      await eventually(() => messages.hasListener);

      await sub.cancel();

      expect(cancelled, isTrue);
    });

    test('asks the host for at least a second between looks', () async {
      Map<String, Object?>? asked;
      final transport = FakeTransport()
        ..onHostMessages = (service, method, args) {
          asked = args;
          return const Stream.empty();
        };
      await HostPorts(transport).watch(interval: const Duration(milliseconds: 100)).toList();
      expect(asked, {'interval_ms': 1000});
    });
  });
}
