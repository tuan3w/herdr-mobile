// Idle through the real shell: a long list folds its older rows behind one
// line that says how many and what, and opens them in place.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/features/agents/agent_more_row.dart';
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

Pane _pane(int i) => (id: 'w1:p${i.toString().padLeft(2, '0')}', ws: 'w1', agent: 'omp', status: 'idle');

void main() {
  setUpAll(loadAppFonts);

  Future<UiHarness> fleet(int idle) => UiHarness.create([
    (
      profile: MachineProfile(id: 'a', label: 'workstation', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith([for (var i = 1; i <= idle; i++) _pane(i)], title: (id) => 'Task ${id.split('p').last}'),
    ),
  ]);

  // None of them has a known time, so newest first ties and they keep pane
  // order.
  testWidgets('27 idle agents show the first five, then one line that names the first two it holds', (tester) async {
    final h = await fleet(27);
    await pumpUi(tester, h, height: 3000);

    expect(find.text('Task 01'), findsOneWidget);
    expect(find.text('Task 05'), findsOneWidget);
    expect(find.text('Task 06'), findsNothing, reason: 'folded away');
    final fold = find.byType(AgentMoreRow);
    expect(fold, findsOneWidget);
    expect(
      tester.getTopLeft(fold).dy,
      greaterThan(tester.getTopLeft(find.text('Task 05')).dy),
      reason: 'after the rows',
    );
    expect(find.text('${27 - idleShown} more idle'), findsOneWidget);
    expect(find.text('Task 06 \u00B7 Task 07'), findsOneWidget, reason: 'what is inside, not a guess');

    await tester.tap(fold);
    await settle(tester);
    expect(find.text('Task 27'), findsOneWidget, reason: 'every row shows');
    expect(
      tester.getTopLeft(find.text('Task 27')).dy,
      greaterThan(tester.getTopLeft(find.text('Task 05')).dy),
      reason: 'in its own place',
    );
    expect(find.text('Show less'), findsOneWidget);
    expect(find.textContaining('more idle'), findsNothing);

    await tester.tap(find.text('Show less'));
    await settle(tester);
    expect(find.text('Task 27'), findsNothing);
    expect(find.text('${27 - idleShown} more idle'), findsOneWidget);
    await teardownUi(tester, h);
  });

  // Owner decision: a predictable board. A row never slips into the fold
  // while the person looks; the next look folds it.
  testWidgets('an agent going idle folds nothing away until the board is looked at afresh', (tester) async {
    final h = await UiHarness.create([
      (
        profile: MachineProfile(id: 'a', label: 'workstation', host: 'a.example', username: 'dev'),
        snapshot: snapshotWith([
          for (var i = 1; i <= 7; i++) _pane(i),
          (id: 'w1:p08', ws: 'w1', agent: 'omp', status: 'working'),
        ], title: (id) => 'Task ${id.split('p').last}'),
      ),
    ]);
    await pumpUi(tester, h, height: 3000);
    expect(find.text('2 more idle'), findsOneWidget);
    expect(find.text('Task 05'), findsOneWidget);

    final panes = h.transports['a']!.snapshot['panes'] as List;
    panes[7] = {...panes[7] as Map<String, dynamic>, 'agent_status': 'idle'};
    await h.fleet.connections.single.refresh();
    await settle(tester);
    expect(find.text('Task 08'), findsOneWidget, reason: 'the newest idle, on top');
    expect(find.text('Task 05'), findsOneWidget, reason: 'still in view, though it is now sixth');
    expect(find.text('2 more idle'), findsOneWidget);

    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await h.fleet.connections.single.refresh();
    await settle(tester);
    expect(find.text('Task 05'), findsNothing, reason: 'the next look folds it');
    expect(find.text('3 more idle'), findsOneWidget);
    await teardownUi(tester, h);
  });

  testWidgets('a short list has no fold at all', (tester) async {
    final h = await fleet(idleShown + 1);
    await pumpUi(tester, h, height: 3000);

    expect(find.byType(AgentMoreRow), findsNothing);
    expect(find.text('Task 06'), findsOneWidget);
    await teardownUi(tester, h);
  });
}
