import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/repositories/slash_catalog.dart';
import 'package:herdr_mobile/ui/features/pane/slash_view_model.dart';

import 'support/fake_fs.dart';
import 'support/files_support.dart';

const _cwd = '/home/dev/app';

SlashCatalog _catalog(FakeFs? fs) => SlashCatalog(machineWithFiles(fs).files);

SlashCommand? _find(List<SlashCommand> all, String name) {
  for (final c in all) {
    if (c.name == name) return c;
  }
  return null;
}

void main() {
  group('describe', () {
    test('takes the front matter description, quoted or not', () {
      expect(SlashCatalog.describe('---\ndescription: Fix the build\n---\nbody'), 'Fix the build');
      expect(SlashCatalog.describe('---\ndescription: "Say: hi"\n---\n'), 'Say: hi');
      expect(SlashCatalog.describe("---\nname: x\ndescription: 'Quoted'\n---\n"), 'Quoted');
    });

    test('reads a block scalar from the lines under it', () {
      const text = '---\ndescription: >\n  First part\n  second part\nname: x\n---\nbody';

      expect(SlashCatalog.describe(text), 'First part second part');
    });

    test('without a description falls back to the first line of text', () {
      expect(SlashCatalog.describe('---\nmodel: x\n---\n\n# Review the diff\nmore'), 'Review the diff');
      expect(SlashCatalog.describe('\n\nPlain first line\nsecond'), 'Plain first line');
      expect(SlashCatalog.describe(''), '');
    });

    test('a front matter that never closes does not swallow the file', () {
      expect(SlashCatalog.describe('---\ndescription: Open ended\nno close'), 'Open ended');
    });

    test('a long description is cut', () {
      final d = SlashCatalog.describe('x' * 400);

      expect(d.length, 140);
      expect(d.endsWith('…'), isTrue);
    });
  });

  group('SlashCatalog.load', () {
    test('a machine without files still has the built-ins', () async {
      final all = await _catalog(null).load(agent: 'claude', cwd: _cwd);

      expect(_find(all, 'compact')?.source, SlashSource.builtIn);
      expect(all.every((c) => c.source == SlashSource.builtIn), isTrue);
    });

    test('an agent we know nothing about has no commands', () async {
      expect(await _catalog(FakeFs()).load(agent: 'amp', cwd: _cwd), isEmpty);
    });

    test('finds project and user commands and skills for Claude', () async {
      final fs = FakeFs()
        ..addFile('$_cwd/.claude/commands/ship.md', '---\ndescription: Ship it\n---\n')
        ..addFile('$_cwd/.claude/commands/git/sync.md', 'Pull and rebase\n')
        ..addFile('$_cwd/.claude/commands/notes.txt', 'not a command')
        ..addFile('$_cwd/.claude/commands/.hidden.md', 'hidden')
        ..addFile('$_cwd/.claude/skills/pdf/SKILL.md', '---\ndescription: Work with PDFs\n---\n')
        ..addDir('$_cwd/.claude/skills/empty')
        ..addFile('/home/dev/.claude/commands/mine.md', '# My own\n')
        ..addFile('/home/dev/.claude/skills/deploy/SKILL.md', 'Deploy things\n');

      final all = await _catalog(fs).load(agent: 'claude', cwd: _cwd);

      expect(_find(all, 'ship'), const SlashCommand('ship', 'Ship it', SlashSource.project));
      expect(_find(all, 'git:sync'),
          const SlashCommand('git:sync', 'Pull and rebase', SlashSource.project));
      expect(_find(all, 'pdf')?.description, 'Work with PDFs');
      expect(_find(all, 'mine'), const SlashCommand('mine', 'My own', SlashSource.user));
      expect(_find(all, 'deploy')?.source, SlashSource.user);
      for (final absent in ['notes', 'notes.txt', '.hidden', 'empty']) {
        expect(_find(all, absent), isNull, reason: absent);
      }
    });

    test('a command the project defines replaces the built-in of the same name', () async {
      final fs = FakeFs()..addFile('$_cwd/.claude/commands/compact.md', 'Our own compact\n');

      final all = await _catalog(fs).load(agent: 'claude', cwd: _cwd);

      expect(all.where((c) => c.name == 'compact'), [
        const SlashCommand('compact', 'Our own compact', SlashSource.project),
      ]);
    });

    test('lists project, then user, then built-in', () async {
      final fs = FakeFs()
        ..addFile('$_cwd/.claude/commands/p.md', 'p\n')
        ..addFile('/home/dev/.claude/commands/u.md', 'u\n');

      final all = await _catalog(fs).load(agent: 'claude', cwd: _cwd);

      expect(all.map((c) => c.source).toSet().toList(), [
        SlashSource.project,
        SlashSource.user,
        SlashSource.builtIn,
      ]);
    });

    test('an unreadable folder or a failing machine adds nothing and does not throw', () async {
      final fs = FakeFs()
        ..addFile('$_cwd/.claude/commands/ship.md', 'Ship\n')
        ..deny.add('$_cwd/.claude');

      final denied = await _catalog(fs).load(agent: 'claude', cwd: _cwd);
      expect(_find(denied, 'ship'), isNull);
      expect(_find(denied, 'compact'), isNotNull);

      fs.deny.clear();
      fs.fail = StateError('boom');
      final failing = await _catalog(fs).load(agent: 'claude', cwd: _cwd);
      expect(failing.every((c) => c.source == SlashSource.builtIn), isTrue);
    });

    test('opencode reads .opencode/command', () async {
      final fs = FakeFs()..addFile('$_cwd/.opencode/command/test.md', 'Run the tests\n');

      final all = await _catalog(fs).load(agent: 'opencode', cwd: _cwd);

      expect(_find(all, 'test')?.description, 'Run the tests');
    });
  });

  group('SlashViewModel', () {
    var clock = DateTime(2026);
    late FakeFs fs;
    String? agent = 'claude';

    SlashViewModel vm({Duration maxAge = const Duration(minutes: 2)}) => SlashViewModel(
          agent: () => agent,
          cwd: () => _cwd,
          catalog: _catalog(fs),
          maxAge: maxAge,
          now: () => clock,
        );

    setUp(() {
      clock = DateTime(2026);
      agent = 'claude';
      fs = FakeFs()
        ..addFile('$_cwd/.claude/commands/compare.md', 'Compare two files\n')
        ..addFile('$_cwd/.claude/commands/ship.md', 'Ship it\n');
    });

    Future<SlashViewModel> loaded() async {
      final m = vm();
      m.ensureLoaded();
      await pumpEventQueue();
      return m;
    }

    test('matches nothing until it has loaded, and loads only when asked', () async {
      final m = vm();
      expect(m.match('/co'), isEmpty);
      expect(fs.calls, isEmpty);

      m.ensureLoaded();
      await pumpEventQueue();

      expect(m.match('/co'), isNotEmpty);
    });

    test('names that start with the word come first, then names, then descriptions', () async {
      final m = await loaded();

      final names = m.match('/pa').map((c) => c.name).toList();
      // "compare" holds "pa" in its name; "compare" and "permissions" differ.
      expect(names.first, 'compare', reason: 'project command in the name group');

      final starts = m.match('/co').map((c) => c.name).toList();
      expect(starts.indexOf('compare'), lessThan(starts.indexOf('compact')),
          reason: 'project before built-in inside a group');
      expect(starts.take(3), containsAll(['compare', 'compact', 'context']));

      final text = m.match('/files').map((c) => c.name).toList();
      expect(text, contains('compare'), reason: 'found by its description');
    });

    test('only a lone /word is completed', () async {
      final m = await loaded();

      expect(m.match('hello /co'), isEmpty);
      expect(m.match('/compare two'), isEmpty);
      expect(m.match('/compare '), isEmpty);
      expect(m.match(''), isEmpty);
      expect(m.match('/'), isNotEmpty, reason: 'a bare slash lists everything');
    });

    test('a command typed in full leaves nothing to choose', () async {
      final m = await loaded();

      expect(m.match('/ship'), isEmpty);
      expect(m.match('/compa').map((c) => c.name), contains('compare'));
    });

    test('a pane that runs no agent has no palette', () async {
      final m = await loaded();
      agent = null;

      expect(m.match('/co'), isEmpty);
      m.ensureLoaded();
      await pumpEventQueue();
      expect(m.match('/co'), isEmpty);
    });

    test('loads again only once the list is old, or when the agent changed', () async {
      final m = vm();
      m.ensureLoaded();
      await pumpEventQueue();
      final calls = fs.calls.length;

      clock = clock.add(const Duration(minutes: 1));
      m.ensureLoaded();
      await pumpEventQueue();
      expect(fs.calls.length, calls, reason: 'still fresh');

      clock = clock.add(const Duration(minutes: 2));
      m.ensureLoaded();
      await pumpEventQueue();
      expect(fs.calls.length, greaterThan(calls));

      fs.addFile('$_cwd/.claude/commands/fresh.md', 'New one\n');
      agent = 'codex';
      m.ensureLoaded();
      await pumpEventQueue();
      expect(m.match('/ne').map((c) => c.name), contains('new'));
      expect(m.match('/fresh'), isEmpty, reason: 'codex does not read .claude');
    });

    test('a load that finishes after dispose is dropped', () async {
      final m = vm();
      m.ensureLoaded();
      m.dispose();

      await pumpEventQueue();
    });
  });
}
