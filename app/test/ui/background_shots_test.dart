// Renders background work to PNGs for review, light and dark: nothing, one
// job, two, forty, a 4,000-character Vietnamese command with a bidi override
// (closed and open), a long id, an unknown start, the waiting state with its
// two-line strip, Stopping / Could not confirm / Already finished, and the
// narrow (320x640) and compact (landscape, keyboard up) layouts. Off by
// default; it writes files:
//
//   BACKGROUND_SHOTS=1 flutter test test/ui/background_shots_test.dart
//
// Output: $BACKGROUND_SHOTS_DIR (default /tmp/bg_shots)/<case>-<light|dark>.png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/prompt_queue.dart' show SendDelivery;
import 'package:herdr_mobile/data/acp/acp_models.dart' show StopReason;
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/acp/session_state.dart' show AgentSessionState;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/background_strip.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'hold_support.dart';

void main() {
  if (Platform.environment['BACKGROUND_SHOTS'] == null) {
    test('background shots are off (set BACKGROUND_SHOTS=1)', () {}, skip: 'set BACKGROUND_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['BACKGROUND_SHOTS_DIR'] ?? '/tmp/bg_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final now = DateTime.now();

  // The session of the scenario that is rendering (its steps act on it).
  late FakeAgentSession current;
  BackgroundTask task(
    String id, {
    BackgroundKind kind = BackgroundKind.shell,
    BackgroundStatus status = BackgroundStatus.running,
    String? title,
    String? detail,
    StopRoute stop = StopRoute.direct,
    Duration? ago = const Duration(hours: 4, minutes: 36),
    Duration? ran,
  }) => BackgroundTask(
    id: id,
    kind: kind,
    status: status,
    title: title ?? 'python3 run.py --screen s1t --chunk 1 --out /data/results/$id.json',
    detail: detail,
    stop: stop,
    startedAt: ago == null ? null : now.subtract(ago),
    endedAt: ran == null || ago == null ? null : now.subtract(ago).add(ran),
  );

  BackgroundWork work(List<BackgroundTask> tasks, {bool wakes = true, String? label = 'omp', bool unknown = false}) =>
      BackgroundWork(tasks: tasks, wakes: wakes, wakeLabel: label, unknownRunning: unknown);

  AgentSessionState state({bool turn = false}) => stateWith(
    items: [
      userMsg('u1', 'Run the screening in the background and tell me when it is done.'),
      agentMsg('a1', 'Started `bg_6`. Its output is injected as a follow-up the moment it finishes.'),
    ],
    turnActive: turn,
  );

  FakeAgentSession session({bool turn = false, bool terminal = false}) {
    final s = FakeAgentSession(state: state(turn: turn), agent: 'omp', agentLabel: 'omp');
    if (terminal) {
      s
        ..observed = true
        ..paneId = 'p1'
        ..forcedDelivery = SendDelivery.now;
    }
    return s;
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeAgentSession session,
    Brightness brightness, {
    Size size = const Size(412, 892),
    double scale = 1,
    Future<void> Function()? then,
    bool keyboard = false,
    int settleMs = 600,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    if (keyboard) tester.view.viewInsets = const FakeViewPadding(bottom: 160 * dpr);
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => RepaintBoundary(
          key: key,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: AgentSessionScreen(key: ObjectKey(session), session: session),
      ),
    );
    await tester.pump(tapGuard);
    await tester.pump(const Duration(milliseconds: 100));
    await then?.call();
    await tester.pump(Duration(milliseconds: settleMs));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name-${brightness.name}.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name}');
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(BackgroundStrip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  final viet = [
    for (var i = 0; i < 60; i++)
      'python3 chạy_thử_nghiệm.py --màn-hình s${i}t --đoạn $i --tên "Nguyễn Thị Hương Giang" --thư-mục "/dữ-liệu/kết-quả/lần-$i" \u202Eexe.txt',
  ].join('\n').substring(0, 4000);

  // Shots taken mid-hold: no settling time, or the hold would complete.
  const held = {'sheet-stop-held', 'sheet-stop-all-held'};
  final scenarios = <String, (FakeAgentSession Function(), Future<void> Function(WidgetTester)?, Size, double, bool)>{
    // 0 tasks: the screen with no strip.
    'zero': (() => session(), null, const Size(412, 892), 1, false),
    // 1 task while the turn runs: one line.
    'one-running-turn': (
      () => session(turn: true)..backgroundWork = work([task('bg_6')]),
      null,
      const Size(412, 892),
      1,
      false,
    ),
    // The case of the report: the turn is over, a job runs, omp will resume.
    'waiting-two-lines': (
      () => session(terminal: true, turn: true)
        ..backgroundWork = work([task('bg_6')])
        ..waitingOnBackground = true,
      null,
      const Size(412, 892),
      1,
      false,
    ),
    'waiting-two-lines-large-text': (
      () => session(terminal: true, turn: true)
        ..backgroundWork = work([task('bg_6')])
        ..waitingOnBackground = true,
      null,
      const Size(412, 892),
      1.6,
      false,
    ),
    'waiting-unknown': (
      () => session(terminal: true, turn: true)
        ..backgroundWork = work(const [], unknown: true)
        ..waitingOnBackground = true,
      null,
      const Size(412, 892),
      1,
      false,
    ),
    'waiting-no-wake-terminal': (
      () => session()..backgroundWork = work([task('t1', kind: BackgroundKind.terminal, ago: const Duration(minutes: 3))], wakes: false),
      null,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-one': (
      () => session()..backgroundWork = work([task('bg_6')]),
      open,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-two-mixed': (
      () => session()
        ..backgroundWork = work([
          task('bg_6', stop: StopRoute.message),
          task('bg_7', kind: BackgroundKind.eval, title: 'for i in range(10): train(i)', ago: const Duration(minutes: 14)),
          task('RLFrameworks', kind: BackgroundKind.agent, title: 'Survey RL frameworks for the screening', stop: StopRoute.none, ago: const Duration(seconds: 40)),
          task('f1', status: BackgroundStatus.finished, title: 'sleep 31', ago: const Duration(minutes: 20), ran: const Duration(seconds: 31)),
          task('f2', status: BackgroundStatus.failed, title: 'make test', ago: const Duration(minutes: 30), ran: const Duration(seconds: 12)),
          task('f3', status: BackgroundStatus.stopped, title: 'tail -f /var/log/syslog', ago: const Duration(hours: 1), ran: const Duration(minutes: 5)),
        ]),
      open,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-forty': (
      () => session()
        ..backgroundWork = work([
          for (var i = 0; i < 40; i++)
            task('bg_$i', title: 'python3 run.py --screen s${i}t --chunk $i', ago: Duration(minutes: 5 + i * 7)),
          for (var i = 0; i < 7; i++)
            task('f$i', status: i == 3 ? BackgroundStatus.failed : BackgroundStatus.finished, title: 'finished job $i', ago: const Duration(hours: 9), ran: Duration(seconds: 31 + i)),
        ]),
      open,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-forty-scrolled': (
      () => session()
        ..backgroundWork = work([
          for (var i = 0; i < 40; i++) task('bg_$i', title: 'python3 run.py --screen s${i}t --chunk $i', ago: Duration(minutes: 5 + i * 7)),
        ]),
      (tester) async {
        await open(tester);
        await tester.drag(find.byType(ListView).last, const Offset(0, -900));
        await tester.pump();
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-vietnamese-bidi-closed': (
      () => session()..backgroundWork = work([task('bg_6', title: viet), task('bg_7')]),
      open,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-vietnamese-bidi-open': (
      () => session()..backgroundWork = work([task('bg_6', title: viet), task('bg_7')]),
      (tester) async {
        await open(tester);
        await tester.tap(find.textContaining('python3 chạy_thử_nghiệm.py').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-vietnamese-bidi-read-all': (
      () => session()..backgroundWork = work([task('bg_6', title: viet)]),
      (tester) async {
        await open(tester);
        await tester.tap(find.textContaining('python3 chạy_thử_nghiệm.py').first);
        await tester.pump();
        await tester.tap(find.text('Read all'));
        await tester.pump();
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-long-id': (
      () => session()
        ..backgroundWork = work([
          task('background_job_for_the_nightly_screening_of_all_chunks_${'0123456789' * 4}', ago: const Duration(minutes: 70)),
          task('bg_\u202E6', title: 'sleep 9999'),
        ]),
      open,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-unknown-start': (
      () => session()..backgroundWork = work([task('bg_6', ago: null), task('bg_7', ago: null, stop: StopRoute.message)]),
      open,
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-stopping': (
      () => session()..backgroundWork = work([task('bg_6'), task('bg_7')]),
      (tester) async {
        await open(tester);
        await holdFor(tester, find.text('Stop').first);
        await tester.pump();
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-could-not-confirm': (
      () => session()..backgroundWork = work([task('bg_6'), task('bg_7')]),
      (tester) async {
        await open(tester);
        await holdFor(tester, find.text('Stop').first);
        await tester.pump(const Duration(seconds: 13));
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-already-finished': (
      () => session()
        ..stopResult = const BackgroundAlreadyDone()
        ..backgroundWork = work([task('bg_6'), task('bg_7')]),
      (tester) async {
        await open(tester);
        await holdFor(tester, find.text('Stop').first);
        await tester.pump();
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-stop-held': (
      () => session()..backgroundWork = work([task('bg_6'), task('bg_7')]),
      (tester) async {
        await open(tester);
        final g = await pressAndHold(tester, find.text('Stop').first, const Duration(milliseconds: 450));
        await tester.pump();
        addTearDown(() => g.up());
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-stop-all-held': (
      () => session()..backgroundWork = work([task('bg_6'), task('bg_7'), task('bg_8', stop: StopRoute.none)]),
      (tester) async {
        await open(tester);
        final g = await pressAndHold(tester, find.text('Stop all'), const Duration(milliseconds: 450));
        await tester.pump();
        addTearDown(() => g.up());
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-stop-all-done': (
      () => session()..backgroundWork = work([task('bg_6'), task('bg_7'), task('bg_8', stop: StopRoute.none)]),
      (tester) async {
        await open(tester);
        await holdFor(tester, find.text('Stop all'));
        await tester.pump();
      },
      const Size(412, 892),
      1,
      false,
    ),
    'sheet-disconnected': (
      () => session()..backgroundWork = work([task('bg_6'), task('bg_7')]),
      (tester) async {
        await open(tester);
        current.setLink(AgentLink.reconnecting);
        await tester.pump();
      },
      const Size(412, 892),
      1,
      false,
    ),
    'narrow-sheet': (
      () => session()..backgroundWork = work([task('bg_6', stop: StopRoute.message), task('bg_7', title: viet.substring(0, 300))]),
      open,
      const Size(320, 640),
      1,
      false,
    ),
    'narrow-waiting': (
      () => session(terminal: true, turn: true)
        ..backgroundWork = work([task('bg_6'), task('bg_7')])
        ..waitingOnBackground = true,
      null,
      const Size(320, 640),
      1,
      false,
    ),
    'compact-landscape': (
      () => session(turn: true)..backgroundWork = work([task('bg_6'), task('bg_7')]),
      null,
      const Size(800, 400),
      1,
      true,
    ),
    'compact-landscape-waiting-with-subagents': (
      () => (session(terminal: true, turn: true)
        ..backgroundWork = work([task('bg_6')])
        ..waitingOnBackground = true
        ..roster = const [SubagentEntry(info: SubagentInfo(name: 'RLFrameworks'), state: SubagentState.running)]),
      null,
      const Size(800, 400),
      1,
      true,
    ),
    'toast-after-stop': (
      () => session(turn: true)..backgroundWork = work([task('bg_6'), task('bg_7')]),
      (tester) async {
        await tester.tap(find.byIcon(LucideIcons.square));
        await tester.pump();
        current.update((s) => s.withTurnEnded(StopReason.cancelled));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
      const Size(412, 892),
      1,
      false,
    ),
  };

  for (final brightness in Brightness.values) {
    for (final entry in scenarios.entries) {
      testWidgets('${entry.key} ${brightness.name}', (tester) async {
        final (make, then, size, scale, keyboard) = entry.value;
        final s = current = make();
        await shoot(
          tester,
          entry.key,
          s,
          brightness,
          size: size,
          scale: scale,
          keyboard: keyboard,
          settleMs: held.contains(entry.key) ? 10 : 600,
          then: then == null ? null : () => then(tester),
        );
      });
    }
  }
}
