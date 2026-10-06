import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';

void main() {
  group('splitLocation', () {
    test('strips compiler and grep style :line and :line:col', () {
      expect(RemotePath.splitLocation('lib/main.dart:42'), (path: 'lib/main.dart', line: 42, column: null));
      expect(RemotePath.splitLocation('lib/main.dart:42:7'), (path: 'lib/main.dart', line: 42, column: 7));
      expect(RemotePath.splitLocation('/abs/a.rs:1:1:'), (path: '/abs/a.rs', line: 1, column: 1));
      expect(RemotePath.splitLocation('src/a.ts:12:'), (path: 'src/a.ts', line: 12, column: null));
    });

    test('understands #L12 links', () {
      expect(RemotePath.splitLocation('README.md#L30'), (path: 'README.md', line: 30, column: null));
    });

    test('leaves plain paths, colons in names and lone numbers alone', () {
      expect(RemotePath.splitLocation('/etc/hosts'), (path: '/etc/hosts', line: null, column: null));
      expect(RemotePath.splitLocation('a:b/c.txt'), (path: 'a:b/c.txt', line: null, column: null));
      expect(RemotePath.splitLocation(':12'), (path: ':12', line: null, column: null));
      expect(RemotePath.splitLocation('  spaced.txt  '), (path: 'spaced.txt', line: null, column: null));
    });
  });

  group('resolve', () {
    test('absolute paths are only normalised', () {
      expect(RemotePath.resolve('/a//b/./c/../d'), '/a/b/d');
      expect(RemotePath.resolve('/..'), '/');
      expect(RemotePath.resolve('/'), '/');
    });

    test('~ and ~/x use home; ~user is not expanded', () {
      expect(RemotePath.resolve('~', home: '/home/dev'), '/home/dev');
      expect(RemotePath.resolve('~/x/../y', home: '/home/dev'), '/home/dev/y');
      expect(RemotePath.resolve('~/x'), isNull, reason: 'home unknown');
      expect(RemotePath.resolve('~root/x', cwd: '/srv', home: '/home/dev'), '/srv/~root/x');
    });

    test('relative paths start at the cwd, else home, else cannot be placed', () {
      expect(RemotePath.resolve('a/b', cwd: '/srv/app', home: '/h'), '/srv/app/a/b');
      expect(RemotePath.resolve('../b', cwd: '/srv/app'), '/srv/b');
      expect(RemotePath.resolve('a', home: '/h'), '/h/a');
      expect(RemotePath.resolve('a', cwd: 'rel', home: '/h'), '/h/a');
      expect(RemotePath.resolve('a'), isNull);
      expect(RemotePath.resolve('   '), isNull);
    });
  });

  test('parent, basename, join and breadcrumbs', () {
    expect(RemotePath.parent('/a/b/c'), '/a/b');
    expect(RemotePath.parent('/a'), '/');
    expect(RemotePath.parent('/'), '/');
    expect(RemotePath.basename('/a/b/Tệp.txt'), 'Tệp.txt');
    expect(RemotePath.basename('/'), '/');
    expect(RemotePath.join('/', 'x'), '/x');
    expect(RemotePath.join('/a/', 'x'), '/a/x');
    expect(RemotePath.join('/a', 'x'), '/a/x');
    expect(RemotePath.breadcrumbs('/home/dev'), [
      (path: '/', label: '/'),
      (path: '/home', label: 'home'),
      (path: '/home/dev', label: 'dev'),
    ]);
    expect(RemotePath.breadcrumbs('/'), [(path: '/', label: '/')]);
  });

  group('naturalCompare', () {
    List<String> sorted(List<String> names) => [...names]..sort(RemotePath.naturalCompare);

    test('numbers sort by value and case is ignored', () {
      expect(sorted(['file10', 'file2', 'File1', 'file01', 'Zed', 'alpha']),
          ['alpha', 'File1', 'file01', 'file2', 'file10', 'Zed']);
    });

    test('long digit runs do not overflow', () {
      final big = '9' * 40;
      expect(RemotePath.naturalCompare('a${big}0', 'a$big'), greaterThan(0));
    });

    test('is a total order: equal ignoring case still differs', () {
      expect(RemotePath.naturalCompare('A', 'a'), isNot(0));
      expect(RemotePath.naturalCompare('same', 'same'), 0);
    });

    test('a prefix comes first', () {
      expect(RemotePath.naturalCompare('ab', 'abc'), lessThan(0));
    });
  });

  group('models survive JSON', () {
    test('entry with every field, and a broken link', () {
      final e = RemoteEntry(
        name: 'Tệp.txt',
        path: '/h/Tệp.txt',
        kind: RemoteEntryKind.link,
        resolvedKind: RemoteEntryKind.file,
        size: 1 << 40,
        modified: DateTime.utc(2026, 5, 20, 9, 30),
        mode: 0xA1FF,
        linkTarget: '../x',
      );
      expect(RemoteEntry.fromJson(e.toJson()), e);
      const broken = RemoteEntry(name: 'b', path: '/b', kind: RemoteEntryKind.link);
      expect(RemoteEntry.fromJson(broken.toJson()), broken);
      expect(RemoteEntry.fromJson(broken.toJson()).isBrokenLink, isTrue);
    });

    test('stat', () {
      final s = RemoteStat(
        path: '/a/b.txt',
        kind: RemoteEntryKind.file,
        size: 3,
        modified: DateTime.utc(2020),
        mode: 0x81A4,
      );
      expect(RemoteStat.fromJson(s.toJson()), s);
      expect(s.name, 'b.txt');
    });
  });
}
