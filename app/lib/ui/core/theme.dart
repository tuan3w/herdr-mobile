import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder, CupertinoRouteTransitionMixin;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

export 'tokens.dart';

/// WCAG contrast ratio of two colours (1 to 21).
double contrastRatio(Color a, Color b) => _ratio(a.computeLuminance(), b.computeLuminance());

double _ratio(double la, double lb) => (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);

/// [fg] moved towards readable on [bg]: the lightness changes, the hue and the
/// saturation do not (HSL), as little as it takes to reach [floor]:1.
///
/// A colour that already reaches it comes back as the very same object.
/// Lighter or darker is the direction the floor can be reached in; where both
/// can, the way [fg] already leans (lighter than [bg] goes lighter). A floor
/// neither white nor black reaches on [bg] gives the better of the two.
Color liftToContrast(Color fg, Color bg, double floor) {
  final lb = bg.computeLuminance();
  final lf = fg.computeLuminance();
  if (_ratio(lf, lb) >= floor) return fg;
  final maxLighter = 1.05 / (lb + 0.05);
  final maxDarker = (lb + 0.05) / 0.05;
  final bool lighter;
  if (maxLighter >= floor && maxDarker >= floor) {
    lighter = lf >= lb;
  } else if (maxLighter >= floor || maxDarker >= floor) {
    lighter = maxLighter >= floor;
  } else {
    return maxLighter >= maxDarker ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  }
  final hsl = HSLColor.fromColor(fg);
  bool reads(double l) => _ratio(_quantized(hsl.withLightness(l)).computeLuminance(), lb) >= floor;
  // Luminance never falls as HSL lightness rises, so the first lightness that
  // reads is found by halving. [good] reads, [bad] does not.
  var good = lighter ? 1.0 : 0.0;
  var bad = hsl.lightness;
  for (var i = 0; i < 16; i++) {
    final mid = (good + bad) / 2;
    if (reads(mid)) {
      good = mid;
    } else {
      bad = mid;
    }
  }
  return _quantized(hsl.withLightness(good));
}

/// [c] on the 8-bit channels a screen has, so what is measured is what is drawn.
Color _quantized(HSLColor c) {
  final rgb = c.toColor();
  return Color.fromARGB(255, (rgb.r * 255).round(), (rgb.g * 255).round(), (rgb.b * 255).round());
}

/// The dark terminal colours. The ANSI parser resolves colour codes to these,
/// whatever theme is showing; [TerminalPalette.light] maps them to its own
/// when a pane is drawn on paper (see [TerminalPalette.recolor]).
abstract final class TerminalColors {
  static const background = Color(0xFF0A0B0D);
  static const foreground = Color(0xFFD7DCE3);
  static const dim = Color(0xFF7C8591);
  static const border = Color(0xFF1E2127);

  /// The 16 ANSI colours (0-7 normal, 8-15 bright): the true ones, nord-ish,
  /// so a TUI that paints a black block or a black status line gets one, and
  /// its own text on it (default, white) reads. They are NOT tuned to be
  /// legible as text on [background]: black is `#3B4252`, 2:1 on it. Text in
  /// any colour is lifted at render time to 4.5:1 against its cell's own
  /// background (`TerminalContrast`), so a black word on the page reads and a
  /// black block stays a block. `terminal_palette_test.dart` measures it.
  static const ansi = <Color>[
    Color(0xFF3B4252),
    Color(0xFFE06C75),
    Color(0xFF98C379),
    Color(0xFFE5C07B),
    Color(0xFF61AFEF),
    Color(0xFFC678DD),
    Color(0xFF56B6C2),
    Color(0xFFC5CBD3),
    Color(0xFF737D8C),
    Color(0xFFF4858D),
    Color(0xFFB5E08E),
    Color(0xFFF2D38F),
    Color(0xFF7FC1FF),
    Color(0xFFD99BEA),
    Color(0xFF7FD3DE),
    Color(0xFFF1F4F8),
  ];
}

/// The colours a pane is drawn in: its page, its default text, the 16 ANSI
/// colours. The theme carries one (`context.terminal`): [dark] on ink, [light]
/// on paper, or [dark] on both when the person wants a dark terminal.
///
/// The parser always produces [TerminalColors] values. [recolor] turns them
/// into this palette's at the moment a row is prepared and lifts text that
/// does not read on its own background (see [minContrast]); a row with
/// nothing to change comes back as it is, and a theme switch only needs the
/// prepared rows dropped.
@immutable
class TerminalPalette extends ThemeExtension<TerminalPalette> {
  TerminalPalette._({
    required this.isDark,
    required this.background,
    required this.foreground,
    required this.dim,
    required this.border,
    required this.link,
    required this.selection,
    required this.ansi,
  });

  final bool isDark;
  final Color background;
  final Color foreground;

  /// Placeholders and stale text.
  final Color dim;
  final Color border;

  /// Links in output.
  final Color link;

  /// Selected output. Stronger than `Ds.selection` on the dark page: the text
  /// keeps its own colour, so the wash only has to be seen. The accent at 0.28
  /// over [background] was a near-black indigo; at 0.5 it still holds 7:1 with
  /// [foreground].
  final Color selection;

  /// The 16 ANSI colours as the parser's [TerminalColors] map to them. Text in
  /// them reads on [background] once drawn (the contrast guard lifts what does
  /// not), whatever these values are.
  final List<Color> ansi;

  static final dark = TerminalPalette._(
    isDark: true,
    background: TerminalColors.background,
    foreground: TerminalColors.foreground,
    dim: TerminalColors.dim,
    border: TerminalColors.border,
    link: Ds.ink.accentText,
    selection: Ds.ink.terminalSelection,
    ansi: TerminalColors.ansi,
  );

  /// Paper: white page, the paper text colour, darker hues.
  static final light = TerminalPalette._(
    isDark: false,
    background: Ds.paper.surface,
    foreground: Ds.paper.text,
    dim: Ds.paper.textMuted,
    border: Ds.paper.hairline,
    link: Ds.paper.accentText,
    selection: Ds.paper.selection,
    ansi: const [
      Color(0xFF4B5160),
      Color(0xFFB3261E),
      Color(0xFF2E7D32),
      Color(0xFF8A5F00),
      Color(0xFF1F5FBF),
      Color(0xFF8E3FB0),
      Color(0xFF0B7285),
      Color(0xFF5F6672),
      Color(0xFF687080),
      Color(0xFFC62E25),
      Color(0xFF2B7A35),
      Color(0xFF8F6200),
      Color(0xFF2A63D6),
      Color(0xFF9A38BD),
      Color(0xFF0A7488),
      Color(0xFF1F2430),
    ],
  );

  /// Text must reach this contrast against its own cell's background (WCAG
  /// 1.4.3) or it is lifted when a row is prepared, on either palette: a TUI
  /// that painted black or pale grey for a screen it imagined, stays readable.
  static const minContrast = 4.5;

  late final Map<Color, Color> _fromDark = {
    TerminalColors.foreground: foreground,
    TerminalColors.background: background,
    for (var i = 0; i < 16; i++) TerminalColors.ansi[i]: ansi[i],
  };

  /// [dark], one of the parser's [TerminalColors], as this palette draws it;
  /// any other colour is returned as is. The terminal renderer's `recolor`
  /// applies it to a run.
  Color mapped(Color dark) => _fromDark[dark] ?? dark;

  @override
  TerminalPalette copyWith() => this;

  @override
  TerminalPalette lerp(TerminalPalette? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension TerminalPaletteContext on BuildContext {
  /// The palette panes are drawn in under this theme. A tree without one (a
  /// bare test) gets the dark palette.
  TerminalPalette get terminal => Theme.of(this).extension<TerminalPalette>() ?? TerminalPalette.dark;
}

/// The Cupertino slide (parallax, edge-swipe back) at [Motion.page] instead of
/// the SDK's 500 ms: opening a pane is the app's most frequent action.
///
/// Under reduced motion the page does not slide and its parent does not shift:
/// it cross-fades over [Motion.fade]. The edge-swipe back stays (it drags the
/// route's own controller, so the fade follows the finger).
class _FastCupertinoTransitions extends CupertinoPageTransitionsBuilder {
  const _FastCupertinoTransitions();

  // Durations have no context to ask, so they read the same platform flag
  // `MediaQuery.disableAnimations` is made from.
  static bool get _reduced => WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  @override
  Duration get transitionDuration => _reduced ? Motion.fade : Motion.page;

  @override
  Duration get reverseTransitionDuration => _reduced ? Motion.fade : Motion.page;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!Motion.reduced(context)) {
      return super.buildTransitions<T>(route, context, animation, secondaryAnimation, child);
    }
    // The Cupertino transition at rest (no slide, no parallax) keeps the
    // edge-swipe detector; the fade rides the route's real animation.
    return FadeTransition(
      opacity: animation,
      child: CupertinoRouteTransitionMixin.buildPageTransitions<T>(
        route,
        context,
        kAlwaysCompleteAnimation,
        kAlwaysDismissedAnimation,
        child,
      ),
    );
  }
}

abstract final class AppTheme {
  /// [terminal] overrides the pane palette (a dark terminal on paper).
  static ThemeData dark({TerminalPalette? terminal}) => _build(Ds.ink, terminal ?? TerminalPalette.dark);
  static ThemeData light({TerminalPalette? terminal}) => _build(Ds.paper, terminal ?? TerminalPalette.light);

  /// Status and navigation bars drawn transparent over the app (edge to edge),
  /// with icons that contrast with [brightness] of the app surface behind them.
  ///
  /// Flutter's stock `SystemUiOverlayStyle.light/dark` presets never set a
  /// status bar colour, so the OEM default (a flat grey on Samsung) showed
  /// through, and they force a solid black navigation bar.
  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final icons = dark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness, // iOS: brightness of what is behind
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData _build(Ds ds, TerminalPalette terminal) {
    final scheme = ColorScheme(
      brightness: ds.brightness,
      primary: ds.accent,
      onPrimary: ds.onAccent,
      secondary: ds.accentText,
      onSecondary: ds.onAccent,
      error: ds.danger,
      onError: Colors.white,
      surface: ds.bg,
      onSurface: ds.text,
      onSurfaceVariant: ds.textSecondary,
      outline: ds.hairline,
      outlineVariant: ds.hairline,
      surfaceContainerLowest: ds.surface,
      surfaceContainerLow: ds.surface,
      surfaceContainer: ds.fill,
      surfaceContainerHigh: ds.fill,
      surfaceContainerHighest: ds.fillPressed,
    );

    TextStyle t(TextStyle s, [Color? c]) => s.copyWith(color: c ?? ds.text);
    final textTheme = TextTheme(
      displayLarge: t(Type.largeTitle),
      displayMedium: t(Type.largeTitle),
      displaySmall: t(Type.title),
      headlineLarge: t(Type.largeTitle),
      headlineMedium: t(Type.title),
      headlineSmall: t(Type.title),
      titleLarge: t(Type.title),
      titleMedium: t(Type.row),
      titleSmall: t(Type.barTitle),
      bodyLarge: t(Type.body),
      bodyMedium: t(Type.body),
      bodySmall: t(Type.secondary, ds.textSecondary),
      labelLarge: t(Type.button),
      labelMedium: t(Type.label, ds.textSecondary),
      labelSmall: t(Type.caption, ds.textSecondary),
    );

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.sm),
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: ds.brightness,
      colorScheme: scheme,
      fontFamily: Type.family,
      textTheme: textTheme,
      scaffoldBackgroundColor: ds.bg,
      canvasColor: ds.bg,
      extensions: [ds, terminal],
      // No ink ripples or tinted highlights: pressed state is drawn by our own
      // controls (`PressBuilder`).
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      dividerColor: ds.hairline,
      dividerTheme: DividerThemeData(color: ds.hairline, thickness: 1, space: 1),
      // Slide-with-parallax and edge-swipe back on every platform, instead of
      // Android's zoom/fade.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FastCupertinoTransitions(),
          TargetPlatform.iOS: _FastCupertinoTransitions(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ds.bg,
        foregroundColor: ds.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: systemBars(ds.brightness),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ds.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: Type.body.copyWith(color: ds.textMuted),
        errorStyle: Type.caption.copyWith(color: ds.dangerText),
        border: border(ds.controlBorder),
        enabledBorder: border(ds.controlBorder),
        focusedBorder: border(ds.accent, 1.5),
        errorBorder: border(ds.danger),
        focusedErrorBorder: border(ds.danger, 1.5),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: ds.accent,
        selectionColor: ds.selection,
        selectionHandleColor: ds.accent,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: ds.inverseSurface, borderRadius: BorderRadius.circular(Radii.xs)),
        textStyle: Type.caption.copyWith(color: ds.onInverse),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: ds.textSecondary),
    );
  }
}
