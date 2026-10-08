// -----------------------------------------------------------------------------
// LabTrack - Theme & branding
//
// Extracted verbatim from firstFile.dart on 2026-08-02 as step 1 of splitting the
// app into modules. Pure move: no logic was changed.
//
// _NeuSealPainter stays in this library because Dart privacy is per-library and
// NeuLogo is its only user.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

// ─── Theme ────────────────────────────────────────────────────────────────────

class AppTheme {
  // ── NEU Brand Colors ──────────────────────────────────────────────────────
  static const Color primary    = Color(0xFF1B3A8C);   // NEU royal blue
  static const Color primaryDark= Color(0xFF112266);   // darker navy for gradients
  static const Color accent     = Color(0xFFF5A623);   // NEU gold (from seal)
  static const Color success    = Color(0xFF27AE60);   // green
  static const Color warning    = Color(0xFFF39C12);   // amber-orange
  static const Color danger     = Color(0xFFE74C3C);   // red
  static const Color surface    = Color(0xFFF0F3FA);   // very light blue-grey
  static const Color cardBg     = Color(0xFFFFFFFF);
  static const Color textDark   = Color(0xFF1A2340);   // near-black blue
  static const Color textMid    = Color(0xFF5A6A8A);
  static const Color textLight  = Color(0xFF9AAAC8);
  static const Color divider    = Color(0xFFDDE4F0);

  static ThemeData get lightTheme => ThemeData(
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.light(
          primary: primary,
          secondary: accent,
          surface: surface,
        ),
        scaffoldBackgroundColor: surface,
        appBarTheme: const AppBarTheme(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
        cardTheme: CardThemeData(
          color: cardBg,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primary, width: 2),
          ),
        ),
      );
}

// ── NEU Logo Widget ───────────────────────────────────────────────────────────
// Uses a circular golden seal look matching the NEU crest.
// Replace with: Image.asset('assets/neu_logo.png') once you add the asset.
class NeuLogo extends StatelessWidget {
  final double size;
  const NeuLogo({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: AppTheme.accent, width: size * 0.04),
        boxShadow: [
          BoxShadow(
              color: const Color(0x40F5A623),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: ClipOval(
        // 👉 Swap this entire child with:
        //    Image.asset('assets/neu_logo.png', fit: BoxFit.cover)
        //    after adding the PNG to your assets folder.
        child: CustomPaint(
          painter: _NeuSealPainter(),
        ),
      ),
    );
  }
}

class _NeuSealPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    // Background fill
    canvas.drawCircle(Offset(cx, cy), r,
        Paint()..color = const Color(0xFF1B3A8C));

    // Outer gold ring
    canvas.drawCircle(
        Offset(cx, cy),
        r * 0.90,
        Paint()
          ..color = const Color(0xFFF5A623)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.06);

    // Inner white ring
    canvas.drawCircle(
        Offset(cx, cy),
        r * 0.75,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.03);

    // White "NEU" text in center
    final tp = TextPainter(
      text: TextSpan(
        text: 'NEU',
        style: TextStyle(
          color: Colors.white,
          fontSize: r * 0.30,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

    // Gold dots around ring
    final dotPaint = Paint()..color = const Color(0xFFF5A623);
    for (int i = 0; i < 12; i++) {
      final angle = (i / 12) * 3.14159 * 2;
      final dx = cx + r * 0.82 * cos(angle);
      final dy = cy + r * 0.82 * sin(angle);
      canvas.drawCircle(Offset(dx, dy), r * 0.025, dotPaint);
    }
  }

  double cos(double a) => _cos(a);
  double sin(double a) => _sin(a);
  static double _cos(double a) {
    // simple cos approximation via dart:math
    return _mathCos(a);
  }
  static double _sin(double a) {
    return _mathSin(a);
  }
  static double _mathCos(double a) => _mathFunc(a, true);
  static double _mathSin(double a) => _mathFunc(a, false);
  static double _mathFunc(double a, bool isCos) {
    // Taylor series — good enough for small circle dots
    double result = isCos ? 1.0 : a;
    double term = isCos ? 1.0 : a;
    for (int i = 1; i <= 10; i++) {
      int n = isCos ? 2 * i : 2 * i + 1;
      term *= -a * a / ((n - 1) * n);
      result += term;
    }
    return result;
  }

  @override
  bool shouldRepaint(_NeuSealPainter _) => false;
}
