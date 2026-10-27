// -----------------------------------------------------------------------------
// LabTrack - student: how borrowing works
//
// 2026-10-06 (usability update): the four steps of a loan on one screen, in
// plain words. It opens by itself the first time a student reaches Home on a
// phone (showOnce), and is always one tap away in Profile → Support.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── How Borrowing Works Screen ───────────────────────────────────────────────

class HowItWorksScreen extends StatelessWidget {
  // Opened by itself on a first visit: the button then reads "Got it".
  final bool firstTime;
  const HowItWorksScreen({super.key, this.firstTime = false});

  static String _seenKey(String studentId) => 'how_it_works_seen_$studentId';

  // Opens the screen the first time [studentId] gets here on this phone, and
  // never again after that.
  static Future<void> showOnce(BuildContext context, String studentId) async {
    if (studentId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_seenKey(studentId)) == true) return;
      await prefs.setBool(_seenKey(studentId), true);
    } catch (_) {
      // No storage: it would open on every visit, so leave it to Profile.
      return;
    }
    if (!context.mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const HowItWorksScreen(firstTime: true)));
  }

  static const _steps = [
    (
      Icons.playlist_add_rounded,
      'Choose and send',
      'On Home, tap New Request. Pick the items and how many of each (up to '
          '$kMaxUnitsPerRequest in one request), fill in the subject, where you '
          'will use them and your return time, and submit. They are reserved '
          'for you at once, so nobody else can take them while staff decide.',
    ),
    (
      Icons.hourglass_top_rounded,
      'Wait for approval',
      'Staff approve or reject your request, and My Loans updates by itself. '
          'Changed your mind? Cancel the request there while it is still '
          'pending.',
    ),
    (
      Icons.qr_code_scanner_rounded,
      'Pick up at the lab',
      'Go to the laboratory. Staff scan each item as they hand it to you, and '
          'your loan starts then.',
    ),
    (
      Icons.assignment_return_outlined,
      'Return on time',
      'Bring everything back by the time you chose (10:00 PM at the latest), or by the later time staff give you. '
          'Staff scan each item back in. While an item is late, you cannot '
          'borrow anything else.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(title: const Text('How Borrowing Works')),
      body: ListView(
        padding: readablePadding(context, const EdgeInsets.all(20), maxWidth: 700),
        children: [
          const Text('Borrowing in four steps',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
          const SizedBox(height: 4),
          const Text('Same-day loans from the CEA laboratory.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 16),
          for (final (i, step) in _steps.indexed) _stepCard(i + 1, step),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppTheme.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12)),
            child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.report_problem_outlined, size: 18, color: AppTheme.warning),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                    'Something broke? Report it in My Loans with Report Damage. '
                    'The full rules are in Profile → Laboratory Policies.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textDark, height: 1.4)),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text(firstTime ? 'Got it' : 'Close'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepCard(int n, (IconData, String, String) step) {
    final (icon, title, body) = step;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.primary,
          child: Text('$n',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 16, color: AppTheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(body,
                style: const TextStyle(fontSize: 13, color: AppTheme.textMid, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}
