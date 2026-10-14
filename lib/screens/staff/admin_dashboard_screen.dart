// -----------------------------------------------------------------------------
// LabTrack - staff: admin dashboard screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../auth/login_screen.dart';
import 'qr_scan_screen.dart';
import 'admin_requests_screen.dart';
import 'admin_inventory_screen.dart';
import 'admin_reports_screen.dart';
import 'admin_damage_reports_screen.dart';
import 'admin_penalties_screen.dart';
import 'admin_students_screen.dart';

// ─── Admin Dashboard Screen ────────────────────────────────────────────────────

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // ── Auth guard — redirect if not staff ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Session.role != 'staff') {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const LoginScreen()));
      }
    });
  }

  final List<Widget> _pages = [
    const _AdminHome(),
    const AdminRequestsScreen(),
    const AdminInventoryScreen(),
    const AdminReportsScreen(),
  ];

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Sign Out'),
        content: const Text(
            'Are you sure you want to sign out of your staff account?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textMid)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              // Capture the navigator before the await so the BuildContext is
              // not used across an async gap.
              final navigator = Navigator.of(context);
              navigator.pop();
              await ApiService.signOut();
              navigator.pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            icon: const Icon(Icons.logout_rounded, size: 16),
            label: const Text('Sign Out'),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.danger),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabTitles = ['Dashboard', 'Requests', 'Inventory', 'Reports'];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NeuLogo(size: 28),
            const SizedBox(width: 10),
            Text(tabTitles[_currentIndex]),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            onPressed: () => _confirmSignOut(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _pages[_currentIndex]),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, -4))
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppTheme.primary,
          unselectedItemColor: AppTheme.textLight,
          backgroundColor: Colors.transparent,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.dashboard_outlined),
                activeIcon: Icon(Icons.dashboard_rounded),
                label: 'Dashboard'),
            BottomNavigationBarItem(
                icon: Icon(Icons.assignment_outlined),
                activeIcon: Icon(Icons.assignment_rounded),
                label: 'Requests'),
            BottomNavigationBarItem(
                icon: Icon(Icons.inventory_2_outlined),
                activeIcon: Icon(Icons.inventory_2_rounded),
                label: 'Inventory'),
            BottomNavigationBarItem(
                icon: Icon(Icons.bar_chart_outlined),
                activeIcon: Icon(Icons.bar_chart_rounded),
                label: 'Reports'),
          ],
        ),
      ),
    );
  }
}

class _AdminHome extends StatefulWidget {
  const _AdminHome();
  @override
  State<_AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<_AdminHome> {
  bool _loading = true;
  Map<String, dynamic> _stats = {};
  List<dynamic> _pending  = [];
  List<dynamic> _approved = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getDashboardData();
      if (!mounted) return;
      setState(() {
        _stats    = data.stats;
        _pending  = data.pending;
        _approved = data.approved;
        _loading  = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Every action reports its outcome and then reloads. These used to ignore
  // the result, so a refusal (item no longer available, or a request another
  // staff member already decided) looked like nothing happened, and "marked
  // as returned!" showed even when the return was refused (QA 2026-09-19, M4).
  // The reload matters too: this list is a one-shot read and goes stale.
  void _showResult(Map<String, dynamic> res, String okMessage) {
    if (!mounted) return;
    final ok = res['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? okMessage : (res['message'] ?? 'Action failed.')),
      backgroundColor: ok ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
    _load();
  }

  Future<void> _approve(String txId) async {
    final res = await ApiService.updateRequestStatus(txId, 'approve');
    _showResult(res, 'Request approved.');
  }

  Future<void> _reject(String txId) async {
    final reason = await showRejectRequestDialog(context);
    if (reason == null) return;
    final res = await ApiService.updateRequestStatus(txId, 'reject', reason: reason);
    _showResult(res, 'Request rejected.');
  }

  Future<void> _return(String txId, String equipmentName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Confirm Return'),
        content: Text('Mark "$equipmentName" as returned?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm Return')),
        ],
      ),
    );
    if (confirm == true) {
      final res = await ApiService.returnEquipment(txId, 'Good');
      _showResult(res, 'Equipment marked as returned!');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 210,
              pinned: true,
              backgroundColor: AppTheme.primary,
              automaticallyImplyLeading: false,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.primary, AppTheme.primaryDark],
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Background watermark
                      Positioned(
                        right: -24, top: -10,
                        child: Icon(Icons.inventory_2_rounded,
                            size: 180,
                            color: const Color(0x0AFFFFFF)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 52, 24, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Top row
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 36, height: 36,
                                  decoration: BoxDecoration(
                                      color: const Color(0x33F5A623),
                                      borderRadius: BorderRadius.circular(10)),
                                  child: const Icon(Icons.science_rounded,
                                      color: AppTheme.accent, size: 20),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('LabTrack',
                                          style: TextStyle(
                                              color: AppTheme.accent,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 1)),
                                      Text('CEA Laboratory · New Era University',
                                          style: TextStyle(
                                              color: AppTheme.textLight,
                                              fontSize: 10)),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                      color: const Color(0x33F5A623),
                                      borderRadius: BorderRadius.circular(8)),
                                  child: Text(
                                      Session.isViewer
                                          ? 'VIEW ONLY'
                                          : Session.staffRole.toUpperCase(),
                                      style: const TextStyle(
                                          color: AppTheme.accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            // System title
                            const Text(
                              'Equipment Borrowing\n& Return Monitoring',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  height: 1.2),
                            ),
                            const SizedBox(height: 6),
                            Row(children: [
                              const Icon(Icons.manage_accounts_rounded,
                                  color: AppTheme.textLight, size: 13),
                              const SizedBox(width: 4),
                              Text('Staff: ${Session.name}',
                                  style: const TextStyle(
                                      color: AppTheme.textLight,
                                      fontSize: 12)),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()))
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!Session.canManage)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0x141B3A8C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x331B3A8C)),
                          ),
                          child: const Row(children: [
                            Icon(Icons.visibility_outlined,
                                color: AppTheme.primary, size: 18),
                            SizedBox(width: 10),
                            Expanded(
                                child: Text(
                              'View-only access. You can review all records but '
                              'cannot approve, edit, or process transactions.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textDark,
                                  height: 1.4),
                            )),
                          ]),
                        ),

                      // ── Live Stats ──
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(child: _AdminStatCard(
                              label: 'Pending Requests',
                              value: '${_stats['pending_requests'] ?? 0}',
                              icon: Icons.pending_actions_rounded,
                              color: AppTheme.accent)),
                          const SizedBox(width: 12),
                          Expanded(child: _AdminStatCard(
                              label: 'Active Loans',
                              value: '${_stats['active_loans'] ?? 0}',
                              icon: Icons.inventory_2_rounded,
                              color: AppTheme.success)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(child: _AdminStatCard(
                              label: 'Overdue Items',
                              value: '${_stats['overdue_loans'] ?? 0}',
                              icon: Icons.warning_amber_rounded,
                              color: AppTheme.danger)),
                          const SizedBox(width: 12),
                          Expanded(child: _AdminStatCard(
                              label: 'Total Equipment',
                              value: '${_stats['total_equipment'] ?? 0}',
                              icon: Icons.science_rounded,
                              color: AppTheme.primary)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(child: _AdminStatCard(
                              label: 'Registered Students',
                              value: '${_stats['total_students'] ?? 0}',
                              icon: Icons.people_alt_rounded,
                              color: AppTheme.primary)),
                          const SizedBox(width: 12),
                          Expanded(child: _AdminStatCard(
                              label: 'Students on Hold',
                              value: '${_stats['held_students'] ?? 0}',
                              icon: Icons.gpp_bad_rounded,
                              color: AppTheme.danger)),
                        ]),
                      ),
                      const SizedBox(height: 24),

                      // ── Scan QR for Return (manage rights only) ──
                      if (Session.canManage) ...[
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const QRScanScreen())),
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            label: const Text('Scan QR to Process Return'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      // ── Damage reports + penalties quick access (all staff) ──
                      Row(children: [
                        Expanded(child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const AdminDamageReportsScreen())),
                          icon: const Icon(Icons.report_problem_outlined, size: 18),
                          label: Text('Damage (${_stats['damage_reports'] ?? 0})'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.warning,
                            side: const BorderSide(color: AppTheme.warning),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const AdminPenaltiesScreen())),
                          icon: const Icon(Icons.gpp_maybe_outlined, size: 18),
                          label: const Text('Penalties'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.danger,
                            side: const BorderSide(color: AppTheme.danger),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        )),
                      ]),
                      const SizedBox(height: 12),
                      // ── Students directory (all staff; viewer is read-only) ──
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const AdminStudentsScreen())),
                          icon: const Icon(Icons.people_alt_outlined, size: 18),
                          label: const Text('Students'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primary,
                            side: const BorderSide(color: AppTheme.primary),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── Pending Approvals ──
                      SectionHeader(
                          title: 'Pending Approvals (${_pending.length})',
                          action: 'View all',
                          onAction: () {}),
                      const SizedBox(height: 12),
                      if (_pending.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                            child: Column(children: [
                              Icon(Icons.check_circle_outline_rounded,
                                  color: AppTheme.success, size: 36),
                              SizedBox(height: 8),
                              Text('No pending requests',
                                  style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                            ]),
                          ),
                        )
                      else
                        ..._pending.map((e) {
                          final txId = '${e['transaction_id']}';
                          final name = e['borrower_name'] ?? e['student_number'] ?? 'Student';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0x33F5A623))),
                              child: Column(children: [
                                Row(children: [
                                  CircleAvatar(
                                    radius: 18,
                                    backgroundColor: const Color(0x1AF5A623),
                                    child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                                        style: const TextStyle(color: AppTheme.accent,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(name, style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 13,
                                        color: AppTheme.textDark)),
                                    Text('${e['equipment_name']}  •  Qty: ${e['quantity'] ?? 1}',
                                        style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                                  ])),
                                  StatusBadge(label: 'Pending', color: AppTheme.accent),
                                ]),
                                if (Session.canManage) ...[
                                  const SizedBox(height: 12),
                                  const Divider(color: AppTheme.divider, height: 1),
                                  const SizedBox(height: 10),
                                  Row(children: [
                                    Expanded(child: OutlinedButton.icon(
                                      onPressed: () => _reject(txId),
                                      icon: const Icon(Icons.close_rounded, size: 16),
                                      label: const Text('Deny'),
                                      style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.danger,
                                          side: const BorderSide(color: AppTheme.danger)),
                                    )),
                                    const SizedBox(width: 10),
                                    Expanded(child: ElevatedButton.icon(
                                      onPressed: () => _approve(txId),
                                      icon: const Icon(Icons.check_rounded, size: 16),
                                      label: const Text('Approve'),
                                      style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.success),
                                    )),
                                  ]),
                                ],
                              ]),
                            ),
                          );
                        }),
                      const SizedBox(height: 24),

                      // ── Active Loans (Approved — awaiting return) ──
                      SectionHeader(
                          title: 'Active Loans (${_approved.length})',
                          action: 'View all',
                          onAction: () {}),
                      const SizedBox(height: 12),
                      if (_approved.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                            child: Text('No active loans',
                                style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                          ),
                        )
                      else
                        ..._approved.map((e) {
                          final txId = '${e['transaction_id']}';
                          final name = e['borrower_name'] ?? e['student_number'] ?? 'Student';
                          final equipName = e['equipment_name'] ?? 'Equipment';
                          final dueDate = (e['due_date'] ?? '').toString().split('T').first;
                          // Every active loan was badged a green "Active",
                          // including ones already past due, so the Dashboard
                          // gave staff no way to see which (QA 2026-09-19,
                          // low #8). The stored status is unchanged.
                          final due = ApiService.asDate(e['due_date']);
                          final isOverdue =
                              due != null && due.isBefore(DateTime.now());
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0x3306D6A0))),
                              child: Column(children: [
                                Row(children: [
                                  Container(
                                    width: 40, height: 40,
                                    decoration: BoxDecoration(
                                        color: const Color(0x1A06D6A0),
                                        borderRadius: BorderRadius.circular(10)),
                                    child: const Icon(Icons.science_outlined,
                                        color: AppTheme.success, size: 20),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(equipName, style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 13,
                                        color: AppTheme.textDark)),
                                    Text('$name  •  Due: $dueDate',
                                        style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                                  ])),
                                  StatusBadge(
                                      label: isOverdue ? 'Overdue' : 'Active',
                                      color: isOverdue
                                          ? AppTheme.danger
                                          : AppTheme.success),
                                ]),
                                if (Session.canManage) ...[
                                  const SizedBox(height: 12),
                                  const Divider(color: AppTheme.divider, height: 1),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _return(txId, equipName),
                                      icon: const Icon(Icons.assignment_return_rounded, size: 16),
                                      label: const Text('Mark as Returned'),
                                      style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.primary),
                                    ),
                                  ),
                                ],
                              ]),
                            ),
                          );
                        }),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdminStatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _AdminStatCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: color.withAlpha(26),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: color.withAlpha(31),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 12),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppTheme.textMid),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

