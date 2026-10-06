// Renders the brand mark where people meet it, for review: the launcher on
// light and dark wallpaper, the Android 13 themed icon, the status bar, the
// generated platform files, and the first-run screen with the tab bar.
// Off by default; it writes files:
//
//   ICON_SHOTS=1 flutter test test/ui/brand_shots_test.dart
//
// Run `flutter test screenshot_test/brand_assets_test.dart` and
// `dart run flutter_launcher_icons` first: the launcher cells read the
// generated files.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/brand_mark.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/shot.dart';

const _paperBg = Color(0xFFFBFBFA);
const _paperText = Color(0xFF37352F);
const _inkText = Color(0xFFECEDEF);

Future<ui.Image> _load(WidgetTester tester, String path) async => (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
      return (await codec.getNextFrame()).image;
    }))!;

enum _Mask { circle, squircle }

/// An adaptive icon as a launcher draws it: background, the foreground's
/// central 72 of 108 units, through a mask. [themed] uses the monochrome
/// layer on a Material You tint, as Android 13 does.
class _Launcher extends CustomPainter {
  _Launcher(this.fg, this.bg, {this.mask = _Mask.circle, this.mono});
  final ui.Image fg;
  final Color bg;
  final _Mask mask;
  final ui.Image? mono;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.clipPath(
      mask == _Mask.circle
          ? (Path()..addOval(rect))
          : (Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.32)))),
    );
    canvas.drawRect(rect, Paint()..color = mono != null ? const Color(0xFFD8E2FF) : bg);
    final s = size.width * 108 / 72;
    final o = -(s - size.width) / 2;
    final layer = mono ?? fg;
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(o, o, s, s),
      image: layer,
      filterQuality: FilterQuality.high,
      colorFilter: mono != null ? const ColorFilter.mode(Color(0xFF243266), BlendMode.srcIn) : null,
    );
  }

  @override
  bool shouldRepaint(_Launcher old) => true;
}

/// The notification icon, drawn from the same geometry the XML is written
/// from (white silhouette, 50-unit viewport around the mark).
class _Status extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.scale(size.width / 50);
    canvas.translate(-29, -29);
    BrandGeometry.paint(canvas, mono: const Color(0xFFFFFFFF));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Status old) => false;
}

const _label = TextStyle(fontFamily: 'Inter', fontSize: 13, height: 1.3, color: Color(0xFF5F5E5A));

Widget _cell(String caption, Widget child, {Color bg = const Color(0xFFF1F0EE)}) => Container(
      width: 190,
      height: 220,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Expanded(child: Center(child: child)),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(caption, style: _label.copyWith(color: bg.computeLuminance() < 0.3 ? const Color(0xFFB8BAC0) : null)),
          ),
        ],
      ),
    );

Widget _home(CustomPainter p, Color text) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(size: const Size.square(56), painter: p),
        const SizedBox(height: 6),
        Text('herdr', style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: text)),
      ],
    );

Widget _firstRun({int badge = 0}) => Stack(
      children: [
        EmptyState(
          mark: const BrandMark(animate: false),
          title: 'Your agents, in your pocket',
          message: 'Connect a machine running herdr to see every coding '
              'agent, know the moment one needs you, and reply from anywhere.',
          action: AppButton(label: 'Add your first machine', icon: LucideIcons.plus, onPressed: () {}),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: FloatingTabBar(
              tabs: [
                TabSpec(icon: LucideIcons.bot, label: 'Agents', badge: badge),
                const TabSpec(icon: LucideIcons.server, label: 'Machines'),
                const TabSpec(icon: LucideIcons.settings, label: 'Settings'),
              ],
              index: badge == 0 ? 0 : 1,
              onChanged: (_) {},
            ),
          ),
        ),
      ],
    );

void main() {
  if (Platform.environment['ICON_SHOTS'] == null) {
    test('icon shots are off (set ICON_SHOTS=1)', () {}, skip: 'set ICON_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['ICON_SHOTS_DIR'] ?? '/tmp/icon_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  testWidgets('launcher, themed, status bar and generated files', (tester) async {
    final fg = await _load(tester, 'assets/icon/icon_foreground.png');
    final mono = await _load(tester, 'assets/icon/icon_monochrome.png');
    final legacy = await _load(tester, 'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png');
    final ios = await _load(tester, 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png');
    final web = await _load(tester, 'web/icons/Icon-maskable-192.png');
    final bg = BrandGeometry.tile;

    tester.view.physicalSize = const Size(1460, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFFFFFFFF),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _cell('Master', CustomPaint(size: const Size.square(150), painter: _Launcher(fg, bg, mask: _Mask.squircle))),
                    _cell('Light wallpaper · 56 dp', _home(_Launcher(fg, bg), _paperText), bg: const Color(0xFFE6DFD3)),
                    _cell('Dark wallpaper · 56 dp', _home(_Launcher(fg, bg, mask: _Mask.squircle), _inkText), bg: const Color(0xFF1E2230)),
                    _cell('Themed (Android 13)', _home(_Launcher(fg, bg, mono: mono), _paperText), bg: const Color(0xFFEEF0F8)),
                    _cell(
                      'Status bar · 24 dp',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('9:41', style: TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFFFFFFFF))),
                          const SizedBox(width: 10),
                          CustomPaint(size: const Size.square(18), painter: _Status()),
                          const SizedBox(width: 18),
                          CustomPaint(size: const Size.square(48), painter: _Status()),
                        ],
                      ),
                      bg: const Color(0xFF000000),
                    ),
                    _cell('Launch (paper)', CustomPaint(size: const Size.square(88), painter: _Launcher(fg, bg)), bg: _paperBg),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _cell('Legacy mipmap (xxhdpi)', RawImage(image: legacy, width: 96, height: 96)),
                    _cell('iOS 60@3x', ClipRRect(borderRadius: BorderRadius.circular(22), child: RawImage(image: ios, width: 96, height: 96))),
                    _cell('Web maskable 192', ClipOval(child: RawImage(image: web, width: 96, height: 96))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/brand.png').writeAsBytes(data!.buffer.asUint8List());
    });
  });

  for (final brightness in Brightness.values) {
    for (final badge in const [0, 1]) {
      testWidgets('first run · ${brightness.name} · badge $badge', (tester) async {
        await shoot(tester, Material(child: _firstRun(badge: badge)),
            '$out/first_run_${brightness.name}_$badge.png',
            brightness: brightness);
      });
    }
  }
}
