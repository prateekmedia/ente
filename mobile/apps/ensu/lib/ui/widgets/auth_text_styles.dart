import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

TextStyle authHeadingStyle(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final headingColor = isDark ? EnsuColors.accentDark : EnsuColors.accent;

  return GoogleFonts.cormorantGaramond(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: headingColor,
  );
}

TextStyle authSubheadingStyle(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final subheadingColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;

  return GoogleFonts.cormorantGaramond(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.4,
    letterSpacing: 0.4,
    color: subheadingColor,
  );
}
