@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// The alert hook of the REAL keeper script (python3).

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  group('alert hook', skip: hasPython ? false : 'python3 is not installed', () {
    const record = r'''printf '%s|%s|%s|%s|%s|%s\n' "$KEEPER_EVENT" "$KEEPER_ID" "$KEEPER_AGENT" "$KEEPER_CWD" "$KEEPER_TITLE" "$KEEPER_SUMMARY" >> "$HOME/hook.out"''';

    List<List<String>> events(KeeperHost h) {
      final f = File(h.hookOut);
      if (!f.existsSync()) return [];
      return [
        for (final l in f.readAsLinesSync())
          if (l.isNotEmpty) l.split('|'),
      ];
    }

    test('fires when a request is held, with the environment and a redacted summary', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p = a.prompt(
        'perm:curl -H "Authorization: Bearer abcdef1234567890" https://u:pw@x.io?token=zzz1234 sk-abcdefghijklmnop12',
      );
      final perm = await a.next(isMethod('session/request_permission'));
      await eventually(() => events(h).isNotEmpty, what: 'the hook to run');
      final e = events(h).single;
      expect(e[0], 'blocked');
      expect(e[1], info.id);
      expect(e[2], 'omp');
      expect(e[3], h.work);
      expect(e[5], contains('curl'));
      for (final secret in ['abcdef1234567890', 'pw@', 'zzz1234', 'sk-abcdefghijklmnop12']) {
        expect(e[5], isNot(contains(secret)), reason: e[5]);
      }
      expect(e[5].length, lessThanOrEqualTo(120));
      a.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(p);
      // The user was looking: no "done".
      // Absence of a hook cannot be polled for: wait a minimum time (a loaded
      // machine only makes it longer, never flaky).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(events(h), hasLength(1));
    });

    test('a question reports its first line', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('ask');
      final perm = await a.next(isMethod('session/request_permission'));
      a.reply(perm['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      await eventually(() => events(h).length == 2, what: 'two hooks');
      // Each event runs the hook as a process of its own, started a moment
      // apart, and the file is appended to by whichever finishes first: its
      // line order is the order the processes ended, not the order of the
      // events. So the lines are told apart by what they say.
      final byLine = {for (final e in events(h)) e[5]: e};
      expect(byLine.keys, unorderedEquals(['Run: ls -la', 'Pick one?']));
      expect(byLine['Run: ls -la']![0], 'blocked');
      expect(byLine['Pick one?']![0], 'blocked');
      expect(byLine['Pick one?']![4], 'Fake title');
    });

    test('fires "done" when a turn ends while nobody is attached', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('sleep:1');
      await a.close();
      await eventually(() => events(h).isNotEmpty, what: 'the done hook');
      final e = events(h).single;
      expect(e.sublist(0, 4), ['done', info.id, 'omp', h.work]);
      expect(e[5], 'Turn finished (end_turn)');
    });

    test('~/.herdr-mobile/on-blocked is the default and must be executable', () async {
      final h = await newHost({'HERDR_KEEPER_ON_BLOCKED': ''});
      Directory('${h.home.path}/.herdr-mobile').createSync();
      final path = '${h.home.path}/.herdr-mobile/on-blocked';
      File(path).writeAsStringSync('#!/bin/sh\n$record\n'); // not executable yet
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p1 = a.prompt('perm:first');
      final perm1 = await a.next(isMethod('session/request_permission'));
      a.reply(perm1['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(p1);
      // Absence of a hook cannot be polled for: wait a minimum time (a loaded
      // machine only makes it longer, never flaky).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(events(h), isEmpty);

      await Process.run('chmod', ['755', path]);
      final p2 = a.prompt('perm:second');
      final perm2 = await a.next(isMethod('session/request_permission'));
      a.reply(perm2['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(p2);
      await eventually(() => events(h).isNotEmpty, what: 'the default hook');
      expect(events(h).single[5], 'second');
    });

    test('a hook that hangs is killed after 5 s and never blocks the keeper', () async {
      final h = await newHost();
      await h.writeHook('echo \$\$ > "\$HOME/hook.pid"\nexec sleep 30');
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p = a.prompt('perm:slow hook');
      final perm = await a.next(isMethod('session/request_permission'));
      final pidFile = File('${h.home.path}/hook.pid');
      await eventually(() => pidFile.existsSync() && pidFile.readAsStringSync().trim().isNotEmpty, what: 'hook pid');
      final pid = int.parse(pidFile.readAsStringSync().trim());
      expect(await processAlive(pid), isTrue);
      // The keeper still serves while the hook hangs: the answer reaches the
      // agent (blocked in its permission wait) and the turn ends.
      a.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(asJson((await a.response(p))['result'])['stopReason'], 'end_turn');
      await eventually(() async => !await processAlive(pid), what: 'the hook process to be killed after its 5 s');
    });

    test('a 100 KB command in a permission request does not stall the keeper', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p = a.prompt('perm:${'a.' * 50000}');
      final perm = await a.next(isMethod('session/request_permission'));
      expect((asJson(asJson(perm['params'])['toolCall'])['title']! as String).length, 100000); // shown whole
      await eventually(() => events(h).isNotEmpty, what: 'the hook to run');
      expect(events(h).single[5].length, lessThanOrEqualTo(120));
      expect(events(h).single[5], startsWith('a.a.a.'));
      expect((await h.list()).single.pending, 1);
      a.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(asJson((await a.response(p))['result'])['stopReason'], 'end_turn');
    });

    test('redaction is instant on hostile lines and masks the secret whole', () async {
      final h = await newHost();
      final script = keeperScript();
      final probe = File('${h.home.path}/redact_probe.py')
        ..writeAsStringSync(
          '${script.substring(0, script.lastIndexOf('if __name__ == "__main__":'))}\n'
          '''
import time
cases = ["a." * 50000, "token" * 20000, "Authorization: Bearer " + "b" * 100000, "api_key=" + "k" * 100000,
         "http://u:" + "p" * 100000 + "@x", ("A1" * 14 + " ") * 5000, "\\n" * 50000 + "late line"]
out = []
for text in cases:
    t0 = time.perf_counter()
    r = redact_line(text)
    out.append([(time.perf_counter() - t0) * 1000, r])
print(json.dumps(out))
''',
        );
      final r = await h.run("python3 '${probe.path}'");
      expect(r.code, 0, reason: r.err);
      final out = [for (final e in jsonDecode(r.out) as List) (e as List).cast<Object?>()];
      for (final e in out) {
        // The quadratic version took 7800 ms on such a line; this is ~1 ms idle.
        expect(e[0]! as num, lessThan(1500), reason: '${e[1]}');
        expect((e[1]! as String).length, lessThanOrEqualTo(120));
      }
      expect(out[2][1], 'Authorization: *** ***');
      expect(out[3][1], 'api_key=***');
    });
  });
}
