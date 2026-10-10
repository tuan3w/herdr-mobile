import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/quick_phrases.dart';
import '../../../data/repositories/sent_phrases.dart';
import '../../core/controls.dart';
import '../../core/tokens.dart';

/// The person's quick phrases as one row of chips above a composer, for the
/// agent session and the pane alike.
///
/// Shown only while [focus] is in the composer and [input] is empty: it is the
/// answer to "what do I say to start?", and gets out of the way once there is
/// text. Tapping a chip puts the phrase into the composer and leaves the
/// cursor after it; it never sends, the person still presses send.
///
/// It listens to the focus and the text only, never to the window insets, and
/// takes no room (zero height) when hidden or when there are no phrases. The
/// compact layout (landscape with the keyboard up) is the caller's to leave
/// out, as for the slash palette.
class QuickPhrasesRow extends StatelessWidget {
  const QuickPhrasesRow({
    super.key,
    required this.input,
    required this.focus,
    this.padding = EdgeInsets.zero,
  });

  final TextEditingController input;
  final FocusNode focus;

  /// Room before the first chip and after the last (the pane's rows run edge
  /// to edge; the session's sit inside the composer's margin).
  final EdgeInsetsGeometry padding;

  /// Replaces the (empty) composer text with [phrase], cursor after it, and
  /// asks for the keyboard: a field that kept its focus while the keyboard
  /// was dismissed needs the explicit request.
  void _pick(String phrase) {
    input.value = TextEditingValue(
      text: phrase,
      selection: TextSelection.collapsed(offset: phrase.length),
    );
    if (focus.hasFocus) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    } else {
      focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final own = context.select<QuickPhrases?, List<String>>((q) => q?.phrases ?? const []);
    final untouched = context.select<QuickPhrases?, bool>((q) => q?.untouched ?? false);
    final sent = context.watch<SentPhrases?>();
    final phrases = quickChips(
      phrases: own,
      untouched: untouched,
      learned: sent?.chips(except: untouched ? const [] : own) ?? const [],
    );
    if (phrases.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([input, focus]),
      builder: (context, _) {
        if (!focus.hasFocus || input.text.isNotEmpty) return const SizedBox.shrink();
        // A longer phrase ends in an ellipsis on its chip; the whole line
        // still goes into the composer.
        final maxWidth = AppChip.maxRowWidth(context);
        return SizedBox(
          height: AppChip.height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // In the session the chips run on under the screen's side margin
            // instead of stopping at the composer's edge.
            clipBehavior: Clip.none,
            padding: padding,
            itemCount: phrases.length,
            separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
            itemBuilder: (_, i) => ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: AppChip(label: phrases[i], onTap: () => _pick(phrases[i])),
            ),
          ),
        );
      },
    );
  }
}
