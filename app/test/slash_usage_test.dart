import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/repositories/command_source.dart';
import 'package:herdr_mobile/data/repositories/slash_catalog.dart';
import 'package:herdr_mobile/data/repositories/slash_usage.dart';
import 'package:herdr_mobile/ui/features/composer/command_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_fs.dart';
import 'support/files_support.dart';

/// Keeps the memory as the JSON the phone would keep, so a reload goes through
/// the real serialisation.
class _MemoryStore implements SlashUsageStore {
  String? raw;
  Object? readFailure;
  Object? writeFailure;
  int writes = 0;

  @override
  Future<SlashUsageMemory> read() async {
    if (readFailure != null) throw readFailure!;
    final text = raw;
    return text == null ? const SlashUsageMemory() : SlashUsageMemory.fromJson(jsonDecode(text));
  }

  @override
  Future<void> write(SlashUsageMemory memory) async {
    writes++;
    if (writeFailure != null) throw writeFailure!;
    raw = jsonEncode(memory.toJson());
  }
}

/// A clock that moves one minute every time it is read, so every command has
/// its own last-used time.
class _Clock {
  var _t = DateTime(2026, 1, 1);

  DateTime call() => _t = _t.add(const Duration(minutes: 1));
}

SlashUsage _usage([_MemoryStore? store, _Clock? clock]) =>
    SlashUsage(store ?? _MemoryStore(), now: (clock ?? _Clock()).call);

void main() {
  group('SlashUsage', () {
    test('counts what was sent and lists it newest first', () async {
      final u = _usage();
      await u.record('omp', 'review');
      await u.record('omp', 'ship');
      await u.record('omp', 'review');
      await u.record('omp', 'deploy');

      expect(u.count('omp', 'review'), 2);
      expect(u.count('omp', 'ship'), 1);
      expect(u.count('omp', 'unknown'), 0);
      expect(u.used('omp'), ['deploy', 'review', 'ship']);
      expect(u.recent('omp', limit: 2), ['deploy', 'review']);
      expect(u.recent('omp', exclude: {'deploy'}), ['review', 'ship']);
    });

    test('keeps agents apart, whatever the case of their label', () async {
      final u = _usage();
      await u.record('Omp', 'review');
      await u.togglePin('OMP', 'ship');

      expect(u.count('omp', 'review'), 1);
      expect(u.isPinned('omp', 'ship'), isTrue);
      expect(u.count('claude', 'review'), 0);
      expect(u.pinned('claude'), isEmpty);
      expect(u.used('claude'), isEmpty);
    });

    test('ignores an empty agent or name', () async {
      final store = _MemoryStore();
      final u = _usage(store);
      await u.record('', 'review');
      await u.record('omp', '');
      await u.togglePin(' ', 'review');

      expect(u.used('omp'), isEmpty);
      expect(store.writes, 0);
    });

    test('pinning toggles, keeps the order pinned in, and forgets an emptied agent', () async {
      final store = _MemoryStore();
      final u = _usage(store);
      await u.togglePin('omp', 'b');
      await u.togglePin('omp', 'a');
      await u.togglePin('omp', 'c');

      expect(u.pinned('omp'), ['b', 'a', 'c']);

      await u.togglePin('omp', 'a');
      expect(u.pinned('omp'), ['b', 'c']);
      expect(u.isPinned('omp', 'a'), isFalse);

      await u.togglePin('omp', 'b');
      await u.togglePin('omp', 'c');
      expect(u.pinned('omp'), isEmpty);
      expect((jsonDecode(store.raw!) as Map)['pinned'], isEmpty,
          reason: 'no empty list is left behind');
    });

    test('remembers at most 40 per agent: the busiest, and always the newest', () async {
      final u = _usage();
      for (var i = 0; i < 3; i++) {
        await u.record('omp', 'busy');
      }
      for (var i = 0; i < 45; i++) {
        await u.record('omp', 'n$i');
      }

      final names = u.used('omp');
      expect(names, hasLength(SlashUsage.maxPerAgent));
      expect(names, contains('busy'), reason: 'used three times, older than the rest');
      expect(names.take(5), ['n44', 'n43', 'n42', 'n41', 'n40']);
      expect(names, contains('n6'));
      expect(names, isNot(contains('n5')), reason: 'the oldest of those sent once goes first');
      expect(names, isNot(contains('n0')));
    });

    test('a command just sent survives forty older ones that were used more', () async {
      final u = _usage();
      for (var i = 0; i < 40; i++) {
        for (var n = 0; n < 5; n++) {
          await u.record('omp', 'old$i');
        }
      }
      await u.record('omp', 'fresh');

      expect(u.used('omp'), hasLength(40));
      expect(u.recent('omp').first, 'fresh');
      expect(u.count('omp', 'fresh'), 1);
      expect(u.count('omp', 'old0'), 0, reason: 'the least recent of the busy ones made room');
    });

    test('the bound is per agent', () async {
      final u = _usage();
      for (var i = 0; i < 45; i++) {
        await u.record('omp', 'a$i');
      }
      await u.record('pi', 'only');

      expect(u.used('pi'), ['only']);
      expect(u.used('omp'), hasLength(40));
    });

    test('a reload finds the counts, times and pins as they were', () async {
      final store = _MemoryStore();
      final first = _usage(store);
      await first.record('omp', 'review');
      await first.record('omp', 'review');
      await first.record('omp', 'ship');
      await first.togglePin('omp', 'deploy');
      await first.togglePin('omp', 'ship');

      final second = _usage(store);
      await second.load();

      expect(second.count('omp', 'review'), 2);
      expect(second.used('omp'), ['ship', 'review']);
      expect(second.pinned('omp'), ['deploy', 'ship']);
    });

    test('notifies on load, record and pin', () async {
      final u = _usage();
      var notified = 0;
      u.addListener(() => notified++);

      await u.load();
      await u.record('omp', 'a');
      await u.togglePin('omp', 'a');

      expect(notified, 3);
    });

    test('an unreadable store starts empty, and a failing write is not an error', () async {
      final store = _MemoryStore()
        ..readFailure = StateError('disk')
        ..writeFailure = StateError('full');
      final u = _usage(store);

      await u.load();
      await u.record('omp', 'review');
      await u.togglePin('omp', 'review');

      expect(u.count('omp', 'review'), 1, reason: 'kept in memory for this launch');
      expect(u.isPinned('omp', 'review'), isTrue);
    });
  });

  group('SlashUsageMemory.fromJson', () {
    test('drops what does not fit and keeps the rest', () {
      final memory = SlashUsageMemory.fromJson({
        'uses': {
          'omp': {
            'good': [2, 1000],
            'zero': [0, 1000],
            'text': ['x', 1000],
            'short': [1],
            'float': [1, 1.5],
          },
          'empty': {'bad': [0, 0]},
          'nope': 'not a map',
          7: {'a': [1, 1]},
        },
        'pinned': {
          'omp': ['a', 3, 'b', 'a'],
          'none': [],
          'bad': 'x',
        },
      });

      expect(memory.uses.keys, ['omp']);
      expect(memory.uses['omp']!.keys, ['good']);
      expect(memory.uses['omp']!['good']!.count, 2);
      expect(memory.uses['omp']!['good']!.lastUsed.millisecondsSinceEpoch, 1000);
      expect(memory.pinned.keys, ['omp']);
      expect(memory.pinned['omp'], ['a', 'b']);
    });

    test('anything else is empty', () {
      for (final junk in [null, 5, 'x', <Object?>[], {'uses': 3, 'pinned': 3}]) {
        final m = SlashUsageMemory.fromJson(junk);
        expect(m.uses, isEmpty, reason: '$junk');
        expect(m.pinned, isEmpty, reason: '$junk');
      }
    });
  });

  group('PrefsSlashUsageStore', () {
    test('round trips through the preferences, and a corrupt value reads empty', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsSlashUsageStore();
      final u = SlashUsage(store, now: _Clock().call);
      await u.record('pi', 'tree');
      await u.togglePin('pi', 'tree');

      final again = SlashUsage(PrefsSlashUsageStore());
      await again.load();
      expect(again.count('pi', 'tree'), 1);
      expect(again.pinned('pi'), ['tree']);

      SharedPreferences.setMockInitialValues({'slashUsage.v1': '{not json'});
      expect((await PrefsSlashUsageStore().read()).uses, isEmpty);
    });
  });

  group('CommandPaletteModel with usage', () {
    late SlashUsage usage;
    var agent = 'claude';

    CommandPaletteModel vm({SlashUsage? withUsage, FakeFs? fs}) => CommandPaletteModel(
          source: CatalogCommandSource(
            agent: () => agent,
            cwd: () => '/work/app',
            catalog: SlashCatalog(machineWithFiles(fs).files),
          ),
          usage: withUsage ?? usage,
        );

    Future<CommandPaletteModel> loaded({FakeFs? fs}) async {
      final m = vm(fs: fs);
      m.ensureLoaded();
      await pumpEventQueue();
      return m;
    }

    List<String> names(CommandPaletteModel m, String input) =>
        [for (final c in m.match(input)) c.name];

    setUp(() {
      usage = _usage();
      agent = 'claude';
    });

    test('a bare slash lists pinned, then the five latest, then the rest', () async {
      for (final n in ['clear', 'compact', 'model', 'resume', 'rewind', 'context', 'cost']) {
        await usage.record('claude', n);
      }
      await usage.togglePin('claude', 'help');
      await usage.togglePin('claude', 'exit');
      final m = await loaded();

      final all = names(m, '/');

      expect(all.take(2), ['help', 'exit'], reason: 'pinned, in the order pinned');
      expect(all.skip(2).take(5), ['cost', 'context', 'rewind', 'resume', 'model']);
      expect(all.skip(7).take(2), ['clear', 'compact'],
          reason: 'older ones fall back to the catalog order');
      expect(all.toSet(), hasLength(all.length), reason: 'nothing twice');
      expect(all, hasLength(builtInSlashCommands['claude']!.length));
    });

    test('a pinned command is not repeated among the recent ones', () async {
      await usage.record('claude', 'cost');
      await usage.record('claude', 'status');
      await usage.togglePin('claude', 'status');
      final m = await loaded();

      expect(names(m, '/').take(3), ['status', 'cost', 'clear']);
    });

    test('a bare slash with nothing used lists the catalog as before', () async {
      final m = await loaded();

      expect(names(m, '/'), [for (final c in builtInSlashCommands['claude']!) c.name]);
    });

    test('typing a prefix breaks ties by use count', () async {
      await usage.record('claude', 'cost');
      await usage.record('claude', 'cost');
      await usage.record('claude', 'cost');
      await usage.record('claude', 'config');
      final m = await loaded();

      expect(names(m, '/c').take(5), ['cost', 'config', 'clear', 'compact', 'context']);
    });

    test('use never lifts a command over its group or its source', () async {
      for (var i = 0; i < 10; i++) {
        await usage.record('claude', 'clear');
      }
      final fs = FakeFs()..addFile('/work/app/.claude/commands/cleanup.md', 'Tidy\n');
      final m = await loaded(fs: fs);

      expect(names(m, '/cl').take(2), ['cleanup', 'clear'], reason: 'project before built-in');
      expect(names(m, '/Tidy'), ['cleanup'], reason: 'by description, last group');
    });

    test('an agent without a table lists only what was pinned or sent', () async {
      agent = 'omp';
      final empty = await loaded();
      expect(names(empty, '/'), isEmpty);
      expect(names(empty, '/re'), isEmpty);

      await usage.record('omp', 'review');
      await usage.record('omp', 'review');
      await usage.record('omp', 'ship');
      await usage.togglePin('omp', 'deploy');

      expect(names(empty, '/'), ['deploy', 'ship', 'review']);
      expect(names(empty, '/re'), ['review']);
      expect(names(empty, '/zzz'), isEmpty);
      expect(names(empty, '/ship'), isEmpty, reason: 'typed in full: nothing left to choose');
      expect(empty.match('/review'), isEmpty);
    });

    test('a pinned or sent name the catalog lacks still completes, with no description', () async {
      await usage.record('claude', 'mine');
      await usage.togglePin('claude', 'ghost');
      final m = await loaded();

      expect(names(m, '/').take(2), ['ghost', 'mine']);
      final ghost = m.match('/gh').single;
      expect(ghost, const SlashCommand('ghost', '', SlashSource.builtIn));
      // "mi" is also inside "permissions": a longer word only mine holds.
      expect(names(m, '/min'), ['mine']);
    });

    test('a command of the catalog keeps its own description when pinned', () async {
      await usage.togglePin('claude', 'compact');
      final m = await loaded();

      final first = m.match('/').first;
      expect(first.name, 'compact');
      expect(first.description, isNotEmpty);
    });

    test('pins and use belong to the agent in the pane', () async {
      await usage.togglePin('claude', 'cost');
      final m = await loaded();
      agent = 'codex';
      m.ensureLoaded();
      await pumpEventQueue();

      expect(names(m, '/').first, 'new', reason: 'codex has no pin');
      expect(m.isPinned(const SlashCommand('cost', '', SlashSource.builtIn)), isFalse);
      agent = 'claude';
      expect(m.isPinned(const SlashCommand('cost', '', SlashSource.builtIn)), isTrue);
    });

    test('togglePin flips the pin and tells the palette', () async {
      final m = await loaded();
      var notified = 0;
      m.addListener(() => notified++);
      const cost = SlashCommand('cost', '', SlashSource.builtIn);

      m.togglePin(cost);
      await pumpEventQueue();
      expect(m.isPinned(cost), isTrue);
      expect(names(m, '/').first, 'cost');
      expect(notified, 1);

      m.togglePin(cost);
      await pumpEventQueue();
      expect(m.isPinned(cost), isFalse);
      expect(notified, 2);
    });

    test('without a usage there is nothing to pin and the order is the catalog', () async {
      final m = CommandPaletteModel(
        source: CatalogCommandSource(
          agent: () => 'claude',
          cwd: () => '/work/app',
          catalog: SlashCatalog(machineWithFiles(null).files),
        ),
      );
      m.ensureLoaded();
      await pumpEventQueue();

      m.togglePin(const SlashCommand('cost', '', SlashSource.builtIn));
      expect(m.isPinned(const SlashCommand('cost', '', SlashSource.builtIn)), isFalse);
      m.recordSent('/cost');
      expect(names(m, '/c').take(3), ['clear', 'compact', 'context']);
    });

    test('a changing usage does not reach a disposed model', () async {
      final m = await loaded();
      m.dispose();

      await usage.record('claude', 'cost');
    });
  });

  group('CommandPaletteModel.recordSent', () {
    late SlashUsage usage;
    String? agent = 'omp';

    CommandPaletteModel vm() => CommandPaletteModel(
          source: CatalogCommandSource(
            agent: () => agent,
            cwd: () => null,
            catalog: SlashCatalog(machineWithFiles(null).files),
          ),
          usage: usage,
        );

    setUp(() {
      usage = _usage();
      agent = 'omp';
    });

    test('records the command a line starts with, with or without arguments', () async {
      final m = vm();
      m.recordSent('/model gpt-5');
      m.recordSent('/compact');
      m.recordSent('/git:sync now');
      m.recordSent('/review\nthe second line');
      m.recordSent('/skill.v2 x');
      await pumpEventQueue();

      expect(usage.used('omp').toSet(), {'model', 'compact', 'git:sync', 'review', 'skill.v2'});
      expect(usage.count('omp', 'model'), 1);
    });

    test('a path, plain text or a lone slash is not a command', () async {
      final m = vm();
      for (final line in [
        '/etc/hosts is odd',
        '/usr/bin/env',
        'hello /model',
        ' /model',
        '/',
        '/ model',
        '//comment',
        '/-flag',
        '',
        '/${'x' * 80}',
      ]) {
        m.recordSent(line);
      }
      await pumpEventQueue();

      expect(usage.used('omp'), isEmpty);
    });

    test('a pane that runs no agent records nothing', () async {
      agent = null;
      vm().recordSent('/model');
      await pumpEventQueue();

      expect(usage.used('omp'), isEmpty);
    });

    test('the same command sent twice counts twice', () async {
      final m = vm();
      m.recordSent('/ship');
      m.recordSent('/ship now');
      await pumpEventQueue();

      expect(usage.count('omp', 'ship'), 2);
    });

    Future<CommandPaletteModel> codexWithSkill() async {
      final fs = FakeFs()..addFile('/work/app/.agents/skills/review/SKILL.md', '---\ndescription: Review\n---\n');
      final m = CommandPaletteModel(
        source: CatalogCommandSource(
          agent: () => 'codex',
          cwd: () => '/work/app',
          catalog: SlashCatalog(machineWithFiles(fs).files),
        ),
        usage: usage,
      );
      addTearDown(m.dispose);
      m.ensureLoaded();
      await pumpEventQueue();
      return m;
    }

    test('a skill is remembered with its dollar, apart from the command of that name', () async {
      final m = await codexWithSkill();
      m.recordSent(r'$review the diff');
      m.recordSent('/review now');
      m.recordSent(r'$review');
      await pumpEventQueue();

      expect(usage.count('codex', r'$review'), 2);
      expect(usage.count('codex', 'review'), 1);
    });

    test('a line that starts with a shell variable is a sentence, not a skill nobody has', () async {
      final m = await codexWithSkill();
      m.recordSent(r'$PATH is wrong on this box');
      m.recordSent(r'$HOME');
      await pumpEventQueue();
      expect(usage.used('codex'), isEmpty);

      // Nor for an agent whose source knows no skills at all.
      final plain = vm();
      plain.recordSent(r'$PATH is wrong on this box');
      await pumpEventQueue();
      expect(usage.used('omp'), isEmpty);
      expect(m.match(r'$').map((c) => c.name), ['review'], reason: 'the palette lists only the skill that exists');
    });
  });
}
