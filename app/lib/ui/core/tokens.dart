import 'package:flutter/material.dart';

// Light: a crisp edge shadow under a soft ambient one. Dark: a black shadow
// vanishes on near-black, so the lift is a faint light ring instead.
const _floatLight = [
  BoxShadow(color: Color(0x0F000000), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 8)),
];
const _floatDark = [BoxShadow(color: Color(0x14FFFFFF), blurRadius: 0, spreadRadius: 1)];

/// Design tokens, in three tiers: a private palette (the hex values below),
/// the roles a screen reads ([Ds], [Type], [Mono], [Gap], [Radii],
/// [IconSize]), and component metrics, which exist only where two or more
/// components share a value (`FloatingBar`, `RowMetrics`). A new visual token
/// needs two call sites and a one-line reason. A named timer or spring
/// (`Dwell`, `Springs`) may have one call site: it is named by its role, so
/// the value is found and tuned in one place. `tool/design_lint.dart` keeps
/// raw values out of screens.
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
    required this.controlBorder,
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
    required this.pressTint,
    required this.inverseSurface,
    required this.onInverse,
    required this.inverseAccent,
  });

  final Brightness brightness;

  /// Page background.
  final Color bg;

  /// Raised surface: sheets, inputs, the floating bars, the agent card.
  final Color surface;

  /// Quiet fill for controls, chips, tiles and panels inside content.
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

  /// A drawn outline that is decoration (~1.5:1): diagram boxes, table rules,
  /// quote bars. Stronger than [hairline], which is a divider.
  final Color border;

  /// The edge of a control the person must find and fill (a text field, a
  /// picker): >= 3:1 against [surface] (WCAG 1.4.11), where [border] is not.
  final Color controlBorder;

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

  /// A pressed row or area on any surface: a translucent veil, so it works on
  /// [bg], [surface] and a wash alike (an opaque [fill] did not).
  final Color pressTint;

  /// Transient messages floating over everything (toasts, tooltips): the one
  /// inverse surface, so a message never reads as page content or a field.
  final Color inverseSurface;
  final Color onInverse;

  /// An action on [inverseSurface] (a toast's Undo).
  final Color inverseAccent;

  /// Colour of the mark (check, "!") drawn on a filled status glyph or badge:
  /// dark on the bright ink fills, white on the deeper paper fills.
  Color get onStatus => isDark ? bg : const Color(0xFFFFFFFF);

  /// The faint orange wash behind a blocked agent's question (the one place a
  /// blocked card, dock or sheet is tinted).
  Color get blockedWash => blocked.withValues(alpha: isDark ? 0.12 : 0.09);

  /// A state's tint behind a panel, a strip or a primed chip.
  /// `blockedText` / `dangerText` reach 4.5:1 on it.
  Color wash(Color c) => c.withValues(alpha: isDark ? 0.16 : 0.12);

  /// [wash], pressed.
  Color washPressed(Color c) => c.withValues(alpha: isDark ? 0.22 : 0.16);

  /// The edge of a chip that is primed and waits for its confirmation: the
  /// one place a state is outlined, because a risky answer must not be missed.
  Color armedEdge(Color c) => c.withValues(alpha: 0.55);

  /// The accent as a tint: the selected tab's capsule, a selected chip, an
  /// active toggle, a selected row.
  Color get accentWash => accent.withValues(alpha: isDark ? 0.16 : 0.09);
  Color get accentWashPressed => accent.withValues(alpha: isDark ? 0.22 : 0.15);

  /// A primary (accent-filled) control, pressed.
  Color get accentPressed => Color.alphaBlend(const Color(0x1F000000), accent);

  /// Grabbers, scrollbars, faint marks.
  Color get faint => textTertiary.withValues(alpha: 0.6);

  /// Skeleton bars while something loads.
  Color get skeleton => textTertiary.withValues(alpha: 0.2);

  /// Selected text in a field or a selectable block.
  Color get selection => accent.withValues(alpha: 0.28);

  /// Selected output in a pane on the dark page. [selection] is a near-black
  /// indigo there; the text keeps its own colour, so this only has to be seen
  /// (still 7:1 with the terminal foreground).
  Color get terminalSelection => accent.withValues(alpha: 0.5);

  /// The underline under a markdown link: present, quieter than its text.
  Color get linkUnderline => accentText.withValues(alpha: 0.4);

  /// [c] at [t] of its own opacity: an animated fade drawn in paint, where
  /// an `Opacity` layer would cost a layer per frame.
  static Color fade(Color c, double t) => t >= 1 ? c : c.withValues(alpha: c.a * t.clamp(0, 1));

  /// A dark veil over a photo (its bars, a selection), and the marks on it.
  Color get photoScrim => const Color(0x99000000);
  Color get onPhoto => const Color(0xFFFFFFFF);

  /// Added lines as text: a deeper green on paper (`done` is a shape colour
  /// there, 4.2:1); ink reuses `done` (6.7:1 or better). Removed lines use
  /// [dangerText].
  Color get addedText => isDark ? done : const Color(0xFF1B7343);

  /// The one shadow: a surface floating over content (the bottom bars and the
  /// pill over them). Soft and wide, never a band.
  List<BoxShadow> get floatShadow => isDark ? _floatDark : _floatLight;

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
    controlBorder: Color(0xFF8F8E8A),
    accent: Color(0xFF5E6AD2),
    onAccent: Color(0xFFFFFFFF),
    accentText: Color(0xFF4B57BE),
    scrim: Color(0x66000000),
    blocked: Color(0xFFCC5A1E),
    working: Color(0xFFB07F00),
    done: Color(0xFF258A53),
    danger: Color(0xFFD44C47),
    blockedText: Color(0xFFA84A13),
    dangerText: Color(0xFFB5342F),
    pressTint: Color(0x0B000000),
    inverseSurface: Color(0xFF2B2A27),
    onInverse: Color(0xFFF1F1EF),
    inverseAccent: Color(0xFFAAB2F5),
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
    controlBorder: Color(0xFF60646D),
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
    pressTint: Color(0x0BFFFFFF),
    inverseSurface: Color(0xFF2A2B30),
    onInverse: Color(0xFFF1F1EF),
    inverseAccent: Color(0xFFAAB2F5),
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
    controlBorder: controlBorder,
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
    pressTint: pressTint,
    inverseSurface: inverseSurface,
    onInverse: onInverse,
    inverseAccent: inverseAccent,
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
      controlBorder: l(controlBorder, other.controlBorder),
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
      pressTint: l(pressTint, other.pressTint),
      inverseSurface: l(inverseSurface, other.inverseSurface),
      onInverse: l(onInverse, other.onInverse),
      inverseAccent: l(inverseAccent, other.inverseAccent),
    );
  }
}

extension DsContext on BuildContext {
  Ds get ds => Theme.of(this).extension<Ds>()!;
}

/// Spacing scale (4pt grid) and page gutters. Off-grid values are snapped to
/// it; [hair] is the one step below the grid, for optical nudges and the gap
/// between two stacked lines of text.
abstract final class Gap {
  static const hair = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  /// Horizontal page margin.
  static const gutter = 20.0;
}

/// Corner radii: four steps and a pill. One-dp steps (7, 9, 10, 11, 12) were
/// invisible and drifted, so they collapsed. A shape nested inside another
/// takes the outer radius minus the inset between them.
abstract final class Radii {
  /// Small tiles and marks: icon tiles, thumbnails, tooltips, checkboxes.
  static const xs = 6.0;

  /// Controls: buttons, inputs, chips, pressed rows, question washes.
  static const sm = 10.0;

  /// Panels and floating messages: panels, cards, toasts, empty-state tiles.
  static const md = 14.0;

  /// Sheets.
  static const lg = 20.0;

  /// Fully round ends (pills, badges, bars, grabbers): any height.
  static const pill = 999.0;
}

/// Icon sizes by role.
abstract final class IconSize {
  /// Inside a line of text: chip leading, inline warnings, marks.
  static const inline = 14.0;

  /// A row's leading or trailing icon, every chevron, a search prefix.
  static const row = 16.0;

  /// Fields, panels, toasts, sheet actions.
  static const bar = 18.0;

  /// A status glyph in a row's 32 dp leading column.
  static const lead = 20.0;

  /// The batch bar's actions and the attach sheet's bars.
  static const nav = 24.0;

  /// An empty state's tile.
  static const empty = 28.0;

  /// A screen-filling mark (a file that cannot be shown).
  static const hero = 48.0;
}

/// Terminal and code text (JetBrains Mono): proper box drawing for agent
/// UIs; the symbols it lacks come from [monoFallback].
const monoFamily = 'JetBrainsMono';

/// What mono text falls back to for the symbols JetBrains Mono lacks: Claude
/// Code's `⏵⏵ auto mode on`, `⏺`, `⎿` and spinner stars, braille spinners.
/// Subset from Noto onto JetBrains Mono's cell (tool/fonts/build_symbols.py),
/// because the phone's own fallback drew them as boxes (`▯▯ auto mode on`).
const monoFallback = ['HerdrSymbols'];

/// Mono text by role. Ligatures are off: code is read character by character
/// (`!=` must not become one glyph). The terminal keeps its own, user-sized
/// style.
abstract final class Mono {
  static const noLigatures = [FontFeature.disable('liga'), FontFeature.disable('calt')];

  /// Dense meta: a log tail, a hex id.
  static const small = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 11.5,
    height: 1.4,
    letterSpacing: 0,
    fontFeatures: noLigatures,
  );

  /// Commands, paths, code blocks.
  static const base = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 12.5,
    height: 1.4,
    letterSpacing: 0,
    fontFeatures: noLigatures,
  );

  /// Typed shell text, key caps, and the subject of a question (what an
  /// answer approves is the largest thing on its wash).
  static const input = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 13.5,
    height: 1.45,
    letterSpacing: 0,
    fontFeatures: noLigatures,
  );

  /// The terminal preview on a board card.
  static const preview = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 11,
    height: 1.38,
    letterSpacing: 0,
    fontFeatures: noLigatures,
  );
}

/// Type scale (Inter). Sizes are for the default text scale; they grow with the
/// system setting. Tracking is size-specific: tight on large text, neutral on
/// body, never one value for all sizes. Weight comes with the role: a screen
/// never sets `fontWeight`, it picks the `Strong` variant.
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

  /// The name of a thing in a list: an agent, a machine, a file.
  static const row = TextStyle(
    fontFamily: family,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.15,
  );

  /// The title of an action or setting row: regular, so names (w500) stand
  /// out from the actions around them.
  static const cell = TextStyle(
    fontFamily: family,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.15,
  );

  /// Text the person types into a field.
  static const input = TextStyle(
    fontFamily: family,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w400,
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

  /// [secondary] with weight: a log row's line, an emphasised meta.
  static const secondaryStrong = TextStyle(
    fontFamily: family,
    fontSize: 13.5,
    height: 1.35,
    fontWeight: FontWeight.w500,
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

  /// [label] with weight: section headers, a group's title, a text action.
  static const labelStrong = TextStyle(
    fontFamily: family,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.05,
  );

  static const button = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );

  /// A compact button, a segment of a switch.
  static const buttonCompact = TextStyle(
    fontFamily: family,
    fontSize: 13.5,
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

  /// [caption] with weight: a diff mark, a small state word.
  static const captionStrong = TextStyle(
    fontFamily: family,
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );

  /// A count beside a label (`Needs you 1`, a section's total): tabular.
  static const count = TextStyle(
    fontFamily: family,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    fontFeatures: tabular,
  );

  /// The number in a count badge (the agent switcher's, a machine's).
  static const badge = TextStyle(
    fontFamily: family,
    fontSize: 11,
    height: 1.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    fontFeatures: tabular,
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

  /// A one-tap answer, a button label inside a panel, a panel's title.
  static const answer = TextStyle(
    fontFamily: family,
    fontSize: 14.5,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
  );

  /// Markdown headings, levels 1 to 3 (4 and below are [bodyStrong]).
  static const h1 = TextStyle(
    fontFamily: family,
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
  );
  static const h2 = TextStyle(
    fontFamily: family,
    fontSize: 18.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
  );
  static const h3 = TextStyle(
    fontFamily: family,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.15,
  );

  /// [body] with weight: markdown h4, a quiet heading, a table header.
  static const bodyStrong = TextStyle(
    fontFamily: family,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
  );

  static const tabular = [FontFeature.tabularFigures()];
}
