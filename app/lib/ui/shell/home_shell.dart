import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/fleet_repository.dart';
import '../core/chrome.dart';
import '../features/agents/agents_screen.dart';
import '../features/machines/machines_screen.dart';

/// The two root tabs with a floating tab bar over them. The tab bar gives its
/// own selection haptic.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final needYou = context.select<FleetRepository, int>((f) => f.attentionCount);
    return Scaffold(
      body: Stack(
        children: [
          // Hidden tabs must not keep ticking.
          IndexedStack(
            index: _index,
            children: [
              for (final (i, screen) in const [AgentsScreen(), MachinesScreen()].indexed)
                TickerMode(enabled: i == _index, child: screen),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FloatingTabBar(
              index: _index,
              onChanged: (i) => setState(() => _index = i),
              tabs: [
                TabSpec(icon: LucideIcons.layoutList, label: 'Agents', badge: needYou),
                const TabSpec(icon: LucideIcons.server, label: 'Machines'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
