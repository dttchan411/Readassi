import 'package:flutter/material.dart';

ThemeData buildReadAssiTheme() {
  const background = Color(0xFFFDFBF7);
  const primary = Color(0xFFB5651D);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: Brightness.light,
    surface: background,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      displayMedium: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      displaySmall: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      headlineLarge: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      headlineMedium: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      headlineSmall: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      titleLarge: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      titleMedium: TextStyle(fontFamily: 'serif', color: Color(0xFF2F2A25)),
      bodyLarge: TextStyle(color: Color(0xFF2F2A25)),
      bodyMedium: TextStyle(color: Color(0xFF2F2A25)),
      bodySmall: TextStyle(color: Color(0xFF756C63)),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 1.5,
      shadowColor: Colors.black.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFFE6DDD4)),
      ),
    ),
  );
}
