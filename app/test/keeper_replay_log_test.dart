@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// The bounded replay log of the REAL keeper script (python3).

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  // A long, tool-heavy chat used to lose its first turns: the log kept the
  // newest 4000 entries / 4 MB and dropped the oldest whole entries first.
  group('history', skip: hasPython ? false : 'python3 is not installed', () {
    Future<KeeperAttach> detached(KeeperHost h, String id, int turns, String spec) async {
      final a = await h.attach(id);
      await a.initialize();
      await a.newSession(h);
      for (var i = 0; i < turns; i++) {
        await a.response(a.prompt('heavy:$spec:$i'), timeout: const Duration(seconds: 120));
      }
      await a.close();
      return a;
    }

    Future<Replay> replay(KeeperHost h, String id) async {
      final c = await h.attach(id);
      await c.initialize();
      final load = await c.load(h);
      final updates = c.seen.where(isMethod('session/update')).toList();
      await c.close();
      return (
        load: load,
        updates: updatesOf(updates),
        bytes: updates.fold(0, (n, m) => n + jsonEncode(m).length),
      );
    }

    test('a zipped attach replays the same messages in a fraction of the bytes, and leaves small ones alone', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 3, '28:20:100');

      Future<(KeeperAttach, Json)> open({required bool zipped}) async {
        final c = await h.attach(info.id, zipped: zipped);
        await c.initialize();
        final load = await c.load(h);
        return (c, load);
      }

      final (plain, plainLoad) = await open(zipped: false);
      await plain.close();
      final (zipped, zippedLoad) = await open(zipped: true);
      addTearDown(zipped.close);

      expect(zipped.seen, plain.seen, reason: 'what the app reads is what it always read');
      expect(zippedLoad, plainLoad);
      expect(plain.wire, greaterThan(200 * 1024), reason: 'a replay worth zipping');
      expect(zipped.wire, lessThan(plain.wire ~/ 4), reason: 'plain JSON text deflates well');

      // A message that is not worth it travels as it is, a line of its own, and
      // the stream keeps working after it.
      final before = zipped.wire;
      final answer = await zipped.request('session/list');
      expect(asJson(answer['result']), isNotNull);
      expect(zipped.wire - before, lessThan(1024));
    });

    test('twelve heavy turns: every question and answer comes back, the replay stays small', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 12, '28:20:100');
      final r = await replay(h, info.id);

      final turns = turnsOf(r.updates);
      expect(turns.map((t) => t.user), [for (var i = 0; i < 12; i++) 'heavy:28:20:100:$i']);
      for (var i = 0; i < 12; i++) {
        expect(turns[i].answer, 'answer $i', reason: 'turn $i');
      }
      final herdr = herdrMeta(r.load);
      expect(herdr['droppedTurns'], 0);
      // The soft budget (1.5 MB) is what a replay costs: the 21 MB of output
      // of 12 turns became one whole turn (1.8 MB) and eleven skeletons.
      expect(r.bytes, lessThanOrEqualTo(2500 * 1024));
      expect(r.bytes, greaterThan(1024 * 1024), reason: 'the newest turn is whole');

      // Every turn but the newest kept its rows and lost what made it heavy.
      final trimmed = [for (final t in turns) if (t.tools.any(isTrimmed)) t];
      expect(trimmed, hasLength(11));
      expect(herdr['trimmedTurns'], 11);
      for (final t in turns.take(11)) {
        expect(t.tools.every(isTrimmed), isTrue, reason: t.user);
      }
      final first = turns.first.tools;
      expect(first.map((u) => u['toolCallId']).toSet(), hasLength(28), reason: 'every call keeps one row');
      expect(first, hasLength(28), reason: 'progress ticks of finished calls are merged');
      for (final u in first) {
        expect(u['status'], 'completed');
        expect(u['title'], startsWith('Run: step '));
        expect(u['locations'], isNotEmpty);
        expect(u.containsKey('rawOutput'), isFalse);
        expect(jsonEncode(u).length, lessThan(1500));
        expect(asJson(asJson(u['_meta'])['herdr'])['trimmed'], isTrue);
      }
      // The command a row is named by survives; the 3000-byte script does not.
      expect(asJson(first.first['rawInput'])['command'], 'step 0');
      expect(asJson(first.first['rawInput']).containsKey('script'), isFalse);

      // The newest turn is whole: every call's output is there, untouched.
      final newest = turns.last;
      expect(newest.tools.any(isTrimmed), isFalse);
      final done = newest.tools.where((u) => u['status'] == 'completed').toList();
      expect(done, hasLength(28));
      for (final u in done) {
        final out = u['rawOutput'] ?? updateText(asJson((u['content'] as List).first));
        expect((out as String).length, greaterThanOrEqualTo(20 * 1024));
      }
      expect(newest.tools, hasLength(28 * 3), reason: 'nothing merged in a turn that was not cut');
    });

    test('with the soft budget raised to the hard one, detail stays until 16 MB: the newest turns are whole', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_SOFT_BYTES': '${16 * 1024 * 1024}'});
      final info = await h.start();
      await detached(h, info.id, 12, '28:20:100');
      final r = await replay(h, info.id);

      final turns = turnsOf(r.updates);
      expect(turns, hasLength(12));
      expect(turns.last.answer, 'answer 11');
      expect(r.bytes, lessThanOrEqualTo(16 * 1024 * 1024));
      expect(r.bytes, greaterThan(12 * 1024 * 1024));
      expect(herdrMeta(r.load)['trimmedTurns'], lessThan(5), reason: 'only what the hard bound forced');
      for (final t in turns.skip(9)) {
        expect(t.tools.any(isTrimmed), isFalse, reason: t.user);
      }
    });

    test('a flood of 200 turns stays inside the bounds, keeps whole turns, and counts what it dropped', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '2097152', 'HERDR_KEEPER_LOG_MESSAGES': '1500'});
      final info = await h.start();
      await detached(h, info.id, 200, '10:1:3');
      final r = await replay(h, info.id);

      expect(r.updates.length, lessThanOrEqualTo(1500));
      expect(r.bytes, lessThanOrEqualTo(2097152));
      final turns = turnsOf(r.updates);
      final herdr = herdrMeta(r.load);
      final dropped = herdr['droppedTurns']! as int;
      expect(dropped, greaterThan(0));
      // Whole turns, newest first kept: nothing in the middle is missing.
      expect(dropped + turns.length, 200);
      expect(turns.map((t) => t.user), [for (var i = dropped; i < 200; i++) 'heavy:10:1:3:$i']);
      for (final t in turns) {
        expect(t.answer, 'answer ${t.user.split(':').last}', reason: t.user);
        expect(t.tools.map((u) => u['toolCallId']).toSet(), hasLength(10), reason: '${t.user} keeps every call');
      }
      expect(herdr['trimmedTurns'], turns.where((t) => t.tools.any(isTrimmed)).length);
      // The newest turn is never cut. (The entry bound, unlike the byte
      // budgets, also cuts the turns before it, to save entries.)
      expect(turns.last.tools.any(isTrimmed), isFalse, reason: turns.last.user);
      expect(turns.last.tools, hasLength(30));
    });

    test('a turn in flight that alone passes the soft budget is untouched; the older turns are trimmed', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 3, '28:20:100');
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      b.prompt('heavyhold:28:20:100:open');
      await b.next((m) {
        if (m['method'] != 'session/update') return false;
        final u = asJson(asJson(m['params'])['update']);
        return u['toolCallId'] == 'topen-27' && u['status'] == 'completed';
      });
      await b.close();

      final r = await replay(h, info.id);
      final turns = turnsOf(r.updates);
      expect(turns.map((t) => t.user), [
        'heavy:28:20:100:0',
        'heavy:28:20:100:1',
        'heavy:28:20:100:2',
        'heavyhold:28:20:100:open',
      ]);
      final open = turns.last;
      expect(open.tools, hasLength(28 * 3));
      expect(open.tools.any(isTrimmed), isFalse);
      expect(turns.take(3).every((t) => t.tools.every(isTrimmed)), isTrue);
      expect(herdrMeta(r.load), {'droppedTurns': 0, 'trimmedTurns': 3});
      expect(r.bytes, greaterThan(1536 * 1024), reason: 'the open turn is over the soft budget by itself');
    });

    test('the turn in flight is never trimmed or dropped', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '400000'});
      final info = await h.start();
      await detached(h, info.id, 40, '10:20:40');
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      b.prompt('heavyhold:10:20:40:open');
      await b.next((m) {
        if (m['method'] != 'session/update') return false;
        final u = asJson(asJson(m['params'])['update']);
        return u['toolCallId'] == 'topen-9' && u['status'] == 'completed';
      });
      await b.close();

      final r = await replay(h, info.id);
      final turns = turnsOf(r.updates);
      final open = turns.last;
      expect(open.user, 'heavyhold:10:20:40:open');
      expect(open.answer, isNull, reason: 'it has not answered yet');
      expect(open.tools, hasLength(30));
      expect(open.tools.any(isTrimmed), isFalse);
      for (final u in open.tools.where((u) => u['status'] == 'completed')) {
        expect(u['rawOutput'] ?? updateText(asJson((u['content'] as List).first)), isA<String>());
      }
      expect(herdrMeta(r.load)['droppedTurns']! as int, greaterThan(0), reason: 'older turns went, to make room');
      for (final t in turns.where((t) => t != open)) {
        expect(t.answer, 'answer ${t.user.split(':').last}', reason: 'older turns that stay are whole');
      }
    });

    test('taking a refused prompt back keeps the turns and counters consistent', () async {
      final dir = Directory.systemTemp.createTempSync('keeper_log_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/keeper.py')..writeAsStringSync(keeperScript());
      final probe = File('${dir.path}/probe.py')..writeAsStringSync(removeProbe);
      final r = await Process.run('python3', [probe.path, script.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = asJson(jsonDecode(r.stdout as String));
      List<Object?> sound(Json t) => [t['bytesOk'], t['countOk'], t['lastOk']];

      final refused = asJson(out['refused']);
      expect(refused['turns'], 1, reason: 'what the agent streamed meanwhile joins the turn before');
      expect(refused['texts'], ['first', 'answer', 'own 0', 'own 1', 'own 2']);
      expect(sound(refused), [true, true, true]);

      final alone = asJson(out['alone']);
      expect(alone['turns'], 0);
      expect(sound(alone), [true, true, true]);
      final again = asJson(out['aloneThenAdd']);
      expect(again['texts'], ['after']);
      expect(sound(again), [true, true, true]);

      expect(out['sameEntry'], isTrue);
      final two = asJson(out['twoBlocks']);
      expect(two['texts'], ['before', 'reply']);
      expect(sound(two), [true, true, true]);

      expect(out['ghost'], [false, true]);

      final bounded = asJson(out['bounded']);
      expect(sound(bounded), [true, true, true]);
      expect(out['boundedDropped'], 0, reason: 'forty refused attempts took no room from the four real turns');
      expect((bounded['texts'] as List).where((t) => (t as String).startsWith('q')), hasLength(4));
    });

    test('the log is plain python that can be loaded: pinned turns, state carry, and the hot path', () async {
      final dir = Directory.systemTemp.createTempSync('keeper_log_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/keeper.py')..writeAsStringSync(keeperScript());
      final probe = File('${dir.path}/probe.py')..writeAsStringSync(logProbe);
      final r = await Process.run('python3', [probe.path, script.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = asJson(jsonDecode(r.stdout as String));

      // A request waits on a tool call of the OLDEST turn: that turn stays,
      // whole, while the others make room.
      final pinned = asJson(out['pinned']);
      expect(pinned['oldHasRaw'], isTrue);
      expect(pinned['oldKept'], isTrue);
      expect(pinned['otherDropped'], greaterThan(0));
      expect(pinned['newestKept'], isTrue);
      expect(pinned["bytes"], lessThanOrEqualTo(30000));
      // The last mode and command list of the dropped turns still reach a replay.
      for (final key in ['carryWhole', 'carryCut']) {
        final c = asJson(out[key]);
        expect(c['carry'], ['available_commands_update', 'current_mode_update'], reason: key);
        expect(c['mode'], ['plan'], reason: key);
        expect(['available_commands_update', 'current_mode_update'], contains(c['first']), reason: '$key: state replays before the turns');
      }
      expect(asJson(out['carryWhole'])['dropped'], greaterThan(0));
      // Heavy turns: every question stays; the newest turn keeps all its output.
      final fat = asJson(out['fat']);
      expect(fat['users'], 12);
      expect(fat['dropped'], 0);
      expect(fat['newestRaw'], 28);
      expect(fat['bytes'], lessThanOrEqualTo(2500 * 1024), reason: 'one whole turn and skeletons');
      // 600 heavy turns under the soft budget: all there, one whole, none dropped.
      final soft = asJson(out['soft']);
      expect(soft['turns'], 600);
      expect(soft['dropped'], 0);
      expect(soft['trimmed'], 599);
      expect(soft['bytes'] as int, lessThanOrEqualTo((soft['newestBytes'] as int) + 600 * 12 * 1024));
      expect(soft['seconds'], lessThan(20));
      // Nothing re-scans the log per update: 60000 updates, bounded at 20000 entries.
      expect(out['seconds'], lessThan(20));
      expect(out['count'], lessThanOrEqualTo(20000));
      expect(out['hotDropped'], greaterThan(0));
    });
  });
}
