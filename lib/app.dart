// -----------------------------------------------------------------------------
// LabTrack - application root widget
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'theme.dart';
import 'screens/auth/splash_screen.dart';

// ─── App Entry ───────────────────────────────────────────────────────────────
// (The real main() lives in lib/main.dart — this library only exports the app.)

// The web build is the staff portal (prof's comment 2026-10-05). It fills the
// browser window, and the staff screens lay themselves out for the width they
// get. (It used to sit in a centred 1280 px frame, which left a wide monitor
// with grey bars on both sides — the user, 2026-10-06.)
class LabBorrowApp extends StatelessWidget {
  const LabBorrowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kIsWeb ? 'LabTrack Staff Portal' : 'LabTrack',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const SplashScreen(),
    );
  }
}
