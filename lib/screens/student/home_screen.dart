// -----------------------------------------------------------------------------
// LabTrack - student: home screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/notif_prefs.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'alerts_screen.dart';
import 'equipment_catalog_screen.dart';
import 'borrow_request_screen.dart';
import 'damage_report_screen.dart';
import 'lab_policies_screen.dart';
import 'my_borrowings_screen.dart';
import 'profile_screen.dart';

// ─── Student Home Screen ──────────────────────────────────────────────────────

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});
  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const _StudentDashboard(),
    const EquipmentCatalogScreen(),
    const MyBorrowingsScreen(),
    const ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home_rounded),
                label: 'Home'),
            BottomNavigationBarItem(
                icon: Icon(Icons.inventory_2_outlined),
                activeIcon: Icon(Icons.inventory_2_rounded),
                label: 'Catalog'),
            BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_outlined),
                activeIcon: Icon(Icons.receipt_long_rounded),
                label: 'My Loans'),
            BottomNavigationBarItem(
                icon: Icon(Icons.person_outline_rounded),
                activeIcon: Icon(Icons.person_rounded),
                label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

// ─── Student Dashboard ────────────────────────────────────────────────────────

class _StudentDashboard extends StatefulWidget {
  const _StudentDashboard();
  @override
  State<_StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<_StudentDashboard> {
  bool _loading = true;
  List<dynamic> _allLoans = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Honour the user's saved notification toggles when building cards.
      await NotifPrefs.load();
      final loans = await ApiService.getMyBorrowings(
        studentId: Session.studentId,
        studentNumber: Session.studentNumber,
      );
      // Refresh the live hold/penalty flag so the banner stays current even if
      // staff placed a hold during this session.
      final sid = Session.currentUser?['student_id']?.toString() ?? '';
      if (sid.isNotEmpty) {
        final fresh = await ApiService.getStudent(sid);
        if (fresh != null && Session.currentUser != null) {
          Session.currentUser!['hold'] = fresh['hold'] ?? false;
          Session.currentUser!['hold_reason'] = fresh['hold_reason'] ?? '';
        }
      }
      setState(() { _allLoans = loans; _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  // Derive stats from live loans
  List<dynamic> get _activeLoans =>
      _allLoans.where((e) => e['status'] == 'Approved').toList();
  List<dynamic> get _pendingLoans =>
      _allLoans.where((e) => e['status'] == 'Pending').toList();

  int get _dueToday => _activeLoans.where((e) {
    final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
    if (due == null) return false;
    final now = DateTime.now();
    return due.year == now.year && due.month == now.month && due.day == now.day;
  }).length;

  int get _overdue => _activeLoans.where((e) {
    final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
    if (due == null) return false;
    return due.isBefore(DateTime.now());
  }).length;

  // Build notification cards from live loan statuses
  // How long a one-off alert stays on Home. Overdue and Due Today are live
  // state and never expire; the acknowledgements below do, so a week-old
  // "Return Confirmed" stops crowding out today's news. The bell still opens
  // the full list (QA 2026-09-19, low #9).
  static const _alertMaxAge = Duration(days: 7);

  // Every alert this student has, newest first — what the bell opens.
  List<Map<String, dynamic>> get _allNotifications {
    final notes = _buildNotifications();
    notes.sort((a, b) =>
        (b['at'] as DateTime).compareTo(a['at'] as DateTime));
    return notes;
  }

  // What Home shows: live state always, acknowledgements only while recent.
  List<Map<String, dynamic>> get _notifications {
    final now = DateTime.now();
    return _allNotifications
        .where((n) =>
            n['live'] == true ||
            now.difference(n['at'] as DateTime) <= _alertMaxAge)
        .toList();
  }

  List<Map<String, dynamic>> _buildNotifications() {
    final notes = <Map<String, dynamic>>[];
    for (final loan in _allLoans) {
      final status   = loan['status'] ?? '';
      final equipName= loan['equipment_name'] ?? 'Equipment';
      final due      = DateTime.tryParse('${loan['due_date']}'.replaceAll(' ', 'T'));
      final now      = DateTime.now();

      // Each card type honours the corresponding toggle in
      // Profile → Notifications (NotifPrefs).
      if (status == 'Approved' && due != null) {
        // Check overdue FIRST. The due date is 5:00 PM the same day, so an
        // item borrowed today and not returned by 5 is both "due today" and
        // overdue — and the due-today branch used to win, leaving the card
        // reading "due back today before 5:00 PM" at 10 PM while the Active
        // Loans list right below it badged the very same item "Overdue".
        if (NotifPrefs.overdue && due.isBefore(now)) {
          notes.add({
            'icon':  Icons.warning_amber_rounded,
            'color': AppTheme.danger,
            'title': 'Overdue!',
            'body':  '$equipName was due on ${due.month}/${due.day}. Please return it immediately.',
            'at':    due,
            'live':  true,
          });
        } else if (NotifPrefs.dueSoon &&
            due.year == now.year && due.month == now.month && due.day == now.day) {
          notes.add({
            'icon':  Icons.access_alarm_rounded,
            'color': AppTheme.warning,
            'title': 'Due Today',
            'body':  '$equipName is due back today before 5:00 PM.',
            'at':    due,
            'live':  true,
          });
        }
      }
      // Acknowledge the approval regardless of the due date. This used to
      // require `!due.isBefore(now)`, which silently suppressed the card for
      // anything approved after 5:00 PM — and since the due date IS 5:00 PM
      // the same day, every evening approval landed already past due. The
      // student got no confirmation at all that staff had approved them.
      if (NotifPrefs.approved && status == 'Approved' && due != null) {
        notes.add({
          'icon':  Icons.check_circle_rounded,
          'color': AppTheme.success,
          'title': 'Request Approved',
          'body':  'Your request for $equipName has been approved.',
          'at':    ApiService.asDate(loan['approved_at']) ?? due,
        });
      }
      if (NotifPrefs.rejected && status == 'Rejected') {
        notes.add({
          'icon':  Icons.cancel_rounded,
          'color': AppTheme.danger,
          'title': 'Request Rejected',
          'body':  'Your request for $equipName was rejected by staff.',
          'at':    ApiService.asDate(loan['rejected_at']) ??
                   ApiService.asDate(loan['borrow_date']) ?? DateTime(2000),
        });
      }
      if (NotifPrefs.returnConfirmed && status == 'Returned') {
        notes.add({
          'icon':  Icons.assignment_turned_in_rounded,
          'color': AppTheme.success,
          'title': 'Return Confirmed',
          'body':  'Your return of $equipName has been confirmed by staff.',
          'at':    ApiService.asDate(loan['return_date']) ??
                   ApiService.asDate(loan['borrow_date']) ?? DateTime(2000),
        });
      }
    }
    return notes;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            // ── Hero Header ──────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF0D2257), Color(0xFF1B3A8C), Color(0xFF1E4DB7)],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Stack(
                    children: [
                      // Decorative circles
                      Positioned(top: -30, right: -30,
                        child: Container(width: 130, height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x0AFFFFFF)))),
                      Positioned(top: 40, right: 40,
                        child: Container(width: 60, height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x1FF5A623)))),
                      Positioned(bottom: -10, left: -20,
                        child: Container(width: 90, height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x08FFFFFF)))),

                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Top bar — logo + notification
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // System tag
                                Row(children: [
                                  Container(
                                    width: 32, height: 32,
                                    decoration: BoxDecoration(
                                      color: const Color(0x33F5A623),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: const Icon(Icons.science_rounded,
                                        color: Color(0xFFF5A623), size: 18)),
                                  const SizedBox(width: 8),
                                  Column(crossAxisAlignment: CrossAxisAlignment.start,
                                    children: const [
                                      Text('LabTrack',
                                        style: TextStyle(color: Color(0xFFF5A623),
                                          fontSize: 12, fontWeight: FontWeight.w800,
                                          letterSpacing: 0.8)),
                                      Text('CEA Lab · NEU',
                                        style: TextStyle(color: Color(0x99FFFFFF),
                                          fontSize: 9)),
                                    ]),
                                ]),
                                // Notification bell. It carried a red dot
                                // whenever an alert existed but did nothing
                                // when tapped (QA 2026-09-19, low #1); it now
                                // opens the full list, which is also the only
                                // way to see past the three cards Home shows.
                                GestureDetector(
                                  onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => StudentAlertsScreen(
                                              alerts: _allNotifications))),
                                  child: Stack(children: [
                                    Container(
                                      width: 38, height: 38,
                                      decoration: BoxDecoration(
                                        color: const Color(0x1AFFFFFF),
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                      child: const Icon(Icons.notifications_outlined,
                                          color: Colors.white, size: 20)),
                                    if (_allNotifications.isNotEmpty)
                                      Positioned(top: 6, right: 6,
                                        child: Container(
                                          width: 8, height: 8,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFFEF4444),
                                            shape: BoxShape.circle))),
                                  ]),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),

                            // System title — the main identity
                            const Text(
                              'Mobile Equipment Borrowing\n& Return Monitoring System',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                height: 1.25,
                                letterSpacing: 0.1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text('for School Laboratories',
                              style: TextStyle(color: Color(0xFFF5A623),
                                fontSize: 12, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 16),

                            // User greeting chip
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: const Color(0x1AFFFFFF),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: const Color(0x26FFFFFF)),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor: const Color(0xFFF5A623)
                                        .withValues(alpha: 0.25),
                                    child: Text(Session.initials,
                                      style: const TextStyle(
                                        color: Color(0xFFF5A623),
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('$greeting, ${Session.name.split(' ').first}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500)),
                                ]),
                            ),
                            const SizedBox(height: 20),

                            // ── Stats row inside header ──
                            if (!_loading)
                              Row(children: [
                                _HeroStat(
                                  value: '${_activeLoans.length}',
                                  label: 'Active\nLoans',
                                  icon: Icons.inventory_2_rounded,
                                  accent: const Color(0xFFF5A623),
                                ),
                                const SizedBox(width: 10),
                                _HeroStat(
                                  value: '$_dueToday',
                                  label: 'Due\nToday',
                                  icon: Icons.schedule_rounded,
                                  accent: const Color(0xFFFFB703),
                                ),
                                const SizedBox(width: 10),
                                _HeroStat(
                                  value: '${_pendingLoans.length}',
                                  label: 'Pending\nRequests',
                                  icon: Icons.pending_actions_rounded,
                                  accent: const Color(0xFF60A5FA),
                                ),
                                const SizedBox(width: 10),
                                _HeroStat(
                                  value: '$_overdue',
                                  label: 'Over-\ndue',
                                  icon: Icons.warning_amber_rounded,
                                  accent: _overdue > 0
                                      ? const Color(0xFFEF4444)
                                      : const Color(0xFF06D6A0),
                                ),
                              ]),
                            if (_loading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2)),
                              ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (!_loading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      // ── Penalty / Hold banner (Prof recommendation #3) ──
                      if (Session.isOnHold || _overdue > 0) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0x1AE74C3C),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: AppTheme.danger.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.gpp_bad_rounded,
                                  color: AppTheme.danger, size: 22),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        Session.isOnHold
                                            ? 'Borrowing on Hold'
                                            : 'Overdue Equipment',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: AppTheme.danger)),
                                    const SizedBox(height: 4),
                                    Text(
                                      // A hold and an overdue item are separate
                                      // triggers, so never claim the student has
                                      // overdue equipment when they simply have a
                                      // hold recorded with no reason.
                                      Session.isOnHold && Session.holdReason.isNotEmpty
                                          ? Session.holdReason
                                          : _overdue > 0
                                              ? 'You have overdue equipment. Please return it and '
                                                  'settle any penalty with the laboratory staff '
                                                  'before borrowing again.'
                                              : 'Your borrowing privileges are on hold. Please see '
                                                  'the laboratory staff to settle the penalty.',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textDark,
                                          height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // ── Alerts / Notifications ──────────────────────────
                      if (_notifications.isNotEmpty) ...[
                        Row(children: [
                          const Expanded(
                            child: SectionTitle(title: 'Alerts',
                                icon: Icons.notifications_active_rounded,
                                color: Color(0xFFEF4444)),
                          ),
                          // Home shows three; this and the bell are the only
                          // ways to the rest (QA 2026-09-19, low #9).
                          if (_allNotifications.length > 3)
                            TextButton(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => StudentAlertsScreen(
                                          alerts: _allNotifications))),
                              child: const Text('See all',
                                  style: TextStyle(
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ),
                        ]),
                        const SizedBox(height: 10),
                        ..._notifications.take(3).map((n) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AlertCard(
                            icon:  n['icon'] as IconData,
                            color: n['color'] as Color,
                            title: n['title'] as String,
                            body:  n['body']  as String,
                          ),
                        )),
                        const SizedBox(height: 20),
                      ],

                      // ── Quick Actions ────────────────────────────────────
                      SectionTitle(title: 'Quick Actions',
                          icon: Icons.flash_on_rounded,
                          color: const Color(0xFFF5A623)),
                      const SizedBox(height: 12),
                      Row(children: [
                        _ActionTile(
                          icon: Icons.add_circle_rounded,
                          label: 'New\nRequest',
                          gradient: const [Color(0xFF1B3A8C), Color(0xFF1E4DB7)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const BorrowRequestScreen())),
                        ),
                        const SizedBox(width: 10),
                        _ActionTile(
                          icon: Icons.receipt_long_rounded,
                          label: 'My\nLoans',
                          gradient: const [Color(0xFF059669), Color(0xFF10B981)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const MyBorrowingsScreen())),
                        ),
                        const SizedBox(width: 10),
                        _ActionTile(
                          icon: Icons.report_problem_rounded,
                          label: 'Damage\nReport',
                          gradient: const [Color(0xFFD97706), Color(0xFFF59E0B)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const DamageReportScreen())),
                        ),
                        const SizedBox(width: 10),
                        _ActionTile(
                          icon: Icons.policy_rounded,
                          label: 'Lab\nPolicies',
                          gradient: const [Color(0xFF7C3AED), Color(0xFF8B5CF6)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const LabPoliciesScreen())),
                        ),
                      ]),
                      const SizedBox(height: 24),

                      // ── Active Loans ─────────────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          SectionTitle(title: 'Active Loans',
                              icon: Icons.inventory_2_rounded,
                              color: const Color(0xFF1B3A8C)),
                          if (_activeLoans.isNotEmpty || _pendingLoans.isNotEmpty)
                            GestureDetector(
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const MyBorrowingsScreen())),
                              child: const Text('See all',
                                style: TextStyle(
                                  color: Color(0xFF1B3A8C),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                )),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      if (_activeLoans.isEmpty && _pendingLoans.isEmpty)
                        EmptyCard(
                          icon: Icons.inventory_2_outlined,
                          title: 'No active loans',
                          subtitle: 'Tap "New Request" to borrow equipment',
                        )
                      else ...[
                        ..._pendingLoans.take(2).map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _LoanItemCard(
                            name: '${e['equipment_name'] ?? ''}',
                            qr: '${e['qr_code'] ?? ''}',
                            status: 'Pending',
                            statusColor: const Color(0xFFF5A623),
                            subtitle: 'Awaiting staff approval',
                            icon: Icons.pending_actions_rounded,
                          ),
                        )),
                        ..._activeLoans.take(3).map((e) {
                          final due = DateTime.tryParse(
                              '${e['due_date']}'.replaceAll(' ', 'T'));
                          final now2 = DateTime.now();
                          final isOverdue = due != null && due.isBefore(now2);
                          final isDueToday = due != null &&
                              due.year == now2.year &&
                              due.month == now2.month &&
                              due.day == now2.day;
                          final status = isOverdue ? 'Overdue'
                              : isDueToday ? 'Due Today' : 'Active';
                          final statusColor = isOverdue
                              ? const Color(0xFFEF4444)
                              : isDueToday
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF059669);
                          final dueStr = due != null
                              ? '${due.month}/${due.day} · 5:00 PM'
                              : '';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _LoanItemCard(
                              name: '${e['equipment_name'] ?? ''}',
                              qr: '${e['qr_code'] ?? ''}',
                              status: status,
                              statusColor: statusColor,
                              subtitle: 'Return by $dueStr',
                              icon: isOverdue
                                  ? Icons.warning_amber_rounded
                                  : isDueToday
                                      ? Icons.access_alarm_rounded
                                      : Icons.check_circle_outline_rounded,
                            ),
                          );
                        }),
                      ],
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

// ── Dashboard Helper Widgets ──────────────────────────────────────────────────

class _HeroStat extends StatelessWidget {
  final String value, label;
  final IconData icon;
  final Color accent;
  const _HeroStat({required this.value, required this.label,
      required this.icon, required this.accent});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Column(children: [
          Icon(icon, color: accent, size: 18),
          const SizedBox(height: 5),
          Text(value, style: const TextStyle(
              color: Colors.white, fontSize: 18,
              fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(label, textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xAAFFFFFF),
                  fontSize: 9, height: 1.2)),
        ]),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<Color> gradient;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.label,
      required this.gradient, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(
                color: gradient.last.withValues(alpha: 0.3),
                blurRadius: 8, offset: const Offset(0, 4))],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 5),
              Text(label, textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10,
                      fontWeight: FontWeight.w600, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoanItemCard extends StatelessWidget {
  final String name, qr, status, subtitle;
  final Color statusColor;
  final IconData icon;
  const _LoanItemCard({required this.name, required this.qr,
      required this.status, required this.subtitle,
      required this.statusColor, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: const Color(0x0A000000),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: statusColor, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold,
                color: Color(0xFF1A1D2E))),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(
                fontSize: 11, color: Color(0xFF6B7280))),
            const SizedBox(height: 4),
            Text(qr, style: const TextStyle(
                fontSize: 10, color: Color(0xFF9CA3AF),
                fontFamily: 'Courier New')),
          ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20)),
          child: Text(status, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold,
              color: statusColor))),
      ]),
    );
  }
}



