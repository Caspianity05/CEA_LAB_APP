// -----------------------------------------------------------------------------
// LabTrack - student: my borrowings screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
//
// 2026-10-05 (prof's comment: borrowing and returning were confusing): one card
// per request, each saying in plain words what happens next; an overdue loan
// is badged Overdue (it used to read "Approved"); a rejected request shows the
// reason staff gave (it was saved but never shown to the student).
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../theme.dart';
import '../../services/api_service.dart';
import '../../widgets/common.dart';
import 'damage_report_screen.dart';

// ─── My Borrowings Screen ─────────────────────────────────────────────────────

class MyBorrowingsScreen extends StatefulWidget {
  const MyBorrowingsScreen({super.key});
  @override
  State<MyBorrowingsScreen> createState() => _MyBorrowingsScreenState();
}

class _MyBorrowingsScreenState extends State<MyBorrowingsScreen> {
  // Live Firestore stream: the lists update by themselves when staff approve,
  // reject or process a return — no pull-to-refresh needed.
  late final Stream<List<dynamic>> _stream = ApiService.myBorrowingsStream();

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
            appBar: AppBar(title: const Text('My Borrowings')),
            body: const Center(
                child: Text('Could not load your borrowings.',
                    style: TextStyle(color: AppTheme.textMid))),
          );
        }
        final all = snap.data ?? const [];
        final active  = all.where((e) => e['status'] == 'Approved').toList();
        final pending = all.where((e) => e['status'] == 'Pending').toList();
        final history = all.where((e) => e['status'] == 'Returned' || e['status'] == 'Rejected').toList();

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('My Borrowings'),
              bottom: const TabBar(
                indicatorColor: AppTheme.accent,
                labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textLight,
                tabs: [Tab(text: 'Active'), Tab(text: 'Pending'), Tab(text: 'History')],
              ),
            ),
            body: TabBarView(
              children: [
                _RequestList(items: active),
                _RequestList(items: pending),
                _RequestList(items: history),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RequestList extends StatelessWidget {
  final List<dynamic> items;
  const _RequestList({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.inbox_rounded, size: 48, color: AppTheme.textLight),
        SizedBox(height: 8),
        Text('No items', style: TextStyle(color: AppTheme.textMid)),
        SizedBox(height: 12),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.sync_rounded, size: 14, color: AppTheme.textLight),
          SizedBox(width: 6),
          Text('Updates automatically', style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
        ]),
      ]));
    }
    final requests = ApiService.groupRequests(items);
    return Material(
      color: Colors.transparent,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: requests.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _RequestCard(request: requests[i]),
      ),
    );
  }
}

// One request: its items, its status, and what the student should do next.
class _RequestCard extends StatelessWidget {
  final List<dynamic> request;
  const _RequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final first   = request.first;
    final status  = '${first['status'] ?? 'Pending'}';
    final now     = DateTime.now();
    final due     = ApiService.asDate(first['due_date']);
    final asked   = ApiService.asDate(first['borrow_date']);
    final overdue = status == 'Approved' && due != null && due.isBefore(now);
    String time(DateTime d) => TimeOfDay.fromDateTime(d).format(context);
    String when(DateTime d) {
      final today = d.year == now.year && d.month == now.month && d.day == now.day;
      return today ? '${time(d)} today' : '${time(d)} on ${formatDate(d)}';
    }

    final (label, color) = switch (status) {
      'Approved' when overdue => ('Overdue', AppTheme.danger),
      'Approved' => ('Approved', AppTheme.success),
      'Pending'  => ('Pending', AppTheme.accent),
      'Returned' => ('Returned', AppTheme.textMid),
      'Rejected' => ('Rejected', AppTheme.danger),
      _          => (status, AppTheme.textMid),
    };

    // What happens next, in plain words.
    final reason = '${first['reject_reason'] ?? ''}'.trim();
    final (IconData nextIcon, String next) = switch (status) {
      'Pending' => (Icons.hourglass_top_rounded,
          'Waiting for staff approval. This page updates by itself when they decide.'),
      'Approved' when overdue => (Icons.warning_amber_rounded,
          'Overdue: it was due back by ${when(due)}. Return it to '
              'the lab as soon as possible. You cannot borrow anything else until you do.'),
      'Approved' => (Icons.check_circle_outline_rounded,
          'Approved. Pick it up at the lab, and return it by '
              '${due == null ? '5:00 PM today' : when(due)}.'),
      'Rejected' => (Icons.cancel_outlined,
          reason.isEmpty ? 'Rejected by staff.' : 'Rejected by staff: $reason'),
      'Returned' => (Icons.assignment_turned_in_outlined, 'Returned. Thank you!'),
      _ => (Icons.info_outline_rounded, status),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
              asked == null ? 'Request sent just now' : 'Request sent ${when(asked)}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMid),
            ),
          ),
          StatusBadge(label: label, color: color),
        ]),
        const SizedBox(height: 10),
        for (final e in request)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              EquipmentThumb(
                bytes: photoThumbOf(e),
                category: e['category'] as String? ?? '',
                color: AppTheme.primary,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${e['equipment_name'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
                  Text('${e['qr_code'] ?? ''}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                ]),
              ),
            ]),
          ),

        // Next step.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(nextIcon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(next,
                style: const TextStyle(fontSize: 12, color: AppTheme.textDark, height: 1.4))),
          ]),
        ),

        if (status == 'Approved') ...[
          const SizedBox(height: 8),
          const Row(children: [
            Icon(Icons.qr_code_2_rounded, size: 13, color: AppTheme.textLight),
            SizedBox(width: 6),
            Expanded(
                child: Text(
              'To return: bring it to the lab. Staff will scan its QR code.',
              style: TextStyle(fontSize: 11, color: AppTheme.textLight),
            )),
          ]),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DamageReportScreen())),
              icon: const Icon(Icons.report_problem_outlined, size: 16),
              label: const Text('Report Damage'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.warning,
                  side: const BorderSide(color: AppTheme.warning)),
            ),
          ),
        ],
      ]),
    );
  }
}
