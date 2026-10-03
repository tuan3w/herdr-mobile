import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/fleet_repository.dart';
import '../core/chrome.dart';
import '../core/tokens.dart';
import '../features/agents/agents_screen.dart';
import '../features/machines/machines_screen.dart';
import '../features/settings/settings_screen.dart';

/// The three root tabs with a floating tab bar over them. The tab bar gives its
/// own selection haptic.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTab = 0, this.onTabChanged});

  /// The tab shown at first, unless the OS restores another (0 Agents,
  /// 1 Machines, 2 Settings): the one the app was left on.
  final int initialTab;

  /// Called with the tab the person switched to, to be remembered.
  final ValueChanged<int>? onTabChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with RestorationMixin {
  static const _agents = 0;
  static const _machines = 1;
  static const _settings = 2;

  // The tab survives the process being reclaimed.
  late final _tab = RestorableInt(widget.initialTab);

  // Settings is the quietest tab: built on first visit, then kept (with its
  // scroll position) like the others.
  bool _settingsOpened = false;

  @override
  String get restorationId => 'home';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_tab, 'tab');
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _select(int i) {
    setState(() => _tab.value = i);
    widget.onTabChanged?.call(i);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final needYou = context.select<FleetRepository, int>((f) => f.attentionCount);
    final index = _tab.value;
    if (index == _settings) _settingsOpened = true;
    return Scaffold(
      body: Stack(
        children: [
          // Hidden tabs must not keep ticking, and do not rebuild with the fleet.
          IndexedStack(
            index: index,
            children: [
              TickerMode(
                enabled: index == _agents,
                child: AgentsScreen(onShowMachines: () => _select(_machines)),
              ),
              TickerMode(enabled: index == _machines, child: const MachinesScreen()),
              TickerMode(
                enabled: index == _settings,
                child: _settingsOpened ? const SettingsScreen() : const SizedBox.shrink(),
              ),
            ],
          ),
          // Rows fade out into the page instead of being cut off behind the
          // tab bar and the gesture inset.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: FloatingTabBar.clearance(context),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [ds.bg.withValues(alpha: 0), ds.bg],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FloatingTabBar(
              index: index,
              onChanged: _select,
              tabs: [
                TabSpec(icon: LucideIcons.layoutList, label: 'Agents', badge: needYou),
                const TabSpec(icon: LucideIcons.server, label: 'Machines'),
                const TabSpec(icon: LucideIcons.settings, label: 'Settings'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
