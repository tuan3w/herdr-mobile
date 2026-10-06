import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import 'file_format.dart';
import 'file_kind.dart';
import 'file_viewer_view_model.dart';
import 'file_widgets.dart';

/// What a file the viewer cannot draw looks like: who it is, how big, when it
/// changed, and the first bytes as a hex dump. Nothing in it is read beyond
/// the first [viewerHexBytes] bytes.
class BinaryView extends StatelessWidget {
  const BinaryView({super.key, required this.model, required this.onCopyPath, this.onViewAsText});

  final FileViewerViewModel model;
  final VoidCallback onCopyPath;

  /// Offered for SVG: its source is text.
  final VoidCallback? onViewAsText;

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
                _ => fileIconForName(model.name) == LucideIcons.fileText ? LucideIcons.file : fileIconForName(model.name),
              },
              size: 48,
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
          label: 'Size',
          value: stat.size == null
              ? 'Unknown'
              : stat.size! < 1024
                  ? formatBytes(stat.size)
                  : '${formatBytes(stat.size)} (${groupDigits(stat.size!)} bytes)',
        ),
        if (stat.modified != null) InfoRow(label: 'Modified', value: formatExactTime(stat.modified)),
        if (perms.isNotEmpty) InfoRow(label: 'Permissions', value: perms, mono: true),
        InfoRow(label: 'Path', value: stat.path, mono: true, divider: false),
        const SizedBox(height: Gap.lg),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Copy path',
                icon: LucideIcons.copy,
                expand: true,
                kind: AppButtonKind.secondary,
                onPressed: onCopyPath,
              ),
            ),
            if (onViewAsText != null) ...[
              const SizedBox(width: Gap.sm),
              Expanded(
                child: AppButton(label: 'View as text', icon: LucideIcons.fileText, expand: true, onPressed: onViewAsText),
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
                  ? 'First ${model.head.length} bytes'
                  : 'Contents',
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
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: ds.hairline),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          dump(bytes),
          style: codeStyle(ds, size: 12, color: ds.textSecondary).copyWith(height: 1.55),
        ),
      ),
    );
  }
}
