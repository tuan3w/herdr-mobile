import 'package:flutter/foundation.dart';

/// The home screen's root tabs, in tab-bar order.
enum HomeTab { agents, machines, settings }

/// Selects a root tab from outside the home shell: a notification tap, a link,
/// a toast's action. The app makes one and hands it to the shell and to
/// whatever needs to turn the home screen to a tab; the shell attaches itself
/// while it is up and does the switch as a tap on the tab bar would (fade,
/// remembered as the tab the app was left on).
class HomeTabs {
  _Shell? _shell;

  /// The tab the shell shows, or null while no shell is up.
  HomeTab? get current => _shell?.current();

  /// Shows [tab]. Nothing happens when it is already showing (a tap on the
  /// active tab would scroll the board to the top; this does not move it).
  void select(HomeTab tab) {
    final shell = _shell;
    if (shell == null || shell.current() == tab) return;
    shell.select(tab);
  }

  /// For the shell: [current] reads its tab, [select] switches it.
  void attach({required HomeTab Function() current, required ValueChanged<HomeTab> select}) =>
      _shell = (current: current, select: select);

  /// For the shell, when it goes. A shell that is not the attached one (an
  /// older one being replaced) changes nothing.
  void detach(ValueChanged<HomeTab> select) {
    if (_shell?.select == select) _shell = null;
  }
}

typedef _Shell = ({HomeTab Function() current, ValueChanged<HomeTab> select});
