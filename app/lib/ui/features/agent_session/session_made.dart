import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/background/background_work.dart' show BackgroundTask;
import '../../../data/acp/session_made.dart';
import '../../../data/models/remote_file.dart';
import '../../../data/models/web_bridge.dart' show sensitiveServiceOf;
import '../../../data/repositories/agent_session.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../../data/words/elapsed.dart';
import '../../../data/words/plural.dart';
import '../files/files_navigation.dart' show machineSupportsFiles, openRemoteFile;
import '../files/photo_files.dart' show remotePhotoItem;
import '../files/photo_grid.dart' show PhotoThumbFace;
import '../files/photo_thumbs.dart' show PhotoThumbs;
import '../photos/photo_item.dart' show PhotoItem;
import '../photos/photo_viewer.dart' show openPhotoViewer;
import '../web/web_preview_screen.dart';
import 'session_select.dart';
import '../../render/visible_text.dart';

/// What the sheet and the chip read from a session: the servers and pages, the
/// background tasks that say whether a server still runs, and whether anything
/// here may be called live (a saved copy or a link that is down knows nothing
/// of what runs now).
typedef _Snap = (List<MadeAsset>, List<BackgroundTask>, bool, MadeReach, MadeHistory?);

_Snap _snap(AgentSessionView s) => (
  madeAssetsOf(s.state.items, cwd: s.cwd, history: s.madeHistory),
  s.backgroundWork.tasks,
  s.link == AgentLink.live && s.cachedAsOf == null,
  s.madeReach,
  s.madeHistory,
);

bool _same(_Snap a, _Snap b) =>
    sameMadeAssets(a.$1, b.$1) && identical(a.$2, b.$2) && a.$3 == b.$3 && a.$4 == b.$4 && identical(a.$5, b.$5);

/// The apps, pages, pictures and documents a session made, newest first, one tap
/// from the session bar. Each row opens over the sheet, which stays under it:
/// Back returns to the list, so the person can look at the next one (an app or
/// page as a page in herdr, `WebPreviewScreen`: an app through the SSH
/// connection, a page from its folder on the machine; a picture in the photo
/// viewer, which swipes to the other pictures; a document in the file viewer).
///
/// [opener] is the screen the sheet was opened from: a viewer is only pushed
/// while it is still there.
Future<void> showSessionMade(BuildContext opener, AgentSessionView session) => showAppSheet<void>(
  opener,
  builder: (ctx) => SessionMadeSheet(session: session, opener: opener),
);

/// The tab each session was last left on, so the sheet opens where the person
/// was. Only the choice is kept (not what was on the tab): a kind that is no
/// longer there falls back to the newest one.
final _lastTab = <String, MadeKind>{};

/// The kinds that get a tab, in the order they are laid out.
const _tabKinds = [MadeKind.server, MadeKind.page, MadeKind.picture, MadeKind.doc];

/// Rows a list shows before `N more`, and tiles a grid does: what is BUILT, not
/// what is found.
const _listStep = 60;
const _gridStep = 24;

/// Said once over a grid of pictures (and under each row) on a machine that
/// cannot list files.
const _noFiles = 'Files are not available on this machine';

class SessionMadeSheet extends StatefulWidget {
  const SessionMadeSheet({super.key, required this.session, required this.opener});

  final AgentSessionView session;
  final BuildContext opener;

  @override
  State<SessionMadeSheet> createState() => _SessionMadeSheetState();
}

class _SessionMadeSheetState extends State<SessionMadeSheet> {
  /// The rows as the sheet found them, in that order, across every kind and
  /// tab. Nothing moves under a thumb while the sheet is open (AGENTS.md
  /// principle 3): a bottom sheet grows upward, so a row added anywhere shifts
  /// the ones beside it. A link that arrives meanwhile shows on the chip
  /// behind the sheet and in the list the next time it opens; the rows that
  /// are here keep their place and keep their state (a server stops being
  /// Running, a path is updated). Switching tabs only shows another part of
  /// this one order.
  List<String>? _order;

  /// The tab the person chose in this sheet, or the one they left last time.
  late MadeKind? _picked = _lastTab[widget.session.key];

  /// How many times `N more` was tapped, per list.
  final _more = <MadeKind, int>{};

  late final _entries = _EntryLoader(widget.session);

  /// The history the order was made from: when the read of the earlier part of
  /// the log lands, the rows it found join the list (the person asked for them
  /// by opening the sheet, and a line says it is reading).
  MadeHistory? _orderHistory;

  /// What the last build showed, in the stable order: what a tapped picture
  /// pages through.
  List<MadeAsset> _shown = const [];

  /// The kinds the last build had a tab for, in tab order: what a page index means.
  List<MadeKind> _kinds = const [];

  /// The pages of the tabs; null until there are two or more kinds.
  PageController? _pager;

  /// The switch is sliding the page to a tab: pages passed on the way are not
  /// choices.
  var _settling = false;

  @override
  void initState() {
    super.initState();
    // Opening the sheet is the ask: the part of a long log the phone has not
    // read is read now, never before (a radio and a battery cost).
    widget.session.readEarlierMade();
  }

  @override
  void dispose() {
    _pager?.dispose();
    _entries.dispose();
    super.dispose();
  }

  List<MadeAsset> _stable(List<MadeAsset> assets) {
    final order = _order ??= [for (final a in assets) a.key];
    final byKey = {for (final a in assets) a.key: a};
    return [for (final k in order) ?byKey[k]];
  }

  /// The tab [kind] without moving the page (a swipe already did).
  void _choose(MadeKind kind) {
    _lastTab[widget.session.key] = kind;
    setState(() => _picked = kind);
  }

  /// The switch above the list: the tab, and the page slides to it.
  void _pick(MadeKind kind) {
    _choose(kind);
    final at = _kinds.indexOf(kind), pager = _pager;
    if (at < 0 || pager == null || !pager.hasClients) return;
    _settling = true;
    unawaited(
      pager
          .animateToPage(at, duration: Motion.of(context, Motion.standard), curve: Motion.easeOut)
          .whenComplete(() => _settling = false),
    );
  }

  /// A swipe landed on page [i]: its kind is the tab. Pages passed over while
  /// the switch slides the page are not choices.
  void _paged(int i) {
    if (_settling || i < 0 || i >= _kinds.length) return;
    _choose(_kinds[i]);
  }

  void _showMore(MadeKind kind) => setState(() => _more[kind] = (_more[kind] ?? 0) + 1);

  /// How many of [kind]'s items are built.
  int _limit(MadeKind kind) => (kind == MadeKind.picture ? _gridStep : _listStep) * (1 + (_more[kind] ?? 0));

  void _open(MadeAsset asset) => unawaited(
    _openMade(
      context,
      widget.opener,
      widget.session,
      asset,
      loader: _entries,
      pictures: [
        for (final a in _shown)
          if (a.kind == MadeKind.picture) a,
      ],
    ),
  );

  /// [items] of one kind (not apps) as rows: the first [_limit] of them and a
  /// `N more` row when there are others.
  List<Widget> _rows(List<MadeAsset> items, MadeKind bucket, {required bool files}) {
    final limit = _limit(bucket);
    final built = items.length > limit ? items.sublist(0, limit) : items;
    final rest = items.length - built.length;
    return [
      for (final (i, asset) in built.indexed)
        _FileRow(
          asset: asset,
          filesAvailable: files,
          divider: i < built.length - 1 || rest > 0,
          onTap: () => _open(asset),
        ),
      if (rest > 0) _MoreRow(count: rest, onTap: () => _showMore(bucket)),
    ];
  }

  /// [apps] as rows: the first [_limit] of them and a `N more` row.
  List<Widget> _appRows(List<MadeApp> apps, {required List<BackgroundTask> tasks, required bool live}) {
    final limit = _limit(MadeKind.server);
    final built = apps.length > limit ? apps.sublist(0, limit) : apps;
    final rest = apps.length - built.length;
    return [
      for (final (i, app) in built.indexed)
        _AppRow(app: app, tasks: tasks, live: live, divider: i < built.length - 1 || rest > 0, onOpen: _open),
      if (rest > 0) _MoreRow(count: rest, onTap: () => _showMore(MadeKind.server)),
    ];
  }

  /// What [_noFiles] takes at [width]: it is a sentence that wraps on a narrow
  /// phone or large text, so it is laid out, not guessed.
  static double _noteHeight(double width, TextScaler scaler) {
    final painter = TextPainter(
      text: const TextSpan(text: _noFiles, style: Type.secondary),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// The most of the screen's height the scrolling area takes; the sheet's own
  /// cap (which the pinned title and switch share) still applies on a small one.
  static const _bodyShare = 0.6;

  /// The height of the scrolling area, the same for every tab and for the
  /// life of the sheet. A bottom sheet grows upward, so a tab with fewer rows
  /// than the last one would pull the switch down from under the thumb (and a
  /// longer one push it up): the switch is pinned above the area, and the area
  /// is as tall as the tallest tab's first batch, or [_bodyShare] of the screen
  /// if that is less, whichever tab is open (a sheet filling the screen around
  /// a two-row tab is worse than a list that scrolls). `N more` adds rows
  /// inside the area, it does not grow it. Estimated from the type scale
  /// rather than measured: the
  /// tabs that are not open are not built, and a few dp either way only
  /// leaves a little room under a short tab or scrolls a long one by that
  /// much.
  double _bodyHeight(List<MadeAsset> shown, List<MadeKind> kinds, double width, TextScaler scaler, bool files) {
    double line(TextStyle s) => scaler.scale(s.fontSize!) * s.height!;
    // A row: its padding, a title line and a line under it, and the hairline.
    final row = math.max(56.0, 24 + line(Type.row) + 2 + line(Type.secondary)) + 1;
    final tile =
        (width - (_PictureGrid.columns - 1) * _PictureGrid.gap) / _PictureGrid.columns * 3 / 4 +
        Gap.xs +
        line(Type.caption);
    var tallest = 0.0;
    for (final kind in kinds) {
      final n = shown.where((a) => a.kind == kind).length;
      if (kind == MadeKind.picture) {
        final cells = math.min(n, _gridStep) + (n > _gridStep ? 1 : 0);
        final rows = (cells + _PictureGrid.columns - 1) ~/ _PictureGrid.columns;
        final note = files ? 0.0 : _noteHeight(width, scaler) + Gap.md;
        tallest = math.max(tallest, Gap.md + note + rows * tile + (rows - 1) * Gap.md);
      } else if (kind == MadeKind.server) {
        // An app is a row, and a line of chips more when it has pages (one
        // wrapped line assumed: a longer wrap scrolls inside the area).
        final apps = madeAppsOf(shown.where((a) => a.kind == kind));
        final withPages = apps.take(_listStep).where((a) => a.pages.isNotEmpty).length;
        tallest = math.max(
          tallest,
          (math.min(apps.length, _listStep) + (apps.length > _listStep ? 1 : 0)) * row +
              withPages * (AppChip.height + Gap.sm),
        );
      } else {
        tallest = math.max(tallest, (math.min(n, _listStep) + (n > _listStep ? 1 : 0)) * row);
      }
    }
    return tallest;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return SessionSelect<_Snap>(
      session: session,
      select: _snap,
      same: _same,
      builder: (context, snap) {
        final (assets, tasks, live, reach, history) = snap;
        if (!identical(history, _orderHistory)) {
          // The read of the earlier part landed: the rows it found are older than
          // the ones shown, so they join at the end. Nothing already here moves.
          _orderHistory = history;
          final known = _order?.toSet() ?? const <String>{};
          if (_order != null) {
            _order = [
              ..._order!,
              for (final a in assets)
                if (!known.contains(a.key)) a.key,
            ];
          }
        }
        final shown = _stable(assets);
        _shown = shown;
        final ds = context.ds;
        final files = machineSupportsFiles(session.machine);
        final kinds = [
          for (final k in _tabKinds)
            if (shown.any((a) => a.kind == k)) k,
        ];
        // The kind the person chose if it is still here, else the newest made
        // (servers only when nothing else exists).
        final newest = shown.where((a) => a.kind != MadeKind.server).firstOrNull?.kind ?? MadeKind.server;
        final tab = kinds.isEmpty ? null : (_picked != null && kinds.contains(_picked) ? _picked! : newest);
        final tabbed = kinds.length >= 2;
        _kinds = kinds;
        if (tabbed) {
          final at = kinds.indexOf(tab!);
          final pager = _pager ??= PageController(initialPage: at);
          // The kinds changed under it (the earlier history brought one): the page follows the tab.
          if (!_settling && pager.hasClients && pager.page?.round() != at) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && pager.hasClients && !_settling) pager.jumpToPage(kinds.indexOf(tab));
            });
          }
        }
        final apps = madeAppsOf([
          for (final a in shown)
            if (a.kind == MadeKind.server) a,
        ]);
        final running = shown.any(
          (a) => a.kind == MadeKind.server && serverStateOf(a, tasks, live: live) == ServerState.running,
        );
        final scaler = MediaQuery.textScalerOf(context);
        // One kind's list or grid. Each starts at its top (a page that was
        // scrolled away is built again).
        Widget scroller(MadeKind kind) => CustomScrollView(
          key: ValueKey(kind),
          // About a row of pictures past the edge, not the default
          // 250 dp: every tile built is a read of up to 2 MiB over
          // the radio, and on a phone that is a third of the grid.
          scrollCacheExtent: const ScrollCacheExtent.pixels(120),
          slivers: [
            if (kind == MadeKind.picture)
              _PictureGrid(
                assets: [
                  for (final a in shown)
                    if (a.kind == kind) a,
                ],
                limit: _limit(MadeKind.picture),
                files: files,
                loader: _entries,
                onOpen: _open,
                onMore: () => _showMore(MadeKind.picture),
              )
            else
              SliverToBoxAdapter(
                child: Column(
                  children: kind == MadeKind.server
                      ? _appRows(apps, tasks: tasks, live: live)
                      : _rows(
                          [
                            for (final a in shown)
                              if (a.kind == kind) a,
                          ],
                          kind,
                          files: files,
                        ),
                ),
              ),
          ],
        );
        return SheetScaffold(
          title: 'Made in this session',
          kind: SheetKind.list,
          child: Padding(
            // The list kind's inset 4 + 12: the rows sit 16 from the edge.
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: LayoutBuilder(
              builder: (context, box) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (shown.isEmpty && reach == MadeReach.whole)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xl),
                      child: Text(
                        'Nothing has come up in this session yet.',
                        style: Type.secondary.copyWith(color: ds.textSecondary),
                      ),
                    ),
                  if (tabbed)
                    _KindTabs(
                      tabs: [
                        for (final k in kinds)
                          (
                            k,
                            _tabLabel(k),
                            k == MadeKind.server ? apps.length : shown.where((a) => a.kind == k).length,
                            k == MadeKind.server && running,
                          ),
                      ],
                      selected: tab!,
                      onChanged: _pick,
                    ),
                  if (tab != null)
                    SizedBox(
                      height: math.min(
                        _bodyHeight(shown, kinds, box.maxWidth, scaler, files),
                        MediaQuery.sizeOf(context).height * _bodyShare,
                      ),
                      // A swipe sideways goes to the next kind, as the switch above does.
                      child: tabbed
                          ? PageView(
                              controller: _pager,
                              onPageChanged: _paged,
                              children: [for (final k in kinds) scroller(k)],
                            )
                          : scroller(tab),
                    ),
                  if (reach != MadeReach.whole) _EarlierNote(reach: reach, onRead: session.readEarlierMade),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Under the list while the rows may not be all of them: the phone read the end
/// of a long chat, and the earlier part is being read, or could not be.
class _EarlierNote extends StatelessWidget {
  const _EarlierNote({required this.reach, required this.onRead});

  final MadeReach reach;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final style = Type.secondary.copyWith(color: context.ds.textSecondary);
    return switch (reach) {
      MadeReach.reading => const LoadingRow('Reading earlier history…'),
      MadeReach.failed => Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Row(
          children: [
            Expanded(child: Text('Couldn’t read the earlier part of this chat. These are the newest.', style: style)),
            AppButton(label: 'Retry', kind: AppButtonKind.ghost, compact: true, onPressed: onRead),
          ],
        ),
      ),
      MadeReach.partial => Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Row(
          children: [
            Expanded(child: Text('Only the end of this chat has been read.', style: style)),
            AppButton(label: 'Read earlier', kind: AppButtonKind.ghost, compact: true, onPressed: onRead),
          ],
        ),
      ),
      MadeReach.whole => const SizedBox.shrink(),
    };
  }
}

String _tabLabel(MadeKind kind) => switch (kind) {
  MadeKind.page => 'Pages',
  MadeKind.picture => 'Pictures',
  MadeKind.doc => 'Docs',
  MadeKind.server => 'Apps',
};

/// The switch between what was made: the app's one `Segmented`, a cell per kind
/// with its count, a live dot on Apps while one runs. The sheet only says
/// which kinds there are and which one is open; this is the one place that
/// decides how it looks.
class _KindTabs extends StatelessWidget {
  const _KindTabs({required this.tabs, required this.selected, required this.onChanged});

  /// Kind, label, count, and whether something of this kind is running now.
  final List<(MadeKind, String, int, bool)> tabs;
  final MadeKind selected;
  final ValueChanged<MadeKind> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    // The title row already leaves Gap.sm above.
    padding: const EdgeInsets.only(bottom: Gap.xs),
    child: Segmented<MadeKind>(
      options: [
        for (final (kind, label, count, running) in tabs)
          SegmentOption(
            kind,
            label,
            count: count,
            leading: running ? const LinkDot.live() : null,
            // The dot is all a sighted person gets of "running"; say it.
            semanticLabel: running ? '$label, $count, running' : null,
          ),
      ],
      value: selected,
      onChanged: onChanged,
    ),
  );
}

/// `12 more`: shows the next batch of a list.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListRow(
    leading: const IconTile(icon: LucideIcons.chevronDown),
    leadingOnTitle: false,
    title: '$count more',
    onTap: onTap,
  );
}

/// Rows being opened, so a second tap while the connection is made does not
/// start a second open and a second viewer.
final _opening = <String>{};

/// Opens [asset] over the sheet, which stays on the stack under it (Back lands
/// on the list, on the same tab): an app or page as a page in herdr (its screen
/// goes up at once and says there if it cannot open), a picture in the photo
/// viewer with the other [pictures] to swipe to, and a document in the file
/// viewer. A failure is a toast over the sheet.
Future<void> _openMade(
  BuildContext sheet,
  BuildContext opener,
  AgentSessionView session,
  MadeAsset asset, {
  required _EntryLoader loader,
  required List<MadeAsset> pictures,
}) async {
  final toaster = Toaster.of(sheet);
  final machine = session.machine;
  final service = asset.kind == MadeKind.server && asset.port != null ? sensitiveServiceOf(asset.port!) : null;
  if (service != null) {
    // Not a web page: opened only from the link in the chat, where the whole
    // address is on the screen and the tap is the person's own.
    toaster.show('That is a $service port. Open the link from the chat if you mean to.');
    return;
  }
  void failed(String text) => toaster.show(text, kind: ToastKind.failed);
  if (asset.kind != MadeKind.server && !machineSupportsFiles(machine)) {
    failed('Files are not available on this machine.');
    return;
  }
  final id = '${session.key}\u0000${asset.key}';
  if (!_opening.add(id)) {
    // The row says what it is doing instead of looking dead.
    toaster.show('Still opening ${visibleText(asset.title)}…');
    return;
  }
  try {
    switch (asset.kind) {
      case MadeKind.doc:
        // The screen goes up at once and finds the file inside (it says what
        // went wrong itself).
        if (opener.mounted) unawaited(openRemoteFile(opener, machine, asset.path!, cwd: session.cwd));
      case MadeKind.picture:
        // No toast: it would stand over the viewer for its 3 s (the app has no
        // way to take one down), and the tile the person tapped is already a
        // thumbnail of this picture.
        final files = machine.files;
        final stat = await files.stat(await files.resolve(asset.path!, cwd: session.cwd));
        if (!opener.mounted) return;
        // The pictures of the list, in its order, with the tapped one open. A
        // picture the grid found gone is left out; two rows that name one file
        // are one picture (the viewer keeps its pictures by path).
        final items = <PhotoItem>[];
        final used = <String>{stat.path};
        var at = 0;
        for (final p in pictures) {
          if (p.key == asset.key) {
            at = items.length;
            items.add(remotePhotoItem(files, path: stat.path, size: stat.size, modified: stat.modified));
            continue;
          }
          if (loader.gone(p)) continue;
          final String path;
          try {
            path = await files.resolve(p.path!, cwd: session.cwd);
          } on RemoteFileException {
            continue;
          }
          if (!used.add(path)) continue;
          final known = loader.known(p);
          items.add(remotePhotoItem(files, path: path, size: known?.size, modified: known?.modified));
        }
        if (!opener.mounted) return;
        unawaited(openPhotoViewer(opener, items: items, initialIndex: at));
      case MadeKind.server:
        if (opener.mounted) {
          final name = serverNameOf(asset, session.backgroundWork.tasks);
          unawaited(openWebPreview(opener, machine, ServerPage(asset.url!, name: name)));
        }
      case MadeKind.page:
        if (opener.mounted) unawaited(openWebPreview(opener, machine, FilePage(asset.path!, cwd: session.cwd)));
    }
  } on RemoteFileException catch (e) {
    failed(
      e.kind == RemoteFileErrorKind.notFound
          ? '${visibleText(asset.title)} isn’t on the machine any more.'
          : visibleText(e.message),
    );
  } finally {
    _opening.remove(id);
  }
}

/// One app: the server of a port and the pages the agent named on it. Its name
/// is what started it (the command of a background task on the port, or the one
/// the transcript launched it with), else the port. A tap opens the app; a chip
/// under it opens one of its pages.
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.tasks,
    required this.live,
    required this.divider,
    required this.onOpen,
  });

  final MadeApp app;
  final List<BackgroundTask> tasks;
  final bool live;
  final bool divider;
  final ValueChanged<MadeAsset> onOpen;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final service = sensitiveServiceOf(app.port);
    final state = serverStateOf(app.entry, tasks, live: live);
    final running = state == ServerState.running;
    final named = service == null ? serverNameOf(app.entry, tasks) : null;
    final at = app.at;
    final when = at == null ? '' : formatAgo(at, DateTime.now());
    // Said only as far as the phone knows: a link in the chat does not say the
    // server still runs.
    final status = service != null
        ? 'not a web page'
        : switch (state) {
            ServerState.running => 'Running',
            ServerState.stopped => when.isEmpty ? 'Stopped' : 'Stopped · $when',
            ServerState.seen => when.isEmpty ? 'Status unknown' : 'Status unknown · mentioned $when',
          };
    final row = ListRow(
      leading: IconTile(icon: HerdrIcons.madeServer, color: running ? ds.done : null),
      leadingOnTitle: false,
      title: visibleText(service ?? named ?? 'App on port ${app.port}'),
      // The fallback name already says the port.
      subtitle: [if (service != null || named != null) 'Port ${app.port}', status].join(' · '),
      dim: state == ServerState.stopped || service != null,
      onTap: () => onOpen(app.entry),
      trailing: running ? const LinkDot.live() : null,
    );
    final pages = service == null && app.pages.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (pages)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: ListRow.textIndent(), right: Gap.md, bottom: Gap.xs),
              child: Wrap(
                spacing: Gap.sm,
                children: [for (final p in app.pages) AppChip(label: visibleText(p.route), onTap: () => onOpen(p))],
              ),
            ),
          ),
        if (divider) Hairline(indent: ListRow.textIndent()),
      ],
    );
  }
}

/// A page or a document: its name, and under it the folder and time (or why it
/// cannot be opened on this machine).
class _FileRow extends StatelessWidget {
  const _FileRow({required this.asset, required this.filesAvailable, required this.divider, required this.onTap});

  final MadeAsset asset;
  final bool filesAvailable;
  final bool divider;
  final VoidCallback onTap;

  String? get _subtitle {
    if (!filesAvailable) return _noFiles;
    final at = asset.at;
    final when = at == null ? '' : formatAgo(at, DateTime.now());
    final text = [visibleText(asset.where), when].where((s) => s.isNotEmpty).join(' · ');
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final row = ListRow(
      leading: IconTile(
        icon: switch (asset.kind) {
          MadeKind.page => HerdrIcons.madePage,
          MadeKind.picture => HerdrIcons.picture,
          MadeKind.doc => HerdrIcons.madeDoc,
          MadeKind.server => HerdrIcons.madeServer,
        },
      ),
      leadingOnTitle: false,
      title: visibleText(asset.title),
      subtitle: _subtitle,
      dim: !filesAvailable,
      onTap: filesAvailable ? onTap : null,
    );
    if (!divider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Hairline(indent: ListRow.textIndent()),
      ],
    );
  }
}

/// The stat of a made picture, once per picture and sheet, a few at a time.
/// A tile asks only when it is built, so a picture nobody sees costs nothing;
/// its thumbnail is then read by [PhotoThumbs] (three at a time, dropped when
/// the tile goes).
class _EntryLoader {
  _EntryLoader(this._session);

  final AgentSessionView _session;
  final _byKey = <String, Future<RemoteEntry?>>{};
  final _known = <String, RemoteEntry>{};
  final _gone = <String>{};
  final _waiting = Queue<Completer<void>>();
  var _running = 0;
  var _disposed = false;

  static const _parallel = 4;

  /// The listing entry of [asset]'s file; null when it is gone (or is no
  /// longer a file), which is remembered for the sheet. Throws when it could
  /// not be asked (link down, a timeout, a refusal): that says nothing about
  /// the file, so it is not remembered and the next ask goes to the machine.
  Future<RemoteEntry?> of(MadeAsset asset) => _byKey[asset.key] ??= _load(asset);

  /// The entry of [asset] when it has been asked and found a file.
  RemoteEntry? known(MadeAsset asset) => _known[asset.key];

  /// Whether [asset] has been asked and found gone.
  bool gone(MadeAsset asset) => _gone.contains(asset.key);

  /// The sheet is gone: tiles waiting for a turn are let go without asking.
  void dispose() {
    _disposed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    }
  }

  Future<void> _turn() {
    if (_running < _parallel) {
      _running++;
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  void _next() {
    if (_waiting.isEmpty) {
      _running--;
    } else {
      _waiting.removeFirst().complete();
    }
  }

  Future<RemoteEntry?> _load(MadeAsset asset) async {
    await _turn();
    try {
      if (_disposed) return null;
      final files = _session.machine.files;
      final stat = await files.stat(await files.resolve(asset.path!, cwd: _session.cwd));
      if (!stat.isFile) {
        _gone.add(asset.key);
        return null;
      }
      return _known[asset.key] = RemoteEntry(
        name: stat.name,
        path: stat.path,
        kind: RemoteEntryKind.file,
        resolvedKind: RemoteEntryKind.file,
        size: stat.size,
        modified: stat.modified,
      );
    } on Object catch (e) {
      if (e is RemoteFileException && e.kind == RemoteFileErrorKind.notFound) {
        _gone.add(asset.key);
        return null;
      }
      _byKey.remove(asset.key);
      rethrow;
    } finally {
      _next();
    }
  }
}

/// The pictures as a grid, three across: a 4:3 thumbnail and the file name
/// under it. A sliver of lazy rows of three, so only the tiles at the
/// viewport (and a little beyond it) exist and ask for their picture; the
/// first [limit] tiles are all there can be.
class _PictureGrid extends StatelessWidget {
  const _PictureGrid({
    required this.assets,
    required this.limit,
    required this.files,
    required this.loader,
    required this.onOpen,
    required this.onMore,
  });

  final List<MadeAsset> assets;
  final int limit;
  final bool files;
  final _EntryLoader loader;
  final ValueChanged<MadeAsset> onOpen;
  final VoidCallback onMore;

  static const columns = 3;
  static const gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final built = assets.length > limit ? assets.sublist(0, limit) : assets;
    final rest = assets.length - built.length;
    final cells = built.length + (rest > 0 ? 1 : 0);
    Widget cell(int i) {
      if (i < built.length) {
        final a = built[i];
        return _PictureTile(key: ValueKey(a.key), asset: a, loader: loader, enabled: files, onTap: () => onOpen(a));
      }
      return i == built.length && rest > 0 ? _MoreTile(count: rest, onTap: onMore) : const SizedBox.shrink();
    }

    final rows = SliverList.builder(
      itemCount: (cells + columns - 1) ~/ columns,
      // A row scrolled away lets go of its pictures at once.
      addAutomaticKeepAlives: false,
      itemBuilder: (context, row) => Padding(
        padding: row > 0 ? const EdgeInsets.only(top: Gap.md) : EdgeInsets.zero,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < columns; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(child: cell(row * columns + i)),
            ],
          ],
        ),
      ),
    );
    return SliverPadding(
      padding: const EdgeInsets.only(top: Gap.md),
      sliver: SliverMainAxisGroup(
        slivers: [
          // Unavailable stays, dimmed, and says why once instead of under every tile.
          if (!files)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: Gap.md),
                child: Text(_noFiles, style: Type.secondary.copyWith(color: ds.textSecondary)),
              ),
            ),
          if (files) rows else SliverOpacity(opacity: 0.55, sliver: rows),
        ],
      ),
    );
  }
}

/// One picture: the thumbnail when it can be had, a quiet tile with a picture
/// glyph until then, a crossed one when the file is gone, and a tile that asks
/// again when tapped when the machine could not be asked.
class _PictureTile extends StatefulWidget {
  const _PictureTile({
    super.key,
    required this.asset,
    required this.loader,
    required this.enabled,
    required this.onTap,
  });

  final MadeAsset asset;
  final _EntryLoader loader;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_PictureTile> createState() => _PictureTileState();
}

enum _Face { loading, ready, gone, unknown }

class _PictureTileState extends State<_PictureTile> {
  RemoteEntry? _entry;
  var _face = _Face.loading;

  @override
  void initState() {
    super.initState();
    // Nothing is asked of a machine that cannot answer.
    if (widget.enabled) _ask();
  }

  void _ask() => unawaited(
    widget.loader
        .of(widget.asset)
        .then(
          (entry) {
            if (!mounted) return;
            setState(() {
              _entry = entry;
              _face = entry == null ? _Face.gone : _Face.ready;
            });
          },
          // Not "gone": the link may be down. Say nothing is known, ask again on a tap.
          onError: (Object _) {
            if (mounted) setState(() => _face = _Face.unknown);
          },
        ),
  );

  void _retry() {
    setState(() => _face = _Face.loading);
    _ask();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final entry = _entry;
    final name = visibleText(widget.asset.title);
    final unknown = _face == _Face.unknown;
    return PressBuilder(
      onTap: !widget.enabled ? null : (unknown ? _retry : widget.onTap),
      haptic: true,
      semanticLabel: unknown ? '$name, couldn’t be loaded, tap to retry' : name,
      builder: (context, pressed) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: entry == null
                  ? _QuietTile(
                      icon: switch (_face) {
                        _Face.gone => HerdrIcons.pictureOff,
                        _Face.unknown => LucideIcons.refreshCw,
                        _ => HerdrIcons.picture,
                      },
                      faint: _face == _Face.loading,
                      pressed: pressed,
                    )
                  : PhotoThumbFace(
                      files: widget.loader._session.machine.files,
                      entry: entry,
                      thumbs: PhotoThumbs.shared,
                      pressed: pressed,
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: ds.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tile with only a glyph on the quiet fill.
class _QuietTile extends StatelessWidget {
  const _QuietTile({required this.icon, this.faint = false, this.pressed = false, this.text});

  final IconData icon;
  final bool faint;
  final bool pressed;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: ds.fill,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: IconSize.nav, color: faint ? ds.faint : ds.textMuted),
                if (text != null) ...[
                  const SizedBox(height: Gap.xs),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(text!, maxLines: 1, style: Type.caption.copyWith(color: ds.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (pressed) ColoredBox(color: ds.wash(ds.text)),
      ],
    );
  }
}

/// `12 more` in the grid: the next batch of tiles.
class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PressBuilder(
    onTap: onTap,
    haptic: true,
    builder: (context, pressed) => AspectRatio(
      aspectRatio: 4 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: _QuietTile(icon: LucideIcons.chevronDown, pressed: pressed, text: '$count more'),
      ),
    ),
  );
}

/// `Made 3` beside the subagents chip under the session's title: the number of
/// servers, pages, pictures and documents the session has made. Takes no room
/// while there are none.
class MadeChip extends StatelessWidget {
  const MadeChip({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<(List<MadeAsset>, bool, MadeReach)>(
    session: session,
    select: (s) => (
      madeAssetsOf(s.state.items, cwd: s.cwd, history: s.madeHistory),
      s.subagents.isNotEmpty || s.subagentSummary.total > 0,
      s.madeReach,
    ),
    same: (a, b) => sameMadeAssets(a.$1, b.$1) && a.$2 == b.$2 && a.$3 == b.$3,
    builder: (context, v) {
      final (assets, besideSubagents, reach) = v;
      final partial = reach != MadeReach.whole;
      if (assets.isEmpty && !partial) return const SizedBox.shrink();
      // `9+`: the rows are the newest ones, the earlier part is not read yet.
      return Padding(
        // The bar's row places the chips; this one follows the subagents chip.
        padding: besideSubagents
            ? const EdgeInsets.only(left: Gap.sm, bottom: Gap.hair)
            : const EdgeInsets.only(bottom: Gap.hair),
        child: AppChip(
          label: partial ? (assets.isEmpty ? 'Made' : 'Made ${madeCountOf(assets)}+') : 'Made',
          count: partial ? null : madeCountOf(assets),
          semanticLabel: partial
              ? '${countOf(madeCountOf(assets), 'item')} made so far, earlier history not read'
              : '${countOf(madeCountOf(assets), 'item')} made',
          leading: Icon(HerdrIcons.made, size: IconSize.inline, color: context.ds.textSecondary),
          onTap: () => unawaited(showSessionMade(context, session)),
        ),
      );
    },
  );
}
