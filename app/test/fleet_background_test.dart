// The fleet in the background: the 90 s suspension, and what keeps it from
// happening while there is something to watch.
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

class _Harness {
  _Harness(this.async) {
    machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      network: network,
      clock: () => now,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transports.putIfAbsent(profile.id, FakeTransport.new)),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(seconds: 20),
        backgroundPollInterval: const Duration(minutes: 2),
      ),
    );
    machines.save(
      const MachineProfile(id: 'a', label: 'Alpha', host: 'a.local', username: 'u'),
      secrets: const MachineSecrets(password: 'x'),
    );
    async.flushMicrotasks();
    advance(const Duration(seconds: 1));
  }

  final FakeAsync async;
  final network = FakeNetwork();
  final transports = <String, FakeTransport>{};
  FakeTransport get transport => transports['a']!;
  late final MachineRepository machines;
  late final FleetRepository fleet;
  DateTime now = DateTime.utc(2026);

  MachineConnection get connection => fleet.connection('a')!;

  void advance(Duration d) {
    now = now.add(d);
    async.elapse(d);
  }

  void life(AppLifecycleState state) {
    fleet.onLifecycleState(state);
    async.flushMicrotasks();
  }

  void dispose() => fleet.dispose();
}

void main() {
  const away = AppLifecycleState.paused;
  const back = AppLifecycleState.resumed;
  const grace = Duration(seconds: 90);

  void run(void Function(_Harness h) body) => fakeAsync((async) {
        final h = _Harness(async);
        expect(h.connection.isLive, isTrue, reason: 'set-up');
        body(h);
        h.dispose();
      });

  group('the 90 s suspension', () {
    test('applies by default', () {
      run((h) {
        expect(h.fleet.keepAliveInBackground, isFalse);
        h.life(away);
        h.advance(grace);
        expect(h.connection.isLive, isFalse);
      });
    });

    test('does not apply while the notifier keeps the fleet alive, however long', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(grace);
        h.advance(const Duration(minutes: 30));
        expect(h.connection.isLive, isTrue);
        expect(h.transport.resets, 0);
      });
    });

    test('a connection kept alive recovers from a network change by itself', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(const Duration(minutes: 5));

        h.network.goOffline();
        h.async.flushMicrotasks();
        expect(h.connection.isLive, isFalse);
        h.network.goOnline('mobile');
        h.advance(const Duration(seconds: 2));
        expect(h.connection.isLive, isTrue);
      });
    });

    test('keeping alive that starts inside the grace period still holds it off', () {
      run((h) {
        h.life(away);
        h.advance(const Duration(seconds: 60));
        h.fleet.keepAliveInBackground = true;
        h.advance(const Duration(minutes: 5));
        expect(h.connection.isLive, isTrue);
      });
    });

    test('keeping alive that ends inside the grace period suspends at 90 s, not before', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(const Duration(seconds: 30));
        h.fleet.keepAliveInBackground = false;
        h.advance(const Duration(seconds: 59));
        expect(h.connection.isLive, isTrue);
        h.advance(const Duration(seconds: 1));
        expect(h.connection.isLive, isFalse);
      });
    });

    test('keeping alive that ends after the grace period suspends at once', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(const Duration(minutes: 10));
        expect(h.connection.isLive, isTrue);

        h.fleet.keepAliveInBackground = false;
        expect(h.connection.isLive, isFalse);
        final calls = h.transport.snapshotCalls;
        h.advance(const Duration(minutes: 10));
        expect(h.transport.snapshotCalls, calls, reason: 'nothing runs while suspended');
      });
    });

    test('keeping alive that ends in the foreground does nothing to the connections', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.advance(const Duration(minutes: 10));
        h.fleet.keepAliveInBackground = false;
        h.advance(const Duration(minutes: 10));
        expect(h.connection.isLive, isTrue);
      });
    });

    test('a second background after a kept-alive one starts the clock again', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(const Duration(minutes: 5));
        h.life(back);
        h.fleet.keepAliveInBackground = false;

        h.life(away);
        h.advance(const Duration(seconds: 89));
        expect(h.connection.isLive, isTrue);
        h.advance(const Duration(seconds: 1));
        expect(h.connection.isLive, isFalse);
      });
    });
  });

  group('coming back', () {
    test('after a kept-alive absence the sockets are refreshed, not reset', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(const Duration(minutes: 10));
        final calls = h.transport.snapshotCalls;

        h.life(back);
        h.advance(const Duration(seconds: 1));
        expect(h.transport.resets, 0);
        expect(h.transport.snapshotCalls, greaterThan(calls), reason: 'a refresh, to see what changed');
        expect(h.connection.isLive, isTrue);
      });
    });

    test('after an absence that was not kept alive they are reset, as before', () {
      run((h) {
        h.life(away);
        h.advance(const Duration(seconds: 30));
        h.life(back);
        h.advance(const Duration(seconds: 1));
        expect(h.transport.resets, 1);
      });
    });

    test('after a suspension that came from the end of the watching they are reset', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.advance(const Duration(minutes: 10));
        h.fleet.keepAliveInBackground = false;
        expect(h.connection.isLive, isFalse);

        h.life(back);
        h.advance(const Duration(seconds: 1));
        expect(h.connection.isLive, isTrue);
        expect(h.transport.resets, greaterThan(0));
      });
    });
  });

  group('the keep-alive flag', () {
    test('tells the screens that read it, once per change', () {
      run((h) {
        var told = 0;
        h.fleet.addListener(() => told++);
        h.fleet.keepAliveInBackground = true;
        h.fleet.keepAliveInBackground = true;
        expect(told, 1);
        h.fleet.keepAliveInBackground = false;
        expect(told, 2);
      });
    });
  });

  group('the background profile of the transport', () {
    test('is asked for only while the app is away AND the fleet is kept alive', () {
      run((h) {
        h.life(away);
        h.advance(const Duration(seconds: 30));
        expect(h.transport.backgroundCalls, isEmpty, reason: 'away, but nobody is watching');
        h.life(back);

        h.fleet.keepAliveInBackground = true;
        expect(h.transport.backgroundCalls, isEmpty, reason: 'watching, but in front');

        h.life(away);
        expect(h.transport.backgroundCalls, [true]);
        h.life(back);
        expect(h.transport.backgroundCalls, [true, false]);
      });
    });

    test('follows keep-alive while the app is away', () {
      run((h) {
        h.life(away);
        h.fleet.keepAliveInBackground = true;
        expect(h.transport.backgroundCalls, [true]);
        h.advance(const Duration(minutes: 5));
        h.fleet.keepAliveInBackground = false;
        expect(h.transport.backgroundCalls, [true, false]);
      });
    });

    test('a machine added while the profile holds starts in it', () {
      run((h) {
        h.fleet.keepAliveInBackground = true;
        h.life(away);
        h.machines.save(
          const MachineProfile(id: 'b', label: 'Bravo', host: 'b.local', username: 'u'),
          secrets: const MachineSecrets(password: 'x'),
        );
        h.async.flushMicrotasks();
        h.advance(const Duration(seconds: 1));
        expect(h.transports['b']!.backgroundCalls, [true]);

        h.life(back);
        expect(h.transports['b']!.backgroundCalls, [true, false]);
      });
    });
  });
}
