// A board card reads its pane (a 24-row read every few seconds while the agent
// works) only while the person can see it: a board hidden behind another tab,
// or covered by a screen, reads nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

const _tall = 2400.0;

const _menu = PromptInfo(
  question: 'Do you want to proceed?\nBash command: npm test',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter']),
    QuickReply(label: '3. No', keys: ['3', 'enter']),
  ],
);

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(List<Pane> panes) => (
      profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith(panes, title: (id) => 'task ${id.split('p').last}'),
    );

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

void main() {
  setUpAll(loadAppFonts);

  testWidgets('cards on a board hidden behind another tab release their reads, and take them back when it shows',
      (tester) async {
    final h = await BoardHarness.create([_machine([_pane(1, 'working'), _pane(2, 'blocked')])]);
    h.previews.set('a/w1:p2', ['…context…'], prompt: _menu);
    await pumpBoard(tester, h, height: _tall);
    expect(find.byType(AgentCard), findsNWidgets(2));
    expect(h.previews.openCount, 2);

    await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
    await settle(tester);
    expect(h.previews.openCount, 0, reason: 'the board is not in front: nothing is read for it');

    await tester.tap(find.byKey(FloatingTabBar.tabKey('Agents')));
    await settle(tester);
    expect(h.previews.openCount, 2, reason: 'back in front: the cards read again');
    expect(find.text('1. Yes'), findsOneWidget, reason: 'and the question is there to answer');

    await teardownBoard(tester, h);
    expect(h.previews.openCount, 0);
  });

  testWidgets('a card built while the board is hidden holds nothing until it shows', (tester) async {
    final h = await BoardHarness.create([_machine([_pane(1, 'working')])]);
    await pumpBoard(tester, h, height: _tall);
    await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
    await settle(tester);
    expect(h.previews.openCount, 0);

    // A new working agent appears while the board is hidden.
    await h.changeStatuses(tester, 'a', [_pane(1, 'working'), _pane(2, 'working')],
        title: (id) => 'task ${id.split('p').last}');
    expect(h.previews.openCount, 0);
    expect(h.previews.opened.length, 1, reason: 'never taken then dropped: only the first card ever watched');

    await tester.tap(find.byKey(FloatingTabBar.tabKey('Agents')));
    await settle(tester);
    expect(h.previews.openCount, 2);
    await teardownBoard(tester, h);
  });
}
