import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

/// Loads the bundled fonts so rendered text matches the phone. `flutter test`
/// otherwise draws every glyph with the Ahem placeholder font.
Future<void> loadAppFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = await File('assets/fonts/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    }
    await loader.load();
  }

  await load('Inter', const [
    'Inter-Regular.ttf',
    'Inter-Medium.ttf',
    'Inter-SemiBold.ttf',
    'Inter-Bold.ttf',
  ]);
  await load('JetBrainsMono', const [
    'JetBrainsMono-Regular.ttf',
    'JetBrainsMono-Bold.ttf',
    'JetBrainsMono-Italic.ttf',
    'JetBrainsMono-BoldItalic.ttf',
  ]);

  // Icon font from the lucide package (no asset path of our own).
  final config = jsonDecode(await File('.dart_tool/package_config.json').readAsString())
      as Map<String, dynamic>;
  final root = (config['packages'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((p) => p['name'] == 'lucide_icons_flutter')['rootUri'] as String;
  final fontFile = File.fromUri(Uri.parse('${root.endsWith('/') ? root : '$root/'}assets/lucide.ttf'));
  final lucide = FontLoader('packages/lucide_icons_flutter/Lucide');
  lucide.addFont(
    fontFile.readAsBytes().then((b) => ByteData.sublistView(Uint8List.fromList(b))),
  );
  await lucide.load();
}

/// A Galaxy-A51-sized screen: 412x892 logical px at 2.625 dpr, with the
/// system insets an edge-to-edge app sees (status bar, gesture bar).
const phone = Size(412, 892);
const phoneDpr = 2.625;

/// Pumps [home] in a themed [MaterialApp] and writes a PNG to [path].
///
/// [pump] runs after the first frame and before the capture, to scroll, open a
/// sheet, type, and so on.
Future<void> shoot(
  WidgetTester tester,
  Widget home,
  String path, {
  Brightness brightness = Brightness.light,
  Future<void> Function(WidgetTester tester)? pump,
  List<NavigatorObserver> observers = const [],
  Widget Function(Widget app)? wrap,
  double imageScale = 1.5,
  Size size = phone,
}) async {
  tester.view.physicalSize = size * phoneDpr;
  tester.view.devicePixelRatio = phoneDpr;
  tester.view.padding = const FakeViewPadding(top: 24 * phoneDpr, bottom: 20 * phoneDpr);
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  Widget app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    navigatorObservers: observers,
    builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemBars(Theme.of(context).brightness),
      child: RepaintBoundary(key: key, child: child!),
    ),
    home: home,
  );
  if (wrap != null) app = wrap(app);

  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 500));
  if (pump != null) await pump(tester);
  await tester.pump(const Duration(milliseconds: 500));

  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: imageScale);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(data!.buffer.asUint8List());
  });
}
