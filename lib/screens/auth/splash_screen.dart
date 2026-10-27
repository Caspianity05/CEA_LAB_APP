// -----------------------------------------------------------------------------
// LabTrack - splash / session restore
//
// Extracted from firstFile.dart on 2026-08-03 as step 5 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../staff/admin_dashboard_screen.dart';
import '../student/home_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import 'login_screen.dart';

// ─── Splash Screen ────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
    Future.delayed(const Duration(seconds: 2), _checkSession);
  }

  void _goLogin() {
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _checkSession() async {
    if (!mounted) return;
    try {
      final firebaseUser = FirebaseAuth.instance.currentUser;

      // Respect the "Remember me" choice. If it was off (or there's no session),
      // go straight to login — and sign out any lingering session so it isn't
      // silently restored.
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool('remember_me') ?? true;
      if (firebaseUser == null || !remember) {
        if (firebaseUser != null && !remember) {
          await FirebaseAuth.instance.signOut();
        }
        _goLogin();
        return;
      }

      final uid = firebaseUser.uid;
      final db  = FirebaseFirestore.instance;
      const limit = Duration(seconds: 8); // never hang on the splash

      // Try to restore as student
      final studentDoc =
          await db.collection('students').doc(uid).get().timeout(limit);
      if (!mounted) return;
      if (studentDoc.exists) {
        // Same e-mail verification gate as login(). A restored session must
        // never be the weaker door: an unverified account used to get in by
        // leaving a session behind from a failed Lab Staff sign-in and then
        // relaunching (QA 2026-09-19, H3). The web build is the staff portal,
        // so a student session is never restored there either.
        if (kIsWeb || !ApiService.passesVerificationGate(studentDoc.data())) {
          await ApiService.signOut();
          _goLogin();
          return;
        }
        Session.set({...studentDoc.data()!, 'student_id': uid}, 'student');
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const StudentHomeScreen()));
        return;
      }

      // Try to restore as staff
      final staffDoc =
          await db.collection('staff').doc(uid).get().timeout(limit);
      if (!mounted) return;
      if (staffDoc.exists) {
        if (!ApiService.passesVerificationGate(staffDoc.data(), isStaff: true)) {
          await ApiService.signOut();
          _goLogin();
          return;
        }
        Session.set({...staffDoc.data()!, 'staff_id': uid}, 'staff');
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const AdminDashboardScreen()));
        return;
      }

      // Auth token exists but no Firestore profile — sign out cleanly.
      await FirebaseAuth.instance.signOut();
      _goLogin();
    } catch (_) {
      // Any failure (offline, timeout, permission, etc.) → fall back to login
      // so the app never gets stuck on the splash screen.
      _goLogin();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: FadeTransition(
        opacity: _fade,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppTheme.primaryDark, AppTheme.primary],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                Container(
                  width: 100, height: 100,
                  decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                        color: const Color(0x33FFFFFF), width: 1.5),
                  ),
                  child: const Icon(Icons.science_rounded,
                      color: AppTheme.accent, size: 52),
                ),
                const SizedBox(height: 24),
                // App name
                const Text('LabTrack',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2)),
                const SizedBox(height: 10),
                // Full system title
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'Mobile Equipment Borrowing\n& Return Monitoring System',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.4),
                  ),
                ),
                const SizedBox(height: 6),
                const Text('for School Laboratories',
                    style: TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 12,
                        letterSpacing: 0.5)),
                const SizedBox(height: 8),
                const Text('CEA · New Era University',
                    style: TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 11,
                        letterSpacing: 0.5)),
                const SizedBox(height: 56),
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        color: AppTheme.accent, strokeWidth: 2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

