// Batch actions on the Agents board: picking agents, the action bar, the
// confirm sheet, and what really goes over the (fake) wire.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/agent_session_rows.dart';
import 'package:herdr_mobile/ui/features/agents/batch_actions_sheet.dart';
import 'package:herdr_mobile/ui/features/agents/triage_pill.dart';
import 'package:herdr_mobile/ui/features/settings/app_switch.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

const _tall = 2400.0;

MachineProfile _profile(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Pane _pane(int i, String status, {String agent = 'claude'}) =>
    (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

String _title(String paneId) => 'task ${paneId.split('p').last}';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(
  String id,
  List<Pane> panes, {
  String? label,
  String Function(String paneId)? title,
}) =>
    (profile: _profile(id, label ?? 'box-$id'), snapshot: snapshotWith(panes, title: title ?? _title));

/// The ten agents of the acceptance case on one machine: tasks 1-3 work,
/// 4-5 wait for an answer, 6-7 are done, 8-10 are idle.
List<Pane> _ten() => [
      for (var i = 1; i <= 3; i++) _pane(i, 'working'),
      for (var i = 4; i <= 5; i++) _pane(i, 'blocked'),
      for (var i = 6; i <= 7; i++) _pane(i, 'done'),
      for (var i = 8; i <= 10; i++) _pane(i, 'idle'),
    ];

Future<BoardHarness> _studio(List<Pane> panes) =>
    BoardHarness.create([_machine('a', panes, label: 'studio-mac')]);

class _Sessions extends FakeAgentSessions {
  _Sessions(super.sessions);

  void changed() => notifyListeners();
}

/// A session whose `end()` waits for the test.
class _SlowEnd extends FakeAgentSession {
  _SlowEnd({super.key, super.title, super.machine});

  final gate = Completer<void>();

  @override
  Future<void> end() async {
    await gate.future;
    await super.end();
  }
}

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(
  WidgetTester tester,
  BoardHarness h, {
  _Sessions? sessions,
  double width = 360,
  double height = _tall,
  double textScale = 1,
  Brightness brightness = Brightness.dark,
  double bottomInset = 0,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2
    ..padding = FakeViewPadding(bottom: bottomInset * 2)
    ..viewPadding = FakeViewPadding(bottom: bottomInset * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ...h.providers,
        if (sessions != null) ListenableProvider<AgentSessions>.value(value: sessions),
        attentionSetProvider(),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        navigatorObservers: [ToastRouteObserver()],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const HomeShell(),
      ),
    ),
  );
  await _settle(tester);
}

/// The title of a board row (card or compact row), not the same text in a sheet.
Finder _row(String title) => find.descendant(
      of: find.byWidgetPredicate((w) => w is AgentCard || w is AgentCompactRow || w is AgentSessionRow),
      matching: find.text(title),
    );

Future<void> _longPress(WidgetTester tester, Finder f) async {
  await tester.longPress(f);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await _settle(tester);
}

/// Picks [titles]: a long press on the first, taps on the rest.
Future<void> _pick(WidgetTester tester, List<String> titles) async {
  await _longPress(tester, _row(titles.first));
  for (final t in titles.skip(1)) {
    await _tap(tester, _row(t));
  }
}

List<Map<String, dynamic>> _sent(BoardHarness h, String machine, String method) => [
      for (final (m, p) in h.transports[machine]!.calls)
        if (m == method) p,
    ];

List<String> _panesOf(List<Map<String, dynamic>> calls) => [for (final c in calls) c['pane_id'] as String];

Finder _selected(int n) => find.text('$n selected');

bool _enabled(WidgetTester tester, String label) =>
    tester.getSemantics(find.text(label)).flagsCollection.isEnabled == Tristate.isTrue;

Finder _confirm(String label) => find.widgetWithText(AppButton, label);

/// The sheet's own Cancel (the selection header has one too).
Finder get _sheetCancel =>
    find.descendant(of: find.byType(BatchSheet), matching: find.widgetWithText(AppButton, 'Cancel'));

void main() {
  setUpAll(loadAppFonts);

  group('picking', () {
    testWidgets('a long press starts, taps toggle, All picks the rest, Cancel leaves', (tester) async {
      final h = await _studio([_pane(1, 'working'), _pane(2, 'working'), _pane(3, 'idle'), _pane(4, 'done')]);
      await _pump(tester, h);
      expect(find.byType(FloatingTabBar), findsOneWidget);
      expect(find.text('All'), findsNothing);

      await _longPress(tester, _row('task 1'));
      expect(_selected(1), findsOneWidget);
      expect(find.byType(FloatingTabBar), findsNothing, reason: 'the action bar takes its place');
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(
        tester.getSemantics(_row('task 1')).flagsCollection.isSelected,
        Tristate.isTrue,
      );

      await _tap(tester, _row('task 2'));
      expect(_selected(2), findsOneWidget);
      await _tap(tester, _row('task 2'));
      expect(_selected(1), findsOneWidget);
      expect(h.agentScreens.front, isNull, reason: 'a tap while picking opens nothing');

      await _tap(tester, find.text('All'));
      expect(_selected(4), findsOneWidget);

      await _tap(tester, find.text('Cancel'));
      expect(find.textContaining('selected'), findsNothing);
      expect(find.byType(FloatingTabBar), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('tapping without picking still opens the pane', (tester) async {
      final h = await _studio([_pane(1, 'working')]);
      await _pump(tester, h);
      await _tap(tester, _row('task 1'));
      expect(h.agentScreens.front, isNotNull);
      await teardownBoard(tester, h);
    });

    testWidgets('the triage pill steps aside while picking and returns after', (tester) async {
      final h = await _studio([_pane(1, 'working'), _pane(2, 'blocked')]);
      await _pump(tester, h);
      expect(find.byType(TriagePill), findsOneWidget);

      await _longPress(tester, _row('task 1'));
      expect(find.byType(TriagePill), findsNothing);

      await _tap(tester, find.text('Cancel'));
      expect(find.byType(TriagePill), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('back leaves picking first, and the board stays', (tester) async {
      final h = await _studio([_pane(1, 'working')]);
      await _pump(tester, h);
      await _longPress(tester, _row('task 1'));
      expect(_selected(1), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.textContaining('selected'), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(FloatingTabBar), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('compact rows pick the same way', (tester) async {
      final h = await _studio([_pane(1, 'working'), _pane(2, 'idle')]);
      await h.appSettings.setDensity(BoardDensity.compact);
      await _pump(tester, h);
      expect(find.byType(AgentCompactRow), findsNWidgets(2));

      await _longPress(tester, _row('task 1'));
      expect(_selected(1), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(AgentCompactRow).first).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      await _tap(tester, _row('task 2'));
      expect(_selected(2), findsOneWidget);
      expect(h.agentScreens.front, isNull);
      await teardownBoard(tester, h);
    });

    testWidgets('All picks what the current filter shows, nothing else', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _tap(tester, find.byWidgetPredicate((w) => w is AppChip && w.label == 'Working'));

      await _longPress(tester, _row('task 1'));
      await _tap(tester, find.text('All'));
      expect(_selected(3), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('a collapsed section is not "visible": All leaves it out', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _tap(tester, find.descendant(of: find.byType(SectionLabel), matching: find.text('Done')));

      await _longPress(tester, _row('task 1'));
      await _tap(tester, find.text('All'));
      expect(_selected(8), findsOneWidget, reason: 'ten agents, the two done ones are folded away');
      await teardownBoard(tester, h);
    });

    testWidgets('Select all done picks the finished ones, even from a collapsed section', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _tap(tester, find.descendant(of: find.byType(SectionLabel), matching: find.text('Done')));
      expect(_row('task 6'), findsNothing);

      await _tap(tester, find.byKey(const ValueKey('select-all-done')));
      expect(_selected(2), findsOneWidget);
      expect(_row('task 6'), findsOneWidget, reason: 'what is picked is on screen');
      expect(_enabled(tester, 'Close'), isTrue);
      expect(_enabled(tester, 'Interrupt'), isFalse);
      await teardownBoard(tester, h);
    });

    testWidgets('a pane that disappears drops out of the selection, silently', (tester) async {
      final h = await _studio([_pane(1, 'working'), _pane(2, 'working'), _pane(3, 'working')]);
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 2', 'task 3']);
      expect(_selected(3), findsOneWidget);

      await h.changeStatuses(tester, 'a', [_pane(1, 'working'), _pane(3, 'working')]);
      expect(_selected(2), findsOneWidget);
      expect(find.byKey(toastKey), findsNothing);

      await _tap(tester, find.text('Interrupt'));
      expect(_confirm('Interrupt 2 agents'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('picking survives a status change and the sheet shows the new status', (tester) async {
      final h = await _studio([_pane(1, 'working'), _pane(2, 'working')]);
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 2']);

      await h.changeStatuses(tester, 'a', [_pane(1, 'idle'), _pane(2, 'working')]);
      expect(_selected(2), findsOneWidget);
      await _tap(tester, find.text('Interrupt'));
      expect(_confirm('Interrupt 1 agent'), findsOneWidget, reason: 'built from live data');
      expect(find.text('Not working'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('the action bar', () {
    testWidgets('enables an action only when it would touch someone', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);

      await _longPress(tester, _row('task 1')); // working
      expect([for (final a in ['Interrupt', 'Message', 'Close']) _enabled(tester, a)], [true, true, false]);

      await _tap(tester, _row('task 1'));
      expect(_selected(0), findsOneWidget);
      expect([for (final a in ['Interrupt', 'Message', 'Close']) _enabled(tester, a)], [false, false, false]);

      await _tap(tester, _row('task 4')); // blocked: only a message (on the person's say so)
      expect([for (final a in ['Interrupt', 'Message', 'Close']) _enabled(tester, a)], [false, true, false]);

      await _tap(tester, _row('task 4'));
      await _tap(tester, _row('task 6')); // done
      expect([for (final a in ['Interrupt', 'Message', 'Close']) _enabled(tester, a)], [false, true, true]);

      await _tap(tester, _row('task 6'));
      await _tap(tester, _row('task 8')); // idle
      expect([for (final a in ['Interrupt', 'Message', 'Close']) _enabled(tester, a)], [false, true, true]);
      await teardownBoard(tester, h);
    });

    testWidgets('follows a selected agent whose status changes', (tester) async {
      final h = await _studio([_pane(1, 'working')]);
      await _pump(tester, h);
      await _longPress(tester, _row('task 1'));
      expect(_enabled(tester, 'Interrupt'), isTrue);

      await h.changeStatuses(tester, 'a', [_pane(1, 'done')]);
      expect(_enabled(tester, 'Interrupt'), isFalse);
      expect(_enabled(tester, 'Close'), isTrue);
      await teardownBoard(tester, h);
    });

    testWidgets('sits above the system inset, each action a 44 dp target', (tester) async {
      final h = await _studio([_pane(1, 'working')]);
      await _pump(tester, h, height: 740, bottomInset: 40);
      await _longPress(tester, _row('task 1'));

      for (final label in ['Interrupt', 'Message', 'Close']) {
        final node = find.ancestor(of: find.text(label), matching: find.byType(PressBuilder));
        final box = tester.getRect(node.first);
        expect(box.bottom, lessThanOrEqualTo(740 - 40), reason: label);
        expect(box.height, greaterThanOrEqualTo(44), reason: label);
        expect(box.width, greaterThanOrEqualTo(44), reason: label);
      }
      await teardownBoard(tester, h);
    });
  });

  group('interrupt', () {
    testWidgets('three working agents: two taps, a confirm, esc to each pane', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);

      await _pick(tester, ['task 1', 'task 2', 'task 3']);
      await _tap(tester, find.text('Interrupt'));

      expect(find.text('Interrupt agents'), findsOneWidget);
      for (final t in ['task 1', 'task 2', 'task 3']) {
        expect(find.text(t), findsNWidgets(2), reason: '$t on the board and in the sheet');
      }
      expect(find.text('claude · studio-mac'), findsNWidgets(3));
      expect(find.text('Skipped'), findsNothing);
      expect(_confirm('Interrupt 3 agents'), findsOneWidget);

      await _tap(tester, find.text('Interrupt 3 agents'));
      final keys = _sent(h, 'a', 'pane.send_keys');
      expect(_panesOf(keys), ['w1:p1', 'w1:p2', 'w1:p3']);
      expect([for (final k in keys) k['keys']], everyElement(['esc']));
      expect(_sent(h, 'a', 'pane.send_input'), isEmpty);
      expect(find.text('Interrupted 3'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing, reason: 'picking ends');
      expect(find.byType(FloatingTabBar), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('lists the agents it leaves alone, with the reason, and sends them nothing', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 4', 'task 6', 'task 8']);
      await _tap(tester, find.text('Interrupt'));

      expect(_confirm('Interrupt 1 agent'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
      expect(find.text('Waiting for an answer'), findsOneWidget);
      expect(find.text('Not working'), findsNWidgets(2));

      await _tap(tester, find.text('Interrupt 1 agent'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_keys')), ['w1:p1']);
      expect(find.text('Interrupted 1 · 3 skipped'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('Cancel in the sheet sends nothing and keeps the selection', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 2']);
      await _tap(tester, find.text('Interrupt'));
      await _tap(tester, _sheetCancel);

      expect(_sent(h, 'a', 'pane.send_keys'), isEmpty);
      expect(_selected(2), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('an agent on an offline machine is skipped as offline and never called', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')], label: 'studio-mac'),
        _machine('b', [_pane(2, 'working')], label: 'build-box'),
      ]);
      await _pump(tester, h);
      h.fleet.connection('b')!.goOffline();
      await _settle(tester);

      await _pick(tester, ['task 1', 'task 2']);
      await _tap(tester, find.text('Interrupt'));
      expect(_confirm('Interrupt 1 agent'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);

      final before = h.transports['b']!.calls.length;
      await _tap(tester, find.text('Interrupt 1 agent'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_keys')), ['w1:p1']);
      expect(h.transports['b']!.calls.length, before, reason: 'nothing is sent to an offline machine');
      expect(find.text('Interrupted 1 · 1 skipped'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('a machine that fails is named, and the other machine still gets its keys', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')], label: 'studio-mac'),
        _machine('b', [_pane(2, 'working')], label: 'build-box'),
      ]);
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 2']);
      await _tap(tester, find.text('Interrupt'));
      h.transports['b']!.failure = const HerdrTransportException('Connection reset');

      await _tap(tester, find.text('Interrupt 2 agents'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_keys')), ['w1:p1']);
      expect(find.text('Interrupted 1 · 1 failed: build-box: Connection reset'), findsOneWidget);
      h.transports['b']!.failure = null;
      await teardownBoard(tester, h);
    });
  });

  group('message', () {
    testWidgets('one line to each idle pane through send_input, the text exactly as typed', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 8', 'task 9']);
      await _tap(tester, find.text('Message'));

      // Nothing typed: the button waits.
      expect(tester.widget<AppButton>(_confirm('Message 2 agents')).onPressed, isNull);

      const text = 'Chạy lại bộ kiểm thử\nrồi báo kết quả ';
      await tester.enterText(find.byType(TextField), text);
      await _settle(tester);
      expect(tester.widget<AppButton>(_confirm('Message 2 agents')).onPressed, isNotNull);

      await _tap(tester, find.text('Message 2 agents'));
      final inputs = _sent(h, 'a', 'pane.send_input');
      expect(_panesOf(inputs), ['w1:p8', 'w1:p9']);
      expect([for (final i in inputs) i['text']], everyElement(text));
      expect([for (final i in inputs) i['keys']], everyElement(['enter']));
      expect(_sent(h, 'a', 'pane.send_keys'), isEmpty, reason: 'one request carries the text and its Enter');
      expect(find.text('Messaged 2'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('a blocked agent is not typed into unless "Send anyway" is on', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 8', 'task 4']);
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), 'continue');
      await _settle(tester);

      expect(find.text('Waiting for an answer (skipped)'), findsOneWidget);
      expect(find.text('Send anyway'), findsOneWidget);
      expect(tester.widget<SwitchRow>(find.byType(SwitchRow)).value, isFalse);
      expect(_confirm('Message 1 agent'), findsOneWidget);

      await _tap(tester, find.text('Message 1 agent'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_input')), ['w1:p8'], reason: 'task 4 shows a prompt');
      expect(find.text('Messaged 1 · 1 skipped'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('"Send anyway" includes them and says what happens', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 8', 'task 4']);
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), '1');
      await _settle(tester);

      await _tap(tester, find.text('Send anyway'));
      expect(tester.widget<SwitchRow>(find.byType(SwitchRow)).value, isTrue);
      expect(_confirm('Message 2 agents'), findsOneWidget);
      expect(find.text('Will be typed into its question'), findsOneWidget);

      await _tap(tester, find.text('Message 2 agents'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_input')), unorderedEquals(['w1:p4', 'w1:p8']));
      await teardownBoard(tester, h);
    });

    testWidgets('an agent that starts waiting while the sheet is open is left out', (tester) async {
      final h = await _studio([_pane(1, 'idle'), _pane(2, 'idle')]);
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 2']);
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), 'hello');
      await _settle(tester);
      expect(_confirm('Message 2 agents'), findsOneWidget);

      await h.changeStatuses(tester, 'a', [_pane(1, 'blocked'), _pane(2, 'idle')]);
      expect(_confirm('Message 1 agent'), findsOneWidget);
      expect(find.text('Waiting for an answer (skipped)'), findsOneWidget);

      await _tap(tester, find.text('Message 1 agent'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_input')), ['w1:p2']);
      await teardownBoard(tester, h);
    });

    testWidgets('"Send anyway" turns itself off when another agent starts waiting', (tester) async {
      final h = await _studio([_pane(1, 'idle'), _pane(2, 'idle'), _pane(3, 'blocked')]);
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 2', 'task 3']);
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), 'hello');
      await _settle(tester);
      await _tap(tester, find.text('Send anyway'));
      expect(_confirm('Message 3 agents'), findsOneWidget);

      await h.changeStatuses(tester, 'a', [_pane(1, 'blocked'), _pane(2, 'idle'), _pane(3, 'blocked')]);
      expect(tester.widget<SwitchRow>(find.byType(SwitchRow)).value, isFalse, reason: 'it was not meant for task 1');
      expect(_confirm('Message 1 agent'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('only blocked agents picked: the sheet offers nothing until the switch is on', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 4', 'task 5']);
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), 'ok');
      await _settle(tester);

      expect(_confirm('Message 0 agents'), findsOneWidget);
      expect(tester.widget<AppButton>(_confirm('Message 0 agents')).onPressed, isNull);
      await teardownBoard(tester, h);
    });

    testWidgets('a long message with many lines is fine', (tester) async {
      final h = await _studio([_pane(1, 'idle')]);
      await _pump(tester, h, height: 640);
      await _pick(tester, ['task 1']);
      await _tap(tester, find.text('Message'));
      final text = List.generate(60, (i) => 'dòng số $i của một yêu cầu rất dài').join('\n');
      await tester.enterText(find.byType(TextField), text);
      await _settle(tester);
      expect(tester.takeException(), isNull);

      await _tap(tester, find.text('Message 1 agent'));
      expect(_sent(h, 'a', 'pane.send_input').single['text'], text);
      await teardownBoard(tester, h);
    });
  });

  group('close', () {
    testWidgets('Select all done, then Close: the finished panes are closed, nothing else', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);

      await _tap(tester, find.byKey(const ValueKey('select-all-done')));
      await _tap(tester, find.text('Close'));

      expect(find.text('Close agents'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(find.text('task 6'), findsNWidgets(2));
      expect(find.text('task 7'), findsNWidgets(2));
      expect(_confirm('Close 2 agents'), findsOneWidget);

      await _tap(tester, find.text('Close 2 agents'));
      expect(_panesOf(_sent(h, 'a', 'pane.close')), ['w1:p6', 'w1:p7']);
      expect(find.text('Closed 2'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('working and waiting agents are listed as skipped and stay open', (tester) async {
      final h = await _studio(_ten());
      await _pump(tester, h);
      await _pick(tester, ['task 1', 'task 4', 'task 6', 'task 8']);
      await _tap(tester, find.text('Close'));

      expect(_confirm('Close 2 agents'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
      expect(find.text('Still working'), findsOneWidget);
      expect(find.text('Waiting for an answer'), findsOneWidget);

      await _tap(tester, find.text('Close 2 agents'));
      expect(_panesOf(_sent(h, 'a', 'pane.close')), ['w1:p6', 'w1:p8']);
      expect(find.text('Closed 2 · 2 skipped'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('a pane that is already gone counts as closed', (tester) async {
      final h = await _studio([_pane(1, 'done')]);
      await _pump(tester, h);
      await _pick(tester, ['task 1']);
      await _tap(tester, find.text('Close'));
      h.transports['a']!.failure = const HerdrApiException('pane_not_found', 'no such pane');

      await _tap(tester, find.text('Close 1 agent'));
      expect(find.text('Closed 1'), findsOneWidget);
      h.transports['a']!.failure = null;
      await teardownBoard(tester, h);
    });
  });

  group('agent sessions', () {
    FakeAgentSession session(BoardHarness h, String key, String title, {AgentSessionState? state}) =>
        FakeAgentSession(
          key: 'a/$key',
          title: title,
          machine: h.fleet.connection('a'),
          state: state ?? const AgentSessionState('s1'),
        );

    testWidgets('interrupt, message and close go through cancel, send and end', (tester) async {
      final h = await _studio([_pane(1, 'working')]);
      final working = session(h, 'k1', 'agent one', state: stateWith(turnActive: true));
      final idle = session(h, 'k2', 'agent two');
      final idle2 = session(h, 'k3', 'agent three');
      final idle4 = session(h, 'k4', 'agent four');
      final sessions = _Sessions([working, idle, idle2, idle4]);
      await _pump(tester, h, sessions: sessions);

      // Interrupt: a terminal agent and a session together.
      await _pick(tester, ['task 1', 'agent one']);
      await _tap(tester, find.text('Interrupt'));
      expect(_confirm('Interrupt 2 agents'), findsOneWidget);
      await _tap(tester, find.text('Interrupt 2 agents'));
      expect(working.cancelCount, 1);
      expect(_panesOf(_sent(h, 'a', 'pane.send_keys')), ['w1:p1']);

      // Message: the idle sessions get a prompt.
      await _pick(tester, ['agent two', 'agent three']);
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), 'ship it');
      await _settle(tester);
      await _tap(tester, find.text('Message 2 agents'));
      expect(idle.sent, ['ship it']);
      expect(idle2.sent, ['ship it']);
      expect(working.sent, isEmpty);

      // Close: an idle session is ended (the ones messaged are working now).
      await _pick(tester, ['agent four']);
      await _tap(tester, find.text('Close'));
      await _tap(tester, find.text('Close 1 agent'));
      expect(idle4.link, AgentLink.ended);
      expect(idle.link, AgentLink.live);
      expect(find.text('Closed 1'), findsOneWidget);
      sessions.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a blocked session is never offered the switch, and sessions that cannot take a message are not sent one', (tester) async {
      final h = await _studio([_pane(1, 'blocked')]);
      final working = session(h, 'k1', 'agent one', state: stateWith(turnActive: true));
      final blocked = session(
        h,
        'k2',
        'agent two',
        state: stateWith(turnActive: true, pending: [PendingPermission(1, permissionRequest())]),
      );
      final sessions = _Sessions([working, blocked]);
      await _pump(tester, h, sessions: sessions);

      // Sessions alone: nothing could take a message, so the bar says no.
      await _pick(tester, ['agent one', 'agent two']);
      expect(_enabled(tester, 'Message'), isFalse);

      await _tap(tester, _row('task 1'));
      await _tap(tester, find.text('Message'));
      await tester.enterText(find.byType(TextField), 'hi');
      await _settle(tester);
      await _tap(tester, find.text('Send anyway'));

      // The switch opens the terminal agent; the blocked session stays skipped.
      expect(_confirm('Message 1 agent'), findsOneWidget);
      expect(find.text('Waiting for an answer (skipped)'), findsOneWidget);
      expect(find.text('Waiting for an answer'), findsOneWidget, reason: 'the skipped row says why');
      expect(find.text('Still working'), findsOneWidget);
      await _tap(tester, find.text('Message 1 agent'));
      expect(_panesOf(_sent(h, 'a', 'pane.send_input')), ['w1:p1']);
      expect(working.sent, isEmpty);
      expect(blocked.sent, isEmpty);
      sessions.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a session that is not live can be neither closed nor messaged', (tester) async {
      final h = await _studio([_pane(1, 'idle')]);
      final gone = session(h, 'k1', 'agent one')..setLink(AgentLink.reconnecting);
      final sessions = _Sessions([gone]);
      await _pump(tester, h, sessions: sessions);

      await _pick(tester, ['agent one']);
      await _tap(tester, find.text('Close'));
      // Not enabled: the bar would not even have opened the sheet.
      expect(find.text('Close agents'), findsNothing);
      expect(_enabled(tester, 'Close'), isFalse);
      sessions.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a spinner shows while the batch runs, and only then', (tester) async {
      final h = await _studio([_pane(1, 'idle')]);
      final slow = _SlowEnd(key: 'a/k1', title: 'agent one', machine: h.fleet.connection('a'));
      final sessions = _Sessions([slow]);
      await _pump(tester, h, sessions: sessions);
      expect(find.byType(BusySpinner), findsNothing);

      await _pick(tester, ['agent one']);
      expect(find.byType(BusySpinner), findsNothing);
      await _tap(tester, find.text('Close'));
      await _tap(tester, find.text('Close 1 agent'));

      expect(find.byType(BusySpinner), findsOneWidget);
      expect(find.text('Closing 1 agent…'), findsOneWidget);
      // The selection is frozen while it runs.
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Cancel')).onPressed, isNull);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(_selected(1), findsOneWidget);

      slow.gate.complete();
      await _settle(tester);
      expect(find.byType(BusySpinner), findsNothing);
      expect(find.textContaining('selected'), findsNothing);
      expect(find.text('Closed 1'), findsOneWidget);
      sessions.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a session that goes away drops out of the selection', (tester) async {
      final h = await _studio([_pane(1, 'idle')]);
      final one = session(h, 'k1', 'agent one');
      final two = session(h, 'k2', 'agent two');
      final list = [one, two];
      final sessions = _Sessions(list);
      await _pump(tester, h, sessions: sessions);
      await _pick(tester, ['agent one', 'agent two']);
      expect(_selected(2), findsOneWidget);

      list.remove(two);
      sessions.changed();
      await _settle(tester);
      expect(_selected(1), findsOneWidget);
      sessions.dispose();
      await teardownBoard(tester, h);
    });
  });

  group('worst case', () {
    String longTitle(String paneId) =>
        'Tái cấu trúc mô-đun thanh toán và đồng bộ hóa dữ liệu khách hàng số ${paneId.split('p').last} '
        '— ưu tiên rất cao, kiểm thử lại toàn bộ trước khi phát hành';

    List<Pane> thirty() => [
          for (var i = 1; i <= 30; i++) _pane(i, const ['working', 'blocked', 'done', 'idle', 'unknown'][i % 5]),
        ];

    for (final brightness in Brightness.values) {
      testWidgets('30 agents, 320 dp, 2x text, ${brightness.name}: no overflow in any step', (tester) async {
        final h = await BoardHarness.create([
          _machine('a', thirty(), label: 'máy-chủ-xây-dựng-rất-dài', title: longTitle),
        ]);
        await _pump(tester, h, width: 320, height: 640, textScale: 2, brightness: brightness, bottomInset: 24);

        await _longPress(tester, _row(longTitle('w1:p1')));
        expect(tester.takeException(), isNull);
        expect(_selected(1), findsOneWidget);

        await _tap(tester, find.text('All'));
        expect(tester.takeException(), isNull);
        expect(_selected(30), findsOneWidget);

        for (final action in ['Interrupt', 'Message', 'Close']) {
          await _tap(tester, find.text(action));
          expect(tester.takeException(), isNull, reason: action);
          if (action == 'Message') {
            await tester.enterText(find.byType(TextField), 'Chạy lại toàn bộ rồi báo kết quả cho tôi biết nhé');
            await _settle(tester);
            expect(tester.takeException(), isNull);
          }
          await _tap(tester, _sheetCancel);
          expect(find.byType(BatchSheet), findsNothing);
        }
        await teardownBoard(tester, h);
      });
    }

    testWidgets('one agent at 2x text on a narrow phone', (tester) async {
      final h = await _studio([_pane(1, 'working')]);
      await _pump(tester, h, width: 320, height: 640, textScale: 2);
      await _longPress(tester, _row('task 1'));
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Interrupt'));
      expect(_confirm('Interrupt 1 agent'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await teardownBoard(tester, h);
    });
  });
}
