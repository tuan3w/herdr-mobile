import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/data/services/apk_installer.dart';
import 'package:herdr_mobile/data/services/release_feed.dart';
import 'package:herdr_mobile/data/services/release_files.dart';

const _base = 'https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.7';

ReleaseInfo _release([String version = '0.1.7']) => ReleaseInfo(
      version: version,
      apkUrl: '$_base/herdr-mobile-$version.apk',
      size: 1000,
      pageUrl: 'https://github.com/tuan3w/herdr-mobile/releases/tag/v$version',
      notes: '### Better\n\n- a thing',
      sha256: 'a' * 64,
    );

Map<String, Object?> _github({
  String tag = 'v0.1.7',
  List<Map<String, Object?>>? assets,
}) =>
    {
      'tag_name': tag,
      'html_url': 'https://github.com/tuan3w/herdr-mobile/releases/tag/$tag',
      'body': '  notes  ',
      'assets': assets ??
          [
            {'name': 'herdr-mobile-0.1.7.apk', 'size': 1000, 'browser_download_url': '$_base/herdr-mobile-0.1.7.apk'},
            {'name': 'SHA256SUMS', 'size': 90, 'browser_download_url': '$_base/SHA256SUMS'},
          ],
    };

class _Feed implements ReleaseFeed {
  ReleaseInfo? answer;
  Object? error;
  int asked = 0;
  AppVersion? askedFor;

  @override
  Future<ReleaseInfo?> newerThan(AppVersion current) async {
    asked++;
    askedFor = current;
    if (error != null) throw error!;
    return answer;
  }
}

class _Files implements ReleaseFiles {
  File? onPhone;
  Completer<File>? running;
  final pruned = <String?>[];
  late void Function(int) report;
  bool cancelled = false;

  @override
  Future<File?> verified(ReleaseInfo release) async => onPhone;

  /// What [intact] answers: false is a file the cache lost or changed.
  bool intactAnswer = true;

  @override
  Future<bool> intact(ReleaseInfo release, File apk) async => intactAnswer;

  @override
  Future<void> prune({ReleaseInfo? keep}) async => pruned.add(keep?.version);

  @override
  UpdateDownload download(ReleaseInfo release, void Function(int received) onProgress) {
    report = onProgress;
    final c = running = Completer<File>();
    return UpdateDownload(c.future, () {
      cancelled = true;
      c.completeError(const UpdateCancelled());
    });
  }
}

class _Installer implements ApkInstaller {
  InstallStart answer = InstallStart.started;
  Object? error;
  final installed = <String>[];

  @override
  Future<InstallStart> install(File apk) async {
    if (error != null) throw error!;
    installed.add(apk.path);
    return answer;
  }
}

class _BrokenStore implements UpdateStore {
  @override
  Future<UpdateRecord> read() => Future.error(StateError('preferences unreadable'));

  @override
  Future<void> write(UpdateRecord record) => Future.error(StateError('preferences unreadable'));
}

void main() {
  group('release parsing', () {
    test('takes the APK named for the tag and its checksum file', () {
      final r = ReleaseInfo.fromGitHub(_github())!;
      expect(r.version, '0.1.7');
      expect(r.size, 1000);
      expect(r.apkUrl, '$_base/herdr-mobile-0.1.7.apk');
      expect(r.sumsUrl, '$_base/SHA256SUMS');
      expect(r.notes, 'notes');
    });

    test('prefers the digest GitHub states with the asset', () {
      final hex = 'ab' * 32;
      final r = ReleaseInfo.fromGitHub(_github(assets: [
        {
          'name': 'herdr-mobile-0.1.7.apk',
          'size': 5,
          'digest': 'sha256:${hex.toUpperCase()}',
          'browser_download_url': '$_base/herdr-mobile-0.1.7.apk',
        },
      ]))!;
      expect(r.sha256, hex);
    });

    test('never fetches from a host the release names outside the repository', () {
      final r = ReleaseInfo.fromGitHub(_github(assets: [
        {'name': 'herdr-mobile-0.1.7.apk', 'size': 5, 'browser_download_url': 'https://evil.example/herdr-mobile-0.1.7.apk'},
        {'name': 'SHA256SUMS', 'size': 5, 'browser_download_url': '$_base/SHA256SUMS'},
      ]));
      expect(r, isNull);
    });

    test('a release that is not x.y.z or has no APK is not offered', () {
      expect(ReleaseInfo.fromGitHub(_github(tag: 'v0.2.0-rc1')), isNull);
      expect(ReleaseInfo.fromGitHub(_github(assets: const [])), isNull);
    });

    test('an APK that cannot be checked is refused with a reason', () {
      expect(
        () => ReleaseInfo.fromGitHub(_github(assets: [
          {'name': 'herdr-mobile-0.1.7.apk', 'size': 5, 'browser_download_url': '$_base/herdr-mobile-0.1.7.apk'},
        ])),
        throwsA(isA<UpdateException>()),
      );
    });

    test('files outside this repository\'s release downloads are never taken', () {
      String asset(String url) => ReleaseInfo.fromGitHub(_github(assets: [
            {'name': 'herdr-mobile-0.1.7.apk', 'size': 5, 'digest': 'sha256:${'a' * 64}', 'browser_download_url': url},
          ])) == null
              ? 'refused'
              : 'taken';
      expect(asset('$_base/herdr-mobile-0.1.7.apk'), 'taken');
      expect(asset('$_base/../../../../other/repo/releases/download/v1/herdr-mobile-0.1.7.apk'), 'refused');
      expect(asset('$_base/herdr-mobile-0.1.7.apk?x=1'), 'refused');
      expect(asset('https://github.com:8443/tuan3w/herdr-mobile/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'), 'refused');
      expect(asset('https://user@github.com/tuan3w/herdr-mobile/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'), 'refused');
      expect(asset('https://github.com/other/repo/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'), 'refused');
      expect(asset('http://github.com/tuan3w/herdr-mobile/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'), 'refused');
    });

    test('a field of the wrong type is read as missing', () {
      final json = _github();
      expect(json['assets'], isA<List<Object?>>());
      expect(ReleaseInfo.fromGitHub({...json, 'tag_name': 7}), isNull);
      expect(ReleaseInfo.fromGitHub({...json, 'assets': 'x'}), isNull);
      expect(ReleaseInfo.fromGitHub({..._github(), 'body': 5})?.notes, '');
    });

    test('a remembered release survives a restart, but not tampering', () {
      final r = _release();
      expect(ReleaseInfo.decode(r.encode()), r);
      expect(ReleaseInfo.decode(r.encode().replaceAll('github.com', 'evil.example')), isNull);
      expect(ReleaseInfo.decode('not json'), isNull);
    });

    test('versions compare by number, not by text', () {
      final a = AppVersion.tryParse('v0.1.10')!;
      final b = AppVersion.tryParse('0.1.9')!;
      expect(a.compareTo(b), greaterThan(0));
      expect(AppVersion.tryParse('0.1'), isNull);
    });
  });

  group('AppUpdate', () {
    late _Feed feed;
    late _Files files;
    late _Installer installer;
    late MemoryUpdateStore store;
    late DateTime now;
    late AppUpdate update;

    setUp(() {
      feed = _Feed();
      files = _Files();
      installer = _Installer();
      store = MemoryUpdateStore();
      now = DateTime(2026, 10, 9, 12);
      update = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
        now: () => now,
      );
    });

    tearDown(() => update.dispose());

    test('a newer release is suggested, remembered, and its notes are kept', () async {
      feed.answer = _release();
      await update.check();
      expect(update.release?.version, '0.1.7');
      expect(update.stage, UpdateStage.idle);
      expect(store.record.release?.version, '0.1.7');
      expect(feed.askedFor.toString(), '0.1.6');
    });

    test('nothing newer says so, and clears an earlier suggestion', () async {
      feed.answer = _release();
      await update.check();
      feed.answer = null;
      await update.check();
      expect(update.release, isNull);
      expect(update.upToDate, isTrue);
      expect(store.record.release, isNull);
    });

    test('a failed check the person asked for says why; a daily one stays silent', () async {
      feed.error = const UpdateException('Could not reach GitHub.');
      await update.check();
      expect(update.checkProblem, isNotNull);
      expect(update.stage, UpdateStage.idle);

      final quiet = AppUpdate(
        store: MemoryUpdateStore(),
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
        now: () => now,
      );
      addTearDown(quiet.dispose);
      await quiet.checkIfDue();
      expect(quiet.checkProblem, isNull);
    });

    test('the daily check waits out its interval, also after a failure', () async {
      feed.error = const UpdateException('offline');
      await update.checkIfDue();
      expect(feed.asked, 1);

      now = now.add(const Duration(hours: 11));
      update.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(feed.asked, 1, reason: 'not due yet');

      now = now.add(const Duration(hours: 2));
      await update.checkIfDue();
      expect(feed.asked, 2);
    });

    test('the daily check does nothing when the person turned it off, or is already offered an update', () async {
      await update.setAutoCheck(false);
      await update.checkIfDue();
      expect(feed.asked, 0);

      await update.setAutoCheck(true);
      expect(feed.asked, 1, reason: 'turning it on asks at once when due');
      await Future<void>.delayed(Duration.zero);
      feed.answer = _release();
      await update.check();
      now = now.add(const Duration(days: 2));
      final before = feed.asked;
      await update.checkIfDue();
      expect(feed.asked, before);
    });

    test('download reports progress, then is ready to install; install hands the file over', () async {
      feed.answer = _release();
      await update.check();

      final done = update.download();
      expect(update.stage, UpdateStage.downloading);
      files.report(400);
      expect(update.received, 400);
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await done;
      expect(update.stage, UpdateStage.ready);

      await update.install();
      expect(installer.installed, ['/cache/updates/herdr-mobile-0.1.7.apk']);
      expect(update.needsInstallPermission, isFalse);
    });

    test('cancelling a download returns to Download with no error', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      update.cancelDownload();
      await done;
      expect(files.cancelled, isTrue);
      expect(update.stage, UpdateStage.idle);
      expect(update.problem, isNull);
      expect(update.release, isNotNull);
    });

    test('a failed download keeps the release and says what to do', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      files.running!.completeError(const UpdateException('The download stopped at 1 MB of 48 MB.'));
      await done;
      expect(update.stage, UpdateStage.idle);
      expect(update.problem, isNotNull);
      expect(update.release, isNotNull);
    });

    test('Install without the permission to install apps says so and can be tapped again', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      files.running!.complete(File('/x.apk'));
      await done;

      installer.answer = InstallStart.needsPermission;
      await update.install();
      expect(update.needsInstallPermission, isTrue);
      expect(update.stage, UpdateStage.ready);

      installer.answer = InstallStart.started;
      await update.install();
      expect(update.needsInstallPermission, isFalse);
      expect(installer.installed, hasLength(2));
    });

    test('a download that finished before a restart is ready at once', () async {
      store.record = UpdateRecord(release: _release());
      files.onPhone = File('/cache/updates/herdr-mobile-0.1.7.apk');
      await update.load();
      expect(update.release?.version, '0.1.7');
      expect(update.stage, UpdateStage.ready);
    });

    test('a failed check the person asked for is not a failed download: the panel button stays Download', () async {
      feed.answer = _release();
      await update.check();
      feed.error = const UpdateException('offline');
      await update.check();
      expect(update.checkProblem, isNotNull);
      expect(update.problem, isNull);
      expect(update.release, isNotNull);
    });

    test('a download that is not the release asks GitHub again before the next try', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      // The same version was published again, with another file.
      feed.answer = ReleaseInfo(
        version: '0.1.7',
        apkUrl: _release().apkUrl,
        size: 1200,
        pageUrl: _release().pageUrl,
        notes: 'again',
        sha256: 'b' * 64,
      );
      files.running!.completeError(const StaleRelease('The download did not match.'));
      await done;
      expect(feed.asked, 2);
      expect(update.release?.size, 1200);
      expect(update.problem, isNotNull, reason: 'the person still sees why it stopped');
      expect(update.stage, UpdateStage.idle);
    });

    test('Install never opens the installer on a file that is gone or was changed', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      files.running!.complete(File('/x.apk'));
      await done;

      files.intactAnswer = false;
      await update.install();
      expect(installer.installed, isEmpty);
      expect(update.stage, UpdateStage.idle);
      expect(update.problem, isNotNull);
      expect(update.release, isNotNull);
    });

    test('storage that cannot be read starts the updater empty instead of stopping the app', () async {
      final broken = AppUpdate(
        store: _BrokenStore(),
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
      );
      addTearDown(broken.dispose);
      await broken.load();
      expect(broken.release, isNull);
      expect(broken.stage, UpdateStage.idle);
    });

    test('after the update is installed the suggestion and its file are gone', () async {
      store.record = UpdateRecord(autoCheck: false, release: _release('0.1.6'));
      await update.load();
      expect(update.release, isNull);
      expect(store.record.release, isNull);
      expect(store.record.autoCheck, isFalse);
      expect(files.pruned, contains(null));
    });
  });
}
