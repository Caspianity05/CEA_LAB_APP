// -----------------------------------------------------------------------------
// LabTrack - student: change password screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Change Password Screen ───────────────────────────────────────────────────

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentCtrl = TextEditingController();
  final _newCtrl     = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNew     = true;
  bool _obscureConfirm = true;
  bool _saving = false;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_currentCtrl.text.isEmpty || _newCtrl.text.isEmpty || _confirmCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.'), backgroundColor: AppTheme.danger));
      return;
    }
    if (_newCtrl.text != _confirmCtrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New passwords do not match.'), backgroundColor: AppTheme.danger));
      return;
    }
    // Trimmed to match the login screen, which trims what it sends — a
    // password saved with a trailing space could otherwise never be used.
    final current = _currentCtrl.text.trim();
    final next    = _newCtrl.text.trim();
    if (next.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New password must be at least 8 characters.'), backgroundColor: AppTheme.danger));
      return;
    }
    if (next == current) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New password must be different from the current one.'), backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _saving = true);
    final res = await ApiService.changePassword(current, next);
    if (!mounted) return;
    setState(() => _saving = false);
    if (res['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message'] ?? 'Could not change password.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
        title: const Text('Password Changed!'),
        content: const Text('Your password has been updated successfully.',
            textAlign: TextAlign.center),
        actions: [
          ElevatedButton(
            onPressed: () { Navigator.pop(context); Navigator.pop(context); },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppTheme.textMid),
            suffixIcon: GestureDetector(
              onTap: onToggle,
              child: Icon(
                  obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  color: AppTheme.textMid),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change Password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Info banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0x121B3A8C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x261B3A8C))),
              child: const Row(children: [
                Icon(Icons.shield_outlined, color: AppTheme.primary, size: 20),
                SizedBox(width: 10),
                Expanded(child: Text(
                    'Use a strong password with at least 8 characters.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textDark))),
              ]),
            ),
            const SizedBox(height: 24),

            _passwordField(
              controller: _currentCtrl,
              label: 'Current Password',
              hint: 'Enter current password', // not bullets — see login field

              obscure: _obscureCurrent,
              onToggle: () => setState(() => _obscureCurrent = !_obscureCurrent),
            ),

            const Divider(color: AppTheme.divider, height: 8),
            const SizedBox(height: 16),

            _passwordField(
              controller: _newCtrl,
              label: 'New Password',
              hint: 'At least 8 characters',
              obscure: _obscureNew,
              onToggle: () => setState(() => _obscureNew = !_obscureNew),
            ),

            _passwordField(
              controller: _confirmCtrl,
              label: 'Confirm New Password',
              hint: 'Re-enter new password',
              obscure: _obscureConfirm,
              onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
            ),

            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.lock_reset_rounded),
                label: const Text('Update Password'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
