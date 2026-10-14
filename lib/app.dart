// -----------------------------------------------------------------------------
// LabTrack - application root widget
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import 'theme.dart';
import 'screens/auth/splash_screen.dart';

// ─── App Entry ───────────────────────────────────────────────────────────────
// (The real main() lives in lib/main.dart — this library only exports the app.)

class LabBorrowApp extends StatelessWidget {
  const LabBorrowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LabTrack',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const SplashScreen(),
    );
  }
}
