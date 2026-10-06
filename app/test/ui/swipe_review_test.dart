// Swiping a finished agent on the Agents board marks it reviewed (with an Undo
// toast), and everything that must not: slow short drags, other statuses,
// offline agents, picking mode, a second finger.
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

const _tall = 2400.0;

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

Future<BoardHarness> _board(List<Pane> panes) => BoardHarness.create([
      (
        profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
        snapshot: snapshotWith(panes, title: (id) => 'task ${id.split('p').last}'),
      ),
    ]);

MachineConnection _machine(BoardHarness h) => h.fleet.connection('a')!;

AgentStatus _status(BoardHarness h, int i) => _machine(h).paneById('w1:p$i')!.status;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Where the card's title is: moves with the row, unlike the card widget.
double _x(WidgetTester tester, [int i = 1]) => tester.getTopLeft(find.text('task $i')).dx;

Finder _title([int i = 1]) => find.text('task $i');

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a swipe past the threshold reviews the agent, offers Undo, and Undo brings it back',
      (tester) async {
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final h = await _board([_pane(1, 'done'), _pane(2, 'working')]);
    await pumpBoard(tester, h, height: _tall);
    expect(_status(h, 1), AgentStatus.done);

    await tester.drag(_title(), const Offset(-260, 0));
    await _settle(tester);

    expect(_status(h, 1), AgentStatus.idle);
    expect(find.text('Marked reviewed'), findsOneWidget);
    expect(haptics, contains('HapticFeedbackType.selectionClick'), reason: 'the threshold was crossed');
    expect(haptics.last, 'HapticFeedbackType.lightImpact', reason: 'the commit is a send');
    expect(_title(), findsOneWidget, reason: 'the agent moved to another section, it is not gone');
    expect(_x(tester), _x(tester, 2), reason: 'and sits in place there, like any other card');

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(_status(h, 1), AgentStatus.done);
    expect(find.text('Marked reviewed'), findsNothing);
    await tester.drag(_title(), const Offset(-260, 0));
    await _settle(tester);
    expect(_status(h, 1), AgentStatus.idle, reason: 'and it can be swiped again');
    await teardownBoard(tester, h);
  });

  testWidgets('a short, slow drag follows the finger, shows Reviewed, springs back and does nothing',
      (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await pumpBoard(tester, h, height: _tall);
    final home = _x(tester);

    final g = await tester.startGesture(tester.getCenter(_title()));
    for (var i = 0; i < 3; i++) {
      await g.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_x(tester), lessThan(home - 40), reason: 'the row follows the finger');
    expect(find.text('Reviewed'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400)); // it stopped: no speed to carry it
    await g.up();
    await _settle(tester);

    expect(_x(tester), home, reason: 'sprung back to where it was');
    expect(find.text('Reviewed'), findsNothing);
    expect(find.text('Marked reviewed'), findsNothing);
    expect(_status(h, 1), AgentStatus.done);
    await teardownBoard(tester, h);
  });

  testWidgets('a fast flick commits even from a short distance', (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await pumpBoard(tester, h, height: _tall);

    await tester.fling(_title(), const Offset(-70, 0), 2500);
    await _settle(tester);

    expect(_status(h, 1), AgentStatus.idle);
    expect(find.text('Marked reviewed'), findsOneWidget);
    await teardownBoard(tester, h);
  });

  testWidgets('a flick the other way does not review, and a twitch is not a flick', (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await pumpBoard(tester, h, height: _tall);

    await tester.fling(_title(), const Offset(120, 0), 2500);
    await _settle(tester);
    expect(_status(h, 1), AgentStatus.done);

    await tester.fling(_title(), const Offset(-20, 0), 3000); // 2 px past the touch slop
    await _settle(tester);
    expect(_status(h, 1), AgentStatus.done);
    await teardownBoard(tester, h);
  });

  testWidgets('a working card ignores the swipe', (tester) async {
    final h = await _board([_pane(1, 'working'), _pane(2, 'done')]);
    await pumpBoard(tester, h, height: _tall);
    final home = _x(tester);

    final g = await tester.startGesture(tester.getCenter(_title()));
    await g.moveBy(const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_x(tester), home, reason: 'it does not move');
    expect(find.text('Reviewed'), findsNothing);
    await g.up();
    await _settle(tester);

    expect(find.text('Marked reviewed'), findsNothing);
    expect(_status(h, 1), AgentStatus.working);
    await teardownBoard(tester, h);
  });

  testWidgets('a finished agent on an offline machine ignores the swipe', (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await pumpBoard(tester, h, height: _tall);
    h.network.goOffline();
    await tester.pump(const Duration(milliseconds: 300));
    final home = _x(tester);

    await tester.drag(_title(), const Offset(-260, 0));
    await _settle(tester);

    expect(_x(tester), home);
    expect(find.text('Marked reviewed'), findsNothing);
    expect(_status(h, 1), AgentStatus.done);
    h.network.goOnline();
    await teardownBoard(tester, h);
  });

  testWidgets('while the board is picking agents a swipe does nothing', (tester) async {
    final h = await _board([_pane(1, 'done'), _pane(2, 'done')]);
    await pumpBoard(tester, h, height: _tall);

    await tester.longPress(_title());
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    final home = _x(tester, 2);

    await tester.drag(_title(2), const Offset(-260, 0));
    await _settle(tester);

    expect(_x(tester, 2), home);
    expect(find.text('Marked reviewed'), findsNothing);
    expect(_status(h, 1), AgentStatus.done);
    expect(_status(h, 2), AgentStatus.done);
    await teardownBoard(tester, h);
  });

  testWidgets('a second finger puts the row back, even past the threshold', (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await pumpBoard(tester, h, height: _tall);
    final home = _x(tester);

    final first = await tester.startGesture(tester.getCenter(_title()), pointer: 1);
    for (var i = 0; i < 5; i++) {
      await first.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final second = await tester.startGesture(Offset(340, tester.getCenter(_title()).dy), pointer: 2);
    await tester.pump(const Duration(milliseconds: 16));
    await first.up();
    await second.up();
    await _settle(tester);

    expect(_status(h, 1), AgentStatus.done);
    expect(_x(tester), home);
    await teardownBoard(tester, h);
  });

  testWidgets('with reduced motion the review happens on release, nothing slides', (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await pumpBoard(tester, h, height: _tall, reduceMotion: true);

    await tester.drag(_title(), const Offset(-260, 0));
    await tester.pump(const Duration(milliseconds: 16));

    expect(_status(h, 1), AgentStatus.idle);
    expect(find.text('Marked reviewed'), findsOneWidget);
    await teardownBoard(tester, h);
  });

  testWidgets('screen readers get a Mark reviewed action on a finished agent only', (tester) async {
    final handle = tester.ensureSemantics();
    final h = await _board([_pane(1, 'done'), _pane(2, 'working')]);
    await pumpBoard(tester, h, height: _tall);

    Iterable<String> actions(int i) {
      final data = tester.getSemantics(_title(i)).getSemanticsData();
      return [
        for (final id in data.customSemanticsActionIds ?? const <int>[])
          CustomSemanticsAction.getAction(id)!.label!,
      ];
    }

    expect(actions(2), isEmpty);
    expect(actions(1), ['Mark reviewed']);

    final node = tester.getSemantics(_title());
    node.owner!.performAction(node.id, SemanticsAction.customAction, node.getSemanticsData().customSemanticsActionIds!.single);
    await _settle(tester);

    expect(_status(h, 1), AgentStatus.idle);
    expect(find.text('Marked reviewed'), findsOneWidget);
    await teardownBoard(tester, h);
    handle.dispose();
  });

  testWidgets('the compact list swipes too', (tester) async {
    final h = await _board([_pane(1, 'done')]);
    await h.appSettings.setDensity(BoardDensity.compact);
    await pumpBoard(tester, h, height: _tall);
    expect(find.byType(AgentCompactRow), findsOneWidget);

    await tester.drag(_title(), const Offset(-260, 0));
    await _settle(tester);

    expect(_status(h, 1), AgentStatus.idle);
    expect(find.text('Marked reviewed'), findsOneWidget);
    await teardownBoard(tester, h);
  });

  testWidgets('two swipes in a row share one toast, and its Undo takes both back', (tester) async {
    final h = await _board([_pane(1, 'done'), _pane(2, 'done')]);
    await pumpBoard(tester, h, height: _tall);

    await tester.drag(_title(1), const Offset(-260, 0));
    await _settle(tester);
    expect(find.text('Marked reviewed'), findsOneWidget);

    await tester.drag(_title(2), const Offset(-260, 0));
    await _settle(tester);
    expect(_status(h, 1), AgentStatus.idle);
    expect(_status(h, 2), AgentStatus.idle);
    expect(find.text('Marked 2 reviewed'), findsOneWidget);
    expect(find.text('Marked reviewed'), findsNothing);

    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(_status(h, 1), AgentStatus.done, reason: 'the first swipe was not lost');
    expect(_status(h, 2), AgentStatus.done);
    expect(find.text('Marked 2 reviewed'), findsNothing);
    await teardownBoard(tester, h);
  });
}
