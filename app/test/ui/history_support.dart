// Shared by the Past sessions and Continue tests and their shots: a scripted
// AgentSessions (what the agents remember, what a resume does), the machines
// of a board harness, and the screen mounted under them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_settings.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/history/past_sessions_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import 'board_support.dart';
import 'ui_harness.dart';

typedef HistoryCall = ({String machineId, String agent, String? cwd});
typedef ResumeCall = ({String machineId, String agent, String cwd, String sessionId, String? replaces});

/// [AgentSessions] whose agents remember what a test says and whose
/// [resume] does what a test says.
class ScriptedSessions extends FakeAgentSessions {
  ScriptedSessions() : super([]);

  /// Route ids every machine can run.
  Set<String> installed = {'omp', 'claude'};

  /// Thrown by `available` while set (the machine cannot say what it has).
  AgentHostException? availableError;

  /// What each agent answers to `history`, by route id; nothing remembered
  /// when absent.
  final answers = <String, PastSessions>{};

  /// Thrown by `history` while set.
  AgentHostException? historyError;

  /// `history` waits for this before it answers.
  Future<void>? historyGate;

  /// What `resume` does; throws when a test did not say.
  Future<AgentSessionView> Function(ResumeCall call)? onResume;

  final historyCalls = <HistoryCall>[];
  final resumeCalls = <ResumeCall>[];

  /// What `start` does; throws when a test did not say.
  Future<AgentSessionView> Function(({String machineId, String agent, String cwd}) call)? onStart;

  final startCalls = <({String machineId, String agent, String cwd})>[];

  /// Holds [session], as the repository does for a started keeper.
  void hold(AgentSessionView session) {
    sessions.add(session);
    notifyListeners();
  }

  @override
  Future<AgentSessionView> start({
    required MachineConnection machine,
    required String agent,
    required String cwd,
  }) {
    final call = (machineId: machine.profile.id, agent: agent, cwd: cwd);
    startCalls.add(call);
    final run = onStart;
    if (run == null) throw StateError('no start scripted');
    return run(call);
  }

  @override
  Future<Set<String>> available(MachineConnection machine) async {
    final error = availableError;
    if (error != null) throw error;
    return installed;
  }

  @override
  Future<PastSessions> history({required MachineConnection machine, required String agent, String? cwd}) async {
    historyCalls.add((machineId: machine.profile.id, agent: agent, cwd: cwd));
    await historyGate;
    final error = historyError;
    if (error != null) throw error;
    return answers[agent] ?? PastSessions(agent: agent, sessions: const []);
  }

  @override
  Future<AgentSessionView> resume({
    required MachineConnection machine,
    required String agent,
    required String cwd,
    required String sessionId,
    String? replaces,
  }) {
    final call = (machineId: machine.profile.id, agent: agent, cwd: cwd, sessionId: sessionId, replaces: replaces);
    resumeCalls.add(call);
    final run = onResume;
    if (run == null) throw StateError('no resume scripted');
    return run(call);
  }
}

class MemorySessionStore implements AgentSessionStore {
  AgentSessionMemory memory = const AgentSessionMemory();

  @override
  Future<AgentSessionMemory> read() async => memory;

  @override
  Future<void> write(AgentSessionMemory memory) async => this.memory = memory;
}

class HistoryEnv {
  HistoryEnv(this.h, this.sessions, this.settings);

  final BoardHarness h;
  final ScriptedSessions sessions;
  final AgentSessionSettings settings;

  MachineConnection machine([String id = 'a']) => h.fleet.connection(id)!;

  Future<void> tearDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  }
}

MachineProfile machineProfile(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Future<HistoryEnv> historyEnv({List<({String id, String label})> machines = const [(id: 'a', label: 'studio-mac')]}) async {
  final h = await BoardHarness.create([
    for (final m in machines) (profile: machineProfile(m.id, m.label), snapshot: snapshotWith(const [])),
  ]);
  final settings = AgentSessionSettings(MemorySessionStore());
  await settings.load();
  return HistoryEnv(h, ScriptedSessions(), settings);
}

/// Lets the machines connect (the screens only offer machines that are online).
Future<void> connectMachines(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> settleHistory(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// [home] under the providers of [e], at [size] and [textScale].
Future<void> pumpUnder(
  WidgetTester tester,
  HistoryEnv e,
  Widget home, {
  Size size = const Size(360, 800),
  double textScale = 1,
  Brightness brightness = Brightness.dark,
  bool connect = true,
  Key? boundary,
}) async {
  if (connect) await connectMachines(tester);
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ...e.h.providers,
        ListenableProvider<AgentSessions>.value(value: e.sessions),
        ChangeNotifierProvider.value(value: e.settings),
        attentionSetProvider(),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: home,
      ),
    ),
  );
  await settleHistory(tester);
}

Future<void> pumpPast(
  WidgetTester tester,
  HistoryEnv e, {
  Size size = const Size(360, 800),
  double textScale = 1,
  Brightness brightness = Brightness.dark,
  String? machineId,
  String? cwd,
  bool connect = true,
  Key? boundary,
}) => pumpUnder(
  tester,
  e,
  PastSessionsScreen(machineId: machineId, cwd: cwd),
  size: size,
  textScale: textScale,
  brightness: brightness,
  connect: connect,
  boundary: boundary,
);

PastSession past(
  String id, {
  String agent = 'omp',
  String cwd = '/home/dev/payments-api',
  String? title,
  Duration? ago = const Duration(minutes: 5),
  int? messages = 14,
}) => PastSession(
  agent: agent,
  sessionId: id,
  cwd: cwd,
  title: title,
  updatedAt: ago == null ? null : DateTime.now().subtract(ago),
  messageCount: messages,
);

PastSessions remembered(
  List<PastSession> sessions, {
  String agent = 'omp',
  bool canList = true,
  bool canLoad = true,
  bool canResume = false,
  bool more = false,
}) => PastSessions(
  agent: agent,
  sessions: sessions,
  canList: canList,
  canLoad: canLoad,
  canResume: canResume,
  more: more,
);
