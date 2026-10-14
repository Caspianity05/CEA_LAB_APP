// -----------------------------------------------------------------------------
// LabTrack - student: lab policies screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';

// ─── Lab Policies Screen ──────────────────────────────────────────────────────

class LabPoliciesScreen extends StatelessWidget {
  const LabPoliciesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const policies = [
      {
        'title': 'Damaged or Missing Equipment Policy',
        'icon': '⚠️',
        'color': 0xFFEF4444,
        'body':
            'If a borrowed equipment is returned damaged or with missing parts, the student is required to replace the item with the same type or equivalent condition. The replacement does not need to be brand new, but it must be functional and acceptable to the staff.\n\nFailure to replace the damaged or missing equipment will result in the student\'s clearance not being signed or approved.',
      },
      {
        'title': 'Late Return Policy',
        'icon': '🕐',
        'color': 0xFFFFB703,
        'body':
            'Students who fail to return borrowed equipment on the agreed return date and time will be considered late returnees.\n\nLate returnees may temporarily lose their borrowing privileges for a certain period determined by the laboratory staff.',
      },
      {
        'title': 'Reservation Policy',
        'icon': '📅',
        'color': 0xFF1B3A8C,
        'body':
            'Equipment reservations are only allowed for the same day. Students must specify the exact borrowing time and expected return time during the reservation process.\n\nReservations are subject to equipment availability and staff approval.',
      },
      {
        'title': 'Outside Campus Equipment Usage Policy',
        'icon': '🏫',
        'color': 0xFF7C3AED,
        'body':
            'If a student needs to use laboratory equipment outside the campus or university premises, they are required to submit a formal request or report explaining the purpose and reason for external usage.\n\nThe request must be reviewed and approved by the laboratory staff before the equipment can be released.',
      },
      {
        'title': 'Inventory and Serial Number Policy',
        'icon': '📋',
        'color': 0xFF059669,
        'body':
            'All laboratory equipment must be recorded in the inventory system. Large equipment, tools, or high-value items are required to have a unique serial number for tracking purposes, while small equipment or minor tools may be recorded without a serial number.',
      },
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Laboratory Policies')),
      body: Column(
        children: [
          // Header banner
          Container(
            width: double.infinity,
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.policy_rounded,
                    color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('CEA Laboratory Policies',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  SizedBox(height: 2),
                  Text(
                      'Please read all policies carefully before borrowing equipment.',
                      style:
                          TextStyle(color: AppTheme.textLight, fontSize: 11)),
                ]),
              ),
            ]),
          ),

          // Policy list
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: policies.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final pol = policies[i];
                final color = Color(pol['color'] as int);
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border(
                        left: BorderSide(color: color, width: 4)),
                    boxShadow: [
                      BoxShadow(
                          color: color.withAlpha(15),
                          blurRadius: 8,
                          offset: const Offset(0, 2))
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      // Policy title row
                      Row(children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(10)),
                          child: Center(
                              child: Text(pol['icon'] as String,
                                  style: const TextStyle(fontSize: 18))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(pol['title'] as String,
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: color)),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      const Divider(color: AppTheme.divider, height: 1),
                      const SizedBox(height: 12),
                      // Policy body
                      Text(pol['body'] as String,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textDark,
                              height: 1.6)),
                    ]),
                  ),
                );
              },
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
        ],
      ),
    );
  }
}

