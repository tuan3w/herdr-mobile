import 'package:flutter/material.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_api.dart' show HerdrUnsupportedException;
import '../../../data/services/herdr_transport.dart' show HerdrApiException, HerdrTransportException;
import '../../core/chrome.dart';
import '../../core/toast.dart';

/// What the person reads for an agent that reports its session to herdr
/// through [target] (`claude`, `codex`, `omp`).
String _agentName(String target) => switch (target) {
  'claude' => 'Claude Code',
  'codex' => 'Codex',
  _ => target,
};

/// Offers to install herdr's hook for [target] on [machine], which makes the
/// agent report its session so its pane can be read as a chat. Nothing is
/// installed without the tap on the confirm button: the hook is added to the
/// agent's own settings on that machine.
Future<void> showConnectChat(BuildContext context, MachineConnection machine, String paneId, String target) async {
  final name = _agentName(target);
  final home = switch (target) {
    'claude' => '~/.claude',
    'codex' => '~/.codex',
    _ => 'its settings',
  };
  final toaster = Toaster.of(context);
  final ok = await showConfirmSheet(
    context,
    title: 'Set up chat for $name',
    message:
        'The chat needs herdr to know which session this agent runs. This adds herdr\u2019s hook to $home on ${machine.profile.label}. '
        'It applies to sessions started or resumed afterwards: resume this one in its terminal, when it is idle.'
        '${target == 'codex' ? ' Codex asks you to trust the hook the first time.' : ''}',
    confirmLabel: 'Install herdr hook',
    destructive: false,
  );
  if (!ok) return;
  try {
    await machine.api.installIntegration(target);
    toaster.show('Installed on ${machine.profile.label}. Resume the session to read it as a chat.');
  } on HerdrUnsupportedException {
    toaster.show(
      'This herdr is too old to install it. Run herdr integration install $target on the machine.',
      kind: ToastKind.failed,
    );
  } on HerdrApiException catch (e) {
    toaster.show(e.message, kind: ToastKind.failed);
  } on HerdrTransportException catch (e) {
    toaster.show(e.message, kind: ToastKind.failed);
  }
}
