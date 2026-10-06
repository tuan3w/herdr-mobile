import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/herdr_models.dart';
import '../../data/repositories/machine_connection.dart';
import 'motion.dart';
import 'tokens.dart';

/// Colour per agent status. [color] is for shapes (>= 3:1); [textColor] is for
/// words ("Needs you", counts) and reaches 4.5:1.
extension AgentStatusColor on AgentStatus {
  Color color(Ds ds) => switch (this) {
        AgentStatus.blocked => ds.blocked,
        AgentStatus.working => ds.working,
        AgentStatus.done => ds.done,
        AgentStatus.idle || AgentStatus.unknown => ds.textTertiary,
      };

  Color textColor(Ds ds) => switch (this) {
        AgentStatus.blocked => ds.blockedText,
        _ => ds.textSecondary,
      };

  String get label => switch (this) {
        AgentStatus.blocked => 'Needs you',
        AgentStatus.working => 'Working',
        AgentStatus.done => 'Done',
        AgentStatus.idle => 'Idle',
        AgentStatus.unknown => 'Unknown',
      };
}

/// Colour per connection state. [color] is for the dot; [textColor] is for the
/// status line (only states that need the person are tinted).
extension LinkStateColor on LinkState {
  Color color(Ds ds) => switch (this) {
        LinkState.online => ds.done,
        LinkState.connecting || LinkState.reconnecting => ds.working,
        LinkState.attention || LinkState.approval => ds.blocked,
        LinkState.disabled || LinkState.offline => ds.textTertiary,
      };

  Color textColor(Ds ds) => switch (this) {
        LinkState.attention || LinkState.approval => ds.blockedText,
        _ => ds.textSecondary,
      };

  String get label => switch (this) {
        LinkState.online => 'Online',
        LinkState.connecting => 'Connecting…',
        LinkState.reconnecting => 'Reconnecting…',
        LinkState.attention => 'Needs attention',
        LinkState.disabled => 'Disabled',
        LinkState.offline => 'No network',
        LinkState.approval => 'Waiting for approval',
      };
}

/// An agent's status as a small shape: the shape says what it is even without
/// colour (needs you = filled with a bar, working = half-filled ring,
/// done = check, idle = empty ring, unknown = dashed ring).
///
/// At rest nothing moves. A turning arc on every working agent kept a timer
/// and a repaint per glyph alive for as long as the board was open, which is
/// noise to look at and battery to pay for; the half ring says "working" by
/// shape. The one motion is the SETTLE: when the status of a glyph that is on
/// screen changes, the old shape fades and the new one is drawn in once
/// (a ring sweeps round, a check and a bar are stroked), and a needs-you or
/// done glyph sends a single faint ring outward. [Motion.settle], then the
/// ticker stops; a glyph first built with its status never animates.
class StatusGlyph extends StatefulWidget {
  const StatusGlyph({
    super.key,
    required this.status,
    this.size = 18,
    this.dim = false,
  });

  final AgentStatus status;
  final double size;

  /// Stale data: draw at reduced opacity.
  final bool dim;

  @override
  State<StatusGlyph> createState() => _StatusGlyphState();
}

class _StatusGlyphState extends State<StatusGlyph> with SingleTickerProviderStateMixin {
  // Created on the first change, so the many glyphs that never change cost
  // one null field.
  AnimationController? _controller;
  CurvedAnimation? _progress;
  AgentStatus? _from;

  @override
  void didUpdateWidget(StatusGlyph old) {
    super.didUpdateWidget(old);
    if (old.status == widget.status || Motion.reduced(context)) return;
    final controller = _controller ??= AnimationController(vsync: this, duration: Motion.settle);
    _progress ??= CurvedAnimation(parent: controller, curve: Motion.easeOut);
    _from = old.status;
    controller
      ..value = 0
      ..forward().whenComplete(() {
        if (mounted) setState(() => _from = null);
      });
  }

  @override
  void dispose() {
    _progress?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final status = widget.status;
    final from = _from;
    Widget glyph = CustomPaint(
      size: Size.square(widget.size),
      painter: _GlyphPainter(
        status,
        status.color(ds),
        ds.onStatus,
        from: from,
        fromColor: from?.color(ds),
        progress: from == null ? null : _progress,
      ),
    );
    // No Opacity layer for the (usual) undimmed glyph.
    if (widget.dim) glyph = Opacity(opacity: 0.45, child: glyph);
    return Semantics(label: status.label, excludeSemantics: true, child: glyph);
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(
    this.status,
    this.color,
    this.markColor, {
    this.from,
    this.fromColor,
    this.progress,
  }) : super(repaint: progress);

  final AgentStatus status;
  final Color color;

  /// Check / "!" drawn on the filled shapes.
  final Color markColor;

  /// The shape being left and how far the settle has got (0..1); both null
  /// at rest.
  final AgentStatus? from;
  final Color? fromColor;
  final Animation<double>? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress?.value ?? 1.0;
    if (from != null && p < 1) {
      _shape(canvas, size, from!, fromColor!, markColor, 1, 1 - p);
    }
    _shape(canvas, size, status, color, markColor, p, p);
    // One faint ring leaving the glyph, for the two states that are news.
    if (from != null && p < 1 && (status == AgentStatus.blocked || status == AgentStatus.done)) {
      final c = size.center(Offset.zero);
      canvas.drawCircle(
        c,
        size.width / 2 * (1 + 0.6 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width / 14
          ..color = color.withValues(alpha: color.a * 0.5 * (1 - p)),
      );
    }
  }

  /// One shape. [draw] is how much of it has been drawn in (1 = all of it),
  /// [alpha] its opacity.
  static void _shape(
    Canvas canvas,
    Size size,
    AgentStatus status,
    Color color,
    Color markColor,
    double draw,
    double alpha,
  ) {
    Color a(Color c) => alpha >= 1 ? c : c.withValues(alpha: c.a * alpha.clamp(0, 1));
    double part(double from, double to) => ((draw - from) / (to - from)).clamp(0.0, 1.0);
    final c = size.center(Offset.zero);
    final stroke = size.width / 11;
    final r = size.width / 2 - stroke / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = a(color)
      ..isAntiAlias = true;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = a(color)
      ..isAntiAlias = true;
    final mark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = a(markColor);

    switch (status) {
      case AgentStatus.idle:
        // An empty ring is drawn round from the top.
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * draw, false, ring);
      case AgentStatus.unknown:
        const dashes = 10;
        final sweep = 2 * math.pi / dashes;
        for (var i = 0; i < dashes; i++) {
          canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * sweep, sweep * 0.55, false, ring);
        }
      case AgentStatus.working:
        // A quiet track and a half ring from the top, clockwise.
        canvas.drawCircle(c, r, ring..color = a(color.withValues(alpha: 0.32)));
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          -math.pi / 2,
          math.pi * draw,
          false,
          ring
            ..color = a(color)
            ..strokeWidth = stroke * 1.5
            ..strokeCap = StrokeCap.round,
        );
      case AgentStatus.done:
        // The disc settles to size, then the check is stroked.
        canvas.drawCircle(c, (r + stroke / 2) * (0.7 + 0.3 * part(0, 0.5)), fill);
        final path = Path()
          ..moveTo(c.dx - r * 0.42, c.dy + r * 0.02)
          ..lineTo(c.dx - r * 0.1, c.dy + r * 0.34)
          ..lineTo(c.dx + r * 0.46, c.dy - r * 0.3);
        final drawn = part(0.3, 1);
        if (drawn >= 1) {
          canvas.drawPath(path, mark);
        } else if (drawn > 0) {
          for (final metric in path.computeMetrics()) {
            canvas.drawPath(metric.extractPath(0, metric.length * drawn), mark);
          }
        }
      case AgentStatus.blocked:
        // The disc settles to size, the bar is stroked down, the dot lands.
        canvas.drawCircle(c, (r + stroke / 2) * (0.7 + 0.3 * part(0, 0.5)), fill);
        final top = Offset(c.dx, c.dy - r * 0.46);
        final bottom = Offset(c.dx, c.dy + r * 0.1);
        final bar = part(0.3, 0.8);
        if (bar > 0) canvas.drawLine(top, Offset.lerp(top, bottom, bar)!, mark);
        final dot = part(0.7, 1);
        if (dot > 0) {
          canvas.drawCircle(
            Offset(c.dx, c.dy + r * 0.46),
            stroke * 0.62 * dot,
            Paint()..color = a(markColor),
          );
        }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.status != status ||
      old.color != color ||
      old.markColor != markColor ||
      old.from != from ||
      old.fromColor != fromColor ||
      old.progress != progress;
}

/// Small solid dot for connection state.
class LinkDot extends StatelessWidget {
  const LinkDot({super.key, required this.state, this.size = 8});

  final LinkState state;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: state.color(context.ds), shape: BoxShape.circle),
      );
}

/// Notion-style icon tile: a glyph on a softly tinted rounded square.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 32});

  final IconData icon;

  /// Tint; defaults to the secondary text colour (neutral tile).
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tint = color ?? ds.textSecondary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: ds.isDark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.56, color: tint),
    );
  }
}
