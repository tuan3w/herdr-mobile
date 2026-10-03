import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/open_tabs.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/theme.dart';
import 'tab_info.dart';

/// Preview rows on a card.
const _previewRows = 3;

/// Card height at the default text scale (text scale is clamped to 1.3).
const _cardExtent = 142.0;

/// Every open tab as a card, two to a row, like a browser's tab switcher: the
/// agent's state, name and where it runs, the last rows of its terminal, and how
/// long it has been in that state. Tapping a card switches to the tab.
///
/// Cards watch their pane's preview only while the tray is mounted; the host
/// unmounts it when it has closed, which releases every watcher.
class TabsTray extends StatelessWidget {
  const TabsTray({
    super.key,
    required this.tabs,
    required this.infos,
    required this.maxHeight,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
    required this.onDismiss,
  });

  final OpenTabs tabs;
  final ValueListenable<List<TabInfo>> infos;
  final double maxHeight;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback onAdd;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.3);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.bg,
        border: Border(bottom: BorderSide(color: ds.hairline)),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(Radii.sheet),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(Radii.sheet),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: ListenableBuilder(
                    listenable: Listenable.merge([tabs, infos]),
                    builder: (context, _) {
                      final list = infos.value;
                      return CustomScrollView(
                        shrinkWrap: true,
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                              Gap.lg,
                              Gap.xs,
                              Gap.lg,
                              Gap.sm,
                            ),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    mainAxisSpacing: Gap.sm,
                                    crossAxisSpacing: Gap.sm,
                                    mainAxisExtent: _cardExtent * scale,
                                  ),
                              delegate: SliverChildBuilderDelegate(
                                childCount: list.length + 1,
                                (context, i) {
                                  if (i == list.length) {
                                    return _AddCard(onTap: onAdd);
                                  }
                                  final info = list[i];
                                  return _TabCard(
                                    key: ValueKey(info.key),
                                    info: info,
                                    active: info.key == tabs.activeKey,
                                    attention: tabs.hasAttention(info.key),
                                    onTap: () => onSelect(info.key),
                                    onClose: () => onClose(info.key),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              // A handle to pull back up, or tap, like the sheets.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                onVerticalDragUpdate: (d) {
                  if (d.delta.dy < -4) onDismiss();
                },
                child: SizedBox(
                  height: 20,
                  width: double.infinity,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: ds.textTertiary.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: const SizedBox(width: 36, height: 4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabCard extends StatefulWidget {
  const _TabCard({
    super.key,
    required this.info,
    required this.active,
    required this.attention,
    required this.onTap,
    required this.onClose,
  });

  final TabInfo info;
  final bool active;
  final bool attention;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_TabCard> createState() => _TabCardState();
}

class _TabCardState extends State<_TabCard> {
  PreviewHandle? _handle;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_TabCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Watches the pane's preview while it exists.
  void _sync() {
    final wanted = !widget.info.gone;
    if (wanted && _handle == null) {
      final ref = widget.info.ref;
      _handle = context.read<PanePreviews>().watch(ref.machineId, ref.paneId);
    } else if (!wanted && _handle != null) {
      _handle!.release();
      _handle = null;
    }
  }

  @override
  void dispose() {
    _handle?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final info = widget.info;
    final status = info.status;
    final stale = !info.live || info.gone;
    final state = info.stateText(DateTime.now());
    return PressBuilder(
      onTap: widget.onTap,
      scale: 0.98,
      builder: (context, pressed) => DecoratedBox(
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : ds.surface,
          borderRadius: BorderRadius.circular(Radii.panel),
          // Selected: accent. Needs you: a quiet orange edge, as on the board.
          border: Border.all(
            color: widget.active
                ? ds.accent
                : (status == AgentStatus.blocked
                      ? ds.blocked.withValues(alpha: 0.55)
                      : ds.hairline),
            width: widget.active ? 1.5 : 1,
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          status == null
                              ? Icon(
                                  LucideIcons.squareX,
                                  size: 16,
                                  color: ds.textTertiary,
                                )
                              : StatusGlyph(
                                  status: status,
                                  size: 16,
                                  dim: stale,
                                ),
                          if (widget.attention)
                            Positioned(
                              top: -3,
                              right: -3,
                              child: Semantics(
                                label: 'Changed while hidden',
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: ds.accent,
                                    border: Border.all(
                                      color: ds.surface,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: const SizedBox.square(dimension: 9),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 22),
                          child: Text(
                            info.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.secondary.copyWith(
                              fontWeight: FontWeight.w600,
                              color: ds.text,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 22),
                    child: Text(
                      info.where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(color: ds.textMuted),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ColoredBox(
                        color: context.terminal.background,
                        child: SizedBox.expand(
                          child: _handle == null
                              ? const _PreviewRows(rows: [], stale: true)
                              : ValueListenableBuilder<PanePreview?>(
                                  valueListenable: _handle!.preview,
                                  builder: (context, preview, _) =>
                                      _PreviewRows(
                                        rows: preview == null
                                            ? const []
                                            : [
                                                for (final l
                                                    in preview.lines.skip(
                                                      math.max(
                                                        0,
                                                        preview.lines.length -
                                                            _previewRows,
                                                      ),
                                                    ))
                                                  l.text,
                                              ],
                                        stale: stale,
                                      ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    state ?? (info.gone ? 'closed' : ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.caption.copyWith(
                      color: stale ? ds.textMuted : (status?.textColor(ds) ?? ds.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: PressBuilder(
                onTap: widget.onClose,
                scale: 0.9,
                semanticLabel: 'Close tab ${info.title}',
                minTapSize: kMinTap,
                builder: (context, pressed) => Icon(
                  LucideIcons.x,
                  size: 15,
                  color: pressed ? ds.text : ds.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last rows of a terminal in the tab's card: small, monospace, cut at the
/// right edge; dimmed when the pane is not live.
class _PreviewRows extends StatelessWidget {
  const _PreviewRows({required this.rows, required this.stale});

  final List<String> rows;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final palette = context.terminal;
    final color = stale ? palette.dim : palette.foreground;
    final style = TextStyle(
      fontFamily: monoFamily,
      fontSize: 10.5,
      height: 1.25,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.isEmpty)
            Text('…', style: style.copyWith(color: palette.dim))
          else
            for (final row in rows)
              Text(
                row.isEmpty ? ' ' : row,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: style,
              ),
        ],
      ),
    );
  }
}

/// The last card: leaves the tab screen for the board, to pick another agent.
class _AddCard extends StatelessWidget {
  const _AddCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: 0.98,
      builder: (context, pressed) => DecoratedBox(
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : ds.fill,
          borderRadius: BorderRadius.circular(Radii.panel),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.plus, size: 22, color: ds.textSecondary),
              const SizedBox(height: 6),
              Text(
                'Open another agent',
                textAlign: TextAlign.center,
                style: Type.caption.copyWith(color: ds.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
