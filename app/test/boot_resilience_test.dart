import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/boot.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_snapshot_cache.dart';
import 'support/memory_stores.dart';

const _good = {
  'id': 'good',
  'label': 'good',
  'host': 'good.example',
  'port': 22,
  'username': 'u',
  'auth': 'password',
};

/// Never answers: the board must not need a machine to boot.
class _Silent extends FakeTransport {
  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) =>
      Completer<Map<String, dynamic>>().future;
}

void _prefs(Map<String, Object> values) {
  SharedPreferences.resetStatic();
  SharedPreferences.setMockInitialValues(values);
}

Future<String?> _stored(String key) async => (await SharedPreferences.getInstance()).getString(key);

void main() {
  group('saved machines', () {
    test('one that cannot be read is skipped, the others load', () async {
      _prefs({
        'machines.v1': jsonEncode([
          {'id': 'broken', 'label': 'x', 'host': 5, 'username': 'u'}, // host of the wrong type
          _good,
          {'label': 'no id', 'host': 'h', 'username': 'u'},
          'not an object',
        ]),
      });

      final machines = await PrefsProfileStore().read();

      expect(machines.map((m) => m.id), ['good']);
    });

    test('a write keeps what could not be read, so nothing is deleted or orphaned', () async {
      final broken = {'id': 'broken', 'label': 'x', 'host': 5, 'username': 'u'};
      _prefs({
        'machines.v1': jsonEncode([broken, _good]),
      });
      final store = PrefsProfileStore();
      final machines = await store.read();

      await store.write([machines.single.copyWith(label: 'renamed')]);

      final rows = jsonDecode((await _stored('machines.v1'))!) as List;
      expect(rows, hasLength(2));
      expect(rows.first, containsPair('label', 'renamed'));
      expect(rows.last, broken, reason: 'written back exactly as stored');
      expect((await PrefsProfileStore().read()).single.label, 'renamed');
    });

    test('removing every readable machine leaves the unreadable one', () async {
      final broken = {'id': 'broken', 'label': 'x', 'host': 5, 'username': 'u'};
      _prefs({
        'machines.v1': jsonEncode([_good, broken]),
      });
      final store = PrefsProfileStore();
      await store.read();

      await store.write(const []);

      expect(jsonDecode((await _stored('machines.v1'))!), [broken]);
    });

    test('a saved list that is not JSON loads as none and is copied aside before the next write', () async {
      _prefs({'machines.v1': '{oops'});
      final store = PrefsProfileStore();

      expect(await store.read(), isEmpty);
      final fresh = MachineProfile.fromJson(_good);
      await store.write([fresh]);

      expect(await _stored('machines.v1.unreadable'), '{oops');
      expect((await store.read()).single.id, fresh.id);
    });
  });

  group('terminal settings', () {
    test('a saved value of another type is the default, not a failed start', () async {
      _prefs({'terminal.fontSize.v1': 'big', 'terminal.wrap.v1': 3});
      final settings = TerminalSettings(PrefsTerminalSettingsStore());

      await settings.load();

      expect(settings.fontSize, defaultTerminalFontSize);
      expect(settings.wrap, isFalse);
    });
  });

  test('the app boots over garbage in its stores, with the machines it can read', () async {
    _prefs({
      'machines.v1': jsonEncode([
        {'id': 'broken', 'host': 5},
        _good,
      ]),
      'terminal.fontSize.v1': 'big',
    });

    final app = await bootApp(
      network: FakeNetwork(),
      secrets: MemorySecretStore(),
      snapshotCache: MemorySnapshotCache(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(_Silent()),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
    addTearDown(() => app.fleet?.dispose());
    await app.fleet!.settled();

    expect(app.machines.machines.map((m) => m.id), ['good']);
    expect(app.terminalSettings.fontSize, defaultTerminalFontSize);
  });

  group('a start that fails', () {
    test('shows what failed with Retry, and Retry boots again into the app', () async {
      final shown = <Widget>[];
      var failures = 1;
      const app = SizedBox();

      await launchApp(
        boot: () async {
          if (failures-- > 0) throw StateError('disk is full');
          return app;
        },
        show: shown.add,
      );

      expect(shown.single, isA<BootFailedApp>());

      await (shown.single as BootFailedApp).retry();

      expect(shown.last, same(app));
    });

    testWidgets('the screen names the error and Retry runs the retry', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        BootFailedApp(
          error: StateError('disk is full'),
          retry: () async => retried++,
        ),
      );

      expect(find.textContaining('disk is full'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retried, 1);
    });
  });

  group('a snapshot with a row this app cannot read', () {
    test('leaves that row out and keeps the rest', () {
      final json = snapshotJson(panes: [
        (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
        (id: 'w1:p2', ws: 'w1', agent: 'claude', status: 'working'),
      ]);
      json['panes'] = <Object?>[
        ...(json['panes']! as List),
        {'pane_id': 7, 'workspace_id': 'w1'}, // an id of the wrong type
        'junk',
      ];
      json['tabs'] = <Object?>[...(json['tabs']! as List), {'tab_id': 'only-half'}];

      final snapshot = Snapshot.fromJson(json);

      expect(snapshot.panes.map((p) => p.id), ['w1:p1', 'w1:p2']);
      expect(snapshot.workspaces, isNotEmpty);
      expect(snapshot.tabs.map((t) => t.id), isNot(contains('only-half')));
    });
  });
}
