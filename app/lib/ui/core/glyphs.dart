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

/// Colour per connection state. [color] is for the dot and a state's panel;
/// [textColor] is for the status line (only states that need the person are
/// tinted). Online has no colour: a green dot on every healthy machine was
/// decoration that competed with what needs the person, and the absence of
/// a problem is not news.
extension LinkStateColor on LinkState {
  Color color(Ds ds) => switch (this) {
    LinkState.online => ds.textTertiary,
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
    LinkState.offline => 'Offline',
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
  const StatusGlyph({super.key, required AgentStatus this.status, this.size = 18, this.dim = false}) : _ended = null;

  /// A call, run or plan step that failed: a disc in the danger colour with a
  /// cross, the same grammar as done (disc and check) and needs-you (disc and
  /// bar). Not an agent status: no agent is "failed", so [AgentStatus] and
  /// everything that switches over it stay as they are.
  const StatusGlyph.failed({super.key, this.size = 18, this.dim = false}) : status = null, _ended = _Ended.failed;

  /// A call, run or plan step that was cancelled: the quiet ring of idle with
  /// a slash through it.
  const StatusGlyph.cancelled({super.key, this.size = 18, this.dim = false}) : status = null, _ended = _Ended.cancelled;

  /// The agent status drawn; null for [StatusGlyph.failed] and [StatusGlyph.cancelled].
  final AgentStatus? status;
  final _Ended? _ended;
  final double size;

  /// Stale data: draw at reduced opacity.
  final bool dim;

  /// What is drawn, for the shape and the words.
  _Shape get _shape => switch (_ended) {
    _Ended.failed => _Shape.failed,
    _Ended.cancelled => _Shape.cancelled,
    null => _Shape.of(status!),
  };

  /// Whether this is [StatusGlyph.failed].
  bool get isFailed => _ended == _Ended.failed;

  /// Whether this is [StatusGlyph.cancelled].
  bool get isCancelled => _ended == _Ended.cancelled;

  @override
  State<StatusGlyph> createState() => _StatusGlyphState();
}

enum _Ended { failed, cancelled }

/// Every shape the glyph draws: the agent statuses and the two ways a call, a
/// run or a plan step can end without being done.
enum _Shape {
  idle(AgentStatus.idle),
  unknown(AgentStatus.unknown),
  working(AgentStatus.working),
  done(AgentStatus.done),
  blocked(AgentStatus.blocked),
  failed(null),
  cancelled(null);

  const _Shape(this.status);

  final AgentStatus? status;

  static _Shape of(AgentStatus s) => switch (s) {
    AgentStatus.idle => idle,
    AgentStatus.unknown => unknown,
    AgentStatus.working => working,
    AgentStatus.done => done,
    AgentStatus.blocked => blocked,
  };

  Color color(Ds ds) => status?.color(ds) ?? (this == failed ? ds.danger : ds.textTertiary);

  String get label => status?.label ?? (this == failed ? 'Failed' : 'Cancelled');

  /// News: the glyph sends one faint ring outward when it arrives.
  bool get isNews => this == blocked || this == done || this == failed;
}

class _StatusGlyphState extends State<StatusGlyph> with SingleTickerProviderStateMixin {
  // Created on the first change, so the many glyphs that never change cost
  // one null field.
  AnimationController? _controller;
  CurvedAnimation? _progress;
  _Shape? _from;

  @override
  void didUpdateWidget(StatusGlyph old) {
    super.didUpdateWidget(old);
    if (old._shape == widget._shape || Motion.reduced(context)) return;
    final controller = _controller ??= AnimationController(vsync: this, duration: Motion.settle);
    _progress ??= CurvedAnimation(parent: controller, curve: Motion.easeOut);
    _from = old._shape;
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
    final shape = widget._shape;
    final from = _from;
    Widget glyph = CustomPaint(
      size: Size.square(widget.size),
      painter: _GlyphPainter(
        shape,
        shape.color(ds),
        ds.onStatus,
        from: from,
        fromColor: from?.color(ds),
        progress: from == null ? null : _progress,
      ),
    );
    // No Opacity layer for the (usual) undimmed glyph.
    if (widget.dim) glyph = Opacity(opacity: 0.45, child: glyph);
    return Semantics(label: shape.label, excludeSemantics: true, child: glyph);
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.shape, this.color, this.markColor, {this.from, this.fromColor, this.progress})
    : super(repaint: progress);

  final _Shape shape;
  final Color color;

  /// Check / "!" / cross drawn on the filled shapes.
  final Color markColor;

  /// The shape being left and how far the settle has got (0..1); both null
  /// at rest.
  final _Shape? from;
  final Color? fromColor;
  final Animation<double>? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress?.value ?? 1.0;
    if (from != null && p < 1) {
      _draw(canvas, size, from!, fromColor!, markColor, 1, 1 - p);
    }
    _draw(canvas, size, shape, color, markColor, p, p);
    // One faint ring leaving the glyph, for the states that are news.
    if (from != null && p < 1 && shape.isNews) {
      final c = size.center(Offset.zero);
      canvas.drawCircle(
        c,
        size.width / 2 * (1 + 0.6 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width / 14
          ..color = Ds.fade(color, 0.5 * (1 - p)),
      );
    }
  }

  /// One shape. [draw] is how much of it has been drawn in (1 = all of it),
  /// [alpha] its opacity.
  static void _draw(Canvas canvas, Size size, _Shape shape, Color color, Color markColor, double draw, double alpha) {
    Color a(Color c) => Ds.fade(c, alpha);
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

    switch (shape) {
      case _Shape.idle:
        // An empty ring is drawn round from the top.
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * draw, false, ring);
      case _Shape.unknown:
        const dashes = 10;
        final sweep = 2 * math.pi / dashes;
        for (var i = 0; i < dashes; i++) {
          canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * sweep, sweep * 0.55, false, ring);
        }
      case _Shape.working:
        // A quiet track and a half ring from the top, clockwise.
        canvas.drawCircle(c, r, ring..color = a(Ds.fade(color, 0.32)));
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
      case _Shape.done:
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
      case _Shape.blocked:
        // The disc settles to size, the bar is stroked down, the dot lands.
        canvas.drawCircle(c, (r + stroke / 2) * (0.7 + 0.3 * part(0, 0.5)), fill);
        final top = Offset(c.dx, c.dy - r * 0.46);
        final bottom = Offset(c.dx, c.dy + r * 0.1);
        final bar = part(0.3, 0.8);
        if (bar > 0) canvas.drawLine(top, Offset.lerp(top, bottom, bar)!, mark);
        final dot = part(0.7, 1);
        if (dot > 0) {
          canvas.drawCircle(Offset(c.dx, c.dy + r * 0.46), stroke * 0.62 * dot, Paint()..color = a(markColor));
        }
      case _Shape.failed:
        // The disc settles to size, then the two strokes of the cross.
        canvas.drawCircle(c, (r + stroke / 2) * (0.7 + 0.3 * part(0, 0.5)), fill);
        final k = r * 0.34;
        final first = part(0.3, 0.7);
        final second = part(0.55, 1);
        final a1 = Offset(c.dx - k, c.dy - k), b1 = Offset(c.dx + k, c.dy + k);
        final a2 = Offset(c.dx + k, c.dy - k), b2 = Offset(c.dx - k, c.dy + k);
        if (first > 0) canvas.drawLine(a1, Offset.lerp(a1, b1, first)!, mark);
        if (second > 0) canvas.drawLine(a2, Offset.lerp(a2, b2, second)!, mark);
      case _Shape.cancelled:
        // The idle ring, then the slash from top left to bottom right.
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * part(0, 0.7), false, ring);
        final k = r * math.sqrt1_2;
        final from = Offset(c.dx - k, c.dy - k);
        canvas.drawLine(
          from,
          Offset.lerp(from, Offset(c.dx + k, c.dy + k), part(0.5, 1))!,
          ring..strokeCap = StrokeCap.round,
        );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.shape != shape ||
      old.color != color ||
      old.markColor != markColor ||
      old.from != from ||
      old.fromColor != fromColor ||
      old.progress != progress;
}

/// A machine's connection as a small shape, readable without colour:
///
/// - online: a small filled dot in [Ds.textTertiary]. Quiet, because nothing
///   is wrong; still there, so a row keeps its leading mark and the fleet's
///   health reads the same everywhere.
/// - connecting, reconnecting: a ring in the working colour (not there yet).
/// - offline, disabled: a ring in [Ds.textTertiary] (not there, nothing to do
///   here: the words say why).
/// - attention, approval: a ring with a dot in it, in the blocked colour: the
///   person is needed, and the shape says so apart from the colour.
///
/// [LinkDot.live] is the one exception: a filled dot in the done colour for
/// something that runs right now (a server an agent started), where the dot
/// is the only sign of it.
class LinkDot extends StatelessWidget {
  const LinkDot({super.key, required LinkState this.state, this.size = 8});

  /// Something running now, not a machine's link: the done colour, filled.
  const LinkDot.live({super.key, this.size = 8}) : state = null;

  /// The link drawn; null for [LinkDot.live].
  final LinkState? state;
  final double size;

  /// The shape drawn.
  LinkMark get mark => switch (state) {
    final s? => LinkMark.of(s),
    null => LinkMark.dot,
  };

  /// The colour drawn.
  Color colorIn(Ds ds) => state?.color(ds) ?? ds.done;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LinkDotPainter(mark, colorIn(context.ds)));
}

/// The shapes of [LinkDot]: a filled dot (online, live), a ring (not
/// connected: on its way, or not), a ring with a dot in it (needs the person).
enum LinkMark {
  dot,
  ring,
  target;

  static LinkMark of(LinkState s) => switch (s) {
    LinkState.online => dot,
    LinkState.attention || LinkState.approval => target,
    LinkState.connecting || LinkState.reconnecting || LinkState.offline || LinkState.disabled => ring,
  };
}

class _LinkDotPainter extends CustomPainter {
  const _LinkDotPainter(this.shape, this.color);

  final LinkMark shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (shape == LinkMark.dot) {
      canvas.drawCircle(c, outer, fill);
      return;
    }
    // A quarter of the size reads as a ring at 8 dp (2 dp, the health
    // chip's ring); the target's ring is thinner to leave air round its dot.
    final stroke = size.shortestSide / (shape == LinkMark.ring ? 4 : 5.5);
    canvas.drawCircle(
      c,
      outer - stroke / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color
        ..isAntiAlias = true,
    );
    if (shape == LinkMark.target) canvas.drawCircle(c, outer * 0.32, fill);
  }

  @override
  bool shouldRepaint(_LinkDotPainter old) => old.shape != shape || old.color != color;
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
      decoration: BoxDecoration(color: ds.wash(tint), borderRadius: BorderRadius.circular(Radii.xs)),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.56, color: tint),
    );
  }
}
