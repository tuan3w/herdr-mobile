import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/host_inbox.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

// When the phone asks a machine to sweep its inbox. Which files go, and how a
// phone file is named, is the agent helper's rule, tested in
// rust/crates/host (svc/transfer.rs) and against the real binary in
// host_transfer_test.dart.

final _now = DateTime(2026, 10, 5, 9, 8, 7);

MachineConnection _machine(String id, FakeTransport transport) => MachineConnection(
  profile: MachineProfile(id: id, label: 'box', host: 'h', username: 'u'),
  api: HerdrApi(transport),
  pollInterval: const Duration(hours: 1),
);

void main() {
  test('watch sweeps when the machine first goes online, once per run', () async {
    final transport = FakeTransport()
      ..fs = FakeFs()
      ..sweepRemoved = 3;
    final machine = _machine('m3', transport);
    addTearDown(machine.dispose);
    final log = _MemoryLog();
    InboxJanitor(log, startDelay: Duration.zero).watch(machine);
    expect(transport.sweeps, 0, reason: 'not before the machine is online');
    machine.start();
    await eventually(() => log.runs.isNotEmpty, reason: 'the sweep after going online');
    expect(transport.sweeps, 1);
  });

  test('sweeps a machine at most once per 24 hours', () async {
    final transport = FakeTransport()
      ..fs = FakeFs()
      ..sweepRemoved = 2;
    final machine = _machine('m1', transport);
    addTearDown(machine.dispose);
    var clock = _now;
    final log = _MemoryLog();
    final janitor = InboxJanitor(log, now: () => clock);

    expect(await janitor.run(machine), 2);
    clock = clock.add(const Duration(hours: 23));
    expect(await janitor.run(machine), isNull, reason: 'swept 23 h ago');
    expect(transport.sweeps, 1);
    clock = clock.add(const Duration(hours: 2));
    expect(await janitor.run(machine), 2);
    expect(transport.sweeps, 2);
  });

  test('a machine without files, or one that cannot sweep, is skipped and tried again later', () async {
    final log = _MemoryLog();
    final janitor = InboxJanitor(log, now: () => _now);

    final bare = _machine('bare', FakeTransport());
    addTearDown(bare.dispose);
    expect(await janitor.run(bare), isNull);
    expect(log.runs.containsKey('bare'), isFalse);

    final failing = FakeTransport()
      ..fs = FakeFs()
      ..sweepFailure = RemoteFileException(RemoteFileErrorKind.unsupported, 'Needs the agent helper on this machine.');
    final broken = _machine('broken', failing);
    addTearDown(broken.dispose);
    expect(await janitor.run(broken), isNull);
    expect(log.runs.containsKey('broken'), isFalse, reason: 'not recorded: the next launch tries again');
  });
}

class _MemoryLog implements InboxCleanupLog {
  final runs = <String, DateTime>{};

  @override
  Future<DateTime?> lastRun(String machineId) async => runs[machineId];

  @override
  Future<void> record(String machineId, DateTime at) async => runs[machineId] = at;
}
