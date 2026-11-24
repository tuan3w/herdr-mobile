// Where a page of a machine shown in herdr may go: only the bridge's own
// listeners load in the view; the web is offered to the phone's browser on a
// tap; the rest opens nowhere.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/ui/features/web/web_navigation.dart';

void main() {
  const ports = {8790, 41999};
  WebNavigation decide(String url, {bool mainFrame = true}) =>
      webNavigation(Uri.parse(url), ports: ports, mainFrame: mainFrame);

  test('the preview\'s own listeners load, by the name their cookie is set for', () {
    for (final url in [
      'http://localhost:8790/',
      'http://localhost:8790/page2.html#section-b',
      'http://LOCALHOST:8790/',
      'http://localhost:41999/__herdr/open?t=x&to=/',
    ]) {
      expect(decide(url), WebNavigation.load, reason: url);
    }
    expect(decide('about:blank'), WebNavigation.load);
  });

  test('another port, name or spelling of the phone itself loads nowhere: not here, and not in the browser', () {
    for (final url in [
      'http://localhost:3000/',
      'http://localhost/',
      'http://127.0.0.1:8790/', // the same listener, but no cookie is sent there
      'http://127.0.0.2:8790/',
      'http://[::1]:8790/',
      'http://0.0.0.0:8790/',
      'http://app.localhost:8790/',
      'http://printer.local/',
      'https://localhost:8790/',
      'http://localhost.:8790/',
      'http://127.0.0.1.:5432/',
      'http://[::ffff:7f00:1]:5432/',
      'http://[::ffff:127.0.0.1]:5432/',
      'http://2130706433:5432/',
      'http://0x7f.1:5432/',
      'http://0177.0.0.1:5432/',
    ]) {
      expect(decide(url), WebNavigation.refuse, reason: url);
    }
  });

  test('a link to the web is offered to the phone\'s browser, sign-in redirects included, never loaded here', () {
    for (final url in [
      'https://accounts.google.com/o/oauth2/v2/auth?client_id=x',
      'https://login.tailscale.com/a/l3503a0535f1bf',
      'https://github.com/tuan3w/herdr-mobile',
      'http://example.org/a',
      'http://8.8.8.8/',
    ]) {
      expect(decide(url), WebNavigation.web, reason: url);
    }
  });

  test('other schemes open nowhere, a data: page in the top frame included', () {
    for (final url in [
      'intent://scan#Intent;scheme=zxing;end',
      'file:///sdcard/a.html',
      'mailto:a@b.c',
      'javascript:alert(1)',
      'content://x/y',
      'data:text/html,<p>hi</p>',
    ]) {
      expect(decide(url), WebNavigation.refuse, reason: url);
    }
  });

  test('a frame (asked about on iOS only) never offers the browser; a data: frame is part of its page', () {
    expect(decide('https://accounts.google.com/', mainFrame: false), WebNavigation.refuse);
    expect(decide('http://localhost:8790/frame.html', mainFrame: false), WebNavigation.load);
    expect(decide('data:text/html,<p>hi</p>', mainFrame: false), WebNavigation.load);
  });

  test('every spelling of a loopback or unspecified address is the phone itself, and nothing else is', () {
    for (final host in [
      '127.0.0.1',
      '127.1',
      '2130706433',
      '0x7f000001',
      '0x7f.0.0.1',
      '0177.0.0.1',
      '0.0.0.0',
      '0',
      '::1',
      '[::1]',
      '::',
      '::ffff:127.0.0.1',
      '::ffff:7f00:1',
      '127.0.0.1.',
    ]) {
      expect(isLoopbackAddress(host), isTrue, reason: host);
    }
    for (final host in [
      '8.8.8.8',
      '128.0.0.1',
      '1.2.3.4',
      '::2',
      '2001:db8::1',
      '::ffff:8.8.8.8',
      'example.com',
      '127.0.0.1.5',
      '0x1g',
      '99999999999',
    ]) {
      expect(isLoopbackAddress(host), isFalse, reason: host);
    }
  });

  group('a website opened by itself', () {
    WebNavigation site(String url, {bool mainFrame = true}) => siteNavigation(Uri.parse(url), mainFrame: mainFrame);

    test('any https page loads, a link or a redirect to another site included, as in a browser', () {
      for (final url in [
        'https://wandb.ai/me/p',
        'https://github.com/x/y/pull/1#a',
        'https://www.arxiv.org:443/abs/1',
      ]) {
        expect(site(url), WebNavigation.load, reason: url);
      }
      expect(site('about:blank'), WebNavigation.load);
    });

    test('a sign-in that needs the phone’s browser, and plain http, are offered with a tap, never loaded', () {
      for (final url in [
        'https://accounts.google.com/o/oauth2/auth',
        'https://login.tailscale.com/a/x',
        'https://appleid.apple.com/auth',
        'http://example.org/a',
      ]) {
        expect(site(url), WebNavigation.web, reason: url);
      }
      expect(needsOwnBrowser(Uri.parse('https://ACCOUNTS.google.com./x')), isTrue, reason: 'case and a trailing dot');
      expect(needsOwnBrowser(Uri.parse('https://google.com/search')), isFalse, reason: 'only the sign-in hosts');
    });

    test('the phone itself, other schemes and a data page load nowhere', () {
      for (final url in [
        'http://localhost:3000/',
        'https://localhost/',
        'https://127.0.0.1:8443/',
        'https://[::1]/',
        'https://2130706433/',
        'https://printer.local/',
        'intent://scan/#Intent;scheme=zxing;end',
        'mailto:a@b.c',
        'file:///etc/passwd',
        'data:text/html,hi',
      ]) {
        expect(site(url), WebNavigation.refuse, reason: url);
      }
    });

    test('a frame loads https only: a page’s plain http or sign-in frame goes nowhere', () {
      expect(site('https://cdn.example.net/a.js', mainFrame: false), WebNavigation.load);
      expect(site('http://ads.example.net/', mainFrame: false), WebNavigation.refuse);
      expect(site('http://localhost:3000/', mainFrame: false), WebNavigation.refuse);
    });
  });
}
