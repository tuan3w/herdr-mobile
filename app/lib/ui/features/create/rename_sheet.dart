import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Asks for a new name in a sheet. Returns the trimmed text, or null when
/// dismissed. With [allowEmpty] an empty name is a valid answer (it clears the
/// name); otherwise Save waits for some text.
Future<String?> showRenameSheet(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? helper,
  bool allowEmpty = false,
}) => showAppSheet<String>(
  context,
  builder: (ctx) => _RenameBody(title: title, label: label, initial: initial, helper: helper, allowEmpty: allowEmpty),
);

class _RenameBody extends StatefulWidget {
  const _RenameBody({
    required this.title,
    required this.label,
    required this.initial,
    required this.helper,
    required this.allowEmpty,
  });

  final String title;
  final String label;
  final String initial;
  final String? helper;
  final bool allowEmpty;

  @override
  State<_RenameBody> createState() => _RenameBodyState();
}

class _RenameBodyState extends State<_RenameBody> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _valid => widget.allowEmpty || _controller.text.trim().isNotEmpty;

  void _save() {
    if (_valid) Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: widget.title,
    kind: SheetKind.form,
    actions: [AppButton(label: context.l10n.uiSave, expand: true, onPressed: _valid ? _save : null)],
    child: Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: LabeledField(
        label: widget.label,
        controller: _controller,
        helper: widget.helper,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        onChanged: (_) => setState(() {}),
      ),
    ),
  );
}
