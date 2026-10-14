// -----------------------------------------------------------------------------
// LabTrack - student: notification settings screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../services/notif_prefs.dart';
import '../../widgets/common.dart';

// ─── Notifications Settings Screen ───────────────────────────────────────────

class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});
  @override
  State<NotificationsSettingsScreen> createState() => _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState extends State<NotificationsSettingsScreen> {
  bool _borrowApproved  = NotifPrefs.approved;
  bool _borrowRejected  = NotifPrefs.rejected;
  bool _dueSoon         = NotifPrefs.dueSoon;
  bool _overdue         = NotifPrefs.overdue;
  bool _returnConfirmed = NotifPrefs.returnConfirmed;
  bool _damageUpdate    = NotifPrefs.damageUpdate;

  @override
  void initState() {
    super.initState();
    // Re-read from disk in case this screen is opened before the dashboard
    // has loaded the preferences.
    NotifPrefs.load().then((_) {
      if (!mounted) return;
      setState(() {
        _borrowApproved  = NotifPrefs.approved;
        _borrowRejected  = NotifPrefs.rejected;
        _dueSoon         = NotifPrefs.dueSoon;
        _overdue         = NotifPrefs.overdue;
        _returnConfirmed = NotifPrefs.returnConfirmed;
        _damageUpdate    = NotifPrefs.damageUpdate;
      });
    });
  }

  Future<void> _save() async {
    NotifPrefs.approved        = _borrowApproved;
    NotifPrefs.rejected        = _borrowRejected;
    NotifPrefs.dueSoon         = _dueSoon;
    NotifPrefs.overdue         = _overdue;
    NotifPrefs.returnConfirmed = _returnConfirmed;
    NotifPrefs.damageUpdate    = _damageUpdate;
    await NotifPrefs.save();
  }

  Widget _notifTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    Color? activeColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: activeColor ?? AppTheme.primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'Borrow Requests'),
            const SizedBox(height: 12),
            _notifTile(
              title: 'Request Approved',
              subtitle: 'When staff approves your borrow request',
              value: _borrowApproved,
              onChanged: (v) => setState(() => _borrowApproved = v),
              activeColor: AppTheme.success,
            ),
            _notifTile(
              title: 'Request Rejected',
              subtitle: 'When staff rejects your borrow request',
              value: _borrowRejected,
              onChanged: (v) => setState(() => _borrowRejected = v),
              activeColor: AppTheme.danger,
            ),
            const SizedBox(height: 20),

            const SectionHeader(title: 'Due Dates'),
            const SizedBox(height: 12),
            _notifTile(
              title: 'Due Soon Reminder',
              subtitle: 'Get reminded 1 day before equipment is due',
              value: _dueSoon,
              onChanged: (v) => setState(() => _dueSoon = v),
              activeColor: AppTheme.warning,
            ),
            _notifTile(
              title: 'Overdue Alert',
              subtitle: 'Alert when equipment return is overdue',
              value: _overdue,
              onChanged: (v) => setState(() => _overdue = v),
              activeColor: AppTheme.danger,
            ),
            const SizedBox(height: 20),

            const SectionHeader(title: 'Returns & Reports'),
            const SizedBox(height: 12),
            _notifTile(
              title: 'Return Confirmed',
              subtitle: 'When staff confirms your equipment return',
              value: _returnConfirmed,
              onChanged: (v) => setState(() => _returnConfirmed = v),
            ),
            _notifTile(
              title: 'Damage Report Update',
              subtitle: 'Updates on your submitted damage reports',
              value: _damageUpdate,
              onChanged: (v) => setState(() => _damageUpdate = v),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await _save();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Notification preferences saved!'),
                      backgroundColor: AppTheme.success,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.save_rounded),
                label: const Text('Save Preferences'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
