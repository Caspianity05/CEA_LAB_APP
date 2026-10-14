// -----------------------------------------------------------------------------
// LabTrack - student: borrow request screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'lab_policies_screen.dart';

// ─── Equipment Picker Sheet ───────────────────────────────────────────────────
// Bottom sheet behind the borrow form's equipment field. Pages through the
// collection (see ApiService.getEquipmentPage) rather than reading all of it,
// and pops with the chosen record.

class _EquipmentPickerSheet extends StatefulWidget {
  final String selectedId;
  const _EquipmentPickerSheet({required this.selectedId});
  @override
  State<_EquipmentPickerSheet> createState() => _EquipmentPickerSheetState();
}

class _EquipmentPickerSheetState extends State<_EquipmentPickerSheet> {
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  final List<Map<String, dynamic>> _items = [];
  DocumentSnapshot? _cursor;
  bool _loading     = true;
  bool _loadingMore = false;
  bool _hasMore     = true;
  bool _failed      = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) _loadMore();
  }

  // Only 'Available' equipment is offered. That filter runs on the client,
  // because combining it with the name ordering server-side would need a
  // composite index (see the TODO in _AdminInventoryScreenState), so a page
  // can arrive with nothing to show — build() keeps pulling until it does.
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await ApiService.getEquipmentPage(
          limit: _pageSize, startAfter: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items.where((e) => e['status'] == 'Available'));
        _cursor      = page.cursor ?? _cursor;
        _hasMore     = page.hasMore;
        _loading     = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed      = _items.isEmpty;
        _hasMore     = false;
        _loading     = false;
        _loadingMore = false;
      });
    }
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: Text('No available equipment.',
              style: TextStyle(color: AppTheme.textMid)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }

  @override
  Widget build(BuildContext context) {
    // Every item loaded so far was filtered out — pull the next page.
    if (!_loading && !_loadingMore && _hasMore && _items.length < _pageSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
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
              color: AppTheme.divider,
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(Icons.science_outlined, color: AppTheme.primary, size: 20),
            SizedBox(width: 10),
            Text('Select Equipment',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                    color: AppTheme.textDark)),
          ]),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('Only available equipment is shown.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
        ),
        const SizedBox(height: 12),
        const Divider(color: AppTheme.divider, height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _failed
                  ? const Center(
                      child: Text('Could not load equipment.',
                          style: TextStyle(color: AppTheme.textMid)))
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      // One extra row for the paging footer.
                      itemCount: _items.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        if (i == _items.length) return _footer();
                        final e = _items[i];
                        final isSelected =
                            widget.selectedId == '${e['equipment_id']}';
                        return GestureDetector(
                          onTap: () => Navigator.pop(context, e),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0x121B3A8C)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: isSelected
                                      ? AppTheme.primary
                                      : AppTheme.divider),
                            ),
                            child: Row(children: [
                              EquipmentThumb(
                                bytes: photoThumbOf(e),
                                category: e['category'] as String? ?? '',
                                color: AppTheme.success,
                                size: 40,
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(e['equipment_name'] as String,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: AppTheme.textDark)),
                                Text('${e['qr_code']}  •  ${e['category']}',
                                    style: const TextStyle(
                                        fontSize: 12, color: AppTheme.textMid)),
                              ])),
                              StatusBadge(label: 'Available', color: AppTheme.success),
                              if (isSelected) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.check_circle_rounded,
                                    color: AppTheme.primary, size: 20),
                              ],
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

// ─── Borrow Request Screen ─────────────────────────────────────────────────────

class BorrowRequestScreen extends StatefulWidget {
  final String? equipmentName;
  final String equipmentId; // Firebase doc ID is a String
  // Full equipment record when the student arrives from the catalog, so the
  // confirmation card can show the photo without re-reading the document.
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
  int _qty = 1;
  bool _loading = false;
  bool _agreedToPolicies = false;
  final _nameCtrl    = TextEditingController();
  final _idCtrl      = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();

  // Selected equipment — Firebase doc ID stored as String
  String _selectedEquipmentId   = '';
  String _selectedEquipmentName = '';
  // Full record of the selection, so the student can check the photo and the
  // identifying details before submitting and avoid requesting the wrong item.
  Map<String, dynamic> _selectedEquipment = {};

  String _sel(String key) => '${_selectedEquipment[key] ?? ''}';

  // Borrow time — default now, return time — default 5:00 PM
  TimeOfDay _borrowTime = TimeOfDay.now();
  TimeOfDay _returnTime = const TimeOfDay(hour: 17, minute: 0);

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

  Future<void> _pickBorrowTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _borrowTime,
      helpText: 'Select Borrow Time',
    );
    if (picked == null) return;
    if (_minutes(picked) >= _minutes(_returnTime)) {
      _warn('Borrow time must be earlier than the return time '
          '(${_formatTime(_returnTime)}).');
      return;
    }
    setState(() => _borrowTime = picked);
  }

  Future<void> _pickReturnTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _returnTime,
      helpText: 'Select Return Time',
    );
    if (picked != null) {
      // Enforce max 5:00 PM
      final maxReturn = const TimeOfDay(hour: 17, minute: 0);
      if (picked.hour > 17 || (picked.hour == 17 && picked.minute > 0)) {
        setState(() => _returnTime = maxReturn);
        _warn('Return time cannot be later than 5:00 PM.');
      } else if (_minutes(picked) <= _minutes(_borrowTime)) {
        // A return before the borrow time is not a loan period, and one
        // already in the past is overdue the moment staff approve it
        // (QA 2026-09-19, M3). Refuse it instead of storing it.
        _warn('Return time must be later than the borrow time '
            '(${_formatTime(_borrowTime)}).');
      } else {
        setState(() => _returnTime = picked);
      }
    }
  }

  // Minutes since midnight — the borrow and return times are always on the
  // same day under the same-day policy, so comparing them needs nothing more.
  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

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
    _nameCtrl.text = Session.name;
    _idCtrl.text   = Session.studentNumber;
    // Pre-fill if coming from catalog
    _selectedEquipmentId   = widget.equipmentId;
    _selectedEquipmentName = widget.equipmentName ?? '';
    _selectedEquipment     = widget.equipment ?? {};
    // Arrived with an id but no record (e.g. an older call site) — fetch just
    // that document so the confirmation card still shows the photo.
    if (_selectedEquipmentId.isNotEmpty && _selectedEquipment.isEmpty) {
      ApiService.getEquipmentById(_selectedEquipmentId).then((match) {
        if (!mounted || match == null) return;
        setState(() => _selectedEquipment = match);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _subjectCtrl.dispose();
    _purposeCtrl.dispose();
    super.dispose();
  }

  // Opens a bottom sheet to pick equipment from the catalog
  Future<void> _pickEquipment() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EquipmentPickerSheet(selectedId: _selectedEquipmentId),
    );
    if (picked == null) return;
    setState(() {
      _selectedEquipmentId   = '${picked['equipment_id']}';
      _selectedEquipmentName = picked['equipment_name'] as String;
      _selectedEquipment     = picked;
    });
  }

  Future<void> _submitRequest() async {
    if (_selectedEquipmentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an equipment first.'),
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
    if (_minutes(_returnTime) <= _minutes(_borrowTime)) {
      _warn('Return time must be later than the borrow time '
          '(${_formatTime(_borrowTime)}).');
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
        'equipment_id':   _selectedEquipmentId,
        'borrower_name':  _nameCtrl.text.trim(),
        'student_number': _idCtrl.text.trim(),
        'subject':        _subjectCtrl.text.trim(),
        'quantity':       _qty,
        'borrow_date':    _toDateTime(_borrowTime).toIso8601String(),
        'due_date':       _toDateTime(_returnTime).toIso8601String(),
        'purpose':        _purposeCtrl.text.trim(),
      });
      if (!mounted) return;
      if (res['success'] == true) {
        showDialog(context: context, barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
            title: const Text('Request Submitted!'),
            // The deadline the student actually chose — this used to read
            // "before 5:00 PM" whatever was picked (QA 2026-09-19, M3).
            content: Text('Your borrowing request has been submitted and is '
                'awaiting staff approval. Please return the equipment by '
                '${_formatTime(_returnTime)} today.',
                textAlign: TextAlign.center),
            actions: [ElevatedButton(
              onPressed: () { Navigator.pop(context); Navigator.pop(context); },
              child: const Text('Done'))],
          ));
      } else {
        // The full message is shown so it can be read completely. (Until
        // 2026-09-20 a program/course restriction had its own dialog here; the
        // restriction was removed, so every failure is a plain error now.)
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Borrow Request')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Equipment picker — tappable
            GestureDetector(
              onTap: _pickEquipment,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: _selectedEquipmentId.isEmpty
                        ? const Color(0x0FF5A623)
                        : const Color(0x0F06D6A0),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: _selectedEquipmentId.isEmpty
                            ? const Color(0x4DF5A623)
                            : AppTheme.success.withValues(alpha: 0.3))),
                child: Row(
                  children: [
                    if (_selectedEquipmentId.isEmpty)
                      Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                            color: AppTheme.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.add_circle_outline_rounded,
                            color: AppTheme.accent),
                      )
                    else
                      EquipmentThumb(
                        bytes: photoThumbOf(_selectedEquipment),
                        category: _sel('category'),
                        color: AppTheme.success,
                        size: 64,
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedEquipmentId.isEmpty
                                ? 'Tap to Select Equipment'
                                : _selectedEquipmentName,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: _selectedEquipmentId.isEmpty
                                    ? AppTheme.accent
                                    : AppTheme.textDark),
                          ),
                          const SizedBox(height: 2),
                          // Identifying details, so two similar-looking items
                          // are not mistaken for one another.
                          if (_selectedEquipmentId.isNotEmpty) ...[
                            if (_sel('qr_code').isNotEmpty)
                              Text(
                                [_sel('qr_code'), _sel('category')]
                                    .where((s) => s.isNotEmpty)
                                    .join('  •  '),
                                style: const TextStyle(
                                    fontSize: 12, color: AppTheme.textMid),
                              ),
                            if (_sel('brand').isNotEmpty ||
                                _sel('model').isNotEmpty)
                              Text(
                                [_sel('brand'), _sel('model')]
                                    .where((s) => s.isNotEmpty)
                                    .join(' '),
                                style: const TextStyle(
                                    fontSize: 12, color: AppTheme.textMid),
                              ),
                            const SizedBox(height: 2),
                          ],
                          Text(
                            _selectedEquipmentId.isEmpty
                                ? 'Required — choose from available equipment'
                                : 'Check the photo, then tap to change selection',
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textMid),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _selectedEquipmentId.isEmpty
                          ? AppTheme.accent
                          : AppTheme.success,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Name and Student ID come from the signed-in account and are
            // read-only: the request is filed under the profile regardless
            // (see ApiService.borrowEquipment), so letting them be edited only
            // invited a forged identity (QA 2026-09-19, H5).
            FieldLabel('Borrower Name'),
            const SizedBox(height: 8),
            TextField(controller: _nameCtrl, readOnly: true,
                decoration: const InputDecoration(
                    suffixIcon: Icon(Icons.lock_outline_rounded, size: 18, color: AppTheme.textMid))),
            const SizedBox(height: 16),
            FieldLabel('Student ID'),
            const SizedBox(height: 8),
            TextField(controller: _idCtrl, readOnly: true,
                decoration: const InputDecoration(
                    suffixIcon: Icon(Icons.lock_outline_rounded, size: 18, color: AppTheme.textMid),
                    helperText: 'From your account. Change your name in Profile → Edit Profile.')),
            const SizedBox(height: 16),
            FieldLabel('Subject / Section'),
            const SizedBox(height: 8),
            TextField(controller: _subjectCtrl, decoration: const InputDecoration(hintText: 'e.g. PHYS101 - Sec A')),
            const SizedBox(height: 16),
            FieldLabel('Quantity'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider)),
              child: Row(
                children: [
                  IconButton(
                      onPressed: () => setState(() => _qty = (_qty - 1).clamp(1, 10)),
                      icon: const Icon(Icons.remove_rounded)),
                  Expanded(child: Center(child: Text('$_qty',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
                  IconButton(
                      onPressed: () => setState(() => _qty = (_qty + 1).clamp(1, 10)),
                      icon: const Icon(Icons.add_rounded)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ── Time Selection ──
            Row(children: [
              // Borrow Time
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FieldLabel('Borrow Time'),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _pickBorrowTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.divider),
                        ),
                        child: Row(children: [
                          const Icon(Icons.access_time_rounded,
                              color: AppTheme.primary, size: 18),
                          const SizedBox(width: 8),
                          Text(_formatTime(_borrowTime),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textDark)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Return Time
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FieldLabel('Return Time'),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _pickReturnTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _returnTime.hour >= 17
                                  ? AppTheme.warning
                                  : AppTheme.divider),
                        ),
                        child: Row(children: [
                          Icon(Icons.timer_outlined,
                              color: _returnTime.hour >= 17
                                  ? AppTheme.warning
                                  : AppTheme.primary,
                              size: 18),
                          const SizedBox(width: 8),
                          Text(_formatTime(_returnTime),
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _returnTime.hour >= 17
                                      ? AppTheme.warning
                                      : AppTheme.textDark)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 6),
            const Text('⚠️ Equipment must be returned before 5:00 PM.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
            const SizedBox(height: 16),
            // ── Return Deadline info ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x14FFB703),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x4DFFB703)),
              ),
              child: Row(children: [
                const Icon(Icons.access_time_rounded,
                    color: AppTheme.warning, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('Return Deadline',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.warning)),
                    const SizedBox(height: 2),
                    Text(
                        'Selected return time: ${_formatTime(_returnTime)}. All equipment must be returned today.',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textDark)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            FieldLabel('Purpose / Notes'),
            const SizedBox(height: 8),
            TextField(
              controller: _purposeCtrl,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Describe the purpose of borrowing...'),
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



