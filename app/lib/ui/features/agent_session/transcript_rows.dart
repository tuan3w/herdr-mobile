import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../core/controls.dart';
import '../../core/markdown/markdown.dart';
import '../../core/theme.dart';
import 'code_panel.dart';
import 'content_blocks.dart';
import 'content_copy.dart';
import 'visible_text.dart';

/// Called with the row key each time a transcript row's `build` runs. Tests
/// use it to prove a streaming answer rebuilds only the rows that changed.
@visibleForTesting
ValueSetter<String>? debugRowBuilt;

/// Reports a row build to [debugRowBuilt].
void notifyRowBuilt(String key) => debugRowBuilt?.call(key);

/// A toggle the owner keeps (expanded rows, "Show all"), so it survives the
/// row scrolling out of the list and back.
typedef RowToggle = void Function(String id);

/// The key of the "Show all" flag of a row's panels.
String allKey(String rowKey) => '$rowKey:all';

Widget _gap(double gap, Widget child) => gap == 0 ? child : Padding(padding: EdgeInsets.only(top: gap), child: child);

/// What the person said: a quiet filled block. A long message shows its first
/// lines with a "Show more".
class UserRow extends StatelessWidget {
  const UserRow({
    super.key,
    required this.rowKey,
    required this.message,
    required this.gap,
    required this.open,
    required this.onToggle,
    this.all = false,
  });

  final String rowKey;
  final TranscriptMessage message;
  final double gap;
  final bool open;
  final RowToggle onToggle;

  /// The row's "Show all" flag (an embedded text in the message), kept by the owner.
  final bool all;

  static const _collapsedLines = 8;
  static const _collapsedChars = 20000;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final full = message.text;
    final collapsible = full.length > 600 || '\n'.allMatches(full).length >= _collapsedLines;
    final text = !collapsible || open
        ? (full.length > panelTextLimit ? full.substring(0, panelTextLimit) : full)
        : full.substring(0, full.length > _collapsedChars ? _collapsedChars : full.length);
    return _gap(
      gap,
      MessageCopyTarget(
        message: message,
        child: DecoratedBox(
          decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.panel)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm + 2, Gap.md, Gap.sm + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (text.isNotEmpty)
                  Text(
                    text,
                    maxLines: collapsible && !open ? _collapsedLines : null,
                    // An ellipsis without a line cap would cut the text to one line.
                    overflow: collapsible && !open ? TextOverflow.ellipsis : TextOverflow.clip,
                    style: Type.body.copyWith(fontSize: 14.5, color: ds.text),
                  ),
                for (final block in message.blocks)
                  if (block is! TextBlock) ...[
                    const SizedBox(height: Gap.xs),
                    ContentBlockView(block: block, expanded: all, onToggle: () => onToggle(allKey(rowKey))),
                  ],
                if (collapsible)
                  PressBuilder(
                    onTap: () => onToggle(rowKey),
                    builder: (context, pressed) => ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: kMinTap),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          open ? 'Show less' : 'Show more',
                          style: Type.label.copyWith(color: ds.accentText, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One block of the agent's answer, as Markdown ([MdBlockView]). Whether a
/// long code block or table is open lives with the owner ([expanded]), so it
/// survives the row scrolling out of the list and back.
class AgentTextRow extends StatelessWidget {
  const AgentTextRow({
    super.key,
    required this.rowKey,
    required this.block,
    required this.gap,
    required this.expanded,
    required this.onToggle,
    this.tail = false,
    this.quiet = false,
    this.message,
  });

  final String rowKey;
  final MdBlock block;
  final double gap;
  final bool expanded;
  final RowToggle onToggle;

  /// The open end of a message that is still arriving.
  final bool tail;

  /// Narration inside the work log.
  final bool quiet;

  /// The settled message this block belongs to, for copying it. Null for the
  /// live row: a message that is still arriving is not copied.
  final TranscriptMessage? message;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final Widget markdown = MdToneScope(
      // Narration of the work log: the answer's size and shape in the
      // supporting colour, so a message that was the answer and becomes
      // narration (a call starts after it) changes colour and nothing else.
      tone: quiet ? MdTone.quote : MdTone.reading,
      child: MdBlockView(
        block: block,
        tail: tail,
        expanded: expanded,
        onToggleExpanded: () => onToggle(allKey(rowKey)),
      ),
    );
    final copy = message;
    return _gap(gap, copy == null ? markdown : MessageCopyTarget(message: copy, child: markdown));
  }
}

/// A piece of an agent message that is not text (a picture, a link to a file,
/// an embedded resource, something this app does not know): see
/// [ContentBlockView]. [expanded] is the row's "Show all" flag.
class ContentRow extends StatelessWidget {
  const ContentRow({
    super.key,
    required this.rowKey,
    required this.block,
    required this.gap,
    this.expanded = false,
    this.onToggle,
  });

  final String rowKey;
  final ContentBlock block;
  final double gap;
  final bool expanded;
  final RowToggle? onToggle;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final toggle = onToggle;
    return _gap(
      gap,
      ContentBlockView(block: block, expanded: expanded, onToggle: toggle == null ? null : () => toggle(allKey(rowKey))),
    );
  }
}

/// What a [TranscriptStop] says, in plain words.
String stopNoteText(StopReason reason) => switch (reason) {
  StopReason.refusal => 'The agent stopped: it refused to continue.',
  StopReason.maxTokens => 'The agent stopped: it hit the length limit.',
  StopReason.maxTurnRequests => 'The agent stopped: it reached its limit of steps for one turn.',
  _ => 'The agent stopped.',
};

/// Why a turn ended early (a refusal or a limit), as one quiet line. The app
/// wrote it; the agent did not say it.
class StopNoteRow extends StatelessWidget {
  const StopNoteRow({super.key, required this.rowKey, required this.reason, required this.gap});

  final String rowKey;
  final StopReason reason;
  final double gap;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    return _gap(
      gap,
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.circleAlert, size: 15, color: ds.textTertiary),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(stopNoteText(reason), style: Type.secondary.copyWith(color: ds.textSecondary))),
        ],
      ),
    );
  }
}

/// Something that changed in the session and that the agent did not say (it
/// switched the mode by itself), as one quiet line. The app wrote it.
class NoteRow extends StatelessWidget {
  const NoteRow({super.key, required this.rowKey, required this.text, required this.gap});

  final String rowKey;
  final String text;
  final double gap;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    return _gap(
      gap,
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.info, size: 15, color: ds.textTertiary),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(visibleText(text), style: Type.secondary.copyWith(color: ds.textSecondary))),
        ],
      ),
    );
  }
}
