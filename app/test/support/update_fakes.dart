import 'dart:async';
import 'dart:io';

import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/services/apk_installer.dart';
import 'package:herdr_mobile/data/services/release_feed.dart';
import 'package:herdr_mobile/data/services/release_files.dart';

/// The release feed: answers [answer] (null: nothing newer) or throws [error].
class FakeReleaseFeed implements ReleaseFeed {
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

/// The downloaded files: a download stays open until the test completes
/// [running] (or cancels it), and reports progress through [report].
class FakeReleaseFiles implements ReleaseFiles {
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

/// Android's installer: answers [answer], or throws [error].
class FakeApkInstaller implements ApkInstaller {
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
