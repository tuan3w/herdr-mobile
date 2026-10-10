import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/decision/mode_danger.dart';
import '../../../data/decision/session_chips.dart';
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/theme.dart';
import '../composer/composer_frame.dart' show showComposerKeyboard;
import 'session_bar.dart' show showSessionOptions;
import 'session_select.dart';

/// Mode, model, effort and the switches of the session as one quiet row above
/// the composer: up to [maxSessionChips] chips
/// and `+N` for the rest. A tap on a setting opens the options sheet on that
/// setting's choices; a switch (`Fast`) flips in place; `+N` opens the sheet.
///
/// A dangerous mode keeps the danger tint (a triangle and its name, not only
/// the colour) for as long as it is active, so it is the first chip; an
/// elevated one is neutral with a quiet shield. The row takes no room when the
/// agent offers nothing to show, and no tap while the session is not live (the
/// chips still say what it was left in). It selects the options and modes
/// only, so a streaming answer rebuilds nothing here, and the composer leaves
/// it out in the compact layout.
///
/// A pick from the sheet puts the person back in [focus] with the keyboard
/// up: a model or mode is changed to write the next message with it. Only
/// focus already there came back, so a field that had lost it (the chat
/// scrolled, the keyboard put away) left the person tapping it again.
class SessionChipsRow extends StatelessWidget {
  const SessionChipsRow({super.key, required this.session, this.focus});

  final AgentSessionView session;

  /// The message field the chips belong to.
  final FocusNode? focus;

  @override
  Widget build(BuildContext context) => SessionSelect<(List<ConfigOption>, ModeState?, AgentLink)>(
    session: session,
    select: (s) => (s.state.configOptions, s.state.modes, s.link),
    builder: (context, selected) {
      final chips = sessionChipsOf(session.state);
      if (chips.all.isEmpty) return const SizedBox.shrink();
      final live = selected.$3 == AgentLink.live;
      // Danger first: the one chip that must never scroll out of sight.
      final shown = [...chips.shown.where((c) => c.isRisky), ...chips.shown.where((c) => !c.isRisky)];
      final overflow = chips.overflow;
      final more = overflow == 0
          ? null
          : AppChip(
              label: '+$overflow',
              semanticLabel: '$overflow more ${overflow == 1 ? 'setting' : 'settings'}',
              onTap: live ? () => unawaited(_choose(context, session, focus)) : null,
            );
      final maxWidth = AppChip.maxRowWidth(context);
      return SizedBox(
        height: AppChip.height,
        // A few chips, all built (a screen reader meets every one): a Row in a
        // sideways scroll, not a lazy list. Four chips rarely fit a phone's
        // width, so the row scrolls and `+N` stays pinned beside it.
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (i, chip) in shown.indexed) ...[
                      if (i > 0) const SizedBox(width: Gap.sm),
                      // A long label ends in an ellipsis, except a dangerous
                      // mode: its words are the warning, the row scrolls.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: chip.risk == ModeRisk.dangerous ? double.infinity : maxWidth,
                        ),
                        child: _ChipView(chip: chip, session: session, live: live, focus: focus),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (more != null) ...[const SizedBox(width: Gap.sm), more],
          ],
        ),
      );
    },
  );
}

/// The options sheet ([at]: on that chip's choices); a pick sends the person
/// back to the message field with the keyboard up.
Future<void> _choose(BuildContext context, AgentSessionView session, FocusNode? focus, {SessionChip? at}) async {
  final picked = await showSessionOptions(context, session, at: at);
  if (picked && focus != null && context.mounted) showComposerKeyboard(focus);
}

class _ChipView extends StatelessWidget {
  const _ChipView({required this.chip, required this.session, required this.live, this.focus});

  final SessionChip chip;
  final AgentSessionView session;
  final bool live;
  final FocusNode? focus;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    Widget icon(IconData data, Color color) => Icon(data, size: 14, color: color);
    switch (chip.kind) {
      case SessionChipKind.mode:
        return switch (chip.risk) {
          ModeRisk.dangerous => AppChip(
            label: chip.label,
            tint: ds.dangerText,
            leading: icon(LucideIcons.triangleAlert, ds.dangerText),
            semanticLabel: _said('${chip.title}: ${chip.label}, dangerous'),
            onTap: _open(context),
          ),
          ModeRisk.elevated => AppChip(
            label: chip.label,
            leading: icon(LucideIcons.shieldHalf, ds.textSecondary),
            semanticLabel: _said('${chip.title}: ${chip.label}, elevated'),
            onTap: _open(context),
          ),
          ModeRisk.none => AppChip(
            label: chip.label,
            semanticLabel: '${chip.title}: ${chip.label}',
            onTap: _open(context),
          ),
        };
      case SessionChipKind.model:
        return AppChip(
          label: chip.label,
          leading: icon(LucideIcons.cpu, ds.textSecondary),
          semanticLabel: '${chip.title}: ${chip.label}',
          onTap: _open(context),
        );
      case SessionChipKind.effort:
        return AppChip(
          label: chip.label,
          leading: icon(LucideIcons.brain, ds.textSecondary),
          semanticLabel: '${chip.title}: ${chip.label}',
          onTap: _open(context),
        );
      case SessionChipKind.toggle:
        final on = chip.on == true;
        return AppChip(
          label: chip.label,
          selected: on,
          leading: on ? icon(LucideIcons.check, ds.text) : null,
          semanticLabel: '${chip.title}, ${on ? 'on' : 'off'}',
          onTap: live ? () => unawaited(session.setConfigOption(chip.settingId, !on)) : null,
        );
      case SessionChipKind.other:
        return AppChip(label: chip.label, onTap: _open(context));
    }
  }

  /// The words of a risky mode, with why.
  String _said(String head) => chip.reason == null ? head : '$head. ${chip.reason}';

  VoidCallback? _open(BuildContext context) => live ? () => unawaited(_choose(context, session, focus, at: chip)) : null;
}
