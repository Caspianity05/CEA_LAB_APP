// -----------------------------------------------------------------------------
// LabTrack - staff: the return step, shared by Scan QR and the Dashboard
//
// Both ways of returning an item now ask the same question (Good condition or
// Report Damage) and do the same follow-up: a damage report and a borrowing
// hold, after asking. Until 2026-10-05 the Dashboard's "Mark as Returned"
// always recorded Good without asking, so a damaged item could only be logged
// through Scan QR (prof's comment: returning was confusing). The sheet and the
// follow-up moved here from qr_scan_screen.dart unchanged in look and wording.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// Shows the return sheet for [equipment] (equipment_id, equipment_name,
// qr_code, category, status, location). [doReturn] records the return with the
// chosen condition ('Good' or 'Damaged') and answers like
// ApiService.returnEquipment, plus the borrower's student_id, borrower_name and
// student_number for the damage follow-up. Completes when the sheet and any
// follow-up are done. [closeLabel] names the button that leaves without a
// return ("Scan Another" while scanning, "Cancel" elsewhere).
Future<void> showReturnSheet(
  BuildContext context, {
  required Map<String, dynamic> equipment,
  required Future<Map<String, dynamic>> Function(String condition) doReturn,
  String closeLabel = 'Scan Another',
}) async {
  final status      = '${equipment['status'] ?? 'Unknown'}';
  final isBorrowed  = status == 'Borrowed';
  // Not-Borrowed does not mean Available: an item can be Under Repair or
  // For Disposal. This sheet used to paint the badge green and say "already
  // Available" for all three. Found on the emulator 2026-09-21 by scanning
  // an Under Repair item, which reported itself Available.
  final isAvailable = status == 'Available';
  final statusColor = isBorrowed
      ? AppTheme.warning
      : isAvailable
          ? AppTheme.success
          : AppTheme.danger;
  final equipName   = '${equipment['equipment_name'] ?? ''}';
  final equipId     = '${equipment['equipment_id'] ?? ''}';
  final location    = '${equipment['location'] ?? ''}';

  final condition = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Handle
        Container(width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.divider,
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 20),

        // Equipment info
        Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16)),
          child: Icon(Icons.science_outlined, color: statusColor, size: 30),
        ),
        const SizedBox(height: 12),
        Text(equipName,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                color: AppTheme.textDark),
            textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text('${equipment['qr_code'] ?? ''}  •  ${equipment['category'] ?? ''}',
            style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
        const SizedBox(height: 12),

        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          StatusBadge(label: status, color: statusColor),
          if (location.isNotEmpty) ...[
            const SizedBox(width: 8),
            StatusBadge(label: location, color: AppTheme.textMid),
          ],
        ]),
        const SizedBox(height: 24),
        const Divider(color: AppTheme.divider),
        const SizedBox(height: 16),

        // Action
        if (isBorrowed) ...[
          const Text(
              'Confirm the student has returned this equipment, then record its condition.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(sheetCtx, 'Good'),
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: const Text('Return — Good Condition'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.pop(sheetCtx, 'Damaged'),
              icon: const Icon(Icons.report_problem_outlined),
              label: const Text('Return — Report Damage'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.warning,
                  side: const BorderSide(color: AppTheme.warning),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.info_outline_rounded, color: statusColor, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(
                isAvailable
                    ? 'This equipment is already Available — no return '
                        'needed.'
                    : 'This equipment is marked $status and is not out on '
                        'loan, so there is nothing to return.',
                style: const TextStyle(fontSize: 13, color: AppTheme.textDark),
              )),
            ]),
          ),
        ],

        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.pop(sheetCtx),
            child: Text(closeLabel),
          ),
        ),
      ]),
    ),
  );
  if (condition == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final res = await doReturn(condition);
  if (!context.mounted) return;
  if (res['success'] != true) {
    messenger.showSnackBar(SnackBar(
      content: Text(res['message'] ?? 'Failed to process return.'),
      backgroundColor: AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
    return;
  }
  messenger.showSnackBar(SnackBar(
    content: Text(condition == 'Damaged'
        ? '"$equipName" returned and marked Under Repair.'
        : '"$equipName" marked as returned.'),
    backgroundColor:
        condition == 'Damaged' ? AppTheme.warning : AppTheme.success,
    behavior: SnackBarBehavior.floating,
  ));
  if (condition == 'Damaged') {
    await _offerDamageFollowUp(context, res, equipId, equipName);
  }
}

Future<void> _offerDamageFollowUp(BuildContext context,
    Map<String, dynamic> res, String equipId, String equipName) async {
  final borrower  = '${res['borrower_name'] ?? 'the student'}';
  final studentId = '${res['student_id'] ?? ''}';
  final apply = await showDialog<bool>(
    context: context,
    builder: (dCtx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      icon: const Icon(Icons.gpp_maybe_outlined, color: AppTheme.danger, size: 44),
      title: const Text('Log Damage & Hold?'),
      content: Text(
          'Record a damage report for "$equipName" and place a borrowing hold '
          'on $borrower until it is settled?',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Skip', style: TextStyle(color: AppTheme.textMid))),
        ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Log & Hold')),
      ],
    ),
  );
  if (apply != true) return;
  await ApiService.submitDamageReport({
    'equipment_id':   equipId,
    'equipment_name': equipName,
    'student_id':     studentId,
    'borrower_name':  res['borrower_name'] ?? '',
    'student_number': res['student_number'] ?? '',
    'description':    'Reported damaged on return (logged by staff).',
    'reported_by':    'staff',
  });
  if (studentId.isNotEmpty) {
    await ApiService.setStudentHold(studentId, true,
        reason: 'Damaged equipment "$equipName" pending settlement.');
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
    content: Text('Damage report logged and hold placed.'),
    backgroundColor: AppTheme.danger,
    behavior: SnackBarBehavior.floating,
  ));
}
