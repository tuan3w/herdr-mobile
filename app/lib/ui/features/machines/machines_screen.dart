import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../../data/words/plural.dart';
import 'approval_button.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'machine_form_screen.dart';
import 'machine_screen.dart';

class MachinesScreen extends StatelessWidget {
  const MachinesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // Only *which* machines exist decides this list. Connection updates (an
    // agent's status changing on one machine) are heard by that machine's own
    // row, so a busy fleet never rebuilds the rest of the screen.
    return Selector<FleetRepository, List<MachineConnection>>(
      selector: (_, fleet) => fleet.connections,
      shouldRebuild: (a, b) => !listEquals(a, b),
      builder: (context, connections, _) {
        final count = connections.length;
        return Scaffold(
          backgroundColor: ds.bg,
          body: AppRefresh(
            onRefresh: context.read<FleetRepository>().retryAll,
            edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // A page over home, opened from its header: Back returns there.
                SliverLargeTitle.back(
                  title: 'Machines',
                  subtitle: Text(
                    count == 0 ? 'None yet' : countOf(count, 'machine'),
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                  actions: [
                    CircleButton(
                      icon: LucideIcons.plus,
                      tooltip: 'Add machine',
                      onPressed: () => openMachineForm(context),
                    ),
                  ],
                ),
                if (count == 0)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                      child: EmptyState(
                        icon: HerdrIcons.machines,
                        title: 'No machines yet',
                        message:
                            'Add a machine that runs herdr. You can connect as many as '
                            'you like and see them all together.',
                        action: AppButton(
                          label: 'Add machine',
                          icon: LucideIcons.plus,
                          onPressed: () => openMachineForm(context),
                        ),
                      ),
                    ),
                  )
                else ...[
                  SliverList.builder(
                    itemCount: count,
                    itemBuilder: (_, i) =>
                        _MachineRow(key: ValueKey(connections[i].profile.id), machine: connections[i]),
                  ),
                  SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + Gap.xl)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One machine: a flat row with the same metrics as [ListRow]. It is a local
/// row because the status line needs a [LinkDot] and the problem panel sits
/// under the text, neither of which [ListRow] can express.
class _MachineRow extends StatelessWidget {
  const _MachineRow({super.key, required this.machine});

  final MachineConnection machine;

  static const _tile = RowMetrics.leadingExtent;
  static const _gap = RowMetrics.gap;
  static const _inset = PressRow.inset;

  void _open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MachineScreen(machine: machine)));

  Future<void> _remove(BuildContext context, MachineRepository repo) async {
    final p = machine.profile;
    final ok = await showConfirmSheet(
      context,
      title: 'Remove ${p.label}?',
      message:
          'The saved connection and its credentials are deleted from this '
          'phone. Agents on the machine keep running.',
      confirmLabel: 'Remove',
      // Credentials are deleted and cannot be brought back: a hold, not a tap.
      hold: true,
    );
    if (ok) await repo.remove(p.id);
  }

  void _menu(BuildContext context) {
    final repo = context.read<MachineRepository>();
    final p = machine.profile;
    showActionSheet(
      context,
      title: p.label,
      actions: [
        SheetAction(
          label: 'Edit',
          icon: LucideIcons.pencil,
          onTap: () => openMachineForm(context, existing: p),
        ),
        SheetAction(
          label: p.enabled ? 'Disable' : 'Enable',
          icon: p.enabled ? LucideIcons.powerOff : LucideIcons.power,
          onTap: () => repo.save(p.copyWith(enabled: !p.enabled)),
        ),
        SheetAction(label: 'Remove', icon: LucideIcons.trash2, destructive: true, onTap: () => _remove(context, repo)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: machine, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final ds = context.ds;
    final p = machine.profile;
    final state = machine.state;
    // The same "needs you" as the board and the notifications: reachable panes and
    // agent sessions of this machine. An offline machine's last-known waits
    // are not counted; its status line says it is offline.
    final waiting = context.select<AttentionSet, int>((a) => a.needsYouOn(p.id));
    final problem = state == LinkState.attention || state == LinkState.reconnecting;
    final approval = machine.approvalUrl;
    final indent = Gap.gutter + _tile + _gap;

    final semantic = [p.label, state.label, if (waiting > 0) needYou(waiting)].join(', ');

    // "Enable" sits beside the text when there is room, under it on a narrow
    // phone or with large system text (it would squeeze the name to nothing).
    final roomy = MediaQuery.sizeOf(context).width >= 340 && MediaQuery.textScalerOf(context).scale(14) <= 18;
    final enable = AppButton(
      label: 'Enable',
      kind: AppButtonKind.secondary,
      compact: true,
      onPressed: () => context.read<MachineRepository>().save(p.copyWith(enabled: true)),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressRow(
          // A disabled machine has nothing to open: the tap offers the menu,
          // where Enable is.
          onTap: p.enabled ? () => _open(context) : () => _menu(context),
          onLongPress: () => _menu(context),
          semanticLabel: semantic,
          padding: const EdgeInsets.fromLTRB(Gap.gutter - _inset, Gap.md, Gap.gutter - _inset - Gap.sm, Gap.md),
          child: Row(
            children: [
              // The link state is the one thing that tells machines apart
              // at a glance, so it leads the row.
              SizedBox(
                width: _tile,
                child: Center(child: LinkDot(state: state)),
              ),
              const SizedBox(width: _gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      p.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // A machine that is switched off is quiet, not broken:
                      // a softer title, no warning colour, no dimming.
                      style: Type.row.copyWith(color: p.enabled ? ds.text : ds.textSecondary),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.hair),
                      child: _Subtitle(machine: machine),
                    ),
                  ],
                ),
              ),
              // Status as a shape first: the needs-you glyph with its count,
              // as on the board's filter chip (a bare number read as unread).
              if (waiting > 0) ...[
                const SizedBox(width: Gap.sm),
                const StatusGlyph(status: AgentStatus.blocked, size: IconSize.inline),
                const SizedBox(width: Gap.xs),
                Text(waiting > 99 ? '99+' : '$waiting', style: Type.count.copyWith(color: ds.blockedText)),
              ],
              if (!p.enabled && roomy) ...[const SizedBox(width: Gap.sm), enable],
              const SizedBox(width: Gap.xs),
              CircleButton(
                icon: LucideIcons.ellipsis,
                tooltip: 'More options for ${p.label}',
                filled: false,
                size: CircleButton.compact,
                onPressed: () => _menu(context),
              ),
            ],
          ),
        ),
        if (!p.enabled && !roomy)
          Padding(
            padding: EdgeInsets.only(left: indent, right: Gap.gutter, bottom: Gap.md),
            child: Align(alignment: Alignment.centerLeft, child: enable),
          ),
        if (problem && machine.error != null)
          Padding(
            padding: EdgeInsets.only(left: indent, right: Gap.gutter, bottom: Gap.md),
            child: StatusPanel(
              color: state.color(ds),
              message: machine.error,
              messageMaxLines: 3,
              trailing: AppButton(
                label: 'Retry',
                kind: AppButtonKind.secondary,
                compact: true,
                onPressed: machine.retry,
              ),
            ),
          ),
        if (approval != null)
          Padding(
            padding: EdgeInsets.only(left: indent, right: Gap.gutter, bottom: Gap.md),
            child: StatusPanel(
              color: ds.blocked,
              message: 'Tailscale needs you to approve this sign-in.',
              footer: Align(
                alignment: Alignment.centerLeft,
                child: ApprovalButton(url: approval),
              ),
            ),
          ),
        Hairline(indent: indent),
      ],
    );
  }
}

/// The row's second line: how many agents when online, otherwise the state in
/// words; then the address, cut in the middle so its end (the host's
/// domain) and its start (the user and the machine's name) both stay.
class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.machine});

  final MachineConnection machine;

  /// Characters of the address kept whole at its end.
  static const _tailKept = 12;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final p = machine.profile;
    final state = machine.state;
    final agents = machine.agentPanes.length;
    // Only the states that need the person are tinted (with the AA text tone,
    // not the glyph colour); the dot carries the rest.
    final loud = state == LinkState.attention || state == LinkState.approval;
    final lead = state == LinkState.online
        ? (agents == 0 ? 'No agents' : countOf(agents, 'agent'))
        : p.enabled
        ? state.label
        : '${state.label} · not connecting';
    final address = '${p.username}@${p.host}${p.port == 22 ? '' : ':${p.port}'}';
    final style = Type.secondary.copyWith(color: ds.textMuted);
    final leadStyle = loud ? Type.secondaryStrong.copyWith(color: ds.blockedText) : style;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        // The count or state comes first and is cut last; the address gives
        // way from its middle, and goes when even its end has no room.
        final room = box.maxWidth - _width('$lead · ', leadStyle, scaler);
        final shown = middleCut(address, room, (t) => _width(t, style, scaler), tailKept: _tailKept);
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: lead, style: leadStyle),
              if (shown != null) TextSpan(text: ' · $shown', style: style),
            ],
          ),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }

  static double _width(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

/// [text] as it fits [room] by [width]: whole when it fits, else its start
/// and its last [tailKept] characters joined by `…`, keeping as much of the
/// start as fits; null when not even `…` and the end fit.
///
/// One string, measured whole. The address used to be two texts side by
/// side, the start ellipsized in a flexible box: the box kept its full width
/// after the cut, which left a gap before the end (`maya@studio-…   l1a2b.ts.net`).
@visibleForTesting
String? middleCut(String text, double room, double Function(String) width, {required int tailKept}) {
  if (width(text) <= room) return text;
  if (text.length <= tailKept) return null;
  final tail = text.substring(text.length - tailKept);
  if (width('…$tail') > room) return null;
  // The longest start that fits: widths grow with the start's length.
  var lo = 0, hi = text.length - tailKept;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (width('${text.substring(0, mid)}…$tail') <= room) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return '${text.substring(0, lo)}…$tail';
}
