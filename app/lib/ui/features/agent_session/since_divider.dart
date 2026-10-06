import 'package:flutter/widgets.dart';

import '../../core/theme.dart';
import 'transcript_rows.dart';

/// The line above the first thing the person has not seen: a hairline, `6
/// new`, a hairline. It is a row of the list like any other, placed once when
/// the screen opens, so nothing moves when it shows.
class SinceDivider extends StatelessWidget {
  const SinceDivider({super.key, required this.rowKey, required this.label, required this.gap});

  final String rowKey;
  final String label;
  final double gap;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final line = Expanded(child: SizedBox(height: 1, child: ColoredBox(color: ds.border)));
    return Padding(
      padding: EdgeInsets.only(top: gap, bottom: 4),
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              line,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Text(label, maxLines: 1, style: Type.caption.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular)),
              ),
              line,
            ],
          ),
        ),
      ),
    );
  }
}
