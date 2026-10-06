// A small dashboard picture drawn with dart:ui, so the store screenshots can
// show the image viewer without a binary asset in the repository.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show FontWeight;
import 'package:flutter_test/flutter_test.dart';

const _w = 1200.0;
const _h = 2048.0;

class _Palette {
  const _Palette({
    required this.bg,
    required this.card,
    required this.text,
    required this.muted,
    required this.grid,
  });

  final ui.Color bg;
  final ui.Color card;
  final ui.Color text;
  final ui.Color muted;
  final ui.Color grid;
}

const _dark = _Palette(
  bg: ui.Color(0xFF0E1117),
  card: ui.Color(0xFF171B24),
  text: ui.Color(0xFFECEDEF),
  muted: ui.Color(0xFF8D9098),
  grid: ui.Color(0xFF262B36),
);

const _light = _Palette(
  bg: ui.Color(0xFFF1F2F7),
  card: ui.Color(0xFFFFFFFF),
  text: ui.Color(0xFF23252D),
  muted: ui.Color(0xFF7B7E89),
  grid: ui.Color(0xFFE6E8EF),
);

const _accent = ui.Color(0xFF5E6AD2);
const _green = ui.Color(0xFF4CB782);

void _text(
  ui.Canvas canvas,
  String s,
  double x,
  double y,
  double size,
  ui.Color color, {
  FontWeight weight = FontWeight.w400,
  double width = 800,
  ui.TextAlign align = ui.TextAlign.left,
}) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(
    fontFamily: 'Inter',
    fontSize: size,
    fontWeight: weight,
    textAlign: align,
    maxLines: 1,
  ))
    ..pushStyle(ui.TextStyle(color: color, fontFamily: 'Inter', fontSize: size, fontWeight: weight))
    ..addText(s);
  final p = b.build()..layout(ui.ParagraphConstraints(width: width));
  canvas.drawParagraph(p, ui.Offset(x, y));
}

void _card(ui.Canvas canvas, ui.Rect r, _Palette p) =>
    canvas.drawRRect(ui.RRect.fromRectAndRadius(r, const ui.Radius.circular(36)), ui.Paint()..color = p.card);

/// A smooth line through [pts] (midpoint quadratic segments).
ui.Path _smooth(List<ui.Offset> pts) {
  final path = ui.Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length - 1; i++) {
    final mid = ui.Offset((pts[i].dx + pts[i + 1].dx) / 2, (pts[i].dy + pts[i + 1].dy) / 2);
    path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(pts.last.dx, pts.last.dy);
  return path;
}

/// PNG bytes of a 1200x2048 "checkout latency" dashboard (needs
/// `tester.runAsync`, like any engine image work).
Future<Uint8List> dashboardPng(WidgetTester tester, {required bool dark}) async {
  late Uint8List out;
  await tester.runAsync(() async {
    final p = dark ? _dark : _light;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, _w, _h), ui.Paint()..color = p.bg);

    _text(canvas, 'Checkout latency', 64, 80, 68, p.text, weight: FontWeight.w700);
    _text(canvas, 'payments-api  ·  last 7 days', 64, 168, 34, p.muted);

    // Three headline numbers.
    const tiles = [
      ('p50', '84 ms', '-12%'),
      ('p95', '212 ms', '-38%'),
      ('p99', '480 ms', '-41%'),
    ];
    const tileW = 340.0;
    const gap = 30.0;
    for (final (i, t) in tiles.indexed) {
      final x = 64 + i * (tileW + gap);
      _card(canvas, ui.Rect.fromLTWH(x, 260, tileW, 230), p);
      _text(canvas, t.$1, x + 36, 292, 32, p.muted, width: tileW - 72);
      _text(canvas, t.$2, x + 36, 336, 62, p.text, weight: FontWeight.w700, width: tileW - 72);
      _text(canvas, t.$3, x + 36, 428, 32, _green, weight: FontWeight.w600, width: tileW - 72);
    }

    // The line chart.
    const chart = ui.Rect.fromLTWH(64, 530, _w - 128, 640);
    _card(canvas, chart, p);
    _text(canvas, 'p95 by hour', 100, 566, 36, p.text, weight: FontWeight.w600);
    _text(canvas, 'fix deployed', 790, 570, 28, _accent, weight: FontWeight.w600, width: 260, align: ui.TextAlign.right);
    const plot = ui.Rect.fromLTRB(100, 650, _w - 100, 1050);
    final grid = ui.Paint()
      ..color = p.grid
      ..strokeWidth = 2;
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(ui.Offset(plot.left, y), ui.Offset(plot.right, y), grid);
    }
    const values = [
      0.62, 0.66, 0.60, 0.72, 0.78, 0.70, 0.84, 0.80, 0.88, 0.82, 0.90, 0.86, //
      0.70, 0.52, 0.44, 0.40, 0.46, 0.38, 0.34, 0.37, 0.30, 0.33, 0.28, 0.30,
    ];
    final pts = [
      for (final (i, v) in values.indexed)
        ui.Offset(plot.left + plot.width * i / (values.length - 1), plot.bottom - plot.height * v),
    ];
    final line = _smooth(pts);
    final area = ui.Path.from(line)
      ..lineTo(plot.right, plot.bottom)
      ..lineTo(plot.left, plot.bottom)
      ..close();
    canvas.drawPath(
      area,
      ui.Paint()
        ..shader = ui.Gradient.linear(plot.topCenter, plot.bottomCenter, [
          _accent.withValues(alpha: dark ? 0.38 : 0.28),
          _accent.withValues(alpha: 0),
        ]),
    );
    // The deploy marker, between the 12th and 13th hour.
    final markX = pts[12].dx;
    canvas.drawLine(
      ui.Offset(markX, plot.top - 20),
      ui.Offset(markX, plot.bottom),
      ui.Paint()
        ..color = _accent.withValues(alpha: 0.7)
        ..strokeWidth = 3,
    );
    canvas.drawPath(
      line,
      ui.Paint()
        ..color = _accent
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round,
    );
    canvas.drawCircle(pts.last, 14, ui.Paint()..color = p.card);
    canvas.drawCircle(pts.last, 14, ui.Paint()..color = _accent..style = ui.PaintingStyle.stroke..strokeWidth = 7);
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    for (final (i, d) in days.indexed) {
      final x = plot.left + plot.width * i / 6;
      _text(canvas, d, x - 60, 1076, 28, p.muted, width: 120, align: ui.TextAlign.center);
    }

    // Errors per day.
    const bars = ui.Rect.fromLTWH(64, 1210, _w - 128, 330);
    _card(canvas, bars, p);
    _text(canvas, 'Errors per day', 100, 1244, 36, p.text, weight: FontWeight.w600);
    const errors = [0.80, 0.74, 0.86, 0.66, 0.34, 0.22, 0.18];
    const base = 1500.0;
    const maxH = 190.0;
    for (final (i, v) in errors.indexed) {
      final x = 118 + i * 148.0;
      final top = base - maxH * v;
      canvas.drawRRect(
        ui.RRect.fromRectAndCorners(
          ui.Rect.fromLTRB(x, top, x + 96, base),
          topLeft: const ui.Radius.circular(14),
          topRight: const ui.Radius.circular(14),
        ),
        ui.Paint()..color = i < 4 ? p.grid : _green,
      );
    }

    // Slowest endpoints.
    _card(canvas, const ui.Rect.fromLTWH(64, 1580, _w - 128, 420), p);
    _text(canvas, 'Slowest endpoints', 100, 1614, 36, p.text, weight: FontWeight.w600);
    const endpoints = [
      ('POST /checkout', 212),
      ('POST /refund', 188),
      ('GET /orders', 131),
      ('GET /cart', 96),
    ];
    for (final (i, e) in endpoints.indexed) {
      final y = 1698.0 + i * 70;
      _text(canvas, e.$1, 100, y, 30, p.text, width: 300);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(ui.Rect.fromLTWH(420, y + 10, 480, 18), const ui.Radius.circular(9)),
        ui.Paint()..color = p.grid,
      );
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(420, y + 10, 480 * e.$2 / 240, 18),
          const ui.Radius.circular(9),
        ),
        ui.Paint()..color = _accent.withValues(alpha: i == 0 ? 1 : 0.55),
      );
      _text(canvas, '${e.$2} ms', 920, y, 30, p.muted, width: 180, align: ui.TextAlign.right);
    }

    final image = await recorder.endRecording().toImage(_w.toInt(), _h.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    out = data!.buffer.asUint8List();
  });
  return out;
}
