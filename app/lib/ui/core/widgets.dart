import 'package:flutter/material.dart';

import '../../data/models/herdr_models.dart';
import 'motion.dart';
import 'status_style.dart';
import 'theme.dart';

/// A status dot that breathes while an agent is working.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.size = 10, this.pulse = true});

  final Color color;
  final double size;
  final bool pulse;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool get _wantsPulse => widget.pulse && !Motion.reduced(context);

  /// Reduced motion keeps the dot, drops the breathing.
  void _sync() {
    if (_wantsPulse) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else if (_c.isAnimating || _c.value != 0) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PulsingDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: widget.size * 2,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _DotPainter(widget.color, widget.size / 2, _c.value),
          ),
        ),
      );
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.color, this.radius, this.t);

  final Color color;
  final double radius;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (t > 0) {
      canvas.drawCircle(
        c,
        radius + (size.width / 2 - radius) * t,
        Paint()..color = color.withValues(alpha: 0.35 * (1 - t)),
      );
    }
    canvas.drawCircle(c, radius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.t != t || old.color != color;
}

/// Compact tinted pill: dot + label.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.dim = false});

  final AgentStatus status;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 10, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dim ? 0.08 : 0.14),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingDot(
            color: color,
            size: 7,
            pulse: status == AgentStatus.working && !dim,
          ),
          const SizedBox(width: 2),
          Text(
            status.label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

/// Small neutral chip with an icon, for machine / workspace / path tags.
class MetaTag extends StatelessWidget {
  const MetaTag({super.key, required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = color ?? scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
          ),
        ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.label, required this.count, this.color});

  final String label;
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xl, Gap.xs, Gap.sm),
      child: Row(
        children: [
          if (color != null) ...[
            StatusDot(color: color!, size: 8),
            const SizedBox(width: Gap.sm),
          ],
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              color: c,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(width: Gap.sm),
          Text(
            '$count',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.10),
                border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
              ),
              child: Icon(icon, size: 40, color: scheme.primary),
            ),
            const SizedBox(height: Gap.xl),
            Text(title,
                style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: Gap.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            if (action != null) ...[
              const SizedBox(height: Gap.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Last path segment, for compact cwd display.
String cwdTail(String? cwd) {
  if (cwd == null || cwd.isEmpty) return '';
  final parts = cwd.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}
