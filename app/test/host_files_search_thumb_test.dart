import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_files.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/sftp_files.dart';

import 'support/fake_host.dart';

// What `HostFiles.thumbnail` and `HostFiles.search` send to the helper and make
// of what it answers, against a host played by the test (the real binary is
// exercised in host_files_real_test.dart). A thumbnail is a convenience: every
// way it can go wrong is null. A search fails like a listing does.

typedef _Open = ({String svc, String method, Map<String, Object?> args, int stream});

/// Answers each OPEN the client writes with [onOpen].
class _Script {
  _Script(this.host) {
    host.onFrame = (f) {
      if (f.kind == FrameKind.open) {
        final o = jsonDecode(utf8.decode(f.payload)) as Map;
        final open = (
          svc: o['svc']! as String,
          method: o['method']! as String,
          args: (o['args']! as Map).cast<String, Object?>(),
          stream: f.stream,
        );
        opens.add(open);
        onOpen?.call(open);
      } else if (f.kind == FrameKind.reset) {
        resets.add(f.stream);
      }
    };
  }

  final FakeHost host;
  final opens = <_Open>[];
  final resets = <int>[];
  void Function(_Open open)? onOpen;

  void msg(int stream, Object? value) => host.sendJson(FrameKind.msg, stream, value);
  void data(int stream, List<int> bytes) => host.send(Frame(FrameKind.data, stream, Uint8List.fromList(bytes)));
  void end(int stream, [Map<String, Object?> result = const {}]) => host.sendJson(FrameKind.end, stream, result);
  void fail(int stream, String code, [String message = '']) => host.sendJson(FrameKind.end, stream, {
    'error': {'code': code, 'message': message, 'retryable': false},
  });

  List<_Open> of(String method) => [
    for (final o in opens)
      if (o.method == method) o,
  ];
}

void main() {
  late FakeHost host;
  late _Script script;
  late HostFiles files;

  setUp(() async {
    host = FakeHost();
    script = _Script(host);
    final link = HostLink.connect(host, version: '1');
    host.greet(
      services: {
        'fs': {'available': true, 'reason': null},
      },
    );
    files = HostFiles(await link, callTimeout: const Duration(seconds: 5), readTimeout: const Duration(seconds: 5));
  });

  group('thumbnail', () {
    test('asks for the size, the file as it was listed and a clamped edge; the JPEG arrives whole', () async {
      script.onOpen = (o) {
        script.msg(o.stream, {'width': 256, 'height': 171, 'size': 3000000, 'mtime_ms': 1700000000000});
        script.data(o.stream, [0xFF, 0xD8, 1, 2]);
        script.data(o.stream, [3, 4, 0xFF, 0xD9]);
        script.end(o.stream);
      };
      final seen = RemoteStat(
        path: '/home/u/shot.jpg',
        kind: RemoteEntryKind.file,
        size: 3000000,
        modified: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );

      final bytes = await files.thumbnail('/home/u/shot.jpg', maxPx: 5000, expect: seen);

      expect(bytes, [0xFF, 0xD8, 1, 2, 3, 4, 0xFF, 0xD9], reason: 'chunks are joined in order');
      final o = script.of('thumb').single;
      expect(o.svc, 'fs');
      expect(o.args, {
        'path': '/home/u/shot.jpg',
        'max_px': 1024,
        'if_match': {'size': 3000000, 'mtime_ms': 1700000000000},
      });
    });

    test('without expect there is no if_match, and a relative path means from home', () async {
      script.onOpen = (o) {
        script.data(o.stream, [1]);
        script.end(o.stream);
      };

      await files.thumbnail('pics/a.png', maxPx: 10);

      expect(script.of('thumb').single.args, {'path': '~/pics/a.png', 'max_px': 32});
    });

    test('every way the host can refuse is null, never an error', () async {
      for (final (code, message) in const [
        ('failed', 'unsupported image: not a JPEG, PNG or WebP'),
        ('changed', 'the file changed'),
        ('not_found', 'no such file'),
        ('permission', 'denied'),
        ('too_large', 'over 64 MiB'),
        ('not_a_file', 'a folder'),
        ('unknown_method', 'this helper has no fs.thumb'),
        ('unavailable', 'no helper'),
        ('busy', 'too many streams'),
      ]) {
        script.onOpen = (o) => script.fail(o.stream, code, message);
        expect(await files.thumbnail('/p/a.jpg'), isNull, reason: code);
      }
    });

    test('a host that ends the stream with nothing in it has no thumbnail', () async {
      script.onOpen = (o) => script.end(o.stream);
      expect(await files.thumbnail('/p/a.jpg'), isNull);
    });

    test('a connection that drops while the host is working is null, and so is a link already closed', () async {
      script.onOpen = (_) => host.exit(null);
      expect(await files.thumbnail('/p/a.jpg'), isNull);
      expect(await files.thumbnail('/p/b.jpg'), isNull, reason: 'the link is gone: nothing is sent');
    });

    test('a caller that stops waiting resets the stream, and the late bytes are not used', () async {
      final stop = Completer<void>();
      final answered = Completer<_Open>();
      script.onOpen = answered.complete;

      final asked = files.thumbnail('/p/big.jpg', cancelled: stop.future);
      final open = await answered.future;
      expect(script.resets, isEmpty, reason: 'still wanted');

      stop.complete();
      expect(await asked, isNull);

      expect(script.resets, [open.stream], reason: 'the host is told to stop decoding');
      // What the host sends before it hears the reset is dropped by the link.
      script.data(open.stream, [1, 2, 3]);
    });

    test('already cancelled before it starts costs the host one reset at most, and the answer is null', () async {
      script.onOpen = (_) {};
      final stop = Completer<void>()..complete();
      expect(await files.thumbnail('/p/a.jpg', cancelled: stop.future), isNull);
    });

    test('a host that never answers is given up on, and the stream is reset', () async {
      final slow = HostFiles(
        files.link,
        readTimeout: const Duration(milliseconds: 50),
        callTimeout: const Duration(seconds: 5),
      );
      script.onOpen = (_) {};

      expect(await slow.thumbnail('/p/a.jpg'), isNull);
      expect(script.resets, hasLength(1));
    });
  });

  group('search', () {
    const spec = FileSearchSpec(
      root: '/home/u/proj',
      query: ' Shot ',
      kind: FileSearchKind.file,
      modifiedWithin: Duration(hours: 1),
      maxResults: 40,
      maxDepth: 6,
      hidden: true,
      ignore: ['out'],
    );

    Map<String, Object?> entry(String name, String kind, {int? size, int? mtime, String dir = '/home/u/proj/a'}) => {
      'path': '$dir/$name',
      'name': name,
      'kind': kind,
      'size': size,
      'mtime_ms': mtime,
    };

    test('sends the question as the host takes it', () async {
      script.onOpen = (o) => script.end(o.stream, {'scanned': 1, 'truncated': false, 'elapsed_ms': 2});

      await files.search(spec).toList();

      final o = script.of('search').single;
      expect(o.svc, 'fs');
      expect(o.args, {
        'root': '/home/u/proj',
        'query': 'Shot',
        'kind': 'file',
        'modified_within_s': 3600,
        'max_results': 40,
        'max_depth': 6,
        'hidden': true,
        'ignore': ['out'],
      });
    });

    test('an empty question leaves the query out, and `~` and relative roots start at home', () async {
      script.onOpen = (o) => script.end(o.stream, {'scanned': 0, 'truncated': false});

      await files.search(const FileSearchSpec(root: '.', modifiedWithin: Duration(minutes: 5))).toList();

      final args = script.of('search').single.args;
      expect(args['root'], '~');
      expect(args.containsKey('query'), isFalse);
      expect(args['modified_within_s'], 300);
      expect(args['ignore'], FileSearchSpec.defaultIgnore);
    });

    test('batches arrive as entries in order, then the end with what the host says it covered', () async {
      script.onOpen = (o) {
        script.msg(o.stream, {
          'entries': [entry('shot-1.png', 'file', size: 10, mtime: 1700000000000)],
        });
        script.msg(o.stream, {
          'entries': [entry('shots', 'dir', size: 4096, mtime: 1700000001000), entry('s.txt', 'file', size: 1)],
        });
        script.end(o.stream, {'scanned': 321, 'truncated': true, 'elapsed_ms': 40, 'skipped_dirs': 2});
      };

      final events = await files.search(spec).toList();

      expect(events, hasLength(3));
      final first = (events[0] as FileSearchBatch).entries.single;
      expect(first.name, 'shot-1.png');
      expect(first.path, '/home/u/proj/a/shot-1.png');
      expect(first.size, 10);
      expect(first.modified, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
      expect(first.isFile, isTrue);
      final second = (events[1] as FileSearchBatch).entries;
      expect(second.map((e) => e.name), ['shots', 's.txt']);
      expect(second.first.isDirectory, isTrue);
      final done = events[2] as FileSearchDone;
      expect((done.scanned, done.truncated, done.skippedDirs), (321, true, 2));
    });

    test('a link in a batch is looked at before the batch goes on: what it is, not just that it is a link', () async {
      script.onOpen = (o) {
        if (o.method == 'search') {
          script.msg(o.stream, {
            'entries': [entry('to-dir', 'link'), entry('broken', 'link')],
          });
          script.end(o.stream, {'scanned': 2, 'truncated': false});
        } else if (o.method == 'stat') {
          final path = o.args['path']! as String;
          if (path.endsWith('broken')) {
            script.fail(o.stream, 'not_found', 'no such file');
          } else {
            script.msg(o.stream, {'kind': 'dir', 'size': 4096, 'mtime_ms': 1, 'mode': 493});
            script.end(o.stream);
          }
        } else if (o.method == 'real_path') {
          script.msg(o.stream, {'path': '/real/dir'});
          script.end(o.stream);
        }
      };

      final events = await files.search(spec).toList();

      final batch = (events.first as FileSearchBatch).entries;
      expect(batch[0].kind, RemoteEntryKind.link);
      expect(batch[0].isDirectory, isTrue, reason: 'resolved to a folder');
      expect(batch[1].isBrokenLink, isTrue);
      expect(events.last, isA<FileSearchDone>(), reason: 'the end comes after the links were resolved');
    });

    test('a missing root fails the stream with the file error, not a done', () async {
      script.onOpen = (o) => script.fail(o.stream, 'not_found', 'no such folder: /home/u/proj');

      await expectLater(
        files.search(spec),
        emitsInOrder([
          emitsError(
            isA<RemoteFileException>()
                .having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)
                .having((e) => e.path, 'path', '/home/u/proj'),
          ),
          emitsDone,
        ]),
      );
      for (final (code, kind) in const [
        ('permission', RemoteFileErrorKind.permission),
        ('not_a_directory', RemoteFileErrorKind.notADirectory),
      ]) {
        script.onOpen = (o) => script.fail(o.stream, code);
        await expectLater(
          files.search(spec),
          emitsError(isA<RemoteFileException>().having((e) => e.kind, 'kind', kind)),
        );
      }
    });

    test('a link that drops mid-search ends it with a connection problem', () async {
      script.onOpen = (o) {
        script.msg(o.stream, {
          'entries': [entry('a.txt', 'file')],
        });
        host.exit(null);
      };

      final seen = <Object>[];
      await files.search(spec).handleError(seen.add).toList();

      expect(seen, hasLength(1));
      expect(seen.single, isNot(isA<FileSearchDone>()));
    });

    test('cancelling the subscription resets the stream on the host, and what lands after is ignored', () async {
      final answered = Completer<_Open>();
      script.onOpen = (o) {
        script.msg(o.stream, {
          'entries': [entry('a.txt', 'file')],
        });
        answered.complete(o);
      };
      final got = <FileSearchEvent>[];
      final sub = files.search(spec).listen(got.add);
      final open = await answered.future;
      await until(() => got.isNotEmpty, what: 'the first batch');

      await sub.cancel();
      await until(() => script.resets.isNotEmpty, what: 'the reset to reach the host');

      expect(script.resets, [open.stream]);
      script.msg(open.stream, {
        'entries': [entry('late.txt', 'file')],
      });
      await pumpEventQueue();
      expect(got, hasLength(1));
    });

    test('a helper that does not know fs.search is walked from here, folder by folder, with the same rules', () async {
      script.onOpen = (o) {
        switch (o.method) {
          case 'search':
            script.fail(o.stream, 'unknown_method', 'no fs.search');
          case 'list':
            final dir = o.args['path']! as String;
            final entries = switch (dir) {
              '/home/u/proj' => [
                {'name': 'shot-a.png', 'kind': 'file', 'size': 5, 'mtime_ms': 9999999999999},
                {'name': 'node_modules', 'kind': 'dir', 'size': 0, 'mtime_ms': 1},
                {'name': 'sub', 'kind': 'dir', 'size': 0, 'mtime_ms': 1},
              ],
              '/home/u/proj/sub' => [
                {'name': 'deep-shot.png', 'kind': 'file', 'size': 6, 'mtime_ms': 9999999999999},
                {'name': 'other.txt', 'kind': 'file', 'size': 6, 'mtime_ms': 9999999999999},
              ],
              _ => <Map<String, Object?>>[],
            };
            script.msg(o.stream, {'entries': entries});
            script.end(o.stream);
        }
      };

      final events = await files
          .search(const FileSearchSpec(root: '/home/u/proj', query: 'shot', kind: FileSearchKind.file))
          .toList();

      final names = [for (final e in events.whereType<FileSearchBatch>()) ...e.entries.map((x) => x.name)];
      expect(names, ['shot-a.png', 'deep-shot.png'], reason: 'shallow first; node_modules is never entered');
      expect(script.of('list').map((o) => o.args['path']), ['/home/u/proj', '/home/u/proj/sub']);
      expect(events.last, isA<FileSearchDone>());
    });
  });

  group('the SFTP backend', () {
    test('has no thumbnails: null, so the caller does what it always did', () async {
      final sftp = SftpFiles(open: () => throw StateError('never opened'));
      expect(await sftp.thumbnail('/p/a.jpg'), isNull);
    });
  });
}
