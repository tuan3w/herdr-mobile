import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'attach_kit.dart';
import 'tray.dart';

extension AttachTabLook on AttachTab {
  String get label => switch (this) {
    AttachTab.gallery => 'Gallery',
    AttachTab.files => 'Files',
    AttachTab.host => 'Machine',
  };

  IconData get icon => switch (this) {
    AttachTab.gallery => HerdrIcons.pictures,
    AttachTab.files => LucideIcons.fileText,
    AttachTab.host => HerdrIcons.machines,
  };

  /// What the tab holds, for a screen reader.
  String get hint => switch (this) {
    AttachTab.gallery => 'Photos on this phone',
    AttachTab.files => 'Files on this phone',
    AttachTab.host => 'Files on the machine',
  };
}

/// The pill at the bottom of the sheet: Gallery | Files | Machine, each an icon
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
            // Flexible: on a narrow screen at the bar's largest text the labels
            // give way (ellipsis) instead of overflowing the pill.
            for (final tab in AttachTab.values)
              Flexible(
                child: _TabItem(key: tabKey(tab), tab: tab, selected: tab == selected, onTap: () => onChanged(tab)),
              ),
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
      scale: PressScale.chip,
      selected: selected,
      semanticLabel: '${tab.label}, ${tab.hint}',
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: FloatingBar.cell,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          // Selection is a hue, as on the app's tab bar: an accent wash under accent text.
          color: selected ? ds.accentWash : Colors.transparent,
          borderRadius: BorderRadius.circular(FloatingBar.cell / 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon, size: IconSize.lead, color: selected ? ds.accentText : ds.textSecondary),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.label.copyWith(color: selected ? ds.accentText : ds.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `3 / 5 · Clear · Attach (3)`: a lane of the bottom stack above the attach
/// sheet's tab pill, there as soon as one thing is picked in any tab and away
/// when the tray is empty again ([BottomStackTransition]).
class AttachActionBar extends StatefulWidget {
  const AttachActionBar({super.key, required this.tray, required this.onAttach});

  final AttachTray tray;
  final VoidCallback onAttach;

  @override
  State<AttachActionBar> createState() => _AttachActionBarState();
}

class _AttachActionBarState extends State<AttachActionBar> {
  /// The count while it leaves: the last one it showed.
  var _count = 0;

  @override
  void initState() {
    super.initState();
    _count = widget.tray.length;
    widget.tray.addListener(_onTray);
  }

  void _onTray() {
    if (widget.tray.length > 0) _count = widget.tray.length;
    setState(() {});
  }

  @override
  void dispose() {
    widget.tray.removeListener(_onTray);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tray = widget.tray;
    final count = tray.isEmpty ? _count : tray.length;
    return BottomStackTransition(
      visible: !tray.isEmpty,
      builder: (_) => FloatingBarSlot(
        aboveInset: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ds.surface,
            // Not the pill's stadium: the compact buttons sit inside it, and a
            // 28 dp radius would cut their corners.
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: ds.hairline),
            boxShadow: ds.floatShadow,
          ),
          child: SizedBox(
            height: FloatingBar.height,
            child: Padding(
              padding: const EdgeInsets.only(left: Gap.xs, right: Gap.sm),
              child: Row(
                children: [
                  AppButton(
                    label: context.l10n.uiClear,
                    kind: AppButtonKind.ghost,
                    compact: true,
                    onPressed: tray.clear,
                  ),
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
                  AppButton(
                    label: context.l10n.messageAttach('$count'),
                    icon: LucideIcons.paperclip,
                    onPressed: widget.onAttach,
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
