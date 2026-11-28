import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/files/file_search_view_model.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

// What a person sees of a search, with the machine played by the test: when it
// asks, what it shows while the answer streams in, what a newer question does to
// an older one, and that it stops when nobody is looking.

RemoteEntry _file(String path, {DateTime? modified}) => RemoteEntry(
  name: RemotePath.basename(path),
  path: path,
  kind: RemoteEntryKind.file,
  resolvedKind: RemoteEntryKind.file,
  size: 10,
  modified: modified,
);

/// One search the model started: its spec and the way to answer it.
class _Run {
  _Run(this.spec) {
    controller = StreamController<FileSearchEvent>(onCancel: () => cancelled = true);
  }

  final FileSearchSpec spec;
  late final StreamController<FileSearchEvent> controller;
  var cancelled = false;

  void found(List<String> paths) => controller.add(FileSearchBatch([for (final p in paths) _file(p)]));

  void done({int scanned = 100, bool truncated = false, int skipped = 0}) =>
      controller.add(FileSearchDone(scanned: scanned, truncated: truncated, skippedDirs: skipped));

  void fail(Object error) => controller.addError(error);
}

void main() {
  late FakeTransport transport;
  late List<_Run> runs;
  late RemoteFiles files;

  setUp(() {
    transport = FakeTransport()..fs = FakeFs();
    runs = [];
    transport.onSearch = (spec) {
      final run = _Run(spec);
      runs.add(run);
      return run.controller.stream;
    };
    files = RemoteFiles(transport);
  });

  FileSearchViewModel make({
    Duration pause = Duration.zero,
    DateTime Function()? clock,
    FileSearchKind kind = FileSearchKind.any,
    bool hidden = false,
  }) => FileSearchViewModel(
    files: files,
    root: '/home/dev/proj',
    rootName: 'proj',
    typingPause: pause,
    clock: clock,
    kind: kind,
    hidden: hidden,
  );

  group('when it asks', () {
    test('an empty question asks nobody; text or a time window does', () async {
      final vm = make();
      addTearDown(vm.dispose);

      expect(vm.phase, SearchPhase.idle);
      vm.setQuery('   ');
      expect(runs, isEmpty, reason: 'spaces are no question');

      vm.setQuery('shot');
      expect(runs.single.spec.query, 'shot');
      expect(vm.phase, SearchPhase.searching);

      vm.setQuery('');
      expect(vm.phase, SearchPhase.idle, reason: 'the text is gone: the search is too');
      expect(runs.single.cancelled, isTrue);

      vm.setWindow(SearchWindow.hour);
      expect(runs, hasLength(2));
      expect(runs.last.spec.query, isEmpty, reason: 'a time window alone is a question');
      expect(runs.last.spec.modifiedWithin, const Duration(hours: 1));
    });

    test('typing waits for a pause, each letter restarts the wait, and only the last text is asked', () {
      fakeAsync((async) {
        final vm = make(pause: const Duration(milliseconds: 500));
        addTearDown(vm.dispose);

        vm.setQuery('s');
        async.elapse(const Duration(milliseconds: 300));
        vm.setQuery('sh');
        async.elapse(const Duration(milliseconds: 300));
        vm.setQuery('sho');
        expect(runs, isEmpty, reason: 'typing has not paused yet');

        async.elapse(const Duration(milliseconds: 500));

        expect(runs.map((r) => r.spec.query), ['sho']);
      });
    });

    test('the keyboard\u2019s search key asks at once, without waiting for the pause', () {
      fakeAsync((async) {
        final vm = make(pause: const Duration(seconds: 5));
        addTearDown(vm.dispose);

        vm.setQuery('shot');
        expect(runs, isEmpty);
        vm.submit();

        expect(runs.map((r) => r.spec.query), ['shot']);
        async.elapse(const Duration(seconds: 6));
        expect(runs, hasLength(1), reason: 'the pending pause did not ask a second time');
      });
    });

    test('"Today" is the time since local midnight; "Last hour" is an hour; Any time is no limit', () {
      final vm = make(clock: () => DateTime(2026, 11, 28, 15, 30));
      addTearDown(vm.dispose);

      vm.setWindow(SearchWindow.today);
      expect(runs.last.spec.modifiedWithin, const Duration(hours: 15, minutes: 30));
      vm.setWindow(SearchWindow.hour);
      expect(runs.last.spec.modifiedWithin, const Duration(hours: 1));
      vm.setQuery('x');
      vm.setWindow(SearchWindow.any);
      expect(runs.last.spec.modifiedWithin, isNull);
      expect(runs.last.spec.query, 'x');
    });

    test('just after midnight "Today" still asks for a positive span', () {
      final vm = make(clock: () => DateTime(2026, 11, 28));
      addTearDown(vm.dispose);

      vm.setWindow(SearchWindow.today);

      expect(runs.last.spec.modifiedWithin, const Duration(seconds: 1));
    });

    test('the folder, the kind and the hidden choice of the browser are what is asked', () {
      final vm = make(kind: FileSearchKind.dir, hidden: true);
      addTearDown(vm.dispose);

      vm.setQuery('src');

      final spec = runs.single.spec;
      expect((spec.root, spec.kind, spec.hidden), ('/home/dev/proj', FileSearchKind.dir, true));
      expect(spec.ignore, FileSearchSpec.defaultIgnore);
    });
  });

  group('what it shows while the answer streams in', () {
    test('the first batch is on screen before the search is over, in the order it arrived', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');

      runs.single.found(['/home/dev/proj/a.txt']);
      await pumpEventQueue();

      expect(vm.phase, SearchPhase.searching, reason: 'still going');
      expect(vm.results.map((e) => e.name), ['a.txt']);
      runs.single.found(['/home/dev/proj/sub/ab.txt', '/home/dev/proj/sub/deep/abc.txt']);
      await pumpEventQueue();
      expect(vm.results.map((e) => e.name), ['a.txt', 'ab.txt', 'abc.txt'], reason: 'rows are only ever added');
      expect(vm.resultCount, 3);
    });

    test('done says what was covered and whether a limit stopped it', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      runs.single
        ..found(['/home/dev/proj/a.txt'])
        ..done(scanned: 3000, truncated: true, skipped: 2);
      await pumpEventQueue();

      expect(vm.phase, SearchPhase.done);
      expect((vm.scanned, vm.truncated, vm.skippedFolders), (3000, true, 2));
      expect(vm.running, isFalse);
    });

    test('a finished search with no match is done with nothing found, not a failure', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('zzz');
      runs.single.done(scanned: 12);
      await pumpEventQueue();

      expect(vm.phase, SearchPhase.done);
      expect(vm.results, isEmpty);
      expect(vm.truncated, isFalse);
    });
  });

  group('a newer question replaces an older one', () {
    test(
      'the old stream is cancelled, the old matches go, and what the old stream still sends is thrown away',
      () async {
        final vm = make();
        addTearDown(vm.dispose);
        vm.setQuery('a');
        final first = runs.single;
        first.found(['/home/dev/proj/apple.txt']);
        await pumpEventQueue();
        expect(vm.results, hasLength(1));

        vm.setQuery('ab');

        expect(first.cancelled, isTrue);
        expect(vm.results, isEmpty, reason: 'the old matches answer an old question');
        expect(vm.phase, SearchPhase.searching);
        // A straggler from the old stream (already in flight when it was cancelled).
        first.found(['/home/dev/proj/avocado.txt']);
        first.done(scanned: 5);
        runs.last.found(['/home/dev/proj/abc.txt']);
        await pumpEventQueue();

        expect(vm.results.map((e) => e.name), ['abc.txt']);
        expect(vm.phase, SearchPhase.searching, reason: 'the old search\u2019s end is not the new one\u2019s');
        expect(vm.scanned, 0);
      },
    );

    test('changing the time window mid-stream does the same', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      final first = runs.single;
      first.found(['/home/dev/proj/old.txt']);
      await pumpEventQueue();

      vm.setWindow(SearchWindow.hour);
      first.found(['/home/dev/proj/stale.txt']);
      await pumpEventQueue();

      expect(first.cancelled, isTrue);
      expect(vm.results, isEmpty);
      expect(runs.last.spec.modifiedWithin, const Duration(hours: 1));
    });

    test('a pause that has not elapsed yet leaves the matches on screen', () {
      fakeAsync((async) {
        final vm = make(pause: const Duration(milliseconds: 500));
        addTearDown(vm.dispose);
        vm.setQuery('a');
        async.elapse(const Duration(milliseconds: 500));
        runs.single.found(['/home/dev/proj/a.txt']);
        async.flushMicrotasks();

        vm.setQuery('ab');

        expect(vm.results.map((e) => e.name), ['a.txt'], reason: 'nothing changes until the new search starts');
        async.elapse(const Duration(milliseconds: 500));
        expect(vm.results, isEmpty);
      });
    });
  });

  group('when it fails', () {
    test('the text and the window survive; what was found stays; Retry asks again', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('shot');
      vm.setWindow(SearchWindow.today);
      final run = runs.last;
      run.found(['/home/dev/proj/shot.png']);
      run.fail(RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost', path: '/home/dev/proj'));
      await pumpEventQueue();

      expect(vm.phase, SearchPhase.failed);
      expect(vm.error!.kind, RemoteFileErrorKind.network);
      expect((vm.query, vm.window), ('shot', SearchWindow.today));
      expect(vm.results.map((e) => e.name), ['shot.png']);
      expect(vm.running, isFalse);

      vm.retry();

      expect(runs, hasLength(3));
      expect(runs.last.spec.query, 'shot');
      expect(runs.last.spec.modifiedWithin, isNotNull);
      expect(vm.phase, SearchPhase.searching);
      expect(vm.error, isNull);
    });

    test('a folder that is gone or refused says so as a file error', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      runs.single.fail(RemoteFileException(RemoteFileErrorKind.permission, 'denied', path: '/home/dev/proj'));
      await pumpEventQueue();

      expect(vm.error!.kind, RemoteFileErrorKind.permission);
    });

    test('an error that is not a file error is shown as a connection problem', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      runs.single.fail(StateError('boom'));
      await pumpEventQueue();

      expect(vm.phase, SearchPhase.failed);
      expect(vm.error!.kind, RemoteFileErrorKind.network);
    });

    test('a stream that ends without saying it is done is not a finished search', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      runs.single.found(['/home/dev/proj/a.txt']);
      unawaited(runs.single.controller.close());
      await pumpEventQueue();

      expect(vm.phase, SearchPhase.failed);
      expect(vm.results, hasLength(1));
    });
  });

  group('it runs only while somebody looks', () {
    test('leaving the screen or the app cancels the stream; coming back goes on without moving the rows', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      runs.single.found(['/home/dev/proj/one.txt', '/home/dev/proj/two.txt']);
      await pumpEventQueue();

      vm.setActive(false);

      expect(runs.single.cancelled, isTrue, reason: 'nothing is searched for nobody');
      expect(vm.running, isFalse);
      expect(vm.results, hasLength(2), reason: 'what was found stays');

      vm.setActive(true);

      expect(runs, hasLength(2), reason: 'it takes up again');
      expect(vm.results, hasLength(2), reason: 'the rows are not cleared while it does');
      // The second run finds the same two again, then one new match.
      runs.last.found(['/home/dev/proj/one.txt', '/home/dev/proj/two.txt']);
      runs.last.found(['/home/dev/proj/three.txt']);
      runs.last.done();
      await pumpEventQueue();

      expect(vm.results.map((e) => e.name), ['one.txt', 'two.txt', 'three.txt'], reason: 'no row twice, none moved');
      expect(vm.phase, SearchPhase.done);
    });

    test('a finished search is not run again when the screen comes back', () async {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setQuery('a');
      runs.single
        ..found(['/home/dev/proj/a.txt'])
        ..done();
      await pumpEventQueue();

      vm.setActive(false);
      vm.setActive(true);

      expect(runs, hasLength(1));
      expect(vm.phase, SearchPhase.done);
    });

    test('a question asked while the screen is covered starts when it is in front again', () {
      final vm = make();
      addTearDown(vm.dispose);
      vm.setActive(false);

      vm.setQuery('late');

      expect(runs, isEmpty, reason: 'nothing runs behind another screen');
      expect(vm.phase, SearchPhase.searching, reason: 'but it is the question');
      vm.setActive(true);
      expect(runs.single.spec.query, 'late');
    });

    test('a pause that was running when the screen was covered does not fire', () {
      fakeAsync((async) {
        final vm = make(pause: const Duration(milliseconds: 500));
        addTearDown(vm.dispose);
        vm.setQuery('a');
        vm.setActive(false);

        async.elapse(const Duration(seconds: 2));

        expect(runs, isEmpty);
      });
    });

    test('closing the screen cancels the stream, and nothing it sends later is used', () async {
      final vm = make();
      vm.setQuery('a');
      final run = runs.single;

      vm.dispose();

      expect(run.cancelled, isTrue);
      run.found(['/home/dev/proj/a.txt']);
      await pumpEventQueue();
    });
  });

  group('over a machine without the agent helper', () {
    test('a search is the bounded walk over the listing, with the same ignore names', () async {
      final fs = FakeFs()
        ..addFile('/home/dev/proj/shot-1.png', 'x')
        ..addFile('/home/dev/proj/sub/shot-2.png', 'x')
        ..addFile('/home/dev/proj/node_modules/pkg/shot-3.png', 'x')
        ..addFile('/home/dev/proj/.hidden/shot-4.png', 'x');
      final plain = FakeTransport()..fs = fs;
      final vm = FileSearchViewModel(
        files: RemoteFiles(plain),
        root: '/home/dev/proj',
        rootName: 'proj',
        typingPause: Duration.zero,
      );
      addTearDown(vm.dispose);

      vm.setQuery('shot');
      while (vm.phase == SearchPhase.searching) {
        await pumpEventQueue();
      }

      expect(vm.phase, SearchPhase.done);
      expect(vm.results.map((e) => e.path), ['/home/dev/proj/shot-1.png', '/home/dev/proj/sub/shot-2.png']);
      expect(vm.truncated, isFalse);
      expect(vm.scanned, greaterThan(0));
    });
  });
}
