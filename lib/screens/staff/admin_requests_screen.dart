// -----------------------------------------------------------------------------
// LabTrack - staff: admin requests screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Admin Requests Screen ────────────────────────────────────────────────────

class AdminRequestsScreen extends StatefulWidget {
  const AdminRequestsScreen({super.key});
  @override
  State<AdminRequestsScreen> createState() => _AdminRequestsScreenState();
}

class _AdminRequestsScreenState extends State<AdminRequestsScreen> {
  // Live Firestore stream: new requests pop in as students submit them and
  // status changes render immediately — no manual refresh.
  late final Stream<List<dynamic>> _stream = ApiService.requestsStream();

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

  Future<void> _action(String txId, String action, {String reason = ''}) async {
    try {
      final res = await ApiService.updateRequestStatus(txId, action, reason: reason);
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

  Future<void> _confirmReject(String txId) async {
    final reason = await showRejectRequestDialog(context);
    if (reason != null) _action(txId, 'reject', reason: reason);
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

  Widget _buildCard(dynamic e, {bool showActions = false}) {
    final status = e['status'] ?? '';
    // An Approved loan that is past its due date is overdue, and the badge
    // used to say plain "Approved" in green — so the Approved tab gave staff
    // no way to spot a late loan (QA 2026-09-19, low #8). The stored status
    // is unchanged; only the badge tells the truth about it.
    final isOverdue = status == 'Approved' && _isPastDue(e);
    final label = isOverdue ? 'Overdue' : status;
    final sc = isOverdue ? AppTheme.danger : _statusColor(status);
    final txId = '${e['transaction_id']}';
    final studentName = e['borrower_name'] ?? e['student_number'] ?? '';
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
              Expanded(child: Text('${e['equipment_name'] ?? ''}  •  Qty: ${e['quantity'] ?? 1}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textDark, fontWeight: FontWeight.w600))),
              const Icon(Icons.calendar_today_rounded, size: 13, color: AppTheme.textMid),
              const SizedBox(width: 4),
              Text('Due: ${(e['due_date'] ?? '').toString().split('T').first}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
            ]),
          ),
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
          if (showActions && status == 'Pending' && Session.canManage) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => _confirmReject(txId),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Deny'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)),
              )),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(
                onPressed: () => _action(txId, 'approve'),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Approve'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              )),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _requestList(List<dynamic> items, String emptyText,
      {bool showActions = false}) {
    return ListView(padding: const EdgeInsets.all(16),
        children: items.isEmpty
            ? [Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(emptyText, style: const TextStyle(color: AppTheme.textMid))))]
            : items.map((e) => _buildCard(e, showActions: showActions)).toList());
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
              _requestList(pending, 'No pending requests', showActions: true),
              _requestList(approved, 'No approved requests'),
              _requestList(all, 'No requests yet'),
            ]),
          ),
        );
      },
    );
  }
}



