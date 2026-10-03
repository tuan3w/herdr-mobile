import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/open_tabs.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'tab_info.dart';

/// Height of the strip: every chip is a full 44dp touch target.
const tabStripHeight = 44.0;

/// Longest a chip's label grows before an ellipsis cuts it: the selected tab
/// gets more room than the others, so three or so tabs fit on a phone.
const _activeLabelMax = 160.0;
const _otherLabelMax = 110.0;

/// The same, with room to spare (landscape, where the strip is the title bar).
const _activeLabelMaxWide = 300.0;
const _otherLabelMaxWide = 160.0;

/// The open tabs as chips, left to right, with the count button at the right
/// end. The order is the order of [OpenTabs.tabs] and only changes when tabs
/// open or close; selecting a tab scrolls it into view and nothing else moves.
///
/// Only the selected chip carries a close button: a 44dp close target on every
/// chip would leave room for two chips on a phone. Other tabs close from their
/// long-press sheet or from the tray.
///
/// Dragging down on the strip opens the tray, like pulling a browser's tab bar.
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.infos,
    required this.onOpenTray,
    required this.onClose,
    required this.onActions,
    this.wide = false,
  });

  /// More room for labels, as when the strip shares a row with the buttons.
  final bool wide;

  final OpenTabs tabs;
  final ValueListenable<List<TabInfo>> infos;
  final VoidCallback onOpenTray;
  final ValueChanged<String> onClose;
  final ValueChanged<TabInfo> onActions;

  @override
  State<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<TabStrip> {
  final _scroll = ScrollController();
  final _viewKey = GlobalKey();
  final _chipKeys = <String, GlobalKey>{};
  String? _shown;
  bool _revealed = false;
  double _pull = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the selected chip into view, centred, unless it is already fully
  /// visible (then nothing moves). The first reveal does not animate.
  void _reveal(String key, {required bool animate}) {
    final context = _chipKeys[key]?.currentContext;
    final view = _viewKey.currentContext?.findRenderObject();
    if (context == null || !context.mounted || view is! RenderBox) return;
    final chip = context.findRenderObject()! as RenderBox;
    final left = view.globalToLocal(chip.localToGlobal(Offset.zero)).dx;
    if (left >= 8 && left + chip.size.width <= view.size.width - 8) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: animate && !Motion.reduced(context)
          ? Motion.standard
          : Duration.zero,
      curve: Motion.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: (_) => _pull = 0,
    onVerticalDragUpdate: (d) {
      _pull += d.delta.dy;
      if (_pull > 24) {
        _pull = -double.maxFinite;
        HapticFeedback.selectionClick();
        widget.onOpenTray();
      }
    },
    child: SizedBox(
      height: tabStripHeight,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.tabs, widget.infos]),
        builder: (context, _) {
          final infos = widget.infos.value;
          final active = widget.tabs.activeKey;
          _chipKeys.removeWhere((k, _) => !widget.tabs.contains(k));
          if (active != null && active != _shown) {
            _shown = active;
            final first = _revealed;
            _revealed = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _reveal(active, animate: first);
            });
          }
          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: _viewKey,
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: Gap.lg - 6),
                  child: Row(
                    children: [
                      for (final info in infos)
                        _TabChip(
                          key: _chipKeys.putIfAbsent(info.key, GlobalKey.new),
                          info: info,
                          wide: widget.wide,
                          active: info.key == active,
                          attention: widget.tabs.hasAttention(info.key),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            widget.tabs.activate(info.key);
                          },
                          onClose: () => widget.onClose(info.key),
                          onActions: () => widget.onActions(info),
                        ),
                    ],
                  ),
                ),
              ),
              TabCountButton(
                count: widget.tabs.length,
                attention: widget.tabs.attentionCount > 0,
                onTap: widget.onOpenTray,
              ),
              const SizedBox(width: Gap.sm),
            ],
          );
        },
      ),
    ),
  );
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.info,
    required this.wide,
    required this.active,
    required this.attention,
    required this.onTap,
    required this.onClose,
    required this.onActions,
  });

  final TabInfo info;
  final bool wide;
  final bool active;
  final bool attention;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final dim = !info.live;
    return PressBuilder(
      onTap: active ? null : onTap,
      onLongPress: onActions,
      selected: active,
      // A selected chip is not tappable (its close button is), but must keep
      // reading as a tab.
      button: true,
      builder: (context, pressed) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: active
                        ? ds.surface
                        : (pressed ? ds.fillPressed : Colors.transparent),
                    borderRadius: BorderRadius.circular(Radii.control),
                    border: active ? Border.all(color: ds.border) : null,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: tabStripHeight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 10),
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      info.status == null
                          ? Icon(
                              LucideIcons.squareX,
                              size: 16,
                              color: ds.textTertiary,
                            )
                          : StatusGlyph(
                              status: info.status!,
                              size: 16,
                              dim: dim,
                            ),
                      if (attention)
                        Positioned(
                          top: -3,
                          right: -3,
                          child: Semantics(
                            label: 'Changed while hidden',
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ds.accent,
                                border: Border.all(color: ds.bg, width: 1.5),
                              ),
                              child: const SizedBox.square(dimension: 9),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: active
                          ? (wide ? _activeLabelMaxWide : _activeLabelMax)
                          : (wide ? _otherLabelMaxWide : _otherLabelMax),
                    ),
                    child: Text(
                      info.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.label.copyWith(
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                        color: active ? ds.text : ds.textSecondary,
                      ),
                    ),
                  ),
                  if (active)
                    PressBuilder(
                      onTap: onClose,
                      scale: 0.9,
                      semanticLabel: 'Close tab',
                      minTapSize: kMinTap,
                      builder: (context, pressed) => Icon(
                        LucideIcons.x,
                        size: 15,
                        color: pressed ? ds.text : ds.textSecondary,
                      ),
                    )
                  else
                    const SizedBox(width: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tab switcher button: the number of open tabs in a rounded square, with a
/// dot when a background tab changed.
class TabCountButton extends StatelessWidget {
  const TabCountButton({
    super.key,
    required this.count,
    required this.attention,
    required this.onTap,
  });

  final int count;
  final bool attention;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: 0.94,
      minTapSize: kMinTap,
      semanticLabel: attention
          ? 'All tabs, $count open, some changed'
          : 'All tabs, $count open',
      builder: (context, pressed) => Stack(
        clipBehavior: Clip.none,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: pressed ? ds.text : ds.textSecondary,
                width: 1.5,
              ),
            ),
            child: SizedBox.square(
              dimension: 26,
              child: Center(
                child: Text(
                  '$count',
                  maxLines: 1,
                  style: Type.caption.copyWith(
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: ds.text,
                    fontFeatures: Type.tabular,
                  ),
                ),
              ),
            ),
          ),
          if (attention)
            Positioned(
              top: -3,
              right: -3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ds.accent,
                  border: Border.all(color: ds.bg, width: 1.5),
                ),
                child: const SizedBox.square(dimension: 9),
              ),
            ),
        ],
      ),
    );
  }
}
