// -----------------------------------------------------------------------------
// LabTrack - login screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 5 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import '../staff/admin_dashboard_screen.dart';
import '../student/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import 'signup_screen.dart';

// ─── Login Screen ─────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isStudent = true;
  bool _obscure = true;
  bool _loading = false;
  bool _rememberMe = true;
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl   = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadRemembered();
  }

  // Restore the "remember me" choice and the saved identifier (never the
  // password) so a returning user finds their student number / email pre-filled.
  Future<void> _loadRemembered() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool('remember_me') ?? true;
      final savedId  = prefs.getString('saved_identifier') ?? '';
      final savedIsStudent = prefs.getBool('saved_is_student') ?? true;
      if (!mounted) return;
      setState(() {
        _rememberMe = remember;
        if (remember && savedId.isNotEmpty) {
          _isStudent = savedIsStudent;
          _identifierCtrl.text = savedId;
        }
      });
    } catch (_) {/* ignore — just start with defaults */}
  }

  Future<void> _saveRemembered(String identifier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('remember_me', _rememberMe);
      if (_rememberMe) {
        await prefs.setString('saved_identifier', identifier);
        await prefs.setBool('saved_is_student', _isStudent);
      } else {
        await prefs.remove('saved_identifier');
        await prefs.remove('saved_is_student');
      }
    } catch (_) {/* non-fatal */}
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // Clear fields and reset obscure when switching tabs
  void _switchRole(bool toStudent) {
    setState(() {
      _isStudent = toStudent;
      _identifierCtrl.clear();
      _passwordCtrl.clear();
      _obscure = true;
    });
  }

  Future<void> _forgotPassword() async {
    final emailCtrl = TextEditingController(
        text: _isStudent ? '' : _identifierCtrl.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reset Password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Enter your registered email address and we will send you a link '
            'to reset your password.',
            style: TextStyle(fontSize: 13, color: AppTheme.textMid, height: 1.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'name@neu.edu.ph',
              prefixIcon: Icon(Icons.email_outlined, color: AppTheme.textMid),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dialogCtx, emailCtrl.text.trim()),
              child: const Text('Send Link')),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;
    final res = await ApiService.sendPasswordReset(email);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? 'Password reset link sent to $email. Check your inbox and spam folder.'
          : (res['message'] ?? 'Could not send reset email.')),
      backgroundColor:
          res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _login() async {
    final id = _identifierCtrl.text.trim();
    final pw = _passwordCtrl.text.trim();
    if (id.isEmpty || pw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.'), backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiService.login(id, pw, _isStudent ? 'student' : 'staff');
      if (!mounted) return;
      if (res['success'] == true) {
        await _saveRemembered(id);
        if (!mounted) return;
        Session.set(res['user'] as Map<String, dynamic>, res['role'] as String);
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => _isStudent ? const StudentHomeScreen() : const AdminDashboardScreen()));
      } else if (res['message'] == 'email_not_verified') {
        _showVerificationDialog(res['email'] as String);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message'] ?? 'Login failed.'), backgroundColor: AppTheme.danger));
      }
    } catch (e) {
      // Never surface a raw exception to the user.
      final userMsg = ApiService.friendlyError(e);
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.wifi_off_rounded, color: AppTheme.danger),
              SizedBox(width: 10),
              Text('Connection Error'),
            ]),
            content: Text(userMsg, style: const TextStyle(fontSize: 13, height: 1.6)),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showVerificationDialog(String email) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: const BoxDecoration(color: Color(0x1FFFFB70), shape: BoxShape.circle),
            child: const Icon(Icons.mark_email_unread_outlined, color: AppTheme.accent, size: 40),
          ),
          const SizedBox(height: 20),
          const Text('Email Not Verified',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
          const SizedBox(height: 10),
          Text('Please verify your email ($email) before signing in. Check your inbox for a verification link.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                // Show loading spinner first, THEN await — so we can show
                // the result even if something goes wrong.
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );
                final res = await ApiService.resendVerificationEmail(
                    email, _passwordCtrl.text.trim());
                if (!mounted) return;
                Navigator.pop(context); // close loading spinner
                Navigator.pop(context); // close verification dialog
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(res['success'] == true
                      ? 'Verification email sent! Check your inbox and spam folder.'
                      : (res['message'] ?? 'Failed to send. Please try again.')),
                  backgroundColor:
                      res['success'] == true ? AppTheme.success : AppTheme.danger,
                  duration: const Duration(seconds: 6),
                ));
              },
              child: const Text('Resend Verification Email'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            const NeuLogo(size: 60),
            const SizedBox(height: 12),
            const Text('LabTrack',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5)),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Mobile Equipment Borrowing\n& Return Monitoring System',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.4),
              ),
            ),
            const SizedBox(height: 4),
            const Text('for School Laboratories · CEA · NEU',
                style: TextStyle(
                    color: AppTheme.textLight,
                    fontSize: 11)),
            const SizedBox(height: 28),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                padding: const EdgeInsets.all(28),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      // Role Toggle
                      Container(
                        decoration: BoxDecoration(
                          color: AppTheme.divider,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            _RoleTab(
                                label: 'Student',
                                icon: Icons.school_rounded,
                                selected: _isStudent,
                                onTap: () => _switchRole(true)),
                            _RoleTab(
                                label: 'Lab Staff',
                                icon: Icons.admin_panel_settings_rounded,
                                selected: !_isStudent,
                                onTap: () => _switchRole(false)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      const Text('Welcome back',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 4),
                      Text(
                          _isStudent
                              ? 'Sign in to borrow lab equipment'
                              : 'Sign in to manage the lab',
                          style: const TextStyle(
                              color: AppTheme.textMid, fontSize: 14)),
                      const SizedBox(height: 24),
                      Text(
                          _isStudent ? 'Student ID / Email' : 'Email Address',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _identifierCtrl,
                        keyboardType: _isStudent
                            ? TextInputType.text
                            : TextInputType.emailAddress,
                        autocorrect: false,
                        decoration: InputDecoration(
                          hintText: _isStudent
                              ? 'e.g. 26-12345-123'
                              : 'staff@neu.edu.ph',
                          prefixIcon: Icon(
                              _isStudent
                                  ? Icons.person_outline_rounded
                                  : Icons.email_outlined,
                              color: AppTheme.textMid),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('Password',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          // NOT a row of bullets: "remember me" restores the
                          // identifier but never the password, so a bullet hint
                          // over an empty field is indistinguishable from a
                          // filled obscured one — users tapped Sign In and got
                          // "Please fill in all fields" on a form that looked complete.
                          hintText: 'Enter your password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded,
                              color: AppTheme.textMid),
                          suffixIcon: GestureDetector(
                            onTap: () => setState(() => _obscure = !_obscure),
                            child: Icon(
                                _obscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: AppTheme.textMid),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Remember me
                          GestureDetector(
                            onTap: () => setState(() => _rememberMe = !_rememberMe),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              SizedBox(
                                width: 22, height: 22,
                                child: Checkbox(
                                  value: _rememberMe,
                                  onChanged: (v) =>
                                      setState(() => _rememberMe = v ?? true),
                                  activeColor: AppTheme.primary,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('Remember me',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textMid,
                                      fontWeight: FontWeight.w500)),
                            ]),
                          ),
                          // Forgot password
                          GestureDetector(
                            onTap: _forgotPassword,
                            child: const Text('Forgot password?',
                                style: TextStyle(
                                    color: AppTheme.accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _login,
                          child: _loading
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Text('Sign In'),
                        ),
                      ),
                      // ── Sign Up Link (students only) ──
                      if (_isStudent) ...[
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text("Don't have an account? ",
                                style: TextStyle(
                                    fontSize: 13, color: AppTheme.textMid)),
                            GestureDetector(
                              onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const SignUpScreen())),
                              child: const Text('Sign Up',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _RoleTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _RoleTab(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected ? AppTheme.accent : AppTheme.textMid),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      color: selected ? Colors.white : AppTheme.textMid,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
