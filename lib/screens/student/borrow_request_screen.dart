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
// 1.0.20 (2026-10-19, the lab's rules): Subject and Where (where the items
// will be used) are required so staff can trace every borrower; the student
// must choose the return time; requests from 7:00 AM, back by 10:00 PM.
// 1.0.19 (2026-10-15): the item list comes from the item-type list and a
// type's free units are counted only when it is picked (Firestore reads, see
// ApiService "Item types").
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
// Bottom sheet behind "Add equipment": the item types in the lab and a search
// box. Pops with the chosen type ({name, category, count, photo_thumb}), where
// count is how many are free right now.
//
// Since 1.0.19 the list is the item-type list (one read, kept for a few
// minutes) and a type's free units are counted when the student taps it (one
// read). The sheet used to read every Available unit each time it opened:
// ~945 reads with the full inventory (2026-10-15).

class _TypePickerSheet extends StatefulWidget {
  final Set<String> alreadyAdded;
  const _TypePickerSheet({required this.alreadyAdded});
  @override
  State<_TypePickerSheet> createState() => _TypePickerSheetState();
}

class _TypePickerSheetState extends State<_TypePickerSheet> {
  List<Map<String, dynamic>> _types = [];
  // Until staff build the type list, the old list is used; it already knows
  // how many of each are free.
  bool _counted = false;
  bool _loading = true;
  bool _failed  = false;
  final _searchCtrl = TextEditingController();
  String _search = '';
  // The type being checked after a tap, and what a check found when nothing
  // could be added.
  String _checking = '';
  final Map<String, String> _note = {};

  @override
  void initState() {
    super.initState();
    ApiService.getBorrowableTypes().then((res) {
      if (mounted) {
        setState(() { _types = res.types; _counted = res.counted; _loading = false; });
      }
    }).catchError((_) {
      if (mounted) setState(() { _failed = true; _loading = false; });
    });
  }

  Future<void> _pick(Map<String, dynamic> t) async {
    if (_checking.isNotEmpty) return;
    if (_counted) {
      Navigator.pop(context, {...t, 'count': t['available']});
      return;
    }
    final name = '${t['name']}';
    setState(() { _checking = name; _note.remove(name); });
    try {
      final free = await ApiService.availableNow(name);
      if (!mounted) return;
      if (free > 0) {
        Navigator.pop(context, {...t, 'count': free});
        return;
      }
      final inLab = t['in_service'] as int? ?? 0;
      setState(() => _note[name] = inLab == 1
          ? 'None free right now: it is out or reserved.'
          : 'None free right now: all $inLab are out or reserved.');
    } catch (_) {
      if (mounted) setState(() => _note[name] = 'Could not check. Tap to try again.');
    } finally {
      if (mounted) setState(() => _checking = '');
    }
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
              _counted
                  ? 'Only items available right now are shown.'
                  : 'Tap an item to add it. The app checks how many are free.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
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
                      ? Center(
                          child: Text(
                              _types.isEmpty
                                  ? 'No available equipment.'
                                  : 'No equipment matches "$_search".',
                              style: const TextStyle(color: AppTheme.textMid)))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final t = shown[i];
                            final name = '${t['name']}';
                            final added = widget.alreadyAdded.contains(name);
                            final checking = _checking == name;
                            final note = _note[name];
                            final line = _counted
                                ? '${t['available'] ?? 0} available  •  ${t['category'] ?? ''}'
                                : '${t['in_service'] ?? 0} in the lab  •  ${t['category'] ?? ''}';
                            return GestureDetector(
                              onTap: () => _pick(t),
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
                                    Text(note ?? line,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: note == null
                                                ? AppTheme.textMid
                                                : AppTheme.danger)),
                                  ])),
                                  if (checking)
                                    const SizedBox(
                                        width: 22, height: 22,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                  else
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
  // How many of that type are free, when the item page has just counted them
  // (1.0.19), so the form does not count again.
  final int? available;
  const BorrowRequestScreen({
    super.key,
    this.equipmentName,
    this.equipmentId = '',
    this.equipment,
    this.available,
  });
  @override
  State<BorrowRequestScreen> createState() => _BorrowRequestScreenState();
}

class _BorrowRequestScreenState extends State<BorrowRequestScreen> {
  bool _loading = false;
  bool _agreedToPolicies = false;
  final _subjectCtrl = TextEditingController();
  final _whereCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();
  final List<_Line> _lines = [];

  // Return time: none until the student chooses one (required, 1.0.20).
  TimeOfDay? _returnTime;

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
      initialTime: _returnTime ?? TimeOfDay.now(),
      helpText: 'Return by',
    );
    if (picked == null) return;
    if (_minutes(picked) > kReturnByHour * 60) {
      _warn('Return time cannot be later than 10:00 PM.');
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
    // A student on hold only found out on Submit, after filling the whole
    // form (QA 2026-10-06). Re-read the hold, as Home does, and say it up
    // front. Submit still asks the server, which has the last word.
    final sid = Session.currentUser?['student_id']?.toString() ?? '';
    if (sid.isNotEmpty) {
      ApiService.getStudent(sid).then((fresh) {
        if (!mounted || fresh == null || Session.currentUser == null) return;
        setState(() {
          Session.currentUser!['hold'] = fresh['hold'] ?? false;
          Session.currentUser!['hold_reason'] = fresh['hold_reason'] ?? '';
        });
      }).catchError((_) {});
    }
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
      // How many of that type are free, for the quantity limit: one count
      // (1.0.19), or none when the item page has just counted.
      final known = widget.available;
      if (known != null) {
        line.available = known;
      } else {
        ApiService.availableNow(line.name).then((n) {
          if (mounted) setState(() => line.available = n);
        }).catchError((_) {});
      }
    }
  }

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _whereCtrl.dispose();
    _purposeCtrl.dispose();
    super.dispose();
  }

  Future<void> _addItems() async {
    // Full already: say so here instead of opening the picker and refusing
    // the pick afterwards (QA 2026-10-06).
    if (_total >= kMaxUnitsPerRequest) {
      _warn('At most $kMaxUnitsPerRequest items per request.');
      return;
    }
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
    // (QA 2026-09-19, M3). Borrowing hours are 7:00 AM to 10:00 PM, the
    // latest return time, so nothing can be borrowed outside them.
    final nowTime = TimeOfDay.now();
    if (nowTime.hour < kBorrowOpenHour) {
      _warn('Borrowing opens at 7:00 AM. Please send the request then.');
      return;
    }
    if (_minutes(nowTime) >= kReturnByHour * 60) {
      _warn('Borrowing is closed for today — all equipment is due back by '
          '10:00 PM. Please file the request tomorrow.');
      return;
    }
    if (_subjectCtrl.text.trim().isEmpty || _whereCtrl.text.trim().isEmpty) {
      _warn('Please fill in the Subject and where you will use the equipment.');
      return;
    }
    final returnTime = _returnTime;
    if (returnTime == null) {
      _warn('Please choose your return time.');
      return;
    }
    if (_minutes(returnTime) <= _minutes(nowTime)) {
      _warn('Return time ${_formatTime(returnTime)} has already passed. '
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
        'use_location':   _whereCtrl.text.trim(),
        'due_date':       _toDateTime(returnTime).toIso8601String(),
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
                '${_formatTime(returnTime)} today.',
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
            if (Session.isOnHold)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0x1AE74C3C),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.gpp_bad_rounded, color: AppTheme.danger, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Borrowing on hold. You cannot send a request until the '
                      'laboratory staff lift it.'
                      '${Session.holdReason.isNotEmpty ? '\n${Session.holdReason}' : ''}',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textDark, height: 1.4),
                    ),
                  ),
                ]),
              ),
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
                    child: Text(
                        _returnTime == null
                            ? 'Choose a return time'
                            : '${_formatTime(_returnTime!)} today',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _returnTime == null
                                ? AppTheme.textMid
                                : AppTheme.textDark)),
                  ),
                  Text(_returnTime == null ? 'Choose' : 'Change',
                      style: const TextStyle(fontSize: 12, color: AppTheme.accent)),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Everything is returned the same day, by 10:00 PM at the latest.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
            const SizedBox(height: 20),

            // ── 3. Details: staff trace the borrower by these ──
            FieldLabel('Subject / Section'),
            const SizedBox(height: 8),
            TextField(controller: _subjectCtrl,
                maxLength: 200,
                decoration: const InputDecoration(
                    hintText: 'e.g. CE 311 - Sec A', counterText: '')),
            const SizedBox(height: 16),
            FieldLabel('Where you will use it'),
            const SizedBox(height: 8),
            TextField(controller: _whereCtrl,
                maxLength: 200,
                decoration: const InputDecoration(
                    hintText: 'e.g. Room 301, CE Lab', counterText: '')),
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
                    text: 'Return by 10:00 PM. Late returns lose borrowing privileges.',
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
