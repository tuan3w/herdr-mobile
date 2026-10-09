import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../app_info.dart';
import '../models/release_info.dart';

/// Where the newest release is read from.
abstract interface class ReleaseFeed {
  /// The newest release that is newer than [current] and can be installed, or
  /// null when there is none. Throws [UpdateException] with words for the
  /// person when GitHub cannot be asked or answers nonsense.
  Future<ReleaseInfo?> newerThan(AppVersion current);
}

const _unreadable = UpdateException('GitHub sent something herdr could not read. Try again later.');

/// Words for what went wrong talking to GitHub, for [UpdateException]. A
/// failure the person caused or can fix says so; everything else says what
/// stopped.
UpdateException updateFailure(Object error, {String doing = 'reach GitHub'}) {
  if (error is UpdateException) return error;
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is HttpException) {
    return UpdateException('Could not $doing. Check the connection and try again.');
  }
  if (error is FileSystemException) {
    return const UpdateException('Could not save the update on this phone. Free some space and try again.');
  }
  if (error is TypeError || error is FormatException) return _unreadable;
  return UpdateException('Could not $doing: $error');
}

/// The one HTTP failure message for a status the code does not expect.
UpdateException httpFailure(int status) => switch (status) {
      403 || 429 => const UpdateException('GitHub is limiting requests from this network. Try again later.'),
      404 => const UpdateException('That release is no longer on GitHub. Check for updates again.'),
      _ => UpdateException('GitHub answered $status. Try again later.'),
    };

/// Where a redirect may lead: GitHub, and the hosts it serves release files
/// from (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`),
/// over https. A redirect anywhere else is refused, so a hostile hop cannot
/// name its own file server.
bool _trustedRedirect(Uri uri) =>
    uri.scheme == 'https' &&
    (uri.host == 'github.com' || uri.host == 'api.github.com' || uri.host.endsWith('.githubusercontent.com'));

/// GETs [uri], following at most four redirects by hand (each checked by
/// [_trustedRedirect]) with the same [headers]. Every request says who is
/// asking: the app's name and version, and nothing else of its own.
Future<HttpClientResponse> openGet(HttpClient client, Uri uri, {Map<String, String> headers = const {}}) async {
  var url = uri;
  for (var hops = 0;; hops++) {
    final request = await client.getUrl(url);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'herdr-mobile/$appVersion');
    headers.forEach(request.headers.set);
    final response = await request.close();
    if (!response.isRedirect) return response;
    await response.drain<void>();
    final location = response.headers.value(HttpHeaders.locationHeader);
    final next = location == null ? null : url.resolve(location);
    if (hops >= 4 || next == null || !_trustedRedirect(next)) {
      throw const UpdateException('GitHub sent the download somewhere herdr will not follow. Try again later.');
    }
    url = next;
  }
}

/// [body] with an error when nothing arrives for [idle]: a connection that
/// went quiet (a handover between Wi-Fi and mobile data) must fail, not sit
/// at "downloading" for ever.
Stream<List<int>> failWhenStalled(Stream<List<int>> body, Duration idle) => body.timeout(
      idle,
      onTimeout: (sink) {
        sink
          ..addError(TimeoutException('no data for $idle'))
          ..close();
      },
    );

/// All of [body] as text, or [_unreadable] when it is longer than [limit].
Future<String> readLimited(Stream<List<int>> body, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in body) {
    bytes.add(chunk);
    if (bytes.length > limit) throw _unreadable;
  }
  return utf8.decode(bytes.takeBytes());
}

/// `https://api.github.com/repos/<repo>/releases/latest`: the newest published
/// release, which GitHub never makes a draft or a prerelease.
///
/// One small request, only when the person asked or the check is due; it
/// carries nothing but the app's name and version in the User-Agent.
class GitHubReleaseFeed implements ReleaseFeed {
  GitHubReleaseFeed({HttpClient Function()? client, Uri? url})
      : _client = client ?? HttpClient.new,
        _url = url ?? Uri.parse('https://api.github.com/repos/$appRepository/releases/latest');

  final HttpClient Function() _client;
  final Uri _url;

  static const _timeout = Duration(seconds: 15);

  /// More than any release notes need; a bigger answer is not one.
  static const _maxBytes = 1 << 20;

  @override
  Future<ReleaseInfo?> newerThan(AppVersion current) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 10);
    try {
      final body = await _get(client).timeout(_timeout);
      final Object? json;
      try {
        json = jsonDecode(body);
      } on FormatException {
        throw _unreadable;
      }
      if (json is! Map<String, Object?>) throw _unreadable;
      final release = ReleaseInfo.fromGitHub(json);
      if (release == null) return null;
      final version = AppVersion.tryParse(release.version)!;
      return version.compareTo(current) > 0 ? release : null;
    } on Object catch (e) {
      throw updateFailure(e);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _get(HttpClient client) async {
    final response = await openGet(client, _url, headers: {HttpHeaders.acceptHeader: 'application/vnd.github+json'});
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw httpFailure(response.statusCode);
    }
    return readLimited(response, _maxBytes);
  }
}
