import 'package:flutter/widgets.dart';

import '../theme.dart';

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
      MdTone.quiet => Type.secondary.copyWith(color: ds.textSecondary, height: 1.45),
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

  static TextStyle _codeBlock(Ds ds) => TextStyle(
    fontFamily: monoFamily,
    fontSize: 12.5,
    height: 1.45,
    letterSpacing: 0,
    color: ds.text,
    fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
  );

  /// A heading of [level] (1 to 6).
  TextStyle heading(int level) {
    if (quiet) return body.copyWith(fontWeight: FontWeight.w600, color: ds.text);
    return switch (level) {
      1 => Type.title.copyWith(fontSize: 22, height: 1.25, letterSpacing: -0.5, fontWeight: FontWeight.w700, color: ds.text),
      2 => Type.title.copyWith(fontSize: 18.5, fontWeight: FontWeight.w600, color: ds.text),
      3 => Type.row.copyWith(fontWeight: FontWeight.w600, color: ds.text),
      4 => Type.body.copyWith(fontWeight: FontWeight.w600, color: ds.text),
      _ => Type.body.copyWith(fontWeight: FontWeight.w600, color: ds.textSecondary),
    };
  }

  /// Inline code inside text of style [base]: mono, a notch smaller, on the
  /// quiet fill.
  TextStyle inlineCode(TextStyle base) => TextStyle(
    fontFamily: monoFamily,
    fontSize: (base.fontSize ?? 15) - 1.5,
    letterSpacing: 0,
    fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
    backgroundColor: ds.fill,
  );

  /// Links and tappable paths: the accent, underlined faintly.
  TextStyle get link => TextStyle(
    color: ds.accentText,
    decoration: TextDecoration.underline,
    decorationColor: ds.accentText.withValues(alpha: 0.4),
  );

  /// An image chip: quiet text on the fill, so it never reads as a link.
  TextStyle get imageChip => TextStyle(color: ds.textSecondary, backgroundColor: ds.fill);
}
