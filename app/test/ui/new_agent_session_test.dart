// Starting an agent session: the machine, the folder, the agents a machine can
// run, what the form remembers, and every way a start can fail.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/agent_session_settings.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_host.dart';
import 'board_support.dart';
import 'ui_harness.dart';

class _MemoryStore implements AgentSessionStore {
  AgentSessionMemory memory = const AgentSessionMemory();

  @override
  Future<AgentSessionMemory> read() async => memory;

  @override
  Future<void> write(AgentSessionMemory memory) async => this.memory = memory;
}

class _Env {
  _Env(this.h, this.repo, this.hosts, this.settings, this.store);

  final BoardHarness h;
  final AgentSessionRepository repo;
  final Map<String, FakeAgentHost> hosts;
  final AgentSessionSettings settings;
  final _MemoryStore store;

  FakeAgentHost host(String id) => hosts[id]!;
}

MachineProfile _machine(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Future<_Env> _env({
  List<({String id, String label})> machines = const [(id: 'a', label: 'studio-mac')],
  AgentSessionMemory memory = const AgentSessionMemory(),
}) async {
  final h = await BoardHarness.create([
    for (final m in machines) (profile: _machine(m.id, m.label), snapshot: snapshotWith(const [])),
  ]);
  final hosts = <String, FakeAgentHost>{};
  final repo = AgentSessionRepository(fleet: h.fleet, hostFor: (c) => hosts.putIfAbsent(c.profile.id, FakeAgentHost.new));
  final store = _MemoryStore()..memory = memory;
  final settings = AgentSessionSettings(store);
  await settings.load();
  return _Env(h, repo, hosts, settings, store);
}

/// Lets the machines connect (the form only offers machines that are online).
Future<void> _connect(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpForm(
  WidgetTester tester,
  _Env e, {
  double width = 360,
  double height = 800,
  double textScale = 1,
  bool connect = true,
}) async {
  if (connect) await _connect(tester);
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ...e.h.providers,
        ListenableProvider<AgentSessions>.value(value: e.repo),
        ChangeNotifierProvider.value(value: e.settings),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const NewAgentSessionScreen(),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _teardown(WidgetTester tester, _Env e) async {
  await tester.pumpWidget(const SizedBox());
  e.repo.dispose();
  e.h.dispose();
}

Finder _field(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is LabeledField && w.label == label),
      matching: find.byType(TextFormField),
    );

Finder _chip(String label) => find.widgetWithText(AppChip, label);

Finder _start() => find.widgetWithText(AppButton, 'Start');

Finder _startAndOpen() => find.widgetWithText(AppButton, 'Start and open');

String _folder(WidgetTester tester) => tester.widget<TextFormField>(_field('Folder')).controller!.text;

bool _selected(WidgetTester tester, String label) => tester.widget<AppChip>(_chip(label)).selected;

Future<void> _type(WidgetTester tester, String folder) async {
  await tester.enterText(_field('Folder'), folder);
  await tester.pump();
}

Future<void> _tapStart(WidgetTester tester) async {
  await tester.ensureVisible(_start());
  await tester.tap(_start());
  await _settle(tester, 8);
}

Future<void> _tapStartAndOpen(WidgetTester tester) async {
  await tester.ensureVisible(_startAndOpen());
  await tester.tap(_startAndOpen());
  await _settle(tester, 8);
}

void main() {
  group('the form', () {
    testWidgets('offers every route; the ones the machine cannot run are disabled, with the reason', (tester) async {
      final e = await _env();
      e.host('a').installed = {'claude', 'codex'};
      await _pumpForm(tester, e);

      for (final label in ['omp', 'Claude Code', 'Codex', 'pi']) {
        expect(_chip(label), findsOneWidget, reason: label);
      }
      expect(tester.widget<AppChip>(_chip('omp')).onTap, isNull);
      expect(tester.widget<AppChip>(_chip('pi')).onTap, isNull);
      expect(tester.widget<AppChip>(_chip('Codex')).onTap, isNotNull);
      expect(find.text('omp is not installed on studio-mac'), findsOneWidget);
      expect(find.text('pi is not installed on studio-mac'), findsOneWidget);
      expect(find.text('Codex is not installed on studio-mac'), findsNothing);
      expect(_selected(tester, 'Claude Code'), isTrue, reason: 'the first agent that can run');

      await tester.tap(_chip('omp'));
      await tester.pump();
      expect(_selected(tester, 'omp'), isFalse, reason: 'a disabled chip does nothing');
      await tester.tap(_chip('Codex'));
      await tester.pump();
      expect(_selected(tester, 'Codex'), isTrue);
      expect(_selected(tester, 'Claude Code'), isFalse);
      await _teardown(tester, e);
    });

    testWidgets('starts from what was used last: machine, agent and folder', (tester) async {
      final e = await _env(
        machines: const [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')],
        memory: const AgentSessionMemory(
          machineId: 'b',
          agents: {'a': 'omp', 'b': 'codex'},
          folders: {'a': '/home/dev/a-app', 'b': '/srv/app'},
        ),
      );
      await _pumpForm(tester, e);

      expect(find.text('build-box'), findsOneWidget);
      expect(_folder(tester), '/srv/app');
      expect(_selected(tester, 'Codex'), isTrue);
      await _teardown(tester, e);
    });

    testWidgets('another machine brings its own agents and folder', (tester) async {
      final e = await _env(
        machines: const [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')],
        memory: const AgentSessionMemory(
          machineId: 'a',
          agents: {'a': 'omp', 'b': 'omp'},
          folders: {'a': '/home/dev/a-app', 'b': '/srv/app'},
        ),
      );
      e.host('b').installed = {'codex'};
      await _pumpForm(tester, e);
      expect(_folder(tester), '/home/dev/a-app');
      expect(_selected(tester, 'omp'), isTrue);

      await tester.tap(find.text('studio-mac'));
      await _settle(tester);
      await tester.tap(find.text('build-box'));
      await _settle(tester);

      expect(_folder(tester), '/srv/app');
      expect(_selected(tester, 'Codex'), isTrue, reason: 'omp is not on build-box');
      expect(find.text('omp is not installed on build-box'), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('a folder the person typed is not overwritten by switching machines', (tester) async {
      final e = await _env(
        machines: const [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')],
        memory: const AgentSessionMemory(machineId: 'a', folders: {'a': '/home/dev/a-app', 'b': '/srv/app'}),
      );
      await _pumpForm(tester, e);
      await _type(tester, '/tmp/scratch');

      await tester.tap(find.text('studio-mac'));
      await _settle(tester);
      await tester.tap(find.text('build-box'));
      await _settle(tester);

      expect(_folder(tester), '/tmp/scratch');
      await _teardown(tester, e);
    });

    testWidgets('no machine online says so', (tester) async {
      final e = await _env();
      await _connect(tester);
      e.h.fleet.connection('a')!.goOffline();
      await _pumpForm(tester, e, connect: false);

      expect(find.text('No machine is online'), findsOneWidget);
      expect(_start(), findsNothing);
      await _teardown(tester, e);
    });

    testWidgets('a machine that cannot be asked says why and still lets the start report', (tester) async {
      final e = await _env();
      e.host('a').availableFailure = const AgentHostException('python3 is missing on studio-mac.');
      await _pumpForm(tester, e);

      expect(find.text('python3 is missing on studio-mac.'), findsOneWidget);
      expect(tester.widget<AppButton>(_start()).onPressed, isNotNull);
      await _teardown(tester, e);
    });

    testWidgets('a long machine name, folder and large text fit a small screen', (tester) async {
      final e = await _env(machines: const [(id: 'a', label: 'build-server-eu-west-2-primary-with-a-very-long-name')]);
      await _pumpForm(tester, e, width: 320, height: 640, textScale: 2);
      await _type(tester, '/home/dev/Dự án thử nghiệm/${'thư mục rất dài ' * 10}');

      expect(tester.takeException(), isNull);
      await _teardown(tester, e);
    });
  });

  group('starting', () {
    testWidgets('success: the form gives way to the session and remembers its choices', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '  /home/dev/api ');
      await tester.tap(_chip('Claude Code'));
      await tester.pump();

      await _tapStartAndOpen(tester);

      expect(find.byType(NewAgentSessionScreen), findsNothing, reason: 'replaced, not stacked');
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      final host = e.host('a');
      expect(host.startCalls, 1);
      final keeper = host.keepers.values.single;
      expect(keeper.info.agent, 'claude');
      expect(keeper.info.cwd, '/home/dev/api');
      expect(keeper.newCount, 1);
      expect(e.repo.sessions.single.link, AgentLink.live);
      expect(e.store.memory.machineId, 'a');
      expect(e.store.memory.agents['a'], 'claude');
      expect(e.store.memory.folders['a'], '/home/dev/api');
      await _teardown(tester, e);
    });

    testWidgets('shows progress while starting, and a second tap starts nothing twice', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '/home/dev/api');
      e.host('a').attachGate = Completer<void>();

      await _tapStartAndOpen(tester);
      expect(find.text('Starting…'), findsOneWidget);
      expect(find.byType(BusySpinner), findsOneWidget);
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Starting…')).loading, isTrue);
      await tester.tap(find.widgetWithText(AppButton, 'Starting…'), warnIfMissed: false);
      await _settle(tester);
      expect(e.host('a').startCalls, 1);

      e.host('a').attachGate!.complete();
      await _settle(tester, 8);
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(e.host('a').startCalls, 1);
      await _teardown(tester, e);
    });

    testWidgets('an agent that went missing since the form looked is named', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '/home/dev/api');
      e.host('a').installed = {'claude'};

      await _tapStart(tester);

      expect(find.text("Couldn't start the session"), findsOneWidget);
      expect(find.text('omp is not installed on studio-mac.'), findsOneWidget);
      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(e.host('a').startCalls, 0);
      expect(e.store.memory.folders, isEmpty, reason: 'a failed start remembers nothing');
      await _teardown(tester, e);
    });

    testWidgets('a folder the host cannot use is said in the host\'s words', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '/home/dev/gone');
      e.host('a').startFailure = const AgentHostException('/home/dev/gone does not exist on studio-mac.', fatal: true);

      await _tapStart(tester);

      expect(find.text('/home/dev/gone does not exist on studio-mac.'), findsOneWidget);
      expect(e.repo.sessions, isEmpty);
      await _teardown(tester, e);
    });

    testWidgets('an agent that cannot sign in fails the start and leaves no keeper behind', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '/home/dev/api');
      e.host('a').attachFailures.add(const AgentHostException('omp is not signed in: run `omp login` on studio-mac', fatal: true));

      await _tapStart(tester);

      expect(find.text('omp is not signed in: run `omp login` on studio-mac'), findsOneWidget);
      expect(e.host('a').killed, hasLength(1));
      expect(e.repo.sessions, isEmpty);
      await _teardown(tester, e);
    });

    testWidgets('an unreachable host is said, and a retry works once it is back', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '/home/dev/api');
      final host = e.host('a');
      host.availableFailure = const AgentHostException('Could not reach studio-mac: connection timed out');

      await _tapStart(tester);
      expect(find.text('Could not reach studio-mac: connection timed out'), findsOneWidget);

      host.availableFailure = null;
      await _tapStartAndOpen(tester);
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('the error goes away when the person edits the form', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);
      await _type(tester, '/home/dev/api');
      e.host('a').startFailure = const AgentHostException('disk full');
      await _tapStart(tester);
      expect(find.text('disk full'), findsOneWidget);

      await _type(tester, '/home/dev/api2');
      await _settle(tester);
      expect(find.text('disk full'), findsNothing);
      await _teardown(tester, e);
    });

    testWidgets('a relative folder or a ~ is refused before anything is asked of the host', (tester) async {
      final e = await _env();
      await _pumpForm(tester, e);

      await _type(tester, 'src/app');
      await _tapStart(tester);
      expect(find.text('Start with / or ~'), findsOneWidget, reason: 'not a path at all');

      await _type(tester, '~/code/app');
      await _tapStart(tester);
      expect(find.text('An absolute path, starting with /'), findsOneWidget, reason: 'a ~ would reach the agent unexpanded');

      await _type(tester, '');
      await _tapStart(tester);
      expect(find.text('Choose a folder'), findsOneWidget);
      expect(e.host('a').startCalls, 0);
      await _teardown(tester, e);
    });
  });
}
