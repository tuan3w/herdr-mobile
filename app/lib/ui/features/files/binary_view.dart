import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'file_format.dart';
import 'file_kind.dart';
import 'file_viewer_view_model.dart';
import 'file_widgets.dart';

/// What a file the viewer cannot draw looks like: who it is, how big, when it
/// changed, and the first bytes as a hex dump. Nothing in it is read beyond
/// the first [viewerHexBytes] bytes.
class BinaryView extends StatelessWidget {
  const BinaryView({
    super.key,
    required this.model,
    required this.onCopyPath,
    required this.onShare,
    this.onViewAsText,
    this.onShowAsPage,
  });

  final FileViewerViewModel model;
  final VoidCallback onCopyPath;

  /// Hands the file to the share sheet (copied to the phone first).
  final VoidCallback onShare;

  /// Offered for SVG: its source is text.
  final VoidCallback? onViewAsText;

  /// Offered for SVG, which has no drawn view here at all: shown as a page
  /// (`WebPreviewScreen`).
  final VoidCallback? onShowAsPage;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final stat = model.stat;
    final bottom = MediaQuery.paddingOf(context).bottom + Gap.xl;
    final perms = formatPermissions(stat.mode);
    return ListView(
      padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, bottom),
      children: [
        Row(
          children: [
            IconTile(
              icon: switch (model.kind) {
                FileKind.svg => LucideIcons.fileImage,
                FileKind.pdf => LucideIcons.fileText,
                _ =>
                  fileIconForName(model.name) == LucideIcons.fileText ? LucideIcons.file : fileIconForName(model.name),
              },
              size: IconSize.hero,
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.row.copyWith(color: ds.text),
                  ),
                  Text(
                    model.type.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.lg),
        const Hairline(),
        InfoRow(
          label: context.l10n.uiSize,
          value: stat.size == null
              ? 'Unknown'
              : stat.size! < 1024
              ? formatBytes(stat.size)
              : '${formatBytes(stat.size)} (${groupDigits(stat.size!)} bytes)',
        ),
        if (stat.modified case final at?)
          InfoRow(label: context.l10n.uiModified, value: formatWhen(at, DateTime.now())),
        if (perms.isNotEmpty) InfoRow(label: context.l10n.uiPermissions, value: perms, mono: true),
        InfoRow(label: context.l10n.uiPath, value: stat.path, mono: true, divider: false),
        const SizedBox(height: Gap.lg),
        if (onShowAsPage != null) ...[
          AppButton(label: context.l10n.uiShowAsPage, icon: LucideIcons.globe, expand: true, onPressed: onShowAsPage),
          const SizedBox(height: Gap.sm),
        ],
        // What there is to do with a file the viewer cannot show: take it elsewhere.
        AppButton(
          label: context.l10n.uiShareOrSave,
          icon: LucideIcons.share2,
          expand: true,
          kind: onShowAsPage == null && onViewAsText == null ? AppButtonKind.primary : AppButtonKind.secondary,
          onPressed: onShare,
        ),
        const SizedBox(height: Gap.sm),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: context.l10n.uiCopyPath,
                icon: LucideIcons.copy,
                expand: true,
                kind: AppButtonKind.secondary,
                onPressed: onCopyPath,
              ),
            ),
            if (onViewAsText != null) ...[
              const SizedBox(width: Gap.sm),
              Expanded(
                child: AppButton(
                  label: context.l10n.uiShowAsText,
                  icon: LucideIcons.fileText,
                  expand: true,
                  kind: onShowAsPage == null ? AppButtonKind.primary : AppButtonKind.secondary,
                  onPressed: onViewAsText,
                ),
              ),
            ],
          ],
        ),
        if (model.head.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(
              model.head.length < (stat.size ?? model.head.length)
                  ? context.l10n.messageFirstBytes('${model.head.length}')
                  : context.l10n.uiContents,
              style: Type.label.copyWith(color: ds.textSecondary),
            ),
          ),
          _HexDump(bytes: model.head),
        ],
      ],
    );
  }
}

class _HexDump extends StatelessWidget {
  const _HexDump({required this.bytes});

  final Uint8List bytes;

  static String dump(Uint8List bytes) {
    const perRow = 8;
    final out = StringBuffer();
    for (var at = 0; at < bytes.length; at += perRow) {
      final row = bytes.sublist(at, at + perRow > bytes.length ? bytes.length : at + perRow);
      if (at > 0) out.writeln();
      out.write(at.toRadixString(16).padLeft(4, '0'));
      out.write('  ');
      for (var i = 0; i < perRow; i++) {
        out.write(i < row.length ? row[i].toRadixString(16).padLeft(2, '0') : '  ');
        out.write(i == perRow - 1 ? '  ' : ' ');
      }
      for (final b in row) {
        out.write(b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : '·');
      }
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: ds.fill,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: ds.hairline),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(dump(bytes), style: Mono.base.copyWith(color: ds.textSecondary)),
      ),
    );
  }
}
