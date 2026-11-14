import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/quick_phrases.dart';
import '../../../data/repositories/sent_phrases.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../composer/command_model.dart';

/// The person's quick phrases as one row of chips above a composer, for the
/// agent session and the pane alike, and before them the cue chips: `/` (and
/// `$` for an agent whose skills start with it) that put the trigger into the
/// field and open the command palette, so a command does not start with a
/// trip to the keyboard's symbol page ([CommandPaletteModel.cues]).
///
/// Shown only while [focus] is in the composer and [input] is empty: it is the
/// answer to "what do I say to start?", and gets out of the way once there is
/// text (a command is only a command at the start of an empty field). Tapping
/// a chip puts the phrase or the trigger into the composer and leaves the
/// cursor after it; it never sends, the person still presses send.
///
/// The cue chips stand first and pinned at the left, where the thumb finds
/// them without scrolling, while the phrases scroll beside them. It listens to
/// the focus, the text and the commands only,
/// never to the window insets, and takes no room (zero height) when hidden or
/// when there is nothing to show. The compact layout (landscape with the
/// keyboard up) is the caller's to leave out, as for the slash palette.
class QuickPhrasesRow extends StatelessWidget {
  const QuickPhrasesRow({
    super.key,
    required this.input,
    required this.focus,
    this.commands,
    this.padding = EdgeInsets.zero,
  });

  final TextEditingController input;
  final FocusNode focus;

  /// The palette the field feeds; null for a field that has none (tests).
  final CommandPaletteModel? commands;

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
    final model = commands;
    if (phrases.isEmpty && model == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([input, focus, ?model]),
      builder: (context, _) {
        if (!focus.hasFocus || input.text.isNotEmpty) return const SizedBox.shrink();
        final cues = model?.cues ?? const <String>[];
        if (phrases.isEmpty && cues.isEmpty) return const SizedBox.shrink();
        // A longer phrase ends in an ellipsis on its chip; the whole line
        // still goes into the composer.
        final maxWidth = AppChip.maxRowWidth(context);
        final edge = padding.resolve(Directionality.of(context));
        final cueChips = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, cue) in cues.indexed) ...[
              if (i > 0) const SizedBox(width: Gap.sm),
              AppChip(label: cue, semanticLabel: cue == '/' ? 'Commands' : 'Skills', onTap: () => _pick(cue)),
            ],
          ],
        );
        return SizedBox(
          height: AppChip.height,
          child: Row(
            children: [
              if (cues.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(left: edge.left),
                  child: cueChips,
                ),
              if (cues.isNotEmpty && phrases.isNotEmpty) const SizedBox(width: Gap.sm),
              if (phrases.isNotEmpty)
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    // In the session the chips run on under the screen's side
                    // margin instead of stopping at the composer's edge; after
                    // the pinned cues they start at them.
                    clipBehavior: cues.isEmpty ? Clip.none : Clip.hardEdge,
                    padding: cues.isEmpty
                        ? EdgeInsets.only(left: edge.left, right: edge.right)
                        : EdgeInsets.only(right: edge.right),
                    itemCount: phrases.length,
                    separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
                    itemBuilder: (_, i) => ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: AppChip(label: phrases[i], onTap: () => _pick(phrases[i])),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
