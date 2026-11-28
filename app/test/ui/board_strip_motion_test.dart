// A machine dropping (or coming back) opens (or closes) the connection strip
// above the list. The agents under it follow the strip's height instead of
// teleporting by a whole strip in one frame, so the card being read does not
// jump (docs/screens/board.md, "The connection strip stays a strip").
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart' show LinkState;
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

/// The first agent's top edge: what the person is reading moves with it.
double _top(WidgetTester tester) =>
    tester.getTopLeft(find.byWidgetPredicate((w) => w is AgentCard || w is AgentCompactRow).first).dy;

/// The first agent's top over [frames] frames of 16 ms.
Future<List<double>> _tops(WidgetTester tester, int frames) async {
  final tops = <double>[_top(tester)];
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    tops.add(_top(tester));
  }
  return tops;
}

void main() {
  setUpAll(loadAppFonts);

  Future<UiHarness> board(WidgetTester tester) async {
    final h = await UiHarness.create([
      (
        profile: MachineProfile(id: 'a', label: 'workstation', host: 'a.example', username: 'dev'),
        snapshot: snapshotWith([_pane(1, 'working'), _pane(2, 'idle')], title: (id) => 'task ${id.split('p').last}'),
      ),
    ]);
    await pumpUi(tester, h, height: 892, width: 412);
    return h;
  }

  void drop(UiHarness h) {
    h.transports['a']!.failure = HerdrTransportException('Host key changed', fatal: true);
    h.fleet.connections.first.reconnect();
  }

  testWidgets('a machine dropping opens the strip in its own height: the list glides, it does not jump', (
    tester,
  ) async {
    final h = await board(tester);
    final resting = _top(tester);

    drop(h);
    final tops = await _tops(tester, 30);

    final total = tops.last - resting;
    expect(total, greaterThan(40), reason: 'the strip took its room');
    final steps = [for (var i = 1; i < tops.length; i++) tops[i] - tops[i - 1]];
    expect(
      steps.reduce((a, b) => a > b ? a : b),
      lessThan(total * 0.75),
      reason: 'no single frame carries the list most of the way: $steps',
    );
    expect(tops.last, tops[tops.length - 2], reason: 'it came to rest');
    await teardownUi(tester, h);
  });

  testWidgets('the machine coming back closes the strip the same way', (tester) async {
    final h = await board(tester);
    final resting = _top(tester);
    drop(h);
    await _tops(tester, 30);
    expect(_top(tester), greaterThan(resting + 40));

    h.transports['a']!.failure = null;
    final link = h.fleet.connections.first;
    link.retry();
    // The retry runs on real I/O: let the event loop turn until the link is up.
    for (var i = 0; i < 200 && link.state != LinkState.online; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(link.state, LinkState.online);
    final tops = await _tops(tester, 30);

    final total = tops.first - resting;
    expect(total, greaterThan(40), reason: 'the strip was still open when the machine came back');
    final steps = [for (var i = 1; i < tops.length; i++) tops[i - 1] - tops[i]];
    expect(steps.reduce((a, b) => a > b ? a : b), lessThan(total * 0.75), reason: 'closing glides: $steps');
    expect(find.byType(StatusStrip), findsNothing, reason: 'the strip is gone once the gap is closed');
    expect(tops.last, resting);
    await teardownUi(tester, h);
  });
}
