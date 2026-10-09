import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_info.dart';

/// `48 MB` (one decimal under 10 MB), for sizes the person reads.
String megabytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// Why an update step failed, in words for the person: what happened and what
/// to do next. Everything the update code throws on purpose is one of these.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The bytes GitHub served are not the release the app was told about: a
/// checksum that does not match, more bytes than the release has, or a range
/// the file cannot satisfy. The usual cause is a release re-published under
/// the same tag, so the app asks GitHub for it again before offering another
/// download.
class StaleRelease extends UpdateException {
  const StaleRelease(super.message);
}

/// `0.1.7` as numbers, for comparing. Only plain `x.y.z` (with an optional
/// leading `v`): a tag like `v0.2.0-rc1` is not a release to offer.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  static AppVersion? tryParse(String text) {
    final m = RegExp(r'^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})$').firstMatch(text.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// A published release the app could install: one APK, and how to prove the
/// download is the file that was published.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.apkUrl,
    required this.size,
    required this.pageUrl,
    required this.notes,
    this.sha256,
    this.sumsUrl,
  });

  /// `https://github.com/<repo>/releases/download/v<version>/<name>`: the one
  /// place a release file may come from. Compared as a parsed address, not a
  /// string prefix: dot segments, userinfo, a port or a query would pass a
  /// prefix test and name another repository or host.
  static bool isReleaseFile(String url, String version, String name) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        !uri.hasPort &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.path == '/$appRepository/releases/download/v$version/$name';
  }

  /// The release's page, built from the version: never taken from a server.
  static String pageFor(String version) => '$appRepositoryUrl/releases/tag/v$version';

  /// `0.1.7`.
  final String version;
  final String apkUrl;

  /// Bytes; the download is complete only at exactly this size.
  final int size;

  /// The release's page, for "open on GitHub".
  final String pageUrl;

  /// The release notes: the version's section of `CHANGELOG.md`, as Markdown.
  final String notes;

  /// Lowercase hex SHA-256 of the APK, when GitHub states it with the asset.
  final String? sha256;

  /// A `SHA256SUMS` file of the release, used when [sha256] is not given.
  final String? sumsUrl;

  /// The APK's name on disk and on GitHub.
  String get fileName => 'herdr-mobile-$version.apk';

  /// What a release object of GitHub's API (`releases/latest`) says, or null
  /// when it is not a version this app can install: no `x.y.z` tag, or no
  /// APK. Throws [UpdateException] for a release that names an APK but gives
  /// no way to check it. Fields of the wrong type are treated as absent.
  static ReleaseInfo? fromGitHub(Map<String, Object?> json) {
    final tag = json['tag_name'];
    final version = tag is String ? AppVersion.tryParse(tag) : null;
    if (version == null) return null;
    final v = version.toString();
    final name = 'herdr-mobile-$v.apk';
    String? apkUrl;
    int? size;
    String? sha256;
    String? sumsUrl;
    final assets = json['assets'];
    for (final asset in (assets is List<Object?> ? assets : const <Object?>[])) {
      if (asset is! Map<String, Object?>) continue;
      final url = asset['browser_download_url'];
      if (url is! String) continue;
      if (asset['name'] == name && isReleaseFile(url, v, name)) {
        apkUrl = url;
        final s = asset['size'];
        size = s is int ? s : null;
        final digest = asset['digest'];
        if (digest is String && digest.startsWith('sha256:')) {
          final hex = digest.substring(7).toLowerCase();
          if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) sha256 = hex;
        }
      } else if (asset['name'] == 'SHA256SUMS' && isReleaseFile(url, v, 'SHA256SUMS')) {
        sumsUrl = url;
      }
    }
    if (apkUrl == null || size == null || size <= 0) return null;
    if (sha256 == null && sumsUrl == null) {
      throw UpdateException('Version $v has no checksum, so herdr will not install it.');
    }
    final body = json['body'];
    return ReleaseInfo(
      version: v,
      apkUrl: apkUrl,
      size: size,
      pageUrl: pageFor(v),
      notes: body is String ? body.trim() : '',
      sha256: sha256,
      sumsUrl: sumsUrl,
    );
  }

  factory ReleaseInfo.fromJson(Map<String, Object?> json) => ReleaseInfo(
        version: json['version']! as String,
        apkUrl: json['apkUrl']! as String,
        size: json['size']! as int,
        pageUrl: json['pageUrl']! as String,
        notes: json['notes'] as String? ?? '',
        sha256: json['sha256'] as String?,
        sumsUrl: json['sumsUrl'] as String?,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'apkUrl': apkUrl,
        'size': size,
        'pageUrl': pageUrl,
        'notes': notes,
        'sha256': sha256,
        'sumsUrl': sumsUrl,
      };

  /// What is written to preferences, so a suggestion survives a restart.
  String encode() => jsonEncode(toJson());

  /// The release [encode] wrote, or null for anything unreadable or whose
  /// URLs are not this repository's release files: preferences are not
  /// trusted either.
  static ReleaseInfo? decode(String? text) {
    if (text == null) return null;
    try {
      final r = ReleaseInfo.fromJson(jsonDecode(text) as Map<String, Object?>);
      final sums = r.sumsUrl;
      final version = AppVersion.tryParse(r.version);
      if (version == null ||
          version.toString() != r.version ||
          !isReleaseFile(r.apkUrl, r.version, r.fileName) ||
          (sums != null && !isReleaseFile(sums, r.version, 'SHA256SUMS')) ||
          (r.sha256 == null && sums == null) ||
          (r.sha256 != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(r.sha256!)) ||
          r.pageUrl != pageFor(r.version) ||
          r.size <= 0) {
        return null;
      }
      return r;
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is ReleaseInfo && other.encode() == encode();

  @override
  int get hashCode => Object.hash(version, apkUrl, size, sha256);
}
