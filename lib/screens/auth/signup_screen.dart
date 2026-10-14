// -----------------------------------------------------------------------------
// LabTrack - student sign-up
//
// Extracted from firstFile.dart on 2026-08-03 as step 5 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'legal_screens.dart';
import 'login_screen.dart';

// ─── Sign Up Screen ───────────────────────────────────────────────────────────

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _studentIdCtrl = TextEditingController();
  String? _selectedCourse;
  final _yearCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _agreedToTerms = false;

  // Live email validation state
  bool get _emailValid => kDemoMode
      ? _emailCtrl.text.trim().contains('@')
      : RegExp(r'^[a-zA-Z0-9._%+\-]+@neu\.edu\.ph$')
          .hasMatch(_emailCtrl.text.trim());

  // Live student ID validation (##-#####-### format)
  bool get _idValid =>
      RegExp(r'^\d{2}-\d{5}-\d{3}$').hasMatch(_studentIdCtrl.text.trim());

  // Validate: must be NEU email domain only (relaxed in demo mode)
  String? _validateEmail(String? val) {
    if (val == null || val.trim().isEmpty) return 'Email is required';
    if (!val.trim().contains('@')) return 'Enter a valid email address';
    if (!kDemoMode && !val.trim().toLowerCase().endsWith('@neu.edu.ph')) {
      return 'Must be an official NEU email (@neu.edu.ph)';
    }
    return null;
  }

  // Validate: NEU student ID format ##-#####-###
  String? _validateStudentId(String? val) {
    if (val == null || val.trim().isEmpty) return 'Student ID is required';
    if (!RegExp(r'^\d{2}-\d{5}-\d{3}$').hasMatch(val.trim())) {
      return 'Invalid format — e.g. 26-12345-123';
    }
    return null;
  }

  String? _validateRequired(String? val) {
    if (val == null || val.trim().isEmpty) return 'Required';
    return null;
  }

  String? _validatePassword(String? val) {
    if (val == null || val.isEmpty) return 'Required';
    if (val.length < 8) return 'At least 8 characters';
    return null;
  }

  String? _validateConfirmPass(String? val) {
    if (val == null || val.isEmpty) return 'Required';
    if (val != _passCtrl.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _submitSignUp() async {
    if (_formKey.currentState!.validate()) {
      if (!_agreedToTerms) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please agree to the Terms and Conditions'), backgroundColor: AppTheme.danger));
        return;
      }
      // Show loading
      showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

      try {
        final res = await ApiService.registerStudent({
          'first_name':     _firstNameCtrl.text.trim(),
          'last_name':      _lastNameCtrl.text.trim(),
          'email':          _emailCtrl.text.trim(),
          'student_number': _studentIdCtrl.text.trim(),
          'course':         _selectedCourse ?? '',
          'year_level':     int.tryParse(_yearCtrl.text.trim()) ?? 1,
          // Trimmed to match login, which has always trimmed. A password with
          // a trailing space could be created and then never signed in with
          // (QA 2026-09-19, low #10).
          'password':       _passCtrl.text.trim(),
        });
        if (!mounted) return;
        Navigator.pop(context); // close loading

        if (res['success'] == true) {
          showDialog(context: context, barrierDismissible: false,
            builder: (_) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 72, height: 72,
                  decoration: BoxDecoration(color: const Color(0x1F06D6A0), shape: BoxShape.circle),
                  child: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 40)),
                const SizedBox(height: 20),
                const Text('Account Created!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                const SizedBox(height: 10),
                Text(kDemoMode
                        ? 'Welcome, ${_firstNameCtrl.text}! Your account is ready — you can sign in now with your student number and password.'
                        : 'Welcome, ${_firstNameCtrl.text}! A verification link has been sent to ${_emailCtrl.text.trim()}. Please check your inbox and verify your email before signing in.',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
                const SizedBox(height: 24),
                SizedBox(width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () { Navigator.pop(context); Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen())); },
                    child: const Text('Go to Sign In'))),
              ]),
            ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res['message'] ?? 'Registration failed.'), backgroundColor: AppTheme.danger));
        }
      } catch (e) {
        // This pop was unguarded: if the throw happened AFTER the loading
        // dialog was already closed, it popped the sign-up screen itself and
        // the user was thrown back to login mid-error. Only close what is
        // actually still up.
        //
        // NOTE: QA 2026-09-19 low #12 also reports "every sign-up error prints
        // twice". That was NOT reproduced here — registerStudent returns a
        // result map rather than throwing, so this catch does not run on an
        // ordinary failure. Left open; it needs a repro first.
        if (mounted) {
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not create the account. Check your internet connection and try again.'), backgroundColor: AppTheme.danger));
        }
      }
    }
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _studentIdCtrl.dispose();
    _yearCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 24, 20),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Create Account',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                        Text('Student Registration',
                            style: TextStyle(
                                color: AppTheme.textLight, fontSize: 12)),
                      ],
                    ),
                  ),
                  const NeuLogo(size: 40),
                ],
              ),
            ),
            // Form Sheet
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        // ── NEU Students Only Banner ──
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0x1A1B3A8C),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppTheme.primary.withAlpha(50)),
                          ),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color: AppTheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.school_rounded,
                                  color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('NEU Students Only',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: AppTheme.primary)),
                                  SizedBox(height: 4),
                                  Text(
                                    'This system is exclusively for students of New Era University — College of Engineering and Architecture. Registration requires a valid NEU email address (@neu.edu.ph) and your official student ID number.',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textMid,
                                        height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 20),

                        // ── SECTION: Identity Verification ──
                        SectionDivider(
                          icon: Icons.verified_user_outlined,
                          label: 'Identity Verification',
                          color: AppTheme.accent,
                        ),
                        const SizedBox(height: 16),

                        // Institutional Email
                        FieldLabel('NEU Email Address'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          validator: _validateEmail,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'yourname@neu.edu.ph',
                            prefixIcon: const Icon(Icons.email_outlined,
                                color: AppTheme.textMid),
                            suffixIcon: _emailCtrl.text.isNotEmpty
                                ? Icon(
                                    _emailValid
                                        ? Icons.check_circle_rounded
                                        : Icons.cancel_rounded,
                                    color: _emailValid
                                        ? AppTheme.success
                                        : AppTheme.danger,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(children: [
                          Icon(
                            _emailCtrl.text.isEmpty
                                ? Icons.info_outline_rounded
                                : _emailValid
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                            size: 12,
                            color: _emailCtrl.text.isEmpty
                                ? AppTheme.textLight
                                : _emailValid
                                    ? AppTheme.success
                                    : AppTheme.danger,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _emailCtrl.text.isEmpty
                                ? 'Must end with @neu.edu.ph'
                                : _emailValid
                                    ? 'Valid NEU email ✓'
                                    : 'Only @neu.edu.ph emails are accepted',
                            style: TextStyle(
                              fontSize: 11,
                              color: _emailCtrl.text.isEmpty
                                  ? AppTheme.textLight
                                  : _emailValid
                                      ? AppTheme.success
                                      : AppTheme.danger,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 16),

                        // Student ID
                        FieldLabel('Student ID Number'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _studentIdCtrl,
                          keyboardType: TextInputType.text,
                          autocorrect: false,
                          validator: _validateStudentId,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'e.g. 26-12345-123',
                            prefixIcon: const Icon(Icons.badge_outlined,
                                color: AppTheme.textMid),
                            suffixIcon: _studentIdCtrl.text.isNotEmpty
                                ? Icon(
                                    _idValid
                                        ? Icons.check_circle_rounded
                                        : Icons.cancel_rounded,
                                    color: _idValid
                                        ? AppTheme.success
                                        : AppTheme.danger,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(children: [
                          Icon(
                            _studentIdCtrl.text.isEmpty
                                ? Icons.info_outline_rounded
                                : _idValid
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                            size: 12,
                            color: _studentIdCtrl.text.isEmpty
                                ? AppTheme.textLight
                                : _idValid
                                    ? AppTheme.success
                                    : AppTheme.danger,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _studentIdCtrl.text.isEmpty
                                ? 'Format: 26-12345-123'
                                : _idValid
                                    ? 'Valid student ID format ✓'
                                    : 'Invalid format — check your ID number',
                            style: TextStyle(
                              fontSize: 11,
                              color: _studentIdCtrl.text.isEmpty
                                  ? AppTheme.textLight
                                  : _idValid
                                      ? AppTheme.success
                                      : AppTheme.danger,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 20),

                        // Verification info box
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0x0FF5A623),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: const Color(0x33F5A623)),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.verified_user_outlined,
                                  size: 16, color: AppTheme.accent),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                    'Your NEU email and Student ID are used to verify that you are an enrolled CEA student. Accounts with non-NEU emails or invalid student IDs will not be approved by laboratory staff.',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textMid,
                                        height: 1.5)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── SECTION: Personal Information ──
                        SectionDivider(
                          icon: Icons.person_outline_rounded,
                          label: 'Personal Information',
                          color: AppTheme.primary,
                        ),
                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FieldLabel('First Name'),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _firstNameCtrl,
                                    validator: _validateRequired,
                                    decoration: const InputDecoration(
                                        hintText: 'e.g. Juan'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FieldLabel('Last Name'),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _lastNameCtrl,
                                    validator: _validateRequired,
                                    decoration: const InputDecoration(
                                        hintText: 'e.g. Dela Cruz'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FieldLabel('Course / Program'),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    value: _selectedCourse,
                                    validator: (v) => v == null ? 'Required' : null,
                                    decoration: const InputDecoration(
                                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
                                    hint: const Text('Select course'),
                                    isExpanded: true,
                                    items: kCourses.map((c) => DropdownMenuItem(value: c, child: Text(courseLabel(c)))).toList(),
                                    onChanged: (v) => setState(() => _selectedCourse = v),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FieldLabel('Year Level'),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    validator: (v) =>
                                        v == null ? 'Required' : null,
                                    decoration: const InputDecoration(
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 14)),
                                    hint: const Text('Year'),
                                    items: ['1st', '2nd', '3rd', '4th', '5th']
                                        .map((y) => DropdownMenuItem(
                                            value: y, child: Text(y)))
                                        .toList(),
                                    onChanged: (v) =>
                                        setState(() => _yearCtrl.text = v ?? ''),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // ── SECTION: Account Security ──
                        SectionDivider(
                          icon: Icons.lock_outline_rounded,
                          label: 'Account Security',
                          color: AppTheme.warning,
                        ),
                        const SizedBox(height: 16),

                        FieldLabel('Password'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _passCtrl,
                          obscureText: _obscurePass,
                          validator: _validatePassword,
                          decoration: InputDecoration(
                            hintText: 'Minimum 8 characters',
                            prefixIcon: const Icon(Icons.lock_outline_rounded,
                                color: AppTheme.textMid),
                            suffixIcon: GestureDetector(
                              onTap: () =>
                                  setState(() => _obscurePass = !_obscurePass),
                              child: Icon(
                                  _obscurePass
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppTheme.textMid),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        FieldLabel('Confirm Password'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _confirmPassCtrl,
                          obscureText: _obscureConfirm,
                          validator: _validateConfirmPass,
                          decoration: InputDecoration(
                            hintText: 'Re-enter your password',
                            prefixIcon: const Icon(Icons.lock_outline_rounded,
                                color: AppTheme.textMid),
                            suffixIcon: GestureDetector(
                              onTap: () => setState(
                                  () => _obscureConfirm = !_obscureConfirm),
                              child: Icon(
                                  _obscureConfirm
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppTheme.textMid),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Terms and Conditions
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () => setState(
                                  () => _agreedToTerms = !_agreedToTerms),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 22, height: 22,
                                decoration: BoxDecoration(
                                  color: _agreedToTerms
                                      ? AppTheme.accent
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: _agreedToTerms
                                          ? AppTheme.accent
                                          : AppTheme.textLight,
                                      width: 1.5),
                                ),
                                child: _agreedToTerms
                                    ? const Icon(Icons.check_rounded,
                                        color: Colors.white, size: 14)
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  text: 'I have read and agree to the ',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textMid),
                                  children: [
                                    WidgetSpan(
                                      child: GestureDetector(
                                        onTap: () => Navigator.push(context,
                                            MaterialPageRoute(builder: (_) =>
                                                const TermsAndConditionsScreen())),
                                        child: const Text('Terms and Conditions',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: AppTheme.accent,
                                                fontWeight: FontWeight.bold,
                                                decoration: TextDecoration.underline)),
                                      ),
                                    ),
                                    const TextSpan(text: ' and '),
                                    WidgetSpan(
                                      child: GestureDetector(
                                        onTap: () => Navigator.push(context,
                                            MaterialPageRoute(builder: (_) =>
                                                const PrivacyPolicyScreen())),
                                        child: const Text('Privacy Policy',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: AppTheme.accent,
                                                fontWeight: FontWeight.bold,
                                                decoration: TextDecoration.underline)),
                                      ),
                                    ),
                                    const TextSpan(
                                        text: ' of the LabTrack borrowing system.'),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // Submit Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _submitSignUp,
                            icon: const Icon(Icons.how_to_reg_rounded),
                            label: const Text('Create Account'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('Already have an account? ',
                                style: TextStyle(
                                    fontSize: 13, color: AppTheme.textMid)),
                            GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: const Text('Sign In',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
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

// ── Sign Up helper widgets ──

