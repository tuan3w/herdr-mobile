import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Spacing scale (4pt grid).
abstract final class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class Radii {
  static const card = 20.0;
  static const chip = 12.0;
  static const field = 14.0;
}

/// Terminal surface colours, shared by both themes: a pane is always dark.
abstract final class TerminalColors {
  static const background = Color(0xFF0B0E13);
  static const foreground = Color(0xFFD7DCE3);
  static const dim = Color(0xFF7C8591);
  static const border = Color(0xFF1E252E);

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

const _accent = Color(0xFF5EEAD4);

const monoFamily = 'monospace';

abstract final class AppTheme {
  static ThemeData dark() {
    const surface = Color(0xFF0F1318);
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.dark,
      surface: surface,
    ).copyWith(
      primary: _accent,
      onPrimary: const Color(0xFF00201C),
      surfaceContainerLowest: const Color(0xFF0B0E12),
      surfaceContainerLow: const Color(0xFF141A21),
      surfaceContainer: const Color(0xFF181F27),
      surfaceContainerHigh: const Color(0xFF1E2630),
      surfaceContainerHighest: const Color(0xFF252E3A),
      outlineVariant: const Color(0xFF28313C),
    );
    return _build(scheme, SystemUiOverlayStyle.light);
  }

  static ThemeData light() {
    const surface = Color(0xFFF5F7FA);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F766E),
      brightness: Brightness.light,
      surface: surface,
    ).copyWith(
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: const Color(0xFFEEF1F5),
      surfaceContainerHigh: const Color(0xFFE6EAF0),
      outlineVariant: const Color(0xFFDDE2E9),
    );
    return _build(scheme, SystemUiOverlayStyle.dark);
  }

  static ThemeData _build(ColorScheme scheme, SystemUiOverlayStyle overlay) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
    );
    final text = base.textTheme;
    return base.copyWith(
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        systemOverlayStyle: overlay,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        height: 68,
        labelTextStyle: WidgetStatePropertyAll(
          text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.field),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.field),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.field),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.field),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.field),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.field),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.field),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.field),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    );
  }
}
