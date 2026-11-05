import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/prompt_queue.dart' show SendDelivery;

import 'package:herdr_mobile/ui/core/kit.dart';

/// What happens to the message in the field if it is sent now, said before it
/// is sent: it waits for the turn to end (`pi`, or anything already waiting) or
/// it goes into the running turn (an agent that takes input there: `Claude
/// Code`, `Codex`, `omp` with steering, and any agent in a terminal), where a
/// hold on Send keeps it on the phone and sends it after the turn instead.
/// Nothing when it would go out at once.
String? deliveryHint(SendDelivery delivery) => switch (delivery) {
  SendDelivery.now => null,
  SendDelivery.queued => 'Will be queued until the turn ends',
  SendDelivery.steered => 'Goes into the turn. Hold Send to send it after.',
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
      duration: Motion.of(context, Motion.expand),
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.xs),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      delivery == SendDelivery.steered ? LucideIcons.cornerDownRight : LucideIcons.clock,
                      size: IconSize.inline,
                      color: ds.textSecondary,
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
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
