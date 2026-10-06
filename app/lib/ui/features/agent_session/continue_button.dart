import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/agent_host.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/toast.dart';
import '../agents/agent_navigation.dart';

/// `Continue` on an ended session whose keeper is gone: starts a new keeper in
/// the session's folder, replays the conversation the agent kept into it
/// ([AgentSessions.resume]) and puts the new chat in place of this one. The
/// spinner shows while the host works; a second tap meanwhile does nothing; a
/// failure is a toast with the host's words and the button is ready again.
class ContinueButton extends StatefulWidget {
  const ContinueButton({super.key, required this.session});

  /// The ended session; its [AgentSessionView.resumeTarget] must be set.
  final AgentSessionView session;

  @override
  State<ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<ContinueButton> {
  bool _busy = false;

  Future<void> _continue() async {
    final target = widget.session.resumeTarget;
    if (_busy || target == null) return;
    final sessions = context.read<AgentSessions>();
    final toaster = Toaster.of(context);
    setState(() => _busy = true);
    try {
      final next = await sessions.resume(
        machine: widget.session.machine,
        agent: target.agent,
        cwd: target.cwd,
        sessionId: target.sessionId,
        replaces: widget.session.key,
      );
      if (!mounted) return;
      unawaited(openAgent(context, SessionAgent(next.key), replace: true));
    } on AgentHostException catch (e) {
      toaster.show(e.message, kind: ToastKind.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppButton(
    label: 'Continue',
    compact: true,
    loading: _busy,
    onPressed: _continue,
  );
}
