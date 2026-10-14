// -----------------------------------------------------------------------------
// LabTrack - student: all alerts
//
// Added 2026-09-21. Home shows at most three alert cards and, until now, the
// notification bell above them did nothing at all — so a student with four
// alerts had no way to reach the fourth (QA 2026-09-19, low #1 and low #9).
// The bell opens this screen, which lists every alert newest first and dates
// each one, including the acknowledgements Home ages out after a week.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/common.dart';

class StudentAlertsScreen extends StatelessWidget {
  // Alert maps exactly as the Home screen builds them: icon, color, title,
  // body and `at` (the moment the alert is about), already sorted newest first.
  final List<Map<String, dynamic>> alerts;
  const StudentAlertsScreen({super.key, required this.alerts});

  // "Today" / "Yesterday" / "3 days ago" reads better on a list of events than
  // a bare date, and needs no locale handling.
  String _when(DateTime at) {
    final now  = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(at.year, at.month, at.day))
        .inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7)  return '$days days ago';
    return '${at.month}/${at.day}/${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(title: const Text('Alerts')),
      body: alerts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_off_outlined,
                        size: 56, color: AppTheme.textLight),
                    SizedBox(height: 12),
                    Text('No alerts',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textDark)),
                    SizedBox(height: 4),
                    Text(
                        'Approvals, returns and overdue reminders will appear '
                        'here.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 13, color: AppTheme.textMid)),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: alerts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final n = alerts[i];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AlertCard(
                      icon:  n['icon']  as IconData,
                      color: n['color'] as Color,
                      title: n['title'] as String,
                      body:  n['body']  as String,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 14, top: 4),
                      child: Text(_when(n['at'] as DateTime),
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textLight)),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
