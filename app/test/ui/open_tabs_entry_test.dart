// The board's way back to tabs left open (also across launches).
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/open_tabs.dart';
import 'package:herdr_mobile/ui/features/pane/pane_host_screen.dart';
import 'package:herdr_mobile/ui/features/pane/tab_info.dart';
import 'package:herdr_mobile/ui/features/pane/tab_strip.dart';

import 'ui_harness.dart';

MachineProfile _machine() =>
    const MachineProfile(id: 'a', label: 'workstation', host: 'a.example', username: 'dev');

Pane _pane(int i) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: 'working');

Future<UiHarness> _harness() => UiHarness.create([
      (
        profile: _machine(),
        snapshot: snapshotWith([_pane(1), _pane(2), _pane(3)]),
      ),
    ]);

void main() {
  group('the tab button on the board', () {
    testWidgets('is absent without tabs and shows the count with them', (tester) async {
      final h = await _harness();
      await pumpUi(tester, h);
      expect(find.byType(TabCountButton), findsNothing);

      h.openTabs.open('a', 'w1:p1');
      h.openTabs.open('a', 'w1:p2');
      await tester.pump();
      expect(find.byType(TabCountButton), findsOneWidget);
      expect(find.descendant(of: find.byType(TabCountButton), matching: find.text('2')), findsOneWidget);

      h.openTabs.closeAll();
      await tester.pump();
      expect(find.byType(TabCountButton), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('opens the tab screen as it was left, without touching the tabs', (tester) async {
      final h = await _harness();
      h.openTabs
        ..open('a', 'w1:p1')
        ..open('a', 'w1:p2')
        ..open('a', 'w1:p3')
        ..activate(const TabRef('a', 'w1:p2').key);
      await pumpUi(tester, h);

      await tester.tap(find.byType(TabCountButton));
      await settle(tester);
      expect(find.byType(PaneHostScreen), findsOneWidget);
      expect([for (final t in h.openTabs.tabs) t.paneId], ['w1:p1', 'w1:p2', 'w1:p3']);
      expect(h.openTabs.active, const TabRef('a', 'w1:p2'));
      await teardownUi(tester, h);
    });
  });

  group('an offline tab', () {
    TabInfo info({required bool live, AgentStatus? status = AgentStatus.idle}) => TabInfo(
          ref: const TabRef('m', 'p'),
          title: 't',
          agent: null,
          machineLabel: 'box',
          status: status,
          live: live,
          gone: status == null,
          since: DateTime(2026),
        );

    test('says offline, not the state it had when last seen', () {
      expect(info(live: false).stateText(DateTime(2026, 1, 1, 1)), 'offline');
      expect(info(live: false, status: AgentStatus.working).stateText(DateTime(2026)), 'offline');
    });

    test('an online tab still says its state and age; a closed one nothing', () {
      expect(info(live: true).stateText(DateTime(2026, 1, 1, 1)), 'idle 1h');
      expect(info(live: false, status: null).stateText(DateTime(2026)), isNull);
    });
  });
}
