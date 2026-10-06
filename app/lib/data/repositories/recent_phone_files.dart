import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One file of the phone that was attached before: its name and size, and,
/// when it was uploaded, where its copy lies on [machineId]'s host (so the
/// same file is attached again without sending it again).
@immutable
class RecentPhoneFile {
  const RecentPhoneFile({required this.name, required this.size, this.machineId, this.hostPath});

  final String name;
  final int size;
  final String? machineId;
  final String? hostPath;

  @override
  bool operator ==(Object other) =>
      other is RecentPhoneFile &&
      other.name == name &&
      other.size == size &&
      other.machineId == machineId &&
      other.hostPath == hostPath;

  @override
  int get hashCode => Object.hash(name, size, machineId, hostPath);

  Map<String, Object?> toJson() => {
    'name': name,
    'size': size,
    if (machineId != null) 'machine': machineId,
    if (hostPath != null) 'path': hostPath,
  };

  static RecentPhoneFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final size = json['size'];
    if (name is! String || name.isEmpty || size is! int) return null;
    final machine = json['machine'];
    final path = json['path'];
    return RecentPhoneFile(
      name: name,
      size: size,
      machineId: machine is String ? machine : null,
      hostPath: path is String ? path : null,
    );
  }
}

/// Where the list is kept between launches.
abstract interface class RecentPhoneFilesStore {
  Future<List<RecentPhoneFile>> read();

  Future<void> write(List<RecentPhoneFile> files);
}

class PrefsRecentPhoneFilesStore implements RecentPhoneFilesStore {
  static const _key = 'attach.recentFiles.v1';

  @override
  Future<List<RecentPhoneFile>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final json = jsonDecode(raw);
      if (json is! List) return const [];
      return [
        for (final item in json) ?RecentPhoneFile.fromJson(item),
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> write(List<RecentPhoneFile> files) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final f in files) f.toJson()]));
  }
}

/// The last [maxCount] files of the phone that were attached, newest first.
/// Names, sizes and a host path only: never content, never a phone path.
class RecentPhoneFiles extends ChangeNotifier {
  RecentPhoneFiles(this._store);

  static const maxCount = 10;

  final RecentPhoneFilesStore _store;
  var _files = const <RecentPhoneFile>[];
  Future<void>? _loading;

  List<RecentPhoneFile> get files => _files;

  /// Reads the saved list once.
  Future<void> load() => _loading ??= () async {
    _files = (await _store.read()).take(maxCount).toList(growable: false);
    notifyListeners();
  }();

  /// [file] becomes the newest entry; an older entry of the same name and
  /// size goes (a file attached twice is listed once).
  Future<void> add(RecentPhoneFile file) async {
    await load();
    _files = [
      file,
      for (final f in _files)
        if (!(f.name == file.name && f.size == file.size)) f,
    ].take(maxCount).toList(growable: false);
    notifyListeners();
    await _store.write(_files);
  }

  Future<void> remove(RecentPhoneFile file) async {
    await load();
    _files = [for (final f in _files) if (f != file) f];
    notifyListeners();
    await _store.write(_files);
  }
}
