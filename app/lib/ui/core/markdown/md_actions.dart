import 'package:flutter/widgets.dart';

/// A tapped web link (`http`/`https`, already vetted by the renderer). The
/// owner decides what to show first: the app's link sheet names the whole
/// address before anything opens, because text from an agent can label a link
/// with another address.
typedef MdLinkHandler = void Function(BuildContext context, String url);

/// A tapped file path (`lib/a.dart`, `lib/a.dart:42`, `~/x`, a relative link
/// target). [line] is the one-based line the text named, if it did. The owner
/// resolves it against the machine and folder it knows; the renderer never
/// touches the host, so a path costs nothing until it is tapped.
typedef MdPathHandler = void Function(BuildContext context, String path, int? line);

/// What a tap on a link, a path or an image chip does, for every Markdown
/// surface below it.
///
/// Kept apart from the renderer because only the screen knows the machine and
/// the folder a path is relative to, and `ui/core` may not reach into a
/// feature. A surface without a handler draws the text without the affordance:
/// no [onPath] means paths are plain text, no [onLink] means links are styled
/// text that does nothing, never a link that opens by itself.
class MdActions extends InheritedWidget {
  const MdActions({super.key, this.onLink, this.onPath, required super.child});

  final MdLinkHandler? onLink;
  final MdPathHandler? onPath;

  /// The nearest handlers, or null when none were provided.
  static MdActions? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MdActions>();

  @override
  bool updateShouldNotify(MdActions oldWidget) => onLink != oldWidget.onLink || onPath != oldWidget.onPath;
}
