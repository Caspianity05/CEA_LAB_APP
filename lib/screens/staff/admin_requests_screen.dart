// -----------------------------------------------------------------------------
// LabTrack - staff: admin requests screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// 2026-10-05: Pending shows one card per request (a request can hold several
// units, see request_card.dart); the lists no longer read the whole
// borrow_transactions collection (Pending/Approved live, All = last 90 days).
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'request_card.dart';

// ─── Admin Requests Screen ────────────────────────────────────────────────────

class AdminRequestsScreen extends StatefulWidget {
  const AdminRequestsScreen({super.key});
  @override
  State<AdminRequestsScreen> createState() => _AdminRequestsScreenState();
}

class _AdminRequestsScreenState extends State<AdminRequestsScreen> {
  // Live Firestore streams: new requests pop in as students submit them and
  // status changes render immediately — no manual refresh. Pending and
  // Approved are naturally small; "All" covers the same 90 days as Reports.
  late final Stream<List<dynamic>> _stream = ApiService.requestsStream();
  late final Stream<List<dynamic>> _recent = ApiService.recentRequestsStream();

  // True when this loan's due date has gone by. Uses the shared parser so an
  // ISO string and a raw Firestore Timestamp are both handled.
  bool _isPastDue(dynamic e) {
    final due = ApiService.asDate(e['due_date']);
    return due != null && due.isBefore(DateTime.now());
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Pending':  return AppTheme.accent;
      case 'Approved': return AppTheme.success;
      case 'Returned': return AppTheme.textMid;
      case 'Rejected': return AppTheme.danger;
      default:         return AppTheme.textMid;
    }
  }

  // Approve or reject every record of one request.
  Future<void> _decide(List<dynamic> request, String action,
      {String reason = ''}) async {
    try {
      final res = await ApiService.decideRequest(
          [for (final t in request) '${t['transaction_id']}'], action,
          reason: reason);
      if (mounted && res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message'] ?? 'Action failed.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
      // No manual reload needed — the snapshot stream delivers the change.
    } catch (_) {}
  }

  Future<void> _confirmReject(List<dynamic> request) async {
    final reason = await showRejectRequestDialog(context);
    if (reason != null) _decide(request, 'reject', reason: reason);
  }

  // One-line "who processed this" note built from the audit fields stamped on
  // the transaction (approved/rejected/returned by which staff member).
  String _auditLine(dynamic e) {
    final status = '${e['status'] ?? ''}';
    if (status == 'Approved' && '${e['approved_by_name'] ?? ''}'.isNotEmpty) {
      return 'Approved by ${e['approved_by_name']}';
    }
    if (status == 'Rejected' && '${e['rejected_by_name'] ?? ''}'.isNotEmpty) {
      return 'Rejected by ${e['rejected_by_name']}';
    }
    if (status == 'Returned' && '${e['returned_by_name'] ?? ''}'.isNotEmpty) {
      return 'Returned to ${e['returned_by_name']}';
    }
    return '';
  }

  // One record (one unit), for the Approved and All tabs: each unit is
  // returned on its own, so these stay one card per unit.
  Widget _buildCard(dynamic e) {
    final status = e['status'] ?? '';
    // An Approved loan that is past its due date is overdue, and the badge
    // used to say plain "Approved" in green — so the Approved tab gave staff
    // no way to spot a late loan (QA 2026-09-19, low #8). The stored status
    // is unchanged; only the badge tells the truth about it.
    final isOverdue = status == 'Approved' && _isPastDue(e);
    final label = isOverdue ? 'Overdue' : status;
    final sc = isOverdue ? AppTheme.danger : _statusColor(status);
    // Always a String: `.isNotEmpty` and `[0]` below would throw on any other
    // stored type and blank the card (QA 2026-10-03).
    final studentName = '${e['borrower_name'] ?? e['student_number'] ?? ''}';
    final subject = '${e['subject'] ?? ''}'.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sc.withValues(alpha: 0.25))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 20, backgroundColor: sc.withValues(alpha: 0.12),
                child: Text(studentName.isNotEmpty ? studentName[0].toUpperCase() : '?',
                    style: TextStyle(color: sc, fontWeight: FontWeight.bold, fontSize: 15))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(studentName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
              Text('ID: ${e['student_number'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
            ])),
            StatusBadge(label: label, color: sc),
          ]),
          const SizedBox(height: 10),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: AppTheme.surface, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.science_outlined, size: 13, color: AppTheme.textMid),
              const SizedBox(width: 6),
              Expanded(child: Text('${e['equipment_name'] ?? ''}  •  ${e['qr_code'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textDark, fontWeight: FontWeight.w600))),
              const Icon(Icons.calendar_today_rounded, size: 13, color: AppTheme.textMid),
              const SizedBox(width: 4),
              Text('Due: ${(e['due_date'] ?? '').toString().split('T').first}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
            ]),
          ),
          if (subject.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Subject: $subject',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
          ],
          if (status == 'Rejected' && '${e['reject_reason'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Reason: ${e['reject_reason']}',
                style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.danger,
                    fontStyle: FontStyle.italic)),
          ],
          // Audit trail — who acted on this request/loan.
          if (_auditLine(e).isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.badge_outlined, size: 12, color: AppTheme.textLight),
              const SizedBox(width: 4),
              Expanded(child: Text(_auditLine(e),
                  style: const TextStyle(fontSize: 10, color: AppTheme.textLight))),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _empty(String text) => Center(
      child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, style: const TextStyle(color: AppTheme.textMid))));

  Widget _pendingList(List<dynamic> pending) {
    final requests = ApiService.groupRequests(pending);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (requests.isEmpty) _empty('No pending requests'),
      for (final request in requests)
        PendingRequestCard(
          request: request,
          onApprove: () => _decide(request, 'approve'),
          onReject: () => _confirmReject(request),
        ),
    ]);
  }

  Widget _recordList(List<dynamic> items, String emptyText, {String? footer}) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (items.isEmpty) _empty(emptyText),
      for (final e in items) _buildCard(e),
      if (footer != null && items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Center(
              child: Text(footer,
                  style: const TextStyle(fontSize: 11, color: AppTheme.textLight))),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<dynamic>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Requests')),
            body: const Center(
                child: Text('Could not load requests.',
                    style: TextStyle(color: AppTheme.textMid))),
          );
        }
        final all = snap.data ?? const [];
        final pending  = all.where((e) => e['status'] == 'Pending').toList();
        final approved = all.where((e) => e['status'] == 'Approved').toList();

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              // No title: the staff shell's AppBar already shows the tab name,
              // so "Requests" appeared twice, stacked (QA 2026-09-19, low #12).
              // This bar exists only to host the tabs.
              toolbarHeight: 0,
              bottom: const TabBar(
                indicatorColor: AppTheme.accent, labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textLight,
                tabs: [Tab(text: 'Pending'), Tab(text: 'Approved'), Tab(text: 'All')],
              ),
            ),
            body: TabBarView(children: [
              _pendingList(pending),
              _recordList(approved, 'No approved requests'),
              StreamBuilder<List<dynamic>>(
                stream: _recent,
                builder: (context, recent) {
                  if (recent.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (recent.hasError) return _empty('Could not load requests.');
                  return _recordList(recent.data ?? const [], 'No requests yet',
                      footer: 'Showing the last 90 days');
                },
              ),
            ]),
          ),
        );
      },
    );
  }
}
