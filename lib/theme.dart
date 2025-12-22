import 'package:flutter/material.dart';

class AppColors {
  static const primary = Color(0xFF4DD0E1);
  static const primaryLight = Color(0xFF80DEEA);
  static const primaryDark = Color(0xFF0097A7);
  static const taken = Color(0xFF43A047);
  static const pending = Color(0xFFFB8C00);
  static const missed = Color(0xFFE53935);
  static const muted = Color(0xFF90A4AE);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primaryDark,
    secondary: AppColors.primary,
  );
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF7FBFC),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: rounded,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primaryDark,
        side: const BorderSide(color: AppColors.primary),
        minimumSize: const Size.fromHeight(50),
        shape: rounded,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 1.5,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      indicatorColor: AppColors.primaryLight,
      backgroundColor: Colors.white,
    ),
  );
}
