// Renders the page screen (WebPreviewScreen) to PNGs for review, with the fake
// web view painting a real screenshot of a page where the WebView would be:
// the page shown, a load in progress (the hairline under the bar), a load that
// failed (panel with Retry), the ⋯ sheet, the toast for another port of the
// machine, the toast for a link to the web, a page that is not from the
// machine (posted elsewhere), and a dropped connection; light and dark at
// 412x892, and the page shown at 320x640 with text at 1.6. Off by default; it
// writes files:
//
//   WEB_PREVIEW_SHOTS=1 flutter test test/ui/web_preview_screen_shots_test.dart
//
// Page pictures: /tmp/web_preview_page.png and /tmp/web_preview_page_dark.png
// (412 dp wide); without them the page is a plain box with its title.
// Output: /tmp/web_preview_shots/<state>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:async' show Completer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';

import '../support/fake_transport.dart';
import '../support/fake_webview.dart';
import '../support/shot.dart';

const _out = '/tmp/web_preview_shots';
const _title = 'herdr web preview test';
const _page = 'http://localhost:8790/';

void main() {
  if (Platform.environment['WEB_PREVIEW_SHOTS'] == null) {
    test('page screen shots are off (set WEB_PREVIEW_SHOTS=1)', () {}, skip: 'set WEB_PREVIEW_SHOTS=1 to render PNGs');
    return;
  }

  setUpAll(() async {
    await loadAppFonts();
    Directory(_out).createSync(recursive: true);
  });

  /// The page's picture for [brightness], or null when it is not there.
  Future<ui.Image?> picture(WidgetTester tester, Brightness brightness) async {
    final file = File(brightness == Brightness.dark ? '/tmp/web_preview_page_dark.png' : '/tmp/web_preview_page.png');
    if (!file.existsSync()) return null;
    return tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
      return (await codec.getNextFrame()).image;
    });
  }

  Future<void> render(
    WidgetTester tester,
    String state, {
    required Brightness brightness,
    Size size = phone,
    double textScale = 1,
    String? appName,
    Completer<void>? hold,
    String? site,
    Future<void> Function(WidgetTester tester, FakeWebView web)? then,
  }) async {
    final transport = FakeTransport()
      ..webInfo = const WebBridgeInfo(port: 8790, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
    if (hold != null) transport.webGate = hold;
    final web = FakeWebView.install(pagePort: 8790);
    web.titles[_page] = _title;
    final image = await picture(tester, brightness);
    web.paint = (context, url) {
      if (url == null || url.contains('/__herdr/')) return const SizedBox.expand();
      if (image != null) {
        return ColoredBox(
          color: context.ds.bg,
          child: RawImage(image: image, fit: BoxFit.fitWidth, alignment: Alignment.topCenter),
        );
      }
      return ColoredBox(
        color: context.ds.surface,
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Text(_title, style: Type.title.copyWith(color: context.ds.text)),
        ),
      );
    };
    final fleet = emptyFleet();
    addTearDown(fleet.dispose);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final scale = textScale == 1 ? '' : '-x$textScale';
    await shoot(
      tester,
      site == null
          ? WebPreviewScreen(
              machine: pageMachine(transport, label: 'tuannd12'),
              page: ServerPage(Uri.parse(_page), name: appName),
            )
          : WebPreviewScreen(page: WebsitePage(Uri.parse(site))),
      '$_out/$state-$mode-${size.width.toInt()}x${size.height.toInt()}$scale.png',
      brightness: brightness,
      size: size,
      wrap: (app) => withFleet(fleet, app),
      pump: (tester) async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (then != null) await then(tester, web);
      },
    );
  }

  for (final brightness in Brightness.values) {
    final mode = brightness.name;

    testWidgets('page shown, $mode', (tester) async {
      await render(tester, 'shown', brightness: brightness);
    });

    testWidgets('loading a page, $mode', (tester) async {
      await render(
        tester,
        'loading',
        brightness: brightness,
        then: (tester, web) async {
          web.startLoading('http://localhost:8790/page2.html', 40);
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    // The machine is being asked: the cover says so, with the page named in the bar.
    testWidgets('asking the machine, $mode', (tester) async {
      await render(tester, 'asking', brightness: brightness, hold: Completer<void>());
    });

    // Nothing came back for Dwell.pageSlow: it says so and offers Try again.
    testWidgets('slow to answer, $mode', (tester) async {
      await render(
        tester,
        'slow',
        brightness: brightness,
        hold: Completer<void>(),
        then: (tester, web) async {
          await tester.pump(Dwell.pageSlow);
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    // A page of the web, in the same screen: the lock in the bar's glyph place, the
    // site's own title over its host.
    testWidgets('a website, $mode', (tester) async {
      const site = 'https://wandb.ai/suneye/qwen-warp/runs/ab12cd';
      await render(
        tester,
        'site',
        brightness: brightness,
        site: site,
        then: (tester, web) async {
          web.titles[site] = 'qwen-warp · rows27 sampling, 5 seeds';
          await web.navigate(site);
          await tester.pump(const Duration(milliseconds: 600));
        },
      );
    });

    testWidgets('a website that failed, small phone, large text, $mode', (tester) async {
      const site = 'https://wandb.ai/suneye/qwen-warp/runs/ab12cd';
      await render(
        tester,
        'site-failed',
        brightness: brightness,
        site: site,
        size: const Size(320, 640),
        textScale: 1.6,
        then: (tester, web) async {
          web.failing.add(site);
          await web.navigate(site);
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    testWidgets('a page that failed to load, $mode', (tester) async {
      await render(
        tester,
        'failed',
        brightness: brightness,
        then: (tester, web) async {
          web.failing.add('http://localhost:8790/page2.html');
          await web.navigate('http://localhost:8790/page2.html');
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    // Opened from the Made sheet: the bar says what the app is, not its address.
    testWidgets('an app named by what started it, $mode', (tester) async {
      await render(tester, 'named', brightness: brightness, appName: 'python label_server.py --port 8790');
    });

    testWidgets('a named app that failed to load, $mode', (tester) async {
      await render(
        tester,
        'named-failed',
        brightness: brightness,
        appName: 'python label_server.py --port 8790',
        then: (tester, web) async {
          web.failing.add('http://localhost:8790/page2.html');
          await web.navigate('http://localhost:8790/page2.html');
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    testWidgets('page options, $mode', (tester) async {
      await render(
        tester,
        'options',
        brightness: brightness,
        then: (tester, web) async {
          await tester.tap(find.byTooltip('Page options'));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        },
      );
    });

    testWidgets('another port of the machine, $mode', (tester) async {
      await render(
        tester,
        'other-port',
        brightness: brightness,
        then: (tester, web) async {
          await web.navigate('http://localhost:8791/api');
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        },
      );
    });

    testWidgets('a link to the web, $mode', (tester) async {
      await render(
        tester,
        'web-link',
        brightness: brightness,
        then: (tester, web) async {
          await web.navigate('https://github.com/tuan3w/herdr-mobile');
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        },
      );
    });

    testWidgets('a page not from the machine, $mode', (tester) async {
      await render(
        tester,
        'not-from',
        brightness: brightness,
        then: (tester, web) async {
          web.titles['https://login.example.com/session'] = 'Sign in';
          web.land('https://login.example.com/session');
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    testWidgets('a dropped connection, $mode', (tester) async {
      await render(
        tester,
        'lost',
        brightness: brightness,
        then: (tester, web) async {
          final machine = tester.widget<WebPreviewScreen>(find.byType(WebPreviewScreen)).machine!;
          machine.start();
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          machine.suspend();
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    });

    testWidgets('page shown, small phone, large text, $mode', (tester) async {
      await render(tester, 'shown', brightness: brightness, size: const Size(320, 640), textScale: 1.6);
    });
  }
}
