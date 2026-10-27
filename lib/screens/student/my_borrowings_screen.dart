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
        final history = all.where((e) =>
            e['status'] == 'Returned' || e['status'] == 'Rejected' ||
            e['status'] == 'Cancelled').toList();
        // Requests with something already returned: their Active card asks for
        // the rest back instead of "Pick it up".
        final partlyBack = {
          for (final e in all)
            if (e['status'] == 'Returned') ApiService.requestKey(e),
        };

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
                // Waiting at the lab and handed over are separate cards
                // (2026-10-06).
                _RequestList(items: active, partlyBack: partlyBack, byPickup: true),
                _RequestList(items: pending),
                // Split by status too: a request can end partly returned and
                // partly rejected, and one card for both read "Returned" for
                // items that were never lent (QA 2026-10-06).
                _RequestList(items: history, byStatus: true),
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
  final bool byStatus;
  final bool byPickup;
  final Set<String> partlyBack;
  const _RequestList(
      {required this.items, this.byStatus = false, this.byPickup = false,
      this.partlyBack = const {}});

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
    final requests =
        ApiService.groupRequests(items, byStatus: byStatus, byPickup: byPickup);
    return Material(
      color: Colors.transparent,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: requests.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _RequestCard(
            request: requests[i],
            partlyBack: partlyBack.contains(ApiService.requestKey(requests[i].first))),
      ),
    );
  }
}

// One request: its items, its status, and what the student should do next.
class _RequestCard extends StatelessWidget {
  final List<dynamic> request;
  // Some of this request is already back (Active tab only).
  final bool partlyBack;
  const _RequestCard({required this.request, this.partlyBack = false});

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: Text(
            'You asked for ${ApiService.requestSummary(request)}. Cancelling '
            'gives the items back to the lab, and staff will not see the '
            'request any more.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel request',
                  style: TextStyle(color: AppTheme.danger))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final res = await ApiService.cancelRequest(request);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${res['message']}'),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // The records grouped by item type, alphabetically.
  static List<List<dynamic>> _byType(List<dynamic> records) {
    final types = <String, List<dynamic>>{};
    for (final t in records) {
      types.putIfAbsent(ApiService.baseNameOf('${t['equipment_name'] ?? ''}'), () => []).add(t);
    }
    final names = types.keys.toList()..sort();
    return [for (final n in names) types[n]!];
  }

  Widget _itemRow(dynamic e, String title, String? code) => Padding(
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
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
              if (code != null && code.isNotEmpty)
                Text(code,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final first   = request.first;
    final status  = '${first['status'] ?? 'Pending'}';
    final now     = DateTime.now();
    final due     = ApiService.asDate(first['due_date']);
    final asked   = ApiService.asDate(first['borrow_date']);
    // Approved items wait at the lab until staff hand them over; only items
    // the student has can be overdue (2026-10-06).
    final ready   = request.any(ApiService.awaitingPickup);
    final overdue = request.any(ApiService.isOverdue);
    String time(DateTime d) => TimeOfDay.fromDateTime(d).format(context);
    String when(DateTime d) {
      final today = d.year == now.year && d.month == now.month && d.day == now.day;
      return today ? '${time(d)} today' : '${time(d)} on ${formatDate(d)}';
    }

    final (label, color) = switch (status) {
      'Approved' when ready => ('Ready for pick-up', AppTheme.primary),
      'Approved' when overdue => ('Overdue', AppTheme.danger),
      'Approved' => ('On loan', AppTheme.success),
      'Pending'  => ('Pending', AppTheme.accent),
      'Returned' => ('Returned', AppTheme.textMid),
      'Rejected' => ('Rejected', AppTheme.danger),
      'Cancelled' => ('Cancelled', AppTheme.textMid),
      _          => (status, AppTheme.textMid),
    };

    // What happens next, in plain words.
    final reason = '${first['reject_reason'] ?? ''}'.trim();
    final cancelReason = '${first['cancel_reason'] ?? ''}'.trim();
    final (IconData nextIcon, String next) = switch (status) {
      'Pending' => (Icons.hourglass_top_rounded,
          'Waiting for staff approval. The items are reserved for you meanwhile, '
              'and this page updates by itself when staff decide.'),
      'Cancelled' => (Icons.do_not_disturb_on_outlined,
          cancelReason.isEmpty
              ? 'You cancelled this request.'
              : 'Cancelled by staff: $cancelReason'),
      'Approved' when ready => (Icons.storefront_outlined,
          'Approved. Pick it up at the lab: staff scan each item as they hand '
              'it to you. Return it by ${due == null ? '10:00 PM today' : when(due)}.'),
      'Approved' when overdue => (Icons.warning_amber_rounded,
          'Overdue: it was due back by ${due == null ? 'its due time' : when(due)}. Return it to '
              'the lab as soon as possible. You cannot borrow anything else until you do.'),
      'Approved' when partlyBack => (Icons.check_circle_outline_rounded,
          'Part of this request is back. Return the rest by '
              '${due == null ? '10:00 PM today' : when(due)}.'),
      'Approved' => (Icons.check_circle_outline_rounded,
          'You have it. Return it to the lab by '
              '${due == null ? '10:00 PM today' : when(due)}.'),
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
        // Lent units by name and code. A pending or rejected request has no
        // unit of its own yet: the one it reserved can change at approval, and
        // showing it put "Depth Gauge #2" on a student's Pending card while the
        // same unit was on their Active one (QA 2026-10-06). So those list the
        // item types they asked for. So does one waiting for pick-up: staff
        // may hand over another unit of the same item (2026-10-06).
        if (status == 'Pending' || status == 'Rejected' || status == 'Cancelled' || ready)
          for (final type in _byType(request))
            _itemRow(type.first,
                type.length > 1
                    ? '${ApiService.baseNameOf('${type.first['equipment_name'] ?? ''}')} × ${type.length}'
                    : ApiService.baseNameOf('${type.first['equipment_name'] ?? ''}'),
                null)
        else
          for (final e in request)
            _itemRow(e, '${e['equipment_name'] ?? ''}', '${e['qr_code'] ?? ''}'),

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

        // Changed your mind? A request can be taken back until staff decide
        // (2026-10-06); it used to need staff to reject it.
        if (status == 'Pending') ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _confirmCancel(context),
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('Cancel request'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textMid,
                  side: const BorderSide(color: AppTheme.divider)),
            ),
          ),
        ],

        if (status == 'Approved' && !ready) ...[
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
