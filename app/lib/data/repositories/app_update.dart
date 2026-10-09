import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../models/release_info.dart';
import '../services/apk_installer.dart';
import '../services/release_feed.dart';
import '../services/release_files.dart';

/// What is remembered between launches: the person's choice, when GitHub was
/// last asked, and the newer release it named (so the suggestion is still
/// there after a restart, until it is installed).
@immutable
class UpdateRecord {
  const UpdateRecord({this.autoCheck = true, this.lastCheck, this.release});

  final bool autoCheck;
  final DateTime? lastCheck;
  final ReleaseInfo? release;
}

abstract interface class UpdateStore {
  Future<UpdateRecord> read();

  Future<void> write(UpdateRecord record);
}

class PrefsUpdateStore implements UpdateStore {
  static const _auto = 'update.auto.v1';
  static const _last = 'update.lastCheck.v1';
  static const _release = 'update.release.v1';

  @override
  Future<UpdateRecord> read() async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_last);
    return UpdateRecord(
      autoCheck: prefs.getBool(_auto) ?? true,
      lastCheck: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      release: ReleaseInfo.decode(prefs.getString(_release)),
    );
  }

  @override
  Future<void> write(UpdateRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_auto, record.autoCheck);
    final at = record.lastCheck;
    if (at == null) {
      await prefs.remove(_last);
    } else {
      await prefs.setInt(_last, at.millisecondsSinceEpoch);
    }
    final release = record.release;
    if (release == null) {
      await prefs.remove(_release);
    } else {
      await prefs.setString(_release, release.encode());
    }
  }
}

/// For tests.
class MemoryUpdateStore implements UpdateStore {
  MemoryUpdateStore([this.record = const UpdateRecord()]);

  UpdateRecord record;

  @override
  Future<UpdateRecord> read() async => record;

  @override
  Future<void> write(UpdateRecord record) async => this.record = record;
}

enum UpdateStage {
  /// Nothing running: up to date, or a newer [AppUpdate.release] waiting.
  idle,

  /// Asking GitHub for the newest release.
  checking,

  /// Downloading [AppUpdate.release]'s APK; [AppUpdate.received] bytes so far.
  downloading,

  /// The APK is on the phone and its checksum matched: Install is next.
  ready,
}

/// Looking for a newer herdr mobile on GitHub, downloading it and handing it
/// to Android's installer: the app's own update, for a phone that installs
/// from the release page by hand.
///
/// Quiet by design: an update is never an interruption. It shows as a mark on
/// the Settings tab and a panel at the top of Settings, never a toast or a
/// notification. GitHub is asked once a [checkEvery] while the app is in
/// front (and the person allows it), or at once on request; the APK is
/// downloaded only when the person taps Download, and installed only after
/// their confirmation in Android's own dialog.
class AppUpdate extends ChangeNotifier {
  AppUpdate({
    required this.store,
    required this.feed,
    required this.files,
    required this.installer,
    AppVersion? current,
    DateTime Function()? now,
  })  : _current = current ?? AppVersion.tryParse(appVersion)!,
        _now = now ?? DateTime.now;

  /// How long a check stays fresh. Also the wait after a failed one: a phone
  /// on a bad radio is not asked again every time the app is opened.
  static const checkEvery = Duration(hours: 12);

  final UpdateStore store;
  final ReleaseFeed feed;
  final ReleaseFiles files;
  final ApkInstaller installer;
  final AppVersion _current;
  final DateTime Function() _now;

  bool _autoCheck = true;
  DateTime? _lastCheck;
  ReleaseInfo? _release;
  UpdateStage _stage = UpdateStage.idle;
  int _received = 0;
  String? _problem;
  String? _checkProblem;
  bool _upToDate = false;
  bool _needsPermission = false;
  bool _installing = false;
  File? _apk;
  UpdateDownload? _job;
  bool _disposed = false;

  /// Whether GitHub is asked about twice a day without the person asking.
  bool get autoCheck => _autoCheck;

  /// The newer release the person can install, or null.
  ReleaseInfo? get release => _release;

  UpdateStage get stage => _stage;

  /// Bytes of [release] received while [stage] is downloading.
  int get received => _received;

  /// What went wrong in the last download or install, in words for the
  /// person. Cleared by the next step.
  String? get problem => _problem;

  /// Why the last check the person asked for failed (a check that runs by
  /// itself stays silent). Kept apart from [problem]: a failed check must
  /// never turn the panel's button into a 50 MB retry.
  String? get checkProblem => _checkProblem;

  /// The last check found nothing newer than this version.
  bool get upToDate => _upToDate && _release == null;

  /// Install was tapped before Android allowed this app to install apps: the
  /// page that allows it is open, and Install works once it is allowed.
  bool get needsInstallPermission => _needsPermission;

  /// Reads what was remembered. Before the first frame: the suggestion is
  /// there from the start.
  Future<void> load() async {
    try {
      final saved = await store.read();
      _autoCheck = saved.autoCheck;
      _lastCheck = saved.lastCheck;
      final release = saved.release;
      if (release == null) return;
      final known = AppVersion.tryParse(release.version)!;
      if (known.compareTo(_current) <= 0) {
        // Installed (or older than what is installed): its file is not needed.
        unawaited(files.prune());
        await store.write(UpdateRecord(autoCheck: _autoCheck, lastCheck: _lastCheck));
        return;
      }
      _release = release;
      _apk = await files.verified(release);
      if (_apk != null) _stage = UpdateStage.ready;
      unawaited(files.prune(keep: release));
    } on Object {
      // Looking for updates is never worth keeping the person from their
      // agents: unreadable preferences or storage start it as if new.
    }
  }

  Future<void> setAutoCheck(bool on) async {
    if (on == _autoCheck) return;
    _autoCheck = on;
    _notify();
    await _save();
    if (on) unawaited(checkIfDue());
  }

  /// The app came to the front: ask GitHub when the person allows it and the
  /// last answer is old.
  void onLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(checkIfDue());
  }

  Future<void> checkIfDue() async {
    if (!_autoCheck || _stage != UpdateStage.idle || _release != null) return;
    final last = _lastCheck;
    if (last != null && _now().difference(last) < checkEvery) return;
    await check(manual: false);
  }

  /// Asks GitHub for the newest release. A request by the person ([manual])
  /// says why it failed; a daily one stays silent and tries again later.
  Future<void> check({bool manual = true}) async {
    if (_stage != UpdateStage.idle) return;
    _stage = UpdateStage.checking;
    if (manual) _checkProblem = null;
    _notify();
    try {
      final found = await feed.newerThan(_current);
      if (found == null) {
        _release = null;
        _apk = null;
        _upToDate = true;
        _problem = null;
        unawaited(files.prune());
      } else if (found != _release) {
        _release = found;
        _upToDate = false;
        _problem = null;
        _apk = await files.verified(found);
        unawaited(files.prune(keep: found));
      }
      _checkProblem = null;
    } on Object catch (e) {
      if (manual) _checkProblem = e is UpdateException ? e.message : 'Could not look for updates.';
    } finally {
      _lastCheck = _now();
      _stage = _apk != null && _release != null ? UpdateStage.ready : UpdateStage.idle;
      _notify();
      await _save();
    }
  }

  /// Downloads [release]'s APK and checks it. The person's tap: it costs
  /// [ReleaseInfo.size] bytes of whatever connection the phone is on.
  Future<void> download() async {
    final release = _release;
    if (release == null || _stage != UpdateStage.idle) return;
    _stage = UpdateStage.downloading;
    _received = 0;
    _problem = null;
    _needsPermission = false;
    _notify();
    final job = _job = files.download(release, (n) {
      _received = n;
      _notify();
    });
    var stale = false;
    try {
      _apk = await job.done;
      _stage = UpdateStage.ready;
    } on UpdateCancelled {
      _stage = UpdateStage.idle;
    } on StaleRelease catch (e) {
      _stage = UpdateStage.idle;
      _problem = e.message;
      stale = true;
    } on UpdateException catch (e) {
      _stage = UpdateStage.idle;
      _problem = e.message;
    } finally {
      _job = null;
      _notify();
    }
    // The release was probably published again under the same tag: read it
    // again now (one small request), so the next Download is for what is
    // there, not another 50 MB for the old description of it.
    if (stale) await _refresh();
  }

  Future<void> _refresh() async {
    final message = _problem;
    await check(manual: false);
    // A check clears what it is not about; the download's reason stays.
    if (_release != null) {
      _problem = message;
      _notify();
    }
  }

  /// Stops a download. What was received is kept for the next try.
  void cancelDownload() => _job?.cancel();

  /// Opens Android's installer on the verified APK. Without the permission to
  /// install apps Android's page for it opens instead, and Install is tapped
  /// again once it is allowed.
  Future<void> install() async {
    final release = _release;
    final apk = _apk;
    if (_stage != UpdateStage.ready || release == null || apk == null || _installing) return;
    _installing = true;
    _problem = null;
    _needsPermission = false;
    try {
      // Android may have cleared the cache, or something cut the file, since
      // it was verified: say so and offer the download again, rather than
      // open an installer on bytes that are not the release.
      if (!await files.intact(release, apk)) {
        _apk = null;
        _stage = UpdateStage.idle;
        _problem = 'The update file is gone or changed. Download it again.';
      } else {
        _needsPermission = await installer.install(apk) == InstallStart.needsPermission;
      }
    } on UpdateException catch (e) {
      _problem = e.message;
    } finally {
      _installing = false;
      _notify();
    }
  }

  Future<void> _save() => store.write(UpdateRecord(autoCheck: _autoCheck, lastCheck: _lastCheck, release: _release));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _job?.cancel();
    super.dispose();
  }
}
