import 'package:flutter/material.dart';

import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/step_clock.dart';
import '../../render/visible_text.dart';

/// What the pane shows right now, while the agent works and its log is quiet
/// (the model is writing its next message, which the log only gets when it is
/// finished): the raw tail of the screen, muted and mono, one tap down in the
/// background sheet. Never on the chat screen itself: the status, the tool row
/// and the background strip already say what is going on, and the tail
/// repeated them in a box taller than the answer.
class LiveTail extends StatelessWidget {
  const LiveTail({super.key, required this.rows});

  final List<String> rows;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
      child: Semantics(
        label: 'Live output from the terminal',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Text('On the terminal now', style: Type.caption.copyWith(color: ds.textMuted)),
            ),
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
    );
  }
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
