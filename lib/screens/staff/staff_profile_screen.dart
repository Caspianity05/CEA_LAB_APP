// -----------------------------------------------------------------------------
// LabTrack - staff: my profile screen
//
// Added 2026-09-23 alongside the seven provisioned admin accounts. Staff
// accounts are created out-of-band (Firebase console or scripts/create-admins.js)
// and `staff/{uid}` was closed to the client entirely, so a staff member could
// not correct their own display name at all — the name stamped onto every
// request they approve (`approved_by_name`).
//
// This is the one staff-side self-service write: the display name, and nothing
// else. Email and role are read-only on purpose — `role` is what every rule in
// firestore.rules authorises against, and `email` is the staff login
// identifier, so both stay with whoever provisioned the account.
//
// Password changes reuse the student ChangePasswordScreen, which is
// role-agnostic (it re-authenticates through Firebase Auth and touches no
// Firestore document). For the provisioned admin addresses it is the only
// self-service password path, since "Forgot password?" needs a real mailbox.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../student/change_password_screen.dart';

// ─── Staff Profile Screen ─────────────────────────────────────────────────────

class StaffProfileScreen extends StatefulWidget {
  const StaffProfileScreen({super.key});
  @override
  State<StaffProfileScreen> createState() => _StaffProfileScreenState();
}

class _StaffProfileScreenState extends State<StaffProfileScreen> {
  late TextEditingController _nameCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: Session.name);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    // The same bounds firestore.rules enforces, checked here so a mistake reads
    // as a sentence instead of arriving back as a refusal.
    if (name.length < 2) {
      _snack('Please enter your full name (at least 2 characters).', AppTheme.danger);
      return;
    }
    if (name.length > 60) {
      _snack('That name is too long (60 characters maximum).', AppTheme.danger);
      return;
    }
    if (name == Session.name) {
      _snack('That is already your name.', AppTheme.textMid);
      return;
    }

    setState(() => _saving = true);
    try {
      final res = await ApiService.updateStaffName(
        staffId: Session.staffId,
        name:    name,
      );
      if (!mounted) return;

      if (res['success'] == true) {
        // Keep the in-memory session in step, so the dashboard header and the
        // approval audit trail it stamps both use the new name immediately.
        Session.currentUser?['name'] = name;
        _snack('Profile updated successfully!', AppTheme.success);
        Navigator.pop(context, true);
      } else {
        _snack(res['message'] ?? 'Update failed.', AppTheme.danger);
      }
    } catch (e) {
      if (mounted) _snack('Cannot connect to server.', AppTheme.danger);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // One read-only row: icon, label, value, and a "Read-only" badge.
  Widget _readOnlyRow(IconData icon, String label, String value) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.divider)),
        child: Row(children: [
          Icon(icon, color: AppTheme.textMid, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
              Text(value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
            ]),
          ),
          const SizedBox(width: 8),
          const StatusBadge(label: 'Read-only', color: AppTheme.textLight),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final viewer = Session.isViewer;
    final email  = '${Session.currentUser?['email'] ?? '—'}';
    final role   = viewer ? 'VIEW ONLY' : Session.staffRoleLabel;

    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      body: SingleChildScrollView(
        padding: readablePadding(context, const EdgeInsets.all(24), maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: CircleAvatar(
                radius: 48,
                backgroundColor: const Color(0x26F5A623),
                child: Text(Session.initials,
                    style: const TextStyle(
                        color: AppTheme.accent, fontSize: 34, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 28),

            _readOnlyRow(Icons.email_outlined, 'Sign-in email', email),
            const SizedBox(height: 12),
            _readOnlyRow(Icons.shield_outlined, 'Access level', role),
            const SizedBox(height: 8),
            const Text(
              'Your sign-in email and access level are set by an administrator '
              'and cannot be changed from the app.',
              style: TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4),
            ),
            const SizedBox(height: 20),

            FieldLabel('Display Name'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              enabled: !viewer && !_saving,
              textCapitalization: TextCapitalization.words,
              maxLength: 60,
              decoration: const InputDecoration(
                  hintText: 'e.g. Ramoel Bello',
                  prefixIcon: Icon(Icons.person_outline_rounded, color: AppTheme.textMid)),
            ),
            Text(
              viewer
                  ? 'View-only accounts cannot change their own details.'
                  : 'This is the name shown on every request you approve.',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4),
            ),
            const SizedBox(height: 24),

            if (!viewer)
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.save_rounded),
                label: const Text('Save Changes'),
              ),
            const SizedBox(height: 28),
            const SectionDivider(
                icon: Icons.manage_accounts_rounded,
                label: 'Account',
                color: AppTheme.primary),
            const SizedBox(height: 4),

            // Sign-out deliberately stays in the dashboard app bar: one exit for
            // one action. Password change is here because it is account-level,
            // and for these accounts it is the only self-service route.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline_rounded, color: AppTheme.primary),
              title: const Text('Change Password',
                  style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textDark)),
              subtitle: const Text('Requires your current password',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textLight),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
            ),
          ],
        ),
      ),
    );
  }
}
