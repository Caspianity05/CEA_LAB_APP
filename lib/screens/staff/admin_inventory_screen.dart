// -----------------------------------------------------------------------------
// LabTrack - staff: admin inventory screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../student/equipment_detail_screen.dart';
import 'equipment_registration_screen.dart';

// ─── Admin Inventory Screen ──────────────────────────────────────────────────

class AdminInventoryScreen extends StatefulWidget {
  const AdminInventoryScreen({super.key});
  @override
  State<AdminInventoryScreen> createState() => _AdminInventoryScreenState();
}

class _AdminInventoryScreenState extends State<AdminInventoryScreen> {
  List<dynamic> _equipment = [];
  bool _loading = true;
  bool _hasError = false;
  String _search = '';
  // Keeps the typed text on screen across reloads. Without it, every _load()
  // (after an edit, a delete or a new registration) swapped the screen for a
  // spinner and rebuilt the search box empty while _search still filtered the
  // list, so staff saw an empty box and "No equipment found" (found on the
  // phone, 2026-10-05).
  final _searchCtrl = TextEditingController();
  // TODO(scalability): this category filter is single-select, so unlike the
  // student catalog's multi-select it COULD run server-side as
  //   .where('category', isEqualTo: _filter).orderBy('equipment_name')
  // which would stop the list paging through non-matching items. It needs a
  // composite index (category + equipment_name) created in the Firebase
  // console first — the query fails until that index finishes building, so it
  // was deliberately left client-side rather than risk it close to the
  // defense. The borrow picker's 'Available' filter needs the same treatment
  // (status + equipment_name). Do both in one pass when there is time to
  // verify the indexes.
  String _filter = 'All';
  final _categories = ['All', ...kCategories];

  // Pagination — see ApiService.getEquipmentPage. The header counts come from
  // aggregation queries so they stay true for the whole inventory, not just
  // the pages loaded so far.
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  DocumentSnapshot? _cursor;
  bool _hasMore = true;
  bool _loadingMore = false;
  int _totalItems = 0;
  int _availableItems = 0;
  int _borrowedItems  = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _hasError = false;
      _equipment = [];
      _cursor = null;
      _hasMore = true;
    });
    try {
      // Both start before either is awaited, so they run concurrently.
      final pageFuture   = ApiService.getEquipmentPage(limit: _pageSize);
      final countsFuture = ApiService.getEquipmentCounts();
      final page   = await pageFuture;
      final counts = await countsFuture;
      if (!mounted) return;
      setState(() {
        _equipment = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _totalItems = counts.total;
        _availableItems = counts.available;
        _borrowedItems  = counts.borrowed;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _hasError = true; });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ApiService.getEquipmentPage(
          limit: _pageSize, startAfter: _cursor);
      if (!mounted) return;
      setState(() {
        _equipment = [..._equipment, ...page.items];
        _cursor = page.cursor ?? _cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Keep what is loaded; scrolling again retries.
      setState(() => _loadingMore = false);
    }
  }

  Color _conditionColor(String c) {
    switch (c) {
      case 'Available': return AppTheme.success;
      case 'Borrowed':  return AppTheme.warning;
      default:          return AppTheme.textMid;
    }
  }

  Widget _thumb(Map<String, dynamic> e, Color condColor) => EquipmentThumb(
        bytes: photoThumbOf(e),
        category: e['category'] as String? ?? '',
        color: condColor,
        size: 48,
      );

  // Trailing row of the inventory list: paging spinner, empty-result message,
  // or a quiet end-of-list marker.
  Widget _listFooter(bool isEmpty) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 60),
        child: Column(children: [
          Icon(Icons.inventory_2_outlined, size: 52, color: AppTheme.textLight),
          SizedBox(height: 12),
          Text('No equipment found',
              style: TextStyle(color: AppTheme.textMid, fontSize: 14)),
        ]),
      );
    }
    if (!_hasMore) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Center(
          child: Text('End of inventory',
              style: TextStyle(fontSize: 11, color: AppTheme.textLight)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }

  void _openEdit(Map<String, dynamic> equipment) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditEquipmentSheet(
        equipment: equipment,
        onSaved: _load,
      ),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> equipment) async {
    final id = '${equipment['equipment_id'] ?? ''}';
    final name = equipment['equipment_name'] ?? 'this equipment';
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.delete_forever_rounded, color: AppTheme.danger, size: 44),
        title: const Text('Delete Equipment'),
        content: Text(
            'Permanently remove "$name" from the inventory? This cannot be undone.',
            textAlign: TextAlign.center),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final res = await ApiService.deleteEquipment(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? '"$name" deleted.'
          : (res['message'] ?? 'Delete failed.')),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
    if (res['success'] == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.wifi_off_rounded, size: 52, color: AppTheme.textLight),
            const SizedBox(height: 16),
            const Text('Failed to load inventory',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
            const SizedBox(height: 8),
            const Text('Check your internet connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
            const SizedBox(height: 20),
            ElevatedButton.icon(onPressed: _load,
                icon: const Icon(Icons.refresh_rounded), label: const Text('Try Again')),
          ]),
        ),
      );
    }

    final filtered = _equipment.where((e) {
      final matchCat = _filter == 'All' || e['category'] == _filter;
      final matchSearch = _search.isEmpty ||
          (e['equipment_name'] as String).toLowerCase().contains(_search.toLowerCase()) ||
          (e['qr_code'] as String).toLowerCase().contains(_search.toLowerCase());
      return matchCat && matchSearch;
    }).toList();

    // Counted server-side over the whole collection — the list below is only a
    // page of it, so these cannot be derived from _equipment.
    final totalItems       = _totalItems;
    final availableItems = _availableItems;
    // Counted on its own, not as total − available: that folded Under Repair
    // and For Disposal into a tile labelled "Borrowed" and read 6 when 3
    // things were actually out (QA 2026-09-19, low #6).
    final borrowedItems = _borrowedItems;

    // An active search or category can hide everything loaded so far while
    // matches remain further down the collection; pull more until the list
    // fills or the inventory runs out.
    if (filtered.length < _pageSize && _hasMore && !_loadingMore && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: Column(
        children: [
          // ── Header with summary stats ──
          Container(
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                // Summary row
                Row(
                  children: [
                    _InvStat(label: 'Total Items', value: '$totalItems', icon: Icons.inventory_2_rounded, color: Colors.white),
                    const SizedBox(width: 10),
                    _InvStat(label: 'Available', value: '$availableItems', icon: Icons.check_circle_outline_rounded, color: AppTheme.success),
                    const SizedBox(width: 10),
                    _InvStat(label: 'Borrowed', value: '$borrowedItems', icon: Icons.remove_circle_outline_rounded, color: AppTheme.danger),
                  ],
                ),
                const SizedBox(height: 12),
                // Search bar
                TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search by name or ID...',
                    hintStyle: const TextStyle(color: AppTheme.textLight),
                    prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textLight),
                    filled: true,
                    fillColor: const Color(0x1AFFFFFF),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.accent, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 10),
                // Category filter chips
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final c = _categories[i];
                      final sel = _filter == c;
                      return GestureDetector(
                        onTap: () => setState(() => _filter = c),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: sel ? AppTheme.accent : const Color(0x1AFFFFFF),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(c,
                              style: TextStyle(
                                  color: sel ? AppTheme.primary : AppTheme.textLight,
                                  fontSize: 12,
                                  fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── Equipment list ──
          Expanded(
            child: ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    // One extra row for the paging footer.
                    itemCount: filtered.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      if (i == filtered.length) {
                        return _listFooter(filtered.isEmpty);
                      }
                      final e = filtered[i];
                      final status = e['status'] ?? 'Available';
                      final condColor = _conditionColor(status);

                      return GestureDetector(
                        onTap: () => Navigator.push(context,
                            MaterialPageRoute(
                                builder: (_) => EquipmentDetailScreen(equipment: e))),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border(left: BorderSide(color: condColor, width: 4)),
                          ),
                          child: Row(
                            children: [
                              _thumb(e, condColor),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(e['equipment_name'] as String,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
                                    const SizedBox(height: 2),
                                    Text('${e['qr_code']}  ·  ${e['category']}',
                                        style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                                    if (ApiService.asDate(e['created_at']) case final added?) ...[
                                      const SizedBox(height: 2),
                                      Text('Added ${formatDate(added)}',
                                          style: const TextStyle(fontSize: 11, color: AppTheme.textLight)),
                                    ],
                                    const SizedBox(height: 8),
                                    Row(children: [
                                      Expanded(child: StatusBadge(label: status, color: condColor)),
                                      const SizedBox(width: 12),
                                      StatusBadge(label: e['category'] as String, color: AppTheme.primary),
                                    ]),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              if (Session.canManage)
                                PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'edit') _openEdit(e);
                                    if (v == 'delete') _confirmDelete(e);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Row(children: [
                                        Icon(Icons.edit_outlined, size: 18, color: AppTheme.textMid),
                                        SizedBox(width: 8),
                                        Text('Edit Details'),
                                      ]),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Row(children: [
                                        Icon(Icons.delete_outline_rounded, size: 18, color: AppTheme.danger),
                                        SizedBox(width: 8),
                                        Text('Delete', style: TextStyle(color: AppTheme.danger)),
                                      ]),
                                    ),
                                  ],
                                  child: const Icon(Icons.more_vert_rounded, color: AppTheme.textLight),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: !Session.canManage ? null : FloatingActionButton.extended(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          final result = await Navigator.push<Map<String, dynamic>>(
              context,
              MaterialPageRoute(builder: (_) => const EquipmentRegistrationScreen()));
          if (result != null) {
            _load();
            if (!mounted) return;
            final name  = result['equipment_name'] ?? 'Equipment';
            final count = result['count'] as int? ?? 1;
            messenger.showSnackBar(
              SnackBar(
                content: Text(count > 1
                    ? '$count units of $name registered successfully!'
                    : '$name registered successfully!'),
                backgroundColor: AppTheme.success,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            );
          }
        },
        backgroundColor: AppTheme.accent,
        foregroundColor: AppTheme.primary,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Equipment', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}

// ── Inventory stat mini-card ──
// ─── Edit Equipment Bottom Sheet ──────────────────────────────────────────────

class _EditEquipmentSheet extends StatefulWidget {
  final Map<String, dynamic> equipment;
  final VoidCallback onSaved;
  const _EditEquipmentSheet({required this.equipment, required this.onSaved});
  @override
  State<_EditEquipmentSheet> createState() => _EditEquipmentSheetState();
}

class _EditEquipmentSheetState extends State<_EditEquipmentSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _brandCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _serialCtrl;
  late final TextEditingController _iinCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _descCtrl;
  DateTime? _dateAcquired;

  late String? _selectedCategory;
  late String _selectedStatus;
  late List<String> _selectedCourses;
  XFile? _pickedImage;
  bool _saving = false;

  final _imagePicker = ImagePicker();
  final _statuses    = kStatuses;
  final _categories  = kCategories;

  @override
  void initState() {
    super.initState();
    final e = widget.equipment;
    _nameCtrl     = TextEditingController(text: e['equipment_name'] as String? ?? '');
    _brandCtrl    = TextEditingController(text: e['brand']          as String? ?? '');
    _modelCtrl    = TextEditingController(text: e['model']          as String? ?? '');
    _serialCtrl   = TextEditingController(text: e['serial_number']  as String? ?? '');
    _iinCtrl      = TextEditingController(text: '${e['iin'] ?? ''}');
    _locationCtrl = TextEditingController(text: e['location']       as String? ?? '');
    _descCtrl     = TextEditingController(text: e['description']    as String? ?? '');
    _dateAcquired = ApiService.asDate(e['date_acquired']);
    _selectedCategory = e['category'] as String?;
    _selectedStatus   = (e['status'] as String?) ?? 'Available';
    _selectedCourses  = List<String>.from((e['courses'] as List?) ?? []);
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _brandCtrl.dispose(); _modelCtrl.dispose();
    _serialCtrl.dispose(); _iinCtrl.dispose(); _locationCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
        source: source, imageQuality: 80, maxWidth: 1200);
    if (picked != null) setState(() => _pickedImage = picked);
  }

  // "Added to the inventory on Oct 2, 2026 by Ramoel Bello". Records made
  // before 2026-10-05 carry the date but not the name.
  String _addedLine(DateTime added) {
    final by = '${widget.equipment['created_by_name'] ?? ''}'.trim();
    return 'Added to the inventory on ${formatDate(added)}'
        '${by.isEmpty ? '' : ' by $by'}';
  }

  Future<void> _save() async {
    final equipmentId = '${widget.equipment['equipment_id'] ?? ''}';
    if (equipmentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Cannot edit demo equipment.'),
          backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _saving = true);
    try {
      String? photoError;
      if (_pickedImage != null) {
        final bytes = await _pickedImage!.readAsBytes();
        final saved = await ApiService.saveEquipmentPhoto(equipmentId, bytes);
        photoError = saved.error;
      }
      final res = await ApiService.updateEquipment(equipmentId, {
        'equipment_name': _nameCtrl.text.trim(),
        'category':       _selectedCategory ?? widget.equipment['category'],
        'status':         _selectedStatus,
        'location':       _locationCtrl.text.trim(),
        'brand':          _brandCtrl.text.trim(),
        'model':          _modelCtrl.text.trim(),
        'serial_number':  _serialCtrl.text.trim(),
        'iin':            _iinCtrl.text.trim(),
        // null clears it, for a date entered by mistake.
        'date_acquired':  _dateAcquired,
        'description':    _descCtrl.text.trim(),
        'courses':        _selectedCourses,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        widget.onSaved();
        messenger.showSnackBar(photoError == null
            ? const SnackBar(
                content: Text('Equipment updated successfully.'),
                backgroundColor: AppTheme.success)
            : SnackBar(
                content: Text('Equipment updated, but the photo did not '
                    'upload: $photoError'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 6)));
      } else {
        setState(() => _saving = false);
        // A snackbar shown from inside this bottom sheet renders BEHIND it, so
        // a refused save looked like nothing happening at all. A dialog sits
        // above the sheet. (Found while verifying the on-loan refusal below on
        // the emulator, 2026-09-21.)
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: const Icon(Icons.error_outline_rounded,
                color: AppTheme.danger, size: 48),
            title: const Text('Update Failed'),
            content: Text(res['message'] ?? 'Update failed.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13)),
            actions: [
              ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'))
            ],
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Cannot connect to server.'),
            backgroundColor: AppTheme.danger));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.97,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: AppTheme.divider, borderRadius: BorderRadius.circular(2)),
          ),
          // Title row
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
            child: Row(children: [
              const Expanded(
                child: Text('Edit Equipment',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                        color: AppTheme.textDark)),
              ),
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ]),
          ),
          const Divider(height: 1),
          // Scrollable form
          Expanded(
            child: ListView(controller: scroll, padding: const EdgeInsets.all(20),
              children: [
                // When, and by whom, this record was added (read-only).
                if (ApiService.asDate(widget.equipment['created_at']) case final added?) ...[
                  Row(children: [
                    const Icon(Icons.history_rounded, size: 16, color: AppTheme.textMid),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_addedLine(added),
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                    ),
                  ]),
                  const SizedBox(height: 16),
                ],

                // Photo picker
                FieldLabel('Equipment Photo'),
                const SizedBox(height: 8),
                if (_pickedImage != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(File(_pickedImage!.path),
                          height: 160, width: double.infinity, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _pickedImage = null),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                              color: AppTheme.danger, shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ])
                else if (photoThumbOf(widget.equipment) != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      photoThumbOf(widget.equipment)!,
                      height: 160, width: double.infinity, fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                    ),
                  )
                else
                  Container(
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.image_outlined, size: 32, color: AppTheme.textLight),
                        SizedBox(height: 4),
                        Text('No photo', style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
                      ]),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Take Photo'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('From Gallery'),
                    ),
                  ),
                ]),
                const SizedBox(height: 20),

                // Status + Category
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    FieldLabel('Status *'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.divider)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedStatus,
                          items: _statuses.map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(s, style: const TextStyle(fontSize: 13)))).toList(),
                          onChanged: (v) => setState(() => _selectedStatus = v!),
                        ),
                      ),
                    ),
                  ])),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    FieldLabel('Category *'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.divider)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedCategory,
                          hint: const Text('Select', style: TextStyle(fontSize: 13)),
                          items: _categories.map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
                          onChanged: (v) => setState(() => _selectedCategory = v),
                        ),
                      ),
                    ),
                  ])),
                ]),
                const SizedBox(height: 16),

                FieldLabel('Equipment Name *'),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Digital Multimeter',
                    prefixIcon: Icon(Icons.science_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('Storage Location'),
                const SizedBox(height: 8),
                TextField(
                  controller: _locationCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Cabinet A, Shelf 2',
                    prefixIcon: Icon(Icons.location_on_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    FieldLabel('Brand'),
                    const SizedBox(height: 8),
                    TextField(controller: _brandCtrl,
                        decoration: const InputDecoration(hintText: 'e.g. Fluke')),
                  ])),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    FieldLabel('Model'),
                    const SizedBox(height: 8),
                    TextField(controller: _modelCtrl,
                        decoration: const InputDecoration(hintText: 'e.g. 117')),
                  ])),
                ]),
                const SizedBox(height: 16),

                FieldLabel('Serial Number'),
                const SizedBox(height: 8),
                TextField(
                  controller: _serialCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. SN-20241105-001',
                    prefixIcon: Icon(Icons.tag_rounded, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('IIN (Item Identification No.)'),
                const SizedBox(height: 8),
                TextField(
                  controller: _iinCtrl,
                  decoration: const InputDecoration(
                    hintText: "From the custodian's inventory list",
                    prefixIcon: Icon(Icons.inventory_2_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('Date Acquired'),
                const SizedBox(height: 8),
                DateField(
                  value: _dateAcquired,
                  onChanged: (d) => setState(() => _dateAcquired = d),
                ),
                const SizedBox(height: 16),

                FieldLabel('Description'),
                const SizedBox(height: 8),
                TextField(
                  controller: _descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Brief description of the equipment...',
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('Available to Courses'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8, runSpacing: 6,
                  children: kCourses.map((c) {
                    final sel = _selectedCourses.contains(c);
                    return FilterChip(
                      label: Text(courseLabel(c), style: TextStyle(
                          fontSize: 12, color: sel ? Colors.white : AppTheme.textDark)),
                      selected: sel,
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.surface,
                      checkmarkColor: Colors.white,
                      side: BorderSide(color: sel ? AppTheme.primary : AppTheme.divider),
                      onSelected: (v) => setState(() {
                        if (v) { _selectedCourses.add(c); } else { _selectedCourses.remove(c); }
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save Changes'),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Inventory stat mini-card ──
class _InvStat extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _InvStat({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: TextStyle(
                          color: color, fontSize: 15, fontWeight: FontWeight.bold)),
                  Text(label,
                      style: const TextStyle(
                          color: AppTheme.textLight, fontSize: 9),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

