import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_api.dart' show HerdrUnsupportedException;
import '../../../data/services/herdr_transport.dart' show HerdrApiException, HerdrTransportException;
import '../../../data/words/agent_names.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Offers to install herdr's hook for [target] on [machine], which makes the
/// agent report its session so its pane can be read as a chat. Nothing is
/// installed without the tap on the confirm button: the hook is added to the
/// agent's own settings on that machine.
Future<void> showConnectChat(BuildContext context, MachineConnection machine, String paneId, String target) async {
  final words = context.l10n;
  final name = agentName(target);
  final home = switch (target) {
    'claude' => '~/.claude',
    'codex' => '~/.codex',
    _ => 'its settings',
  };
  final toaster = Toaster.of(context);
  final ok = await showConfirmSheet(
    context,
    title: words.messageSetUpChatFor(name),
    message: words.messageTheChatNeedsHerdrToKnowWhichSession(
      home,
      machine.profile.label,
      target == 'codex' ? words.uiCodexAsksYouToTrustTheHookTheFirst : '',
    ),
    confirmLabel: words.uiInstallHerdrHook,
    destructive: false,
  );
  if (!ok) return;
  try {
    await machine.api.installIntegration(target);
    toaster.show(words.messageInstalledOnResumeTheSessionToReadIt(machine.profile.label));
  } on HerdrUnsupportedException {
    toaster.show(words.messageThisHerdrIsTooOldToInstallIt(target), kind: ToastKind.failed);
  } on HerdrApiException catch (e) {
    toaster.show(e.message, kind: ToastKind.failed);
  } on HerdrTransportException catch (e) {
    toaster.show(e.message, kind: ToastKind.failed);
  }
}
