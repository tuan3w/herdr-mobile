import 'package:flutter/widgets.dart';

import '../../core/markdown/markdown.dart';
import '../../core/terminal_links.dart' show looksLikeSlashCommand;

/// Where a link or uri from an agent leads, decided without touching the
/// network or the host.
sealed class ContentTarget {
  const ContentTarget();
}

/// An `http`/`https` address: shown in full in the link sheet before anything
/// opens, never fetched by the app.
class WebTarget extends ContentTarget {
  const WebTarget(this.url);

  final String url;

  /// `example.com` for the chip; the path stays in the sheet.
  String get host => Uri.tryParse(url)?.host ?? '';
}

/// A file on the session's machine (`file:///a/b`, `/a/b`, `~/a`, `./a`): the
/// file viewer opens it, through the same route as a path in the Markdown.
class PathTarget extends ContentTarget {
  const PathTarget(this.path);

  final String path;
}

/// What [uri] points at, or null when the app can do nothing with it (another
/// scheme, a `file:` uri on another host, an empty string). A `data:` uri is
/// not a target either: it is never decoded here.
ContentTarget? resolveContentUri(String uri) {
  final text = uri.trim();
  if (text.isEmpty) return null;
  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final parsed = Uri.tryParse(text);
    return parsed != null && parsed.host.isNotEmpty ? WebTarget(text) : null;
  }
  if (lower.startsWith('file:')) {
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    final host = parsed.host.toLowerCase();
    if (host.isNotEmpty && host != 'localhost') return null;
    final path = _decoded(parsed.path);
    return path.isEmpty ? null : PathTarget(path);
  }
  if (text.startsWith('/') || text.startsWith('~/') || text.startsWith('./') || text.startsWith('../')) {
    // `/model` is a word of the agent's, not a file.
    return looksLikeSlashCommand(text) ? null : PathTarget(text);
  }
  return null;
}

/// The last segment of a path or address, for a name when the agent sent none.
String contentBaseName(String uri) {
  final target = resolveContentUri(uri);
  switch (target) {
    case WebTarget(:final url):
      final parsed = Uri.tryParse(url);
      final segments = parsed?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
      return segments.isEmpty ? (parsed?.host ?? uri) : segments.last;
    case PathTarget(:final path):
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      return segments.isEmpty ? path : segments.last;
    case null:
      final trimmed = uri.trim();
      final cut = trimmed.lastIndexOf('/');
      return cut >= 0 && cut < trimmed.length - 1 ? trimmed.substring(cut + 1) : trimmed;
  }
}

String _decoded(String path) {
  try {
    return Uri.decodeComponent(path);
  } on ArgumentError {
    return path;
  }
}

/// What a tap on [target] does here: the link sheet for a web address, the
/// file viewer for a path. Null when the surface has no handler (no
/// `MdActions` above, as in a bare test), which makes the row plain text.
VoidCallback? contentTapFor(BuildContext context, ContentTarget? target, {int? line}) {
  final actions = MdActions.maybeOf(context);
  switch (target) {
    case WebTarget(:final url):
      final onLink = actions?.onLink;
      return onLink == null ? null : () => onLink(context, url);
    case PathTarget(:final path):
      final onPath = actions?.onPath;
      return onPath == null ? null : () => onPath(context, path, line);
    case null:
      return null;
  }
}
