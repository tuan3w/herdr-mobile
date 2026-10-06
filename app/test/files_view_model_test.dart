import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_view_model.dart';
import 'package:herdr_mobile/ui/features/files/file_kind.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_view_model.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

RemoteFiles _filesOf(FakeFs fs) => RemoteFiles(FakeTransport()..fs = fs);

Future<FileViewerViewModel> _open(
  FakeFs fs,
  String path, {
  int? line,
  int firstChunk = viewerFirstChunk,
  int textLimit = viewerTextLimit,
  bool forceText = false,
  JsonFormatter? formatJson,
}) async {
  final vm = FileViewerViewModel(
    files: _filesOf(fs),
    stat: await fs.stat(path),
    line: line,
    firstChunk: firstChunk,
    textLimit: textLimit,
    forceText: forceText,
    formatJson: formatJson ?? (raw) => Future.value(const JsonEncoder.withIndent('  ').convert(jsonDecode(raw))),
  );
  addTearDown(vm.dispose);
  await vm.load();
  fs.calls.removeWhere((c) => c.startsWith('stat'));
  return vm;
}

String _lines(int n) => List.generate(n, (i) => 'line ${i + 1} — tiếng Việt ✓').join('\n');

void main() {
  group('viewer: text', () {
    test('a small file loads in one read', () async {
      final fs = FakeFs()..addFile('/h/a.txt', 'one\ntwo\n');
      final vm = await _open(fs, '/h/a.txt');

      expect(vm.phase, ViewerPhase.ready);
      expect(vm.kind, FileKind.text);
      expect(vm.document!.lines, ['one', 'two']);
      expect(vm.hasMore, isFalse);
      expect(fs.calls, ['read /h/a.txt@0+8']);
    });

    test('a long file loads in pieces, each starting where the last ended, and ends complete', () async {
      final text = _lines(400);
      final fs = FakeFs()..addFile('/h/log.txt', text);
      final size = utf8.encode(text).length;
      final vm = await _open(fs, '/h/log.txt', firstChunk: 2000);

      expect(vm.hasMore, isTrue);
      expect(vm.document!.lineCount, lessThan(400));
      while (vm.hasMore) {
        await vm.loadMore();
      }

      expect(vm.document!.lines, text.split('\n'), reason: 'multi-byte characters survive every cut');
      expect(vm.truncatedAtLimit, isFalse);
      final offsets = [for (final c in fs.calls) int.parse(c.split('@')[1].split('+')[0])];
      expect(offsets.first, 0);
      expect(offsets, orderedEquals([...offsets]..sort()));
      expect(offsets.toSet().length, offsets.length, reason: 'no byte is read twice');
      expect(vm.document!.bytes, size);
    });

    test('text is never read past the limit, and says so', () async {
      final fs = FakeFs()..addFile('/h/huge.log', _lines(3000));
      final vm = await _open(fs, '/h/huge.log', firstChunk: 1500, textLimit: 5000);

      while (vm.hasMore) {
        await vm.loadMore();
      }

      expect(vm.truncatedAtLimit, isTrue);
      expect(vm.hasMore, isFalse);
      expect(vm.document!.bytes, 5000);
      final ends = [
        for (final c in fs.calls)
          int.parse(c.split('@')[1].split('+')[0]) + int.parse(c.split('+').last),
      ];
      expect(ends.every((e) => e <= 5000), isTrue, reason: '$ends');
      final reads = fs.calls.length;
      await vm.loadMore();
      expect(fs.calls.length, reads, reason: 'nothing more to ask for');
    });

    test('the highlighted line is loaded even when it is past the first piece', () async {
      final fs = FakeFs()..addFile('/h/a.txt', _lines(500));
      final vm = await _open(fs, '/h/a.txt', line: 400, firstChunk: 1500);

      expect(vm.highlightLine, 400);
      expect(vm.document!.lineCount, greaterThanOrEqualTo(400));
    });

    test('a line number past the end of the file highlights nothing', () async {
      final fs = FakeFs()..addFile('/h/a.txt', 'a\nb\nc');
      expect((await _open(fs, '/h/a.txt', line: 99)).highlightLine, isNull);
      expect((await _open(fs, '/h/a.txt', line: 0)).highlightLine, isNull);
      expect((await _open(fs, '/h/a.txt', line: 3)).highlightLine, 3);
    });

    test('a file the server reports as 0 bytes (procfs) is still read', () async {
      final fs = FakeFs()..addFile('/proc/version', 'Linux version 6.1\n');
      final vm = FileViewerViewModel(
        files: _filesOf(fs),
        stat: const RemoteStat(path: '/proc/version', kind: RemoteEntryKind.file, size: 0),
      );
      addTearDown(vm.dispose);
      await vm.load();

      expect(vm.document!.lines, ['Linux version 6.1']);
    });

    test('an empty file is an empty text document', () async {
      final fs = FakeFs()..addFile('/h/e.txt', '');
      final vm = await _open(fs, '/h/e.txt');
      expect(vm.phase, ViewerPhase.ready);
      expect(vm.document!.isEmpty, isTrue);
    });

    test('a failed "load more" keeps what is shown, reports, and retries from the same place', () async {
      final fs = FakeFs()..addFile('/h/a.txt', _lines(300));
      final vm = await _open(fs, '/h/a.txt', firstChunk: 1000);
      final before = vm.document!.lineCount;

      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'link dropped');
      await vm.loadMore();
      expect(vm.loadMoreError?.kind, RemoteFileErrorKind.network);
      expect(vm.document!.lineCount, before);
      expect(vm.loadingMore, isFalse);

      fs.fail = null;
      await vm.loadMore();
      expect(vm.loadMoreError, isNull);
      expect(vm.document!.lineCount, greaterThan(before));
    });

    test('wrap and Markdown source are plain toggles that notify', () async {
      final fs = FakeFs()..addFile('/h/a.md', '# hi');
      final vm = await _open(fs, '/h/a.md');
      var notified = 0;
      vm.addListener(() => notified++);

      vm.setWrap(true);
      vm.setWrap(true);
      vm.setShowSource(true);

      expect(vm.kind, FileKind.markdown);
      expect(vm.wrap, isTrue);
      expect(vm.showSource, isTrue);
      expect(notified, 2);
    });

    test('copy gets the whole text, reading the rest first', () async {
      final text = _lines(200);
      final fs = FakeFs()..addFile('/h/a.txt', text);
      final vm = await _open(fs, '/h/a.txt', firstChunk: 1000);

      final copied = (await vm.textForCopy())!;

      expect(copied.text, text);
      expect(copied.complete, isTrue);
    });

    test('copy of a file past the limit says it is partial', () async {
      final fs = FakeFs()..addFile('/h/a.txt', _lines(2000));
      final vm = await _open(fs, '/h/a.txt', firstChunk: 1000, textLimit: 4000);

      final copied = (await vm.textForCopy())!;

      expect(copied.complete, isFalse);
      expect(utf8.encode(copied.text).length, lessThanOrEqualTo(4000));
    });
  });

  group('viewer: json', () {
    test('minified JSON is formatted straight away', () async {
      final fs = FakeFs()..addFile('/h/a.json', '{"a":1,"b":[1,2],"c":{"d":null}}');
      final vm = await _open(fs, '/h/a.json');

      expect(vm.pretty, isTrue);
      expect(vm.document!.lines.first, '{');
      expect(vm.document!.lineCount, greaterThan(5));
    });

    test('JSON that is already laid out stays as written until asked', () async {
      final fs = FakeFs()..addFile('/h/a.json', '{\n  "a": 1,\n  "b": 2,\n  "c": 3\n}\n');
      final vm = await _open(fs, '/h/a.json');
      expect(vm.pretty, isFalse);

      expect(await vm.setPretty(true), isNull);
      expect(vm.pretty, isTrue);
      expect(await vm.setPretty(false), isNull);
      expect(vm.document!.lines[1], '  "a": 1,');
    });

    test('invalid JSON says so and stays as written', () async {
      final fs = FakeFs()..addFile('/h/a.json', '{"a":');
      final vm = await _open(
        fs,
        '/h/a.json',
        formatJson: (raw) async {
          try {
            return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
          } on FormatException {
            return null;
          }
        },
      );

      expect(vm.pretty, isFalse);
      expect(await vm.setPretty(true), contains('valid JSON'));
      expect(vm.document!.lines, ['{"a":']);
    });

    test('formatting needs the whole file: it reads the rest, or refuses past the limit', () async {
      final big = jsonEncode({'items': List.generate(400, (i) => {'id': i, 'name': 'item $i'})});
      final fs = FakeFs()..addFile('/h/big.json', big);
      final vm = await _open(fs, '/h/big.json', firstChunk: 600);
      expect(vm.pretty, isFalse);

      expect(await vm.setPretty(true), isNull);
      expect(vm.pretty, isTrue);
      expect(vm.document!.lineCount, greaterThan(400));

      final capped = await _open(fs, '/h/big.json', firstChunk: 600, textLimit: 2000);
      expect(await capped.setPretty(true), contains('too large'));
      expect(capped.pretty, isFalse);
      expect(capped.canPretty, isFalse);
    });

    test('copy gives what is shown (formatted)', () async {
      final fs = FakeFs()..addFile('/h/a.json', '{"a":1}');
      final vm = await _open(fs, '/h/a.json');
      expect((await vm.textForCopy())!.text, '{\n  "a": 1\n}');
    });
  });

  group('viewer: kinds and gating', () {
    test('a picture is recognised from its bytes and not read further: the photo viewer reads it', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(5000, 7)]);
      // A name that says nothing: the first bytes decide.
      final fs = FakeFs()..addFile('/h/screenshot', png);
      final vm = await _open(fs, '/h/screenshot', firstChunk: 1000);
      expect(vm.phase, ViewerPhase.ready);
      expect(vm.kind, FileKind.image);
      expect(fs.calls.where((c) => c.startsWith('read')).length, 1, reason: 'only the sniffing read: no bitmap is made here');
    });

    test('a file shown as text on request stays text whatever its bytes say', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(50, 65)]);
      final fs = FakeFs()..addFile('/h/p.png', png);
      expect((await _open(fs, '/h/p.png')).kind, FileKind.image);
      expect((await _open(fs, '/h/p.png', forceText: true)).kind, FileKind.text);
    });

    test('a file with an image name but text content is shown as text', () async {
      final fs = FakeFs()..addFile('/h/x.png', '<html>404</html>');
      final vm = await _open(fs, '/h/x.png');
      expect(vm.kind, FileKind.text);
    });

    test('a binary file keeps only a short head for the hex preview', () async {
      final fs = FakeFs()..addFile('/h/a.bin', Uint8List.fromList(List.generate(10000, (i) => i % 256)));
      final vm = await _open(fs, '/h/a.bin');

      expect(vm.kind, FileKind.binary);
      expect(vm.head.length, viewerHexBytes);
      expect(vm.head[255], 255);
      expect(vm.document, isNull);
    });

    test('SVG is an info card that can be read as text', () async {
      final fs = FakeFs()..addFile('/h/a.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>');
      final vm = await _open(fs, '/h/a.svg');
      expect(vm.kind, FileKind.svg);
      expect(vm.canViewAsText, isTrue);

      await vm.viewAsText();

      expect(vm.kind, FileKind.text);
      expect(vm.document!.lines.single, startsWith('<svg'));
      expect(vm.canViewAsText, isFalse);
    });

    test('a folder or a socket cannot be opened as a file', () async {
      final fs = FakeFs()..addDir('/h/d');
      final dir = FileViewerViewModel(
        files: _filesOf(fs),
        stat: const RemoteStat(path: '/h/d', kind: RemoteEntryKind.dir),
      );
      addTearDown(dir.dispose);
      await dir.load();
      expect(dir.error!.kind, RemoteFileErrorKind.notAFile);

      final sock = FileViewerViewModel(
        files: _filesOf(fs),
        stat: const RemoteStat(path: '/run/s.sock', kind: RemoteEntryKind.other),
      );
      addTearDown(sock.dispose);
      await sock.load();
      expect(sock.error!.kind, RemoteFileErrorKind.notAFile);
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty);
    });
  });

  group('viewer: failures', () {
    test('permission denied fails with its kind; retry succeeds once it is fixed', () async {
      final fs = FakeFs()..addFile('/h/a.txt', 'secret');
      final stat = await fs.stat('/h/a.txt');
      fs.deny.add('/h/a.txt');
      final vm = FileViewerViewModel(files: _filesOf(fs), stat: stat);
      addTearDown(vm.dispose);

      await vm.load();
      expect(vm.phase, ViewerPhase.failed);
      expect(vm.error!.kind, RemoteFileErrorKind.permission);

      fs.deny.clear();
      await vm.retry();
      expect(vm.phase, ViewerPhase.ready);
      expect(vm.error, isNull);
      expect(vm.document!.lines, ['secret']);
    });

    test('a file deleted since the listing is "not found"', () async {
      final fs = FakeFs()..addFile('/h/a.txt', 'x');
      final stat = await fs.stat('/h/a.txt');
      fs.nodes.remove('/h/a.txt');
      final vm = FileViewerViewModel(files: _filesOf(fs), stat: stat);
      addTearDown(vm.dispose);

      await vm.load();

      expect(vm.error!.kind, RemoteFileErrorKind.notFound);
    });

    test('a machine without file access says so', () async {
      final vm = FileViewerViewModel(
        files: RemoteFiles(FakeTransport()),
        stat: const RemoteStat(path: '/a', kind: RemoteEntryKind.file, size: 1),
      );
      addTearDown(vm.dispose);

      await vm.load();

      expect(vm.error!.kind, RemoteFileErrorKind.unsupported);
    });

    test('while loading the phase is loading, and a stale answer never overwrites a newer one', () async {
      final fs = FakeFs()
        ..addFile('/h/a.txt', 'first')
        ..gate = Completer<void>();
      final vm = FileViewerViewModel(files: _filesOf(fs), stat: await _statNoGate(fs, '/h/a.txt'));
      addTearDown(vm.dispose);

      final slow = vm.load();
      expect(vm.phase, ViewerPhase.loading);
      final gate = fs.gate!;
      fs.gate = null;
      fs.nodes['/h/a.txt'] = FakeNode.file(Uint8List.fromList(utf8.encode('later')));
      await vm.load();
      expect(vm.document!.lines, ['later']);

      gate.complete();
      await slow;
      expect(vm.document!.lines, ['later'], reason: 'the older read finished last and lost');
    });

    test('disposing mid-load is silent', () async {
      final fs = FakeFs()
        ..addFile('/h/a.txt', 'x')
        ..gate = Completer<void>();
      final vm = FileViewerViewModel(files: _filesOf(fs), stat: await _statNoGate(fs, '/h/a.txt'));
      final done = vm.load();
      vm.dispose();
      fs.gate!.complete();

      await done; // must not throw "used after being disposed"
    });
  });

  group('browser', () {
    FileBrowserViewModel vmFor(FakeFs fs, String path, {bool directoriesOnly = false}) {
      final vm = FileBrowserViewModel(files: _filesOf(fs), path: path, directoriesOnly: directoriesOnly);
      addTearDown(vm.dispose);
      return vm;
    }

    test('folders first, then files, each in natural case-insensitive order', () async {
      final fs = FakeFs()
        ..addDir('/p/zeta')
        ..addDir('/p/Alpha')
        ..addDir('/p/đồ án')
        ..addFile('/p/file10.txt', 'x')
        ..addFile('/p/File2.txt', 'x')
        ..addFile('/p/apple.txt', 'x')
        ..addLink('/p/shortcut', 'zeta')
        ..addLink('/p/doc', 'file10.txt');
      final vm = vmFor(fs, '/p');
      await vm.load();

      expect([for (final e in vm.entries) e.name],
          ['Alpha', 'shortcut', 'zeta', 'đồ án', 'apple.txt', 'doc', 'File2.txt', 'file10.txt']);
    });

    test('dotfiles are hidden until asked for, and the count says how many', () async {
      final fs = FakeFs()
        ..addDir('/p/.git')
        ..addFile('/p/.env', 'x')
        ..addFile('/p/a.txt', 'x');
      final vm = vmFor(fs, '/p');
      await vm.load();

      expect([for (final e in vm.entries) e.name], ['a.txt']);
      expect(vm.hiddenCount, 2);
      expect(vm.totalCount, 3);

      vm.setShowHidden(true);
      expect([for (final e in vm.entries) e.name], ['.git', '.env', 'a.txt']);
      expect(vm.hiddenCount, 0);
    });

    test('the visible list is built once, not per read', () async {
      final fs = FakeFs();
      for (var i = 0; i < 50; i++) {
        fs.addFile('/p/f$i', 'x');
      }
      final vm = vmFor(fs, '/p');
      await vm.load();

      expect(identical(vm.entries, vm.entries), isTrue);
    });

    test('5,000 entries sort in well under a frame budget of seconds', () async {
      final fs = FakeFs();
      for (var i = 0; i < 5000; i++) {
        fs.nodes['/p/Tệp ${(i * 7919) % 5000}.txt'] = FakeNode.file(Uint8List(1));
      }
      fs.addDir('/p');
      final vm = vmFor(fs, '/p');
      final sw = Stopwatch()..start();
      await vm.load();
      sw.stop();

      expect(vm.entries.length, 5000);
      expect(vm.entries.first.name, 'Tệp 0.txt');
      expect(vm.entries[10].name, 'Tệp 10.txt');
      expect(vm.entries.last.name, 'Tệp 4999.txt');
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });

    test('folder picking lists only folders (links to folders included)', () async {
      final fs = FakeFs()
        ..addDir('/p/src')
        ..addFile('/p/a.txt', 'x')
        ..addLink('/p/lnk', 'src')
        ..addLink('/p/doc', 'a.txt');
      final vm = vmFor(fs, '/p', directoriesOnly: true);
      await vm.load();

      expect([for (final e in vm.entries) e.name], ['lnk', 'src']);
    });

    test('permission denied and not found are reported with their kinds, and retry recovers', () async {
      final fs = FakeFs()..addDir('/p');
      fs.deny.add('/p');
      final vm = vmFor(fs, '/p');
      await vm.load();
      expect(vm.error!.kind, RemoteFileErrorKind.permission);
      expect(vm.loading, isFalse);

      fs.deny.clear();
      await vm.load();
      expect(vm.error, isNull);

      expect((await _loaded(fs, '/nope')).error!.kind, RemoteFileErrorKind.notFound);
      fs.addFile('/f', 'x');
      expect((await _loaded(fs, '/f')).error!.kind, RemoteFileErrorKind.notADirectory);
    });

    test('a failed refresh keeps the listing on screen', () async {
      final fs = FakeFs()..addFile('/p/a.txt', 'x');
      final vm = vmFor(fs, '/p');
      await vm.load();

      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      await vm.load();

      expect(vm.error, isNull);
      expect(vm.entries.map((e) => e.name), ['a.txt']);
    });

    test('a refresh picks up new entries', () async {
      final fs = FakeFs()..addFile('/p/a.txt', 'x');
      final vm = vmFor(fs, '/p');
      await vm.load();
      fs.addFile('/p/b.txt', 'x');

      await vm.load();

      expect(vm.entries.map((e) => e.name), ['a.txt', 'b.txt']);
    });

    test('an older listing that finishes last does not replace a newer one', () async {
      final fs = FakeFs()..addFile('/p/old.txt', 'x');
      final vm = vmFor(fs, '/p');
      fs.gate = Completer<void>();
      final slow = vm.load();
      final gate = fs.gate!;
      fs.gate = null;
      fs.nodes.remove('/p/old.txt');
      fs.addFile('/p/new.txt', 'x');
      await vm.load();

      gate.complete();
      await slow;

      expect(vm.entries.map((e) => e.name), ['new.txt']);
    });

    test('breadcrumbs say ~ for paths under home, and spell out the rest', () async {
      final fs = FakeFs()
        ..addDir('/home/dev/work/api')
        ..addDir('/var/log');
      final inHome = vmFor(fs, '/home/dev/work/api');
      await inHome.load();
      expect([for (final c in inHome.breadcrumbs) c.label], ['/', '~', 'work', 'api']);
      expect(inHome.breadcrumbs[1].path, '/home/dev');

      final atHome = vmFor(fs, '/home/dev');
      await atHome.load();
      expect([for (final c in atHome.breadcrumbs) c.label], ['/', '~']);

      final outside = vmFor(fs, '/var/log');
      await outside.load();
      expect([for (final c in outside.breadcrumbs) c.label], ['/', 'var', 'log']);
      expect(outside.parentPath, '/var');
      expect((await _loaded(fs, '/')).parentPath, isNull);
    });
  });
}

Future<RemoteStat> _statNoGate(FakeFs fs, String path) async {
  final gate = fs.gate;
  fs.gate = null;
  final s = await fs.stat(path);
  fs.gate = gate;
  return s;
}

Future<FileBrowserViewModel> _loaded(FakeFs fs, String path) async {
  final vm = FileBrowserViewModel(files: _filesOf(fs), path: path);
  addTearDown(vm.dispose);
  await vm.load();
  return vm;
}
