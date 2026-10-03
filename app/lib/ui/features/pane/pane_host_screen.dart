import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/open_tabs.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../files/files_navigation.dart';
import 'pane_screen.dart';
import 'pane_view_model.dart';
import 'tab_info.dart';
import 'tab_strip.dart';
import 'tabs_tray.dart';

/// A tab screen keeps this many panes alive (their text, scrollback, scroll
/// position and composer draft); the least recently shown one beyond that is
/// dropped and rebuilt from a fresh read when its tab is shown again.
const livePanes = 6;

/// Screens shorter than this (a phone on its side) share one row between back,
/// the tabs and the buttons.
const _shortScreen = 520.0;

/// The tray never grows past this share of the screen.
const _trayShare = 0.65;

/// The screen every pane opens in. It holds the tab set ([OpenTabs]): a top bar
/// for the selected tab, the tab strip, the selected pane, and the tray that
/// lays all tabs out as cards. Back from any tab leaves the screen once.
///
/// Panes of visited tabs stay mounted (hidden) so their scroll position and
/// history survive a switch, but only the selected one reads: the others are
/// paused and read again as soon as they are shown.
class PaneHostScreen extends StatefulWidget {
  const PaneHostScreen({super.key, this.maxLive = livePanes});

  /// How many visited panes to keep alive; see [livePanes].
  final int maxLive;

  @override
  State<PaneHostScreen> createState() => _PaneHostScreenState();
}

/// A tab's live pane: the machine it was opened on, its view model, and the
/// page showing them. The page is built once, so that rebuilding the host (a
/// tab switch, an attention mark) hands every hidden pane the identical widget
/// and rebuilds none of them.
class _Session {
  _Session(this.machine, this.viewModel, this.page);

  final MachineConnection machine;
  final PaneViewModel viewModel;
  final Widget page;
}

class _PaneHostScreenState extends State<PaneHostScreen>
    with SingleTickerProviderStateMixin {
  late final OpenTabs _tabs = context.read<OpenTabs>();
  late final FleetRepository _fleet = context.read<FleetRepository>();
  late final TerminalSettings _settings = context.read<TerminalSettings>();

  final _sessions = <String, _Session>{};
  final _shownAt = <String, int>{};
  int _shownClock = 0;

  /// What each tab last looked like while its pane existed.
  final _known = <String, TabInfo>{};
  final _infos = ValueNotifier<List<TabInfo>>(const []);

  late final AnimationController _tray =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 260),
        reverseDuration: const Duration(milliseconds: 200),
      )..addStatusListener((_) {
        if (mounted) setState(() {});
      });
  late final Animation<double> _trayCurve = CurvedAnimation(
    parent: _tray,
    curve: Motion.easeOut,
    reverseCurve: Motion.easeOut,
  );
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _tabs.hostAttached = true;
    _tabs.addListener(_onTabs);
    _fleet.addListener(_onFleet);
    _rebuildInfos();
    _syncSessions();
    // Notifies listeners, so not while the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _noteStatuses();
    });
  }

  @override
  void dispose() {
    _tabs.hostAttached = false;
    _tabs.removeListener(_onTabs);
    _fleet.removeListener(_onFleet);
    _tray.dispose();
    _infos.dispose();
    for (final s in _sessions.values) {
      s.viewModel.dispose();
    }
    _sessions.clear();
    super.dispose();
  }

  void _rebuildInfos() {
    final list = [
      for (final ref in _tabs.tabs)
        TabInfo.of(
          ref,
          _fleet.connection(ref.machineId),
          known: _known[ref.key],
        ),
    ];
    for (final info in list) {
      if (!info.gone) _known[info.key] = info;
    }
    _known.removeWhere((key, _) => !_tabs.contains(key));
    if (!listEquals(list, _infos.value)) _infos.value = list;
  }

  /// Feeds every tab's status to [OpenTabs], which marks the background tabs
  /// that changed.
  void _noteStatuses() {
    for (final info in _infos.value) {
      _tabs.noteStatus(info.key, info.status);
    }
  }

  void _onTabs() {
    _rebuildInfos();
    _syncSessions();
    if (_tabs.isEmpty) {
      _leave();
      return;
    }
    if (mounted) setState(() {});
  }

  void _onFleet() {
    _rebuildInfos();
    _noteStatuses();
    if (_sessionsOutOfDate()) {
      _syncSessions();
      if (mounted) setState(() {});
    }
  }

  /// A machine was replaced or removed under a live pane, or the selected tab's
  /// machine came back after it had none.
  bool _sessionsOutOfDate() {
    for (final entry in _sessions.entries) {
      final ref = _tabs.tabs.where((t) => t.key == entry.key).firstOrNull;
      if (ref == null ||
          _fleet.connection(ref.machineId) != entry.value.machine) {
        return true;
      }
    }
    final active = _tabs.active;
    return active != null &&
        !_sessions.containsKey(active.key) &&
        _fleet.connection(active.machineId) != null;
  }

  /// Makes the live panes match the tabs: one for the selected tab (rebuilt
  /// when its machine's connection was replaced), the others paused, the least
  /// recently shown ones beyond [PaneHostScreen.maxLive] dropped.
  void _syncSessions() {
    for (final key in _sessions.keys.toList()) {
      final ref = _tabs.tabs.where((t) => t.key == key).firstOrNull;
      if (ref == null ||
          _fleet.connection(ref.machineId) != _sessions[key]!.machine) {
        _drop(key);
      }
    }
    final active = _tabs.active;
    if (active != null) {
      final machine = _fleet.connection(active.machineId);
      if (machine != null && !_sessions.containsKey(active.key)) {
        final vm = PaneViewModel.forMachine(
          machine,
          active.paneId,
          wrap: _settings.wrap,
        );
        _sessions[active.key] = _Session(
          machine,
          vm,
          PaneScreen(
            machine: machine,
            paneId: active.paneId,
            viewModel: vm,
            onSwipe: _swipe,
          ),
        );
      }
      _shownAt[active.key] = ++_shownClock;
    }
    for (final entry in _sessions.entries) {
      final vm = entry.value.viewModel;
      if (entry.key == active?.key) {
        // The wrap setting is global; a pane that was hidden when it changed
        // still reads the old way.
        vm.setWrap(_settings.wrap);
        vm.resume();
      } else {
        vm.pause();
      }
    }
    while (_sessions.length > widget.maxLive) {
      String? oldest;
      for (final key in _sessions.keys) {
        if (key == active?.key) continue;
        if (oldest == null || (_shownAt[key] ?? 0) < (_shownAt[oldest] ?? 0)) {
          oldest = key;
        }
      }
      if (oldest == null) break;
      _drop(oldest);
    }
  }

  void _drop(String key) {
    final session = _sessions.remove(key);
    _shownAt.remove(key);
    if (session == null) return;
    // Its page is still mounted until the next frame.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => session.viewModel.dispose(),
    );
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _openTray() {
    if (_tray.value > 0 && _tray.status != AnimationStatus.reverse) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _tray.duration = Motion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    _tray.forward();
  }

  void _closeTray() {
    if (_tray.isDismissed) return;
    _tray.reverseDuration = Motion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    _tray.reverse();
  }

  void _selectFromTray(String key) {
    HapticFeedback.selectionClick();
    _tabs.activate(key);
    _closeTray();
  }

  void _addFromTray() {
    HapticFeedback.selectionClick();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _swipe(int delta) {
    if (_tabs.step(delta)) HapticFeedback.selectionClick();
  }

  void _toggleWrap() {
    HapticFeedback.selectionClick();
    final next = !_settings.wrap;
    _sessions[_tabs.activeKey]?.viewModel.setWrap(next);
    unawaited(_settings.setWrap(next));
  }

  void _openFiles(MachineConnection machine, String paneId) {
    unawaited(
      openFileBrowser(context, machine, startDir: paneIn(machine, paneId)?.cwd),
    );
  }

  void _showActions(TabInfo info) {
    HapticFeedback.mediumImpact();
    final index = _tabs.indexOfKey(info.key);
    final last = index == _tabs.length - 1;
    unawaited(
      showActionSheet(
        context,
        title: info.title,
        actions: [
          SheetAction(
            label: 'Close tab',
            icon: LucideIcons.x,
            onTap: () => _tabs.close(info.key),
          ),
          if (_tabs.length > 1)
            SheetAction(
              label: 'Close other tabs',
              icon: LucideIcons.listX,
              onTap: () => _tabs.closeOthers(info.key),
            ),
          if (!last)
            SheetAction(
              label: 'Close tabs to the right',
              icon: LucideIcons.arrowRightToLine,
              onTap: () => _tabs.closeToRight(info.key),
            ),
          SheetAction(
            label: 'Copy title',
            icon: LucideIcons.copy,
            onTap: () =>
                unawaited(Clipboard.setData(ClipboardData(text: info.title))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeKey = _tabs.activeKey;
    final active = _tabs.active;
    final session = _sessions[activeKey];
    final trayShown = !_tray.isDismissed;
    final strip = TabStrip(
      tabs: _tabs,
      infos: _infos,
      onOpenTray: _openTray,
      onClose: _tabs.close,
      onActions: _showActions,
    );
    final actions = _BarActions(
      onToggleWrap: session == null ? null : _toggleWrap,
      onOpenFiles: session == null || active == null
          ? null
          : () => _openFiles(session.machine, active.paneId),
      machine: session?.machine,
    );
    final chrome = _Chrome(
      portrait: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PaneTopBar(
            infos: _infos,
            activeKey: activeKey,
            viewModel: session?.viewModel,
            actions: actions,
          ),
          strip,
        ],
      ),
      landscape: _LandscapeBar(
        strip: TabStrip(
          tabs: _tabs,
          infos: _infos,
          onOpenTray: _openTray,
          onClose: _tabs.close,
          onActions: _showActions,
          wide: true,
        ),
        actions: actions,
      ),
    );
    return CompactScope(
      child: PopScope(
        canPop: _tray.isDismissed,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeTray();
        },
        child: Scaffold(
          body: Column(
            children: [
              chrome,
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final entry in _sessions.entries)
                      KeyedSubtree(
                        key: ObjectKey(entry.value),
                        child: _TabPage(
                          active: entry.key == activeKey,
                          child: entry.value.page,
                        ),
                      ),
                    if (activeKey != null && session == null)
                      _MissingMachine(onClose: () => _tabs.close(activeKey)),
                    if (trayShown) _trayOverlay(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The tray over the page: a scrim that closes it, and the tray growing down
  /// from the strip.
  Widget _trayOverlay() => LayoutBuilder(
    builder: (context, box) => Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _closeTray,
          child: AnimatedBuilder(
            animation: _trayCurve,
            builder: (context, _) {
              final scrim = context.ds.scrim;
              return ColoredBox(
                color: scrim.withValues(alpha: scrim.a * _trayCurve.value),
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: SizeTransition(
            sizeFactor: _trayCurve,
            alignment: Alignment.topCenter,
            child: TabsTray(
              tabs: _tabs,
              infos: _infos,
              maxHeight: (MediaQuery.sizeOf(context).height * _trayShare).clamp(
                0.0,
                box.maxHeight,
              ),
              onSelect: _selectFromTray,
              onClose: _tabs.close,
              onAdd: _addFromTray,
              onDismiss: _closeTray,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The chrome above the pane. Portrait: the title block over the strip.
/// On a short screen (landscape), where height is scarce: one row, back, the strip (whose selected
/// chip carries the title) and the buttons. Landscape with the keyboard up
/// ([compactLayout]): none, only the terminal and composer fit.
class _Chrome extends StatelessWidget {
  const _Chrome({required this.portrait, required this.landscape});

  final Widget portrait;
  final Widget landscape;

  @override
  Widget build(BuildContext context) {
    if (compactLayout(context)) return const SizedBox.shrink();
    return MediaQuery.sizeOf(context).height < _shortScreen
        ? landscape
        : portrait;
  }
}

class _LandscapeBar extends StatelessWidget {
  const _LandscapeBar({required this.strip, required this.actions});

  final Widget strip;
  final Widget actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    child: SizedBox(
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: Gap.lg),
          CircleButton(
            icon: LucideIcons.chevronLeft,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: Gap.xs),
          Expanded(child: strip),
          actions,
          const SizedBox(width: Gap.lg),
        ],
      ),
    ),
  );
}

/// A visited tab's pane. Hidden, it stays mounted (keeping its scroll position
/// and draft) but takes no input, paints nothing and runs no tickers.
///
/// It is also laid out at the size it had when it was last shown, not at the
/// size of the screen: while the keyboard animates the shown pane changes size
/// every frame, and a hidden terminal re-laid out each time would cost about as
/// much per frame as the one on screen.
class _TabPage extends StatefulWidget {
  const _TabPage({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage> {
  Size? _shown;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (widget.active || _shown == null) _shown = box.biggest;
      final size = _shown!;
      return Offstage(
        offstage: !widget.active,
        child: TickerMode(
          enabled: widget.active,
          child: ExcludeFocus(
            excluding: !widget.active,
            // The same wrapper whether shown or not, so the pane is never
            // re-parented (which would drop its state).
            child: OverflowBox(
              minWidth: size.width,
              maxWidth: size.width,
              minHeight: size.height,
              maxHeight: size.height,
              child: widget.child,
            ),
          ),
        ),
      );
    },
  );
}

/// The selected tab's machine was removed: nothing to read from. The tab can
/// still be closed.
class _MissingMachine extends StatelessWidget {
  const _MissingMachine({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.serverOff, size: 28, color: ds.textTertiary),
            const SizedBox(height: Gap.md),
            Text(
              'This machine is no longer saved',
              textAlign: TextAlign.center,
              style: Type.row.copyWith(color: ds.text),
            ),
            const SizedBox(height: Gap.lg),
            AppButton(
              label: 'Close tab',
              kind: AppButtonKind.secondary,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// Back, the selected tab's task title with where it lives, a button for the
/// machine's files and the wrap toggle. No bottom border: the strip and the
/// terminal panel below anchor it.
class PaneTopBar extends StatelessWidget {
  const PaneTopBar({
    super.key,
    required this.infos,
    required this.activeKey,
    required this.viewModel,
    required this.actions,
  });

  final ValueListenable<List<TabInfo>> infos;
  final String? activeKey;
  final PaneViewModel? viewModel;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final secondary = Type.secondary.copyWith(color: ds.textSecondary);
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Row(
            children: [
              CircleButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: ValueListenableBuilder<List<TabInfo>>(
                  valueListenable: infos,
                  builder: (context, list, _) {
                    final info = list
                        .where((i) => i.key == activeKey)
                        .firstOrNull;
                    if (info == null) return const SizedBox.shrink();
                    final id = info.ref.paneId;
                    final status = info.status;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            info.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.barTitle.copyWith(color: ds.text),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            // The glyph names the status for screen readers; the
                            // text beside it is not repeated.
                            if (status != null) ...[
                              _TitleGlyph(
                                status: status,
                                live: info.live,
                                viewModel: viewModel,
                              ),
                              const SizedBox(width: 6),
                            ],
                            // The id is short and never cut; the rest gives way.
                            Flexible(
                              child: Text(
                                info.where,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: secondary,
                              ),
                            ),
                            Text(' · $id', maxLines: 1, style: secondary),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: Gap.md),
              actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// The machine's files and the wrap toggle, as the bar shows them.
class _BarActions extends StatelessWidget {
  const _BarActions({
    required this.machine,
    required this.onToggleWrap,
    required this.onOpenFiles,
  });

  final MachineConnection? machine;
  final VoidCallback? onToggleWrap;
  final VoidCallback? onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final files =
        machine != null &&
        machineSupportsFiles(machine!) &&
        onOpenFiles != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (files) ...[
          CircleButton(
            icon: LucideIcons.folderOpen,
            tooltip: 'Browse files',
            onPressed: onOpenFiles,
          ),
          const SizedBox(width: Gap.sm),
        ],
        CircleButton(
          icon: LucideIcons.wrapText,
          tooltip: wrap ? 'Show exact terminal layout' : 'Wrap lines to screen',
          active: wrap,
          onPressed: onToggleWrap,
        ),
      ],
    );
  }
}

/// The status glyph beside the title: dimmed while the machine is down or the
/// last read failed.
class _TitleGlyph extends StatelessWidget {
  const _TitleGlyph({
    required this.status,
    required this.live,
    required this.viewModel,
  });

  final AgentStatus status;
  final bool live;
  final PaneViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final vm = viewModel;
    if (vm == null) return StatusGlyph(status: status, size: 16, dim: !live);
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) =>
          StatusGlyph(status: status, size: 16, dim: !live || vm.isStale),
    );
  }
}
