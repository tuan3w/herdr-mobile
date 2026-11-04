import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/quick_phrases.dart';
import '../../../data/repositories/sent_phrases.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Settings > Agents > Quick phrases: its own page, because the list grows
/// with the person (up to [QuickPhrases.maxCount]) and would stretch the group
/// it belongs to.
class QuickPhrasesPage extends StatelessWidget {
  const QuickPhrasesPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.ds.bg,
    body: CustomScrollView(
      slivers: [
        SliverLargeTitle.back(title: context.l10n.uiQuickPhrases),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + Gap.lg),
            child: const QuickPhrasesSection(),
          ),
        ),
      ],
    ),
  );
}

/// The lines offered as chips above the composers. A row opens the editor
/// sheet (edit, delete); Add opens it empty. Changes apply and are remembered
/// at once.
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
    final sent = context.watch<SentPhrases?>();
    return FormPanel(
      endsWithField: false,
      children: [
        Text(
          context.l10n.uiOneTapChipsAboveTheMessageBoxWhileIt,
          style: Type.secondary.copyWith(color: ds.textSecondary),
        ),
        const SizedBox(height: Gap.sm),
        if (phrases.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(context.l10n.uiNoPhrasesYetSoNoChips, style: Type.secondary.copyWith(color: ds.textMuted)),
          ),
        for (final phrase in phrases)
          _PhraseRow(
            key: ValueKey(phrase),
            phrase: phrase,
            onTap: () => showQuickPhraseEditor(context, editing: phrase),
          ),
        const SizedBox(height: Gap.sm),
        AppButton(
          label: full ? context.l10n.messageListIsFull('${QuickPhrases.maxCount}') : context.l10n.uiAddAPhrase,
          icon: LucideIcons.plus,
          kind: AppButtonKind.secondary,
          expand: true,
          onPressed: full ? null : () => showQuickPhraseEditor(context),
        ),
        if (sent != null) ...[
          const SizedBox(height: Gap.md),
          SwitchRow(
            title: context.l10n.uiAddWhatISendMost,
            subtitle: context.l10n.uiAMessageToAnAgentThatYouSentAt,
            value: sent.enabled,
            onChanged: (on) => unawaited(sent.setEnabled(on)),
          ),
          if (sent.tracked > 0)
            AppButton(
              label: context.l10n.messageForgetRemembered('${sent.tracked}', plural(sent.tracked, 'message')),
              kind: AppButtonKind.secondary,
              expand: true,
              // Not recoverable (the counts are gone), and one tap forgets all
              // of them: a confirmation with the number, not an Undo.
              onPressed: () => unawaited(_forget(context, sent)),
            ),
        ],
      ],
    );
  }
}

Future<void> _forget(BuildContext context, SentPhrases sent) async {
  final n = sent.tracked;
  final ok = await showConfirmSheet(
    context,
    title: context.l10n.messageForgetRemembered30('$n', plural(n, 'message')),
    message: context.l10n.uiTheMessagesLearnedFromWhatYouSendAreDeleted,
    confirmLabel: context.l10n.uiForget,
  );
  if (ok) await sent.forget();
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
        PressRow(
          onTap: () {
            Haptics.tick();
            onTap();
          },
          minHeight: _rowHeight,
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
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
              Icon(LucideIcons.pencil, size: IconSize.row, color: ds.textTertiary),
            ],
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
    final phrase = widget.editing!;
    final phrases = widget.phrases;
    // Taken before the sheet closes: its context is gone when Undo is pressed.
    final toaster = Toaster.of(context);
    unawaited(phrases.remove(phrase));
    Navigator.of(context).pop();
    // Undo appends: the list has no way to put a phrase back at its place.
    toaster.show(context.l10n.uiPhraseDeleted, action: ToastAction('Undo', () => unawaited(phrases.add(phrase))));
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    // An empty field is not an error yet: Save just waits.
    final shown = _controller.text.trim().isEmpty ? null : problem;
    return SheetScaffold(
      title: widget.editing == null ? context.l10n.uiNewQuickPhrase : context.l10n.uiEditQuickPhrase,
      kind: SheetKind.form,
      actions: [
        AppButton(label: context.l10n.uiSave, expand: true, onPressed: problem == null ? _save : null),
        if (widget.editing != null)
          AppButton(
            label: context.l10n.uiDelete,
            icon: LucideIcons.trash2,
            kind: AppButtonKind.danger,
            expand: true,
            onPressed: _delete,
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: LabeledField(
          label: context.l10n.uiPhrase,
          prose: true,
          hint: context.l10n.uiEGRunTheTests,
          controller: _controller,
          autofocus: true,
          helper: shown?.message ?? 'Up to ${QuickPhrases.maxLength} characters, one line.',
          inputFormatters: [LengthLimitingTextInputFormatter(QuickPhrases.maxLength)],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }
}

/// A phrase row: one line of text with room for its handle.
const _rowHeight = 48.0;
