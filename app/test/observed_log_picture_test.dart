import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart' show AgentHostException;
import 'package:herdr_mobile/data/observed/log_picture.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/services/disk_cache.dart';

import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' show eventually;

// A picture of a terminal-log chat is fetched only when asked for, from the
// store when the phone holds it, else from the machine (the keeper for Claude
// and Codex, a plain file over SFTP for omp), kept, and never twice at once.

const _keeper = KeeperPictureRef(start: 4096, hash: '0123456789abcdef', bytes: 100);
final _sha = 'cd' * 32;

void main() {
  late Directory dir;
  late DiskCache store;
  late DiskCache savedStore;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('observed_picture_');
    savedStore = DiskCache.shared;
    store = DiskCache.shared = DiskCache(() async => dir);
  });
  tearDown(() {
    DiskCache.shared = savedStore;
    dir.deleteSync(recursive: true);
  });

  Future<(ObservedRig, ObservedAgentSession)> open({FakeFs? fs}) async {
    final rig = await ObservedRig.create();
    addTearDown(rig.dispose);
    if (fs != null) rig.transport.fs = fs;
    rig.source.write([sessionLine(), userLine('u1', 'go')]);
    final session = ObservedAgentSession(
      machine: rig.machine,
      paneId: 'w1:p1',
      kind: ompKind,
      source: rig.source,
      mapper: OmpLogMapper.new,
      previews: rig.previews,
    );
    addTearDown(session.dispose);
    session.acquire();
    await eventually(() => session.link == AgentLink.live, reason: 'log followed');
    return (rig, session);
  }

  Future<void> stored(String key) async {
    for (var i = 0; i < 100 && !store.knows(key); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(store.knows(key), isTrue, reason: 'the picture was kept');
  }

  group('a Claude or Codex picture, through the keeper', () {
    test('the first ask reads the log line again, the next is answered from the store', () async {
      final (rig, session) = await open();
      rig.source.blobs['4096.0123456789abcdef'] = Uint8List.fromList([9, 8, 7]);

      expect(await session.loadLogPicture(_keeper), [9, 8, 7]);
      expect(rig.source.blobCalls, [(path: ompLog, start: 4096, hash: '0123456789abcdef')]);
      await stored(_keeper.key);

      expect(await session.loadLogPicture(_keeper), [9, 8, 7]);
      expect(rig.source.blobCalls, hasLength(1), reason: 'held pictures cost no radio');
    });

    test('a double tap is one transfer', () async {
      final (rig, session) = await open();
      rig.source.blobs['4096.0123456789abcdef'] = Uint8List.fromList([1, 2]);
      rig.source.blobGate = Completer<void>();

      final a = session.loadLogPicture(_keeper);
      final b = session.loadLogPicture(_keeper);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      rig.source.blobGate!.complete();

      expect(await a, [1, 2]);
      expect(await b, [1, 2]);
      expect(rig.source.blobCalls, hasLength(1));
    });

    test('a failure is not remembered: asking again asks the machine again', () async {
      final (rig, session) = await open();
      rig.source.blobs['4096.0123456789abcdef'] = Uint8List.fromList([5]);
      rig.source.blobError = const AgentHostException('The log changed since that picture was listed.', fatal: true);

      await expectLater(
        session.loadLogPicture(_keeper),
        throwsA(isA<LogPictureException>().having((e) => e.message, 'message', 'The log changed since that picture was listed.')),
      );
      expect(await session.loadLogPicture(_keeper), [5]);
      expect(rig.source.blobCalls, hasLength(2));
    });

    test('a picture known to be over 12 MB is refused before a byte is asked for', () async {
      final (rig, session) = await open();
      const big = KeeperPictureRef(start: 1, hash: 'fedcba9876543210', bytes: 14 * 1024 * 1024);
      await expectLater(
        session.loadLogPicture(big),
        throwsA(isA<LogPictureTooLarge>().having((e) => e.bytes, 'bytes', 14 * 1024 * 1024)),
      );
      expect(rig.source.blobCalls, isEmpty);
    });

    test('a picture the store holds is served even though it would be over the limit now', () async {
      final (rig, session) = await open();
      await store.put(_keeper.key, Uint8List.fromList([4, 4]));
      expect(await session.loadLogPicture(_keeper), [4, 4]);
      expect(rig.source.blobCalls, isEmpty);
    });
  });

  group('an omp picture, a plain file next to the sessions folder', () {
    final ref = OmpPictureRef(sha256: _sha);

    test('is read over SFTP from <agent dir>/blobs/<sha256> and kept', () async {
      final fs = FakeFs()..addFile('/home/u/.omp/agent/blobs/$_sha', Uint8List.fromList(List.generate(5000, (i) => i % 251)));
      final (rig, session) = await open(fs: fs);

      final got = await session.loadLogPicture(ref);
      expect(got, List.generate(5000, (i) => i % 251));
      expect(rig.source.blobCalls, isEmpty, reason: 'no keeper involved');
      await stored(ref.key);
      final reads = fs.calls.where((c) => c.startsWith('read')).length;

      expect(await session.loadLogPicture(ref), got);
      expect(fs.calls.where((c) => c.startsWith('read')).length, reads, reason: 'the second ask is local');
    });

    test('a file that is not there is a picture that is gone', () async {
      final (_, session) = await open(fs: FakeFs());
      await expectLater(session.loadLogPicture(ref), throwsA(same(logPictureGone)));
      expect(logPictureGone.message, 'The picture is no longer on the machine.');
    });

    test('a file over 12 MB is refused before it is read', () async {
      final fs = FakeFs()..addFile('/home/u/.omp/agent/blobs/$_sha', Uint8List(13 * 1024 * 1024));
      final (_, session) = await open(fs: fs);
      await expectLater(session.loadLogPicture(ref), throwsA(isA<LogPictureTooLarge>()));
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty);
    });
  });
}
