// Background work on the session screen: the strip's states, the sheet with
// its held Stop, Send instead of Stop
// while the agent waits, the words in the bar and the status line, and the toast
// after Stop.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart' show AgentSessionState;
import 'package:herdr_mobile/data/acp/prompt_queue.dart' show SendDelivery;
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart' show toastKey;
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/background_strip.dart';
import 'package:herdr_mobile/ui/features/agents/agent_session_rows.dart' show sessionStateLabel;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'hold_support.dart';

BackgroundTask task(
  String id, {
  BackgroundKind kind = BackgroundKind.shell,
  BackgroundStatus status = BackgroundStatus.running,
  String? title,
  String? detail,
  StopRoute stop = StopRoute.direct,
  DateTime? startedAt,
  DateTime? endedAt,
}) => BackgroundTask(
  id: id,
  kind: kind,
  status: status,
  title: title ?? 'python3 run.py --job $id',
  detail: detail,
  stop: stop,
  startedAt: startedAt,
  endedAt: endedAt,
);

BackgroundWork work(List<BackgroundTask> tasks, {bool wakes = false, String? label, bool unknown = false}) =>
    BackgroundWork(tasks: tasks, wakes: wakes, wakeLabel: label, unknownRunning: unknown);

Future<void> pump(WidgetTester tester, FakeAgentSession session, {Size size = const Size(412, 892)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump(tapGuard);
}

/// A sheet or a route starts on the frame after the change.
Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.byType(BackgroundStrip));
  await settle(tester);
}

AgentSessionState _state({bool turn = false}) => stateWith(items: [userMsg('u1', 'go')], turnActive: turn);

FakeAgentSession idle() => FakeAgentSession(state: _state());
FakeAgentSession working() => FakeAgentSession(state: _state(turn: true));

/// An agent in a terminal that says `working` while it waits on a job.
FakeAgentSession waitingTerminal() => FakeAgentSession(state: _state(turn: true))
  ..observed = true
  ..paneId = 'p1'
  ..forcedDelivery = SendDelivery.now;

Finder get stripIcon => find.descendant(of: find.byType(BackgroundStrip), matching: find.byIcon(LucideIcons.layers));

void main() {
  setUpAll(loadAppFonts);
  group('the strip, state by state', () {
    testWidgets('no turn, nothing running: no strip, no room taken', (tester) async {
      final session = idle();
      await pump(tester, session);
      expect(stripIcon, findsNothing);
      expect(tester.getSize(find.byType(BackgroundStrip)).height, 0);
    });

    testWidgets('turn runs, nothing in the background: none', (tester) async {
      final session = working();
      await pump(tester, session);
      expect(stripIcon, findsNothing);
    });

    testWidgets('turn runs, 2 running: one line', (tester) async {
      final session = working();
      session.backgroundWork = work([task('bg_1'), task('bg_2')], wakes: true, label: 'omp');
      await pump(tester, session);
      expect(find.text('2 running in background'), findsOneWidget);
      expect(find.textContaining('continues by itself'), findsNothing, reason: 'the turn runs: nothing to promise yet');
      expect(find.text('Send', skipOffstage: false), findsNothing);
    });

    testWidgets('waiting and it wakes: two lines, the second is the consequence; Send, not Stop', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6')], wakes: true, label: 'omp');
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(find.text('1 running in background'), findsOneWidget);
      expect(find.text('omp continues by itself when it finishes'), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget, reason: 'Send');
      expect(find.byIcon(LucideIcons.square), findsNothing, reason: 'there is no turn to stop');
    });

    testWidgets('idle with a background terminal that does not wake: one line', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('t1', kind: BackgroundKind.terminal)]);
      await pump(tester, session);
      expect(find.text('1 background terminal running'), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget);
    });

    testWidgets('waiting on something unlisted: details unavailable', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work(const [], unknown: true);
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(find.text('Background work \u00b7 details unavailable'), findsOneWidget);
    });

    testWidgets('it appears and goes without a height animation', (tester) async {
      final session = idle();
      await pump(tester, session);
      session.setBackground(work([task('bg_1')]));
      await tester.pump();
      expect(find.text('1 background terminal running'), findsNothing, reason: 'a job is a job');
      expect(find.text('1 job running'), findsOneWidget, reason: 'there on the very next frame');
      expect(find.descendant(of: find.byType(BackgroundStrip), matching: find.byType(AnimatedSize)), findsNothing);
      session.setBackground(BackgroundWork.empty);
      await tester.pump();
      expect(stripIcon, findsNothing);
    });

    testWidgets('it rebuilds for the work, the waiting flag and the link, not for every notification', (tester) async {
      final session = working();
      session.backgroundWork = work([task('bg_1')]);
      await pump(tester, session);
      final before = tester.element(find.byType(BackgroundStrip)).widget;
      session.update((s) => s); // a notification that changes nothing the strip reads
      await tester.pump();
      expect(tester.element(find.byType(BackgroundStrip)).widget, same(before));
      expect(find.text('1 running in background'), findsOneWidget);
      session.setBackground(work([task('bg_1'), task('bg_2')]));
      await tester.pump();
      expect(find.text('2 running in background'), findsOneWidget);
    });

    testWidgets('one semantics node: what it is, how many, how to open it', (tester) async {
      final handle = tester.ensureSemantics();
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6')], wakes: true, label: 'omp');
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(
        find.bySemanticsLabel('Background work, 1 running, omp continues by itself when it finishes, double tap to open'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('1 running in background'), findsNothing, reason: 'the visible lines are inside the one node');
      handle.dispose();
    });

    testWidgets('compact layout: no strip, a chip in the bar instead', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_1'), task('bg_2')]);
      await pump(tester, session, size: const Size(800, 400));
      expect(find.text('2 jobs running'), findsOneWidget, reason: 'roomy: the strip');
      expect(find.text('2 jobs'), findsNothing);

      tester.view.viewInsets = const FakeViewPadding(bottom: 160 * 2);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pump();
      expect(find.text('2 jobs running'), findsNothing, reason: 'compact: the strip is hidden');
      expect(find.text('2 jobs'), findsOneWidget, reason: 'the bar carries the count');
    });
  });

  group('the bar and the status line', () {
    final started = DateTime.now().subtract(const Duration(minutes: 14, seconds: 30));

    testWidgets('waiting says what and for how long, in the status line', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6', startedAt: started)], wakes: true, label: 'omp');
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(find.text('Waiting for bg_6'), findsOneWidget);
      expect(find.text(' \u00b7 14m'), findsOneWidget, reason: 'its clock, by the minute');
      expect(find.textContaining('Working'), findsNothing);
    });

    testWidgets('several jobs: their count, from the oldest start', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([
        task('bg_6', startedAt: started),
        task('bg_7', startedAt: started.add(const Duration(minutes: 10))),
      ]);
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(find.text('Waiting for 2 jobs'), findsOneWidget);
      expect(find.text(' \u00b7 14m'), findsOneWidget, reason: 'the status line');
    });

    testWidgets('unknown work: Waiting, with no clock', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work(const [], unknown: true);
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(find.text('Waiting for background work'), findsOneWidget);
    });

    testWidgets('an unknown start has no clock', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6')]);
      session.waitingOnBackground = true;
      await pump(tester, session);
      expect(find.textContaining(' \u00b7 0'), findsNothing);
      expect(find.text('Waiting for bg_6'), findsOneWidget);
    });

    testWidgets('a running turn keeps the activity line, and no Waiting', (tester) async {
      final session = working();
      session.backgroundWork = work([task('bg_6', startedAt: started)]);
      await pump(tester, session);
      expect(find.textContaining('Waiting'), findsNothing);
      expect(find.text('Working'), findsOneWidget);
    });

    testWidgets('the wait ends: the line goes back to nothing', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6', startedAt: started)]);
      session.waitingOnBackground = true;
      await pump(tester, session);
      session.setBackground(BackgroundWork.empty);
      await tester.pump();
      expect(find.textContaining('Waiting'), findsNothing);
    });
  });

  group('Send, not Stop', () {
    testWidgets('a terminal agent that waits can be written to; the keyboard send goes through', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6')], wakes: true, label: 'omp');
      session.waitingOnBackground = true;
      await pump(tester, session);
      await tester.enterText(find.byType(TextField).last, 'status?');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(session.sent, ['status?']);
    });

    testWidgets('while its turn runs a terminal agent has Stop, and nothing is sent', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      expect(find.byIcon(LucideIcons.square), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowUp), findsNothing);
      await tester.enterText(find.byType(TextField).last, 'status?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(session.sent, isEmpty, reason: 'a turn is running: Stop, not Send');
    });

    testWidgets('Stop stays a plain tap', (tester) async {
      final session = working();
      await pump(tester, session);
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump();
      expect(session.cancelCount, 1);
    });
  });

  group('the sheet', () {
    testWidgets('lists what runs, says once what the agent does, and the footer', (tester) async {
      final session = idle();
      session.backgroundWork = work(
        [task('bg_6', startedAt: DateTime.now().subtract(const Duration(hours: 4, minutes: 36)))],
        wakes: true,
        label: 'omp',
      );
      session.waitingOnBackground = true;
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Background work \u00b7 1'), findsOneWidget);
      expect(find.text('omp continues by itself when a job finishes.'), findsOneWidget);
      expect(find.text('Running \u00b7 1'), findsOneWidget);
      expect(find.text('python3 run.py --job bg_6'), findsOneWidget);
      expect(find.text('bash \u00b7 bg_6 \u00b7 4h 36m'), findsOneWidget);
      expect(
        find.text('Stop on the message bar ends the turn only. Work listed here keeps running until you stop it.'),
        findsOneWidget,
      );
      expect(find.textContaining('has no stop key'), findsNothing, reason: 'only the message route says it');
      expect(find.byIcon(LucideIcons.squareTerminal), findsOneWidget);
    });

    testWidgets('the message route says what Stop does, in the chip and once in the footer', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6', stop: StopRoute.message), task('bg_7', stop: StopRoute.message)]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Ask to stop'), findsNWidgets(2));
      expect(
        find.text('Claude Code has no stop key for this. The phone sends Claude Code a message asking it to.'),
        findsOneWidget,
      );
    });

    testWidgets('a task with no stop route shows no Stop and no hint', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6', stop: StopRoute.none)]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Stop'), findsNothing);
      expect(find.textContaining('Hold'), findsNothing);
      expect(find.text('python3 run.py --job bg_6'), findsOneWidget);
    });

    testWidgets('Stop is a hold: a tap says how and stops nothing; the hold stops', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);

      await quickTap(tester, find.text('Stop'));
      expect(find.text('Hold to stop'), findsOneWidget);
      expect(session.stopped, isEmpty);
      await advance(tester, holdHintWindow());

      final gesture = await pressAndHold(tester, find.text('Stop'), const Duration(milliseconds: 300));
      expect(session.stopped, isEmpty, reason: 'half way');
      await advance(tester, const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
      expect(session.stopped, ['bg_6']);
      expect(find.text('Stopping\u2026'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
    });

    testWidgets('letting go early stops nothing', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      final gesture = await pressAndHold(tester, find.text('Stop'), const Duration(milliseconds: 400));
      await gesture.up();
      await advance(tester, const Duration(milliseconds: 300));
      expect(session.stopped, isEmpty);
    });

    testWidgets('Stopping… ends when the task leaves running', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      await holdFor(tester, find.text('Stop'));
      expect(find.text('Stopping\u2026'), findsOneWidget);

      session.setBackground(
        work([task('bg_6', status: BackgroundStatus.stopped)]),
      );
      await tester.pump();
      expect(find.text('Stopping\u2026'), findsNothing);
      expect(find.text('Could not confirm'), findsNothing);
      expect(find.text('Finished \u00b7 1'), findsOneWidget);
      expect(find.textContaining('stopped'), findsOneWidget);
    });

    testWidgets('after 12 s: Could not confirm and Retry, which asks again', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      await holdFor(tester, find.text('Stop'));
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('Stopping\u2026'), findsOneWidget, reason: 'still waiting');
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Stopping\u2026'), findsNothing);
      expect(find.text('Could not confirm'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(session.stopped, ['bg_6', 'bg_6']);
      expect(find.text('Stopping\u2026'), findsOneWidget);
    });

    testWidgets('a refused stop says so at once, with its reason', (tester) async {
      final session = idle()..stopResult = const BackgroundStopFailed('The host did not answer.');
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      await holdFor(tester, find.text('Stop'));
      await tester.pump();
      expect(find.text('Could not confirm \u00b7 The host did not answer.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('a task that ended meanwhile says Already finished, not an error', (tester) async {
      final session = idle()..stopResult = const BackgroundAlreadyDone();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      await holdFor(tester, find.text('Stop'));
      await tester.pump();
      expect(find.text('Already finished'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Could not confirm'), findsNothing);
      expect(find.text('Stopping\u2026'), findsNothing);
    });

    testWidgets('Stop all is held, acts on the stoppable ones and reports the rest', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('a'), task('b'), task('c', stop: StopRoute.none)]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Stop all'), findsOneWidget);

      await quickTap(tester, find.text('Stop all'));
      expect(session.stopAllCount, 0, reason: 'a tap only says how');
      await advance(tester, holdHintWindow());

      await holdFor(tester, find.text('Stop all'));
      await tester.pump();
      expect(session.stopAllCount, 1);
      expect(find.text('Stopped 2 \u00b7 1 has no stop control'), findsOneWidget);
      expect(find.text('Stopping\u2026'), findsNWidgets(2));
      expect(find.text('Stop all'), findsNothing, reason: 'nothing left to stop all of');
    });

    testWidgets('one stoppable task: no Stop all', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('a'), task('c', stop: StopRoute.none)]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Stop all'), findsNothing);
    });

    testWidgets('a screen reader: the first activation primes, the second stops', (tester) async {
      final handle = tester.ensureSemantics();
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);

      tester.semantics.tap(find.semantics.byLabel('Stop bg_6, hold to confirm'));
      await tester.pump();
      expect(session.stopped, isEmpty);
      expect(find.text('Hold or tap again'), findsOneWidget);
      expect(find.bySemanticsLabel('Confirm: Stop bg_6, activate again to confirm'), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel('Confirm: Stop bg_6, activate again to confirm'));
      await tester.pump();
      expect(session.stopped, ['bg_6']);
      handle.dispose();
    });

    testWidgets('a primed stop lapses after its window', (tester) async {
      final handle = tester.ensureSemantics();
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      tester.semantics.tap(find.semantics.byLabel('Stop bg_6, hold to confirm'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.bySemanticsLabel('Stop bg_6, hold to confirm'), findsOneWidget);
      expect(session.stopped, isEmpty);
      handle.dispose();
    });

    testWidgets('every touch target is at least 44 dp', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('a'), task('b')]);
      await pump(tester, session);
      await openSheet(tester);
      for (final label in ['Stop', 'Stop all']) {
        for (final e in find.text(label).evaluate()) {
          final box = find.ancestor(of: find.byWidget(e.widget), matching: find.byType(Listener)).first;
          expect(tester.getSize(box).height, greaterThanOrEqualTo(44), reason: label);
        }
      }
    });

    testWidgets('a tap opens the full command; Read all past six lines; the first line says it once', (tester) async {
      final session = idle();
      final lines = [for (var i = 1; i <= 12; i++) 'echo step $i'];
      session.backgroundWork = work([task('bg_6', title: lines.join('\n'))]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('echo step 1'), findsOneWidget);
      expect(find.textContaining('echo step 2'), findsNothing, reason: 'closed: the first line only');

      await tester.tap(find.text('echo step 1'));
      await tester.pump();
      expect(find.textContaining('echo step 12'), findsOneWidget);
      expect(find.text('echo step 1'), findsNothing, reason: 'the open text replaces the title');
      expect(find.text('Read all'), findsOneWidget);
      final clamped = tester.renderObject<RenderParagraph>(find.textContaining('echo step 12'));
      expect(clamped.didExceedMaxLines, isTrue);

      await tester.tap(find.text('Read all'));
      await tester.pump();
      expect(find.text('Read all'), findsNothing);
      expect(tester.renderObject<RenderParagraph>(find.textContaining('echo step 12')).didExceedMaxLines, isFalse);

      await tester.tap(find.textContaining('echo step 12'));
      await tester.pump();
      expect(find.text('echo step 1'), findsOneWidget, reason: 'closed again');
    });

    testWidgets('a hostile command is shown with its hidden characters made visible', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_\u202E6', title: 'rm \u202E-rf /tmp/x')]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('rm \u2039U+202E\u203a-rf /tmp/x'), findsOneWidget);
      expect(find.textContaining('bg_\u2039U+202E\u203a6'), findsWidgets);
    });

    testWidgets('finished: failed first, five at most, then Show more', (tester) async {
      final session = idle();
      final t0 = DateTime(2026, 1, 1, 10);
      session.backgroundWork = work([
        for (var i = 0; i < 7; i++)
          task(
            'f$i',
            title: 'finished job $i',
            status: i == 2 ? BackgroundStatus.failed : BackgroundStatus.finished,
            startedAt: t0,
            endedAt: t0.add(Duration(seconds: 31 + i)),
          ),
      ]);
      await pump(tester, session);
      expect(find.byType(BackgroundStrip), findsOneWidget);
      session.setBackground(session.backgroundWork.copyWith(unknownRunning: true));
      await tester.pump();
      await openSheet(tester);
      expect(find.text('Finished \u00b7 7'), findsOneWidget);
      expect(find.text('Show 2 more'), findsOneWidget);
      expect(find.text('finished job 2'), findsOneWidget);
      expect(find.text('finished job 0'), findsNothing, reason: 'oldest of the same end is last');
      expect(
        tester.getTopLeft(find.text('finished job 2')).dy,
        lessThan(tester.getTopLeft(find.text('finished job 6')).dy),
        reason: 'failed first',
      );
      expect(find.textContaining('finished \u00b7 37s'), findsOneWidget);
      expect(find.textContaining('failed'), findsOneWidget);

      await tester.tap(find.text('Show 2 more'));
      await tester.pump();
      await tester.drag(find.byType(ListView).last, const Offset(0, -400));
      await tester.pump();
      expect(find.text('finished job 0'), findsOneWidget);
      expect(find.text('Show fewer'), findsOneWidget);
    });

    testWidgets('40 tasks: the list is lazy', (tester) async {
      final session = idle();
      session.backgroundWork = work([for (var i = 0; i < 40; i++) task('bg_$i')]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Background work \u00b7 40'), findsOneWidget);
      final built = find.byIcon(LucideIcons.squareTerminal).evaluate().length;
      expect(built, greaterThan(0));
      expect(built, lessThan(20), reason: 'only the rows near the screen exist');
      await tester.drag(find.byType(ListView).last, const Offset(0, -3000));
      await tester.pump();
      expect(find.text('python3 run.py --job bg_39'), findsOneWidget);
    });

    testWidgets('a subagent that has its own roster opens it instead of expanding', (tester) async {
      final session = waitingTerminal();
      session.roster = const [
        SubagentEntry(info: SubagentInfo(name: 'RLFrameworks'), state: SubagentState.running),
      ];
      session.backgroundWork = work([
        task('RLFrameworks', kind: BackgroundKind.agent, title: 'Survey RL frameworks', stop: StopRoute.none),
      ]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.byIcon(LucideIcons.bot)), findsOneWidget);
      await tester.tap(find.text('Survey RL frameworks'));
      await settle(tester);
      expect(find.text('Background work \u00b7 1'), findsNothing, reason: 'the sheet closed');
      expect(find.text('Subagents'), findsOneWidget, reason: 'the existing roster');
    });

    testWidgets('a machine that is not reachable: the last list, no actions', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      expect(find.text('Stop'), findsOneWidget);
      session.setLink(AgentLink.reconnecting);
      await tester.pump();
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Not connected. This is the last known list.'), findsOneWidget);
      expect(find.text('python3 run.py --job bg_6'), findsOneWidget);
    });

    testWidgets('unknown work: says details are unavailable', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work(const [], unknown: true);
      session.waitingOnBackground = true;
      await pump(tester, session);
      await openSheet(tester);
      expect(find.textContaining('Details are unavailable'), findsOneWidget);
    });

    testWidgets('everything finishing while it is open leaves a plain sentence, not an error', (tester) async {
      final session = idle();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await openSheet(tester);
      session.setBackground(BackgroundWork.empty);
      await tester.pump();
      expect(find.text('Nothing is running in the background.'), findsOneWidget);
    });
  });

  group('the toast after Stop', () {
    Future<void> stopAndEnd(WidgetTester tester, FakeAgentSession session) async {
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump();
      session.update((s) => s.withTurnEnded(StopReason.cancelled));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('Turn stopped · 1 job still running, with View, once', (tester) async {
      final session = working();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(toastKey), findsNothing, reason: 'the turn has not ended yet');

      session.update((s) => s.withTurnEnded(StopReason.cancelled));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Turn stopped \u00b7 1 job still running'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);

      // Later notifications do not say it again.
      session.setBackground(work([task('bg_6'), task('bg_7')]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.text('Turn stopped \u00b7 1 job still running'), findsOneWidget);
    });

    testWidgets('View opens the sheet', (tester) async {
      final session = working();
      session.backgroundWork = work([task('bg_6'), task('bg_7')]);
      await pump(tester, session);
      await stopAndEnd(tester, session);
      expect(find.text('Turn stopped \u00b7 2 jobs still running'), findsOneWidget);
      await tester.tap(find.text('View'));
      await settle(tester);
      expect(find.text('Background work \u00b7 2'), findsOneWidget);
    });

    testWidgets('nothing left running: no toast', (tester) async {
      final session = working();
      await pump(tester, session);
      await stopAndEnd(tester, session);
      expect(find.byKey(toastKey), findsNothing);
    });

    testWidgets('a turn that ends by itself is not a Stop: no toast', (tester) async {
      final session = working();
      session.backgroundWork = work([task('bg_6')]);
      await pump(tester, session);
      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(toastKey), findsNothing);
    });

    testWidgets('an agent in a terminal: the turn ends into waiting, the toast comes', (tester) async {
      final session = waitingTerminal();
      session.backgroundWork = work([task('bg_6')], wakes: true, label: 'omp');
      await pump(tester, session);
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump();
      session
        ..update((s) => s.withTurnEnded(StopReason.cancelled))
        ..setBackground(session.backgroundWork, waiting: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Turn stopped \u00b7 1 job still running'), findsOneWidget);
    });
  });

  group('the board row', () {
    final now = DateTime(2026, 10, 5, 12, 30);

    test('says waiting, with the time, while the turn is over and a job runs', () {
      final s = idle()
        ..phaseSinceValue = now.subtract(const Duration(minutes: 14))
        ..setBackground(work([task('bg_6')]), waiting: true);
      expect(sessionStateLabel(s, now), 'waiting 14m');
    });

    test('says idle when nothing waits, and working while the turn runs', () {
      final s = idle()..phaseSinceValue = now.subtract(const Duration(minutes: 14));
      expect(sessionStateLabel(s, now), 'idle 14m');
      final w = working()
        ..phaseSinceValue = now.subtract(const Duration(minutes: 3))
        ..setBackground(work([task('bg_6')]));
      expect(sessionStateLabel(w, now), 'working 3m');
    });
  });
}

Duration holdHintWindow() => const Duration(milliseconds: 2500);
