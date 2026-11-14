import 'package:flutter/widgets.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// How loud a Markdown surface reads.
enum MdTone {
  /// An answer, a file: the primary text colour and body size.
  reading,

  /// Reasoning and other asides: the secondary size and colour.
  quiet,

  /// Inside a block quote: body size, supporting colour.
  quote,
}

/// Provides the [MdTone] of every Markdown block below it. Without one the
/// tone is [MdTone.reading].
class MdToneScope extends InheritedWidget {
  const MdToneScope({super.key, required this.tone, required super.child});

  final MdTone tone;

  static MdTone of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MdToneScope>()?.tone ?? MdTone.reading;

  @override
  bool updateShouldNotify(MdToneScope oldWidget) => tone != oldWidget.tone;
}

/// The text styles of one tone under the current theme: all from `Type.*`.
@immutable
final class MdStyles {
  const MdStyles._(this.tone, this.ds, this.body, this.codeBlock);

  factory MdStyles.of(BuildContext context, [MdTone? tone]) {
    final t = tone ?? MdToneScope.of(context);
    final ds = context.ds;
    final body = switch (t) {
      MdTone.reading => Type.body.copyWith(color: ds.text),
      MdTone.quote => Type.body.copyWith(color: ds.textSecondary),
      MdTone.quiet => Type.secondary.copyWith(color: ds.textSecondary, height: Type.body.height),
    };
    return MdStyles._(t, ds, body, _codeBlock(ds));
  }

  final MdTone tone;
  final Ds ds;

  /// Paragraph, list item and table cell text.
  final TextStyle body;

  /// A line of a fenced block (the colour is the plain-text colour of the
  /// block; the highlighter overrides it per token).
  final TextStyle codeBlock;

  bool get quiet => tone == MdTone.quiet;

  static TextStyle _codeBlock(Ds ds) => Mono.base.copyWith(color: ds.text);

  /// A heading of [level] (1 to 6).
  TextStyle heading(int level) {
    // Quiet text is 13.5 w400: its heading is the same size at w600 (the table
    // header's role), so the step is weight, not a size jump in a small panel.
    if (quiet) return Type.buttonCompact.copyWith(height: body.height, color: ds.text);
    return switch (level) {
      1 => Type.h1.copyWith(color: ds.text),
      2 => Type.h2.copyWith(color: ds.text),
      3 => Type.h3.copyWith(color: ds.text),
      4 => Type.bodyStrong.copyWith(color: ds.text),
      _ => Type.bodyStrong.copyWith(color: ds.textSecondary),
    };
  }

  /// Inline code inside text of style [base]: mono, a notch (1.5) smaller than
  /// the text around it, on the quiet [Ds.textChip]. Relative, not [Mono.base]: a fixed
  /// 12.5 is tiny in a heading and the same size as quiet 13.5 text.
  TextStyle inlineCode(TextStyle base) => Mono.base.copyWith(
    // design-lint: allow(raw-type) inline code follows the size of the text it sits in
    fontSize: (base.fontSize ?? Type.body.fontSize!) - 1.5,
    height: base.height,
    backgroundColor: ds.textChip,
  );

  /// Links and tappable paths: the accent, underlined faintly.
  TextStyle get link {
    // design-lint: allow(raw-type) colour-only overlay merged onto the text it sits in
    return TextStyle(color: ds.accentText, decoration: TextDecoration.underline, decorationColor: ds.linkUnderline);
  }

  /// An image chip: quiet text on the chip fill, so it never reads as a link.
  // design-lint: allow(raw-type) colour-only overlay merged onto the text it sits in
  TextStyle get imageChip => TextStyle(color: ds.textSecondary, backgroundColor: ds.textChip);
}
