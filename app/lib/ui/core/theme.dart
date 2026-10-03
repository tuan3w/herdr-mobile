import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

export 'tokens.dart';

/// Terminal surface colours, shared by both themes: a pane is always dark.
abstract final class TerminalColors {
  static const background = Color(0xFF0A0B0D);
  static const foreground = Color(0xFFD7DCE3);
  static const dim = Color(0xFF7C8591);
  static const border = Color(0xFF1E2127);

  /// The 16 ANSI colours (0-7 normal, 8-15 bright), tuned for [background]:
  /// black and bright black stay legible, and nothing outshines [foreground].
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

/// Bundled monospace face (JetBrains Mono): the same on every phone, with
/// proper box-drawing and symbol coverage for agent UIs.
const monoFamily = 'JetBrainsMono';

/// The Cupertino slide (parallax, edge-swipe back) at [Motion.page] instead of
/// the SDK's 500 ms: opening a pane is the app's most frequent action.
class _FastCupertinoTransitions extends CupertinoPageTransitionsBuilder {
  const _FastCupertinoTransitions();

  @override
  Duration get transitionDuration => Motion.page;

  @override
  Duration get reverseTransitionDuration => Motion.page;
}

abstract final class AppTheme {
  static ThemeData dark() => _build(Ds.ink);
  static ThemeData light() => _build(Ds.paper);

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

  static ThemeData _build(Ds ds) {
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
          borderRadius: BorderRadius.circular(Radii.control),
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
      extensions: [ds],
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
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _FastCupertinoTransitions(),
        TargetPlatform.iOS: _FastCupertinoTransitions(),
      }),
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
        border: border(ds.border),
        enabledBorder: border(ds.border),
        focusedBorder: border(ds.accent, 1.5),
        errorBorder: border(ds.danger),
        focusedErrorBorder: border(ds.danger, 1.5),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: ds.accent,
        selectionColor: ds.accent.withValues(alpha: 0.28),
        selectionHandleColor: ds.accent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ds.isDark ? ds.fillPressed : const Color(0xFF2B2A27),
        contentTextStyle: Type.body.copyWith(color: const Color(0xFFF1F1EF)),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.snack)),
        insetPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 96),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ds.isDark ? ds.fillPressed : const Color(0xFF2B2A27),
          borderRadius: BorderRadius.circular(Radii.tooltip),
        ),
        textStyle: Type.caption.copyWith(color: const Color(0xFFF1F1EF)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: ds.surface,
        modalBackgroundColor: ds.surface,
        modalBarrierColor: ds.scrim,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: ds.textSecondary),
    );
  }
}
