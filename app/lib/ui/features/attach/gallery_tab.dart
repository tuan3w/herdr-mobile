import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/services/phone_gallery.dart';
import '../../../data/services/thumb_cache.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../agent_session/session_select.dart' show notifyRegionBuilt;
import '../files/file_format.dart';
import 'attach_kit.dart';
import 'gallery_model.dart';
import 'gallery_preview.dart';
import 'gallery_thumb.dart';
import 'selection_circle.dart';
import 'sheet_frame.dart';
import 'tray.dart';

/// The gap between tiles; a phone shows three columns, a wider window more
/// (tiles stay about 130 dp).
const galleryGap = 2.0;

/// Columns for a grid [width] wide: 3 on a phone, up to 8.
int galleryColumnsFor(double width) => (width / 130).round().clamp(3, 8);

/// A scroll faster than this (dp/s) holds the thumbnail queue: the tiles
/// flying past are not worth decoding.
const galleryFlingPause = 2400.0;

/// `today 14:02`, `yesterday 09:10`, `May 20, 14:02`, `May 20, 2025`.
String describeTaken(DateTime when, DateTime now) {
  final t = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(t.hour)}:${two(t.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days == 0) return 'today $clock';
  if (days == 1) return 'yesterday $clock';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = '${months[t.month - 1]} ${t.day}';
  return t.year == now.year ? '$date, $clock' : '$date, ${t.year}';
}

/// The Gallery tab: the phone's recent pictures as a 3-column grid, newest
/// first, the camera as the first tile, a round mark on every picture.
///
/// The permission is read when the tab is shown and asked for only after a
/// one-line reason and a tap. Nothing here rebuilds the grid for a selection
/// (a tile listens to the tray for its own number) or for a page arriving (a
/// tile waiting for its picture listens to `GalleryModel.revision`).
class GalleryTab extends StatefulWidget {
  const GalleryTab({
    super.key,
    required this.kit,
    required this.session,
    required this.tray,
    required this.onCamera,
    required this.onSystemPicker,
    this.now,
  });

  final AttachKit kit;
  final AgentSessionView session;
  final AttachTray tray;

  /// The Camera tile was tapped (the sheet closes and the camera opens).
  final VoidCallback onCamera;

  /// "Open the system picker": the fallback when the library cannot be read.
  final VoidCallback onSystemPicker;

  /// The moment "today" is for the tile labels (a test pins it).
  final DateTime Function()? now;

  @override
  State<GalleryTab> createState() => _GalleryTabState();
}

class _GalleryTabState extends State<GalleryTab> with WidgetsBindingObserver {
  GalleryModel get model => widget.kit.galleryModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(model.open());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings: the answer may have changed.
    if (state == AppLifecycleState.resumed) unawaited(model.recheck());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final body = switch (model.access) {
        GalleryAccess.granted || GalleryAccess.limited => _Grid(
          model: model,
          tray: widget.tray,
          cache: widget.kit.thumbs,
          onCamera: widget.onCamera,
          now: widget.now ?? DateTime.now,
          onSystemPicker: widget.onSystemPicker,
        ),
        GalleryAccess.undetermined when !model.checked => _Grid(
          model: model,
          tray: widget.tray,
          cache: widget.kit.thumbs,
          onCamera: widget.onCamera,
          now: widget.now ?? DateTime.now,
          onSystemPicker: widget.onSystemPicker,
        ),
        GalleryAccess.undetermined => _Panel(
          icon: LucideIcons.images,
          title: 'Attach photos from your phone',
          message: 'Photos stay on your phone until you attach them.',
          primary: ('Allow photo access', () => unawaited(model.request())),
          onCamera: widget.onCamera,
          onSystemPicker: widget.onSystemPicker,
        ),
        GalleryAccess.denied => _Panel(
          icon: LucideIcons.imageOff,
          title: 'Photo access is off',
          message: 'Allow it in the phone\u2019s settings to see your photos here.',
          primary: ('Open settings', () => unawaited(model.openSettings())),
          onCamera: widget.onCamera,
          onSystemPicker: widget.onSystemPicker,
        ),
        GalleryAccess.unavailable => _Panel(
          icon: LucideIcons.imageOff,
          title: 'Photos cannot be listed',
          message: 'This phone would not show its library to herdr. The system picker still works.',
          onCamera: widget.onCamera,
          onSystemPicker: widget.onSystemPicker,
        ),
      };
      return Column(
        children: [
          if (model.access.canRead) _Header(model: model),
          // Said, not hidden: the photos still go, as files.
          if (!widget.session.acceptsImages && model.access.canRead) const _NoImagesNote(),
          Expanded(child: body),
        ],
      );
    },
  );
}

/// The album chip, the count, and (partial access) the way to change what is shared.
class _Header extends StatelessWidget {
  const _Header({required this.model});

  final GalleryModel model;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final album = model.album;
    final limited = model.access == GalleryAccess.limited;
    return SizedBox(
      height: AppChip.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Row(
          children: [
            AppChip(
              label: album?.name ?? 'Recent',
              semanticLabel: 'Album: ${album?.name ?? 'Recent'}',
              leading: Icon(LucideIcons.chevronsUpDown, size: 14, color: ds.textSecondary),
              onTap: () => unawaited(_chooseAlbum(context, model)),
            ),
            if (limited) ...[
              const SizedBox(width: Gap.sm),
              AppChip(
                label: 'Manage',
                semanticLabel: 'Manage which photos herdr can see',
                leading: Icon(LucideIcons.slidersHorizontal, size: 14, color: ds.textSecondary),
                onTap: () => unawaited(model.manage()),
              ),
            ],
            const Spacer(),
            if (album != null && album.count > 0)
              Text(
                '${groupDigits(album.count)} ${album.count == 1 ? 'photo' : 'photos'}',
                style: Type.caption.copyWith(color: ds.textMuted, fontFeatures: Type.tabular),
              ),
          ],
        ),
      ),
    );
  }
}

/// The honest line for an agent that takes no pictures.
class _NoImagesNote extends StatelessWidget {
  const _NoImagesNote();

  /// The line itself (a test finds it).
  static const text = 'This agent does not take images. Photos go up as files.';

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.gutter, 0, Gap.gutter, Gap.sm),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: Type.caption.copyWith(color: context.ds.textSecondary)),
    ),
  );
}

Future<void> _chooseAlbum(BuildContext context, GalleryModel model) async {
  await model.loadAlbums();
  if (!context.mounted) return;
  await showAppSheet<void>(
    context,
    builder: (sheet) {
      final ds = sheet.ds;
      final albums = model.albums;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(header: true, child: Text('Albums', style: Type.label.copyWith(color: ds.textSecondary))),
            ),
            for (final a in albums)
              PressBuilder(
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(model.selectAlbum(a));
                },
                selected: a.id == model.album?.id,
                builder: (context, pressed) => Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: pressed ? ds.fill : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.row),
                  ),
                  child: Row(
                    children: [
                      Icon(a.isRecent ? LucideIcons.images : LucideIcons.folder, size: 20, color: ds.textSecondary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.row.copyWith(color: ds.text)),
                      ),
                      const SizedBox(width: 12),
                      Text(groupDigits(a.count), style: Type.secondary.copyWith(color: ds.textMuted, fontFeatures: Type.tabular)),
                      if (a.id == model.album?.id) ...[
                        const SizedBox(width: 12),
                        Icon(LucideIcons.check, size: 18, color: ds.accentText),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// No library to show: why, and what to do instead. The camera and the
/// system picker are always one tap away: when the actions would not fit above
/// the bars at half height (a small screen, large text) the sheet is lifted to
/// full height, so none of them is ever out of reach.
class _Panel extends StatefulWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.message,
    required this.onCamera,
    required this.onSystemPicker,
    this.primary,
  });

  final IconData icon;
  final String title;
  final String message;
  final (String, VoidCallback)? primary;
  final VoidCallback onCamera;
  final VoidCallback onSystemPicker;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  final _content = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  void _fit() {
    if (!mounted) return;
    final box = _content.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final position = SheetScope.of(context).position;
    // What shows at half height: its height less the grabber and the bars.
    final room = position.halfHeight - 20 - sheetBarsReserve;
    if (box.size.height + Gap.lg > room) position.expand();
  }

  @override
  Widget build(BuildContext context) {
    final clearance = SheetScope.of(context).bottomClearance;
    final primary = widget.primary;
    return SheetScroll(
      builder: (context, controller, physics) => ListView(
        controller: controller,
        physics: physics,
        padding: EdgeInsets.only(top: Gap.lg, bottom: clearance),
        children: [
          KeyedSubtree(
            key: _content,
            child: EmptyState(
              icon: widget.icon,
              title: widget.title,
              message: widget.message,
              action: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (primary != null) ...[
                    AppButton(label: primary.$1, onPressed: primary.$2, expand: true),
                    const SizedBox(height: Gap.sm),
                  ],
                  AppButton(
                    label: 'Open the system picker',
                    icon: LucideIcons.image,
                    kind: primary == null ? AppButtonKind.primary : AppButtonKind.secondary,
                    expand: true,
                    onPressed: widget.onSystemPicker,
                  ),
                  const SizedBox(height: Gap.sm),
                  AppButton(
                    label: 'Take a photo',
                    icon: LucideIcons.camera,
                    kind: AppButtonKind.ghost,
                    expand: true,
                    onPressed: widget.onCamera,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Grid extends StatefulWidget {
  const _Grid({
    required this.model,
    required this.tray,
    required this.cache,
    required this.onCamera,
    required this.now,
    required this.onSystemPicker,
  });

  final GalleryModel model;
  final AttachTray tray;
  final ThumbCache cache;
  final VoidCallback onCamera;
  final DateTime Function() now;
  final VoidCallback onSystemPicker;

  @override
  State<_Grid> createState() => _GridState();
}

class _GridState extends State<_Grid> {
  final _scroll = ScrollController();
  double _tile = 130;
  int _columns = 3;
  double _lastPixels = 0;
  final _clock = Stopwatch()..start();
  int _lastMicros = 0;
  int _lastRow = -1;

  @override
  void dispose() {
    widget.cache.paused = false;
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollEndNotification) {
      widget.cache.paused = false;
      _afterScroll(n.metrics.pixels, n.metrics.viewportDimension, 0);
    } else if (n is ScrollUpdateNotification) {
      final now = _clock.elapsedMicroseconds;
      final dt = (now - _lastMicros) / 1e6;
      final dpx = n.metrics.pixels - _lastPixels;
      _lastMicros = now;
      _lastPixels = n.metrics.pixels;
      if (dt > 0) {
        final speed = dpx.abs() / dt;
        widget.cache.paused = speed > galleryFlingPause;
        _afterScroll(n.metrics.pixels, n.metrics.viewportDimension, dpx.sign.toInt());
      }
    }
    return false;
  }

  /// One screenful of rows ahead in the direction of travel is warmed.
  void _afterScroll(double pixels, double viewport, int direction) {
    final row = _tile + galleryGap;
    final lastRow = ((pixels + viewport) / row).floor();
    if (lastRow == _lastRow) return;
    _lastRow = lastRow;
    final lastIndex = (lastRow + 1) * _columns - 1 - 1; // grid index -> asset index (camera is tile 0)
    final span = ((viewport / row).ceil() + 1) * _columns;
    widget.model.prefetchAround(lastIndex, span: span, direction: direction >= 0 ? 1 : -1);
  }

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('attach:grid');
    final model = widget.model;
    final clearance = SheetScope.of(context).bottomClearance;
    return LayoutBuilder(
      builder: (context, box) {
        _columns = galleryColumnsFor(box.maxWidth);
        _tile = (box.maxWidth - galleryGap * (_columns + 1)) / _columns;
        final count = model.count;
        final empty = model.checked && model.access.canRead && !model.loading && model.album != null && count == 0;
        return SheetScroll(
          controller: _scroll,
          builder: (context, controller, physics) => NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: CustomScrollView(
              controller: controller,
              physics: physics,
              // A screenful of tiles is built beyond the edge, never the
              // whole library.
              scrollCacheExtent: ScrollCacheExtent.pixels(_tile * 2),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(galleryGap, 0, galleryGap, empty ? 0 : clearance),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _columns,
                      mainAxisSpacing: galleryGap,
                      crossAxisSpacing: galleryGap,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        if (i == 0) return _CameraTile(onTap: widget.onCamera);
                        final index = i - 1;
                        final asset = model.at(index);
                        if (asset == null) {
                          model.ensure(index);
                          return _PendingTile(model: model, index: index, build: (a) => _tileFor(a, index));
                        }
                        return _tileFor(asset, index);
                      },
                      childCount: 1 + (model.access.canRead ? count : 0),
                      addAutomaticKeepAlives: false,
                      addSemanticIndexes: false,
                    ),
                  ),
                ),
                if (empty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(top: Gap.xl, bottom: clearance),
                      child: const EmptyState(
                        icon: LucideIcons.imageOff,
                        title: 'No photos yet',
                        message: 'Take one with the camera, or pick a file from the Files tab.',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tileFor(GalleryAsset asset, int index) => PhotoTile(
    key: ValueKey(asset.id),
    asset: asset,
    index: index,
    tray: widget.tray,
    cache: widget.cache,
    now: widget.now,
    onOpen: () => openGalleryPreview(
      context,
      model: widget.model,
      tray: widget.tray,
      cache: widget.cache,
      index: index,
    ),
  );
}

/// A slot whose page has not arrived: flat tint, until the model has it.
class _PendingTile extends StatefulWidget {
  const _PendingTile({required this.model, required this.index, required this.build});

  final GalleryModel model;
  final int index;
  final Widget Function(GalleryAsset asset) build;

  @override
  State<_PendingTile> createState() => _PendingTileState();
}

class _PendingTileState extends State<_PendingTile> {
  @override
  void initState() {
    super.initState();
    widget.model.revision.addListener(_onRevision);
  }

  void _onRevision() {
    if (widget.model.at(widget.index) != null && mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.model.revision.removeListener(_onRevision);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.model.at(widget.index);
    return asset == null ? ColoredBox(color: context.ds.fill) : widget.build(asset);
  }
}

/// The first tile: the camera.
class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      haptic: true,
      semanticLabel: 'Camera',
      builder: (context, pressed) => ColoredBox(
        color: pressed ? ds.fillPressed : ds.fill,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.camera, size: 30, color: ds.textSecondary),
              const SizedBox(height: Gap.xs),
              Text('Camera', style: Type.caption.copyWith(color: ds.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One picture. Rebuilds itself (and only itself) when its number in the tray
/// changes.
class PhotoTile extends StatefulWidget {
  const PhotoTile({
    super.key,
    required this.asset,
    required this.index,
    required this.tray,
    required this.cache,
    required this.now,
    required this.onOpen,
  });

  final GalleryAsset asset;

  /// Position in the album, 0-based (the label says `Photo ${index + 1}`).
  final int index;
  final AttachTray tray;
  final ThumbCache cache;
  final DateTime Function() now;
  final VoidCallback onOpen;

  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  late int? _number = widget.tray.numberOf('g:${widget.asset.id}');

  @override
  void initState() {
    super.initState();
    widget.tray.addListener(_onTray);
  }

  void _onTray() {
    final n = widget.tray.numberOf('g:${widget.asset.id}');
    if (n != _number && mounted) setState(() => _number = n);
  }

  @override
  void dispose() {
    widget.tray.removeListener(_onTray);
    super.dispose();
  }

  void _toggle() {
    final tray = widget.tray;
    final key = 'g:${widget.asset.id}';
    if (tray.contains(key)) {
      tray.remove(key);
    } else {
      tray.add(GalleryPick(widget.asset, thumb: widget.cache.peek(widget.asset.id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('attach:tile');
    final ds = context.ds;
    final n = _number;
    final picked = n != null;
    final reduced = Motion.reduced(context);
    final label = 'Photo ${widget.index + 1}, taken ${describeTaken(widget.asset.createdAt, widget.now())}';
    Widget picture = GalleryThumb(asset: widget.asset, cache: widget.cache);
    if (picked) picture = ClipRRect(borderRadius: BorderRadius.circular(Radii.tile), child: picture);
    return Semantics(
      container: true,
      label: '$label, ${picked ? 'selected, number $n' : 'not selected'}',
      button: true,
      onTap: widget.onOpen,
      onLongPress: _toggle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: widget.onOpen,
        onLongPress: () {
          Haptics.hold();
          _toggle();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: ds.fill),
            AnimatedScale(
              scale: picked ? 0.88 : 1,
              duration: reduced ? Duration.zero : Motion.press,
              curve: Motion.easeOut,
              child: picture,
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SelectionCircle(
                number: n,
                onPhoto: true,
                label: picked ? 'Deselect photo ${widget.index + 1}' : 'Select photo ${widget.index + 1}',
                onTap: _toggle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
