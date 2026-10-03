import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/herdr_models.dart';
import '../core/status_style.dart';
import '../../data/repositories/fleet_repository.dart';
import '../features/agents/agents_screen.dart';
import '../features/machines/machines_screen.dart';

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
      body: IndexedStack(
        index: _index,
        children: const [AgentsScreen(), MachinesScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i != _index) HapticFeedback.selectionClick();
          setState(() => _index = i);
        },
        destinations: [
          NavigationDestination(
            icon: _AttentionBadge(
              count: needYou,
              child: const Icon(Icons.hub_outlined),
            ),
            selectedIcon: _AttentionBadge(
              count: needYou,
              child: const Icon(Icons.hub_rounded),
            ),
            label: 'Agents',
          ),
          const NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns_rounded),
            label: 'Machines',
          ),
        ],
      ),
    );
  }
}

/// Amber, not error-red: it means "an agent wants you", not "something broke".
class _AttentionBadge extends StatelessWidget {
  const _AttentionBadge({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) => Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: AgentStatus.blocked.color,
        textColor: Colors.black,
        child: child,
      );
}
