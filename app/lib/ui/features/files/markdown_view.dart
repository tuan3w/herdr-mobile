import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../core/controls.dart';
import '../../core/markdown/markdown.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../pane/link_sheet.dart';
import 'files_navigation.dart';
import 'text_document.dart';

/// A text this long is parsed off the UI isolate (a 200 KB message parses in
/// about 70 ms on a desktop).
const _parseOffThreadFrom = 50000;

/// Rendered Markdown in the app's type: the shared Markdown renderer
/// (`ui/core/markdown/`) over a lazy list of blocks, with CommonMark's line
/// breaks (a single newline is a space: a README is wrapped by its author).
///
/// A link shows the whole address in the link sheet first; a path (in text, in
/// code or as a relative link) opens in the file viewer, found from
/// [directory] when it is relative, on [machine]; without a machine paths are
/// plain text.
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.document, this.directory, this.machine});

  final TextDocument document;

  /// The folder of the file, for relative paths in the text.
  final String? directory;

  /// The machine the file lives on; what a tapped path opens on.
  final MachineConnection? machine;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  MdDocument _parsed = MdDocument.empty;
  int _parsedBytes = -1;
  Object? _parsedFor;
  int _generation = 0;
  bool _parsing = false;
  final _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    // More of the file arrived: parse again (the text is only ever appended).
    if (widget.document.bytes != _parsedBytes || !identical(widget.document, _parsedFor)) _parse();
  }

  void _parse() {
    final doc = widget.document;
    _parsedBytes = doc.bytes;
    _parsedFor = doc;
    final text = doc.text;
    final generation = ++_generation;
    if (text.length < _parseOffThreadFrom) {
      _parsing = false;
      _parsed = parseMd(text, softBreaksAsNewlines: false);
      _expanded.clear();
      return;
    }
    _parsing = true;
    unawaited(
      Isolate.run(() => parseMd(text, softBreaksAsNewlines: false)).then((result) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _parsed = result;
          _parsing = false;
          _expanded.clear();
        });
      }),
    );
  }

  void _link(BuildContext context, String url) => unawaited(showLinkSheet(context, url));

  void _path(BuildContext context, String path, int? line) {
    final machine = widget.machine!;
    Haptics.tick();
    unawaited(openRemoteFile(context, machine, path, cwd: widget.directory, line: line));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + Gap.xl;
    final blocks = _parsed.blocks;
    if (_parsing && blocks.isEmpty) {
      return const Center(child: BusySpinner(size: 20));
    }
    return MdActions(
      onLink: _link,
      onPath: widget.machine == null ? null : _path,
      child: SelectionArea(
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, bottom),
          itemCount: blocks.length,
          itemBuilder: (context, i) => Padding(
            padding: EdgeInsets.only(top: mdBlockGap(i == 0 ? null : blocks[i - 1], blocks[i])),
            child: MdBlockView(
              block: blocks[i],
              expanded: _expanded.contains(i),
              onToggleExpanded: () => setState(() => _expanded.contains(i) ? _expanded.remove(i) : _expanded.add(i)),
            ),
          ),
        ),
      ),
    );
  }
}
