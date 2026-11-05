import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/repositories/app_update.dart';
import '../features/machines/machines_screen.dart';
import '../features/settings/settings_screen.dart';

/// Where the app can send the person on the home screen: the Agents board
/// itself, or one of the two pages its header opens.
enum HomePage { agents, machines, settings }

/// Opens Machines and Settings, the pages reached from the Agents board's
/// header (the machines chip, the gear), from its connection strip and from a
/// link's toast. They are ordinary pages pushed over the board, with Back in
/// their top bars. Why not tabs: most of the time the person cares about
/// agents, not machines, and a tab bar under the board cost focus and covered
/// the bottom of the list (owner decision; the tab bar went with it).
///
/// The app makes one and hands it to the shell and to `DeepLinks`.
@immutable
class HomePages {
  const HomePages({this.update});

  /// Looks for a newer version, for Settings and the gear's dot; null where
  /// the app cannot update itself.
  final AppUpdate? update;

  /// Opens [page] over what is in front, unless it already is in front: a
  /// quick second tap must not stack a second copy. [HomePage.agents] is home
  /// itself and opens nothing.
  void open(BuildContext context, HomePage page) {
    final nav = Navigator.of(context);
    if (page == HomePage.agents || pageInFront(nav) == page) return;
    unawaited(nav.push(_HomePageRoute(page, update)));
  }

  /// Which of [HomePage] is in front of [nav]: [HomePage.agents] when home is,
  /// null when anything else is (an agent, a form, a sheet).
  static HomePage? pageInFront(NavigatorState nav) => switch (topRoute(nav)) {
    final _HomePageRoute r => r.page,
    final Route<dynamic> r when r.isFirst => HomePage.agents,
    _ => null,
  };

  /// Whether [route] is [page]'s own (home for [HomePage.agents]).
  static bool isPage(Route<dynamic> route, HomePage page) => switch (route) {
    final _HomePageRoute r => r.page == page,
    _ => page == HomePage.agents && route.isFirst,
  };
}

/// The route in front of [nav]. `popUntil` with a predicate that holds at
/// once pops nothing; it is the navigator's one way to name its top route.
Route<dynamic>? topRoute(NavigatorState nav) {
  Route<dynamic>? top;
  nav.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

class _HomePageRoute extends MaterialPageRoute<void> {
  _HomePageRoute(this.page, AppUpdate? update)
    : super(
        builder: (_) => switch (page) {
          HomePage.machines => const MachinesScreen(),
          HomePage.settings => SettingsScreen(update: update),
          HomePage.agents => throw StateError('home isn’t a pushed page'),
        },
      );

  final HomePage page;
}
