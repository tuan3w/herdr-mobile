import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/services/release_feed.dart';

void main() {
  late HttpServer server;
  late int status;
  late String body;
  String? location;
  String? userAgent;

  setUp(() async {
    status = 200;
    body = '';
    location = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((req) async {
      userAgent = req.headers.value(HttpHeaders.userAgentHeader);
      req.response.statusCode = status;
      if (location != null) req.response.headers.set(HttpHeaders.locationHeader, location!);
      req.response.write(body);
      await req.response.close();
    }));
  });

  tearDown(() => server.close(force: true));

  GitHubReleaseFeed feed() => GitHubReleaseFeed(url: Uri.parse('http://127.0.0.1:${server.port}/latest'));

  String release(String tag, {Object? size = 10}) {
    final base = 'https://github.com/tuan3w/herdr-mobile/releases/download/$tag';
    return jsonEncode({
      'tag_name': tag,
      'assets': [
        {'name': 'herdr-mobile-${tag.substring(1)}.apk', 'size': size, 'browser_download_url': '$base/herdr-mobile-${tag.substring(1)}.apk'},
        {'name': 'SHA256SUMS', 'size': 10, 'browser_download_url': '$base/SHA256SUMS'},
      ],
    });
  }

  final current = AppVersion.tryParse('0.1.6')!;

  test('offers a newer release and says who is asking', () async {
    body = release('v0.1.7');
    final r = await feed().newerThan(current);
    expect(r?.version, '0.1.7');
    expect(userAgent, startsWith('herdr-mobile/'));
  });

  test('the same or an older release is not an update', () async {
    body = release('v0.1.6');
    expect(await feed().newerThan(current), isNull);
    body = release('v0.1.5');
    expect(await feed().newerThan(current), isNull);
  });

  test('a limited, missing or broken GitHub is an error, not "up to date"', () async {
    for (final code in [403, 429, 404, 500]) {
      status = code;
      await expectLater(feed().newerThan(current), throwsA(isA<UpdateException>()), reason: '$code');
    }
  });

  test('an answer that is not a release is an error, not "up to date"', () async {
    body = '<html>captive portal</html>';
    await expectLater(feed().newerThan(current), throwsA(isA<UpdateException>()));
    body = '[1, 2]';
    await expectLater(feed().newerThan(current), throwsA(isA<UpdateException>()));
  });

  test('a field of the wrong type is read as missing, never a raw Dart error', () async {
    body = release('v0.1.7', size: '10');
    expect(await feed().newerThan(current), isNull);
    body = jsonEncode({'tag_name': 7, 'assets': 'nope', 'body': 3});
    expect(await feed().newerThan(current), isNull);
  });

  test('a redirect away from GitHub is refused', () async {
    status = 302;
    location = 'https://evil.example/latest';
    await expectLater(feed().newerThan(current), throwsA(isA<UpdateException>()));
  });

  test('an unreachable host is an error', () async {
    final port = server.port;
    await server.close(force: true);
    final dead = GitHubReleaseFeed(url: Uri.parse('http://127.0.0.1:$port/latest'));
    await expectLater(dead.newerThan(current), throwsA(isA<UpdateException>()));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
}
