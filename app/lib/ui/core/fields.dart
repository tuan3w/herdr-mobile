import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Text field with its label above (Linear-style) instead of Material's
/// floating label.
///
/// The field is named for screen readers by [label] (the visible text is
/// excluded from semantics so it is not read twice), and one line below it is
/// always reserved for [helper] / validation text, so an error appearing never
/// shifts the fields underneath.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.validator,
    this.obscure = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.mono = false,
    this.onChanged,
    this.inputFormatters,
    this.enabled = true,
    this.restorationId,
    this.autofocus = false,
    this.onSubmitted,
    this.prose = false,
    this.autofillHints,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final FormFieldValidator<String>? validator;
  final bool obscure;
  final int minLines;
  final int maxLines;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool mono;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  /// Persist the text across process death (state restoration). Leave null for
  /// secrets: restoration data is not protected storage.
  final String? restorationId;

  /// Takes focus (and the keyboard) as soon as it is shown.
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  /// Words the person writes for people or an agent (a message, a name): the
  /// keyboard corrects, suggests and capitalises sentences. Off for hosts,
  /// paths, keys and search, where a "fix" corrupts the value.
  final bool prose;

  /// Lets a password manager fill the field; wrap related fields in an
  /// [AutofillGroup].
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text(label, style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        Semantics(
          label: label,
          child: TextFormField(
            controller: controller,
            restorationId: restorationId,
            autofocus: autofocus,
            onFieldSubmitted: onSubmitted,
            enabled: enabled,
            obscureText: obscure,
            minLines: obscure ? 1 : minLines,
            maxLines: obscure ? 1 : maxLines,
            validator: validator,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            onChanged: onChanged,
            inputFormatters: inputFormatters,
            autocorrect: prose,
            enableSuggestions: prose,
            textCapitalization: prose ? TextCapitalization.sentences : TextCapitalization.none,
            autofillHints: autofillHints,
            style: (mono ? Mono.input : Type.input).copyWith(color: ds.text),
            cursorColor: ds.accent,
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: suffix,
              // A blank helper keeps one line reserved for the error text.
              helperText: helper ?? ' ',
              helperMaxLines: 3,
              helperStyle: Type.caption.copyWith(color: ds.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}
