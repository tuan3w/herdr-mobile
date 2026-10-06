// The plus buttons, the agent form's machine and folder fields, and managing
// what exists (rename/close workspaces and panes, new tabs).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/herdr_stub.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import 'ui_harness.dart' show attentionSetProvider;

Map<String, dynamic> _fleetSnapshot() => snapshotJson(
      workspaces: const [(id: 'w1', label: 'payments-api'), (id: 'w2', label: 'docs')],
      panes: const [
        (id: 'w1:p0', ws: 'w1', agent: 'claude', status: 'working'),
        (id: 'w1:p1', ws: 'w1', agent: null, status: 'unknown'),
        (id: 'w2:p0', ws: 'w2', agent: 'codex', status: 'idle'),
      ],
    );

/// workstation and laptop online, staging off.
Future<CreateHarness> _env() async {
  final h = await CreateHarness.create([
    (profile: profileOf('a', 'workstation'), snapshot: _fleetSnapshot()),
    (profile: profileOf('b', 'laptop'), snapshot: snapshotJson()),
    (profile: profileOf('off', 'staging', enabled: false), snapshot: snapshotJson()),
  ], waitOnline: false);
  return h;
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(
  WidgetTester tester,
  CreateHarness h,
  Widget home, {
  double width = 360,
  double height = 740,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: h.machines),
      ChangeNotifierProvider.value(value: h.fleet),
      ListenableProvider<AgentSessions>.value(value: h.agents),
      ChangeNotifierProvider.value(value: h.agentSettings),
      ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
      ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
      ChangeNotifierProvider(create: (_) => AgentScreens()),
      Provider<PanePreviews>(
        create: (_) => PanePreviews(changes: h.fleet, connection: h.fleet.connection),
        dispose: (_, previews) => previews.dispose(),
      ),
      Provider<TransportFactory>.value(value: (p, s, a, b) => throw StateError('unused')),
      attentionSetProvider(),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    ),
  ));
  await _flush(tester);
}

Future<void> _tearDown(WidgetTester tester, CreateHarness h) async {
  await tester.pumpWidget(const SizedBox());
  h.dispose();
}

Finder _field(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is LabeledField && w.label == label),
      matching: find.byType(TextFormField),
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _flush(tester);
  await tester.tap(finder);
  await _flush(tester);
}

Finder _button(String label) => find.widgetWithText(AppButton, label);

void main() {
  group('the plus on the Agents tab', () {
    testWidgets('opens the new agent session form at once, with no menu in between', (tester) async {
      final h = await _env();
      await _pump(tester, h, const HomeShell());

      await tester.tap(find.byTooltip('New agent session'));
      await _flush(tester);

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(find.text('Add machine'), findsNothing);
      await _tearDown(tester, h);
    });
  });

  group('the agent form', () {
    testWidgets('lists only machines that are online', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewAgentSessionScreen());

      await tester.tap(find.bySemanticsLabel(RegExp('^Machine, workstation')));
      await _flush(tester);

      expect(find.text('laptop'), findsOneWidget);
      expect(find.text('staging'), findsNothing, reason: 'offline');
      await _tearDown(tester, h);
    });

    testWidgets('one online machine is just named, with nothing to choose', (tester) async {
      final h = await _env();
      h.connection('b').goOffline();
      await _pump(tester, h, const NewAgentSessionScreen());

      expect(find.text('workstation'), findsOneWidget);
      await tester.tap(find.text('workstation'));
      await _flush(tester);
      expect(find.text('laptop'), findsNothing, reason: 'no sheet opened');
      await _tearDown(tester, h);
    });

    testWidgets('folders open on the machine are one tap away and fill the field', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewAgentSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'work/w1'));

      expect(tester.widget<TextFormField>(_field('Folder')).controller!.text, '/work/w1');
      expect(tester.widget<AppChip>(find.widgetWithText(AppChip, 'work/w1')).selected, isTrue);
      await _tearDown(tester, h);
    });

    testWidgets('Browse appears only where files can be browsed', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewAgentSessionScreen());
      expect(find.byTooltip('Browse folders'), findsNothing);
      await _tearDown(tester, h);

      final files = await _env();
      files.stubs['a']!.fs = FakeFs();
      await _pump(tester, files, const NewAgentSessionScreen());
      expect(find.byTooltip('Browse folders'), findsOneWidget);
      await _tearDown(tester, files);
    });

    testWidgets('the Start bar rides above the keyboard and the focused field stays reachable', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewAgentSessionScreen());
      tester.view.viewInsets = const FakeViewPadding(bottom: 600); // 300dp at 2x
      addTearDown(tester.view.resetViewInsets);

      await tester.tap(_field('Folder'));
      await _flush(tester);

      final start = tester.getRect(_button('Start'));
      expect(start.bottom, lessThanOrEqualTo(740 - 300 + 0.5), reason: 'above the keyboard');
      expect(tester.getRect(_field('Folder')).bottom, lessThan(start.top), reason: 'the field is not under the bar');
      await _tearDown(tester, h);
    });
  });

  group('managing a machine', () {
    Future<CreateHarness> open(WidgetTester tester, {String id = 'a'}) async {
      final h = await _env();
      await _pump(tester, h, MachineScreen(machine: h.connection(id)));
      return h;
    }

    testWidgets('the plus starts an agent session on this machine, not on the first one', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await open(tester, id: 'b');

      await tester.tap(find.byTooltip('New agent session'));
      await _flush(tester);

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Machine, laptop')), findsOneWidget, reason: 'workstation is first in the list');
      semantics.dispose();
      await _tearDown(tester, h);
    });

    testWidgets('Browse files only where there is a file system, the plus only while online', (tester) async {
      final h = await _env();
      h.stubs['a']!.fs = FakeFs();
      h.connection('b').goOffline();
      await _pump(tester, h, MachineScreen(machine: h.connection('a')));
      expect(find.byTooltip('Browse files'), findsOneWidget);
      await _tearDown(tester, h);

      final plain = await _env();
      plain.connection('b').goOffline();
      await _pump(tester, plain, MachineScreen(machine: plain.connection('b')));
      expect(find.byTooltip('Browse files'), findsNothing);
      final plus = find.byWidgetPredicate((w) => w is CircleButton && w.tooltip == 'New agent session');
      expect(tester.widget<CircleButton>(plus).onPressed, isNull,
          reason: 'an offline machine cannot take a session');
      await _tearDown(tester, plain);
    });

    testWidgets('workspace actions: rename sends the new label and refreshes the list', (tester) async {
      final h = await open(tester);
      final t = h.stubs['a']!;
      final before = t.snapshotCalls;

      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      expect(find.text('New tab here'), findsOneWidget);
      await tester.tap(find.text('Rename'));
      await _flush(tester);

      expect(tester.widget<TextFormField>(_field('Name')).controller!.text, 'payments-api', reason: 'starts from the current name');
      await tester.enterText(_field('Name'), '  Thanh toán  ');
      await tester.tap(_button('Save'));
      await _flush(tester);

      expect(t.paramsOf('workspace.rename').single, {'workspace_id': 'w1', 'label': 'Thanh toán'});
      expect(t.snapshotCalls, greaterThan(before), reason: 'the machine is refreshed');
      await _tearDown(tester, h);
    });

    testWidgets('Save waits for a name', (tester) async {
      final h = await open(tester);
      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('Rename'));
      await _flush(tester);

      await tester.enterText(_field('Name'), '   ');
      await tester.pump();
      await tester.tap(_button('Save'));
      await _flush(tester);

      expect(h.stubs['a']!.paramsOf('workspace.rename'), isEmpty);
      expect(find.text('Rename workspace'), findsOneWidget, reason: 'the sheet is still open');
      await _tearDown(tester, h);
    });

    testWidgets('closing a workspace asks first and names what stops', (tester) async {
      final h = await open(tester);
      final t = h.stubs['a']!;

      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('Close workspace'));
      await _flush(tester);

      expect(find.text('Close payments-api?'), findsOneWidget);
      expect(find.textContaining('2 panes'), findsOneWidget);
      expect(t.paramsOf('workspace.close'), isEmpty, reason: 'not before the confirmation');

      await tester.tap(_button('Close workspace'));
      await _flush(tester);

      expect(t.paramsOf('workspace.close').single, {'workspace_id': 'w1'});
      await _tearDown(tester, h);
    });

    testWidgets('cancelling the confirmation closes nothing', (tester) async {
      final h = await open(tester);
      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('Close workspace'));
      await _flush(tester);

      await tester.tap(_button('Cancel'));
      await _flush(tester);

      expect(h.stubs['a']!.methods, isEmpty);
      await _tearDown(tester, h);
    });

    testWidgets('a workspace closed on the desktop meanwhile is simply gone: no error', (tester) async {
      final h = await open(tester);
      h.stubs['a']!.on['workspace.close'] = (_) => throw const HerdrApiException('workspace_not_found', 'workspace w1 not found');

      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('Close workspace'));
      await _flush(tester);
      await tester.tap(_button('Close workspace'));
      await _flush(tester);

      expect(find.byKey(toastKey), findsNothing);
      await _tearDown(tester, h);
    });

    testWidgets('renaming something that vanished says so', (tester) async {
      final h = await open(tester);
      h.stubs['a']!.on['workspace.rename'] = (_) => throw const HerdrApiException('workspace_not_found', 'gone');

      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('Rename'));
      await _flush(tester);
      await tester.enterText(_field('Name'), 'x');
      await tester.tap(_button('Save'));
      await _flush(tester);

      expect(find.text('It was already closed on the machine.'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('an old herdr is told apart from a failure', (tester) async {
      final h = await open(tester);
      h.stubs['a']!.on['workspace.rename'] = (_) => throw unknownMethod('workspace.rename');

      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('Rename'));
      await _flush(tester);
      await tester.enterText(_field('Name'), 'x');
      await tester.tap(_button('Save'));
      await _flush(tester);

      expect(find.textContaining('Update herdr on that machine'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('a new tab opens in the workspace folder and its pane is shown', (tester) async {
      final h = await open(tester);
      final t = h.stubs['a']!;
      t.on['tab.create'] = (_) => {
            'type': 'tab_created',
            'tab': {'tab_id': 'w1:t2'},
            'root_pane': {'pane_id': 'w1:p9'},
          };

      await tester.tap(find.byTooltip('Workspace actions').first);
      await _flush(tester);
      await tester.tap(find.text('New tab here'));
      await _flush(tester);

      expect(t.paramsOf('tab.create').single, {'workspace_id': 'w1', 'cwd': '/work/w1', 'focus': false});
      expect(find.byType(PaneScreen), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('long-pressing a pane: rename and close', (tester) async {
      final h = await open(tester);
      final t = h.stubs['a']!;

      await tester.longPress(find.text('title w1:p0'));
      await _flush(tester);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Close pane'), findsOneWidget);

      await tester.tap(find.text('Rename'));
      await _flush(tester);
      await tester.enterText(_field('Name'), 'builder');
      await tester.tap(_button('Save'));
      await _flush(tester);
      expect(t.paramsOf('pane.rename').single, {'pane_id': 'w1:p0', 'label': 'builder'});

      await tester.longPress(find.text('title w1:p1'));
      await _flush(tester);
      await tester.tap(find.text('Close pane'));
      await _flush(tester);
      expect(t.paramsOf('pane.close'), isEmpty, reason: 'asks first');
      await tester.tap(_button('Close pane'));
      await _flush(tester);
      expect(t.paramsOf('pane.close').single, {'pane_id': 'w1:p1'});
      await _tearDown(tester, h);
    });

    testWidgets('a pane renamed on the machine shows its name', (tester) async {
      final h = await _env();
      (h.stubs['a']!.snapshot['panes'] as List).first['label'] = 'builder';
      await h.connection('a').refresh();
      await _pump(tester, h, MachineScreen(machine: h.connection('a')));

      expect(find.text('builder'), findsOneWidget);
      expect(find.text('title w1:p0'), findsNothing);
      await _tearDown(tester, h);
    });

    testWidgets('an offline machine has no actions to trigger', (tester) async {
      final h = await _env();
      h.connection('a').goOffline();
      await _pump(tester, h, MachineScreen(machine: h.connection('a')));

      await tester.longPress(find.text('title w1:p0'));
      await _flush(tester);

      expect(find.text('Close pane'), findsNothing);
      await _tearDown(tester, h);
    });
  });
}
