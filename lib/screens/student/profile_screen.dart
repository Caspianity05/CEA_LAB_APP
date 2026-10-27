// -----------------------------------------------------------------------------
// LabTrack - student: profile screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../widgets/common.dart';
import '../auth/login_screen.dart';
import 'about_screen.dart';
import 'change_password_screen.dart';
import 'edit_profile_screen.dart';
import 'help_faq_screen.dart';
import 'how_it_works_screen.dart';
import 'lab_policies_screen.dart';
import 'notifications_settings_screen.dart';

// ─── Profile Screen ───────────────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Borrowing summary for the signed-in student. Null while it is still
  // loading (or if the read failed) — the header then shows placeholders
  // rather than a misleading zero.
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    final sid = '${Session.currentUser?['student_id'] ?? ''}';
    if (sid.isEmpty) return;
    try {
      final txns = await ApiService.getStudentTransactions(sid);
      if (!mounted) return;
      setState(() => _summary = ApiService.studentReliability(txns));
    } catch (_) {
      // Keep the placeholders; the rest of the screen stays usable.
    }
  }

  String _stat(String key) =>
      _summary == null ? '—' : '${_summary![key] ?? 0}';

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              // Capture the navigator before the await so the BuildContext is
              // not used across an async gap.
              final navigator = Navigator.of(context);
              navigator.pop();
              await ApiService.signOut();
              navigator.pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            icon: const Icon(Icons.logout_rounded, size: 16),
            label: const Text('Sign Out'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ── Header ──
            Container(
              color: AppTheme.primary,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: const Color(0x33F5A623),
                      child: Text(Session.initials,
                          style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 28,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                    Text(Session.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      '${Session.studentNumber}  •  ${courseLabel(Session.currentUser?['course'] ?? 'CEA')}',
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ProfileStat(
                            label: 'Total\nBorrowed', value: _stat('loans')),
                        Container(width: 1, height: 32, color: Colors.white24,
                            margin: const EdgeInsets.symmetric(horizontal: 20)),
                        _ProfileStat(
                            label: 'Active\nLoans', value: _stat('active')),
                        Container(width: 1, height: 32, color: Colors.white24,
                            margin: const EdgeInsets.symmetric(horizontal: 20)),
                        _ProfileStat(
                            label: 'Late\nReturns', value: _stat('late')),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Account Settings ──
                  const SectionHeader(title: 'Account Settings'),
                  const SizedBox(height: 12),
                  _SettingTile(
                    icon: Icons.person_outline_rounded,
                    label: 'Edit Profile',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const EditProfileScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.lock_outline_rounded,
                    label: 'Change Password',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.notifications_outlined,
                    label: 'Notifications',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const NotificationsSettingsScreen())),
                  ),
                  const SizedBox(height: 20),

                  // ── Support ──
                  const SectionHeader(title: 'Support'),
                  const SizedBox(height: 12),
                  _SettingTile(
                    icon: Icons.lightbulb_outline_rounded,
                    label: 'How Borrowing Works',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const HowItWorksScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.policy_rounded,
                    label: 'Laboratory Policies',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const LabPoliciesScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.help_outline_rounded,
                    label: 'Help & FAQ',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const HelpFaqScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.info_outline_rounded,
                    label: 'About LabTrack · NEU',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const AboutScreen())),
                  ),
                  const SizedBox(height: 20),

                  // ── Sign Out ──
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _confirmSignOut(context),
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Sign Out'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.danger,
                          side: const BorderSide(color: AppTheme.danger),
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class _ProfileStat extends StatelessWidget {
  final String label, value;
  const _ProfileStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: AppTheme.textLight, fontSize: 11),
            textAlign: TextAlign.center),
      ],
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _SettingTile({required this.icon, required this.label, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: AppTheme.primary, size: 22),
        title: Text(label,
            style: const TextStyle(fontSize: 14, color: AppTheme.textDark)),
        trailing: const Icon(Icons.arrow_forward_ios_rounded,
            size: 14, color: AppTheme.textLight),
        onTap: onTap ?? () {},
      ),
    );
  }
}
