import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../data/models/herdr_models.dart';
import '../../data/repositories/machine_connection.dart';
import 'step_clock.dart';
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
/// colour (needs you = filled with a bar, working = ring with a turning arc,
/// done = check, idle = empty ring, unknown = dashed ring).
///
/// Only "working" moves, and only a little: the arc advances in discrete steps
/// (4 a second) from ONE shared [StepClock.glyph], so ten working agents cost
/// one timer and ten tiny repaints, each inside its own `RepaintBoundary`. The
/// clock runs only while a working glyph is mounted and visible (hidden tabs
/// and covered routes switch it off through `TickerMode`), pauses when the app
/// is in the background, and is off under reduced motion (the arc then rests
/// at a fixed angle). Every other status is static.
class StatusGlyph extends StatelessWidget {
  const StatusGlyph({
    super.key,
    required this.status,
    this.size = 18,
    this.dim = false,
    this.animate = true,
  });

  final AgentStatus status;
  final double size;

  /// Stale data: draw at reduced opacity (and at rest: see [animate]).
  final bool dim;

  /// False draws a working glyph at rest. Use it where the agent is known not
  /// to be working right now but the shape is still shown undimmed (a card on
  /// an offline machine).
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // A stale agent is not working right now: its arc rests too.
    Widget glyph = status == AgentStatus.working && !dim && animate
        ? _WorkingGlyph(size: size, color: status.color(ds))
        : CustomPaint(
            size: Size.square(size),
            painter: _GlyphPainter(status, status.color(ds), ds.onStatus),
          );
    // No Opacity layer for the (usual) undimmed glyph.
    if (dim) glyph = Opacity(opacity: 0.45, child: glyph);
    return Semantics(label: status.label, excludeSemantics: true, child: glyph);
  }
}

/// The turning arc. Repaints through the painter's `repaint` listenable, so a
/// clock step never rebuilds any widget.
class _WorkingGlyph extends StatefulWidget {
  const _WorkingGlyph({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  State<_WorkingGlyph> createState() => _WorkingGlyphState();
}

class _WorkingGlyphState extends State<_WorkingGlyph> with StepClockLease<_WorkingGlyph> {
  bool _reduced = false;

  @override
  StepClock get clock => StepClock.glyph;

  @override
  bool get wantsClock => !_reduced;

  @override
  void didChangeDependencies() {
    _reduced = MediaQuery.disableAnimationsOf(context);
    super.didChangeDependencies();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _GlyphPainter(
            AgentStatus.working,
            widget.color,
            Colors.transparent,
            steps: _reduced ? null : clock.steps,
          ),
        ),
      );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.status, this.color, this.markColor, {this.steps}) : super(repaint: steps);

  /// Working only: the shared clock whose steps turn the arc. Null = at rest.
  final ValueListenable<int>? steps;

  /// Positions the arc can take: 8 x 45 degrees, advanced 4 times a second.
  static const positions = 8;

  final AgentStatus status;
  final Color color;

  /// Check / "!" drawn on the filled shapes.
  final Color markColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final stroke = size.width / 11;
    final r = size.width / 2 - stroke / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color
      ..isAntiAlias = true;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color
      ..isAntiAlias = true;
    final mark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = markColor;

    switch (status) {
      case AgentStatus.idle:
        canvas.drawCircle(c, r, ring);
      case AgentStatus.unknown:
        const dashes = 10;
        final sweep = 2 * math.pi / dashes;
        for (var i = 0; i < dashes; i++) {
          canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * sweep, sweep * 0.55, false, ring);
        }
      case AgentStatus.working:
        // A quiet track and a short arc that hops round it.
        canvas.drawCircle(c, r, ring..color = color.withValues(alpha: 0.32));
        final at = (steps?.value ?? 0) % positions;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          -math.pi / 2 + at * 2 * math.pi / positions,
          math.pi * 0.62,
          false,
          ring
            ..color = color
            ..strokeWidth = stroke * 1.5
            ..strokeCap = StrokeCap.round,
        );
      case AgentStatus.done:
        canvas.drawCircle(c, r + stroke / 2, fill);
        final p = Path()
          ..moveTo(c.dx - r * 0.42, c.dy + r * 0.02)
          ..lineTo(c.dx - r * 0.1, c.dy + r * 0.34)
          ..lineTo(c.dx + r * 0.46, c.dy - r * 0.3);
        canvas.drawPath(p, mark);
      case AgentStatus.blocked:
        canvas.drawCircle(c, r + stroke / 2, fill);
        canvas.drawLine(Offset(c.dx, c.dy - r * 0.46), Offset(c.dx, c.dy + r * 0.1), mark);
        canvas.drawCircle(Offset(c.dx, c.dy + r * 0.46), stroke * 0.62, Paint()..color = markColor);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.status != status || old.color != color || old.markColor != markColor || old.steps != steps;
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
