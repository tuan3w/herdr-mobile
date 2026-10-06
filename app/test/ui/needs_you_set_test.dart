// One "needs you": the badge, the pill, the board's sections, the triage
// sheet, the Machines tab and the notifier's count are the same set, in the
// same order, terminal agents and agent sessions alike; what is out of reach
// is not counted; a handover does not make old waits new.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/attention_notifier.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_session_rows.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_host.dart';
import '../support/fake_notifier.dart';
import 'board_support.dart';
import 'ui_harness.dart';

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

String _title(String paneId) => 'terminal ${paneId.split('p').last}';

MachineProfile _profile(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

Finder _section(String label) => find.byWidgetPredicate((w) => w is SectionLabel && w.label == label);

void main() {
  testWidgets(
      'a blocked pane, a blocked session, a blocked pane offline and a done session: every surface says 2, '
      'and the triage walks the board\'s order', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await BoardHarness.create([
      (profile: _profile('a', 'studio-mac'), snapshot: snapshotWith([_pane(1, 'working')], title: _title)),
      (profile: _profile('b', 'old-box'), snapshot: snapshotWith([_pane(2, 'blocked')], title: _title)),
    ]);
    final hosts = <String, FakeAgentHost>{'a': FakeAgentHost(), 'b': FakeAgentHost()};
    final waits = hosts['a']!.add(id: 'k1', title: 'Deploy');
    hosts['a']!.add(id: 'k2', title: 'Write docs');
    final repo = AgentSessionRepository(fleet: h.fleet, hostFor: (c) => hosts[c.profile.id]!);
    final attention = AttentionSet(fleet: h.fleet, sessions: repo);
    final settings = NotificationSettings(MemoryNotificationStore(const NotificationChoice(enabled: true)));
    await settings.load();
    final notifier = FakeNotifier();
    final notices = AttentionNotifier(
      fleet: h.fleet,
      sessions: repo,
      attention: attention,
      settings: settings,
      notifier: notifier,
      // Its "at most once per 2 s" runs on the test's clock.
      clock: () => tester.binding.clock.now(),
    );

    tester.view
      ..physicalSize = const Size(360, 2400) * 2
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ...h.providers,
          ListenableProvider<AgentSessions>.value(value: repo),
          ChangeNotifierProvider<AttentionSet>.value(value: attention),
          Provider<Notifier>.value(value: notifier),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: const HomeShell()),
      ),
    );
    await _settle(tester);

    // The pane has waited five minutes; the session starts waiting now; the
    // other session finishes; machine b drops out of reach.
    await h.changeStatuses(tester, 'a', [_pane(1, 'blocked')], ago: const Duration(minutes: 5), title: _title);
    waits.askPermission(command: 'npm run deploy');
    unawaited(repo.byKey('a/k2')!.send('write the docs'));
    await _settle(tester);
    h.fleet.connection('b')!.goOffline();
    await _settle(tester, 30);

    // The badge.
    expect(
      tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Agents'))).label,
      'Agents, 2 need you',
      reason: 'the pane and the session; not the offline pane, not the finished session',
    );
    // The pill.
    expect(find.text('2 need you · 1 to review'), findsOneWidget);
    // The section and its chip.
    expect(tester.widget<SectionLabel>(_section('Needs you')).count, 2);
    expect(find.text('1 offline'), findsOneWidget, reason: 'the offline pane is listed, last known, and said so');
    expect(tester.widget<SectionLabel>(_section('Done')).count, 1);
    // The notifier's "need you".
    expect(notifier.glances.last.blocked, 2);
    // The board's order: longest waiting first, panes and sessions mixed.
    final paneTop = _top(tester, find.text('terminal 1'));
    final sessionTop = _top(tester, find.widgetWithText(AgentSessionRow, 'Deploy'));
    final offlineTop = _top(tester, find.text('terminal 2'));
    expect(paneTop, lessThan(sessionTop));
    expect(sessionTop, lessThan(offlineTop), reason: 'what cannot be answered comes last');

    // The triage sheet walks the same two, in the same order, sessions too.
    await tester.tap(find.text('2 need you · 1 to review'));
    await _settle(tester);
    expect(find.byType(ReplySheet), findsOneWidget);
    expect(find.text('1 of 2 need you'), findsOneWidget);
    expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('terminal 1')), findsOneWidget);
    await tester.tap(find.byTooltip('Next agent'));
    await _settle(tester);
    expect(find.text('2 of 2 need you'), findsOneWidget);
    expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('Deploy')), findsOneWidget);
    expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('npm run deploy')), findsOneWidget,
        reason: 'what the session asks, as the board says it');
    expect(find.text('All clear'), findsNothing, reason: 'a session still waits');
    Navigator.of(tester.element(find.byType(ReplySheet))).pop();
    await _settle(tester);

    // The Machines tab.
    await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
    await _settle(tester);
    expect(find.bySemanticsLabel(RegExp(r'^studio-mac, .*, 2 need you$')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^old-box, .*need you')), findsNothing,
        reason: 'its last-known wait cannot be answered; the row says offline');

    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    await notices.dispose();
    attention.dispose();
    repo.dispose();
    settings.dispose();
    h.dispose();
  });

  testWidgets('a handover empties the set and fills it with the same keys: they stay known as waiting',
      (tester) async {
    final h = await BoardHarness.create([
      (profile: _profile('a', 'studio-mac'), snapshot: snapshotWith([_pane(1, 'blocked')], title: _title)),
    ]);
    final attention = AttentionSet(fleet: h.fleet);
    final keys = attention.needsYouKeys;
    expect(keys, {'a/w1:p1'});

    h.fleet.connection('a')!.goOffline();
    await tester.pump(const Duration(milliseconds: 100));
    expect(attention.needsYou, isEmpty, reason: 'nothing can be answered while the link is down');
    expect(attention.waitingKeys, {'a/w1:p1'}, reason: 'the cue still knows it was waiting');

    h.fleet.connection('a')!.reconnect();
    await _settle(tester);
    expect(attention.needsYouKeys, keys, reason: 'the same wait, back in reach: no arrival');

    attention.dispose();
    h.dispose();
  });
}
