// -----------------------------------------------------------------------------
// LabTrack - student: borrow request screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
//
// Reworked 2026-10-05 after the prof's comments ("the flow of borrowing is a
// bit confusing", "less inputs for the students"):
//   • the student picks item TYPES and how many of each ("Beaker 1000 mL × 2"),
//     not one numbered unit; the app reserves the units (ApiService
//     .borrowEquipment). The old Quantity box reserved nothing.
//   • the Borrow Time picker is gone: it was never saved (the borrow time is
//     when the request is sent), it only made the form longer;
//   • name and student ID are one read-only line instead of two locked fields;
//   • subject and purpose stay optional.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'lab_policies_screen.dart';

// ─── Item Type Picker Sheet ───────────────────────────────────────────────────
// Bottom sheet behind "Add equipment": every item type with at least one
// Available unit, how many are free, and a search box. Pops with the chosen
// type ({name, category, count, photo_thumb}).

class _TypePickerSheet extends StatefulWidget {
  final Set<String> alreadyAdded;
  const _TypePickerSheet({required this.alreadyAdded});
  @override
  State<_TypePickerSheet> createState() => _TypePickerSheetState();
}

class _TypePickerSheetState extends State<_TypePickerSheet> {
  List<Map<String, dynamic>> _types = [];
  bool _loading = true;
  bool _failed  = false;
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    ApiService.getAvailableTypes().then((types) {
      if (mounted) setState(() { _types = types; _loading = false; });
    }).catchError((_) {
      if (mounted) setState(() { _failed = true; _loading = false; });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.trim().toLowerCase();
    final shown = q.isEmpty
        ? _types
        : _types.where((t) => '${t['name']}'.toLowerCase().contains(q)).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(children: [
        // Handle
        Container(
          margin: const EdgeInsets.only(top: 12),
          width: 40, height: 4,
          decoration: BoxDecoration(
              color: AppTheme.divider, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(Icons.science_outlined, color: AppTheme.primary, size: 20),
            SizedBox(width: 10),
            Text('Add Equipment',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                    color: AppTheme.textDark)),
          ]),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('Only items available right now are shown.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            decoration: const InputDecoration(
              hintText: 'Search equipment...',
              prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMid),
            ),
          ),
        ),
        const Divider(color: AppTheme.divider, height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _failed
                  ? const Center(
                      child: Text('Could not load equipment.',
                          style: TextStyle(color: AppTheme.textMid)))
                  : shown.isEmpty
                      ? const Center(
                          child: Text('No available equipment.',
                              style: TextStyle(color: AppTheme.textMid)))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final t = shown[i];
                            final added = widget.alreadyAdded.contains('${t['name']}');
                            final count = t['count'] as int? ?? 0;
                            return GestureDetector(
                              onTap: () => Navigator.pop(context, t),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: added ? const Color(0x121B3A8C) : Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                      color: added ? AppTheme.primary : AppTheme.divider),
                                ),
                                child: Row(children: [
                                  EquipmentThumb(
                                    bytes: photoThumbOf(t),
                                    category: '${t['category'] ?? ''}',
                                    color: AppTheme.success,
                                    size: 40,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                    Text('${t['name']}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: AppTheme.textDark)),
                                    Text('$count available  •  ${t['category'] ?? ''}',
                                        style: const TextStyle(
                                            fontSize: 12, color: AppTheme.textMid)),
                                  ])),
                                  Icon(
                                    added
                                        ? Icons.check_circle_rounded
                                        : Icons.add_circle_outline_rounded,
                                    color: added ? AppTheme.primary : AppTheme.success,
                                  ),
                                ]),
                              ),
                            );
                          },
                        ),
        ),
      ]),
    );
  }
}

// One line of the request: an item type and how many.
class _Line {
  final String name;
  final String category;
  final Uint8List? thumb;
  // How many units are free right now; null while still being checked.
  int? available;
  int qty = 1;
  // The unit the student was looking at, reserved first if it is still free.
  final String preferId;
  _Line({
    required this.name,
    required this.category,
    this.thumb,
    this.available,
    this.preferId = '',
  });
}

// ─── Borrow Request Screen ─────────────────────────────────────────────────────

class BorrowRequestScreen extends StatefulWidget {
  final String? equipmentName;
  final String equipmentId; // Firebase doc ID is a String
  // Full equipment record when the student arrives from the catalog, so its
  // type can be added to the request straight away, with its photo.
  final Map<String, dynamic>? equipment;
  const BorrowRequestScreen({
    super.key,
    this.equipmentName,
    this.equipmentId = '',
    this.equipment,
  });
  @override
  State<BorrowRequestScreen> createState() => _BorrowRequestScreenState();
}

class _BorrowRequestScreenState extends State<BorrowRequestScreen> {
  bool _loading = false;
  bool _agreedToPolicies = false;
  final _subjectCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();
  final List<_Line> _lines = [];

  // Return time — default 5:00 PM, the latest the lab allows.
  TimeOfDay _returnTime = const TimeOfDay(hour: 17, minute: 0);

  int get _total => _lines.fold(0, (n, l) => n + l.qty);

  // Build DateTime from today + selected TimeOfDay
  DateTime _toDateTime(TimeOfDay t) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, t.hour, t.minute, 0);
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $p';
  }

  // Minutes since midnight — the return time is always today under the
  // same-day policy, so comparing times needs nothing more.
  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _pickReturnTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _returnTime,
      helpText: 'Return by',
    );
    if (picked == null) return;
    if (picked.hour > 17 || (picked.hour == 17 && picked.minute > 0)) {
      setState(() => _returnTime = const TimeOfDay(hour: 17, minute: 0));
      _warn('Return time cannot be later than 5:00 PM.');
    } else if (_minutes(picked) <= _minutes(TimeOfDay.now())) {
      // A return time already gone by makes the loan overdue the moment staff
      // approve it (QA 2026-09-19, M3). Refuse it instead of storing it.
      _warn('That time has already passed. Choose a later time today.');
    } else {
      setState(() => _returnTime = picked);
    }
  }

  void _warn(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppTheme.warning,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  void initState() {
    super.initState();
    // Arrived from the catalog: start the request with that item's type.
    final e = widget.equipment;
    final rawName = '${e?['equipment_name'] ?? widget.equipmentName ?? ''}';
    if (rawName.trim().isNotEmpty) {
      final line = _Line(
        name: ApiService.baseNameOf(rawName),
        category: '${e?['category'] ?? ''}',
        thumb: photoThumbOf(e),
        preferId: widget.equipmentId.isNotEmpty
            ? widget.equipmentId
            : '${e?['equipment_id'] ?? ''}',
      );
      _lines.add(line);
      // How many of that type are free, for the quantity limit.
      ApiService.getAvailableTypes().then((types) {
        if (!mounted) return;
        final match = types.where((t) => t['name'] == line.name).toList();
        setState(() => line.available =
            match.isEmpty ? 0 : (match.first['count'] as int? ?? 0));
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _purposeCtrl.dispose();
    super.dispose();
  }

  Future<void> _addItems() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _TypePickerSheet(alreadyAdded: {for (final l in _lines) l.name}),
    );
    if (picked == null) return;
    final name = '${picked['name']}';
    final count = picked['count'] as int? ?? 0;
    setState(() {
      final existing = _lines.where((l) => l.name == name).toList();
      if (existing.isNotEmpty) {
        final l = existing.first;
        l.available = count;
        if (l.qty < count && _total < kMaxUnitsPerRequest) l.qty++;
      } else if (_total < kMaxUnitsPerRequest) {
        _lines.add(_Line(
          name: name,
          category: '${picked['category'] ?? ''}',
          thumb: photoThumbOf(picked),
          available: count,
        ));
      } else {
        _warn('At most $kMaxUnitsPerRequest items per request.');
      }
    });
  }

  Future<void> _submitRequest() async {
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add the equipment you need first.'),
            backgroundColor: AppTheme.danger));
      return;
    }
    if (!_agreedToPolicies) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please read and agree to the Laboratory Policies first.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating));
      return;
    }
    if (Session.isOnHold) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.gpp_bad_rounded, color: AppTheme.danger, size: 48),
          title: const Text('Borrowing on Hold'),
          content: Text(
              Session.holdReason.isNotEmpty
                  ? Session.holdReason
                  : 'Your borrowing privileges are on hold. Please see the '
                      'laboratory staff to settle the penalty.',
              textAlign: TextAlign.center),
          actions: [
            ElevatedButton(
                onPressed: () => Navigator.pop(context), child: const Text('OK'))
          ],
        ),
      );
      return;
    }
    // A deadline that has already gone by makes the loan overdue the moment
    // staff approve it, so the request is refused here rather than stored
    // (QA 2026-09-19, M3). Under the same-day 5:00 PM policy that also means
    // nothing can be borrowed once 5:00 PM has passed.
    final nowTime = TimeOfDay.now();
    if (_minutes(nowTime) >= 17 * 60) {
      _warn('Borrowing is closed for today — all equipment is due back by '
          '5:00 PM. Please file the request tomorrow.');
      return;
    }
    if (_minutes(_returnTime) <= _minutes(nowTime)) {
      _warn('Return time ${_formatTime(_returnTime)} has already passed. '
          'Please choose a later time.');
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiService.borrowEquipment({
        'student_id':     Session.currentUser?['student_id']?.toString() ?? '',
        'borrower_name':  Session.name,
        'student_number': Session.studentNumber,
        'subject':        _subjectCtrl.text.trim(),
        'due_date':       _toDateTime(_returnTime).toIso8601String(),
        'purpose':        _purposeCtrl.text.trim(),
      }, [
        for (final l in _lines)
          (name: l.name, quantity: l.qty, preferId: l.preferId),
      ]);
      if (!mounted) return;
      if (res['success'] == true) {
        showDialog(context: context, barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
            title: const Text('Request Submitted!'),
            // What happens next, in order, so the student knows what to do.
            content: Text('You asked for ${res['summary'] ?? 'your equipment'}.\n\n'
                'Next: wait for staff to approve it (see My Loans). Once '
                'approved, pick it up at the lab and return it by '
                '${_formatTime(_returnTime)} today.',
                textAlign: TextAlign.center),
            actions: [ElevatedButton(
              onPressed: () { Navigator.pop(context); Navigator.pop(context); },
              child: const Text('Done'))],
          ));
      } else {
        // The full message is shown so it can be read completely.
        showDialog(context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: const Icon(Icons.error_outline_rounded,
                color: AppTheme.danger, size: 48),
            title: const Text('Submission Failed'),
            content: Text(res['message'] ?? 'Unknown error.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13)),
            actions: [ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'))],
          ));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ApiService.friendlyError(e)), backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 6)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // One requested item type with its quantity stepper.
  Widget _lineCard(_Line l) {
    final avail = l.available;
    final none = avail != null && avail == 0;
    final canAdd = (avail == null || l.qty < avail) && _total < kMaxUnitsPerRequest;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: none ? AppTheme.danger : AppTheme.divider),
      ),
      child: Row(children: [
        EquipmentThumb(
            bytes: l.thumb, category: l.category, color: AppTheme.success, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
            Text(
              avail == null
                  ? 'Checking availability…'
                  : none
                      ? 'Not available right now'
                      : '$avail available',
              style: TextStyle(
                  fontSize: 12, color: none ? AppTheme.danger : AppTheme.textMid),
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Fewer',
          onPressed: l.qty > 1 ? () => setState(() => l.qty--) : null,
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
        Text('${l.qty}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        IconButton(
          tooltip: 'More',
          onPressed: canAdd ? () => setState(() => l.qty++) : null,
          icon: const Icon(Icons.add_circle_outline_rounded),
        ),
        IconButton(
          tooltip: 'Remove',
          onPressed: () => setState(() => _lines.remove(l)),
          icon: const Icon(Icons.close_rounded, color: AppTheme.textMid),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Borrow Request')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. What to borrow ──
            FieldLabel('Equipment'),
            const SizedBox(height: 8),
            for (final l in _lines) _lineCard(l),
            GestureDetector(
              onTap: _addItems,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: const Color(0x0FF5A623),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0x4DF5A623))),
                child: Row(children: [
                  const Icon(Icons.add_circle_outline_rounded, color: AppTheme.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _lines.isEmpty ? 'Add equipment' : 'Add another item',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: AppTheme.accent),
                    ),
                  ),
                  Text('$_total / $kMaxUnitsPerRequest',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            // Who is borrowing: from the signed-in account, not editable — the
            // request is filed under the profile regardless (QA 2026-09-19, H5).
            Row(children: [
              const Icon(Icons.person_outline_rounded, size: 16, color: AppTheme.textMid),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Borrowing as ${Session.name} · ${Session.studentNumber}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
              ),
            ]),
            const SizedBox(height: 20),

            // ── 2. Until when ──
            FieldLabel('Return by'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickReturnTime,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: Row(children: [
                  const Icon(Icons.timer_outlined, color: AppTheme.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${_formatTime(_returnTime)} today',
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textDark)),
                  ),
                  const Text('Change',
                      style: TextStyle(fontSize: 12, color: AppTheme.accent)),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Everything is returned the same day, by 5:00 PM at the latest.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
            const SizedBox(height: 20),

            // ── 3. Optional details ──
            FieldLabel('Subject / Section (optional)'),
            const SizedBox(height: 8),
            TextField(controller: _subjectCtrl,
                decoration: const InputDecoration(hintText: 'e.g. CE 311 - Sec A')),
            const SizedBox(height: 16),
            FieldLabel('Purpose (optional)'),
            const SizedBox(height: 8),
            TextField(
              controller: _purposeCtrl,
              maxLines: 2,
              decoration: const InputDecoration(hintText: 'e.g. Slump test'),
            ),
            const SizedBox(height: 20),

            // ── Lab Policies Agreement ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x0A1B3A8C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x261B3A8C)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.policy_rounded,
                        color: AppTheme.primary, size: 16),
                    const SizedBox(width: 6),
                    const Text('Laboratory Policies',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primary)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(
                              builder: (_) => const LabPoliciesScreen())),
                      child: const Text('View All',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.accent,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline)),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  // Quick policy reminders
                  _PolicyReminder(
                    icon: Icons.warning_amber_rounded,
                    color: AppTheme.danger,
                    text: 'Damaged or missing equipment must be replaced.',
                  ),
                  const SizedBox(height: 6),
                  _PolicyReminder(
                    icon: Icons.access_time_rounded,
                    color: AppTheme.warning,
                    text: 'Return before 5:00 PM. Late returns lose borrowing privileges.',
                  ),
                  const SizedBox(height: 6),
                  _PolicyReminder(
                    icon: Icons.today_rounded,
                    color: AppTheme.primary,
                    text: 'Reservations are for same-day use only.',
                  ),
                  const SizedBox(height: 10),
                  // Agreement checkbox
                  GestureDetector(
                    onTap: () => setState(() => _agreedToPolicies = !_agreedToPolicies),
                    child: Row(children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 20, height: 20,
                        decoration: BoxDecoration(
                          color: _agreedToPolicies
                              ? AppTheme.primary
                              : Colors.white,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                              color: _agreedToPolicies
                                  ? AppTheme.primary
                                  : AppTheme.divider,
                              width: 1.5),
                        ),
                        child: _agreedToPolicies
                            ? const Icon(Icons.check_rounded,
                                color: Colors.white, size: 14)
                            : null,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'I have read and agree to the Laboratory Equipment Policies.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textDark),
                        ),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _submitRequest,
                icon: _loading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: const Text('Submit Request'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Policy Reminder widget ─────────────────────────────────────────────────────
class _PolicyReminder extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _PolicyReminder({required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 14),
      const SizedBox(width: 6),
      Expanded(child: Text(text,
          style: const TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4))),
    ]);
  }
}
