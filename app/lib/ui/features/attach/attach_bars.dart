import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'attach_kit.dart';
import 'tray.dart';

extension AttachTabLook on AttachTab {
  String get label => switch (this) {
    AttachTab.gallery => 'Gallery',
    AttachTab.files => 'Files',
    AttachTab.host => 'Host',
  };

  IconData get icon => switch (this) {
    AttachTab.gallery => LucideIcons.images,
    AttachTab.files => LucideIcons.fileText,
    AttachTab.host => LucideIcons.server,
  };

  /// What the tab holds, for a screen reader.
  String get hint => switch (this) {
    AttachTab.gallery => 'Photos on this phone',
    AttachTab.files => 'Files on this phone',
    AttachTab.host => 'Files on the machine',
  };
}

/// The pill at the bottom of the sheet: Gallery | Files | Host, each an icon
/// and a label, the selected one on a soft capsule. Floats over the content
/// in the main tab bar's pill ([FloatingBarPill]), sized to its tabs.
class AttachTabBar extends StatelessWidget {
  const AttachTabBar({super.key, required this.selected, required this.onChanged});

  final AttachTab selected;
  final ValueChanged<AttachTab> onChanged;

  static Key tabKey(AttachTab tab) => ValueKey('attach-tab:${tab.name}');

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: kBarTextScale,
    child: Center(
      child: FloatingBarPill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tab in AttachTab.values)
              _TabItem(key: tabKey(tab), tab: tab, selected: tab == selected, onTap: () => onChanged(tab)),
          ],
        ),
      ),
    ),
  );
}

class _TabItem extends StatelessWidget {
  const _TabItem({super.key, required this.tab, required this.selected, required this.onTap});

  final AttachTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      haptic: !selected,
      scale: 0.95,
      selected: selected,
      semanticLabel: '${tab.label}, ${tab.hint}',
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: FloatingBar.cell,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          // `fill` on the pill's surface is about 1.1:1 and vanishes in dark.
          color: selected ? ds.fillPressed : Colors.transparent,
          borderRadius: BorderRadius.circular(FloatingBar.cell / 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon, size: 20, color: selected ? ds.text : ds.textSecondary),
            const SizedBox(width: 6),
            Text(
              tab.label,
              maxLines: 1,
              style: Type.label.copyWith(color: selected ? ds.text : ds.textSecondary, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

/// `3 / 5 · Clear · Attach (3)`: slides up (transform and opacity, 200 ms)
/// above the tab bar as soon as one thing is picked in any tab, and away when
/// the tray is empty again.
class AttachActionBar extends StatefulWidget {
  const AttachActionBar({super.key, required this.tray, required this.onAttach});

  final AttachTray tray;
  final VoidCallback onAttach;

  @override
  State<AttachActionBar> createState() => _AttachActionBarState();
}

class _AttachActionBarState extends State<AttachActionBar> with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(vsync: this, duration: Motion.standard, value: widget.tray.isEmpty ? 0 : 1);
  var _count = 0;

  @override
  void initState() {
    super.initState();
    _count = widget.tray.length;
    widget.tray.addListener(_onTray);
  }

  void _onTray() {
    final n = widget.tray.length;
    if (n > 0) _count = n;
    final reduced = Motion.reduced(context);
    if (n > 0) {
      if (reduced) {
        _slide.value = 1;
      } else {
        unawaited(_slide.forward().catchError((Object _) {}));
      }
    } else if (reduced) {
      _slide.value = 0;
    } else {
      unawaited(_slide.reverse().catchError((Object _) {}));
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.tray.removeListener(_onTray);
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tray = widget.tray;
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, _) {
        if (_slide.isDismissed) return const SizedBox(width: double.infinity);
        final count = tray.isEmpty ? _count : tray.length;
        Widget bar = MediaQuery.withClampedTextScaling(
          maxScaleFactor: kBarTextScale,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(FloatingBar.side, 0, FloatingBar.side, Gap.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ds.surface,
                // Not the pill's stadium: the compact buttons sit 10 dp inside
                // it, and a 28 dp radius would cut their corners.
                borderRadius: BorderRadius.circular(Radii.panel + 4),
                border: Border.all(color: ds.hairline),
                boxShadow: ds.floatShadow,
              ),
              child: SizedBox(
                height: FloatingBar.height,
                child: Padding(
                  padding: const EdgeInsets.only(left: Gap.xs, right: Gap.sm),
                  child: Row(
                    children: [
                      AppButton(label: 'Clear', kind: AppButtonKind.ghost, compact: true, onPressed: tray.clear),
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            '$count / ${tray.capacity}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.secondary.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
                          ),
                        ),
                      ),
                      AppButton(label: 'Attach ($count)', icon: LucideIcons.paperclip, onPressed: widget.onAttach, compact: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        if (_slide.value < 1) {
          final t = Motion.easeOut.transform(_slide.value);
          final reduced = Motion.reduced(context);
          bar = Opacity(
            opacity: t,
            child: reduced ? bar : Transform.translate(offset: Offset(0, (1 - t) * 24), child: bar),
          );
        }
        return IgnorePointer(ignoring: tray.isEmpty, child: bar);
      },
    );
  }
}
