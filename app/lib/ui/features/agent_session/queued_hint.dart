import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/prompt_queue.dart' show SendDelivery;
import '../../core/motion.dart';
import '../../core/theme.dart';

/// What happens to the message in the field if it is sent now, said before it
/// is sent: it waits for the turn to end (`omp`, `pi`, or anything already
/// waiting) or it goes into the running turn (`Claude Code`, `Codex`). Nothing
/// when it would go out at once.
String? deliveryHint(SendDelivery delivery) => switch (delivery) {
  SendDelivery.now => null,
  SendDelivery.queued => 'Will be queued until the turn ends',
  SendDelivery.steered => 'Goes into the running turn',
};

/// One quiet line above the field with [deliveryHint]; takes no room when
/// [delivery] is null (not working). The line grows and shrinks, no slide
/// under reduced motion.
class DeliveryHint extends StatelessWidget {
  const DeliveryHint({super.key, required this.delivery});

  /// Null: nothing to say.
  final SendDelivery? delivery;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final text = delivery == null ? null : deliveryHint(delivery!);
    return AnimatedSize(
      duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      delivery == SendDelivery.steered ? LucideIcons.cornerDownRight : LucideIcons.clock,
                      size: 12,
                      color: ds.textSecondary,
                    ),
                  ),
                  const SizedBox(width: Gap.xs + 2),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(color: ds.textMuted),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
