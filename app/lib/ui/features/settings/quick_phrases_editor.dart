import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/quick_phrases.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/form_sections.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';

/// Settings > Quick phrases: the lines offered as chips above the composers.
/// A row opens the editor sheet (edit, delete); Add opens it empty. Changes
/// apply and are remembered at once.
///
/// Absent when the app runs without the phrases (tests).
class QuickPhrasesSection extends StatelessWidget {
  const QuickPhrasesSection({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.read<QuickPhrases?>() == null) return const SizedBox.shrink();
    final ds = context.ds;
    final phrases = context.select<QuickPhrases, List<String>>((q) => q.phrases);
    final full = phrases.length >= QuickPhrases.maxCount;
    return FormSection(
      label: 'Quick phrases',
      endsWithField: false,
      children: [
        Text(
          'One-tap chips above the message box while it is empty and focused. '
          'A tap fills the box; you still press send.',
          style: Type.secondary.copyWith(color: ds.textSecondary),
        ),
        const SizedBox(height: Gap.sm),
        if (phrases.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(
              'No phrases yet, so no chips.',
              style: Type.secondary.copyWith(color: ds.textMuted),
            ),
          ),
        for (final phrase in phrases)
          _PhraseRow(
            key: ValueKey(phrase),
            phrase: phrase,
            onTap: () => showQuickPhraseEditor(context, editing: phrase),
          ),
        const SizedBox(height: Gap.sm),
        AppButton(
          label: full ? 'List is full (${QuickPhrases.maxCount})' : 'Add a phrase',
          icon: LucideIcons.plus,
          kind: AppButtonKind.secondary,
          expand: true,
          onPressed: full ? null : () => showQuickPhraseEditor(context),
        ),
      ],
    );
  }
}

class _PhraseRow extends StatelessWidget {
  const _PhraseRow({super.key, required this.phrase, required this.onTap});

  final String phrase;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressBuilder(
          onTap: onTap,
          haptic: true,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: pressed ? ds.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    phrase,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.row.copyWith(color: ds.text),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Icon(LucideIcons.pencil, size: 16, color: ds.textTertiary),
              ],
            ),
          ),
        ),
        const Hairline(),
      ],
    );
  }
}

/// Opens the editor sheet for a new phrase, or for [editing] (which it can
/// also delete).
Future<void> showQuickPhraseEditor(BuildContext context, {String? editing}) {
  final phrases = context.read<QuickPhrases>();
  return showAppSheet<void>(
    context,
    builder: (ctx) => QuickPhraseEditor(phrases: phrases, editing: editing),
  );
}

/// The sheet body: one field, Save, and for an existing phrase Delete. Save
/// waits for a phrase [QuickPhrases.problem] accepts and says why not.
class QuickPhraseEditor extends StatefulWidget {
  const QuickPhraseEditor({super.key, required this.phrases, this.editing});

  final QuickPhrases phrases;

  /// The phrase being edited; null for a new one.
  final String? editing;

  @override
  State<QuickPhraseEditor> createState() => _QuickPhraseEditorState();
}

class _QuickPhraseEditorState extends State<QuickPhraseEditor> {
  late final _controller = TextEditingController(text: widget.editing ?? '')
    ..selection = TextSelection.collapsed(offset: (widget.editing ?? '').length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  PhraseProblem? get _problem => widget.phrases.problem(_controller.text, replacing: widget.editing);

  void _save() {
    if (_problem != null) return;
    final editing = widget.editing;
    if (editing == null) {
      widget.phrases.add(_controller.text);
    } else {
      widget.phrases.replace(editing, _controller.text);
    }
    Navigator.of(context).pop();
  }

  void _delete() {
    widget.phrases.remove(widget.editing!);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    // An empty field is not an error yet: Save just waits.
    final shown = _controller.text.trim().isEmpty ? null : problem;
    return Padding(
      // Lifts the sheet over the keyboard.
      padding: EdgeInsets.fromLTRB(
        Gap.gutter,
        Gap.xl,
        Gap.gutter,
        Gap.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              widget.editing == null ? 'New quick phrase' : 'Edit quick phrase',
              style: Type.title.copyWith(color: context.ds.text),
            ),
          ),
          const SizedBox(height: Gap.lg),
          LabeledField(
            label: 'Phrase',
            hint: 'e.g. run the tests',
            controller: _controller,
            autofocus: true,
            helper: shown?.message ?? 'Up to ${QuickPhrases.maxLength} characters, one line.',
            inputFormatters: [LengthLimitingTextInputFormatter(QuickPhrases.maxLength)],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.sm),
          AppButton(label: 'Save', expand: true, onPressed: problem == null ? _save : null),
          if (widget.editing != null) ...[
            const SizedBox(height: Gap.sm),
            AppButton(
              label: 'Delete',
              icon: LucideIcons.trash2,
              kind: AppButtonKind.danger,
              expand: true,
              onPressed: _delete,
            ),
          ],
        ],
      ),
    );
  }
}
