// Starting a session (the form, its sticky bar, offline machines, the launch)
// and managing what exists (rename/close workspaces and panes, new tabs).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/open_tabs.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/create/new_session_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/herdr_stub.dart';
import '../support/memory_terminal_settings_store.dart';

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
  for (final t in h.stubs.values) {
    t.on['workspace.create'] = (params) {
      addWorkspaceTo(t.snapshot, label: params['label'] as String? ?? '', cwd: params['cwd'] as String? ?? '/home/u');
      return workspaceCreated(cwd: params['cwd'] as String? ?? '/home/u');
    };
    t.on['server.agent_manifests'] = (_) => {
          'manifests': [
            {'agent': 'claude'},
            {'agent': 'codex'},
            {'agent': 'pi'},
          ],
        };
  }
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
      ChangeNotifierProvider.value(value: h.settings),
      ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
      ChangeNotifierProvider(create: (_) => OpenTabs()),
      Provider<PanePreviews>(
        create: (_) => PanePreviews(changes: h.fleet, connection: h.fleet.connection),
        dispose: (_, previews) => previews.dispose(),
      ),
      Provider<TransportFactory>.value(value: (p, s, a, b) => throw StateError('unused')),
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

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.ensureVisible(_field(label));
  await tester.enterText(_field(label), text);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _flush(tester);
  await tester.tap(finder);
  await _flush(tester);
}

Finder _button(String label) => find.widgetWithText(AppButton, label);

void main() {
  group('the plus on the Agents tab', () {
    testWidgets('offers a new session and a new machine', (tester) async {
      final h = await _env();
      await _pump(tester, h, const HomeShell());

      await tester.tap(find.byTooltip('New'));
      await _flush(tester);

      expect(find.text('New agent session'), findsOneWidget);
      expect(find.text('Add machine'), findsOneWidget);

      await tester.tap(find.text('New agent session'));
      await _flush(tester);
      expect(find.byType(NewSessionScreen), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('Add machine still opens the machine form', (tester) async {
      final h = await _env();
      await _pump(tester, h, const HomeShell());

      await tester.tap(find.byTooltip('New'));
      await _flush(tester);
      await tester.tap(find.text('Add machine'));
      await _flush(tester);

      expect(find.text('herdr is reached over SSH. Nothing is exposed publicly and no relay is involved.'), findsOneWidget);
      await _tearDown(tester, h);
    });
  });

  group('the form', () {
    testWidgets('lists only machines that are online', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await tester.tap(find.bySemanticsLabel(RegExp('^Machine, workstation')));
      await _flush(tester);

      expect(find.text('laptop'), findsOneWidget);
      expect(find.text('staging'), findsNothing, reason: 'offline');
      await _tearDown(tester, h);
    });

    testWidgets('one online machine is just named, with nothing to choose', (tester) async {
      final h = await _env();
      h.connection('b').goOffline();
      await _pump(tester, h, const NewSessionScreen());

      expect(find.text('workstation'), findsOneWidget);
      await tester.tap(find.text('workstation'));
      await _flush(tester);
      expect(find.text('laptop'), findsNothing, reason: 'no sheet opened');
      await _tearDown(tester, h);
    });

    testWidgets('with nothing online it says so instead of showing a form', (tester) async {
      final h = await _env();
      h.connection('a').goOffline();
      h.connection('b').goOffline();
      await _pump(tester, h, const NewSessionScreen());

      expect(find.text('No machine is online'), findsOneWidget);
      expect(_button('Start'), findsNothing);
      await _tearDown(tester, h);
    });

    testWidgets('offers Shell and the agents herdr lists', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      for (final label in ['Shell', 'claude', 'codex', 'pi']) {
        expect(find.widgetWithText(AppChip, label), findsOneWidget, reason: label);
      }
      expect(find.widgetWithText(AppChip, 'gemini'), findsNothing, reason: 'herdr did not list it');
      expect(find.text('Command'), findsNothing, reason: 'a shell needs none');
      await _tearDown(tester, h);
    });

    testWidgets('falls back to the usual agents when herdr cannot list them', (tester) async {
      final h = await _env();
      h.stubs['a']!.on['server.agent_manifests'] = (_) => throw unknownMethod('server.agent_manifests');
      await _pump(tester, h, const NewSessionScreen());

      for (final label in ['Shell', 'claude', 'codex', 'omp', 'opencode', 'gemini', 'cursor', 'amp', 'aider']) {
        expect(find.widgetWithText(AppChip, label), findsOneWidget, reason: label);
      }
      await _tearDown(tester, h);
    });

    testWidgets('an agent brings its command, editable, and a first message', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'claude'));

      expect(find.text('Command'), findsOneWidget);
      expect(find.text('First message (optional)'), findsOneWidget);
      expect(tester.widget<TextFormField>(_field('Command')).controller!.text, 'claude');
      await _tearDown(tester, h);
    });

    testWidgets('folders open on the machine are one tap away and fill the field', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'work/w1'));

      expect(tester.widget<TextFormField>(_field('Folder')).controller!.text, '/work/w1');
      expect(tester.widget<AppChip>(find.widgetWithText(AppChip, 'work/w1')).selected, isTrue);
      await _tearDown(tester, h);
    });

    testWidgets('Browse appears only where files can be browsed', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());
      expect(find.byTooltip('Browse folders'), findsNothing);
      await _tearDown(tester, h);

      final files = await _env();
      files.stubs['a']!.fs = FakeFs();
      await _pump(tester, files, const NewSessionScreen());
      expect(find.byTooltip('Browse folders'), findsOneWidget);
      await _tearDown(tester, files);
    });

    testWidgets('the name field hints at the folder name as it is typed', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _type(tester, 'Folder', '/work/payments-api');

      expect(
        tester.widget<TextField>(find.descendant(of: _field('Workspace name'), matching: find.byType(TextField))).decoration!.hintText,
        'payments-api',
      );
      await _tearDown(tester, h);
    });
  });

  group('starting', () {
    testWidgets('an empty folder is refused on the spot, nothing is sent', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, _button('Start'));

      expect(find.text('Choose a folder'), findsOneWidget);
      expect(h.stubs['a']!.methods, isEmpty);
      await _tearDown(tester, h);
    });

    testWidgets('a shell: creates the workspace and opens its pane', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _type(tester, 'Folder', '/work/payments-api');
      await _tap(tester, _button('Start'));

      expect(h.stubs['a']!.methods, ['workspace.create']);
      expect(h.stubs['a']!.paramsOf('workspace.create').single, {
        'cwd': '/work/payments-api',
        'label': 'payments-api',
        'focus': false,
      });
      expect(find.byType(PaneScreen), findsOneWidget);
      expect(find.byType(NewSessionScreen), findsNothing, reason: 'Back leaves the form behind');
      await _tearDown(tester, h);
    });

    testWidgets('an agent with a first message: command now, message once it is up', (tester) async {
      final h = await _env();
      final t = h.stubs['a']!;
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'claude'));
      await _type(tester, 'Folder', '/work/payments-api');
      await _type(tester, 'First message (optional)', 'fix the failing test\nthen push');
      await _tap(tester, _button('Start'));

      expect(t.methods, ['workspace.create', 'pane.send_input']);
      expect(t.paramsOf('pane.send_input').single['text'], 'claude');
      expect(find.byType(PaneScreen), findsOneWidget, reason: 'opened without waiting for the agent');

      final pane = (t.snapshot['panes'] as List).last as Map<String, dynamic>;
      pane['agent'] = 'claude';
      pane['agent_status'] = 'idle';
      t.emit({'event': 'pane_agent_detected'});
      await _flush(tester); // the connection's refresh timer, then the poll

      expect(t.paramsOf('pane.send_input').last['text'], 'fix the failing test\nthen push');
      await _tearDown(tester, h);
    });

    testWidgets('an edited command is used and remembered for next time', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'codex'));
      await _type(tester, 'Folder', '/srv/x');
      await _type(tester, 'Command', 'codex --full-auto');
      await _tap(tester, _button('Start'));

      expect(h.stubs['a']!.paramsOf('pane.send_input').single['text'], 'codex --full-auto');
      expect(h.settings.commandFor('a', 'codex'), 'codex --full-auto');
      expect(h.settings.kindFor('a'), 'codex');
      await _tearDown(tester, h);
    });

    testWidgets('an empty command for an agent is refused', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'claude'));
      await _type(tester, 'Folder', '/srv/x');
      await _type(tester, 'Command', '');
      await _tap(tester, _button('Start'));

      expect(find.text('Enter the command that starts it'), findsOneWidget);
      expect(h.stubs['a']!.methods, isEmpty);
      await _tearDown(tester, h);
    });

    testWidgets('a failure stays on the form with the reason in the bar', (tester) async {
      final h = await _env();
      h.stubs['a']!.on['workspace.create'] = (_) => throw unknownMethod('workspace.create');
      await _pump(tester, h, const NewSessionScreen());

      await _type(tester, 'Folder', '/work/x');
      await _tap(tester, _button('Start'));

      expect(find.text('Not supported by this herdr'), findsOneWidget);
      expect(find.textContaining('Update herdr on that machine'), findsOneWidget);
      expect(find.byType(NewSessionScreen), findsOneWidget);
      expect(find.byType(PaneScreen), findsNothing);

      await _type(tester, 'Folder', '/work/y');
      expect(find.text('Not supported by this herdr'), findsNothing, reason: 'editing clears it');
      await _tearDown(tester, h);
    });

    testWidgets('the command failing opens the workspace anyway and says so', (tester) async {
      final h = await _env();
      h.stubs['a']!.on['pane.send_input'] = (_) => throw const HerdrTransportException('pty closed');
      await _pump(tester, h, const NewSessionScreen());

      await _tap(tester, find.widgetWithText(AppChip, 'claude'));
      await _type(tester, 'Folder', '/work/x');
      await _tap(tester, _button('Start'));

      expect(find.byType(PaneScreen), findsOneWidget);
      expect(find.textContaining('workspace was created'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('the busy button blocks a second start', (tester) async {
      final h = await _env();
      final t = h.stubs['a']!;
      final gate = Completer<void>();
      final inner = t.on['workspace.create']!;
      t.on['workspace.create'] = (p) async {
        await gate.future;
        return inner(p);
      };
      await _pump(tester, h, const NewSessionScreen());

      await _type(tester, 'Folder', '/work/x');
      await tester.tap(_button('Start'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Starting…'), findsOneWidget);
      await tester.tap(find.text('Starting…'));
      await tester.pump(const Duration(milliseconds: 50));

      gate.complete();
      await _flush(tester);
      expect(t.paramsOf('workspace.create'), hasLength(1));
      await _tearDown(tester, h);
    });
  });

  group('layout', () {
    testWidgets('the Start bar rides above the keyboard and the focused field stays reachable', (tester) async {
      final h = await _env();
      await _pump(tester, h, const NewSessionScreen());
      tester.view.viewInsets = const FakeViewPadding(bottom: 600); // 300dp at 2x
      addTearDown(tester.view.resetViewInsets);

      await tester.tap(_field('Folder'));
      await _flush(tester);

      final start = tester.getRect(_button('Start'));
      expect(start.bottom, lessThanOrEqualTo(740 - 300 + 0.5), reason: 'above the keyboard');
      expect(tester.getRect(_field('Folder')).bottom, lessThan(start.top), reason: 'the field is not under the bar');
      await _tearDown(tester, h);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('320dp wide at ${scale}x text: nothing overflows, every control is reachable', (tester) async {
        final h = await _env();
        h.stubs['a']!.snapshot['panes'] = [
          {
            ...((h.stubs['a']!.snapshot['panes'] as List).first as Map<String, dynamic>),
            'cwd': '/home/nguyễn-văn-a/projects/a-very-long-directory-name-that-keeps-going/and-going/deeper',
          },
        ];
        await h.connection('a').refresh();
        await _pump(tester, h, const NewSessionScreen(), width: 320, height: 568, scale: scale);
        await _tap(tester, find.widgetWithText(AppChip, 'claude'));

        expect(tester.takeException(), isNull);
        for (final f in [_field('Folder'), _field('Command'), _field('First message (optional)'), _button('Start')]) {
          await tester.ensureVisible(f);
          expect(tester.getRect(f).width, lessThanOrEqualTo(320));
        }
        expect(tester.takeException(), isNull);
        await _tearDown(tester, h);
      });
    }
  });

  group('managing a machine', () {
    Future<CreateHarness> open(WidgetTester tester, {String id = 'a'}) async {
      final h = await _env();
      await _pump(tester, h, MachineScreen(machine: h.connection(id)));
      return h;
    }

    testWidgets('New workspace here starts the form on this machine', (tester) async {
      final h = await open(tester, id: 'b');

      await tester.tap(find.byTooltip('New workspace here'));
      await _flush(tester);

      expect(find.byType(NewSessionScreen), findsOneWidget);
      expect(find.text('laptop'), findsWidgets);
      await _tearDown(tester, h);
    });

    testWidgets('Browse files only where there is a file system, New workspace only while online', (tester) async {
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
      final newWorkspace = find.byWidgetPredicate((w) => w is CircleButton && w.tooltip == 'New workspace here');
      expect(tester.widget<CircleButton>(newWorkspace).onPressed, isNull,
          reason: 'an offline machine cannot take a workspace');
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

      expect(find.byType(SnackBar), findsNothing);
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
