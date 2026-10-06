import 'package:flutter/material.dart';

/// Design tokens.
///
/// The look is deliberately not Material: flat rows instead of cards, one
/// accent, hairlines instead of elevation, status by shape as well as colour,
/// and type doing the hierarchy. Light is "paper" (warm, Notion-like); dark is
/// "ink" (cool near-black, Linear-like). See `docs/DESIGN.md`.
@immutable
class Ds extends ThemeExtension<Ds> {
  const Ds({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.fill,
    required this.fillPressed,
    required this.hairline,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textTertiary,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.scrim,
    required this.blocked,
    required this.working,
    required this.done,
    required this.danger,
    required this.blockedText,
    required this.dangerText,
  });

  final Brightness brightness;

  /// Page background.
  final Color bg;

  /// Raised surface: sheets, inputs, the floating tab bar.
  final Color surface;

  /// Quiet fill for chips, tiles and the selected segment.
  final Color fill;
  final Color fillPressed;

  /// 1px dividers and outlines.
  final Color hairline;

  final Color text;

  /// Three text tiers (ratios in `docs/DESIGN.md`): [text] primary,
  /// [textSecondary] supporting copy and unselected navigation,
  /// [textMuted] meta lines, counts, helper text and placeholders. All three
  /// reach 4.5:1 on [bg], [surface] and [fill].
  final Color textSecondary;
  final Color textMuted;

  /// Icons, status rings, chevrons and decoration only (>= 3:1 on [bg]). Never
  /// text: it does not reach 4.5:1.
  final Color textTertiary;

  /// Input outline (~1.5:1): stronger than [hairline], which is a divider.
  final Color border;

  /// The one accent. Fills (primary button) use [accent] with [onAccent] text;
  /// accent-coloured text and icons use [accentText] for contrast.
  final Color accent;
  final Color onAccent;
  final Color accentText;

  final Color scrim;

  /// Agent / link status colours: fills, rings and icons (>= 3:1 on [bg]).
  final Color blocked;
  final Color working;
  final Color done;
  final Color danger;

  /// Status colours as TEXT: >= 4.5:1 on [bg], [surface] and on their own
  /// 12% tints. Use for "Needs attention", error messages, destructive labels.
  final Color blockedText;
  final Color dangerText;

  /// Colour of the mark (check, "!") drawn on a filled status glyph or badge:
  /// dark on the bright ink fills, white on the deeper paper fills.
  Color get onStatus => isDark ? bg : const Color(0xFFFFFFFF);

  /// The faint orange wash behind a blocked agent's question (the one place a
  /// blocked card, dock or sheet is tinted).
  Color get blockedWash => blocked.withValues(alpha: isDark ? 0.12 : 0.09);

  bool get isDark => brightness == Brightness.dark;

  /// Paper: warm off-white, warm near-black text.
  static const paper = Ds(
    brightness: Brightness.light,
    bg: Color(0xFFFBFBFA),
    surface: Color(0xFFFFFFFF),
    fill: Color(0xFFF1F0EE),
    fillPressed: Color(0xFFE8E7E4),
    hairline: Color(0xFFEAE9E6),
    text: Color(0xFF37352F),
    textSecondary: Color(0xFF5F5E5A),
    textMuted: Color(0xFF6E6D69),
    textTertiary: Color(0xFF8F8E8A),
    border: Color(0xFFD3D1CC),
    accent: Color(0xFF5E6AD2),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF4B57BE),
    scrim: Color(0x66000000),
    blocked: Color(0xFFCC5A1E),
    working: Color(0xFFB07F00),
    done: Color(0xFF258A53),
    danger: Color(0xFFD44C47),
    blockedText: Color(0xFFAD4C14),
    dangerText: Color(0xFFB5342F),
  );

  /// Ink: cool near-black with a surface ladder.
  static const ink = Ds(
    brightness: Brightness.dark,
    bg: Color(0xFF0D0E10),
    surface: Color(0xFF16171A),
    fill: Color(0xFF1C1D21),
    fillPressed: Color(0xFF25262B),
    hairline: Color(0xFF24262A),
    text: Color(0xFFECEDEF),
    textSecondary: Color(0xFF8D9098),
    textMuted: Color(0xFF868993),
    textTertiary: Color(0xFF6A6D75),
    border: Color(0xFF3A3D44),
    accent: Color(0xFF5E6AD2),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF9AA3F2),
    scrim: Color(0x99000000),
    blocked: Color(0xFFF2994A),
    working: Color(0xFFF2C94C),
    done: Color(0xFF4CB782),
    danger: Color(0xFFEB5757),
    blockedText: Color(0xFFF2994A),
    dangerText: Color(0xFFF26B6B),
  );

  @override
  Ds copyWith({Color? bg}) => Ds(
        brightness: brightness,
        bg: bg ?? this.bg,
        surface: surface,
        fill: fill,
        fillPressed: fillPressed,
        hairline: hairline,
        text: text,
        textSecondary: textSecondary,
        textMuted: textMuted,
        textTertiary: textTertiary,
        border: border,
        accent: accent,
        onAccent: onAccent,
        accentText: accentText,
        scrim: scrim,
        blocked: blocked,
        working: working,
        done: done,
        danger: danger,
        blockedText: blockedText,
        dangerText: dangerText,
      );

  @override
  Ds lerp(Ds? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Ds(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      fill: l(fill, other.fill),
      fillPressed: l(fillPressed, other.fillPressed),
      hairline: l(hairline, other.hairline),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      textTertiary: l(textTertiary, other.textTertiary),
      border: l(border, other.border),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentText: l(accentText, other.accentText),
      scrim: l(scrim, other.scrim),
      blocked: l(blocked, other.blocked),
      working: l(working, other.working),
      done: l(done, other.done),
      danger: l(danger, other.danger),
      blockedText: l(blockedText, other.blockedText),
      dangerText: l(dangerText, other.dangerText),
    );
  }
}

extension DsContext on BuildContext {
  Ds get ds => Theme.of(this).extension<Ds>()!;
}

/// Spacing scale (4pt grid) and page gutters.
abstract final class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  /// Horizontal page margin.
  static const gutter = 20.0;
}

abstract final class Radii {
  /// Icon tiles.
  static const tile = 7.0;

  /// Pressed highlight of a list row or sheet action.
  static const row = 10.0;

  /// Segmented track (its thumb is [control]).
  static const segmented = 11.0;

  /// Empty-state icon tile.
  static const emptyTile = 14.0;

  /// Toasts.
  static const toast = 12.0;

  /// Tooltips.
  static const tooltip = 7.0;

  /// Buttons, inputs, segmented control.
  static const control = 9.0;

  /// Panels (the terminal, banners).
  static const panel = 12.0;

  /// Bottom sheets.
  static const sheet = 18.0;

  /// Answer chips, question washes and code boxes inside a panel.
  static const chip = 10.0;

  /// Checkboxes and small inline marks.
  static const mark = 5.0;
}

/// Type scale (Inter). Sizes are for the default text scale; they grow with the
/// system setting. Tracking is size-specific: tight on large text, neutral on
/// body, never one value for all sizes.
abstract final class Type {
  static const family = 'Inter';

  static const largeTitle = TextStyle(
    fontFamily: family,
    fontSize: 32,
    height: 1.18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.9,
  );
  static const title = TextStyle(
    fontFamily: family,
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
  );

  /// Compact page title in the top bar.
  static const barTitle = TextStyle(
    fontFamily: family,
    fontSize: 16,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  /// Row title.
  static const row = TextStyle(
    fontFamily: family,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.15,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
  );

  /// Secondary text under a row title.
  static const secondary = TextStyle(
    fontFamily: family,
    fontSize: 13.5,
    height: 1.35,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );

  /// Section labels and chips: Notion-style sentence case, not letterspaced caps.
  static const label = TextStyle(
    fontFamily: family,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.05,
  );
  static const button = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );
  static const caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );

  /// Secondary reading text in sheets, forms and notices (a notch under
  /// [body]).
  static const compact = TextStyle(
    fontFamily: family,
    fontSize: 14.5,
    height: 1.4,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
  );

  /// The question an agent asks (card, dock, sheet): one size everywhere.
  static const prompt = TextStyle(
    fontFamily: family,
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
  );

  /// A one-tap answer or a button label inside a panel.
  static const answer = TextStyle(
    fontFamily: family,
    fontSize: 14.5,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
  );

  static const tabular = [FontFeature.tabularFigures()];
}
