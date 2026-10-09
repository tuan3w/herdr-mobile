import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/open_link.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records what the app asked the phone to open.
class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];
  final modes = <PreferredLaunchMode>[];
  var succeeds = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    modes.add(options.mode);
    return succeeds;
  }
}

void main() {
  late _Launcher launcher;

  setUp(() {
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
  });

  group('where a link opens', () {
    test('in a tab over the app, never in the browser app: Back must return to where the person was', () async {
      await openTappedLink('https://example.com/a');
      await openInBrowser('https://login.tailscale.com/a/abc');
      expect(launcher.modes, everyElement(PreferredLaunchMode.inAppBrowserView));
      expect(launcher.modes, hasLength(2));
    });
  });

  group('a link the user tapped in terminal output', () {
    test('opens https and, only here, http', () async {
      expect(await openTappedLink('https://example.com/a?b=1#c'), isTrue);
      expect(await openTappedLink('http://example.org/a'), isTrue);
      expect(launcher.opened, ['https://example.com/a?b=1#c', 'http://example.org/a']);
    });

    test('refuses everything else', () async {
      for (final url in [
        'ftp://example.com/x',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'intent://scan/#Intent;scheme=zxing;end',
        'tel:+123456789',
        'https://',
        'http:///nohost',
        'example.com/relative',
        '',
      ]) {
        expect(await openTappedLink(url), isFalse, reason: url);
      }
      expect(launcher.opened, isEmpty);
    });

    test('reports a phone with no browser', () async {
      launcher.succeeds = false;
      expect(await openTappedLink('https://example.com'), isFalse);
    });
  });

  group('the login banner opener', () {
    test('stays https only', () async {
      expect(await openInBrowser('http://example.com/login'), isFalse);
      expect(await openInBrowser('https://example.com/login'), isTrue);
      expect(launcher.opened, ['https://example.com/login']);
    });
  });

  group('addresses on the machine itself', () {
    test('are recognised', () {
      for (final url in [
        'http://localhost:3000',
        'https://LOCALHOST/x',
        'http://app.localhost:8080/',
        'http://127.0.0.1:8080/a',
        'http://127.1.2.3/',
        'http://0.0.0.0:5000',
        'http://[::1]:5173/',
        'http://[::]:80/',
        'http://devbox.local:4000/ui',
        'https://My-Mac.LOCAL/',
      ]) {
        expect(isMachineLocalUrl(url), isTrue, reason: url);
      }
    });

    test('are told apart from addresses the phone can reach', () {
      for (final url in [
        'https://example.com',
        'https://localhost.example.com/x',
        'http://notlocal.com/local',
        'http://192.168.1.20:3000',
        'http://10.0.0.5/',
        'http://127.example.com/',
        'https://local.dev/',
        'not a url',
        '',
      ]) {
        expect(isMachineLocalUrl(url), isFalse, reason: url);
      }
    });
  });
}
