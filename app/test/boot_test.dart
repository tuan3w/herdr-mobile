import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/boot.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

/// A machine that never answers: what the board shows has to come from disk.
class _Silent extends FakeTransport {
  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => Completer<Map<String, dynamic>>().future;
}

Map<String, Object> _prefs() {
  Map<String, Object?> machine(String id) => {
        'id': id,
        'label': id,
        'host': '$id.example',
        'port': 22,
        'username': 'u',
        'auth': 'password',
        'session': 'default',
        'enabled': true,
      };
  String snapshot(String id) => jsonEncode(
        Snapshot.fromJson(snapshotJson(
          workspaces: [(id: '$id-w', label: 'work')],
          panes: [
            (id: '$id-p1', ws: '$id-w', agent: 'claude', status: 'working'),
            (id: '$id-p2', ws: '$id-w', agent: 'codex', status: 'blocked'),
            (id: '$id-p3', ws: '$id-w', agent: null, status: 'idle'),
          ],
        )).toJson(),
      );
  return {
    'machines.v1': jsonEncode([machine('a'), machine('b')]),
    'herdr.snapshot.v1.a': snapshot('a'),
    'herdr.snapshot.v1.b': snapshot('b'),
  };
}

void main() {
  test('the connections exist and show their cache before the first frame', () async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(_prefs());
    final cache = PrefsSnapshotCache();

    final app = await bootApp(
      network: FakeNetwork(),
      secrets: MemorySecretStore(),
      snapshotCache: cache,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        cache: cache,
        api: HerdrApi(_Silent()),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
    addTearDown(() => app.fleet?.dispose());

    final fleet = app.fleet;
    expect(fleet, isNotNull, reason: 'built at boot, not when the first frame builds');
    await fleet!.settled();
    await eventually(() => fleet.agents.length == 4, reason: 'cached agents');

    expect(fleet.connections.map((c) => c.profile.id), ['a', 'b']);
    expect(
      fleet.agents.map((a) => a.pane.id).toSet(),
      {'a-p1', 'a-p2', 'b-p1', 'b-p2'},
      reason: 'the two agent panes of each machine; the idle shell is not one',
    );
    expect(fleet.agents.every((a) => a.stale), isTrue,
        reason: 'from disk, not yet confirmed by the machine');
  });

  test('a first launch with no machines boots to an empty fleet', () async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});

    final app = await bootApp(
      network: FakeNetwork(),
      secrets: MemorySecretStore(),
      snapshotCache: PrefsSnapshotCache(),
    );
    addTearDown(() => app.fleet?.dispose());

    await app.fleet!.settled();
    expect(app.fleet!.connections, isEmpty);
    expect(app.machines.machines, isEmpty);
  });
}
