// -----------------------------------------------------------------------------
// LabTrack - login screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 5 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/foundation.dart' show kIsWeb;
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
  // The web build is the staff portal (prof's comment 2026-10-05: "web for
  // staff only, mobile for the staff and student"), so it only ever signs in
  // staff; students use the phone app.
  bool _isStudent = !kIsWeb;
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
  // password) so a returning user finds their email pre-filled. A student
  // number saved before 2026-10-13, when students could sign in with it, is
  // left out: only an email signs in now.
  Future<void> _loadRemembered() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool('remember_me') ?? true;
      final savedId  = prefs.getString('saved_identifier') ?? '';
      final savedIsStudent = prefs.getBool('saved_is_student') ?? true;
      if (!mounted) return;
      setState(() {
        _rememberMe = remember;
        // On the web, only a saved staff sign-in is restored.
        if (remember && savedId.contains('@') && (!kIsWeb || !savedIsStudent)) {
          _isStudent = !kIsWeb && savedIsStudent;
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
    // Both tabs sign in with an email (students since 2026-10-13), so the
    // address already typed is offered for the reset. It used to be left out
    // on the Student tab, where the field could hold a student number.
    final typed = _identifierCtrl.text.trim();
    final emailCtrl =
        TextEditingController(text: typed.contains('@') ? typed : '');
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
    // The portal signs staff in by e-mail only. A student number typed here
    // means a student tried the portal, so point them to the app.
    if (kIsWeb && !id.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sign in with your staff e-mail address. Students: '
              'please use the LabTrack app on your phone.'),
          backgroundColor: AppTheme.danger));
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
        // A student signing in to the staff portal is refused as "no staff
        // account"; on the web, say where students should go instead.
        final msg = kIsWeb && res['message'] == 'Staff account not found.'
            ? 'This portal is for laboratory staff. Students: please use the '
                'LabTrack app on your phone.'
            : (res['message'] ?? 'Login failed.');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppTheme.danger));
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
        child: _webCentered(Column(
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
            Text(kIsWeb ? 'Staff Portal · CEA · NEU' : 'for School Laboratories · CEA · NEU',
                style: const TextStyle(
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
                      // Role Toggle (phone app only; the web portal is staff only)
                      if (!kIsWeb) ...[
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
                      ] else ...[
                        const Row(children: [
                          Icon(Icons.admin_panel_settings_rounded,
                              color: AppTheme.primary, size: 20),
                          SizedBox(width: 8),
                          Text('Lab Staff Portal',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primary)),
                        ]),
                        const SizedBox(height: 4),
                        const Text(
                            'Students borrow equipment with the LabTrack app on their phone.',
                            style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
                        const SizedBox(height: 20),
                      ],
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
                      // Students and staff both sign in with their email
                      // (students used a student number until 2026-10-13).
                      const Text('Email Address',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _identifierCtrl,
                        keyboardType: TextInputType.emailAddress,
                        // The keyboard key moves on to the password (it was
                        // "Done", which only closed the keyboard; QA 2026-10-06).
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        decoration: InputDecoration(
                          hintText: _isStudent
                              ? 'name@neu.edu.ph'
                              : 'staff@neu.edu.ph',
                          prefixIcon: const Icon(Icons.email_outlined,
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
                        // Enter signs in, as a computer user expects (and the
                        // phone keyboard's Done key does the same).
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (!_loading) _login();
                        },
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
        )),
      ),
    );
  }

  // On the web the sign-in column is a centred card instead of spanning the
  // monitor; on a phone it is unchanged.
  Widget _webCentered(Widget child) => kIsWeb
      ? Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: child,
          ),
        )
      : child;
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
