// Opening an agent's terminal from the board feels instant: the first frame
// already has text (marked as saved until a read lands), the read starts when
// the finger goes down, and the likeliest next taps are warm. The radio cost
// of each of those is counted here: reads per open, per scroll, in the
// background, with the board covered.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_tails.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'package:herdr_mobile/ui/features/pane/answer_dock.dart';

import '../support/fake_network.dart';
import '../support/memory_stores.dart';
import '../support/pane_open_rig.dart';
import '../support/terminal_rows.dart';
import 'ui_harness.dart';

/// `row 000` … `row 119` (more than a screen), then [extra].
String _rows([List<String> extra = const []]) =>
    [for (var i = 0; i < 120; i++) 'row ${'$i'.padLeft(3, '0')}', ...extra].join('\n');

/// A scenario on a board with one agent: [body] runs against it and the app
/// is torn down after (a timer must not outlive the test).
void _scenario(String name, Future<void> Function(OpenRig rig) body, {String status = 'working', String text = ''}) =>
    testWidgets(name, (tester) async {
      final rig = await OpenRig.start(tester, status: status, text: text);
      await body(rig);
      await rig.close();
    });

void main() {
  group('the first frame', () {
    _scenario('a pane opened again paints its last tail on the first frame, marked as saved', (rig) async {
      final tester = rig.tester;
      rig.herdr.paneText = _rows();
      await tester.tap(rig.row);
      await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
      expect(terminalRow('row 119'), findsOneWidget);
      expect(rig.live, findsNothing, reason: 'a read landed: it is live');
      await rig.back();

      // The link is slow now: the next read does not come back.
      rig.herdr
        ..gate = Completer<void>()
        ..paneText = _rows(['row 120']);
      rig.clock.now = rig.clock.now.add(const Duration(seconds: 12));
      await tester.tap(rig.row);
      await rig.firstFrame();

      expect(terminalRow('row 119'), findsOneWidget, reason: 'the first frame has the text');
      expect(find.textContaining(RegExp(r'^stale · \d+s$')), findsOneWidget, reason: 'and says how old it is');

      rig.herdr.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(terminalRow('row 120'), findsOneWidget);
      expect(rig.live, findsNothing, reason: 'live once the read lands');
    });

    _scenario('with only the card\'s rows, the first frame shows them, marked as saved', (rig) async {
      final tester = rig.tester;
      rig.herdr.paneText = 'alpha\nbeta';
      // A card of this pane was on screen a moment ago.
      final card = rig.previews.watch(openMachine.id, openPane);
      await rig.elapse(const Duration(seconds: 2));
      card.release();
      expect(rig.previews.known(openMachine.id, openPane), isNotNull);
      expect(rig.herdr.tailReads, isEmpty);

      rig.herdr
        ..gate = Completer<void>()
        ..paneText = 'alpha\nbeta\ngamma';
      await tester.tap(rig.row);
      await rig.firstFrame();

      expect(terminalRow('beta'), findsOneWidget);
      expect(find.textContaining('stale ·'), findsOneWidget);

      rig.herdr.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(terminalRow('gamma'), findsOneWidget);
      expect(rig.live, findsNothing);
    });

    _scenario('a pane never seen paints nothing to mark: no saved copy, no mark', (rig) async {
      final tester = rig.tester;
      rig.herdr
        ..gate = Completer<void>()
        ..paneText = _rows();
      await tester.tap(rig.row);
      await rig.firstFrame();
      expect(terminalRow('row 119'), findsNothing);
      expect(rig.live, findsNothing, reason: 'there is no copy to mark');
      rig.herdr.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(terminalRow('row 119'), findsOneWidget);
    });

    _scenario('the live read finding the same rows moves nothing', (rig) async {
      final tester = rig.tester;
      rig.herdr.paneText = _rows();
      await tester.tap(rig.row);
      await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
      await rig.back();

      rig.herdr.gate = Completer<void>();
      await tester.tap(rig.row);
      await rig.firstFrame();
      final before = [
        for (final n in ['row 100', 'row 110', 'row 119']) tester.getTopLeft(terminalRow(n)),
      ];

      rig.herdr.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(rig.live, findsNothing);
      expect([
        for (final n in ['row 100', 'row 110', 'row 119']) tester.getTopLeft(terminalRow(n)),
      ], before);
    });

    _scenario('new output arriving with the live read keeps the view at the live end', (rig) async {
      final tester = rig.tester;
      rig.herdr.paneText = _rows();
      await tester.tap(rig.row);
      await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
      await rig.back();

      rig.herdr
        ..gate = Completer<void>()
        ..paneText = _rows(['row 120', 'row 121']);
      await tester.tap(rig.row);
      await rig.firstFrame();
      final lastBefore = tester.getTopLeft(terminalRow('row 119'));

      rig.herdr.gate!.complete();
      await tester.pump();
      await tester.pump();
      // The newest row sits where the newest row sat: the two new rows
      // pushed the old ones up, nothing jumped past them.
      expect(tester.getTopLeft(terminalRow('row 121')).dy, lastBefore.dy);
      expect(tester.getTopLeft(terminalRow('row 119')).dy, lessThan(lastBefore.dy));
    });

    _scenario(
      'an answer on a saved first frame sends nothing',
      (rig) async {
        final tester = rig.tester;
        await tester.tap(rig.row.first);
        await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
        final answer = find.descendant(of: find.byType(AnswerDock), matching: find.text('1. Yes'));
        expect(answer, findsOneWidget, reason: 'the live question is docked above the keys');
        await rig.back();

        rig.herdr.gate = Completer<void>();
        await tester.tap(rig.row.first);
        await rig.firstFrame();
        expect(find.textContaining('stale ·'), findsOneWidget, reason: 'the first frame is a saved copy');
        // The saved copy carries the question in its rows, but nothing on it
        // answers: if the dock shows its chips, they are deaf until the screen
        // has been read again.
        if (answer.evaluate().isNotEmpty) await tester.tap(answer, warnIfMissed: false);
        await tester.pump();
        expect(rig.herdr.calls.where((c) => c.$1 == 'pane.send_keys' || c.$1 == 'pane.send_input'), isEmpty);
        rig.herdr.gate!.complete();
        await tester.pump();
      },
      status: 'blocked',
      // What Claude draws when it asks to run a command.
      text:
          ' Bash command\n   ls -la\n\n Do you want to proceed?\n'
          ' ❯ 1. Yes\n   2. Yes, and don\'t ask again for ls commands\n'
          '   3. No, and tell Claude what to do differently (esc)\n',
    );
  });

  group('a finger going down on an agent', () {
    _scenario('starts the read before the tap, and the screen it opens joins it', (rig) async {
      final tester = rig.tester;
      rig.herdr
        ..gate = Completer<void>()
        ..paneText = _rows();
      final finger = await tester.startGesture(tester.getCenter(rig.row));
      expect(rig.reads, 0, reason: 'not before the press has lasted a moment');
      await tester.pump(const Duration(milliseconds: 60));
      expect(rig.reads, 1, reason: 'the read is on its way while the finger is still down');

      await finger.up();
      await tester.pump();
      await tester.pump();
      expect(rig.reads, 1, reason: 'the screen joined it: one read per open, not two');
      rig.herdr.gate!.complete();
      await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
      expect(terminalRow('row 119'), findsOneWidget);
      expect(rig.live, findsNothing);
    });

    _scenario('a quick tap costs one read, the screen\'s own', (rig) async {
      final tester = rig.tester;
      rig.herdr.paneText = _rows();
      await tester.tap(rig.row);
      await rig.elapse(const Duration(milliseconds: 300), step: const Duration(milliseconds: 50));
      expect(rig.reads, 1);
      expect(terminalRow('row 119'), findsOneWidget);
    });

    _scenario('a press that becomes a scroll reads nothing', (rig) async {
      final tester = rig.tester;
      final finger = await tester.startGesture(tester.getCenter(rig.row));
      await finger.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 200));
      await finger.up();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.reads, 0);
    });

    _scenario('a slow scroll costs at most one read per agent per few seconds', (rig) async {
      final tester = rig.tester;
      for (var i = 0; i < 3; i++) {
        final finger = await tester.startGesture(tester.getCenter(rig.row));
        await tester.pump(const Duration(milliseconds: 80));
        await finger.moveBy(const Offset(0, -60));
        await finger.up();
        await tester.pump(const Duration(milliseconds: 100));
        rig.clock.now = rig.clock.now.add(const Duration(milliseconds: 180));
      }
      expect(rig.reads, 1, reason: 'the second and third press found it read a moment ago');
    });

    _scenario('in the background nothing is read', (rig) async {
      final tester = rig.tester;
      rig.previews.onLifecycleState(AppLifecycleState.paused);
      final finger = await tester.startGesture(tester.getCenter(rig.row));
      await tester.pump(const Duration(milliseconds: 200));
      expect(rig.reads, 0, reason: 'held down in the background: nothing is sent');
      await finger.moveBy(const Offset(0, -60));
      await finger.up();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.reads, 0);
    });
  });

  group('warming the likeliest next taps', () {
    _scenario('a blocked agent on the board has its tail read once, then now and then', (rig) async {
      expect(rig.reads, 1, reason: 'read when the board showed it waiting');
      await rig.elapse(const Duration(seconds: 28));
      expect(rig.reads, 1, reason: 'a tail younger than 30 s is not read again');
      await rig.elapse(const Duration(seconds: 4));
      expect(rig.reads, 2);
      await rig.elapse(const Duration(minutes: 1));
      expect(rig.reads, 4, reason: 'two reads a minute for one waiting agent, at most');
    }, status: 'blocked');

    _scenario('a working or idle agent is never warmed', (rig) async {
      await rig.elapse(const Duration(minutes: 2));
      expect(rig.reads, 0);
    }, status: 'working');

    _scenario('the tap that follows opens on the warm tail', (rig) async {
      final tester = rig.tester;
      expect(rig.reads, 1);
      rig.herdr.gate = Completer<void>();
      await rig.elapse(const Duration(seconds: 2));
      await tester.tap(rig.row.first);
      await rig.firstFrame();
      expect(find.textContaining('stale ·'), findsOneWidget, reason: 'saved text on the first frame, marked');
      rig.herdr.gate!.complete();
      await tester.pump();
    }, status: 'blocked');

    _scenario('with the board covered nothing is warmed', (rig) async {
      expect(rig.reads, 1);
      await rig.coverBoard();
      expect(rig.previews.tails.ticking, isFalse);
      final before = rig.reads;
      await rig.elapse(const Duration(minutes: 2));
      expect(rig.reads, before);
    }, status: 'blocked');

    _scenario('in the background nothing is warmed, and coming back reads once', (rig) async {
      expect(rig.reads, 1);
      rig.previews.onLifecycleState(AppLifecycleState.paused);
      expect(rig.previews.tails.ticking, isFalse);
      await rig.elapse(const Duration(minutes: 2));
      expect(rig.reads, 1, reason: 'nothing while the app is away');
      rig.previews.onLifecycleState(AppLifecycleState.resumed);
      await rig.elapse(const Duration(seconds: 1));
      expect(rig.reads, 2, reason: 'the kept tail is old: one read on return');
    }, status: 'blocked');
  });

  group('the kept tails', () {
    late FleetRepository fleet;

    Future<MachineConnection> machine(WidgetTester tester, GatedHerdr herdr) async {
      final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      await machines.load();
      late MachineConnection conn;
      fleet = FleetRepository(
        machines: machines,
        network: FakeNetwork(),
        connect: (profile, secrets) => conn = MachineConnection(
          profile: profile,
          api: HerdrApi(herdr),
          backoff: (_) => const Duration(hours: 1),
          pollInterval: const Duration(hours: 1),
        ),
      );
      await machines.save(openMachine, secrets: const MachineSecrets(password: 'x'));
      await fleet.settled();
      await tester.pump(const Duration(milliseconds: 100));
      return conn;
    }

    testWidgets('are bounded in panes and in bytes, least recently read out first', (tester) async {
      final herdr = GatedHerdr(
        snapshotWith([for (var i = 0; i < 12; i++) (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: 'working')]),
      );
      final conn = await machine(tester, herdr);
      final tails = PaneTails(connection: (_) => conn, preview: (_, _) => null, maxPanes: 8, maxBytes: 4000);
      for (var i = 0; i < 12; i++) {
        herdr.paneText = 'x' * 300;
        await tails.read(conn, 'w1:p$i', ReadSource.recent, paneTailRows);
        expect(tails.keptPanes, lessThanOrEqualTo(8));
        expect(tails.keptBytes, lessThanOrEqualTo(4000));
      }
      expect(tails.seed(openMachine.id, 'w1:p11', wrap: false), isNotNull, reason: 'the newest is kept');
      expect(tails.seed(openMachine.id, 'w1:p0', wrap: false), isNull, reason: 'the oldest went first');
      // 300 characters is 600 bytes: six fit in 4000.
      expect(tails.keptPanes, 6);
      fleet.dispose();
    });

    testWidgets('go with their machine, and with their pane', (tester) async {
      final herdr = GatedHerdr(snapshotWith([(id: openPane, ws: 'w1', agent: 'claude', status: 'working')]));
      final conn = await machine(tester, herdr);
      var listed = true;
      MachineConnection? found = conn;
      final tails = PaneTails(connection: (_) => found, preview: (_, _) => null);
      herdr.paneText = 'one';
      await tails.read(conn, openPane, ReadSource.recent, paneTailRows);
      expect(tails.keptPanes, 1);
      tails.prune();
      expect(tails.keptPanes, 1, reason: 'still listed');

      // The pane is closed on the machine.
      herdr.snapshot = snapshotWith(const []);
      herdr.emit(const {'event': 'pane.closed'});
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(conn.paneById(openPane), isNull);
      tails.prune();
      expect(tails.keptPanes, 0);

      herdr.snapshot = snapshotWith([(id: openPane, ws: 'w1', agent: 'claude', status: 'working')]);
      herdr.emit(const {'event': 'pane.created'});
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tails.read(conn, openPane, ReadSource.recent, paneTailRows);
      expect(tails.keptPanes, 1);
      // The machine is removed.
      found = null;
      listed = false;
      tails.prune();
      expect(tails.keptPanes, 0);
      expect(listed, isFalse);
      fleet.dispose();
    });

    testWidgets('a status other than blocked never warms', (tester) async {
      final herdr = GatedHerdr(snapshotWith([(id: openPane, ws: 'w1', agent: 'claude', status: 'idle')]));
      final conn = await machine(tester, herdr);
      expect(conn.paneById(openPane)?.status, AgentStatus.idle);
      final tails = PaneTails(connection: (_) => conn, preview: (_, _) => null);
      tails.board(inFront: true, targets: [(machine: conn, paneId: openPane)]);
      await tester.pump(const Duration(minutes: 1));
      expect(herdr.tailReads, isEmpty);
      tails.dispose();
      fleet.dispose();
    });
  });
}
