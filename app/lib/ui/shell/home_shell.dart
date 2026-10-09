import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/attention_set.dart';
import '../../data/repositories/fleet_repository.dart';
import '../core/chrome.dart';
import '../core/home_tabs.dart';
import '../core/tokens.dart';
import 'arrival_cue.dart';
import '../core/motion.dart';
import '../features/agents/agents_screen.dart';
import '../features/machines/machines_screen.dart';
import '../features/settings/settings_screen.dart';

/// The three root tabs with a floating tab bar over them. The tab bar gives its
/// own selection haptic.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTab = 0, this.onTabChanged, this.moveToBackground, this.tabs});

  /// The tab shown at first, unless the OS restores another ([HomeTab] order:
  /// 0 Agents, 1 Machines, 2 Settings): the one the app was left on.
  final int initialTab;

  /// Called with the tab the person switched to, to be remembered.
  final ValueChanged<int>? onTabChanged;

  /// Sends the app to the background (see `TaskMover`). Given, Back at the
  /// root does that instead of leaving the app while agents are watched.
  final Future<bool> Function()? moveToBackground;

  /// Selects a tab from outside the shell (a notification tap, a link, a
  /// toast's action), as a tap on the tab bar would.
  final HomeTabs? tabs;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with RestorationMixin, SingleTickerProviderStateMixin {
  static final _agents = HomeTab.agents.index;
  static final _machines = HomeTab.machines.index;
  static final _settings = HomeTab.settings.index;

  // The tab survives the process being reclaimed.
  late final _tab = RestorableInt(widget.initialTab);

  // Machines and Settings are built on first visit, then kept (with their
  // scroll position) like the Agents board. Hidden, they would only add to the
  // first frame, which is the one the person is waiting for.
  bool _machinesOpened = false;
  bool _settingsOpened = false;

  // The Agents board is picking agents for a batch action: its own action bar
  // takes the tab bar's place.
  final _selecting = ValueNotifier<bool>(false);

  // The Agents board's scroll position, for the tab bar's "tap the active tab
  // to go to the top".
  final _agentsScroll = ScrollController();

  // A tab switch fades the incoming content in: opacity only, no slide, and
  // not at all under reduced motion. Rests at 1, so nothing is composited
  // outside the 120 ms of a switch.
  late final _fade = AnimationController(vsync: this, duration: Motion.fade, value: 1);
  late final _opacity = CurvedAnimation(parent: _fade, curve: Motion.easeOut);

  @override
  String get restorationId => 'home';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_tab, 'tab');
  }

  @override
  void initState() {
    super.initState();
    widget.tabs?.attach(current: _current, select: _selectTab);
  }

  @override
  void didUpdateWidget(HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabs == widget.tabs) return;
    oldWidget.tabs?.detach(_selectTab);
    widget.tabs?.attach(current: _current, select: _selectTab);
  }

  @override
  void dispose() {
    widget.tabs?.detach(_selectTab);
    _tab.dispose();
    _selecting.dispose();
    _agentsScroll.dispose();
    _opacity.dispose();
    _fade.dispose();
    super.dispose();
  }

  HomeTab _current() => HomeTab.values[_tab.value];

  void _selectTab(HomeTab tab) => _select(tab.index);

  void _select(int i) {
    if (i == _tab.value) {
      // The tab bar already says "here": no state change, no haptic. On the
      // board it means "back to the top".
      if (i == _agents) _agentsToTop();
      return;
    }
    // From zero before the new tab is built, so it never shows a frame at
    // full opacity first.
    if (!Motion.reduced(context)) _fade.forward(from: 0);
    setState(() => _tab.value = i);
    widget.onTabChanged?.call(i);
  }

  void _agentsToTop() {
    final reduced = Motion.reduced(context);
    for (final p in _agentsScroll.positions) {
      if (p.pixels <= 0) continue;
      if (reduced) {
        p.jumpTo(0);
      } else {
        unawaited(p.animateTo(0, duration: Motion.standard, curve: Motion.easeOut));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // Only what needs an answer and can be given one: the loud colour is for
    // a question, so finished work to review is not in the badge (the board's
    // Done section and the pill carry it). The same set as the pill, the
    // sections, the triage sheet, the Machines tab and the notifications.
    final needsYou = context.select<AttentionSet, int>((a) => a.needsYou.length);
    // The arrival haptic is for an agent that starts waiting, by key: one
    // that was out of reach and is back is not news.
    final (cueNeedsYou, cueWaiting) =
        context.select<AttentionSet, (Set<String>, Set<String>)>((a) => (a.needsYouKeys, a.waitingKeys));
    final index = _tab.value;
    if (index == _machines) _machinesOpened = true;
    if (index == _settings) _settingsOpened = true;
    final watching = widget.moveToBackground != null &&
        context.select<FleetRepository, bool>((f) => f.keepAliveInBackground);
    final shell = Scaffold(
      body: Stack(
        children: [
          // Hidden tabs must not keep ticking, and do not rebuild with the fleet.
          // The incoming tab fades in (see [_fade]); the outgoing one is simply
          // gone, so two tabs never overlap. The Agents list scrolls on the
          // shell's own controller, not the route's primary one that all three
          // tabs would share.
          IndexedStack(
            index: index,
            children: [
              FadeTransition(
                opacity: _opacity,
                child: TickerMode(
                  enabled: index == _agents,
                  child: PrimaryScrollController(
                    controller: _agentsScroll,
                    child: AgentsScreen(
                      onShowMachines: () => _select(_machines),
                      onSelectingChanged: (selecting) => _selecting.value = selecting,
                    ),
                  ),
                ),
              ),
              FadeTransition(
                opacity: _opacity,
                child: TickerMode(
                  enabled: index == _machines,
                  child: _machinesOpened ? const MachinesScreen() : const SizedBox.shrink(),
                ),
              ),
              FadeTransition(
                opacity: _opacity,
                child: TickerMode(
                  enabled: index == _settings,
                  child: _settingsOpened ? const SettingsScreen() : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
          // Rows fade out into the page just above the tab bar and are gone
          // behind it and the system navigation: the scrim is solid under the
          // pill and the gesture inset, so no text shows beside or below the
          // pill. It ends where the triage chip begins (the chip sits at
          // `clearance`): the scrim is drawn above the board, and a taller one
          // dimmed the chip, the one loud shortcut, from its bottom edge up.
          // Picking agents puts the board's own action bar in the tab bar's
          // place.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: FloatingTabBar.clearance(context),
            child: ValueListenableBuilder<bool>(
              valueListenable: _selecting,
              builder: (context, selecting, child) => selecting ? const SizedBox.shrink() : child!,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [ds.bg.withValues(alpha: 0), ds.bg, ds.bg],
                      stops: const [0, 0.5, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: _selecting,
              builder: (context, selecting, child) => selecting ? const SizedBox.shrink() : child!,
              child: FloatingTabBar(
                index: index,
                onChanged: _select,
                tabs: [
                  TabSpec(
                    icon: LucideIcons.bot,
                    label: 'Agents',
                    badge: needsYou,
                    badgeLabel: 'need you',
                  ),
                  const TabSpec(icon: LucideIcons.server, label: 'Machines'),
                  const TabSpec(icon: LucideIcons.settings, label: 'Settings'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    final cued = ArrivalCue(needsYou: cueNeedsYou, waiting: cueWaiting, child: shell);
    // Back on Machines or Settings returns to Agents first. At the root, while
    // agents are watched, Back leaves the app running, as Home does; finishing
    // the activity would end the connections the "Watching" notice stands for.
    // Pushed routes sit above this one and pop as usual. The board's selection
    // mode has its own scope and takes Back first: it is the one that handles
    // it then.
    return PopScope(
      canPop: index == _agents && !watching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (index != _agents) {
          // Selection mode lives on the Agents board; if it is still up
          // (picking, then Machines from the connection strip), its own scope
          // clears it on this same Back.
          _select(_agents);
          return;
        }
        if (_selecting.value) return;
        final away = widget.moveToBackground;
        if (away == null) return;
        away().then((moved) {
          if (!moved) SystemNavigator.pop();
        });
      },
      child: cued,
    );
  }
}
