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
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.scrim,
    required this.blocked,
    required this.working,
    required this.done,
    required this.danger,
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
  final Color textSecondary;
  final Color textTertiary;

  /// The one accent. Fills (primary button) use [accent] with [onAccent] text;
  /// accent-coloured text and icons use [accentText] for contrast.
  final Color accent;
  final Color onAccent;
  final Color accentText;

  final Color scrim;

  /// Agent / link status colours.
  final Color blocked;
  final Color working;
  final Color done;
  final Color danger;

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
    textSecondary: Color(0xFF787774),
    textTertiary: Color(0xFFABA9A4),
    accent: Color(0xFF5E6AD2),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF4B57BE),
    scrim: Color(0x66000000),
    blocked: Color(0xFFE5732A),
    working: Color(0xFFD29A00),
    done: Color(0xFF2E9F63),
    danger: Color(0xFFD44C47),
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
    textTertiary: Color(0xFF5C5F67),
    accent: Color(0xFF5E6AD2),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF9AA3F2),
    scrim: Color(0x99000000),
    blocked: Color(0xFFF2994A),
    working: Color(0xFFF2C94C),
    done: Color(0xFF4CB782),
    danger: Color(0xFFEB5757),
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
        textTertiary: textTertiary,
        accent: accent,
        onAccent: onAccent,
        accentText: accentText,
        scrim: scrim,
        blocked: blocked,
        working: working,
        done: done,
        danger: danger,
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
      textTertiary: l(textTertiary, other.textTertiary),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentText: l(accentText, other.accentText),
      scrim: l(scrim, other.scrim),
      blocked: l(blocked, other.blocked),
      working: l(working, other.working),
      done: l(done, other.done),
      danger: l(danger, other.danger),
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

  /// Buttons, inputs, segmented control.
  static const control = 9.0;

  /// Panels (the terminal, banners).
  static const panel = 12.0;

  /// Bottom sheets.
  static const sheet = 18.0;
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

  static const tabular = [FontFeature.tabularFigures()];
}
