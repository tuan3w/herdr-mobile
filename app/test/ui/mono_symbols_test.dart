// The symbols agents' TUIs draw that JetBrains Mono lacks come from the
// bundled HerdrSymbols fallback, on the mono cell. Why: the phone drew
// Claude Code's `⏵⏵ auto mode on` as `▯▯ auto mode on`.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_cells.dart';

import '../support/shot.dart' show loadAppFonts;

/// What Claude Code, Codex and the CLI spinners draw that JetBrains Mono has
/// no glyph for.
const _symbols = ['⏵', '⏸', '⏺', '⎿', '✻', '✳', '✢', '✽', '✔', '✘', '◐', '☐', '☒', '★', '⠋', '⬤'];

Future<Uint8List> _pixels(WidgetTester tester, String text, TextStyle style) async {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(color: const Color(0xFF000000), fontSize: 40),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), Offset.zero);
  final picture = recorder.endRecording();
  final bytes = await tester.runAsync(() async {
    final image = await picture.toImage(64, 64);
    final data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List();
  });
  picture.dispose();
  painter.dispose();
  return bytes!;
}

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void main() {
  setUpAll(loadAppFonts);

  test('every mono style, and the terminal, falls back to the symbol font', () {
    for (final style in [Mono.small, Mono.base, Mono.input, Mono.preview]) {
      expect(style.fontFamilyFallback, contains('HerdrSymbols'));
    }
    final cells = CellMetrics(fontSize: 13, advance: 7.8, dpr: 2.625);
    expect(cells.textStyle.fontFamilyFallback, contains('HerdrSymbols'));
    expect(cells.strut.fontFamilyFallback, contains('HerdrSymbols'));
  });

  testWidgets('the symbols draw from the fallback, not as missing glyphs', (tester) async {
    final symbols = Mono.base.copyWith(fontFamily: 'HerdrSymbols', fontFamilyFallback: const <String>[]);
    final noFallback = Mono.base.copyWith(fontFamilyFallback: const <String>[]);
    for (final s in _symbols) {
      final drawn = await _pixels(tester, s, Mono.base);
      expect(drawn, await _pixels(tester, s, symbols), reason: '$s is the symbol font\'s glyph');
      expect(drawn, isNot(await _pixels(tester, s, noFallback)), reason: '$s is missing from JetBrains Mono');
    }
  });

  test('a symbol takes one mono cell, so a terminal row stays on its grid', () {
    final cell = _width('M', Mono.base);
    for (final s in _symbols) {
      expect(_width(s, Mono.base), moreOrLessEquals(cell, epsilon: 0.01), reason: s);
    }
    expect(_width('⏵⏵ auto mode on', Mono.base), moreOrLessEquals(cell * 15, epsilon: 0.1));
  });
}
