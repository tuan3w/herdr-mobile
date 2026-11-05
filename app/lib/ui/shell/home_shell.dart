import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:provider/provider.dart';

import '../../data/repositories/attention_set.dart';
import '../../data/repositories/fleet_repository.dart';

import 'arrival_cue.dart';
import 'home_pages.dart';
import '../features/agents/agents_screen.dart';

/// Home: the Agents board, with no bar under it. Machines and Settings are
/// pages its header opens ([HomePages]). Why: most of the time the person
/// cares about agents, not machines; the tab bar (Agents, Machines,
/// Settings) cost focus and covered the bottom of the list, so it went
/// (owner decision), and with it the per-tab stacks, scroll controllers,
/// the remembered tab and the Agents badge (the board's status line says the
/// count where the person already looks).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.moveToBackground, this.pages = const HomePages()});

  /// Sends the app to the background (see `TaskMover`). Given, Back at the
  /// root does that instead of leaving the app while agents are watched.
  final Future<bool> Function()? moveToBackground;

  /// Opens Machines and Settings over home, and carries the update for the
  /// gear's dot.
  final HomePages pages;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // The board is picking agents: Back is its own then (it ends the picking),
  // not the app's.
  bool _selecting = false;

  @override
  Widget build(BuildContext context) {
    // The arrival haptic is for an agent that starts waiting, by key: one
    // that was out of reach and is back is not news.
    final (cueNeedsYou, cueWaiting) = context.select<AttentionSet, (Set<String>, Set<String>)>(
      (a) => (a.needsYouKeys, a.waitingKeys),
    );
    final watching =
        widget.moveToBackground != null && context.select<FleetRepository, bool>((f) => f.keepAliveInBackground);
    final shell = Scaffold(
      body: AgentsScreen(pages: widget.pages, onSelectingChanged: (selecting) => _selecting = selecting),
    );
    final cued = ArrivalCue(needsYou: cueNeedsYou, waiting: cueWaiting, child: shell);
    // At the root, while agents are watched, Back leaves the app running, as
    // Home does; finishing the activity would end the connections the
    // "Watching" notice stands for. Machines, Settings and every other pushed
    // route sit above this one and pop as usual. The board's selection mode
    // has its own scope and takes Back first: it is the one that handles it
    // then.
    return PopScope(
      canPop: !watching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _selecting) return;
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
