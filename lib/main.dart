import 'package:flutter/material.dart';
import 'package:smart_wearables_app/connection/connection_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Soft pastel green used to seed the whole Material 3 palette.
  static const Color _pastelGreen = Color(0xFF7FC8A0);

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _pastelGreen,
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Smart Fitness Glasses',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        // Flat, shadow-free look across the app: a transparent shadow colour
        // removes every Material drop shadow regardless of elevation, and the
        // component themes below pin elevations/tints to zero so surfaces stay
        // crisp on the pastel-green background.
        shadowColor: Colors.transparent,
        scaffoldBackgroundColor: const Color(0xFFE6F4EC),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          shadowColor: Colors.transparent,
        ),
        // Shadows are off, so cards are defined by a clean white fill plus a
        // soft green outline that stands out against the pastel-green
        // background instead of relying on elevation.
        cardTheme: CardThemeData(
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF8ECCAC), width: 1.5),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          elevation: 0,
          focusElevation: 0,
          hoverElevation: 0,
          highlightElevation: 0,
          disabledElevation: 0,
        ),
        dialogTheme: const DialogThemeData(
          elevation: 0,
          shadowColor: Colors.transparent,
        ),
        snackBarTheme: const SnackBarThemeData(elevation: 0),
        bottomSheetTheme: const BottomSheetThemeData(elevation: 0),
        popupMenuTheme: const PopupMenuThemeData(elevation: 0),
      ),

      home: const ConnectionPage(title: 'Smart Fitness Glasses'),
    );
  }
}