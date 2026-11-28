// The heavy tests drive 12 to 200 real turns through the keeper (the `herdr-host` binary); the
// default 30 s per test is what a busy machine runs out of, not a hang.
@Timeout(Duration(minutes: 5))
@TestOn('linux || mac-os')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/keeper_harness.dart';

// The bounded replay log of the keeper (the `herdr-host` binary) as a client
// that attaches later sees it. The log's own rules are the Rust suite's.

void main() {
  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  // A long, tool-heavy chat used to lose its first turns: the log kept the
  // newest 4000 entries / 4 MB and dropped the oldest whole entries first.
  group('history', () {
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
      final load = await c.load(h, timeout: const Duration(seconds: 120));
      final updates = c.seen.where(isMethod('session/update')).toList();
      await c.close();
      return (load: load, updates: updatesOf(updates), bytes: updates.fold(0, (n, m) => n + jsonEncode(m).length));
    }

    test('a long transcript replays whole through the link, and a short request answers after it', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 3, '28:20:100');

      Future<(KeeperAttach, Json)> open() async {
        final c = await h.attach(info.id);
        await c.initialize();
        final load = await c.load(h);
        return (c, load);
      }

      final (first, firstLoad) = await open();
      await first.close();
      final (second, secondLoad) = await open();
      addTearDown(second.close);

      expect(second.seen, first.seen, reason: 'every client reads the same replay');
      expect(secondLoad, firstLoad);
      expect(jsonEncode(first.seen).length, greaterThan(200 * 1024), reason: 'a replay worth streaming');
      final turns = turnsOf(updatesOf(first.seen.where(isMethod('session/update'))));
      expect(turns.map((t) => t.user), [for (var i = 0; i < 3; i++) 'heavy:28:20:100:$i']);

      // The stream keeps working after the long replay.
      final answer = await second.request('session/list');
      expect(asJson(answer['result']), isNotNull);
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
      final trimmed = [
        for (final t in turns)
          if (t.tools.any(isTrimmed)) t,
      ];
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

    test(
      'a turn in flight that alone passes the entry bound eats its own oldest entries, not the conversation before it',
      () async {
        // omp streams every chunk of a long command as an update, so one long
        // turn can hold more entries than the bound. Dropping the turns before it
        // cannot make that fit; it only loses the questions and answers.
        final h = await newHost({'HERDR_KEEPER_LOG_MESSAGES': '600'});
        final info = await h.start();
        await detached(h, info.id, 6, '2:1:1');
        final b = await h.attach(info.id);
        await b.initialize();
        await b.load(h);
        b.prompt('heavyhold:300:1:1:long');
        await b.next((m) {
          if (m['method'] != 'session/update') return false;
          final u = asJson(asJson(m['params'])['update']);
          return u['toolCallId'] == 'tlong-299' && u['status'] == 'completed';
        });
        await b.close();

        final r = await replay(h, info.id);
        final turns = turnsOf(r.updates);
        expect(herdrMeta(r.load)['droppedTurns'], 0, reason: 'no turn before it was dropped');
        expect(turns.map((t) => t.user), [for (var i = 0; i < 6; i++) 'heavy:2:1:1:$i', 'heavyhold:300:1:1:long']);
        for (var i = 0; i < 6; i++) {
          expect(turns[i].answer, 'answer $i', reason: 'turn $i keeps its answer');
        }
        expect(
          turns.last.tools.length,
          lessThan(300 * 3),
          reason: 'the open turn gave up its oldest entries (300 calls, 3 updates each)',
        );
        expect(turns.last.tools, isNotEmpty);
      },
    );
  });
}
