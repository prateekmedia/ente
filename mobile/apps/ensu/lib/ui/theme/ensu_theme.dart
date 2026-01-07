import 'package:ente_ui/theme/colors.dart';
import 'package:ente_ui/theme/text_style.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Ensu app color palette
class EnsuColors {
  // Light theme
  static const Color cream = Color(0xFFF8F5F0);
  static const Color ink = Color(0xFF1A1A1A);
  static const Color muted = Color(0xFF8A8680);
  static const Color rule = Color(0xFFD4D0C8);
  static const Color codeBg = Color(0xFFF0EBE4);
  static const Color sent = Color(0xFF555555);
  static const Color accent = Color(0xFF9A7E0A);

  // Dark theme
  static const Color creamDark = Color(0xFF141414);
  static const Color inkDark = Color(0xFFE8E4DF);
  static const Color mutedDark = Color(0xFF777777);
  static const Color ruleDark = Color(0xFF2A2A2A);
  static const Color codeBgDark = Color(0xFF1E1E1E);
  static const Color sentDark = Color(0xFF999999);
  static const Color accentDark = Color(0xFFFFD700);
}

/// Builds EnteTextTheme with serif font for headings (h1, h2, h3).
/// Body text and other styles remain unchanged with Inter font.
EnteTextTheme _buildEnsuTextTheme(Color textBase, Color textMuted, Color textFaint) {
  const String serifFamily = 'CormorantGaramond';
  const FontWeight regularWeight = FontWeight.w500;
  const FontWeight boldWeight = FontWeight.w600;

  // Serif styles for headings
  final h1Serif = GoogleFonts.cormorantGaramond(
    fontSize: 48,
    height: 48 / 28,
    fontWeight: regularWeight,
    color: textBase,
  );
  final h2Serif = GoogleFonts.cormorantGaramond(
    fontSize: 32,
    height: 39 / 32.0,
    fontWeight: regularWeight,
    color: textBase,
  );
  final h3Serif = GoogleFonts.cormorantGaramond(
    fontSize: 24,
    height: 29 / 24.0,
    fontWeight: regularWeight,
    color: textBase,
  );
  final largeSerif = GoogleFonts.cormorantGaramond(
    fontSize: 18,
    height: 22 / 18.0,
    fontWeight: regularWeight,
    color: textBase,
  );

  // Keep body styles with Inter (from ente_ui)
  final body = TextStyle(
    fontSize: 16,
    height: 20 / 16.0,
    fontWeight: regularWeight,
    fontFamily: 'Inter',
    color: textBase,
  );
  final small = TextStyle(
    fontSize: 14,
    height: 17 / 14.0,
    fontWeight: regularWeight,
    fontFamily: 'Inter',
    color: textBase,
  );
  final mini = TextStyle(
    fontSize: 12,
    height: 15 / 12.0,
    fontWeight: regularWeight,
    fontFamily: 'Inter',
    color: textBase,
  );
  final tiny = TextStyle(
    fontSize: 10,
    height: 12 / 10.0,
    fontWeight: regularWeight,
    fontFamily: 'Inter',
    color: textBase,
  );

  final brandSmall = TextStyle(
    fontWeight: FontWeight.bold,
    fontFamily: serifFamily,
    fontSize: 21,
    color: textBase,
  );
  final brandMedium = TextStyle(
    fontWeight: FontWeight.bold,
    fontFamily: serifFamily,
    fontSize: 24,
    color: textBase,
  );

  return EnteTextTheme(
    // Serif for headings
    h1: h1Serif,
    h1Bold: h1Serif.copyWith(fontWeight: boldWeight),
    h2: h2Serif,
    h2Bold: h2Serif.copyWith(fontWeight: boldWeight),
    h3: h3Serif,
    h3Bold: h3Serif.copyWith(fontWeight: boldWeight),
    large: largeSerif,
    largeBold: largeSerif.copyWith(fontWeight: boldWeight),
    // Sans-serif for body
    body: body,
    bodyBold: body.copyWith(fontWeight: boldWeight),
    small: small,
    smallBold: small.copyWith(fontWeight: boldWeight),
    mini: mini,
    miniBold: mini.copyWith(fontWeight: boldWeight),
    tiny: tiny,
    tinyBold: tiny.copyWith(fontWeight: boldWeight),
    brandSmall: brandSmall,
    brandMedium: brandMedium,
    // Muted variants
    h1Muted: h1Serif.copyWith(color: textMuted),
    h2Muted: h2Serif.copyWith(color: textMuted),
    h3Muted: h3Serif.copyWith(color: textMuted),
    largeMuted: largeSerif.copyWith(color: textMuted),
    bodyMuted: body.copyWith(color: textMuted),
    smallMuted: small.copyWith(color: textMuted),
    miniMuted: mini.copyWith(color: textMuted),
    miniBoldMuted: mini.copyWith(color: textMuted, fontWeight: boldWeight),
    tinyMuted: tiny.copyWith(color: textMuted),
    // Faint variants
    h1Faint: h1Serif.copyWith(color: textFaint),
    h2Faint: h2Serif.copyWith(color: textFaint),
    h3Faint: h3Serif.copyWith(color: textFaint),
    largeFaint: largeSerif.copyWith(color: textFaint),
    bodyFaint: body.copyWith(color: textFaint),
    smallFaint: small.copyWith(color: textFaint),
    miniFaint: mini.copyWith(color: textFaint),
    tinyFaint: tiny.copyWith(color: textFaint),
  );
}

/// Ensu-specific EnteTextTheme with serif headings
final EnteTextTheme ensuLightTextTheme = _buildEnsuTextTheme(
  EnsuColors.ink,
  EnsuColors.muted,
  EnsuColors.muted.withValues(alpha: 0.5),
);

final EnteTextTheme ensuDarkTextTheme = _buildEnsuTextTheme(
  EnsuColors.inkDark,
  EnsuColors.mutedDark,
  EnsuColors.mutedDark.withValues(alpha: 0.5),
);

/// Helper to get Ensu's serif-headings text theme from context.
/// Falls back to standard EnteTextTheme if not in Ensu theme context.
EnteTextTheme getEnsuTextTheme(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.light ? ensuLightTextTheme : ensuDarkTextTheme;
}

class EnsuTheme {
  /// Creates EnteColorScheme for Ensu's light theme with gold accent.
  static EnteColorScheme _createLightColorScheme() {
    return EnteColorScheme.light(
      primary700: EnsuColors.accent,
      primary500: EnsuColors.accent,
      primary400: const Color(0xFFB89A1F),
      primary300: const Color(0xFFD6B939),
    ).copyWith(
      backgroundBase: EnsuColors.cream,
      backgroundElevated: const Color(0xFFFFFDF8),
      textBase: EnsuColors.ink,
      textMuted: EnsuColors.muted,
      fillFaint: EnsuColors.codeBg,
      strokeMuted: EnsuColors.rule,
    );
  }

  /// Creates EnteColorScheme for Ensu's dark theme with gold accent.
  static EnteColorScheme _createDarkColorScheme() {
    return EnteColorScheme.dark(
      primary700: EnsuColors.accentDark,
      primary500: EnsuColors.accentDark,
      primary400: const Color(0xFFE6C200),
      primary300: const Color(0xFFFFC300),
    ).copyWith(
      backgroundBase: EnsuColors.creamDark,
      backgroundElevated: const Color(0xFF1A1A1A),
      textBase: EnsuColors.inkDark,
      textMuted: EnsuColors.mutedDark,
      fillFaint: EnsuColors.codeBgDark,
      strokeMuted: EnsuColors.ruleDark,
    );
  }

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    final enteColorScheme = _createLightColorScheme();

    return base.copyWith(
      extensions: [enteColorScheme],
      scaffoldBackgroundColor: EnsuColors.cream,
      colorScheme: ColorScheme.light(
        surface: EnsuColors.cream,
        primary: EnsuColors.accent,
        onPrimary: Colors.white,
        secondary: EnsuColors.muted,
        onSecondary: EnsuColors.ink,
        outline: EnsuColors.rule,
        onSurface: EnsuColors.ink,
        primaryContainer: EnsuColors.codeBg,
        onPrimaryContainer: EnsuColors.ink,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: EnsuColors.cream,
        foregroundColor: EnsuColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.cormorantGaramond(
          fontSize: 24,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.5,
          color: EnsuColors.ink,
        ),
        iconTheme: const IconThemeData(color: EnsuColors.ink),
      ),
      textTheme:
          _buildTextTheme(base.textTheme, EnsuColors.ink, EnsuColors.muted),
      dividerTheme: const DividerThemeData(
        color: EnsuColors.rule,
        thickness: 1,
      ),
      cardColor: EnsuColors.cream,
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: EnsuColors.rule),
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: EnsuColors.rule),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: EnsuColors.accent),
        ),
        hintStyle: GoogleFonts.inter(
          color: EnsuColors.muted,
          fontSize: 15,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: EnsuColors.accent,
          foregroundColor: Colors.white,
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: EnsuColors.muted,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: EnsuColors.accent,
        foregroundColor: Colors.white,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: EnsuColors.cream,
      ),
      listTileTheme: ListTileThemeData(
        textColor: EnsuColors.ink,
        iconColor: EnsuColors.muted,
        selectedColor: EnsuColors.accent,
        selectedTileColor: EnsuColors.codeBg,
      ),
    );
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    final enteColorScheme = _createDarkColorScheme();

    return base.copyWith(
      extensions: [enteColorScheme],
      scaffoldBackgroundColor: EnsuColors.creamDark,
      colorScheme: ColorScheme.dark(
        surface: EnsuColors.creamDark,
        primary: EnsuColors.accentDark,
        onPrimary: EnsuColors.creamDark,
        secondary: EnsuColors.mutedDark,
        onSecondary: EnsuColors.inkDark,
        outline: EnsuColors.ruleDark,
        onSurface: EnsuColors.inkDark,
        primaryContainer: EnsuColors.codeBgDark,
        onPrimaryContainer: EnsuColors.inkDark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: EnsuColors.creamDark,
        foregroundColor: EnsuColors.inkDark,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.cormorantGaramond(
          fontSize: 24,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.5,
          color: EnsuColors.inkDark,
        ),
        iconTheme: const IconThemeData(color: EnsuColors.inkDark),
      ),
      textTheme: _buildTextTheme(
          base.textTheme, EnsuColors.inkDark, EnsuColors.mutedDark),
      dividerTheme: const DividerThemeData(
        color: EnsuColors.ruleDark,
        thickness: 1,
      ),
      cardColor: EnsuColors.creamDark,
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: EnsuColors.ruleDark),
        ),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: EnsuColors.ruleDark),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: EnsuColors.accentDark),
        ),
        hintStyle: GoogleFonts.inter(
          color: EnsuColors.mutedDark,
          fontSize: 15,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: EnsuColors.accentDark,
          foregroundColor: EnsuColors.creamDark,
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: EnsuColors.mutedDark,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: EnsuColors.accentDark,
        foregroundColor: EnsuColors.creamDark,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: EnsuColors.creamDark,
      ),
      listTileTheme: ListTileThemeData(
        textColor: EnsuColors.inkDark,
        iconColor: EnsuColors.mutedDark,
        selectedColor: EnsuColors.accentDark,
        selectedTileColor: EnsuColors.codeBgDark,
      ),
    );
  }

  static TextTheme _buildTextTheme(
      TextTheme base, Color primary, Color secondary) {
    return base.copyWith(
      // Serif for large display text (elegant, literary)
      displayLarge: GoogleFonts.cormorantGaramond(
        fontSize: 32,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      displayMedium: GoogleFonts.cormorantGaramond(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      displaySmall: GoogleFonts.cormorantGaramond(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      // Serif for headlines (maintains hierarchy)
      headlineLarge: GoogleFonts.cormorantGaramond(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      headlineMedium: GoogleFonts.cormorantGaramond(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      headlineSmall: GoogleFonts.cormorantGaramond(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      // Serif for large titles
      titleLarge: GoogleFonts.cormorantGaramond(
        fontSize: 20,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
        color: primary,
      ),
      // Sans-serif for medium/small titles (better UI readability)
      titleMedium: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: primary,
      ),
      titleSmall: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: secondary,
      ),
      // Sans-serif for body text (optimal reading)
      bodyLarge: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.6,
        color: primary,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.6,
        color: primary,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      // Sans-serif for labels (UI elements)
      labelLarge: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: primary,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: secondary,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: secondary,
      ),
    );
  }
}
