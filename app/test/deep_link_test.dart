import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart' show LinkState;
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/repositories/attention_notifier.dart' show agentsBoardLink;
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/deep_link.dart';
import 'package:herdr_mobile/ui/core/home_tabs.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agents/agents_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import 'support/fake_agent_session.dart';
import 'ui/ui_harness.dart';

const _mini = MachineProfile(
  id: 'm-mini',
  label: 'Mac mini',
  host: 'mini.example.com',
  username: 'me',
);
const _vps = MachineProfile(
  id: 'm-vps',
  label: 'Hetzner VPS',
  host: 'vps.example.com',
  username: 'me',
);

/// Sessions the host only reports once asked (the app was just started).
class _LateSessions extends FakeAgentSessions {
  _LateSessions() : super([]);

  int refreshes = 0;

  @override
  Future<void> refresh() async {
    refreshes++;
    sessions.add(FakeAgentSession(key: 'm-mini/k9'));
  }
}

void main() {
  group('parseAgentLink', () {
    test('decodes machine and pane id', () {
      expect(
        parseAgentLink('herdr://agent/Mac%20mini/wD%3Ap1'),
        const AgentLink('Mac mini', 'wD:p1'),
      );
    });

    test('reads what the host plugin sends (same literals as its test.sh)', () {
      expect(
        parseAgentLink('herdr://agent/Test%20Box/wD%3Ap1'),
        const AgentLink('Test Box', 'wD:p1'),
      );
      expect(
        parseAgentLink('herdr://agent/Mac%2Fmini%20%C3%A9/wD%3Ap1'),
        const AgentLink('Mac/mini é', 'wD:p1'),
      );
      expect(
        parseAgentLink('herdr://agent/%24%28touch%20%2Ftmp%2Fx%29/wD%3Ap1'),
        const AgentLink(r'$(touch /tmp/x)', 'wD:p1'),
      );
    });

    test('an escaped slash stays inside its part; an unescaped colon is fine', () {
      expect(parseAgentLink('herdr://agent/a%2Fb/w1:p2'), const AgentLink('a/b', 'w1:p2'));
    });

    test('keeps non-ASCII names whole', () {
      expect(
        parseAgentLink('herdr://agent/M%C3%A1y%20Vi%E1%BB%87t/w1%3Ap1'),
        const AgentLink('Máy Việt', 'w1:p1'),
      );
    });

    test('scheme and host ignore case; machine and pane keep theirs', () {
      expect(parseAgentLink('HERDR://Agent/Box/Wd%3AP1'), const AgentLink('Box', 'Wd:P1'));
    });

    test('ignores a query, a fragment and one trailing slash', () {
      const want = AgentLink('box', 'w1:p1');
      expect(parseAgentLink('herdr://agent/box/w1%3Ap1?utm=x'), want);
      expect(parseAgentLink('herdr://agent/box/w1%3Ap1#frag'), want);
      expect(parseAgentLink('herdr://agent/box/w1%3Ap1/'), want);
    });

    test('rejects anything that is not exactly an agent link', () {
      for (final bad in <String?>[
        null,
        '',
        '/',
        '  ',
        'herdr://agent',
        'herdr://agent/',
        'herdr://agent/onlyone',
        'herdr://agent/box/w1/extra',
        'herdr://agent/box/w1//',
        'herdr://agent//w1',
        'herdr://agent/box/',
        'herdr://agent/%20/w1',
        'herdr://agent/box/%20',
        'herdr://pane/box/w1',
        'herdr://box/w1',
        'https://agent/box/w1',
        'agent/box/w1',
        '/agent/box/w1',
        'herdr://agent:80/box/w1',
        'herdr://me@agent/box/w1',
        'herdr://agent/%FF/w1', // not UTF-8
        'herdr://agent/%zz/w1', // not an escape
        'herdr://agent/box/w1%',
      ]) {
        expect(parseAgentLink(bad), isNull, reason: '$bad');
      }
    });
  });

  group('parseSessionLink', () {
    test('decodes machine and keeper id', () {
      expect(
        parseSessionLink('herdr://session/Mac%20mini/k%2F1'),
        const SessionLink('Mac mini', 'k/1'),
      );
      expect(parseSessionLink('HERDR://Session/box/abc/'), const SessionLink('box', 'abc'));
    });

    test('is not an agent link, and an agent link is not a session link', () {
      expect(parseAgentLink('herdr://session/box/k1'), isNull);
      expect(parseSessionLink('herdr://agent/box/w1%3Ap1'), isNull);
    });

    test('rejects anything that is not exactly a session link', () {
      for (final bad in <String?>[
        null,
        '',
        'herdr://session',
        'herdr://session/box',
        'herdr://session/box/k1/extra',
        'herdr://session//k1',
        'herdr://session/box/%20',
        'herdr://session/box/%ZZ',
        'https://session/box/k1',
        'herdr://user@session/box/k1',
      ]) {
        expect(parseSessionLink(bad), isNull, reason: '$bad');
      }
    });
  });

  group('isBoardLink', () {
    test('is herdr://agents and nothing that merely starts with it', () {
      expect(isBoardLink('herdr://agents'), isTrue);
      expect(isBoardLink('HERDR://Agents/'), isTrue);
      expect(isBoardLink('herdr://agents/x'), isFalse);
      expect(isBoardLink('herdr://agent/box/w1'), isFalse);
      expect(isBoardLink(null), isFalse);
    });
  });

  group('matchMachine', () {
    const byHost = MachineProfile(id: 'x1', label: 'Other', host: 'Mac mini', username: 'u');
    const byId = MachineProfile(id: 'Mac mini', label: 'Third', host: 'third.example.com', username: 'u');

    test('label first, in any case and with stray spaces', () {
      expect(matchMachine([_vps, _mini], '  mac MINI '), _mini);
    });

    test('a label beats a host and an id that spell the same', () {
      expect(matchMachine([byId, byHost, _mini], 'Mac mini'), _mini);
    });

    test('host when no label fits, in any case', () {
      expect(matchMachine([_vps, _mini], 'MINI.example.com'), _mini);
      expect(matchMachine([byId, byHost], 'mac mini'), byHost);
    });

    test('id last, exactly', () {
      expect(matchMachine([_vps, byId], 'Mac mini'), byId);
      expect(matchMachine([_vps, _mini], 'm-vps'), _vps);
      expect(matchMachine([_vps, _mini], 'M-VPS'), isNull);
    });

    test('the first saved wins when two share a label', () {
      const twin = MachineProfile(id: 'twin', label: 'mac mini', host: 'other.example.com', username: 'u');
      expect(matchMachine([twin, _mini], 'Mac mini'), twin);
    });

    test('unknown and blank names match nothing', () {
      expect(matchMachine([_vps, _mini], 'nope'), isNull);
      expect(matchMachine([_vps, _mini], '  '), isNull);
      expect(matchMachine(const [], 'Mac mini'), isNull);
    });
  });

  group('following a link', () {
    late UiHarness h;
    late DeepLinks links;
    late List<AgentRef> opened;

    Future<void> pumpApp(
      WidgetTester tester, {
      List<({MachineProfile profile, Map<String, dynamic> snapshot})>? machines,
      Duration patience = const Duration(seconds: 2),
      FakeAgentSessions? sessions,
    }) async {
      h = await UiHarness.create(machines ??
          [
            (
              profile: _mini,
              snapshot: snapshotWith([
                (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
                (id: 'w1:p2', ws: 'w1', agent: 'codex', status: 'working'),
              ]),
            ),
            (
              profile: _vps,
              snapshot: snapshotWith([(id: 'w1:p9', ws: 'w1', agent: 'omp', status: 'done')]),
            ),
          ]);
      opened = [];
      links = DeepLinks(
        machines: h.machines,
        fleet: h.fleet,
        patience: patience,
        open: (context, agent) async => opened.add(agent),
        sessions: sessions,
      );
      // The app registers it in initState, before the MaterialApp builds.
      links.attach();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        navigatorKey: links.navigatorKey,
        home: const Scaffold(body: Center(child: Text('board'))),
      ));
      await settle(tester);
    }

    Future<void> tearDownApp(WidgetTester tester) async {
      links.dispose();
      await teardownUi(tester, h);
    }

    /// The link to the machine breaks and the retry is far off (the harness
    /// backs off for an hour): reconnecting, with the last snapshot kept.
    Future<void> loseMachine(WidgetTester tester) async {
      h.transports['m-mini']!.failure = const HerdrTransportException('network down');
      h.fleet.connection('m-mini')!.reconnect();
      await settle(tester);
      expect(h.fleet.connection('m-mini')!.state, LinkState.reconnecting);
      expect(h.fleet.connection('m-mini')!.paneById('w1:p1'), isNotNull);
    }

    /// What Android does for a link while the app runs: route information on
    /// the navigation channel.
    Future<void> pushLink(WidgetTester tester, String location) async {
      final message = const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', {'location': location}),
      );
      await tester.binding.defaultBinaryMessenger
          .handlePlatformMessage('flutter/navigation', message, (_) {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    void showSecondScreen() {
      links.navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('second screen')),
      ));
    }

    testWidgets('a link while running opens that pane of that machine', (tester) async {
      await pumpApp(tester);
      await pushLink(tester, 'herdr://agent/mac%20MINI/w1%3Ap2');
      expect(opened, [const PaneAgent('m-mini', 'w1:p2')]);
      expect(tester.takeException(), isNull, reason: 'the navigator must not get the link');
      expect(find.byKey(toastKey), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('finds the machine by host, then by id', (tester) async {
      await pumpApp(tester);
      await pushLink(tester, 'herdr://agent/vps.example.com/w1%3Ap9');
      await pushLink(tester, 'herdr://agent/m-mini/w1%3Ap1');
      expect(opened, [const PaneAgent('m-vps', 'w1:p9'), const PaneAgent('m-mini', 'w1:p1')]);
      await tearDownApp(tester);
    });

    testWidgets('a link that started the app opens its pane once the first screen is up',
        (tester) async {
      tester.platformDispatcher.defaultRouteNameTestValue = 'herdr://agent/Mac%20mini/w1%3Ap1';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      await pumpApp(tester);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(opened, [const PaneAgent('m-mini', 'w1:p1')]);
      expect(find.text('board'), findsOneWidget, reason: 'the app still starts on its home');
      expect(tester.takeException(), isNull);
      await tearDownApp(tester);
    });

    testWidgets('a plain launch opens nothing', (tester) async {
      await pumpApp(tester);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(opened, isEmpty);
      expect(find.byKey(toastKey), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('a route that is not a herdr link is swallowed, not pushed', (tester) async {
      await pumpApp(tester);
      await pushLink(tester, '/settings');
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
      expect(find.text('board'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a failed link leaves the screen in front and its toast offers the way back',
        (tester) async {
      await pumpApp(tester);
      showSecondScreen();
      await tester.pumpAndSettle();
      expect(find.text('second screen'), findsOneWidget);

      await pushLink(tester, 'herdr://agent/nope/w1%3Ap1');
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.text('second screen'), findsOneWidget, reason: 'a failed link closes nothing');

      await tester.tap(find.byKey(toastActionKey));
      await tester.pumpAndSettle();
      expect(find.text('second screen'), findsNothing);
      expect(find.text('board'), findsOneWidget);
      await tearDownApp(tester);
    });

    testWidgets('a failed link on the screen its toast would open offers no button', (tester) async {
      await pumpApp(tester);
      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap404');
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.byKey(toastActionKey), findsNothing, reason: 'the board is already in front');
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('a pane the live machine does not have shows a toast', (tester) async {
      await pumpApp(tester);
      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap404');
      expect(opened, isEmpty);
      expect(find.text('That agent is no longer on Mac mini.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('a malformed herdr link shows a toast', (tester) async {
      await pumpApp(tester);
      await pushLink(tester, 'herdr://agent/onlyone');
      expect(opened, isEmpty);
      expect(find.text("That link isn't one herdr can open."), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('a switched-off machine shows a toast', (tester) async {
      const off = MachineProfile(
        id: 'm-off',
        label: 'Old laptop',
        host: 'old.example.com',
        username: 'me',
        enabled: false,
      );
      await pumpApp(tester, machines: [(profile: off, snapshot: snapshotWith(const []))]);
      await pushLink(tester, 'herdr://agent/Old%20laptop/w1%3Ap1');
      expect(opened, isEmpty);
      expect(find.text('Old laptop is switched off.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('a machine that is down still opens a pane its cached snapshot has',
        (tester) async {
      await pumpApp(tester);
      await loseMachine(tester);
      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap1');
      expect(opened, [const PaneAgent('m-mini', 'w1:p1')]);
      await tearDownApp(tester);
    });

    testWidgets('a machine that never answers is reported after the patience runs out',
        (tester) async {
      await pumpApp(tester);
      await loseMachine(tester);

      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap77');
      expect(find.byKey(toastKey), findsNothing, reason: 'still waiting for an answer');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(toastKey), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(opened, isEmpty);
      expect(find.text("Couldn't reach Mac mini to open that agent."), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('waits for a reconnecting machine and opens the pane once it is there',
        (tester) async {
      await pumpApp(tester, patience: const Duration(seconds: 30));
      final t = h.transports['m-mini']!;
      await loseMachine(tester);

      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap5');
      expect(opened, isEmpty);
      expect(find.byKey(toastKey), findsNothing);

      t.snapshot = snapshotWith([
        (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
        (id: 'w1:p5', ws: 'w1', agent: 'claude', status: 'blocked'),
      ]);
      t.failure = null;
      h.fleet.connection('m-mini')!.reconnect();
      await settle(tester);
      expect(opened, [const PaneAgent('m-mini', 'w1:p5')]);
      expect(find.byKey(toastKey), findsNothing);
      await tearDownApp(tester);
    });

    testWidgets('a newer link replaces one still waiting', (tester) async {
      await pumpApp(tester, patience: const Duration(seconds: 2));
      await loseMachine(tester);

      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap77'); // waits
      await pushLink(tester, 'herdr://agent/Mac%20mini/w1%3Ap2'); // cached: opens now
      expect(opened, [const PaneAgent('m-mini', 'w1:p2')]);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(toastKey), findsNothing, reason: 'the stale link stays quiet');
      expect(opened, [const PaneAgent('m-mini', 'w1:p2')]);
      await tearDownApp(tester);
    });

    testWidgets('a session link opens the chat of that session', (tester) async {
      final sessions = FakeAgentSessions([FakeAgentSession(key: 'm-mini/k1')]);
      await pumpApp(tester, sessions: sessions);
      await pushLink(tester, 'herdr://session/Mac%20mini/k1');
      await pushLink(tester, 'herdr://session/m-mini/k1');
      expect(opened, [const SessionAgent('m-mini/k1'), const SessionAgent('m-mini/k1')]);
      await tearDownApp(tester);
    });

    testWidgets('an unknown session is "no longer on" the machine, like an unknown pane',
        (tester) async {
      await pumpApp(tester, sessions: FakeAgentSessions([FakeAgentSession(key: 'm-mini/k1')]));
      await pushLink(tester, 'herdr://session/Mac%20mini/gone');
      expect(opened, isEmpty);
      expect(find.text('That agent is no longer on Mac mini.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('a session the phone has not listed yet is looked for on the host first',
        (tester) async {
      final sessions = _LateSessions();
      await pumpApp(tester, sessions: sessions);
      await pushLink(tester, 'herdr://session/Mac%20mini/k9');
      expect(sessions.refreshes, 1);
      expect(opened, [const SessionAgent('m-mini/k9')]);
      await tearDownApp(tester);
    });

    testWidgets('a session link for an unknown machine says so', (tester) async {
      await pumpApp(tester, sessions: FakeAgentSessions([FakeAgentSession(key: 'm-mini/k1')]));
      await pushLink(tester, 'herdr://session/nope/k1');
      expect(opened, isEmpty);
      expect(find.text('No machine named "nope" on this phone.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('without sessions to open, a session link is not one this app can open',
        (tester) async {
      await pumpApp(tester);
      await pushLink(tester, 'herdr://session/Mac%20mini/k1');
      expect(find.text("That link isn't one herdr can open."), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tearDownApp(tester);
    });

    testWidgets('the board link brings the board to the front, quietly', (tester) async {
      await pumpApp(tester);
      showSecondScreen();
      await tester.pumpAndSettle();
      await pushLink(tester, agentsBoardLink);
      await tester.pumpAndSettle();
      expect(find.text('second screen'), findsNothing);
      expect(find.text('board'), findsOneWidget);
      expect(find.byKey(toastKey), findsNothing);
      expect(opened, isEmpty);
      await tearDownApp(tester);
    });

    testWidgets('following a link by hand (a notification tap) is the same as Android handing it over',
        (tester) async {
      await pumpApp(tester);
      await links.follow('herdr://agent/Mac%20mini/w1%3Ap1');
      await links.follow('/settings');
      expect(opened, [const PaneAgent('m-mini', 'w1:p1')]);
      await tearDownApp(tester);
    });
  });

  group('on the home screen', () {
    late UiHarness h;
    late DeepLinks links;
    late HomeTabs tabs;

    /// The real shell, on [tab], with the links wired as the app wires them.
    Future<void> pumpShell(WidgetTester tester, HomeTab tab) async {
      h = await UiHarness.create([
        (profile: _mini, snapshot: snapshotWith([(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked')])),
      ]);
      tabs = HomeTabs();
      links = DeepLinks(machines: h.machines, fleet: h.fleet, tabs: tabs, open: (context, agent) async {});
      links.attach();
      tester.view
        ..physicalSize = const Size(360, 740) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.machines),
          ChangeNotifierProvider.value(value: h.fleet),
          ChangeNotifierProvider(create: (_) => AttentionSet(fleet: h.fleet)),
          ChangeNotifierProvider.value(value: h.terminalSettings),
          ChangeNotifierProvider.value(value: h.appSettings),
          ChangeNotifierProvider.value(value: h.agentScreens),
          Provider<PanePreviews>.value(value: h.previews),
          Provider<TransportFactory>.value(
            value: (profile, secrets, onPin, onNotice) => UiTransport(snapshotWith(const [])),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          navigatorKey: links.navigatorKey,
          home: HomeShell(initialTab: tab.index, tabs: tabs),
        ),
      ));
      await settle(tester);
    }

    Future<void> tearDownShell(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 6)); // the last toast goes
      links.dispose();
      await teardownUi(tester, h);
    }

    Future<void> tapButton(WidgetTester tester, String label) async {
      await tester.tap(find.widgetWithText(AppButton, label));
      await settle(tester);
    }

    testWidgets('the summary notification on the Machines tab lands on the Agents board', (tester) async {
      await pumpShell(tester, HomeTab.machines);
      expect(find.byType(MachinesScreen), findsOneWidget);

      await links.follow(agentsBoardLink);
      await settle(tester);
      expect(find.byType(MachinesScreen), findsNothing);
      expect(find.byType(AgentsScreen), findsOneWidget);
      expect(tabs.current, HomeTab.agents);
      await tearDownShell(tester);
    });

    testWidgets('a link never discards a machine form with unsaved input', (tester) async {
      await pumpShell(tester, HomeTab.machines);
      await tester.tap(find.byTooltip('Add machine'));
      await settle(tester);
      await tester.enterText(find.byType(TextFormField).at(1), 'box.local');
      await settle(tester);

      // A failed link says so over the form and closes nothing.
      await links.follow('herdr://agent/nope/w1%3Ap1');
      await settle(tester);
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.byType(MachineFormScreen), findsOneWidget);
      expect(find.text('box.local'), findsOneWidget);

      // Its button goes back the way Back does: the form asks first.
      await tester.tap(find.byKey(toastActionKey));
      await settle(tester);
      await tapButton(tester, 'Cancel');
      expect(find.byType(MachineFormScreen), findsOneWidget);
      expect(find.text('box.local'), findsOneWidget, reason: 'nothing entered was lost');

      // The summary notification asks the same, and lands on the board after Discard.
      await links.follow(agentsBoardLink);
      await settle(tester);
      expect(find.byType(MachineFormScreen), findsOneWidget);
      await tapButton(tester, 'Discard');
      expect(find.byType(MachineFormScreen), findsNothing);
      expect(find.byType(AgentsScreen), findsOneWidget);
      await tearDownShell(tester);
    });
  });

  test('the link format the docs and the host plugin use is one the parser reads', () {
    expect(agentLinkFormat, 'herdr://agent/<machine>/<pane-id>');
    expect(
      parseAgentLink(agentLinkFormat.replaceAll('<machine>', 'box').replaceAll('<pane-id>', 'w1')),
      const AgentLink('box', 'w1'),
    );
  });
}
