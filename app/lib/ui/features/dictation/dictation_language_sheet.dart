import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/services/dictation.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// The languages offered, from what the phone's speech service has: English and
/// Vietnamese always have a row (dimmed, with the reason, when the phone lacks
/// them), the language already chosen keeps its row, and the phone's own
/// language is the first choice.
List<({String? id, String label, String? missing})> dictationChoices(
  List<DictationLanguage> available,
  String? chosen,
) {
  DictationLanguage? find(bool Function(String id) test) {
    for (final l in available) {
      if (test(l.id.toLowerCase().replaceAll('-', '_'))) return l;
    }
    return null;
  }

  final en = find((id) => id == 'en_us') ?? find((id) => id.startsWith('en'));
  final vi = find((id) => id.startsWith('vi'));
  final other = chosen == null || (en?.id == chosen) || (vi?.id == chosen)
      ? null
      : available.where((l) => l.id == chosen).firstOrNull;
  const missing = 'Not in this phone’s speech service';
  return [
    (id: null, label: 'Phone’s language', missing: null),
    (id: en?.id, label: 'English', missing: en == null ? missing : null),
    (id: vi?.id, label: 'Tiếng Việt', missing: vi == null ? missing : null),
    if (other != null) (id: other.id, label: other.name, missing: null),
  ];
}

/// A long press on the mic: which language to listen in. One list, the choice
/// is kept and shows with a check.
Future<void> showDictationLanguageSheet(BuildContext context, Dictation dictation) async {
  final available = await dictation.languages();
  if (!context.mounted) return;
  if (available.isEmpty) {
    showToast(context, DictationProblem.unavailable.message, kind: ToastKind.failed);
    return;
  }
  final chosen = dictation.languageId;
  final choices = dictationChoices(available, chosen);
  unawaited(
    showAppSheet<void>(
      context,
      builder: (ctx) {
        final ds = ctx.ds;
        return SheetScaffold(
          title: context.l10n.uiDictateIn,
          kind: SheetKind.list,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in choices)
                SheetActionRow(
                  action: SheetAction(
                    label: c.label,
                    icon: c.id == chosen ? LucideIcons.check : LucideIcons.languages,
                    unavailable: c.missing,
                    onTap: () {},
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(dictation.setLanguage(c.id));
                  },
                ),
              Padding(
                padding: const EdgeInsets.only(left: Gap.lg, top: Gap.sm, right: Gap.lg),
                child: Text(
                  context.l10n.uiOneLanguageAtATimeThePhoneSSpeech,
                  style: Type.caption.copyWith(color: ds.textSecondary),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
