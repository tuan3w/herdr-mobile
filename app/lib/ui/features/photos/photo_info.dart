import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../files/file_format.dart';
import '../files/file_widgets.dart';
import 'photo_viewer_view_model.dart';

/// One line of the info sheet. [copy] is what the copy button puts on the
/// clipboard (the full path), null for a line with no button.
class PhotoInfoRow {
  const PhotoInfoRow(this.label, this.value, {this.mono = false, this.copy, this.copied});

  final String label;
  final String value;
  final bool mono;
  final String? copy;
  final String? copied;

  @override
  String toString() => '$label: $value';
}

/// "12.2 MP" for a [width] x [height] picture; empty under 0.1 MP.
String megapixels(int width, int height) {
  final mp = width * height / 1e6;
  if (mp < 0.1) return '';
  return '${mp.toStringAsFixed(1)} MP';
}

/// What the sheet says about the picture of [entry]: enough to tell whether it
/// is the right one (where it is, how big, when it was made, what made it).
/// Lines whose value is not known are left out.
List<PhotoInfoRow> photoInfoRows(PhotoEntry entry) {
  final item = entry.item;
  final image = entry.image;
  final exif = entry.exif;
  final size = item.size ?? entry.bytes?.length;
  final rows = <PhotoInfoRow>[PhotoInfoRow('Name', item.name)];
  if (item.path != null) {
    rows.add(PhotoInfoRow('Path', item.path!, mono: true, copy: item.path, copied: 'Path copied'));
  }
  if (item.origin != null) rows.add(PhotoInfoRow('From', item.origin!));
  if (image != null) {
    final mp = megapixels(image.width, image.height);
    rows.add(PhotoInfoRow(
      'Dimensions',
      '${groupDigits(image.width)} × ${groupDigits(image.height)}${mp.isEmpty ? '' : ' · $mp'}',
    ));
  }
  if (size != null) rows.add(PhotoInfoRow('Size', formatBytes(size)));
  final format = entry.format ?? (item.mime != null && item.mime!.isNotEmpty ? item.mime! : null);
  if (format != null) rows.add(PhotoInfoRow('Format', format));
  if (item.modified != null) rows.add(PhotoInfoRow('Modified', formatExactTime(item.modified)));
  if (exif != null) {
    if (exif.taken != null) rows.add(PhotoInfoRow('Taken', formatExactTime(exif.taken)));
    if (exif.camera != null) rows.add(PhotoInfoRow('Camera', exif.camera!));
    if (exif.lens != null) rows.add(PhotoInfoRow('Lens', exif.lens!));
    if (exif.settings != null) rows.add(PhotoInfoRow('Exposure', exif.settings!));
    final o = exif.orientation;
    if (o != null && o != 1) rows.add(PhotoInfoRow('Orientation', 'Turned upright (EXIF $o)'));
  }
  if (image != null && image.downscaled && entry.sharp == null) {
    rows.add(const PhotoInfoRow('Showing', 'Screen-size preview; it sharpens as you zoom in'));
  }
  return rows;
}

/// The info sheet for the picture of [entry]. It lists what is known now.
Future<void> showPhotoInfo(BuildContext context, PhotoEntry entry) => showAppSheet<void>(
  context,
  builder: (ctx) => ListenableBuilder(
    listenable: entry,
    builder: (ctx, _) => _InfoBody(rows: photoInfoRows(entry)),
  ),
);

class _InfoBody extends StatelessWidget {
  const _InfoBody({required this.rows});

  final List<PhotoInfoRow> rows;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, Gap.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Photo info', style: Type.title.copyWith(color: ds.text)),
          ),
          const SizedBox(height: Gap.sm),
          for (final (i, row) in rows.indexed) _Row(row: row, divider: i < rows.length - 1),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.divider});

  final PhotoInfoRow row;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final copy = row.copy;
    if (copy == null) {
      return InfoRow(label: row.label, value: row.value, mono: row.mono, divider: divider);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(row.label, style: Type.secondary.copyWith(color: ds.textSecondary)),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text(
                    row.value,
                    textDirection: TextDirection.ltr,
                    style: codeStyle(ds, size: 12.5).copyWith(height: 1.4),
                  ),
                ),
              ),
              CircleButton(
                icon: LucideIcons.copy,
                tooltip: 'Copy ${row.label.toLowerCase()}',
                size: 36,
                onPressed: () => copyToClipboard(context, copy, row.copied ?? 'Copied'),
              ),
            ],
          ),
        ),
        if (divider) const Hairline(),
      ],
    );
  }
}
