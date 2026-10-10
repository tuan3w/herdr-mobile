import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/attach_target.dart';
import '../../../data/repositories/recent_phone_files.dart';
import '../../../data/services/attach_limits.dart';
import '../../../data/services/phone_files.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../agent_session/attach_model.dart' show ComposerAttachments;
import '../agent_session/visible_text.dart';
import '../files/file_format.dart';
import '../files/file_kind.dart';
import '../files/file_widgets.dart' show fileIconForName;
import '../files/middle_ellipsis.dart';
import 'attach_kit.dart';
import 'selection_circle.dart';
import 'sheet_frame.dart';
import 'tray.dart';

/// The Files tab of the attach sheet: files on the PHONE.
///
/// A `Choose files…` row opens the system picker; what it returns, and the
/// recent files below it, are only put in the [AttachTray]. Nothing is sent
/// from here: the composer's model decides about uploads when the person taps
/// Attach.
class FilesTab extends StatefulWidget {
  const FilesTab({
    super.key,
    required this.kit,
    required this.target,
    required this.tray,
    required this.onProblem,
  });

  final AttachKit kit;
  final AttachTarget target;
  final AttachTray tray;

  /// Says something went wrong (the composer shows it as a toast).
  final void Function(String message) onProblem;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  var _loaded = false;
  var _picking = false;

  /// Recent files whose host copy is being checked: a second tap meanwhile
  /// must not toggle twice.
  final _checking = <RecentPhoneFile>{};

  static const goneMessage = 'That copy is gone from the host. Choose the file again.';

  @override
  void initState() {
    super.initState();
    widget.tray.addListener(_changed);
    widget.kit.recents.addListener(_changed);
    _loadRecents();
  }

  void _loadRecents() {
    final recents = widget.kit.recents;
    unawaited(
      recents.load().whenComplete(() {
        if (mounted && recents == widget.kit.recents) setState(() => _loaded = true);
      }),
    );
  }

  @override
  void didUpdateWidget(FilesTab old) {
    super.didUpdateWidget(old);
    if (old.tray != widget.tray) {
      old.tray.removeListener(_changed);
      widget.tray.addListener(_changed);
    }
    if (old.kit.recents != widget.kit.recents) {
      old.kit.recents.removeListener(_changed);
      widget.kit.recents.addListener(_changed);
      _loaded = false;
      _loadRecents();
    }
  }

  @override
  void dispose() {
    widget.tray.removeListener(_changed);
    widget.kit.recents.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Opens the system picker and puts what it returns in the tray.
  Future<void> _choose() async {
    if (_picking) return;
    _picking = true;
    try {
      final files = await widget.kit.files.pick();
      if (!mounted) return;
      for (final file in files) {
        if (sizeVerdict(file.size) == SizeVerdict.tooLarge) {
          widget.onProblem(ComposerAttachments.tooLargeMessage(visibleText(file.name), file.size));
          continue;
        }
        // A full tray has said so itself (its onFull); the rest would only repeat it.
        if (!widget.tray.add(PhonePick(path: file.path, name: file.name, size: file.size))) break;
      }
    } on PhoneFileException catch (e) {
      if (mounted) widget.onProblem(e.message);
    } finally {
      _picking = false;
    }
  }

  bool _onHost(RecentPhoneFile r) {
    final machine = widget.target.machine;
    return r.hostPath != null && r.machineId == machine.profile.id && machine.files.supported;
  }

  Future<void> _openRecent(RecentPhoneFile r) async {
    if (!_onHost(r)) return _choose();
    final pick = HostPick(path: r.hostPath!, name: r.name, size: r.size, fromPhone: true);
    final tray = widget.tray;
    if (tray.contains(pick.key)) {
      tray.remove(pick.key);
      return;
    }
    if (!_checking.add(r)) return;
    try {
      final stat = await widget.target.machine.files.stat(pick.path);
      if (!mounted) return;
      if (stat.kind != RemoteEntryKind.file) return _gone(r);
      tray.add(pick);
    } on RemoteFileException catch (e) {
      if (!mounted) return;
      // A missing copy is gone for good; a dropped link says so and keeps the entry.
      if (e.kind == RemoteFileErrorKind.notFound || e.kind == RemoteFileErrorKind.notAFile) return _gone(r);
      widget.onProblem(e.message);
    } finally {
      _checking.remove(r);
    }
  }

  void _gone(RecentPhoneFile r) {
    widget.onProblem(goneMessage);
    unawaited(widget.kit.recents.remove(r));
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tray = widget.tray;
    final recents = widget.kit.recents.files;
    final picked = [
      for (final item in tray.items)
        if (item is PhonePick || (item is HostPick && item.fromPhone)) item,
    ];
    final imagesAsFiles = !widget.target.preparesPictures;
    final clearance = SheetScope.of(context).bottomClearance;

    return ColoredBox(
      color: ds.bg,
      child: SheetScroll(
        builder: (context, controller, physics) => ListView(
          controller: controller,
          physics: physics,
          padding: EdgeInsets.only(top: Gap.sm, bottom: clearance),
          children: [
            _ChooseTile(onTap: _choose),
            if (recents.isEmpty && _loaded && picked.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, Gap.sm),
                child: Text(
                  'Files you attach from the phone are listed here.',
                  style: Type.secondary.copyWith(color: ds.textMuted),
                ),
              ),
            if (picked.isNotEmpty) ...[
              SectionLabel(label: 'Picked', count: picked.length),
              for (final item in picked)
                _FileRow(
                  key: ValueKey('picked:${item.key}'),
                  name: item.name,
                  detail: _pickedDetail(item, imagesAsFiles),
                  number: tray.numberOf(item.key),
                  onTap: () => tray.remove(item.key),
                ),
            ],
            if (recents.isNotEmpty) ...[
              SectionLabel(label: 'Recent', count: recents.length),
              for (final r in recents) _recentRow(r),
            ],
          ],
        ),
      ),
    );
  }

  Widget _recentRow(RecentPhoneFile r) {
    final onHost = _onHost(r);
    final pick = onHost ? HostPick(path: r.hostPath!, name: r.name, size: r.size, fromPhone: true) : null;
    return _FileRow(
      key: ValueKey('recent:${r.name}:${r.size}:${r.hostPath}'),
      name: r.name,
      detail: '${formatBytes(r.size)} · ${onHost ? 'already on the host' : 'choose it again'}',
      number: pick == null ? null : widget.tray.numberOf(pick.key),
      onTap: () => unawaited(_openRecent(r)),
      onForget: () => unawaited(widget.kit.recents.remove(r)),
    );
  }

  static String _pickedDetail(TrayItem item, bool imagesAsFiles) {
    final size = item.size;
    final parts = [
      formatBytes(size),
      if (size != null && sizeVerdict(size) == SizeVerdict.large) 'large, uploading may take a while',
      if (imagesAsFiles && typeForName(item.name).kind == FileKind.image) 'sent as a file',
    ];
    return parts.join(' · ');
  }
}

/// `Choose files…`: the first row of the tab.
class _ChooseTile extends StatelessWidget {
  const _ChooseTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      haptic: true,
      builder: (context, pressed) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: _rowInset),
        child: AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: _rowHeight),
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - _rowInset, vertical: Gap.md),
          decoration: BoxDecoration(
            color: pressed ? ds.fill : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(
            children: [
              IconTile(icon: LucideIcons.folderOpen, color: ds.accentText),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Choose files…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.row.copyWith(color: ds.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Opens the phone\'s file picker',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondary.copyWith(color: ds.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _rowInset = 8.0;
const _rowHeight = 56.0;

/// One file: type tile, name cut in the middle, one muted line, and the
/// selection circle at the right end (plus an `x` on a recent one).
///
/// Two accessibility nodes: the row (`Name, 12 MB, not selected`) and the
/// circle (`Select Name`); the `x` is a third on a recent row.
class _FileRow extends StatelessWidget {
  const _FileRow({
    super.key,
    required this.name,
    required this.detail,
    required this.number,
    required this.onTap,
    this.onForget,
  });

  final String name;
  final String detail;

  /// Place in the tray; null when not picked.
  final int? number;
  final VoidCallback onTap;

  /// Takes a recent file off the list; null on a picked row.
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final shown = visibleText(name);
    final picked = number != null;
    final trailing = kMinTap * (onForget == null ? 1 : 2);
    final label = '$shown, ${detail.replaceAll(' · ', ', ')}, ${picked ? 'selected' : 'not selected'}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            PressBuilder(
              onTap: onTap,
              haptic: true,
              semanticLabel: label,
              builder: (context, pressed) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: _rowInset),
                child: AnimatedContainer(
                  duration: Motion.pressing(pressed),
                  curve: Motion.easeOut,
                  constraints: const BoxConstraints(minHeight: _rowHeight),
                  alignment: Alignment.centerLeft,
                  padding: EdgeInsets.fromLTRB(Gap.gutter - _rowInset, Gap.md, trailing + Gap.xs, Gap.md),
                  decoration: BoxDecoration(
                    color: pressed ? ds.fill : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.row),
                  ),
                  child: Row(
                    children: [
                      IconTile(icon: fileIconForName(shown)),
                      const SizedBox(width: Gap.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MiddleEllipsisText(shown, style: Type.row.copyWith(color: ds.text)),
                            const SizedBox(height: 2),
                            Text(
                              detail,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Type.secondary.copyWith(color: ds.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: _rowInset,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectionCircle(
                    number: number,
                    onTap: onTap,
                    label: picked ? 'Deselect $shown' : 'Select $shown',
                  ),
                  if (onForget != null)
                    PressBuilder(
                      onTap: onForget,
                      haptic: true,
                      scale: 0.9,
                      minTapSize: kMinTap,
                      semanticLabel: 'Remove $shown from recent files',
                      builder: (context, pressed) => Icon(LucideIcons.x, size: 16, color: ds.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
        const Hairline(indent: Gap.gutter + 32 + Gap.md),
      ],
    );
  }
}
