import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/app_info.dart';
import '../../../data/models/release_history.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/markdown/markdown.dart';
import 'update_group.dart' show ClipCard;

/// Reads the notes bundled with the app (`assets/CHANGELOG.md`, the repository's own file).
typedef ChangelogLoader = Future<String> Function();

Future<String> _bundled() => rootBundle.loadString('assets/CHANGELOG.md');

/// Every release the installed version knows, newest first: its version, what it is about in a
/// line, and its date. A tap opens that release's notes in the same sheet shape as the update
/// sheet, tips and walkthrough poster included, so the person can learn what they missed.
///
/// Bundled with the app, so it opens at once, offline, with no request to anyone. It lists releases
/// up to the one installed; a newer one is the update sheet's. The poster of a walkthrough is the
/// one thing fetched, and only when that release's notes are opened (the card keeps its words if it
/// cannot load).
Future<void> openReleaseHistory(BuildContext context, {ChangelogLoader load = _bundled}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReleaseHistoryScreen(load: load)));

class ReleaseHistoryScreen extends StatefulWidget {
  const ReleaseHistoryScreen({super.key, this.load = _bundled});

  final ChangelogLoader load;

  @override
  State<ReleaseHistoryScreen> createState() => _ReleaseHistoryScreenState();
}

class _ReleaseHistoryScreenState extends State<ReleaseHistoryScreen> {
  List<ReleaseNotes>? _releases;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final releases = parseChangelog(await widget.load());
      if (!mounted) return;
      setState(() => _releases = releases);
    } on Object {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final releases = _releases;
    return Scaffold(
      backgroundColor: ds.bg,
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTopBar(title: 'What’s new', subtitle: 'Release notes up to $appVersion'),
            Expanded(
              child: _failed || (releases != null && releases.isEmpty)
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.gutter),
                      child: Text(
                        'The release notes couldn’t be read on this phone.',
                        style: Type.secondary.copyWith(color: ds.textSecondary),
                      ),
                    )
                  : releases == null
                  ? const SizedBox.shrink()
                  : CustomScrollView(
                      slivers: [
                        RowList(
                          rows: [
                            for (final r in releases)
                              EntityRow(
                                id: r.version,
                                title: r.version == appVersion ? '${r.version} · Installed' : r.version,
                                subtitle: r.headline.isEmpty ? 'No headline' : r.headline,
                                subtitleMaxLines: 3,
                                subtitle2: r.date.isEmpty ? null : r.date,
                                trailing: Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
                                onTap: () => unawaited(_openNotes(context, r)),
                              ),
                          ],
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openNotes(BuildContext context, ReleaseNotes release) =>
      showAppSheet<void>(context, builder: (context) => _NotesSheet(release: release));
}

const _inset = Gap.gutter - Gap.xs;

class _NotesSheet extends StatelessWidget {
  const _NotesSheet({required this.release});

  final ReleaseNotes release;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final clip = release.clip;
    final notes = clip == null ? release.notes : clip.without(release.notes);
    return SheetScaffold(
      kind: SheetKind.list,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(_inset, Gap.md, _inset, Gap.sm),
            child: Semantics(
              header: true,
              child: Text('What’s new in ${release.version}', style: Type.title.copyWith(color: ds.text)),
            ),
          ),
          if (clip != null) ClipCard(clip, version: release.version),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _inset),
            child: notes.isEmpty
                ? Text('No notes came with this release.', style: Type.secondary.copyWith(color: ds.textSecondary))
                : MdDocumentView(document: parseMd(notes, softBreaksAsNewlines: false)),
          ),
        ],
      ),
    );
  }
}
