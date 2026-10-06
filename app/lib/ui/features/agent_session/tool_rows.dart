import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/acp/turns/turns.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../files/file_widgets.dart' show copyToClipboard;
import 'code_panel.dart';
import 'content_blocks.dart';
import 'content_locations.dart';
import 'diff_lines.dart';
import 'transcript_rows.dart';
import 'visible_text.dart';
import 'log_atoms.dart';

/// Lines an opened call shows of the text it returned that is not command
/// output (a file it read, its input, MCP progress) before "Show all": the
/// file is behind its name and a tap on the path opens the file viewer, so a
/// 40-line wall of it was mostly scrolled past. The same as a collapsed
/// message (`transcript_rows.dart`).
const toolTextLines = 8;

/// The last lines of command output an opened call shows before "Show all":
/// the outcome (test summary, error) is at the end, and is read.
const commandOutputLines = 40;

/// The Lucide icon that says what a tool call does.
IconData toolIcon(ToolKind kind) => switch (kind) {
  ToolKind.read => LucideIcons.fileText,
  ToolKind.edit => LucideIcons.filePen,
  ToolKind.delete => LucideIcons.trash2,
  ToolKind.move => LucideIcons.arrowRightLeft,
  ToolKind.search => LucideIcons.search,
  ToolKind.execute => LucideIcons.terminal,
  ToolKind.think => LucideIcons.brain,
  ToolKind.fetch => LucideIcons.globe,
  ToolKind.switchMode => LucideIcons.slidersHorizontal,
  ToolKind.other => LucideIcons.wrench,
};

String toolKindLabel(ToolKind kind) => switch (kind) {
  ToolKind.read => 'Read',
  ToolKind.edit => 'Edit',
  ToolKind.delete => 'Delete',
  ToolKind.move => 'Move',
  ToolKind.search => 'Search',
  ToolKind.execute => 'Run',
  ToolKind.think => 'Think',
  ToolKind.fetch => 'Fetch',
  ToolKind.switchMode => 'Switch mode',
  ToolKind.other => 'Tool call',
};

String toolStatusWord(ToolStatus status) => switch (status) {
  ToolStatus.pending => 'pending',
  ToolStatus.inProgress => 'running',
  ToolStatus.completed => 'done',
  ToolStatus.failed => 'failed',
  ToolStatus.cancelled => 'cancelled',
};

/// The words a tool call goes by: its title, else its name, else its kind.
String toolTitle(ToolCall call) {
  if (call.title.trim().isNotEmpty) return visibleText(call.title.trim());
  final name = call.name;
  if (name != null && name.isNotEmpty) return visibleText(name);
  return toolKindLabel(call.kind);
}

/// The status of a tool call as a shape: empty ring (waiting), half ring
/// (running), check (done), cross (failed), slashed circle (cancelled).
class ToolStatusGlyph extends StatelessWidget {
  const ToolStatusGlyph({super.key, required this.status, this.size = 16});

  final ToolStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ExcludeSemantics(
      child: switch (status) {
        ToolStatus.pending => StatusGlyph(status: AgentStatus.idle, size: size),
        ToolStatus.inProgress => StatusGlyph(status: AgentStatus.working, size: size),
        ToolStatus.completed => StatusGlyph(status: AgentStatus.done, size: size),
        ToolStatus.failed => Icon(LucideIcons.circleX, size: size, color: ds.danger),
        ToolStatus.cancelled => Icon(LucideIcons.ban, size: size, color: ds.textTertiary),
      },
    );
  }
}

/// One tool call as a quiet line: the icon of its kind, ONE line that says
/// what it did (`toolSummary`: a file, `name +3 −1`, the command, a pattern
/// and its hits, a host) and, only when the call did not succeed, its state as
/// a shape. No chevron: the row opens on a tap with a pressed fill, and its
/// input, output and changes are behind that tap. A failed command also says
/// why, in a second line: its exit code and the last line it printed.
class ToolRow extends StatelessWidget {
  const ToolRow({
    super.key,
    required this.rowKey,
    required this.item,
    required this.gap,
    required this.open,
    required this.all,
    required this.onToggle,
    this.nested = false,
  });

  final String rowKey;
  final TranscriptTool item;
  final double gap;
  final bool open;

  /// "Show all" is on for this call's panels.
  final bool all;
  final RowToggle onToggle;

  /// Inside an expanded group of reads: indented.
  final bool nested;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final call = item.call;
    final summary = toolSummary(call);
    final failed = toolFailed(call);
    final state = failed ? ToolStatus.failed : call.status;
    final title = toolTitle(call);
    final stats = summary.kind == ToolKind.edit && (summary.added ?? 0) + (summary.removed ?? 0) > 0;
    return Padding(
      padding: EdgeInsets.only(top: gap, left: nested ? Gap.xl : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: PressBuilder(
              onTap: () => onToggle(rowKey),
              semanticLabel: _toolLabel(summary, state, call.detailTrimmed),
              builder: (context, pressed) => AnimatedContainer(
                duration: Motion.pressing(pressed),
                curve: Motion.easeOut,
                constraints: const BoxConstraints(minHeight: kMinTap),
                padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 6),
                decoration: BoxDecoration(
                  color: pressed ? ds.fill : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.row),
                ),
                child: Row(
                  children: [
                    Icon(toolIcon(call.kind), size: 16, color: ds.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(child: _ToolLine(summary: summary, failed: failed, trimmed: call.detailTrimmed)),
                    if (stats) ...[
                      const SizedBox(width: Gap.sm),
                      DiffStats(added: summary.added ?? 0, removed: summary.removed ?? 0),
                    ],
                    // Success is the default and says nothing; a call that is
                    // waiting, running, failed or cancelled shows its shape.
                    if (state != ToolStatus.completed) ...[
                      const SizedBox(width: Gap.sm),
                      ToolStatusGlyph(status: state),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (open)
            // The body hangs off a fold rail: the indent under the icon, the
            // full height of the body, folds the call from wherever the reader
            // is, so a long output never has to be scrolled back up to close.
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, 0, 0, Gap.sm),
                  child: _ToolBody(call: call, all: all, onToggleAll: () => onToggle(allKey(rowKey)), title: title),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: Gap.sm,
                  width: Gap.xl,
                  child: FoldRail(onFold: () => foldKeepingInView(context, () => onToggle(rowKey))),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Folds an open row from inside its body: [fold] closes it, then, when its
/// header ended up above the screen, the list brings the header back to the
/// top, so the reader lands on the call they just closed instead of somewhere
/// further down.
void foldKeepingInView(BuildContext context, VoidCallback fold) {
  fold();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    Scrollable.ensureVisible(
      context,
      duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
      curve: Motion.easeOut,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  });
}

/// The indent an open row's body hangs from: a faint line under the row's
/// icon that folds the row on a tap anywhere along it. 24 dp wide (the indent
/// that was already there, so no output loses width) instead of [kMinTap]: it
/// is as tall as the body, so it is aimed at along one axis only, and the 44 dp
/// header still folds the row too. Left out of semantics: the header is the
/// one toggle a screen reader needs.
class FoldRail extends StatelessWidget {
  const FoldRail({super.key, required this.onFold});

  final VoidCallback onFold;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ExcludeSemantics(
      child: PressBuilder(
        onTap: onFold,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          decoration: BoxDecoration(
            color: pressed ? ds.fill : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          alignment: Alignment.topCenter,
          child: AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            width: pressed ? 2 : 1.5,
            margin: const EdgeInsets.only(top: Gap.xs),
            color: pressed ? ds.textMuted : ds.hairline,
          ),
        ),
      ),
    );
  }
}

String _toolLabel(ToolSummary summary, ToolStatus state, bool trimmed) {
  final line = '${toolKindLabel(summary.kind)} ${visibleText(summary.plain)}';
  final stated = state == ToolStatus.completed ? line : '$line, ${toolStatusWord(state)}';
  return trimmed ? '$stated, details trimmed' : stated;
}

/// The words of a tool row, one line (two for a failed command).
class _ToolLine extends StatelessWidget {
  const _ToolLine({required this.summary, required this.failed, required this.trimmed});

  final ToolSummary summary;
  final bool failed;

  /// The host cut the call's detail (`ToolCall.detailTrimmed`).
  final bool trimmed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final main = Type.secondary.copyWith(color: failed ? ds.text : ds.textSecondary, fontWeight: FontWeight.w500);
    final muted = Type.secondary.copyWith(color: ds.textMuted);
    final mono = TextStyle(
      fontFamily: monoFamily,
      fontSize: 12.5,
      height: 1.35,
      color: failed ? ds.text : ds.textSecondary,
    );
    final text = visibleText(summary.text);
    final hint = summary.hint == null ? null : visibleText(summary.hint!);
    final span = switch (summary.kind) {
      ToolKind.execute => TextSpan(
        text: text,
        style: mono,
        children: [
          if (summary.extraLines > 0) TextSpan(text: '  +${summary.extraLines} lines', style: muted),
          if (trimmed) TextSpan(text: '  Details trimmed', style: muted),
        ],
      ),
      ToolKind.search => TextSpan(
        text: text,
        style: main,
        children: [
          if (summary.hits != null) TextSpan(text: '  ${_hitsWords(summary.hits!)}', style: muted),
          if (trimmed) TextSpan(text: '  Details trimmed', style: muted),
        ],
      ),
      _ => TextSpan(
        text: text,
        style: main,
        children: [
          if (hint != null) TextSpan(text: '  $hint', style: muted),
          if (summary.kind == ToolKind.edit && summary.fileCount > 1)
            TextSpan(text: '  +${summary.fileCount - 1} more', style: muted),
          if (trimmed) TextSpan(text: '  Details trimmed', style: muted),
        ],
      ),
    };
    final line = Text.rich(span, maxLines: 1, overflow: TextOverflow.ellipsis);
    final code = summary.signal != null
        ? 'signal ${visibleText(summary.signal!)}'
        : (summary.exitCode != null ? 'exit ${summary.exitCode}' : null);
    final why = summary.failure == null ? null : visibleText(summary.failure!);
    if (!failed || summary.kind != ToolKind.execute || (code == null && why == null)) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        line,
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(
            children: [
              if (code != null)
                TextSpan(
                  text: code,
                  style: Type.caption.copyWith(color: ds.dangerText, fontWeight: FontWeight.w600),
                ),
              if (code != null && why != null) const TextSpan(text: '  '),
              if (why != null)
                TextSpan(
                  text: why,
                  style: TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.35, color: ds.dangerText),
                ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

String _hitsWords(int hits) => hits == 0 ? 'no matches' : (hits == 1 ? '1 match' : '$hits matches');

// ---------------------------------------------------------------------------
// the expanded body

sealed class _Part {
  const _Part();
}

class _CommandPart extends _Part {
  const _CommandPart(this.command);
  final String command;
}

class _TextPart extends _Part {
  const _TextPart(this.lines, {required this.label, this.fromEnd = false});
  final List<CodeLine> lines;
  final String? label;

  /// The panel keeps the last lines (command output) instead of the first.
  final bool fromEnd;
}

class _DiffPart extends _Part {
  _DiffPart(this.path, this.lines);
  final String path;
  final List<DiffLine> lines;

  /// The lines coloured for one brightness, kept so a row scrolled back into
  /// view does not walk a long diff again.
  (Brightness, List<CodeLine>)? coloured;
}

class _BlockPart extends _Part {
  const _BlockPart(this.block);
  final ContentBlock block;
}

class _NotePart extends _Part {
  const _NotePart(this.text);
  final String text;
}

final _parts = Expando<List<_Part>>('tool parts');
final _diffParts = Expando<_DiffPart>('diff parts');

_DiffPart _diffPart(ToolDiff diff) => _diffParts[diff] ??= _DiffPart(diff.path, diffLines(diff.oldText, diff.newText));

/// The command of an `execute` call: `rawInput.command` when it is a string.
String? toolCommand(ToolCall call) {
  final input = call.rawInput;
  if (input is Map && input['command'] is String) {
    final command = input['command'] as String;
    if (command.trim().isNotEmpty) return command;
  }
  return null;
}

/// A short, single rendering of arbitrary JSON: strings as they are, other
/// values as indented JSON, cut at [max] characters.
String compactJson(Object? value, {int max = 20000}) {
  if (value == null) return '';
  if (value is String) return value.length <= max ? value : value.substring(0, max);
  String text;
  try {
    text = const JsonEncoder.withIndent('  ').convert(value);
  } on Object {
    text = value.toString();
  }
  return text.length <= max ? text : '${text.substring(0, max)}\n…';
}

/// "Exited with code 1." / "Stopped by signal SIGTERM." for a command that
/// did not succeed.
String exitWords(ToolOutput output) {
  final signal = output.signal;
  if (signal != null && signal.isNotEmpty) return 'Stopped by signal ${visibleText(signal)}.';
  return 'Exited with code ${output.exitCode}.';
}

List<_Part> _partsOf(ToolCall call) {
  final cached = _parts[call];
  if (cached != null) return cached;
  final out = <_Part>[];
  final tail = call.kind == ToolKind.execute;
  final command = toolCommand(call);
  if (command != null) out.add(_CommandPart(command));

  StringBuffer? run;
  void flush() {
    final text = run?.toString();
    run = null;
    if (text != null) out.add(_TextPart(textLines(text, fromEnd: tail), label: tail ? 'Output' : null, fromEnd: tail));
  }

  // What the command printed, from `_meta` (codex-acp, pi-acp): its output,
  // the progress lines of an MCP call, and how it ended on failure.
  final printed = call.output;
  void addPrinted(ToolOutput o) {
    if (o.text.isNotEmpty) {
      final lines = textLines(terminalText(o.text), fromEnd: true);
      out.add(
        _TextPart([if (o.cutChars > 0) CodeLine('… ${o.cutChars} characters not shown'), ...lines], label: 'Output', fromEnd: true),
      );
    }
    if (o.progress.isNotEmpty) out.add(_TextPart(textLines(terminalText(o.progress)), label: 'Progress'));
    if (o.failed) {
      out.add(_NotePart(exitWords(o)));
    } else if (o.text.isEmpty && o.progress.isEmpty && o.exited) {
      out.add(const _NotePart('No output.'));
    }
  }

  var content = false;
  var printedShown = false;
  for (final c in call.content) {
    switch (c) {
      case ToolContentBlock(block: TextBlock(:final text)):
        content = true;
        final buffer = run ??= StringBuffer();
        if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) buffer.write('\n');
        buffer.write(text);
      case ToolContentBlock(:final block):
        flush();
        content = true;
        out.add(_BlockPart(block));
      case ToolDiff():
        flush();
        content = true;
        out.add(_diffPart(c));
      case ToolTerminal():
        flush();
        content = true;
        if (printed != null) {
          if (!printedShown) addPrinted(printed);
          printedShown = true;
        } else {
          // Nothing arrived in `_meta`: an agent that really keeps the output
          // in a terminal (`terminal/create`), or one still starting.
          out.add(
            _NotePart(call.status.isFinished ? 'The output is in a terminal on the host.' : 'Waiting for output…'),
          );
        }
      case UnknownToolContent(:final type):
        flush();
        out.add(_NotePart('Content this app can’t show${type.isEmpty ? '' : ' ($type)'}.'));
    }
  }
  flush();
  if (printed != null && !printedShown) addPrinted(printed);
  if (!content) {
    final output = call.rawOutput;
    if (output != null) {
      final text = compactJson(output);
      if (text.isNotEmpty) out.add(_TextPart(textLines(text, fromEnd: tail), label: 'Output', fromEnd: tail));
    } else if (command == null && call.rawInput != null) {
      final text = compactJson(call.rawInput);
      if (text.isNotEmpty) out.add(_TextPart(textLines(text), label: 'Input'));
    }
  }
  // The host cut the output (and the rest of the heavy detail) of an old
  // call to keep its log small: say so where the output would be.
  if (call.detailTrimmed) out.add(const _NotePart('Output trimmed'));
  return _parts[call] = out;
}

class _ToolBody extends StatelessWidget {
  const _ToolBody({required this.call, required this.all, required this.onToggleAll, required this.title});

  final ToolCall call;
  final bool all;
  final VoidCallback onToggleAll;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final term = context.terminal;
    final parts = _partsOf(call);

    Widget panel(List<CodeLine> lines, {bool fromEnd = false, int cap = 40, String? copyText, String copyLabel = 'Copy output'}) =>
        CodePanel(
          lines: lines,
          background: term.background,
          foreground: term.foreground,
          border: term.border,
          all: all,
          fromEnd: fromEnd,
          cap: cap,
          onToggleAll: onToggleAll,
          onCopy: () => copyToClipboard(context, copyText ?? [for (final l in lines) l.text].join('\n'), 'Copied'),
          copyLabel: copyLabel,
        );

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Text(text, style: Type.caption.copyWith(color: ds.textMuted)),
    );

    final children = <Widget>[
      if (title.length > 60 && parts.every((p) => p is! _CommandPart))
        SelectableText(title, style: Type.secondary.copyWith(color: ds.textSecondary)),
      if (call.locations.isNotEmpty) ToolLocationRows(locations: call.locations),
      for (final part in parts)
        switch (part) {
          _CommandPart() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label('Command'),
              panel(textLines('\$ ${visibleText(part.command)}'), cap: 12, copyText: part.command, copyLabel: 'Copy command'),
            ],
          ),
          _TextPart() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (part.label != null) label(part.label!),
              panel(part.lines, fromEnd: part.fromEnd, cap: part.fromEnd ? commandOutputLines : toolTextLines),
            ],
          ),
          _DiffPart() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label(visibleText(part.path)),
              panel(_colourDiff(part, term), cap: 60, copyLabel: 'Copy diff'),
            ],
          ),
          _BlockPart() => ContentBlockView(block: part.block, expanded: all, onToggle: onToggleAll),
          _NotePart() => Text(part.text, style: Type.secondary.copyWith(color: ds.textMuted)),
        },
      if (parts.isEmpty && call.locations.isEmpty)
        Text(
          call.status.isFinished ? 'No output.' : 'Waiting for output…',
          style: Type.secondary.copyWith(color: ds.textMuted),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0) const SizedBox(height: Gap.sm),
          c,
        ],
      ],
    );
  }
}

/// A diff coloured in the terminal palette of the theme: added lines green,
/// removed red (text and a faint band), the left-out runs dim.
List<CodeLine> _colourDiff(_DiffPart part, TerminalPalette term) {
  final brightness = term.isDark ? Brightness.dark : Brightness.light;
  final have = part.coloured;
  if (have != null && have.$1 == brightness) return have.$2;
  final add = term.ansi[2];
  final del = term.ansi[1];
  final lines = [
    for (final l in part.lines)
      switch (l.kind) {
        DiffKind.add => CodeLine('+ ${clipLine(l.text)}', color: add, background: add.withValues(alpha: 0.14)),
        DiffKind.del => CodeLine('- ${clipLine(l.text)}', color: del, background: del.withValues(alpha: 0.14)),
        DiffKind.same => CodeLine('  ${clipLine(l.text)}'),
        DiffKind.gap => CodeLine('… ${l.text}', color: term.dim),
      },
  ];
  part.coloured = (brightness, lines);
  return lines;
}

/// A diff the way a tool call shows it: the path, then the lines coloured in
/// the terminal palette. The Changed card opens the same panel.
class DiffPanel extends StatelessWidget {
  const DiffPanel({super.key, required this.diff, required this.all, required this.onToggleAll});

  final ToolDiff diff;

  /// "Show all" is on.
  final bool all;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final term = context.terminal;
    final part = _diffPart(diff);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Text(visibleText(part.path), style: Type.caption.copyWith(color: ds.textMuted)),
        ),
        CodePanel(
          lines: _colourDiff(part, term),
          background: term.background,
          foreground: term.foreground,
          border: term.border,
          all: all,
          fromEnd: false,
          cap: 60,
          onToggleAll: onToggleAll,
          onCopy: () => copyToClipboard(context, [for (final l in _colourDiff(part, term)) l.text].join('\n'), 'Copied'),
          copyLabel: 'Copy diff',
        ),
      ],
    );
  }
}
