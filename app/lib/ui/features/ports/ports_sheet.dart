import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/machine_connection.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/visible_text.dart';
import '../web/web_preview_screen.dart';
import 'ports_view_model.dart';

/// What listens on [machine], live: its TCP ports, one row each, with the
/// process and pid where the machine says them. A tap opens the port as a page
/// in herdr (`WebPreviewScreen`, through the SSH connection); a port that is not
/// a web page (SSH, a database) or is not on `localhost` stays listed, dimmed,
/// with the reason. The sheet watches the machine only while it is open and the
/// app is in front.
Future<void> showPortsSheet(BuildContext context, MachineConnection machine) =>
    showAppSheet<void>(context, builder: (ctx) => PortsSheet(machine: machine));

class PortsSheet extends StatefulWidget {
  const PortsSheet({super.key, required this.machine});

  final MachineConnection machine;

  @override
  State<PortsSheet> createState() => _PortsSheetState();
}

class _PortsSheetState extends State<PortsSheet> with WidgetsBindingObserver {
  late final _vm = PortsViewModel(ports: widget.machine.ports, machineName: widget.machine.profile.label)..start();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Nobody looks while the app is in the background: the host stops watching.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _vm.pause();
    } else if (state == AppLifecycleState.resumed) {
      _vm.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vm.dispose();
    super.dispose();
  }

  void _open(PortRow row) => unawaited(openWebPreview(context, widget.machine, ServerPage(row.url, name: row.process)));

  /// The least the list takes, in rows: the sheet does not open as a sliver
  /// and grow when the answer arrives, and a short list leaves room for the
  /// port that opens next.
  static const _minHeight = 4 * 60.0;

  final _bodyKey = GlobalKey();

  /// The height the list had when its first rows arrived, kept for the life of
  /// the sheet. A bottom sheet grows upward, so a port that opened later would
  /// push every row up under the thumb that is about to tap one: the new row
  /// joins at the end, inside this height, and scrolls in when it does not fit.
  double? _locked;

  void _lock() {
    if (_locked != null || _vm.phase != PortsPhase.live || _vm.rows.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final height = _bodyKey.currentContext?.size?.height;
      if (mounted && _locked == null && height != null) setState(() => _locked = height);
    });
  }

  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: 'Ports',
    kind: SheetKind.list,
    scrolls: true,
    child: ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        _lock();
        final locked = _locked;
        return ConstrainedBox(
          key: _bodyKey,
          constraints: locked == null
              ? const BoxConstraints(minHeight: _minHeight)
              : BoxConstraints.tightFor(height: locked),
          child: _body(context),
        );
      },
    ),
  );

  Widget _body(BuildContext context) {
    final ds = context.ds;
    // The list kind's inset 4 + 12: the rows sit 16 from the edge.
    const side = EdgeInsets.symmetric(horizontal: Gap.md);
    // Rows and panels are laid out in a column, as everywhere in the app: a
    // row handed the sheet's bounded height would stretch to fill it.
    Widget top(Widget child) =>
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [child]);
    Widget note(String text) => top(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg + Gap.xs, vertical: Gap.lg),
        child: Text(text, style: Type.secondary.copyWith(color: ds.textSecondary)),
      ),
    );
    switch (_vm.phase) {
      case PortsPhase.loading:
        return note('Looking for open ports…');
      case PortsPhase.unsupported:
        final why = _vm.unsupported!;
        return top(
          Padding(
            padding: side,
            child: ListRow(
              leading: const IconTile(icon: LucideIcons.plugZap),
              leadingOnTitle: false,
              title: why.helperMissing
                  ? 'Needs the agent helper on this machine.'
                  : 'Can’t list ports on this machine.',
              subtitle: why.helperMissing ? null : visibleText(why.reason),
              subtitleMaxLines: 3,
              dim: true,
            ),
          ),
        );
      case PortsPhase.failed:
        return top(
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
            child: StatusPanel(
              color: ds.danger,
              icon: LucideIcons.circleAlert,
              title: 'Couldn’t list the ports',
              message: _vm.error,
              messageMaxLines: 4,
              trailing: AppButton(label: 'Retry', kind: AppButtonKind.secondary, compact: true, onPressed: _vm.retry),
            ),
          ),
        );
      case PortsPhase.live:
        final rows = _vm.rows;
        if (rows.isEmpty) return note('Nothing is listening on this machine.');
        return ListView.builder(
          shrinkWrap: _locked == null,
          padding: side,
          itemCount: rows.length,
          itemBuilder: (context, i) => _PortTile(row: rows[i], divider: i < rows.length - 1, onTap: _open),
        );
    }
  }
}

/// One port: the process (else `Port 3000`), under it where it listens, its pid
/// and, when a tap would do nothing, why.
class _PortTile extends StatelessWidget {
  const _PortTile({required this.row, required this.divider, required this.onTap});

  final PortRow row;
  final bool divider;
  final ValueChanged<PortRow> onTap;

  @override
  Widget build(BuildContext context) {
    final reason = row.reason;
    final tile = ListRow(
      leading: const IconTile(icon: HerdrIcons.madeServer),
      leadingOnTitle: false,
      title: visibleText(row.title),
      subtitle: row.subtitle,
      // The reason is the answer, not a detail: it wraps instead of being cut,
      // even at large text on a narrow phone.
      subtitleMaxLines: 3,
      dim: reason != null,
      onTap: reason == null ? () => onTap(row) : null,
    );
    if (!divider) return tile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        Hairline(indent: ListRow.textIndent()),
      ],
    );
  }
}
