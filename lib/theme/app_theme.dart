import 'package:flutter/material.dart';

/// FitSize design system: the "tailor's studio" theme.
///
/// * Light mode: deep teal-green primary on a warm sand/cream surface.
/// * Dark mode: bright teal on a near-black, green-tinted surface.
/// * System fonts only, with a clear type scale; measurement numbers use
///   tabular figures so columns of values line up.
/// * One card radius ([AppRadii.card]) and one spacing scale ([AppSpacing])
///   used everywhere.
/// * A sparing measuring-tape motif: [TapeDivider].
///
/// Apply with `theme: AppTheme.light, darkTheme: AppTheme.dark`.
abstract final class AppTheme {
  /// Light theme: teal on warm sand.
  static ThemeData get light => _build(Brightness.light);

  /// Dark theme: bright teal on near-black green.
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = isDark ? _darkScheme : _lightScheme;
    final extras = isDark ? FitSizeColors.dark : FitSizeColors.light;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );
    final text = _textTheme(base.textTheme, scheme);

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.card),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.button),
    );
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.field),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      extensions: [extras],
      appBarTheme: AppBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        foregroundColor: scheme.onSurface,
        titleTextStyle: text.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: isDark
            ? scheme.surfaceContainerLow
            : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        shape: cardShape,
        clipBehavior: Clip.antiAlias,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 56),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: buttonShape,
          textStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 56),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: buttonShape,
          side: BorderSide(
            color: scheme.outline.withValues(alpha: 0.7),
            width: 1.5,
          ),
          foregroundColor: scheme.primary,
          textStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: buttonShape,
          foregroundColor: scheme.primary,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.onSurface),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.field),
            ),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.primaryContainer;
            }
            return isDark
                ? scheme.surfaceContainerLow
                : scheme.surfaceContainerLowest;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.onPrimaryContainer;
            }
            return scheme.onSurfaceVariant;
          }),
          iconColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return scheme.onPrimaryContainer;
            }
            return scheme.onSurfaceVariant;
          }),
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainerLow
            : scheme.surfaceContainerLowest,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        focusedErrorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        labelStyle: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: text.labelLarge?.copyWith(color: scheme.primary),
        suffixStyle: text.titleMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
        hintStyle: text.bodyLarge?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark
            ? scheme.surfaceContainer
            : scheme.surfaceContainerLowest,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.chip),
        ),
        labelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        iconTheme: IconThemeData(color: scheme.primary, size: 18),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        iconColor: scheme.primary,
        titleTextStyle: text.titleMedium?.copyWith(color: scheme.onSurface),
        subtitleTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.field),
        ),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sheet),
        ),
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.sheet),
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      iconTheme: IconThemeData(color: scheme.onSurface),
    );
  }

  /// Type scale on the system font. Headings tighten letter-spacing and all
  /// numeric-leaning styles (display + headline) use tabular figures.
  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    const tabular = [FontFeature.tabularFigures()];
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontSize: 56,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.5,
        height: 1.05,
        fontFeatures: tabular,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontSize: 44,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        height: 1.05,
        fontFeatures: tabular,
      ),
      displaySmall: base.displaySmall?.copyWith(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.9,
        height: 1.08,
        fontFeatures: tabular,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.15,
        fontFeatures: tabular,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        height: 1.18,
        fontFeatures: tabular,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.2,
        fontFeatures: tabular,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: base.bodySmall?.copyWith(fontSize: 12.5, height: 1.4),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  static final ColorScheme _lightScheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.teal,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.teal,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFC6EBDF),
        onPrimaryContainer: AppColors.tealDeep,
        secondary: AppColors.brass,
        onSecondary: Colors.white,
        secondaryContainer: const Color(0xFFF2E5CB),
        onSecondaryContainer: const Color(0xFF3F2F12),
        tertiary: const Color(0xFF9A5A43),
        tertiaryContainer: const Color(0xFFFFDBCF),
        onTertiaryContainer: const Color(0xFF3B1407),
        surface: AppColors.sand,
        onSurface: AppColors.ink,
        surfaceContainerLowest: const Color(0xFFFFFDF8),
        surfaceContainerLow: const Color(0xFFFBF7EE),
        surfaceContainer: const Color(0xFFF0EADD),
        surfaceContainerHigh: const Color(0xFFEAE3D4),
        surfaceContainerHighest: const Color(0xFFE2DBCA),
        surfaceBright: const Color(0xFFFFFDF8),
        surfaceDim: const Color(0xFFE6E0D2),
        onSurfaceVariant: const Color(0xFF4E5955),
        outline: const Color(0xFF7B8782),
        outlineVariant: const Color(0xFFD3CDBE),
        inverseSurface: const Color(0xFF1B2521),
        onInverseSurface: const Color(0xFFEFF5F1),
        inversePrimary: AppColors.tealBright,
      );

  static final ColorScheme _darkScheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.teal,
        brightness: Brightness.dark,
      ).copyWith(
        primary: AppColors.tealBright,
        onPrimary: const Color(0xFF00382E),
        primaryContainer: const Color(0xFF0F5A4C),
        onPrimaryContainer: const Color(0xFFBDF2E3),
        secondary: const Color(0xFFDCC08F),
        onSecondary: const Color(0xFF3B2B0B),
        secondaryContainer: const Color(0xFF4F3F1E),
        onSecondaryContainer: const Color(0xFFF5E6C8),
        tertiary: const Color(0xFFF0B59F),
        tertiaryContainer: const Color(0xFF6B3A28),
        onTertiaryContainer: const Color(0xFFFFDBCF),
        surface: AppColors.night,
        onSurface: const Color(0xFFE4ECE8),
        surfaceContainerLowest: const Color(0xFF060A09),
        surfaceContainerLow: const Color(0xFF111A17),
        surfaceContainer: const Color(0xFF16211D),
        surfaceContainerHigh: const Color(0xFF1D2A26),
        surfaceContainerHighest: const Color(0xFF26342F),
        surfaceBright: const Color(0xFF2C3B36),
        surfaceDim: AppColors.night,
        onSurfaceVariant: const Color(0xFFAAB9B2),
        outline: const Color(0xFF6D7B76),
        outlineVariant: const Color(0xFF2A3732),
        inverseSurface: const Color(0xFFE4ECE8),
        onInverseSurface: const Color(0xFF17201D),
        inversePrimary: AppColors.teal,
      );
}

/// Raw brand colours. Prefer [ColorScheme] / [FitSizeColors] in widgets.
abstract final class AppColors {
  /// Primary: deep teal-green (light mode primary, dark mode inversePrimary).
  static const Color teal = Color(0xFF0E6B5B);

  /// Deeper teal for text on the primary container.
  static const Color tealDeep = Color(0xFF07473C);

  /// Bright teal used as the dark-mode primary.
  static const Color tealBright = Color(0xFF5FD3B8);

  /// Warm brass accent (secondary).
  static const Color brass = Color(0xFF8C6B3A);

  /// Light-mode surface: warm sand.
  static const Color sand = Color(0xFFF6F1E7);

  /// Light-mode on-surface: soft ink with a green tint.
  static const Color ink = Color(0xFF17201D);

  /// Dark-mode surface: near-black with a green tint.
  static const Color night = Color(0xFF0B110F);
}

/// Corner radii used across the app.
abstract final class AppRadii {
  /// Cards and tiles.
  static const double card = 20;

  /// Buttons.
  static const double button = 16;

  /// Text fields and segmented controls.
  static const double field = 14;

  /// Chips and small pills.
  static const double chip = 12;

  /// Sheets and dialogs.
  static const double sheet = 28;
}

/// Spacing scale (4 pt base).
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter.
  static const double gutter = 20;
}

/// Semantic colours the Material scheme does not carry: confidence states
/// and the measuring-tape ink. Fetch with `FitSizeColors.of(context)`.
class FitSizeColors extends ThemeExtension<FitSizeColors> {
  /// Good confidence (≥ 0.7).
  final Color good;

  /// Container for [good].
  final Color goodContainer;

  /// Medium confidence (0.4–0.7).
  final Color caution;

  /// Container for [caution].
  final Color cautionContainer;

  /// Ink colour of tape tick marks.
  final Color tapeInk;

  const FitSizeColors({
    required this.good,
    required this.goodContainer,
    required this.caution,
    required this.cautionContainer,
    required this.tapeInk,
  });

  static const FitSizeColors light = FitSizeColors(
    good: Color(0xFF1E7A4B),
    goodContainer: Color(0xFFD5F0DF),
    caution: Color(0xFF9A6300),
    cautionContainer: Color(0xFFFCEBC2),
    tapeInk: Color(0xFF0E6B5B),
  );

  static const FitSizeColors dark = FitSizeColors(
    good: Color(0xFF7ED8A2),
    goodContainer: Color(0xFF17432C),
    caution: Color(0xFFF2C66A),
    cautionContainer: Color(0xFF4A3A10),
    tapeInk: Color(0xFF5FD3B8),
  );

  /// The extension registered on the current theme (falls back to light).
  static FitSizeColors of(BuildContext context) =>
      Theme.of(context).extension<FitSizeColors>() ?? light;

  @override
  FitSizeColors copyWith({
    Color? good,
    Color? goodContainer,
    Color? caution,
    Color? cautionContainer,
    Color? tapeInk,
  }) {
    return FitSizeColors(
      good: good ?? this.good,
      goodContainer: goodContainer ?? this.goodContainer,
      caution: caution ?? this.caution,
      cautionContainer: cautionContainer ?? this.cautionContainer,
      tapeInk: tapeInk ?? this.tapeInk,
    );
  }

  @override
  FitSizeColors lerp(FitSizeColors? other, double t) {
    if (other == null) return this;
    return FitSizeColors(
      good: Color.lerp(good, other.good, t)!,
      goodContainer: Color.lerp(goodContainer, other.goodContainer, t)!,
      caution: Color.lerp(caution, other.caution, t)!,
      cautionContainer: Color.lerp(
        cautionContainer,
        other.cautionContainer,
        t,
      )!,
      tapeInk: Color.lerp(tapeInk, other.tapeInk, t)!,
    );
  }
}

/// A subtle measuring-tape divider: a thin baseline with tick marks, every
/// fifth one taller. Use sparingly, as a section divider.
class TapeDivider extends StatelessWidget {
  /// Creates a tape divider.
  const TapeDivider({
    super.key,
    this.height = 14,
    this.spacing = 8,
    this.color,
  });

  /// Total height of the widget; ticks hang down from the baseline.
  final double height;

  /// Distance between ticks.
  final double spacing;

  /// Ink colour; defaults to the theme's outline at reduced opacity.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink =
        color ?? Theme.of(context).colorScheme.outline.withValues(alpha: 0.45);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TapeDividerPainter(ink: ink, spacing: spacing),
      ),
    );
  }
}

class _TapeDividerPainter extends CustomPainter {
  _TapeDividerPainter({required this.ink, required this.spacing});

  final Color ink;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ink
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, 0.5), Offset(size.width, 0.5), paint);
    final tall = size.height * 0.85;
    final mid = size.height * 0.55;
    final short = size.height * 0.32;
    var i = 0;
    for (var x = 0.5; x <= size.width; x += spacing, i++) {
      final len = i % 10 == 0
          ? tall
          : i % 5 == 0
          ? mid
          : short;
      canvas.drawLine(Offset(x, 0.5), Offset(x, len), paint);
    }
  }

  @override
  bool shouldRepaint(_TapeDividerPainter old) =>
      old.ink != ink || old.spacing != spacing;
}
