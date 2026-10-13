// -----------------------------------------------------------------------------
// LabTrack - terms of use and privacy policy
//
// Extracted from firstFile.dart on 2026-08-03 as step 5 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';

// ─── Terms and Conditions Screen ─────────────────────────────────────────────

class TermsAndConditionsScreen extends StatelessWidget {
  const TermsAndConditionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms and Conditions')),
      body: Column(children: [
        // Header
        Container(
          width: double.infinity,
          color: AppTheme.primary,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.gavel_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Terms and Conditions',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 2),
              Text('LabTrack — CEA Laboratory · New Era University',
                  style: TextStyle(color: AppTheme.textLight, fontSize: 11)),
            ])),
          ]),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TermsSection(
                  number: '1',
                  title: 'Acceptance of Terms',
                  body: 'By creating an account and using the LabTrack Mobile Equipment Borrowing and Return Monitoring System, you agree to be bound by these Terms and Conditions. This system is exclusively for enrolled students and authorized laboratory staff of the College of Engineering and Architecture (CEA) at New Era University.',
                ),
                _TermsSection(
                  number: '2',
                  title: 'Eligibility',
                  body: 'Registration is limited to currently enrolled students of New Era University. You must provide a valid NEU institutional email address (ending in @neu.edu.ph) and your official student ID number in the format ##-#####-###. Providing false or misleading information during registration is a violation of these terms and may result in account suspension.',
                ),
                _TermsSection(
                  number: '3',
                  title: 'Equipment Borrowing Responsibilities',
                  body: 'By borrowing equipment through LabTrack, you acknowledge that:\n\n• You are responsible for the safe custody of all borrowed equipment from the time of check-out until it is returned and confirmed by laboratory staff.\n\n• Equipment must be returned in the same condition it was borrowed. Any damage, loss, or missing parts must be reported immediately through the Damage Report feature.\n\n• Damaged or missing equipment must be replaced with an item of the same type or equivalent condition acceptable to laboratory staff.\n\n• Failure to replace damaged or missing equipment may result in your academic clearance not being signed or approved.',
                ),
                _TermsSection(
                  number: '4',
                  title: 'Return Policy',
                  body: 'All borrowed equipment must be returned to the CEA laboratory on the same day of borrowing, before 5:00 PM. Equipment not returned by the agreed return time will be marked as overdue. Repeated late returns may result in temporary suspension of your borrowing privileges for a period determined by laboratory staff.',
                ),
                _TermsSection(
                  number: '5',
                  title: 'Reservation Policy',
                  body: 'Equipment reservations are valid for the same day only. Reservations are subject to equipment availability and must be approved by laboratory staff. Unapproved or pending reservations do not guarantee equipment availability.',
                ),
                _TermsSection(
                  number: '6',
                  title: 'Off-Campus Equipment Use',
                  body: 'The use of laboratory equipment outside of the university campus requires prior written approval from laboratory staff. A formal request stating the purpose and location of external use must be submitted and approved before equipment is released for off-campus use.',
                ),
                _TermsSection(
                  number: '7',
                  title: 'Account Security',
                  body: 'You are responsible for maintaining the confidentiality of your account credentials. You must not share your login information with other students or unauthorized individuals. Any activity performed under your account is your responsibility. If you suspect unauthorized access to your account, notify laboratory staff immediately.',
                ),
                _TermsSection(
                  number: '8',
                  title: 'System Use',
                  body: 'The LabTrack system must be used solely for its intended purpose of laboratory equipment management at CEA, New Era University. Any attempt to misuse, manipulate, or exploit the system for unauthorized purposes is strictly prohibited and may result in disciplinary action.',
                ),
                _TermsSection(
                  number: '9',
                  title: 'Modifications',
                  body: 'Laboratory staff reserves the right to modify these Terms and Conditions at any time. Continued use of the system after any changes constitutes your acceptance of the revised terms.',
                ),
                _TermsSection(
                  number: '10',
                  title: 'Governing Policy',
                  body: 'These Terms and Conditions are governed by the existing policies of New Era University and the College of Engineering and Architecture. In cases not covered by these terms, the university\'s student handbook and laboratory policies shall apply.',
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x0F1B3A8C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1F1B3A8C)),
                  ),
                  child: const Text(
                    'Last updated: May 2026 · LabTrack v1.0 · CEA Laboratory · New Era University',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMid),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),

        // Bottom button
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          color: Colors.white,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.check_rounded),
              label: const Text('I Understand — Go Back'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Privacy Policy Screen ────────────────────────────────────────────────────

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: Column(children: [
        // Header
        Container(
          width: double.infinity,
          color: AppTheme.primary,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.privacy_tip_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Privacy Policy',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 2),
              Text('LabTrack — CEA Laboratory · New Era University',
                  style: TextStyle(color: AppTheme.textLight, fontSize: 11)),
            ])),
          ]),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TermsSection(
                  number: '1',
                  title: 'Information We Collect',
                  body: 'When you register for a LabTrack account, we collect the following personal information:\n\n• Full name\n• NEU institutional email address\n• Student ID number\n• Degree program (course)\n• Year level\n• Password (stored securely through Firebase Authentication — never stored in plain text)',
                ),
                _TermsSection(
                  number: '2',
                  title: 'How We Use Your Information',
                  body: 'Your personal information is used solely for the operation of the LabTrack equipment borrowing system. Specifically:\n\n• Your name and student ID are used to identify you in borrowing transactions and records.\n• Your email address is used for account authentication and login.\n• Your borrowing history is recorded to maintain accountability for laboratory equipment.\n• Your information is used by laboratory staff to verify your identity when you borrow equipment.',
                ),
                _TermsSection(
                  number: '3',
                  title: 'Data Storage',
                  body: 'All personal data and transaction records are stored securely in Google Firebase Cloud Firestore, a cloud-based database service provided by Google LLC. Firebase applies industry-standard security measures including data encryption in transit (HTTPS/TLS) and at rest. Your password is managed exclusively by Firebase Authentication and is never accessible to laboratory staff or system administrators.',
                ),
                _TermsSection(
                  number: '4',
                  title: 'Who Can See Your Information',
                  body: 'Your personal information is accessible only to:\n\n• Laboratory staff with authorized admin accounts, who can view your name, student ID, and borrowing history for the purpose of managing equipment transactions.\n• No third parties outside of New Era University have access to your data.\n• Your password is not visible to anyone, including laboratory staff and system developers.',
                ),
                _TermsSection(
                  number: '5',
                  title: 'Data We Do Not Collect',
                  body: 'LabTrack does not collect:\n\n• Financial information or payment details\n• Device location or GPS data\n• Phone contacts or media files\n• Biometric data of any kind\n• Any data unrelated to laboratory equipment borrowing',
                ),
                _TermsSection(
                  number: '6',
                  title: 'Your Rights',
                  body: 'You have the right to:\n\n• View and update your personal information through the Edit Profile screen in the app.\n• Request correction of inaccurate information by contacting laboratory staff.\n• Request deletion of your account by contacting the laboratory staff directly.',
                ),
                _TermsSection(
                  number: '7',
                  title: 'Data Retention',
                  body: 'Your account information and borrowing records are retained for the duration of your enrollment at New Era University and for a reasonable period thereafter, as required for institutional record-keeping purposes. Borrowing transaction records may be retained indefinitely to maintain a complete audit trail of laboratory equipment usage.',
                ),
                _TermsSection(
                  number: '8',
                  title: 'Security',
                  body: 'We take the security of your data seriously. The system uses Firebase Authentication for secure login, Firestore Security Rules to prevent unauthorized data access, and HTTPS encryption for all data transmission. However, no system is completely immune to security risks. You are responsible for keeping your login credentials confidential.',
                ),
                _TermsSection(
                  number: '9',
                  title: 'Contact',
                  body: 'If you have questions or concerns about this Privacy Policy or how your data is handled, please contact the CEA Laboratory staff at New Era University or reach out through the Help & FAQ section of the application.',
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x0F1B3A8C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1F1B3A8C)),
                  ),
                  child: const Text(
                    'Last updated: May 2026 · LabTrack v1.0 · CEA Laboratory · New Era University',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMid),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),

        // Bottom button
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          color: Colors.white,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.check_rounded),
              label: const Text('I Understand — Go Back'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Terms Section Widget ─────────────────────────────────────────────────────

class _TermsSection extends StatelessWidget {
  final String number, title, body;
  const _TermsSection(
      {required this.number, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(
            left: BorderSide(color: AppTheme.primary, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
                color: const Color(0x1A1B3A8C),
                borderRadius: BorderRadius.circular(8)),
            child: Center(
              child: Text(number,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primary)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primary)),
          ),
        ]),
        const SizedBox(height: 10),
        const Divider(color: AppTheme.divider, height: 1),
        const SizedBox(height: 10),
        Text(body,
            style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textDark,
                height: 1.6)),
      ]),
    );
  }
}

