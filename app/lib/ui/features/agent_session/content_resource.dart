import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../core/theme.dart';
import '../files/file_format.dart';
import '../files/file_widgets.dart' show copyToClipboard, fileIconForName;
import 'code_panel.dart';
import 'content_chip.dart';
import 'content_image_cache.dart' show base64DecodedLength;
import 'content_target.dart';

/// How many lines of an embedded text resource show before "Show all".
const embeddedResourceLines = 6;

/// The Lucide glyph for a file or link by its mime type, else by its name; a
/// web address without either is a link.
IconData contentIcon({String? mime, required String name, bool web = false}) {
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('image/')) return LucideIcons.fileImage;
  if (m.startsWith('audio/')) return LucideIcons.fileMusic;
  if (m.startsWith('video/')) return LucideIcons.fileVideo;
  if (m == 'application/pdf' || m == 'text/markdown') return LucideIcons.fileText;
  if (m == 'application/json') return LucideIcons.fileBraces;
  if (m == 'application/zip' || m.contains('tar') || m.contains('gzip')) return LucideIcons.fileArchive;
  if (web && !name.contains('.')) return LucideIcons.link;
  return fileIconForName(name);
}

/// The name of a link as a person reads it: its title, else its name, else the
/// last part of its address.
String resourceLinkName(ResourceLinkBlock block) {
  for (final s in [block.title, block.name]) {
    if (s != null && s.trim().isNotEmpty) return s.trim();
  }
  return block.uri.trim().isEmpty ? 'Link' : contentBaseName(block.uri);
}

String _hint(ContentTarget? target, String uri) => switch (target) {
  WebTarget(:final host) => host,
  PathTarget(:final path) => path,
  null => uri.trim().length > 120 ? '${uri.trim().substring(0, 120)}…' : uri.trim(),
};

/// A `resource_link` (pi `/export`, codex `view_image`, a file the agent names)
/// as a tappable row: an icon by type, the name, and where it points. A `file:`
/// uri or a path opens the file viewer on the session's machine (the route a
/// path in the Markdown takes); an `http`/`https` address opens the link sheet,
/// which shows the whole address first. Another address stays plain text.
class ResourceLinkRow extends StatelessWidget {
  const ResourceLinkRow({super.key, required this.block});

  final ResourceLinkBlock block;

  @override
  Widget build(BuildContext context) {
    final target = resolveContentUri(block.uri);
    final name = resourceLinkName(block);
    final hint = _hint(target, block.uri);
    final size = block.size;
    final description = block.description?.trim() ?? '';
    return ContentChip(
      icon: contentIcon(mime: block.mimeType, name: name, web: target is WebTarget),
      title: name,
      detail: [if (hint.isNotEmpty && hint != name) hint, if (size != null && size > 0) formatBytes(size)].join(' · '),
      note: description.isEmpty ? null : description,
      muted: target == null,
      onTap: contentTapFor(context, target),
    );
  }
}

final _embeddedLines = Expando<List<CodeLine>>('embedded resource lines');

/// An embedded `resource`: a text resource shows its first
/// [embeddedResourceLines] lines in a quiet code panel under its name, with
/// "Show all" and a copy action; a binary one stays a line with its size. The
/// name taps like a [ResourceLinkRow] when the uri leads somewhere.
///
/// [expanded] and [onToggle] live with the transcript (the row key's "Show all"
/// flag), so an open panel survives scrolling out of the list.
class EmbeddedResourceView extends StatelessWidget {
  const EmbeddedResourceView({super.key, required this.block, required this.expanded, required this.onToggle});

  final EmbeddedResourceBlock block;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final target = resolveContentUri(block.uri);
    final name = block.uri.trim().isEmpty ? 'Attachment' : contentBaseName(block.uri);
    final mime = block.mimeType ?? '';
    final text = block.text;
    final blob = block.blob;
    final hint = _hint(target, block.uri);
    final head = ContentChip(
      icon: contentIcon(mime: block.mimeType, name: name, web: target is WebTarget),
      title: name,
      detail: [
        if (target is PathTarget && hint != name) hint else if (mime.isNotEmpty) mime,
        if (blob != null && blob.isNotEmpty) formatBytes(base64DecodedLength(blob)),
      ].join(' · '),
      note: text == null && (blob == null || blob.isEmpty) ? 'The attachment is empty.' : null,
      muted: target == null,
      onTap: contentTapFor(context, target),
    );
    if (text == null || text.isEmpty) return head;
    final term = context.terminal;
    final lines = _embeddedLines[block] ??= textLines(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        const SizedBox(height: Gap.xs),
        CodePanel(
          lines: lines,
          background: term.background,
          foreground: term.foreground,
          border: term.border,
          all: expanded,
          cap: embeddedResourceLines,
          onToggleAll: onToggle,
          onCopy: () => copyToClipboard(context, text, 'Copied'),
        ),
      ],
    );
  }
}
