// -----------------------------------------------------------------------------
// LabTrack - student: about screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── About Screen ─────────────────────────────────────────────────────────────

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About LabTrack')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Hero
            Container(
              width: double.infinity,
              color: AppTheme.primary,
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
              child: const Column(children: [
                NeuLogo(size: 72),
                SizedBox(height: 16),
                Text('LabTrack',
                    style: TextStyle(color: Colors.white, fontSize: 28,
                        fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                SizedBox(height: 4),
                Text('CEA Laboratory · New Era University',
                    style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
                SizedBox(height: 12),
                StatusBadge(label: kAppVersionLabel, color: AppTheme.accent),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // About card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                        color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('About This App', style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                      SizedBox(height: 10),
                      Text(
                        'LabTrack is a mobile equipment borrowing and return monitoring system '
                        'developed for the College of Engineering and Architecture (CEA) Laboratory '
                        'of New Era University.\n\n'
                        'The system allows students to borrow laboratory equipment digitally, '
                        'track their active loans, and report damage — while giving lab staff '
                        'full visibility and control over inventory.',
                        style: TextStyle(fontSize: 13, color: AppTheme.textMid, height: 1.6),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),

                  // Info tiles
                  _AboutTile(icon: Icons.school_rounded,     label: 'Institution',  value: 'New Era University'),
                  _AboutTile(icon: Icons.business_rounded,   label: 'College',      value: 'College of Engineering & Architecture'),
                  _AboutTile(icon: Icons.code_rounded,       label: 'Platform',     value: 'Flutter (Android & iOS)'),
                  _AboutTile(icon: Icons.storage_rounded,    label: 'Backend',      value: 'Firebase (Auth + Cloud Firestore)'),
                  _AboutTile(icon: Icons.calendar_month_rounded, label: 'Year',     value: '2026'),
                  const SizedBox(height: 16),

                  // Divider
                  const Divider(color: AppTheme.divider),
                  const SizedBox(height: 12),
                  const Center(
                    child: Text('Developed as a Capstone Project',
                        style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
                  ),
                  const SizedBox(height: 4),
                  const Center(
                    child: Text('New Era University · CEA · 2026',
                        style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
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

class _AboutTile extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _AboutTile({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
              color: const Color(0x141B3A8C),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: AppTheme.primary, size: 18),
        ),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
          Text(value,  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
        ]),
      ]),
    );
  }
}
