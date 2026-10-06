// Renders the Markdown corpus to PNGs for review (light and dark, 412x892 and
// 320x640, text scale 1 and 1.6): the worst cases, the corpus messages and the
// answers real agents wrote. Off by default; it writes files:
//
//   MD_SHOTS=1 flutter test test/markdown/render_shots_test.dart
//
// Output: $MD_SHOTS_DIR (default /tmp/md_shots)/<case>-<light|dark>-<w>x<h>-s<scale>[-<n>].png
// MD_SHOTS_ONLY=name1,name2 limits the cases.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

import '../support/shot.dart' show loadAppFonts;
import 'support/render_corpus.dart';

class _Page extends StatefulWidget {
  const _Page({required this.markdown, this.controller});

  final String markdown;
  final ScrollController? controller;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  late final MdDocument _doc = parseMd(widget.markdown);
  final _open = <int>{};

  @override
  Widget build(BuildContext context) {
    final blocks = _doc.blocks;
    final ds = context.ds;
    return Material(
      color: ds.bg,
      child: MdActions(
        onLink: (context, url) {},
        onPath: (context, path, line) {},
        child: SelectionArea(
          child: ListView.builder(
            controller: widget.controller,
            padding: EdgeInsets.fromLTRB(Gap.lg, MediaQuery.paddingOf(context).top + Gap.md, Gap.lg, Gap.xl),
            itemCount: blocks.length,
            itemBuilder: (context, i) => Padding(
              padding: EdgeInsets.only(top: mdBlockGap(i == 0 ? null : blocks[i - 1], blocks[i])),
              child: MdBlockView(
                block: blocks[i],
                expanded: _open.contains(i),
                onToggleExpanded: () => setState(() => _open.contains(i) ? _open.remove(i) : _open.add(i)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  if (Platform.environment['MD_SHOTS'] == null) {
    test('markdown shots are off (set MD_SHOTS=1)', () {}, skip: 'set MD_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['MD_SHOTS_DIR'] ?? '/tmp/md_shots';
  final only = (Platform.environment['MD_SHOTS_ONLY'] ?? '').split(',').where((s) => s.isNotEmpty).toSet();

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final cases = <String, String>{
    for (final e in worstCases().entries) e.key: e.value,
    for (final m in corpusMessages()) m.name: m.text,
    for (final m in realAnswers()) m.name.replaceAll('/', '_').replaceAll('.jsonl', ''): m.text,
    'big200k': bigMessage(200 * 1024),
  };

  Future<void> shoot(WidgetTester tester, String name, String markdown, Size size, double scale, Brightness brightness, {double offset = 0, String suffix = ''}) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final controller = ScrollController(initialScrollOffset: offset);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: _Page(markdown: markdown, controller: controller),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}';
      await File('$out/$name-${brightness.name}-$tag-s$scale$suffix.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size x$scale');
  }

  for (final entry in cases.entries) {
    if (only.isNotEmpty && !only.contains(entry.key)) continue;
    for (final brightness in Brightness.values) {
      for (final (size, scale) in const [
        (Size(412, 892), 1.0),
        (Size(320, 640), 1.0),
        (Size(412, 892), 1.6),
        (Size(320, 640), 1.6),
      ]) {
        testWidgets('${entry.key} ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
          await shoot(tester, entry.key, entry.value, size, scale, brightness);
          // The worst cases are long: also look further down.
          if (entry.key == 'big200k' || entry.key == 'list300' || entry.key == 'code1000') {
            await shoot(tester, entry.key, entry.value, size, scale, brightness, offset: 900, suffix: '-2');
          }
        });
      }
    }
  }
}
