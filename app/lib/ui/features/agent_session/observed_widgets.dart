import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/step_clock.dart';
import 'session_select.dart';
import '../../render/visible_text.dart';

/// What the pane shows right now, under the transcript, while the agent works
/// and its log is quiet (the model is writing its next message, which the log
/// only gets when it is finished). Muted, mono, never part of the transcript:
/// the real message replaces it in the list above. Takes no room when the
/// session has nothing to show.
class LiveOutput extends StatelessWidget {
  const LiveOutput({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<List<String>?>(
    session: session,
    select: (s) => s.liveOutput,
    same: (a, b) => a == null || b == null ? a == b : listEquals(a, b),
    builder: (context, rows) {
      if (rows == null || rows.isEmpty) return const SizedBox.shrink();
      final ds = context.ds;
      return Padding(
        padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
        child: Panel(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          child: Semantics(
            label: 'Live output from the terminal',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final row in rows)
                  ExcludeSemantics(
                    child: Text(
                      visibleText(row),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: Mono.small.copyWith(color: ds.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// `Working · 42s` next to the status glyph while the log is quiet: how long
/// the agent has been in this phase, moving by the minute clock (30 s steps),
/// never per second.
class WorkingLabel extends StatelessWidget {
  const WorkingLabel({super.key, required this.since});

  final DateTime? since;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return MinuteBuilder(
      builder: (context, now) {
        final at = since;
        final text = at == null ? 'Working' : 'Working · ${Elapsed.compact(now.difference(at))}';
        return Text(
          text,
          maxLines: 1,
          style: Type.caption.copyWith(color: ds.working, fontFeatures: Type.tabular),
        );
      },
    );
  }
}
