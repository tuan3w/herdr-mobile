import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart' show MessageRole;
import '../../../data/acp/session_state.dart';
import '../../core/chrome.dart';
import '../../core/markdown/markdown.dart';
import '../files/file_widgets.dart' show copyToClipboard;

/// Copying a message (docs/DESIGN.md "Copying").
///
/// A long press on text belongs to `SelectionArea`: it selects the word and
/// shows the selection toolbar. A long-press handler on the row wins that
/// contest (the deeper recognizer is asked first) and kills selection, so a
/// message is NOT copied by a long press of its own. Instead:
///
///  * the selection toolbar carries two more buttons, `Copy message` and (for
///    an answer) `Copy as Markdown`, for the message the finger went down on;
///  * a screen reader gets the custom action `Copy message` on every block of
///    the message, which opens the same choice as a sheet ([showMessageCopySheet]).
///
/// No button is drawn on the message: an always-visible one would be noise on
/// every answer.

/// What `Copy message` puts on the clipboard: what the person typed, or what the
/// answer says without its Markdown marks.
String messagePlainText(TranscriptMessage message) =>
    message.role == MessageRole.user ? message.text : parseMd(message.text).plainText;

/// What `Copy as Markdown` puts on the clipboard: the source the agent sent,
/// byte for byte.
String messageMarkdown(TranscriptMessage message) => message.text;

/// Whether [message] has anything to copy and a Markdown source worth offering
/// (an answer; what a person typed is already plain).
bool messageHasMarkdown(TranscriptMessage message) => message.role == MessageRole.agent;

/// The message a finger last went down on, valid only for that touch.
///
/// A row notes its message on pointer down ([rowDown]); the area around all the
/// rows notes every pointer down after it ([anyDown], listeners run deepest
/// first). The toolbar that a long press then raises asks [message]: it is the
/// row's only if no later touch landed elsewhere (a tool panel, the gap).
class MessageCopyTracker {
  TranscriptMessage? _message;
  int _rowPointer = -1;
  int _anyPointer = -2;

  void rowDown(TranscriptMessage message, int pointer) {
    _message = message;
    _rowPointer = pointer;
  }

  void anyDown(int pointer) => _anyPointer = pointer;

  /// The message the last touch was on, or null.
  TranscriptMessage? get message => _rowPointer == _anyPointer ? _message : null;
}

class _ContentScope extends InheritedWidget {
  const _ContentScope({required this.tracker, required super.child});

  final MessageCopyTracker tracker;

  @override
  bool updateShouldNotify(_ContentScope old) => tracker != old.tracker;
}

/// The transcript's `SelectionArea`, with `Copy message` and `Copy as Markdown`
/// added to its toolbar for the message the selection began in.
class ContentSelectionArea extends StatefulWidget {
  const ContentSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<ContentSelectionArea> createState() => _ContentSelectionAreaState();
}

class _ContentSelectionAreaState extends State<ContentSelectionArea> {
  final _tracker = MessageCopyTracker();

  Widget _menu(BuildContext context, SelectableRegionState region) {
    final message = _tracker.message;
    final items = [...region.contextMenuButtonItems];
    if (message != null && message.text.isNotEmpty) {
      void run(void Function(BuildContext) copy) {
        region
          ..hideToolbar()
          ..clearSelection();
        copy(region.context);
      }

      // Right after Copy: the toolbar shows two or three buttons and puts the
      // rest behind its overflow, and these are what a transcript needs most
      // (Share and Select all can wait there).
      final after = items.indexWhere((i) => i.type == ContextMenuButtonType.copy) + 1;
      items.insertAll(after, [
        ContextMenuButtonItem(label: 'Copy message', onPressed: () => run((c) => copyMessage(c, message))),
        if (messageHasMarkdown(message))
          ContextMenuButtonItem(label: 'Copy as Markdown', onPressed: () => run((c) => copyMessageMarkdown(c, message))),
      ]);
    }
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: region.contextMenuAnchors, buttonItems: items);
  }

  @override
  Widget build(BuildContext context) => _ContentScope(
    tracker: _tracker,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _tracker.anyDown(e.pointer),
      child: SelectionArea(contextMenuBuilder: _menu, child: widget.child),
    ),
  );
}

void copyMessage(BuildContext context, TranscriptMessage message) =>
    copyToClipboard(context, messagePlainText(message), 'Copied');

void copyMessageMarkdown(BuildContext context, TranscriptMessage message) =>
    copyToClipboard(context, messageMarkdown(message), 'Copied as Markdown');

/// The choice `Copy message` offers a screen reader: the text, or the Markdown
/// source for an answer.
Future<void> showMessageCopySheet(BuildContext context, TranscriptMessage message) => showActionSheet(
  context,
  title: 'Message',
  actions: [
    SheetAction(
      label: 'Copy text',
      icon: LucideIcons.copy,
      onTap: () {
        if (context.mounted) copyMessage(context, message);
      },
    ),
    if (messageHasMarkdown(message))
      SheetAction(
        label: 'Copy as Markdown',
        icon: LucideIcons.fileCode,
        onTap: () {
          if (context.mounted) copyMessageMarkdown(context, message);
        },
      ),
  ],
);

/// Wraps the rows of a settled message: notes the message on a touch (for the
/// selection toolbar) and gives a screen reader the `Copy message` action. No
/// effect without a [ContentSelectionArea] above, and none for a message with
/// no text.
class MessageCopyTarget extends StatelessWidget {
  const MessageCopyTarget({super.key, required this.message, required this.child});

  final TranscriptMessage message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ContentScope>();
    if (scope == null || message.text.isEmpty) return child;
    final tracker = scope.tracker;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => tracker.rowDown(message, e.pointer),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Copy message'): () => showMessageCopySheet(context, message),
        },
        child: child,
      ),
    );
  }
}
