import 'package:flutter/foundation.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/open_tabs.dart';

/// What the tab strip, the tray and the top bar show about one tab. Built from
/// the machine's snapshot; equal infos mean nothing visible changed.
@immutable
class TabInfo {
  const TabInfo({
    required this.ref,
    required this.title,
    required this.agent,
    required this.machineLabel,
    required this.status,
    required this.live,
    required this.gone,
    required this.since,
  });

  /// The tab as the snapshot shows it now. [known] is what it said last, used
  /// when the pane (or its whole machine) has vanished, so the tab keeps its
  /// name and can still be closed.
  factory TabInfo.of(TabRef ref, MachineConnection? machine, {TabInfo? known}) {
    final pane = machine?.paneById(ref.paneId);
    if (pane == null) {
      return TabInfo(
        ref: ref,
        title: known?.title ?? ref.paneId,
        agent: known?.agent,
        machineLabel:
            machine?.profile.label ?? known?.machineLabel ?? ref.machineId,
        status: null,
        // A machine that answers and has no such pane is not "stale", it is
        // closed; a machine that does not answer cannot say.
        live: machine?.isLive ?? false,
        gone: true,
        since: null,
      );
    }
    final task = pane.title.trim();
    return TabInfo(
      ref: ref,
      title: task.isNotEmpty ? task : (pane.agent ?? ref.paneId),
      agent: pane.agent,
      machineLabel: machine!.profile.label,
      status: pane.status,
      live: machine.isLive,
      gone: false,
      since: machine.statusSince(ref.paneId),
    );
  }

  final TabRef ref;

  /// The task the agent is on; the agent, then the pane id, when it has none.
  final String title;
  final String? agent;
  final String machineLabel;

  /// Null when the pane is gone.
  final AgentStatus? status;

  /// Its machine is online (a snapshot that may be old is not live).
  final bool live;

  /// herdr no longer has the pane, or the machine was removed.
  final bool gone;

  /// When the status was last seen to change; null if never observed.
  final DateTime? since;

  String get key => ref.key;

  /// `agent · machine`, the agent left out when it is the title.
  String get where =>
      [if (agent != null && agent != title) agent!, machineLabel].join(' · ');

  /// `working 12m`: the state and how long it has lasted, as far as it is
  /// known. Null for a pane that is gone. A machine that is not online cannot
  /// say what the pane is doing now (the snapshot is from the last time it
  /// did), so the tab says `offline` instead of passing an old state off as
  /// current.
  String? stateText(DateTime now) {
    final status = this.status;
    if (status == null) return null;
    if (!live) return 'offline';
    final word = switch (status) {
      AgentStatus.blocked => 'needs you',
      AgentStatus.working => 'working',
      AgentStatus.done => 'done',
      AgentStatus.idle => 'idle',
      AgentStatus.unknown => 'unknown',
    };
    final since = this.since;
    if (since == null) return word;
    return '$word ${shortAge(now.difference(since))}';
  }

  @override
  bool operator ==(Object other) =>
      other is TabInfo &&
      other.ref == ref &&
      other.title == title &&
      other.agent == agent &&
      other.machineLabel == machineLabel &&
      other.status == status &&
      other.live == live &&
      other.gone == gone &&
      other.since == since;

  @override
  int get hashCode =>
      Object.hash(ref, title, agent, machineLabel, status, live, gone, since);
}

/// `<1m`, `12m`, `3h`, `2d`: one unit, coarse.
String shortAge(Duration d) {
  if (d.inMinutes < 1) return '<1m';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  return '${d.inDays}d';
}
