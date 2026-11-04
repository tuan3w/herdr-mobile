import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../markdown/md_code_block.dart';
import '../markdown/md_document.dart';
import '../markdown/md_edge_fade.dart';
import '../markdown/md_more_row.dart';
import 'md_diagram_opener.dart';
import 'mermaid_cache.dart';
import 'mermaid_layout.dart';
import 'mermaid_theme.dart';

/// Height shown before "Show all", dp: a tall flowchart is not allowed to be a
/// screen of its own in the middle of an answer.
const mdDiagramCap = 420.0;

/// A diagram is never drawn below this share of its laid-out size: past it the
/// block scrolls sideways instead (text 13 dp at 100%, 10.4 dp at 80%).
const mdDiagramFloor = 0.8;

/// A closed ```` ```mermaid ```` fence, drawn.
///
///  * While the layout is on its way (a few ms, in an isolate) the block is the
///    code block it was: no spinner, nothing to wait for. A diagram the app
///    cannot draw (a kind it does not know, a syntax error, too large) stays
///    that code block, with the reason under it.
///  * Drawn: a plate with the kind and two buttons (Open, Copy source), the
///    diagram at its laid-out size, or 80% when that is wider than the block,
///    scrolling sideways with the table's fade. Taller than [mdDiagramCap] it
///    is cropped, with "Show all" (the caller owns that state, like code).
///  * The picture is recorded once and drawn from the cache; nothing moves at
///    rest.
///  * What the person copies is the source as written.
class MdDiagramView extends StatefulWidget {
  const MdDiagramView({super.key, required this.code, this.expanded = false, this.onToggleExpanded});

  final MdCode code;
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  @override
  State<MdDiagramView> createState() => _MdDiagramViewState();
}

class _MdDiagramViewState extends State<MdDiagramView> {
  final _scroll = ScrollController();
  MermaidResult? _result;
  MermaidPictureLease? _lease;
  Future<MermaidResult>? _asked;
  String? _key;
  bool _copied = false;
  Timer? _reset;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ask();
  }

  @override
  void didUpdateWidget(MdDiagramView old) {
    super.didUpdateWidget(old);
    if (old.code.text != widget.code.text) _ask();
  }

  @override
  void dispose() {
    _reset?.cancel();
    _lease?.release();
    _scroll.dispose();
    super.dispose();
  }

  /// Asks for the layout of this source under this theme. A result the cache
  /// already holds is on the first frame (no code block that jumps taller a
  /// frame later); otherwise what is on screen stays until the answer comes (a
  /// theme change does not blink).
  void _ask() {
    final ds = context.ds;
    final key = '${ds.brightness.index}\u0000${widget.code.text}';
    if (key == _key) return;
    _key = key;
    final kept = MermaidCache.shared.peek(widget.code.text, ds);
    if (kept != null) {
      _asked = null;
      _adopt(kept);
      return;
    }
    final asked = MermaidCache.shared.layout(widget.code.text, ds);
    _asked = asked;
    asked.then((result) {
      if (!mounted || !identical(_asked, asked)) return;
      setState(() => _adopt(result));
    });
  }

  void _adopt(MermaidResult result) {
    final lease = result is MermaidDrawn ? MermaidCache.shared.acquirePicture(result) : null;
    _lease?.release();
    _lease = lease;
    _result = result;
  }

  Future<void> _copy() async {
    if (!await copyText(context, widget.code.text, what: 'Diagram source copied')) return;
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(Dwell.copied, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final lease = _lease;
    final code = MdCodeBlock(code: widget.code, expanded: widget.expanded, onToggleExpanded: widget.onToggleExpanded);
    switch (result) {
      case null:
        return code;
      case MermaidFailed(:final reason):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            code,
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(reason, style: Type.caption.copyWith(color: context.ds.textMuted)),
            ),
          ],
        );
      case MermaidDrawn():
        return _drawn(context, result, lease!);
    }
  }

  Widget _drawn(BuildContext context, MermaidDrawn d, MermaidPictureLease lease) {
    final ds = context.ds;
    final open = MdDiagramOpener.maybeOf(context)?.open;
    final natural = ui.Size(d.scene.size.width, d.scene.size.height);
    final textScale = math.min(1.5, MediaQuery.textScalerOf(context).scale(mermaidFontSize) / mermaidFontSize);

    final body = LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxWidth;
        final scale = math.min(1.0, math.max(mdDiagramFloor, avail / natural.width)) * textScale;
        final size = ui.Size(natural.width * scale, natural.height * scale);
        final cropped = size.height > mdDiagramCap && !widget.expanded;
        final paint = RepaintBoundary(
          child: CustomPaint(size: size, painter: _PicturePainter(lease.picture, scale)),
        );
        final Widget content = size.width <= avail
            ? Align(alignment: Alignment.topCenter, child: paint)
            : MdEdgeFade(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: paint,
                ),
              );
        final shown = SizedBox(
          height: cropped ? mdDiagramCap : size.height,
          child: ClipRect(
            child: OverflowBox(alignment: Alignment.topLeft, minHeight: 0, maxHeight: size.height, child: content),
          ),
        );
        final tappable = open == null
            ? shown
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: () => open(context, d),
                child: shown,
              );
        final more = size.height > mdDiagramCap
            ? MoreRow(
                label: widget.expanded ? context.l10n.uiWholeDiagram : context.l10n.uiCropped,
                action: widget.expanded ? 'Show less' : 'Show all',
                onTap: widget.onToggleExpanded ?? () {},
              )
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(child: tappable),
            ?more,
          ],
        );
      },
    );

    final plate = DecoratedBox(
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: ds.hairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                label: d.turned ? context.l10n.messageTopDown(d.kind.label) : d.kind.label,
                copied: _copied,
                onCopy: _copy,
                onOpen: open == null ? null : () => open(context, d),
              ),
              body,
            ],
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: context.l10n.messageDiagram(d.kind.label.toLowerCase()),
      value: d.labels.take(40).join(', '),
      child: plate,
    );
  }
}

/// Draws a recorded scene at [scale]. The picture is the cache's: this never
/// disposes it.
class _PicturePainter extends CustomPainter {
  const _PicturePainter(this.picture, this.scale);

  final ui.Picture picture;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..scale(scale)
      ..drawPicture(picture);
  }

  @override
  bool shouldRepaint(_PicturePainter old) => !identical(old.picture, picture) || old.scale != scale;
}

class _Header extends StatelessWidget {
  const _Header({required this.label, required this.copied, required this.onCopy, required this.onOpen});

  final String label;
  final bool copied;
  final VoidCallback onCopy;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SizedBox(
      height: kMinTap,
      child: Row(
        children: [
          const SizedBox(width: Gap.md),
          Expanded(
            child: ExcludeSemantics(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.caption.copyWith(color: ds.textMuted),
              ),
            ),
          ),
          if (onOpen != null)
            PressBuilder(
              onTap: onOpen,
              semanticLabel: context.l10n.uiOpenDiagram,
              minTapSize: kMinTap,
              builder: (context, pressed) =>
                  Icon(LucideIcons.maximize2, size: 16, color: pressed ? ds.accentText : ds.textMuted),
            ),
          PressBuilder(
            onTap: onCopy,
            semanticLabel: copied ? context.l10n.uiCopied : context.l10n.uiCopySource,
            minTapSize: kMinTap,
            builder: (context, pressed) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
              child: Icon(
                copied ? LucideIcons.check : LucideIcons.copy,
                size: IconSize.row,
                color: copied || pressed ? ds.accentText : ds.textMuted,
              ),
            ),
          ),
          const SizedBox(width: Gap.xs),
        ],
      ),
    );
  }
}
