// -----------------------------------------------------------------------------
// LabTrack - staff: admin dashboard screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants.dart';
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
import 'staff_profile_screen.dart';
import 'admin_staff_accounts_screen.dart';
import 'request_card.dart';
import 'return_flow.dart';

// ─── Admin Dashboard Screen ────────────────────────────────────────────────────

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _currentIndex = 0;
  StreamSubscription<Map<String, dynamic>?>? _account;

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
    if (Session.role == 'staff' && Session.staffId.isNotEmpty) {
      // Errors are ignored: the only expected one is a legacy account whose
      // document id is not its uid, which the rules refuse — and such an
      // account can change nothing anyway.
      _account = ApiService.staffSelfStream(Session.staffId)
          .listen(_onAccount, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _account?.cancel();
    super.dispose();
  }

  // QA 2026-09-23, F2. The portal used to read the account once, at sign-in,
  // so when a super admin changed this account's access level the device
  // kept the old badge and buttons until the person signed out, and every
  // write was refused with a bare "You do not have permission to do that."
  // It now follows its own staff document and redraws when the level changes.
  void _onAccount(Map<String, dynamic>? doc) {
    if (!mounted || Session.role != 'staff') return;
    if (doc == null) {
      _accountRemoved();
      return;
    }
    final change = Session.refreshStaff(doc);
    if (!change.nameChanged && !change.roleChanged) return;
    if (change.narrowed) {
      // A screen or sheet open on top may still offer an action this account
      // no longer has, so close everything back to the portal.
      final portal = ModalRoute.of(context);
      if (portal != null) Navigator.of(context).popUntil((r) => r == portal);
    }
    setState(() {});
    if (change.roleChanged) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Your access level was changed to '
            '${staffRoleName(Session.staffRole)}.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // The account's staff document was deleted (console only — no client can).
  // Nothing this device offers would be accepted any more, so end the session.
  Future<void> _accountRemoved() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await _account?.cancel();
    _account = null;
    await ApiService.signOut();
    navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
    messenger.showSnackBar(const SnackBar(
      content: Text('This staff account has been removed. '
          'Please contact an administrator.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // Built fresh on every build, and _AdminHome deliberately NOT const.
  //
  // The home page greets the signed-in staff member by name. A const widget is
  // canonicalised, so returning the same instance makes Flutter treat the
  // subtree as unchanged and skip it: after the Staff Profile screen renamed
  // the account, setState here reached the app bar but the header underneath
  // still read the old name (found while verifying the rename on the emulator,
  // 2026-09-23 — the same shape as the stale dashboard fixed in 41c1c50).
  // A new instance of the same type rebuilds the subtree while keeping its
  // State, so the stats already loaded are not re-fetched.
  List<Widget> get _pages => [
        // ignore: prefer_const_constructors
        _AdminHome(),
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
              // Stop following the account first: once signed out, the
              // listener would be refused and log a PERMISSION_DENIED.
              await _account?.cancel();
              _account = null;
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
            tooltip: 'My Profile',
            icon: const Icon(Icons.account_circle_outlined, color: Colors.white),
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const StaffProfileScreen()));
              // The dashboard header greets the signed-in staff member by name,
              // so redraw it in case the name was just changed.
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            onPressed: () => _confirmSignOut(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Keyed on the access level so a change picked up by _onAccount
          // rebuilds the open tab from scratch. Three of the four pages are
          // const, and setState skips a const page, so their Approve and Edit
          // buttons would otherwise outlive the level that allowed them.
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(Session.canManage),
              child: _pages[_currentIndex],
            ),
          ),
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

  // Every screen the Dashboard pushes can change a number the Dashboard shows:
  // a QR return clears an active loan and can add a damage report and a hold;
  // resolving a report frees an item and lifts a hold; Penalties and Students
  // both change the hold count. None of them reloaded on the way back, so
  // staff processed a return and the Dashboard went on listing the item as an
  // active — often overdue — loan until the app was restarted. Same family as
  // QA 2026-09-19 M4; found on the emulator 2026-09-21 while testing the QR
  // return flow.
  Future<void> _openThenReload(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    await _load();
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

  // A request may hold several records (one per unit); they are decided
  // together.
  Future<void> _approve(List<dynamic> request) async {
    final res = await ApiService.decideRequest(
        [for (final t in request) '${t['transaction_id']}'], 'approve');
    _showResult(res, 'Request approved.');
  }

  Future<void> _reject(List<dynamic> request) async {
    final reason = await showRejectRequestDialog(context);
    if (reason == null) return;
    final res = await ApiService.decideRequest(
        [for (final t in request) '${t['transaction_id']}'], 'reject',
        reason: reason);
    _showResult(res, 'Request rejected.');
  }

  // The same Good / Report Damage step as Scan QR (return_flow.dart). This
  // used to be a plain confirm that always recorded Good, so a damaged item
  // returned from here could not be logged (prof's comment 2026-10-05).
  Future<void> _return(dynamic loan) async {
    await showReturnSheet(
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
    if (mounted) _load();
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
                                          : Session.staffRoleLabel,
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
                            onPressed: () =>
                                _openThenReload(const QRScanScreen()),
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
                          onPressed: () =>
                              _openThenReload(const AdminDamageReportsScreen()),
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
                          onPressed: () =>
                              _openThenReload(const AdminPenaltiesScreen()),
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
                      // ── Staff accounts (super admin only) ──
                      // The rules refuse this to everyone else, so hiding it is
                      // a courtesy, not the control.
                      if (Session.isSuper) ...[
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                _openThenReload(const AdminStaffAccountsScreen()),
                            icon: const Icon(Icons.manage_accounts_outlined, size: 18),
                            label: const Text('Staff Accounts'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.accent,
                              side: const BorderSide(color: AppTheme.accent),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      // ── Students directory (all staff; viewer is read-only) ──
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _openThenReload(const AdminStudentsScreen()),
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
                          title: 'Pending Approvals (${ApiService.groupRequests(_pending).length})',
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
                        // One card per request, however many units it holds.
                        for (final request in ApiService.groupRequests(_pending))
                          PendingRequestCard(
                            request: request,
                            onApprove: () => _approve(request),
                            onReject: () => _reject(request),
                          ),
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
                          // Always a String, whatever the record holds (QA 2026-10-03).
                          final name = '${e['borrower_name'] ?? e['student_number'] ?? 'Student'}';
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
                                      onPressed: () => _return(e),
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

