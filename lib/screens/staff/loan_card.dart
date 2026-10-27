// -----------------------------------------------------------------------------
// LabTrack - staff: one approved request, as a card
//
// Added 2026-10-06 (usability update). Approval no longer means the student has
// the items: they wait at the lab ("Ready for pick-up") until staff hand them
// over, scanning each one (hand_over_screen.dart). The Dashboard and the
// Requests tab show one card per request and state (ApiService.groupRequests
// with byPickup):
//   • Ready for pick-up: Hand over, or Not picked up if the student never came;
//   • On loan / Overdue: return one item (Good or Report Damage), or Return
//     all in good condition.
// Both show the return time, which staff can change (changeReturnTime): 10:00
// PM is the usual latest, and staff can give a later one. Subject and Where
// (1.0.20) show under the student, so staff can trace who has the items.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'hand_over_screen.dart';
import 'return_flow.dart';

// Asks for a new return time for [request] (today, later than now) and saves
// it on every record still Pending or Approved. True when it changed.
Future<bool> changeReturnTime(BuildContext context, List<dynamic> request) async {
  final now = DateTime.now();
  final due = ApiService.asDate(request.first['due_date']);
  final picked = await showTimePicker(
    context: context,
    helpText: 'RETURN BY (TODAY)',
    initialTime: TimeOfDay.fromDateTime(
        due != null && due.isAfter(now) ? due : DateTime(now.year, now.month, now.day, 17)),
  );
  if (picked == null || !context.mounted) return false;
  // Taken before the save: the card may leave the screen meanwhile (U2).
  final messenger = ScaffoldMessenger.of(context);
  final label = picked.format(context);
  final when = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
  final res = await ApiService.setDueTime(request, when);
  final ok = res['success'] == true;
  messenger.showSnackBar(SnackBar(
    content: Text(ok
        ? 'Return by $label today.'
        : '${res['message'] ?? 'Could not change the return time.'}'),
    backgroundColor: ok ? AppTheme.success : AppTheme.danger,
    behavior: SnackBarBehavior.floating,
  ));
  return ok;
}

// "6:30 PM, Oct 6, 2026"
String returnTimeLabel(BuildContext context, DateTime due) =>
    '${TimeOfDay.fromDateTime(due).format(context)}, ${formatDate(due)}';

// After an approval. The student is often already at the counter, so the
// hand-over is one tap away. [onDone] runs when the hand-over screen closes.
//
// Live test 2026-10-07 (U1): Flutter keeps a SnackBar that has an action on
// screen until it is pressed (`persist` defaults to true), so this one ignored
// its 8 seconds. It covered the bottom of every staff tab, and every later
// message queued behind it. Its HAND OVER also pushed with the approving
// screen's context; after a tab switch that screen was gone, and the tap only
// logged "Null check operator used on a null value". Now it times out, and it
// uses the navigator taken while the screen is still here.
void offerHandOver(BuildContext context, List<dynamic> request, {VoidCallback? onDone}) {
  final navigator = Navigator.of(context);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: const Text('Request approved. It is ready for pick-up.'),
    backgroundColor: AppTheme.success,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 8),
    persist: false,
    action: SnackBarAction(
      label: 'HAND OVER',
      textColor: Colors.white,
      onPressed: () async {
        // Signed out within the 8 seconds: nothing to hand over from here.
        if (!navigator.mounted || Session.role != 'staff') return;
        await navigator.push(
            MaterialPageRoute(builder: (_) => HandOverScreen(request: request)));
        // The screen that approved may be gone (another tab) by now.
        if (context.mounted) onDone?.call();
      },
    ),
  ));
}

class LoanRequestCard extends StatefulWidget {
  // The approved records of one request, all ready for pick-up or all out.
  final List<dynamic> request;
  // After any action; the Dashboard reloads its one-shot lists.
  final VoidCallback? onChanged;
  const LoanRequestCard({super.key, required this.request, this.onChanged});

  @override
  State<LoanRequestCard> createState() => _LoanRequestCardState();
}

class _LoanRequestCardState extends State<LoanRequestCard> {
  String? _busy; // which action is running
  // Taken when an action starts. Requests → Approved is a live list: a loan
  // returned or cancelled drops out of it, and this card with it, usually
  // before the action's result is back. Looking the messenger up afterwards
  // found nothing, so Return all and Not picked up there said nothing at all
  // (live test 2026-10-07, U2).
  ScaffoldMessengerState? _messenger;

  Future<void> _run(String which, Future<void> Function() action) async {
    if (_busy != null) return;
    _messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = which);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    widget.onChanged?.call();
  }

  void _say(Map<String, dynamic> res) {
    _messenger?.showSnackBar(SnackBar(
      content: Text('${res['message'] ?? (res['success'] == true ? 'Done.' : 'Action failed.')}'),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<bool> _confirm(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
          ],
        ),
      ) ==
      true;

  Future<void> _handOver() => Navigator.push(context,
      MaterialPageRoute(builder: (_) => HandOverScreen(request: widget.request)));

  Future<void> _notPickedUp(List<dynamic> waiting) async {
    final ok = await _confirm(
        'Not picked up?',
        'Cancel ${ApiService.requestSummary(waiting)} for this student and put '
            '${waiting.length == 1 ? 'it' : 'them'} back on the shelf? The '
            'student sees "Cancelled by staff: Not picked up".',
        'Not picked up');
    if (!ok) return;
    _say(await ApiService.cancelNotPickedUp(waiting));
  }

  Future<void> _returnAll(List<dynamic> out) async {
    final ok = await _confirm(
        'Return all ${out.length}?',
        'Record ${ApiService.requestSummary(out)} as returned in good '
            'condition. If one is damaged, return it on its own first with its '
            'return button and choose Report Damage.',
        'Return all');
    if (!ok) return;
    _say(await ApiService.returnAll(out));
  }

  Future<void> _returnOne(dynamic loan) => showReturnSheet(
        context,
        equipment: {
          'equipment_id':   loan['equipment_id'],
          'equipment_name': loan['equipment_name'],
          'qr_code':        loan['qr_code'],
          'category':       loan['category'],
          'status':         'Borrowed',
        },
        closeLabel: 'Cancel',
        doReturn: (condition) async {
          final res =
              await ApiService.returnEquipment('${loan['transaction_id']}', condition);
          // The damage follow-up needs to know whose loan it was.
          return {
            ...res,
            'student_id':     '${loan['student_id'] ?? ''}',
            'borrower_name':  '${loan['borrower_name'] ?? loan['student_number'] ?? ''}',
            'student_number': '${loan['student_number'] ?? ''}',
          };
        },
      );

  Widget _spinner(Color color) => SizedBox(
      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color));

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final first   = request.first;
    final waiting = request.where(ApiService.awaitingPickup).toList();
    final out     = request.where(ApiService.isOut).toList();
    final ready   = waiting.isNotEmpty;
    final overdue = out.any(ApiService.isOverdue);
    final due     = ApiService.asDate(first['due_date']);
    final name    = '${first['borrower_name'] ?? first['student_number'] ?? 'Student'}';
    final number  = '${first['student_number'] ?? ''}';
    final trace   = joinParts([first['subject'], first['use_location']]
        .map((v) => '${v ?? ''}'.trim()).where((v) => v.isNotEmpty));
    final (label, color) = ready
        ? ('Ready for pick-up', AppTheme.primary)
        : overdue
            ? ('Overdue', AppTheme.danger)
            : ('On loan', AppTheme.success);
    final approvedBy = '${first['approved_by_name'] ?? ''}'.trim();
    final dueSetBy   = '${first['due_set_by_name'] ?? ''}'.trim();
    final busy = _busy != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textDark)),
            if (number.isNotEmpty)
              Text('ID: $number', style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
            if (trace.isNotEmpty)
              Text(trace, style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
          ])),
          StatusBadge(label: label, color: color),
        ]),
        const SizedBox(height: 10),

        // The units: set aside at the lab, or out with the student.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
              color: AppTheme.surface, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            for (final t in request)
              Row(children: [
                const Icon(Icons.science_outlined, size: 14, color: AppTheme.textMid),
                const SizedBox(width: 6),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(joinParts([t['equipment_name'], t['qr_code']]),
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textDark, fontWeight: FontWeight.w600)),
                  ),
                ),
                if (ApiService.isOut(t) && Session.canManage)
                  IconButton(
                    tooltip: 'Return this item',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy ? null : () => _run('one', () => _returnOne(t)),
                    icon: const Icon(Icons.assignment_return_outlined,
                        size: 18, color: AppTheme.primary),
                  ),
              ]),
          ]),
        ),

        // Until when; staff can change it.
        if (due != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.timer_outlined, size: 13,
                  color: overdue ? AppTheme.danger : AppTheme.textMid),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Return by ${returnTimeLabel(context, due)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: overdue ? AppTheme.danger : AppTheme.textDark,
                        fontWeight: overdue ? FontWeight.w600 : FontWeight.normal)),
              ),
              if (Session.canManage)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run('due', () => changeReturnTime(context, request)),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: const Text('Change'),
                ),
            ]),
          ),
        if (ready && due != null && due.isBefore(DateTime.now()))
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('Not collected by its return time.',
                style: TextStyle(fontSize: 11, color: AppTheme.danger)),
          ),
        if (approvedBy.isNotEmpty || dueSetBy.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              const Icon(Icons.badge_outlined, size: 12, color: AppTheme.textLight),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    [
                      if (approvedBy.isNotEmpty) 'Approved by $approvedBy',
                      if (dueSetBy.isNotEmpty) 'time set by $dueSetBy',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 10, color: AppTheme.textLight)),
              ),
            ]),
          ),

        if (Session.canManage) ...[
          const SizedBox(height: 12),
          const Divider(color: AppTheme.divider, height: 1),
          const SizedBox(height: 10),
          if (ready)
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: busy ? null : () => _run('cancel', () => _notPickedUp(waiting)),
                icon: _busy == 'cancel'
                    ? _spinner(AppTheme.textMid)
                    : const Icon(Icons.event_busy_outlined, size: 16),
                label: const FittedBox(
                    fit: BoxFit.scaleDown, child: Text('Not picked up', maxLines: 1)),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textMid,
                    side: const BorderSide(color: AppTheme.divider)),
              )),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(
                onPressed: busy ? null : () => _run('hand', _handOver),
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(waiting.length > 1 ? 'Hand over ${waiting.length}' : 'Hand over',
                      maxLines: 1),
                ),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              )),
            ]))
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy
                    ? null
                    : out.length == 1
                        ? () => _run('one', () => _returnOne(out.first))
                        : () => _run('all', () => _returnAll(out)),
                icon: _busy == 'all'
                    ? _spinner(Colors.white)
                    : const Icon(Icons.assignment_return_rounded, size: 16),
                label: Text(out.length == 1 ? 'Mark as Returned' : 'Return all ${out.length}'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.6),
                    disabledForegroundColor: Colors.white),
              ),
            ),
        ],
      ]),
    );
  }
}
