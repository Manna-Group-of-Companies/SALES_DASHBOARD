
import 'package:flutter/material.dart';

import 'package:manna_field_sales/screens/auth/login_screen.dart';
import 'package:manna_field_sales/widgets/app_lock_gate.dart';
import 'package:manna_field_sales/widgets/responsive_frame.dart';
import 'package:manna_field_sales/widgets/sync_all_button.dart';

class MannaApp extends StatelessWidget {
  const MannaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manna Field Sales',
      debugShowCheckedModeBanner: false,
      // The Sync button on every screen — see widgets/sync_all_button.dart for
      // why it is placed here rather than in fifty AppBars.
      scaffoldMessengerKey: SapSyncAll.messengerKey,
      navigatorObservers: [SapSyncAll.observer],
      // The fingerprint / screen-lock gate goes outermost, so it covers the
      // Sync button too. Inside it, the app is held to a readable width on a
      // tablet (widgets/responsive_frame.dart), Sync button included.
      builder: (context, child) => AppLockGate(
          child: ResponsiveFrame(
              child: SyncAllOverlay(child: child ?? const SizedBox.shrink()))),
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
        // Every popup: white, not Material's pink tint.
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 6,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          titleTextStyle: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black87),
          contentTextStyle: const TextStyle(
              fontSize: 14.5, height: 1.4, color: Colors.black87),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          showDragHandle: true,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        ),
        datePickerTheme: const DatePickerThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}

// -------------------- LOGIN --------------------
