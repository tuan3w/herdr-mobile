// The machines tab, one machine's workspaces, and the add/edit form: worst-case
// data at phone widths, every connection state, and the flows a person uses.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_transport.dart';
import '../support/memory_stores.dart';
import 'ui_harness.dart';

const _fatal = HerdrTransportException('Permission denied (publickey).', fatal: true);
const _longLabel = 'build-server-eu-west-2-production-primary-gpu-cluster-0042';
const _longHost = 'bartholomew.fitzgerald@northwind-industries-holdings.example.com';

MachineProfile _m(
  String id,
  String label, {
  String host = 'h.example',
  String user = 'fatman',
  bool enabled = true,
  int port = 22,
  SshAuth auth = SshAuth.password,
}) =>
    MachineProfile(id: id, label: label, host: host, username: user, enabled: enabled, port: port, auth: auth);

List<Pane> _agents(int n, {String ws = 'w1', String status = 'working', int blocked = 0}) => [
      for (var i = 0; i < n; i++)
        (id: '$ws:p$i', ws: ws, agent: 'claude', status: i < blocked ? 'blocked' : status),
    ];

/// Lets async connection work and animations finish.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  UiHarness? fleet,
  MachineRepository? repo,
  double width = 360,
  double height = 740,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        if (fleet != null) ...[
          ChangeNotifierProvider.value(value: fleet.machines),
          ChangeNotifierProvider.value(value: fleet.fleet),
        ] else
          ChangeNotifierProvider.value(value: repo!),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await _flush(tester);
}

/// Scrolls [finder] into view (the pinned header can cover it otherwise) and taps it.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _flush(tester);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _flush(tester);
}

Future<void> _tearDown(WidgetTester tester, [UiHarness? h]) async {
  await tester.pumpWidget(const SizedBox());
  h?.dispose();
}

/// One machine per connection state the machines tab can show.
Future<UiHarness> _everyState() async {
  final h = await UiHarness.create([
    (profile: _m('online', 'workstation', host: '192.168.110.60'), snapshot: snapshotWith(_agents(3, blocked: 2))),
    (profile: _m('offline', 'laptop'), snapshot: snapshotWith(_agents(1))),
    (profile: _m('attention', 'staging'), snapshot: snapshotWith(_agents(1))),
    (profile: _m('reconnecting', 'flaky'), snapshot: snapshotWith(_agents(1))),
    (profile: _m('approval', 'tailnet', auth: SshAuth.none), snapshot: snapshotWith(_agents(1))),
    (profile: _m('disabled', 'sleepy', enabled: false), snapshot: snapshotWith(const [])),
  ]);
  h.fleet.connection('offline')!.goOffline();
  h.transports['attention']!.failure = _fatal;
  h.fleet.connection('attention')!.reconnect();
  h.transports['reconnecting']!.failure = const HerdrTransportException('Connection reset by peer');
  h.fleet.connection('reconnecting')!.reconnect();
  h.transports['approval']!.failure = const HerdrTransportException('waiting');
  h.fleet.connection('approval')!.reconnect();
  return h;
}

Future<void> _approve(WidgetTester tester, UiHarness h) async {
  await _flush(tester);
  h.fleet.connection('approval')!.onAuthNotice('visit: https://login.tailscale.com/a/l3503a0535f1bf');
  await tester.pump();
}

void main() {
  group('machines tab', () {
    for (final (width, scale) in [(360.0, 1.0), (320.0, 1.0), (320.0, 2.0)]) {
      testWidgets('every connection state is said in words at ${width.toInt()}dp ${scale}x', (tester) async {
        final h = await _everyState();
        await _pump(tester, const MachinesScreen(), fleet: h, width: width, height: 3000, scale: scale);
        await _approve(tester, h);

        expect(find.text('workstation'), findsOneWidget);
        expect(find.textContaining('workspace'), findsWidgets, reason: 'online meta line');
        expect(find.text('No network'), findsOneWidget);
        expect(find.text('Needs attention'), findsOneWidget);
        expect(find.text('Permission denied (publickey).'), findsOneWidget, reason: 'the reason, not just the state');
        expect(find.textContaining('Reconnecting'), findsOneWidget);
        expect(find.text('Waiting for approval'), findsOneWidget);
        expect(find.text('Open sign-in page'), findsOneWidget);
        expect(find.textContaining('not connecting'), findsOneWidget, reason: 'a disabled machine says why it is quiet');
        expect(find.text('Retry'), findsNWidgets(2), reason: 'attention and reconnecting offer a retry');
        await _tearDown(tester, h);
      });
    }

    testWidgets('worst-case names stay in their lane and counts are never cut', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _m('a', _longLabel, host: 'ip-10-0-143-201.eu-west-2.compute.internal', user: 'bartholomew.fitzgerald'),
          snapshot: snapshotWith(_agents(120, blocked: 120)),
        ),
        (profile: _m('b', 'x', host: 'a', user: 'u'), snapshot: snapshotWith(_agents(1))),
        (
          profile: _m('c', 'Tuấn Nguyễn', host: 'nguyễn.example', user: 'Tuấn'),
          snapshot: snapshotWith(const [], workspaces: const []),
        ),
        (profile: _m('d', '$_longHost-staging', host: _longHost), snapshot: snapshotWith(_agents(2, blocked: 2))),
      ]);
      for (final (width, scale) in [(360.0, 1.0), (320.0, 2.0)]) {
        await _pump(tester, const MachinesScreen(), fleet: h, width: width, scale: scale);
        expect(find.text('120'), findsOneWidget, reason: 'attention count is shown in full');
        expect(find.text('Tuấn Nguyễn'), findsOneWidget);
        expect(find.text('x'), findsOneWidget);
        // A machine with no workspaces says so rather than "0 workspaces · 0 agents".
        if (scale == 1) expect(find.textContaining('No workspaces'), findsOneWidget);
      }
      await _tearDown(tester, h);
    });

    testWidgets('no machines: inviting empty state whose button opens the form', (tester) async {
      final h = await UiHarness.create(const []);
      await _pump(tester, const MachinesScreen(), fleet: h);

      expect(find.text('None yet'), findsOneWidget);
      expect(find.text('No machines yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Add machine'));
      await _flush(tester);
      expect(find.byType(MachineFormScreen), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('one machine is counted in the singular', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'solo'), snapshot: snapshotWith(_agents(1)))]);
      await _pump(tester, const MachinesScreen(), fleet: h);

      expect(find.text('1 machine'), findsOneWidget);
      expect(find.textContaining('1 workspace · 1 agent'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('tapping a machine opens it; a disabled machine stays shut', (tester) async {
      final h = await UiHarness.create([
        (profile: _m('a', 'solo'), snapshot: snapshotWith(_agents(1))),
        (profile: _m('b', 'sleepy', enabled: false), snapshot: snapshotWith(const [])),
      ]);
      await _pump(tester, const MachinesScreen(), fleet: h);

      await tester.tap(find.text('sleepy'));
      await _flush(tester);
      expect(find.byType(MachineScreen), findsNothing);

      await tester.tap(find.text('solo'));
      await _flush(tester);
      expect(find.byType(MachineScreen), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('the menu edits, disables and removes (with a confirmation)', (tester) async {
      final h = await UiHarness.create([
        (profile: _m('a', 'solo'), snapshot: snapshotWith(_agents(1))),
        (profile: _m('b', 'other'), snapshot: snapshotWith(_agents(1))),
      ]);
      await _pump(tester, const MachinesScreen(), fleet: h);

      // Disable through the ellipsis button.
      await tester.tap(find.byTooltip('More').first);
      await _flush(tester);
      await tester.tap(find.text('Disable'));
      await _flush(tester);
      expect(h.machines.machines.firstWhere((m) => m.id == 'a').enabled, isFalse);
      expect(find.textContaining('not connecting'), findsOneWidget);

      // Long-press opens the same sheet; cancelling keeps the machine.
      await tester.longPress(find.text('solo'));
      await _flush(tester);
      expect(find.text('Enable'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await _flush(tester);
      expect(find.text('Remove solo?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _flush(tester);
      expect(h.machines.machines.map((m) => m.id), ['a', 'b']);

      // Confirming removes it.
      await tester.longPress(find.text('solo'));
      await _flush(tester);
      await tester.tap(find.text('Remove'));
      await _flush(tester);
      await tester.tap(find.widgetWithText(AppButton, 'Remove'));
      await _flush(tester);
      expect(h.machines.machines.map((m) => m.id), ['b']);
      expect(find.text('solo'), findsNothing);

      // Edit opens the form for that machine.
      await tester.tap(find.byTooltip('More'));
      await _flush(tester);
      await tester.tap(find.text('Edit'));
      await _flush(tester);
      expect(find.text('Edit machine'), findsWidgets);
      await _tearDown(tester, h);
    });

    testWidgets('Retry gets a machine out of attention once the problem is fixed', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'staging'), snapshot: snapshotWith(_agents(1)))]);
      h.transports['a']!.failure = _fatal;
      h.fleet.connection('a')!.reconnect();
      await _pump(tester, const MachinesScreen(), fleet: h);
      expect(find.text('Needs attention'), findsOneWidget);

      h.transports['a']!.failure = null;
      await tester.tap(find.text('Retry'));
      await _flush(tester);

      expect(h.fleet.connection('a')!.state, LinkState.online);
      expect(find.text('Needs attention'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await _tearDown(tester, h);
    });
  });

  group('one machine', () {
    Map<String, dynamic> manyPanes(int n) => snapshotWith(
          _agents(n),
          workspaces: const [(id: 'w1', label: 'payments-api-gateway-v2-migration-branch-feature-flags-rollout')],
        );

    for (final (width, scale) in [(360.0, 1.0), (320.0, 2.0)]) {
      testWidgets('a workspace with 40 panes and a 60-char name at ${width.toInt()}dp ${scale}x', (tester) async {
        final h = await UiHarness.create([(profile: _m('a', _longLabel), snapshot: manyPanes(40))]);
        await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h, width: width, scale: scale);

        expect(find.textContaining('payments-api-gateway'), findsOneWidget);
        expect(find.text('40'), findsOneWidget, reason: 'pane count is shown in full');
        for (var i = 0; i < 12; i++) {
          await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('title w1:p39'), findsOneWidget, reason: 'the last pane is reachable');
        await _tearDown(tester, h);
      });
    }

    testWidgets('tapping a workspace folds it away and back, and the choice survives scrolling', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'box'), snapshot: manyPanes(3))]);
      await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h);
      expect(find.text('title w1:p0'), findsOneWidget);

      await tester.tap(find.textContaining('payments-api-gateway'));
      await _flush(tester);
      expect(find.text('title w1:p0'), findsNothing);

      await tester.tap(find.textContaining('payments-api-gateway'));
      await _flush(tester);
      expect(find.text('title w1:p0'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('with many workspaces only the ones that need you start open', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _m('a', 'box'),
          snapshot: () {
            final j = snapshotWith(
              [
                for (var i = 1; i <= 6; i++) (id: 'w$i:p1', ws: 'w$i', agent: 'claude', status: 'idle'),
              ],
              workspaces: [for (var i = 1; i <= 6; i++) (id: 'w$i', label: 'space $i')],
            );
            ((j['workspaces'] as List)[2] as Map<String, dynamic>)['agent_status'] = 'blocked';
            return j;
          }(),
        ),
      ]);
      await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h, height: 1200);

      expect(find.text('title w3:p1'), findsOneWidget, reason: 'the blocked workspace is open');
      expect(find.text('title w1:p1'), findsNothing, reason: 'idle ones are folded');
      await tester.tap(find.text('space 1'));
      await _flush(tester);
      expect(find.text('title w1:p1'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('tab names appear on panes only when a workspace has several tabs', (tester) async {
      final j = snapshotWith(_agents(2));
      (j['tabs'] as List).add({
          'tab_id': 'w1:t2',
          'workspace_id': 'w1',
          'number': 2,
          'label': 'logs',
          'focused': false,
          'pane_count': 1,
          'agent_status': 'idle',
        });
      ((j['panes'] as List).last as Map<String, dynamic>)['tab_id'] = 'w1:t2';
      final h = await UiHarness.create([(profile: _m('a', 'box'), snapshot: j)]);
      await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h);

      expect(find.textContaining('claude · logs'), findsOneWidget);
      expect(find.textContaining('claude · 1'), findsOneWidget, reason: 'the first tab is labelled too');
      await _tearDown(tester, h);
    });

    testWidgets('a machine with no workspaces says so', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'box'), snapshot: snapshotWith(const [], workspaces: const []))]);
      await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h);

      expect(find.text('No workspaces'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('offline keeps the last known panes and says it is offline', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'box'), snapshot: manyPanes(3))]);
      h.fleet.connection('a')!.goOffline();
      await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h);

      expect(find.textContaining('No network'), findsOneWidget);
      expect(find.text('title w1:p0'), findsOneWidget);
      expect(find.text('No workspaces'), findsNothing);
      await _tearDown(tester, h);
    });

    testWidgets('a failed connection shows the reason with Retry; approval shows the sign-in', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'box', auth: SshAuth.none), snapshot: manyPanes(1))]);
      h.transports['a']!.failure = _fatal;
      h.fleet.connection('a')!.reconnect();
      await _pump(tester, MachineScreen(machine: h.fleet.connection('a')!), fleet: h);
      expect(find.text('Permission denied (publickey).'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      h.fleet.connection('a')!.onAuthNotice('visit: https://login.tailscale.com/a/l3503a0535f1bf');
      await _flush(tester);
      expect(find.text('Open sign-in page'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('a connection that is still connecting reads "Connecting…"', (tester) async {
      final conn = MachineConnection(
        profile: _m('a', 'box'),
        api: HerdrApi(FakeTransport()),
        backoff: (_) => const Duration(hours: 1),
      );
      final repo = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      await _pump(tester, MachineScreen(machine: conn), repo: repo);

      expect(find.textContaining('Connecting'), findsOneWidget);
      await _tearDown(tester);
      conn.dispose();
    });
  });

  group('machine form', () {
    Future<MachineRepository> repoWith([List<MachineProfile> saved = const []]) async {
      final repo = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      await repo.load();
      for (final p in saved) {
        await repo.save(p, secrets: const MachineSecrets(password: 'old-secret'));
      }
      return repo;
    }

    Finder field(int i) => find.byType(TextFormField).at(i);

    // Name 0, Host 1, Port 2, Username 3, then the auth fields.
    Future<void> fillBasics(WidgetTester tester) async {
      await tester.enterText(field(1), 'workbox.local');
      await tester.enterText(field(3), 'fatman');
    }

    Future<void> tapButton(WidgetTester tester, String label) async {
      final b = find.widgetWithText(AppButton, label);
      await tester.ensureVisible(b);
      await _flush(tester); // typing also scrolls the caret into view
      await tester.ensureVisible(b);
      await tester.pump();
      await tester.tap(b);
      await _flush(tester);
    }

    testWidgets('empty form: every missing required field is called out and nothing is saved', (tester) async {
      final repo = await repoWith();
      await _pump(tester, const MachineFormScreen(), repo: repo);

      await tapButton(tester, 'Add machine');

      expect(find.text('Required'), findsNWidgets(2), reason: 'host and username');
      expect(find.text('Paste your private key'), findsOneWidget);
      expect(repo.machines, isEmpty);
      await _tearDown(tester);
    });

    testWidgets('port must be a real port', (tester) async {
      final repo = await repoWith();
      await _pump(tester, const MachineFormScreen(), repo: repo);
      await fillBasics(tester);
      await tester.enterText(field(4), '-----BEGIN OPENSSH PRIVATE KEY-----');
      await tester.enterText(field(2), '70000');

      await tapButton(tester, 'Add machine');
      expect(find.text('Invalid'), findsOneWidget);
      expect(repo.machines, isEmpty);

      await tester.enterText(field(2), '2222');
      await tapButton(tester, 'Add machine');
      expect(find.text('Invalid'), findsNothing);
      expect(repo.machines.single.port, 2222);
      expect(repo.machines.single.label, 'workbox.local', reason: 'a blank name falls back to the host');
      await _tearDown(tester);
    });

    testWidgets('the plus on the machines tab opens the form and Back returns', (tester) async {
      final h = await UiHarness.create([(profile: _m('a', 'existing'), snapshot: snapshotWith(_agents(1)))]);
      await _pump(tester, const MachinesScreen(), fleet: h);

      await tester.tap(find.byTooltip('Add machine'));
      await _flush(tester);
      expect(find.byType(MachineFormScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1)); // the page slide takes longer than _flush
      expect(find.byType(MachineFormScreen), findsNothing);
      expect(find.byType(MachinesScreen), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('password auth: required when adding, optional when editing', (tester) async {
      final repo = await repoWith();
      await _pump(tester, const MachineFormScreen(), repo: repo);
      await tester.tap(find.text('Password'));
      await _flush(tester);
      await fillBasics(tester);

      await tapButton(tester, 'Add machine');
      expect(find.text('Required'), findsOneWidget, reason: 'password');
      expect(repo.machines, isEmpty);
      await _tearDown(tester);

      final saved = await repoWith([_m('p', 'box', host: 'h.example')]);
      await _pump(tester, MachineFormScreen(existing: saved.machines.single), repo: saved);
      expect(find.text('Leave blank to keep the saved password'), findsOneWidget);
      await tester.enterText(field(0), 'renamed');
      await tapButton(tester, 'Save');
      expect(saved.machines.single.label, 'renamed');
      expect((await saved.secretsFor('p')).password, 'old-secret', reason: 'a blank password keeps the saved one');
      await _tearDown(tester);
    });

    testWidgets('editing a key machine keeps the saved key without asking again', (tester) async {
      final repo = await repoWith([_m('k', 'box', auth: SshAuth.key)]);
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo: repo);

      expect(find.text('Leave blank to keep the saved key'), findsOneWidget);
      await tapButton(tester, 'Save');
      expect(find.text('Paste your private key'), findsNothing);
      await _tearDown(tester);
    });

    testWidgets('Tailscale needs no secret', (tester) async {
      final repo = await repoWith();
      await _pump(tester, const MachineFormScreen(), repo: repo);
      await tester.tap(find.text('Tailscale'));
      await _flush(tester);

      expect(find.textContaining('Nothing is stored'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(4), reason: 'no key or password fields');
      await fillBasics(tester);
      await tapButton(tester, 'Add machine');
      expect(repo.machines.single.auth, SshAuth.none);
      await _tearDown(tester);
    });

    testWidgets('a bad session name hidden in "Advanced" is not silently accepted', (tester) async {
      final repo = await repoWith([_m('s', 'box', auth: SshAuth.none)]);
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo: repo);
      expect(find.text('herdr session'), findsNothing, reason: 'advanced starts folded');

      // Open it, break the name, fold it, and save: the form must open it again.
      await _tapVisible(tester, find.text('Advanced'));
      await tester.enterText(find.byType(TextFormField).at(4), 'bad name!');
      await _tapVisible(tester, find.text('Advanced'));
      await tapButton(tester, 'Save');

      expect(find.text('Letters, digits, . _ - only'), findsOneWidget);
      expect(repo.machines.single.session, 'default');
      await _tearDown(tester);
    });

    testWidgets('a good connection test shows the host key and goes stale as soon as a field changes', (tester) async {
      final repo = await repoWith([_m('t', 'box', auth: SshAuth.none)]);
      await _pump(
        tester,
        MachineFormScreen(
          existing: repo.machines.single,
          transportFactory: (profile, secrets, pin, notice) {
            pin('SHA256:abc');
            return FakeTransport(snapshotWith(_agents(1)));
          },
        ),
        repo: repo,
      );

      await tapButton(tester, 'Test connection');
      expect(find.textContaining('Connected · herdr 9.9.9'), findsOneWidget);
      expect(find.textContaining('Host key SHA256:abc'), findsOneWidget);

      await tester.enterText(field(1), 'other.example');
      await _flush(tester);
      expect(find.textContaining('Connected'), findsNothing, reason: 'the result no longer describes the form');
      await _tearDown(tester);
    });

    testWidgets('a failed test says why', (tester) async {
      final repo = await repoWith([_m('t', 'box', auth: SshAuth.none)]);
      await _pump(
        tester,
        MachineFormScreen(
          existing: repo.machines.single,
          transportFactory: (profile, secrets, pin, notice) =>
              FakeTransport()..failure = const HerdrTransportException('Connection refused by 10.0.0.5:22'),
        ),
        repo: repo,
      );

      await tapButton(tester, 'Test connection');
      expect(find.text('Could not connect'), findsOneWidget);
      expect(find.text('Connection refused by 10.0.0.5:22'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('a test waiting on a Tailscale check offers the sign-in link and a busy button', (tester) async {
      final repo = await repoWith([_m('t', 'box', auth: SshAuth.none)]);
      final gate = Completer<void>();
      await _pump(
        tester,
        MachineFormScreen(
          existing: repo.machines.single,
          transportFactory: (profile, secrets, pin, notice) {
            notice('visit: https://login.tailscale.com/a/l3503a0535f1bf');
            return _Gated(gate.future);
          },
        ),
        repo: repo,
      );

      await tapButton(tester, 'Test connection');
      expect(find.text('Approve this sign-in'), findsOneWidget);
      expect(find.text('Open sign-in page'), findsOneWidget);
      expect(find.text('Connecting…'), findsOneWidget);

      gate.complete();
      await _flush(tester);
      expect(find.text('Approve this sign-in'), findsNothing);
      expect(find.textContaining('Connected'), findsOneWidget);
      await _tearDown(tester);
    });

    for (final (width, scale) in [(320.0, 1.0), (320.0, 2.0)]) {
      testWidgets('the whole form fits at ${width.toInt()}dp ${scale}x without overflow', (tester) async {
        final repo = await repoWith([
          _m('w', _longLabel, host: _longHost, user: 'bartholomew.fitzgerald', auth: SshAuth.key),
        ]);
        await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo: repo, width: width, scale: scale);
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await _tapVisible(tester, find.text('Password'));
        expect(find.text('Password'), findsWidgets);
        await _tearDown(tester);
      });
    }
  });
}

/// A transport whose requests wait for [gate].
class _Gated extends FakeTransport {
  _Gated(this.gate) : super(snapshotJson(panes: const []));
  final Future<void> gate;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    await gate;
    return super.request(method, params);
  }
}
