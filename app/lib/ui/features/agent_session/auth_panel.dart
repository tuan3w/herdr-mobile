import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/auth_needed.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/session_launcher.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../create/session_start_support.dart' show describeLaunchFailure;
import '../agents/agent_navigation.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../render/visible_text.dart';

/// Opens pane [paneId] of [machine] as a terminal.
typedef OpenPane = Future<void> Function(BuildContext context, MachineConnection machine, String paneId);

/// Pushed over the chat, so Back returns to it once the person signed in.
Future<void> _openTerminalPane(BuildContext context, MachineConnection machine, String paneId) =>
    openAgent(context, PaneAgent(machine.profile.id, paneId), view: AgentView.terminal);

/// The agent says it needs a login. The phone runs no login of its own: this
/// says so, names the ways the agent offers, and opens a plain terminal on the
/// machine, in the session's folder, where the person signs in. It never runs
/// a login, types nothing but the quoted `cd` into that folder (for a `~`
/// folder; `SessionLauncher`), and never claims the login worked:
/// after coming back, the next message sent tells (the session clears this
/// panel then, or says again).
///
/// The login hint some agents send (`claude /login`) can be copied to paste
/// into that terminal.
class AuthPanel extends StatefulWidget {
  const AuthPanel({
    super.key,
    required this.session,
    this.launcherFor = SessionLauncher.new,
    this.openPane = _openTerminalPane,
  });

  final AgentSessionView session;

  /// How a terminal is started (a test swaps it).
  final SessionLauncher Function(MachineConnection machine) launcherFor;

  /// How the started terminal is shown (a test swaps it; the app's route
  /// needs providers a test does not have).
  final OpenPane openPane;

  @override
  State<AuthPanel> createState() => _AuthPanelState();
}

class _AuthPanelState extends State<AuthPanel> {
  bool _busy = false;

  AgentSessionView get _session => widget.session;

  Future<void> _openTerminal() async {
    if (_busy) return;
    final machine = _session.machine;
    final folder = _session.cwd.isEmpty ? '~' : _session.cwd;
    setState(() => _busy = true);
    try {
      final launched = await widget
          .launcherFor(machine)
          .launch(LaunchRequest(folder: folder, label: context.l10n.messageSignInTo(_session.agentLabel)));
      if (!mounted) return;
      await widget.openPane(context, machine, launched.paneId);
    } on Exception catch (e) {
      if (mounted) {
        showToast(context, describeLaunchFailure(e, machine, folder).message, kind: ToastKind.failed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copy(String command) => copyText(context, command, what: 'Command copied');

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final need = _session.authNeeded;
    if (need == null) return const SizedBox.shrink();
    final names = [
      for (final m in need.methods)
        if (m.name.isNotEmpty) visibleText(m.name),
    ];
    final command = _command(need);
    final failed = _session.link == AgentLink.failed;
    final machine = visibleText(_session.machine.profile.label);
    // A button is one line: past 1.3x text the machine's name moves to the
    // message and the label shortens, rather than ending in an ellipsis.
    final large = MediaQuery.textScalerOf(context).scale(15) > 19.5;
    return StatusPanel(
      color: ds.blocked,
      icon: LucideIcons.keyRound,
      title: need.keychain
          ? context.l10n.messageNeedsAToken(visibleText(_session.agentLabel))
          : context.l10n.uiSignInOnTheMachine,
      message: [
        visibleText(need.message),
        // Signing in again stores the login in the Keychain again, so the
        // ways the agent lists would lead back here.
        if (need.keychain) ...[
          '1. In a terminal, run $_setupToken and sign in.',
          '2. Add export $_tokenVariable=<the token> to ~/.zshenv.',
          '3. Start a new session.',
        ] else if (names.isNotEmpty)
          'Ways to sign in: ${names.join(' \u00b7 ')}.',
        if (large) context.l10n.messageTerminalOn(machine),
      ].join('\n'),
      messageMaxLines: need.keychain ? 12 : 7,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (command != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Text(
                command,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: Mono.base.copyWith(color: ds.textSecondary),
              ),
            ),
          AppButton(
            label: large ? context.l10n.uiOpenATerminal : context.l10n.messageOpenATerminalOn(machine),
            icon: large ? null : LucideIcons.terminal,
            expand: true,
            loading: _busy,
            onPressed: _openTerminal,
          ),
          if (command != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: AppButton(
                label: context.l10n.uiCopyCommand,
                icon: large ? null : LucideIcons.copy,
                kind: AppButtonKind.secondary,
                expand: true,
                onPressed: () => _copy(command),
              ),
            ),
          // A connection that failed for the login tries again only when
          // asked; a live one clears on the next send.
          if (failed)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: AppButton(
                label: context.l10n.uiRetry,
                kind: AppButtonKind.secondary,
                expand: true,
                onPressed: () => unawaited(_session.reattach()),
              ),
            ),
        ],
      ),
    );
  }

  /// What a Claude Code token is made with, and the variable it is read
  /// from (`claude setup-token`; Claude Code docs, "Authentication").
  static const _setupToken = 'claude setup-token';
  static const _tokenVariable = 'CLAUDE_CODE_OAUTH_TOKEN';

  /// The command to show and copy: the token one when the login is out of
  /// reach in the Keychain, else the login the agent hinted; null when none.
  static String? _command(AuthNeeded need) {
    if (need.keychain) return _setupToken;
    for (final m in need.methods) {
      final c = m.terminalCommand;
      if (m.terminal && c != null && c.trim().isNotEmpty) return visibleText(c.trim());
    }
    return null;
  }
}
