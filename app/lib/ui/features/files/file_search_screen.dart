import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/models/remote_search.dart';
import '../../../data/services/remote_files.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'file_format.dart';
import 'file_row.dart';
import 'file_search_view_model.dart';
import 'file_thumb.dart';
import 'file_widgets.dart';
import 'in_front.dart';

/// Search below a folder: a field, three time chips and the matches as the
/// machine finds them, shallow ones first, as the same rows the browser has with
/// the folder each lives in on the second line.
///
/// A tap on a match is [onOpen] (the browser opens a file or enters a folder
/// exactly as it does for its own rows), and the search stays where it is
/// underneath. The search only runs while this screen is in front (see
/// [FileSearchViewModel.setActive]).
class FileSearchScreen extends StatefulWidget {
  const FileSearchScreen({
    super.key,
    required this.files,
    required this.root,
    required this.rootName,
    required this.onOpen,
    this.kind = FileSearchKind.any,
    this.hidden = false,
    this.maxResults = FileSearchSpec.defaultMaxResults,
    this.typingPause = Dwell.typingPause,
    this.thumbs,
    this.clock,
  });

  final RemoteFiles files;

  /// The folder searched, and its name for the title and the empty states.
  final String root;
  final String rootName;

  /// A match was tapped; [siblings] are all the matches (a photo pages through
  /// the pictures among them).
  final void Function(RemoteEntry entry, List<RemoteEntry> siblings) onOpen;

  /// Folders only, for a folder picker.
  final FileSearchKind kind;
  final bool hidden;
  final int maxResults;
  final Duration typingPause;
  final ThumbLoader? thumbs;

  /// What "now" is, for "3m ago" and "Today".
  final DateTime Function()? clock;

  @override
  State<FileSearchScreen> createState() => _FileSearchScreenState();
}

class _FileSearchScreenState extends State<FileSearchScreen> {
  late final FileSearchViewModel _vm = FileSearchViewModel(
    files: widget.files,
    root: widget.root,
    rootName: widget.rootName,
    kind: widget.kind,
    hidden: widget.hidden,
    maxResults: widget.maxResults,
    typingPause: widget.typingPause,
    clock: widget.clock,
  );
  late final _front = InFront(_vm.setActive);
  final _field = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The point of the screen is the field: the keyboard is up on arrival.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _front.attach(context);
  }

  @override
  void dispose() {
    _front.dispose();
    _vm.dispose();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final inset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: ds.bg,
      body: ListenableBuilder(
        listenable: _vm,
        builder: (context, _) {
          final now = _now();
          final results = _vm.results;
          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverLargeTitle.back(
                title: 'Search',
                subtitle: Text(
                  _subtitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.secondary.copyWith(color: ds.textSecondary),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
                  child: SearchField(
                    controller: _field,
                    focusNode: _focus,
                    hint: 'Name in ${widget.rootName}',
                    onChanged: _vm.setQuery,
                    onSubmitted: (_) => _vm.submit(),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _Windows(vm: _vm)),
              if (results.isNotEmpty)
                SliverList.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) => _Match(
                    entry: results[i],
                    files: widget.files,
                    now: now,
                    root: widget.root,
                    rootName: widget.rootName,
                    thumbs: widget.thumbs,
                    onTap: () {
                      Haptics.tick();
                      FocusManager.instance.primaryFocus?.unfocus();
                      widget.onOpen(results[i], results);
                    },
                  ),
                ),
              ..._status(context, results.isEmpty),
              SliverToBoxAdapter(child: SizedBox(height: Gap.xxl + inset)),
            ],
          );
        },
      ),
    );
  }

  String _subtitle() {
    final n = _vm.resultCount;
    return switch (_vm.phase) {
      SearchPhase.idle => 'in ${widget.rootName}',
      SearchPhase.searching => n == 0 ? 'Searching…' : '${groupDigits(n)} found so far',
      SearchPhase.done => n == 0 ? 'Nothing found' : '${groupDigits(n)} found',
      SearchPhase.failed => n == 0 ? 'Search stopped' : '${groupDigits(n)} found before it stopped',
    };
  }

  List<Widget> _status(BuildContext context, bool noMatches) {
    switch (_vm.phase) {
      case SearchPhase.idle:
        return [
          _filler(
            EmptyState(
              icon: LucideIcons.search,
              title: 'Search ${widget.rootName}',
              message: 'Type part of a name, or pick Last hour or Today to see what changed.',
            ),
          ),
        ];
      case SearchPhase.searching:
        return [
          SliverToBoxAdapter(
            child: LoadingRow(
              noMatches ? 'Searching ${widget.rootName}…' : 'Still searching…',
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: Gap.lg),
            ),
          ),
        ];
      case SearchPhase.failed:
        final error = _vm.error!;
        final panel = FileErrorPanel(error: error, name: widget.rootName, onRetry: _vm.retry);
        return [
          if (noMatches)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(left: Gap.gutter, top: Gap.sm, right: Gap.gutter),
                child: panel,
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, 0), child: panel),
            ),
        ];
      case SearchPhase.done:
        return [if (noMatches) _filler(_empty()) else SliverToBoxAdapter(child: _footer())];
    }
  }

  Widget _filler(Widget child) => SliverFillRemaining(hasScrollBody: false, child: child);

  /// Nothing matched. Said plainly, and when the machine stopped early, that
  /// the answer is not final.
  Widget _empty() {
    final text = _vm.query.trim();
    final where = widget.rootName;
    final String title;
    final String message;
    if (text.isNotEmpty) {
      title = 'Nothing named “$text”';
      message = switch (_vm.window) {
        SearchWindow.any => 'Nothing in $where or the folders inside it.',
        SearchWindow.hour => 'Nothing in $where changed in the last hour.',
        SearchWindow.today => 'Nothing in $where changed today.',
      };
    } else {
      title = _vm.window == SearchWindow.hour ? 'Nothing changed in the last hour' : 'Nothing changed today';
      message = 'Nothing in $where or the folders inside it.';
    }
    final stopped = _vm.truncated;
    return EmptyState(
      icon: LucideIcons.searchX,
      title: title,
      message: stopped
          ? 'It stopped after ${groupDigits(_vm.scanned)} items, so there may be more. Narrow the search.'
          : message,
      action: stopped
          ? AppButton(
              label: 'Narrow the search',
              kind: AppButtonKind.secondary,
              icon: LucideIcons.textCursorInput,
              onPressed: _focus.requestFocus,
            )
          : null,
    );
  }

  /// What was covered, and when it was not all of it: said once, under the matches.
  Widget _footer() {
    final ds = context.ds;
    final skipped = _vm.skippedFolders;
    final looked = 'Searched ${groupDigits(_vm.scanned)} ${plural(_vm.scanned, 'item')}';
    final cant = skipped > 0 ? ' · ${countOf(skipped, 'folder')} couldn’t be read' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$looked$cant', style: Type.secondary.copyWith(color: ds.textMuted)),
          if (_vm.truncated) ...[
            Text(
              'There are more than ${groupDigits(_vm.resultCount)}. Showing the first ones.',
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            TextAction(label: 'Narrow the search', onTap: _focus.requestFocus),
          ],
        ],
      ),
    );
  }
}

/// Any time, Last hour, Today: one is always chosen. The two time chips work
/// with no text at all ("what changed lately, below here").
class _Windows extends StatelessWidget {
  const _Windows({required this.vm});

  final FileSearchViewModel vm;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppChip.height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
        children: [
          for (final w in SearchWindow.values) ...[
            if (w != SearchWindow.any) const SizedBox(width: Gap.sm),
            AppChip(
              label: w.label,
              icon: switch (w) {
                SearchWindow.any => null,
                SearchWindow.hour => LucideIcons.clock,
                SearchWindow.today => LucideIcons.calendar,
              },
              selected: vm.window == w,
              onTap: () => vm.setWindow(w),
            ),
          ],
        ],
      ),
    );
  }
}

/// One match: the browser's row with the folder it is in under the name and,
/// for a file, how long ago it changed at the end.
class _Match extends StatelessWidget {
  const _Match({
    required this.entry,
    required this.files,
    required this.now,
    required this.root,
    required this.rootName,
    required this.thumbs,
    required this.onTap,
  });

  final RemoteEntry entry;
  final RemoteFiles files;
  final DateTime now;
  final String root;
  final String rootName;
  final ThumbLoader? thumbs;
  final VoidCallback onTap;

  /// The folder of [e] below [root]: its path from the searched folder, or the
  /// searched folder's own name for a match directly in it.
  static String folderOf(RemoteEntry e, String root, String rootName) {
    final parent = RemotePath.parent(e.path);
    if (parent == root) return rootName;
    final prefix = root.endsWith('/') ? root : '$root/';
    return parent.startsWith(prefix) ? parent.substring(prefix.length) : parent;
  }

  @override
  Widget build(BuildContext context) {
    final when = entry.modified;
    return FileRow(
      entry: entry,
      files: files,
      now: now,
      thumbs: thumbs,
      detail: folderOf(entry, root, rootName),
      detailSuffix: when == null ? null : formatAgo(when, now),
      onTap: onTap,
    );
  }
}
