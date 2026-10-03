import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/open_tabs.dart';
import 'pane_host_screen.dart';

/// Opens [paneId] of [machine] as a tab and shows it.
///
/// One tab screen holds every open tab: when it is already on the navigator
/// this only switches to the tab, so back always returns to where the user
/// came from, once. With [replace] the screen takes the place of the current
/// route (the new-session form).
Future<void> openPaneTab(
  BuildContext context,
  MachineConnection machine,
  String paneId, {
  bool replace = false,
}) async {
  final tabs = context.read<OpenTabs>();
  final hosted = tabs.hostAttached;
  tabs.open(machine.profile.id, paneId, byRecency: !hosted);
  if (hosted) return;
  final route = MaterialPageRoute<void>(builder: (_) => const PaneHostScreen());
  final navigator = Navigator.of(context);
  if (replace) {
    await navigator.pushReplacement(route);
  } else {
    await navigator.push(route);
  }
}
