import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import 'content_chip.dart';
import 'content_image.dart';
import 'content_resource.dart';

/// A piece of a message or of a tool's output that is not Markdown text: a
/// picture ([ImageBlockView]), a link to a file or page ([ResourceLinkRow]), an
/// embedded text or binary resource ([EmbeddedResourceView]), or a line for
/// what the app cannot show (audio, a block it does not know).
///
/// [expanded] and [onToggle] are the "Show all" flag of an embedded text; the
/// owner keeps it (the transcript, the tool call) so it survives the row
/// scrolling out of the list.
class ContentBlockView extends StatelessWidget {
  const ContentBlockView({super.key, required this.block, this.expanded = false, this.onToggle});

  final ContentBlock block;
  final bool expanded;
  final VoidCallback? onToggle;

  static void _nothing() {}

  @override
  Widget build(BuildContext context) => switch (block) {
    ImageBlock() => ImageBlockView(block: block as ImageBlock),
    ResourceLinkBlock() => ResourceLinkRow(block: block as ResourceLinkBlock),
    EmbeddedResourceBlock() => EmbeddedResourceView(
      block: block as EmbeddedResourceBlock,
      expanded: expanded,
      onToggle: onToggle ?? _nothing,
    ),
    AudioBlock(:final mimeType) => ContentChip(icon: LucideIcons.audioLines, title: 'Audio', detail: mimeType),
    UnknownBlock(:final type) => ContentChip(
      icon: LucideIcons.circleHelp,
      title: 'Content this app can’t show',
      detail: type,
      muted: true,
    ),
    TextBlock(:final text) => ContentChip(icon: LucideIcons.fileText, title: 'Text', detail: text),
  };
}
