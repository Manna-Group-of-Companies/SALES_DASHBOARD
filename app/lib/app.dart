
import 'package:flutter/material.dart';

import 'package:manna_field_sales/screens/auth/login_screen.dart';

class MannaApp extends StatelessWidget {
  const MannaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manna Field Sales',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF46A21),
          primary: const Color(0xFFF46A21),
          secondary: const Color(0xFF3F3F3F),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F7F8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF3F3F3F),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFFECECEC))),
          margin: const EdgeInsets.symmetric(vertical: 6),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFF46A21),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF46A21),
            foregroundColor: Colors.white,
          ),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}

// -------------------- LOGIN --------------------
