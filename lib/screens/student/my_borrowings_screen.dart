// -----------------------------------------------------------------------------
// LabTrack - student: my borrowings screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

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

  Color _statusColor(String s) {
    switch (s) {
      case 'Approved': return AppTheme.success;
      case 'Pending':  return AppTheme.accent;
      case 'Returned': return AppTheme.textMid;
      case 'Rejected': return AppTheme.danger;
      default:         return AppTheme.textMid;
    }
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
                _LiveBorrowList(items: active, statusColorFn: _statusColor),
                _LiveBorrowList(items: pending, statusColorFn: _statusColor),
                _LiveBorrowList(items: history, statusColorFn: _statusColor),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LiveBorrowList extends StatelessWidget {
  final List<dynamic> items;
  final Color Function(String) statusColorFn;
  const _LiveBorrowList({required this.items, required this.statusColorFn});

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
    return Material(
      color: Colors.transparent,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final e = items[i];
          final status = e['status'] ?? 'Pending';
          // Stored as a full ISO timestamp; every other screen shows the date
          // part only, so strip the time here too.
          final dueDate = '${e['due_date'] ?? ''}'.split('T').first;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                Row(
                  children: [
                    EquipmentThumb(
                      bytes: photoThumbOf(e),
                      category: e['category'] as String? ?? '',
                      color: AppTheme.primary,
                      size: 46,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e['equipment_name'] ?? '',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
                        Text('${e['qr_code'] ?? ''}  •  Due: $dueDate',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                      ]),
                    ),
                    StatusBadge(label: status, color: statusColorFn(status)),
                  ],
                ),
                if (status == 'Approved') ...[
                  const SizedBox(height: 12),
                  const Divider(color: AppTheme.divider, height: 1),
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
                  const SizedBox(height: 8),
                  const Row(children: [
                    Icon(Icons.qr_code_2_rounded, size: 13, color: AppTheme.textLight),
                    SizedBox(width: 6),
                    Expanded(
                        child: Text(
                      'Returns are processed by lab staff scanning the QR code on the item.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textLight),
                    )),
                  ]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
