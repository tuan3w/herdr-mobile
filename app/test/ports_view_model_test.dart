import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/host_ports.dart';
import 'package:herdr_mobile/ui/features/ports/ports_view_model.dart';

import 'support/fake_transport.dart';

// What the Ports sheet shows of the machine, from scripted `ports.watch`
// messages: the rows (what the person reads), the ones that must not be opened
// and why, rows that keep their place while the machine changes under them, and
// the states where the machine cannot say.

Map<String, Object?> _l(String addr, int port, {int family = 4, int? pid, String? process}) => {
  'family': family,
  'addr': addr,
  'port': port,
  'pid': ?pid,
  'process': ?process,
};

void main() {
  late StreamController<Object?> messages;
  late FakeTransport transport;
  var opened = 0;
  var cancelled = 0;

  PortsViewModel model() => PortsViewModel(ports: HostPorts(transport), machineName: 'devbox');

  setUp(() {
    opened = 0;
    cancelled = 0;
    transport = FakeTransport()
      ..onHostMessages = (service, method, args) {
        expect('$service.$method', 'ports.watch');
        opened++;
        messages = StreamController<Object?>(onCancel: () => cancelled++);
        return messages.stream;
      };
  });

  Future<void> full(List<Map<String, Object?>> listeners) async {
    messages.add({'listeners': listeners});
    await pumpEventQueue();
  }

  Future<void> change({
    List<Map<String, Object?>> opened = const [],
    List<Map<String, Object?>> closed = const [],
  }) async {
    messages.add({'opened': opened, 'closed': closed});
    await pumpEventQueue();
  }

  test('says it is looking until the machine answers', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    expect(vm.phase, PortsPhase.loading);
    expect(vm.rows, isEmpty);

    await full([_l('127.0.0.1', 3000)]);
    expect(vm.phase, PortsPhase.live);
  });

  test('a row is the process, else the port, over where it listens and its pid', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    await full([_l('127.0.0.1', 3000, pid: 4242, process: 'node'), _l('127.0.0.1', 8080)]);

    expect(vm.rows.map((r) => r.title), ['node', 'Port 8080']);
    expect(vm.rows[0].subtitle, 'localhost:3000 · pid 4242');
    expect(vm.rows[1].subtitle, 'localhost:8080', reason: 'no pid is said when the machine did not show the owner');
    expect(vm.rows.every((r) => r.reason == null), isTrue);
    expect(vm.rows[0].url.toString(), 'http://localhost:3000/');
  });

  test('IPv4 and IPv6 listeners of one port are one row, spelled localhost', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    await full([
      _l('0.0.0.0', 5173, pid: 9, process: 'vite'),
      _l('::', 5173, family: 6),
      _l('127.0.0.1', 3000),
      _l('::1', 3000, family: 6, pid: 7, process: 'next'),
    ]);

    expect(vm.rows, hasLength(2));
    expect(vm.rows.map((r) => r.port), [3000, 5173], reason: 'in port order, as the host sorts');
    expect(vm.rows[0].title, 'next', reason: 'the family whose owner is visible names it');
    expect(vm.rows[0].subtitle, 'localhost:3000 · pid 7');
    expect(vm.rows[1].subtitle, 'localhost:5173 · pid 9');
  });

  test(
    'a port that is not a web page, or not on localhost, stays listed with the reason and cannot be opened',
    () async {
      final vm = model()..start();
      addTearDown(vm.dispose);
      await full([
        _l('0.0.0.0', 22, pid: 811, process: 'sshd'),
        _l('127.0.0.1', 5432, process: 'postgres'),
        _l('192.168.1.5', 3000, process: 'dev'),
        _l('fe80::1', 4000, family: 6),
        _l('127.0.0.1', 8000),
      ]);

      expect(vm.rows.map((r) => r.port), [22, 3000, 4000, 5432, 8000]);
      expect(vm.rows[0].reason, 'SSH · not a web page');
      expect(vm.rows[0].subtitle, 'localhost:22 · pid 811 · SSH · not a web page');
      expect(vm.rows[1].reason, 'Not on localhost');
      expect(vm.rows[1].subtitle, '192.168.1.5:3000 · Not on localhost');
      expect(vm.rows[2].subtitle, '[fe80::1]:4000 · Not on localhost');
      expect(vm.rows[3].reason, 'PostgreSQL · not a web page');
      expect(vm.rows[4].reason, isNull, reason: 'a plain loopback port opens');
    },
  );

  test('rows keep their place: a port that closes stays, dimmed, and a new one joins at the end', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    await full([_l('127.0.0.1', 3000), _l('127.0.0.1', 5000), _l('127.0.0.1', 8000)]);

    await change(closed: [_l('127.0.0.1', 5000)], opened: [_l('127.0.0.1', 1234)]);

    expect(vm.rows.map((r) => r.port), [3000, 5000, 8000, 1234]);
    expect(vm.rows[1].listening, isFalse);
    expect(vm.rows[1].reason, 'No longer listening');
    expect(vm.rows[0].reason, isNull);

    await change(opened: [_l('127.0.0.1', 5000)]);
    expect(vm.rows.map((r) => r.port), [3000, 5000, 8000, 1234], reason: 'it came back where it was');
    expect(vm.rows[1].listening, isTrue);
  });

  test('a machine where nothing listens is live with no rows, not an error', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    await full([]);

    expect(vm.phase, PortsPhase.live);
    expect(vm.rows, isEmpty);
  });

  test('a machine without the helper is unsupported, with its reason, and has no rows', () async {
    final vm = PortsViewModel(ports: HostPorts(FakeTransport()), machineName: 'devbox')..start();
    addTearDown(vm.dispose);
    await eventually(() => vm.phase != PortsPhase.loading);

    expect(vm.phase, PortsPhase.unsupported);
    expect(vm.unsupported!.helperMissing, isTrue);
    expect(vm.rows, isEmpty);
  });

  test('a lost link says what happened and what to do, drops the rows, and Retry watches again', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    await full([_l('127.0.0.1', 3000)]);

    messages.addError(const HostLinkLost('the connection dropped'));
    await eventually(() => vm.phase == PortsPhase.failed);
    expect(vm.error, contains('devbox'));
    expect(vm.error, contains('Retry'));
    expect(vm.rows, isEmpty, reason: 'a list the machine stopped confirming is not shown as live');

    vm.retry();
    expect(vm.phase, PortsPhase.loading);
    expect(opened, 2);
    await full([_l('127.0.0.1', 4000)]);
    expect(vm.phase, PortsPhase.live);
    expect(vm.rows.single.port, 4000);
  });

  test('the host ending the watch is a failure, not a silent freeze', () async {
    final vm = model()..start();
    addTearDown(vm.dispose);
    await full([_l('127.0.0.1', 3000)]);

    await messages.close();
    await eventually(() => vm.phase == PortsPhase.failed);
  });

  test('closing the sheet and sending the app to the background both end the host watch', () async {
    final vm = model()..start();
    await full([_l('127.0.0.1', 3000)]);
    expect(opened, 1);

    vm.pause();
    expect(cancelled, 1);

    vm.resume();
    expect(opened, 2, reason: 'back in front: watching again, the first message brings the list up to date');
    await full([_l('127.0.0.1', 3000), _l('127.0.0.1', 4000)]);
    expect(vm.rows.map((r) => r.port), [3000, 4000]);

    vm.dispose();
    expect(cancelled, 2);
  });

  test('start is idempotent: one host watch however often it is asked', () async {
    final vm = model()
      ..start()
      ..start();
    addTearDown(vm.dispose);
    expect(opened, 1);
  });
}
