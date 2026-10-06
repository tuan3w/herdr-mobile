// Launch and stay (Start goes back to where the form was opened and says what
// started; Start and open goes to the session) and Duplicate (the form opened on
// a running session's machine, folder and agent, remembering nothing until the
// person starts from it), from a chat and from a terminal pane.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_settings.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/create/session_prefill.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_agent_host.dart';
import '../support/fake_agent_session.dart';
import '../support/fake_transport.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import 'board_support.dart';
import 'ui_harness.dart' show attentionSetProvider, snapshotWith;

const _longFolder = '/home/nguyễn-văn-a/Dự án thử nghiệm/thư mục rất dài và lằng nhằng/a-very-long-directory-name/payments-api';

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _field(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is LabeledField && w.label == label),
      matching: find.byType(TextFormField),
    );

Finder _button(String label) => find.widgetWithText(AppButton, label);

Finder _chip(String label) => find.widgetWithText(AppChip, label);

bool _selected(WidgetTester tester, String label) => tester.widget<AppChip>(_chip(label)).selected;

String _text(WidgetTester tester, String field) => tester.widget<TextFormField>(_field(field)).controller!.text;

/// The toast with exactly [text].
Finder _toast(String text) => find.descendant(of: find.byKey(toastKey), matching: find.text(text));

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

/// A page to open the form from, so that Start has somewhere to go back to.
class _Base extends StatelessWidget {
  const _Base();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: AppButton(
            label: 'Open form',
            onPressed: () => openNewAgentSession(context),
          ),
        ),
      );
}

MaterialApp _app(Widget home, {Brightness brightness = Brightness.light, double scale = 1}) => MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester tester, double width, double height) {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

// ---------------------------------------------------------------------------
// Duplicate from a terminal pane

Map<String, dynamic> _fleetSnapshot() {
  final json = snapshotJson(
    workspaces: const [(id: 'w1', label: 'payments-api'), (id: 'w2', label: 'docs')],
    panes: const [
      (id: 'w1:p0', ws: 'w1', agent: 'claude', status: 'working'),
      (id: 'w1:p1', ws: 'w1', agent: null, status: 'unknown'),
      (id: 'w2:p0', ws: 'w2', agent: 'codex', status: 'idle'),
      (id: 'w2:p1', ws: 'w2', agent: 'aider', status: 'idle'),
      (id: 'w2:p2', ws: 'w2', agent: 'pi', status: 'idle'),
    ],
  );
  // The folder the program is in now, not the one the pane was opened in.
  ((json['panes'] as List).first as Map<String, dynamic>)['foreground_cwd'] = '/work/w1/api';
  return json;
}

/// workstation and laptop online, staging off.
Future<CreateHarness> _paneEnv({AgentSessionMemory? memory}) async {
  final h = await CreateHarness.create([
    (profile: profileOf('a', 'workstation'), snapshot: _fleetSnapshot()),
    (profile: profileOf('b', 'laptop'), snapshot: snapshotJson()),
    (profile: profileOf('off', 'staging', enabled: false), snapshot: snapshotJson()),
  ], waitOnline: false);
  if (memory != null) {
    h.agentStore.memory = memory;
    await h.agentSettings.load();
  }
  return h;
}

Future<void> _panePump(WidgetTester tester, CreateHarness h, AgentScreens screens, Widget home) async {
  _phone(tester, 360, 740);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: h.machines),
      ChangeNotifierProvider.value(value: h.fleet),
      ListenableProvider<AgentSessions>.value(value: h.agents),
      ChangeNotifierProvider.value(value: h.agentSettings),
      ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
      ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
      ChangeNotifierProvider.value(value: screens),
      Provider<PanePreviews>(
        create: (_) => PanePreviews(changes: h.fleet, connection: h.fleet.connection),
        dispose: (_, previews) => previews.dispose(),
      ),
      Provider<TransportFactory>.value(value: (p, s, a, b) => throw StateError('unused')),
      attentionSetProvider(),
    ],
    child: _app(home),
  ));
  await _flush(tester);
}

Future<void> _paneTearDown(WidgetTester tester, CreateHarness h, AgentScreens screens) async {
  await tester.pumpWidget(const SizedBox());
  screens.dispose();
  h.dispose();
}

/// The pane's options sheet.
Future<void> _openPaneOptions(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Pane options'));
  await _flush(tester);
}

Future<void> _duplicatePane(WidgetTester tester) async {
  await _openPaneOptions(tester);
  await tester.tap(find.text('Duplicate'));
  await _flush(tester);
}

/// The pane screen showing [paneId] of machine `a`.
Finder _paneScreen(String paneId) =>
    find.byWidgetPredicate((w) => w is PaneScreen && w.agent == PaneAgent('a', paneId));

void main() {
  group('pane: Duplicate', () {
    /// Machine `a`'s pane [paneId] on its own screen, the form's way back.
    Future<void> paneOf(WidgetTester tester, CreateHarness h, AgentScreens screens, String paneId) =>
        _panePump(tester, h, screens, PaneScreen(agent: PaneAgent('a', paneId)));

    testWidgets('opens the agent form on the pane\'s machine, foreground folder and agent', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _paneEnv(
        memory: const AgentSessionMemory(machineId: 'b', agents: {'a': 'codex', 'b': 'omp'}),
      );
      final screens = AgentScreens();
      await paneOf(tester, h, screens, 'w1:p0');

      await _duplicatePane(tester);

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Machine, workstation')), findsOneWidget, reason: 'not the laptop used last');
      expect(_text(tester, 'Folder'), '/work/w1/api', reason: 'where the program is, not where the pane opened');
      expect(_selected(tester, 'Claude Code'), isTrue, reason: 'the pane\'s agent, not the codex used last');
      semantics.dispose();
      await _paneTearDown(tester, h, screens);
    });

    testWidgets('backing out remembers nothing', (tester) async {
      const memory = AgentSessionMemory(machineId: 'b', agents: {'a': 'codex'}, folders: {'a': '/old'});
      final h = await _paneEnv(memory: memory);
      final screens = AgentScreens();
      await paneOf(tester, h, screens, 'w1:p0');

      await _duplicatePane(tester);
      await tester.tap(find.byTooltip('Back'));
      await _flush(tester);

      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(_paneScreen('w1:p0'), findsOneWidget);
      expect(h.agentStore.memory.machineId, 'b');
      expect(h.agentStore.memory.agents, {'a': 'codex'});
      expect(h.agentStore.memory.folders, {'a': '/old'});
      expect(h.hosts['a']?.startCalls ?? 0, 0);
      await _paneTearDown(tester, h, screens);
    });

    for (final (pane, chip) in [
      ('w2:p0', 'Codex'),
      ('w2:p2', 'pi'),
      ('w1:p1', 'omp'), // a shell: the form's own default
      ('w2:p1', 'omp'), // aider: no ACP route, so the form's own default
    ]) {
      testWidgets('the agent of $pane selects $chip', (tester) async {
        final h = await _paneEnv();
        final screens = AgentScreens();
        await paneOf(tester, h, screens, pane);

        await _duplicatePane(tester);

        expect(_selected(tester, chip), isTrue);
        expect(_text(tester, 'Folder'), '/work/${pane.split(':').first}');
        await _paneTearDown(tester, h, screens);
      });
    }

    testWidgets('an offline machine: Duplicate is there, dimmed, with the reason, and does nothing', (tester) async {
      final h = await _paneEnv();
      final screens = AgentScreens();
      await paneOf(tester, h, screens, 'w1:p0');
      h.connection('a').goOffline();
      await _flush(tester);

      await _openPaneOptions(tester);

      expect(find.text('Duplicate'), findsOneWidget);
      expect(find.text('workstation is offline'), findsOneWidget);
      await tester.tap(find.text('Duplicate'));
      await _flush(tester);
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(find.text('Copy title'), findsOneWidget, reason: 'the sheet is still up');
      await _paneTearDown(tester, h, screens);
    });
  });

  // -------------------------------------------------------------------------
  // agent sessions

  group('Start stays', () {
    testWidgets('Start goes back to the board and says what started; Open opens the chat', (tester) async {
      final e = await _AgentEnv.create();
      await e.pump(tester, const HomeShell());
      await e.openFormFromBoard(tester);

      await _type(tester, 'Folder', '/home/dev/api');
      await tester.tap(_chip('Claude Code'));
      await tester.pump();
      await _tap(tester, _button('Start'));

      final session = e.repo.sessions.single;
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
      expect(_toast('${session.agentLabel} started in api · studio-mac'), findsOneWidget);
      expect(e.host('a').startCalls, 1);
      expect(e.store.memory.agents['a'], 'claude');

      await tester.tap(find.descendant(of: find.byKey(toastActionKey), matching: find.text('Open')));
      await _flush(tester);
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session.key, session.key);
      await e.tearDown(tester);
    });

    testWidgets('two agents back to back without leaving the board', (tester) async {
      final e = await _AgentEnv.create();
      await e.pump(tester, const HomeShell());

      await e.openFormFromBoard(tester);
      await _type(tester, 'Folder', '/home/dev/api');
      await _tap(tester, _button('Start'));
      await e.openFormFromBoard(tester);
      expect(_text(tester, 'Folder'), '/home/dev/api', reason: 'the last folder is remembered');
      await _type(tester, 'Folder', '/home/dev/web');
      await tester.tap(_chip('Codex'));
      await tester.pump();
      await _tap(tester, _button('Start'));
      await _flush(tester);

      expect(e.host('a').startCalls, 2);
      expect([for (final k in e.host('a').keepers.values) k.info.cwd], ['/home/dev/api', '/home/dev/web']);
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.textContaining('started in web · studio-mac'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('a failure stays on the form with the reason, and no toast', (tester) async {
      final e = await _AgentEnv.create();
      await e.pump(tester, const HomeShell());
      await e.openFormFromBoard(tester);
      e.host('a').startFailure = const AgentHostException('disk full');

      await _type(tester, 'Folder', '/home/dev/api');
      await _tap(tester, _button('Start'));

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(find.text('disk full'), findsOneWidget);
      expect(find.byKey(toastKey), findsNothing);
      expect(e.store.memory.folders, isEmpty);
      await e.tearDown(tester);
    });

    testWidgets('the toast is read once and stays clear of the tab bar pill', (tester) async {
      final semantics = tester.ensureSemantics();
      final e = await _AgentEnv.create();
      await e.pump(tester, const HomeShell());
      await e.openFormFromBoard(tester);
      await _type(tester, 'Folder', '/home/dev/api');
      await _tap(tester, _button('Start'));

      expect(find.bySemanticsLabel(RegExp('started in api')), findsOneWidget);
      final pill = tester.getRect(find.byType(FloatingTabBar));
      for (final part in [find.textContaining('started in'), find.descendant(of: find.byKey(toastActionKey), matching: find.text('Open'))]) {
        expect(tester.getRect(part).overlaps(pill), isFalse);
      }
      semantics.dispose();
      await e.tearDown(tester);
    });

    testWidgets('320dp at 2x text, a worst-case folder: the form and the toast fit', (tester) async {
      final e = await _AgentEnv.create();
      await e.pump(tester, const _Base(), width: 320, height: 568, scale: 2);
      await tester.tap(_button('Open form'));
      await _flush(tester);

      await _type(tester, 'Folder', _longFolder);
      for (final label in ['Start', 'Start and open']) {
        expect(tester.getRect(_button(label)).width, lessThanOrEqualTo(320));
      }
      await _tap(tester, _button('Start'));

      expect(tester.takeException(), isNull);
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      await e.tearDown(tester);
    });
  });

  group('chat: Duplicate', () {
    const folder = '/home/dev/Dự án/payments';

    Future<FakeAgentSession> sessionScreen(WidgetTester tester, _AgentEnv e, {String agent = 'codex'}) async {
      final session = FakeAgentSession(
        key: 'a/original',
        agent: agent,
        agentLabel: agent == 'codex' ? 'Codex' : 'Claude Code',
        cwd: folder,
        machine: e.h.fleet.connection('a'),
      );
      await e.pump(tester, AgentSessionScreen(session: session));
      return session;
    }

    Future<void> duplicate(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Session options'));
      await _flush(tester);
      await tester.tap(find.text('Duplicate'));
      await _flush(tester);
    }

    testWidgets('opens the form on the session\'s machine, folder and agent; backing out remembers nothing', (tester) async {
      final semantics = tester.ensureSemantics();
      final e = await _AgentEnv.create(
        machines: const [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')],
        memory: const AgentSessionMemory(machineId: 'b', agents: {'a': 'omp', 'b': 'claude'}, folders: {'a': '/old', 'b': '/srv/app'}),
      );
      await sessionScreen(tester, e);

      await duplicate(tester);

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Machine, studio-mac')), findsOneWidget, reason: 'not the build box used last');
      expect(_text(tester, 'Folder'), folder);
      expect(_selected(tester, 'Codex'), isTrue);
      expect(_selected(tester, 'omp'), isFalse);

      await tester.tap(find.byTooltip('Back'));
      await _flush(tester);
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(e.store.memory.machineId, 'b');
      expect(e.store.memory.agents, {'a': 'omp', 'b': 'claude'});
      expect(e.store.memory.folders, {'a': '/old', 'b': '/srv/app'});
      expect(e.host('a').startCalls, 0);
      semantics.dispose();
      await e.tearDown(tester);
    });

    testWidgets('starting from it starts a fresh session, stays on the chat it came from and remembers', (tester) async {
      final e = await _AgentEnv.create();
      final original = await sessionScreen(tester, e);

      await duplicate(tester);
      await _tap(tester, _button('Start'));

      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session, same(original));
      final started = e.repo.sessions.single;
      expect(started.key, isNot(original.key), reason: 'a new session, not the old one');
      expect(started.state.items, isEmpty, reason: 'never the old conversation');
      expect(e.host('a').keepers.values.single.info.cwd, folder);
      expect(e.host('a').keepers.values.single.info.agent, 'codex');
      expect(_toast('${started.agentLabel} started in payments · studio-mac'), findsOneWidget);
      expect(e.store.memory.folders['a'], folder);
      expect(e.store.memory.agents['a'], 'codex');
      await e.tearDown(tester);
    });

    testWidgets('Start and open goes to the new chat', (tester) async {
      final e = await _AgentEnv.create();
      await sessionScreen(tester, e);

      await duplicate(tester);
      await _tap(tester, _button('Start and open'));

      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session.key, e.repo.sessions.single.key);
      expect(find.byKey(toastKey), findsNothing);
      await e.tearDown(tester);
    });

    testWidgets('an offline machine: Duplicate is dimmed with the reason and does nothing', (tester) async {
      final e = await _AgentEnv.create();
      await sessionScreen(tester, e);
      e.h.fleet.connection('a')!.goOffline();
      await _flush(tester);

      await tester.tap(find.byTooltip('Session options'));
      await _flush(tester);

      expect(find.text('studio-mac is offline'), findsOneWidget);
      await tester.tap(find.text('Duplicate'));
      await _flush(tester);
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(find.text('Duplicate'), findsOneWidget, reason: 'the sheet is still up');
      await e.tearDown(tester);
    });

    testWidgets('a route id the app does not know falls back to what the form would have chosen', (tester) async {
      final e = await _AgentEnv.create();
      await e.pump(
        tester,
        const NewAgentSessionScreen(prefill: SessionPrefill(machineId: 'a', folder: folder, agent: 'not-a-route')),
      );

      expect(_text(tester, 'Folder'), folder);
      expect(_selected(tester, 'omp'), isTrue);
      await e.tearDown(tester);
    });

    testWidgets('a machine gone offline since: the form says so, keeps the folder and cannot start', (tester) async {
      final e = await _AgentEnv.create(machines: const [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')]);
      await e.pump(
        tester,
        const NewAgentSessionScreen(prefill: SessionPrefill(machineId: 'gone', folder: folder, agent: 'codex')),
      );

      expect(find.text('That machine went offline. Pick another.'), findsOneWidget);
      expect(_text(tester, 'Folder'), folder);
      expect(tester.widget<AppButton>(_button('Start')).onPressed, isNull);
      expect(tester.widget<AppButton>(_button('Start and open')).onPressed, isNull);
      await e.tearDown(tester);
    });

    testWidgets('a worst-case folder at 320dp and 2x text fits, and is kept whole', (tester) async {
      final e = await _AgentEnv.create(machines: const [(id: 'a', label: 'build-server-eu-west-2-primary-with-a-very-long-name')]);
      await e.pump(
        tester,
        const NewAgentSessionScreen(prefill: SessionPrefill(machineId: 'a', folder: _longFolder, agent: 'codex')),
        width: 320,
        height: 568,
        scale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(_text(tester, 'Folder'), _longFolder);
      for (final f in [_field('Folder'), _button('Start'), _button('Start and open')]) {
        await tester.ensureVisible(f);
        expect(tester.getRect(f).width, lessThanOrEqualTo(320));
      }
      expect(tester.takeException(), isNull);
      await e.tearDown(tester);
    });
  });
}

// ---------------------------------------------------------------------------

class _MemoryStore implements AgentSessionStore {
  AgentSessionMemory memory = const AgentSessionMemory();

  @override
  Future<AgentSessionMemory> read() async => memory;

  @override
  Future<void> write(AgentSessionMemory memory) async => this.memory = memory;
}

/// Machines on the board harness, with a fake keeper host each.
class _AgentEnv {
  _AgentEnv(this.h, this.repo, this.hosts, this.settings, this.store);

  final BoardHarness h;
  final AgentSessionRepository repo;
  final Map<String, FakeAgentHost> hosts;
  final AgentSessionSettings settings;
  final _MemoryStore store;

  FakeAgentHost host(String id) => hosts[id]!;

  static Future<_AgentEnv> create({
    List<({String id, String label})> machines = const [(id: 'a', label: 'studio-mac')],
    AgentSessionMemory memory = const AgentSessionMemory(),
  }) async {
    final h = await BoardHarness.create([
      for (final m in machines)
        (
          profile: MachineProfile(id: m.id, label: m.label, host: '${m.id}.example', username: 'dev'),
          snapshot: snapshotWith(const []),
        ),
    ]);
    final hosts = <String, FakeAgentHost>{};
    final repo = AgentSessionRepository(fleet: h.fleet, hostFor: (c) => hosts.putIfAbsent(c.profile.id, FakeAgentHost.new));
    final store = _MemoryStore()..memory = memory;
    final settings = AgentSessionSettings(store);
    await settings.load();
    return _AgentEnv(h, repo, hosts, settings, store);
  }

  /// Lets the machines connect (the forms only offer machines that are online),
  /// then shows [home].
  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    double width = 360,
    double height = 740,
    double scale = 1,
  }) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    _phone(tester, width, height);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ...h.providers,
          ListenableProvider<AgentSessions>.value(value: repo),
          ChangeNotifierProvider.value(value: settings),
          attentionSetProvider(),
        ],
        child: _app(home, brightness: Brightness.dark, scale: scale),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// From the board's plus.
  Future<void> openFormFromBoard(WidgetTester tester) async {
    await tester.tap(find.byTooltip('New agent session'));
    await _flush(tester);
  }

  Future<void> tearDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    repo.dispose();
    h.dispose();
  }
}
