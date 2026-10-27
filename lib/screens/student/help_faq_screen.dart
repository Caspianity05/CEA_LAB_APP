// -----------------------------------------------------------------------------
// LabTrack - student: help and FAQ screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../theme.dart';

// ─── Help & FAQ Screen ────────────────────────────────────────────────────────

class HelpFaqScreen extends StatefulWidget {
  const HelpFaqScreen({super.key});
  @override
  State<HelpFaqScreen> createState() => _HelpFaqScreenState();
}

class _HelpFaqScreenState extends State<HelpFaqScreen> {
  int? _expanded;

  final _faqs = const [
    {
      'q': 'How do I borrow equipment?',
      'a': 'On Home, tap New Request (or open an item in the Equipment Catalog and tap Borrow This Equipment). Choose the items and how many of each, then submit. The items are reserved for you while lab staff review the request; once it is approved, pick them up at the laboratory. Profile → How Borrowing Works shows every step.',
    },
    {
      'q': 'How long can I borrow equipment?',
      'a': 'Borrowing is same-day only. You can borrow from 7:00 AM. You choose the return time when you send the request, at the latest 10:00 PM on the day you borrow. Lab staff can give you a later time; My Loans always shows the time that applies.',
    },
    {
      'q': 'What happens if I return equipment late?',
      'a': 'Late returns are recorded in your profile, and while an item is overdue you cannot send a new request. Repeated late returns may affect your borrowing privileges. Always return equipment on or before its due time.',
    },
    {
      'q': 'Where do I find the equipment QR code?',
      'a': 'It is on a label stuck to the item itself. You do not scan anything yourself: lab staff scan the label on each item when they hand it to you and again when you return it. My Loans shows the code of each item you have on loan.',
    },
    {
      'q': 'What do I do if equipment is damaged?',
      'a': 'Report it immediately using the Damage Report feature. Go to My Borrowings, find the item, and tap "Report Damage". Describe the damage and submit — lab staff will be notified.',
    },
    {
      'q': 'Can I cancel a borrow request?',
      'a': 'Yes, while it is still pending: open My Loans → Pending and tap Cancel request. The items go back to the lab at once. Once a request is approved, ask the lab staff instead.',
    },
    {
      'q': 'I forgot my password, what should I do?',
      'a': 'Tap "Forgot Password?" on the login screen, or contact your lab staff to reset your account credentials.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & FAQ')),
      body: Column(
        children: [
          // Banner
          Container(
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                    color: const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.help_outline_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Frequently Asked Questions',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                SizedBox(height: 2),
                Text('Tap a question to see the answer',
                    style: TextStyle(color: AppTheme.textLight, fontSize: 12)),
              ])),
            ]),
          ),

          // FAQ List
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _faqs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final isOpen = _expanded == i;
                return GestureDetector(
                  onTap: () => setState(() => _expanded = isOpen ? null : i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: isOpen ? const Color(0x4D1B3A8C) : AppTheme.divider),
                      boxShadow: isOpen ? [
                        BoxShadow(color: const Color(0x141B3A8C),
                            blurRadius: 8, offset: const Offset(0, 2))
                      ] : [],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                                color: isOpen ? AppTheme.primary : AppTheme.surface,
                                borderRadius: BorderRadius.circular(8)),
                            child: Center(
                              child: Text('${i + 1}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isOpen ? Colors.white : AppTheme.textMid)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_faqs[i]['q']!,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: isOpen ? AppTheme.primary : AppTheme.textDark))),
                          Icon(isOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                              color: isOpen ? AppTheme.primary : AppTheme.textLight),
                        ]),
                        if (isOpen) ...[
                          const SizedBox(height: 12),
                          const Divider(color: AppTheme.divider, height: 1),
                          const SizedBox(height: 12),
                          Text(_faqs[i]['a']!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textMid,
                                  height: 1.5)),
                        ],
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),

          // Contact bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            color: Colors.white,
            child: Row(children: [
              const Icon(Icons.mail_outline_rounded, color: AppTheme.primary, size: 20),
              const SizedBox(width: 10),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Still need help?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textDark)),
                Text('cea.lab@neu.edu.ph', style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
              ])),
              // This button did nothing at all (QA 2026-09-19, low #1). There
              // is no mail plugin in the dependency list and adding one for a
              // single button is not worth it, so it copies the address the
              // row already shows — which is what a student needs to write in.
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                      const ClipboardData(text: 'cea.lab@neu.edu.ph'));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('cea.lab@neu.edu.ph copied. Send us an '
                        'e-mail and we will get back to you.'),
                    backgroundColor: AppTheme.success,
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 4),
                  ));
                },
                child: const Text('Contact Us', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
