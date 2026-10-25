// -----------------------------------------------------------------------------
// LabTrack - staff: one pending borrow request, as a card
//
// Added 2026-10-05 (prof's comment: borrowing was confusing). A student's
// request can now hold several units ("Beaker 1000 mL × 2, Flask 500 mL"),
// stored as one record per unit that share a borrow_date; this card shows them
// as the one request they are, with the subject, the purpose and the return
// time the student gave, and Approve / Deny act on all of them. The Dashboard
// and the Requests tab both use it, so the two lists look and act the same.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

class PendingRequestCard extends StatelessWidget {
  // The records of one request (see ApiService.groupRequests).
  final List<dynamic> request;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  const PendingRequestCard(
      {super.key, required this.request, required this.onApprove, required this.onReject});

  @override
  Widget build(BuildContext context) {
    final first   = request.first;
    // Always Strings, whatever the record holds (QA 2026-10-03).
    final name    = '${first['borrower_name'] ?? first['student_number'] ?? 'Student'}';
    final number  = '${first['student_number'] ?? ''}';
    final subject = '${first['subject'] ?? ''}'.trim();
    final purpose = '${first['purpose'] ?? ''}'.trim();
    final due     = ApiService.asDate(first['due_date']);
    final codes   = [for (final t in request) '${t['qr_code'] ?? ''}']
        .where((c) => c.isNotEmpty)
        .join(', ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x33F5A623))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0x1AF5A623),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textDark)),
            if (number.isNotEmpty)
              Text('ID: $number',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
          ])),
          StatusBadge(label: 'Pending', color: AppTheme.accent),
        ]),
        const SizedBox(height: 10),

        // What was asked for.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
              color: AppTheme.surface, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.science_outlined, size: 14, color: AppTheme.textMid),
              const SizedBox(width: 6),
              Expanded(child: Text(ApiService.requestSummary(request),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textDark, fontWeight: FontWeight.w600))),
            ]),
            if (codes.isNotEmpty) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Text(codes,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
              ),
            ],
          ]),
        ),

        // Why, and until when.
        if (subject.isNotEmpty) _line(Icons.menu_book_outlined, 'Subject: $subject'),
        if (purpose.isNotEmpty) _line(Icons.notes_rounded, 'Purpose: $purpose'),
        if (due != null)
          _line(Icons.timer_outlined,
              'Return by ${TimeOfDay.fromDateTime(due).format(context)}, ${formatDate(due)}'),

        if (Session.canManage) ...[
          const SizedBox(height: 12),
          const Divider(color: AppTheme.divider, height: 1),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: onReject,
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('Deny'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  side: const BorderSide(color: AppTheme.danger)),
            )),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton.icon(
              onPressed: onApprove,
              icon: const Icon(Icons.check_rounded, size: 16),
              label: Text(request.length > 1 ? 'Approve all ${request.length}' : 'Approve'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
            )),
          ]),
        ],
      ]),
    );
  }

  Widget _line(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 13, color: AppTheme.textMid),
          const SizedBox(width: 6),
          Expanded(child: Text(text,
              style: const TextStyle(fontSize: 12, color: AppTheme.textDark))),
        ]),
      );
}
