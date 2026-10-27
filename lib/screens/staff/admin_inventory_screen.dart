// -----------------------------------------------------------------------------
// LabTrack - staff: admin inventory screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
//
// 1.0.19 (2026-10-15): with the item-type list built, a search or a category
// reads only the units of the matching types (a QR code, only the matching
// codes) instead of paging through all 1,067 units until enough matched. The
// plain list still pages 20 at a time. Managers can rebuild the type list here.
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/file_download.dart';
import '../../services/qr_labels.dart';
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
  // 1.0.19: with the item-type list the category goes through the matching
  // types (see _startFind), so the note below only applies before it exists.
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

  // The item-type list (1.0.19); null until a manager builds it.
  List<Map<String, dynamic>>? _types;
  // The filtered view: types still to load, the units found so far, and the
  // search + category they belong to (a slower answer to an older search is
  // dropped).
  List<String> _queue = [];
  List<Map<String, dynamic>> _found = [];
  bool _finding = false;
  String _foundKey = '';
  Timer? _debounce;
  bool _rebuilding = false;

  bool get _filtering => _search.trim().isNotEmpty || _filter != 'All';
  bool get _byType => _types != null && _filtering;
  String get _findKey => '$_filter|${_search.trim().toLowerCase()}';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      if (_byType) {
        _findMore();
      } else {
        _loadMore();
      }
    }
  }

  // The type names the search and category point to, in name order.
  List<String> _matchingTypes() => ApiService.typesMatching([
        for (final t in _types ?? const <Map<String, dynamic>>[])
          if (_filter == 'All' || t['category'] == _filter) '${t['name']}',
      ], _search);

  void _scheduleFind() {
    _debounce?.cancel();
    if (!_byType) return;
    _debounce = Timer(const Duration(milliseconds: 350), _startFind);
  }

  // A new search or category: the matching QR codes, or the units of the
  // matching types, a screenful at a time.
  Future<void> _startFind() async {
    if (!_byType) return;
    final key = _findKey;
    final q = _search.trim();
    setState(() { _foundKey = key; _found = []; _queue = []; _finding = true; });
    try {
      if (q.isNotEmpty && ApiService.looksLikeQrCode(q)) {
        final units = await ApiService.unitsByQrCode(q);
        if (!mounted || _foundKey != key) return;
        setState(() {
          _found = units.where(_matches).toList();
          _finding = false;
        });
        return;
      }
      _queue = _matchingTypes();
      await _findMore(key);
    } catch (_) {
      if (mounted && _foundKey == key) setState(() => _finding = false);
    }
  }

  // The units of the next matching types: about a screenful, by the counts in
  // the type list, at most 30 types a query.
  Future<void> _findMore([String? key]) async {
    final k = key ?? _foundKey;
    if (key == null && (_finding || !_byType)) return;
    if (_queue.isEmpty) {
      if (mounted) setState(() => _finding = false);
      return;
    }
    final units = {for (final t in _types!) '${t['name']}': t['units'] as int? ?? 1};
    final next = <String>[];
    var expected = 0;
    while (_queue.isNotEmpty && next.length < 30 && expected < _pageSize) {
      final name = _queue.removeAt(0);
      next.add(name);
      expected += units[name] ?? 1;
    }
    setState(() => _finding = true);
    try {
      final loaded = await ApiService.unitsOfTypes(next);
      if (!mounted || _foundKey != k) return;
      setState(() {
        _found = [..._found, ...loaded.where(_matches)];
        _finding = false;
      });
    } catch (_) {
      if (!mounted || _foundKey != k) return;
      // Put them back so scrolling again retries.
      setState(() { _queue = [...next, ..._queue]; _finding = false; });
    }
  }

  // Rebuilds the item-type list from every record (1.0.19). Needed once to
  // switch the lists over, after an import, or if a count ever looks wrong.
  Future<void> _rebuild() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.sync_rounded, color: AppTheme.primary, size: 40),
        title: const Text('Rebuild the item list?'),
        content: Text(
            'Reads all $_totalItems equipment records once to rebuild the list of '
            'item types that students borrow from, and gives each record its type.\n\n'
            'Do this the first time, after importing equipment, or if a count looks wrong.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rebuild')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _rebuilding = true);
    final res = await ApiService.rebuildItemTypes();
    if (!mounted) return;
    setState(() => _rebuilding = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? 'Item list rebuilt: ${res['types']} types from ${res['units']} records'
              '${(res['backfilled'] as int? ?? 0) > 0 ? ' (${res['backfilled']} records given their type)' : ''}.'
          : 'Could not rebuild the item list: ${res['message'] ?? 'unknown error'}'),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
    ));
    if (res['success'] == true) _load();
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
      // All start before any is awaited, so they run concurrently. The type
      // list is one read, or none while it is cached.
      final pageFuture   = ApiService.getEquipmentPage(limit: _pageSize);
      final countsFuture = ApiService.getEquipmentCounts();
      final typesFuture  = ApiService.getItemTypes()
          .then<List<Map<String, dynamic>>?>((t) => t, onError: (_) => null);
      final page   = await pageFuture;
      final counts = await countsFuture;
      final types  = await typesFuture;
      if (!mounted) return;
      setState(() {
        _equipment = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _totalItems = counts.total;
        _availableItems = counts.available;
        _borrowedItems  = counts.borrowed;
        _types = types;
        _loading = false;
      });
      if (_byType) _startFind();
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

  Widget _categoryChips() => SizedBox(
        height: 32,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _categories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final c = _categories[i];
            final sel = _filter == c;
            return GestureDetector(
              onTap: () {
                setState(() => _filter = c);
                _scheduleFind();
              },
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
      );

  // ── QR labels (web portal, 2026-10-06) ──
  // A PDF of label sheets for every item the category and search show. The
  // list on screen is paged, so the matching units are read in full, only when
  // staff ask: with the type list (1.0.19) just those of the matching types or
  // codes; without it, or with no filter, the whole inventory.
  bool _makingLabels = false;

  bool _matches(Map<String, dynamic> e) {
    final q = _search.toLowerCase();
    return (_filter == 'All' || e['category'] == _filter) &&
        (q.isEmpty ||
            '${e['equipment_name'] ?? ''}'.toLowerCase().contains(q) ||
            '${e['qr_code'] ?? ''}'.toLowerCase().contains(q));
  }

  Future<void> _qrLabels() async {
    setState(() => _makingLabels = true);
    try {
      final q = _search.trim();
      final source = !_byType
          ? await ApiService.getAllEquipment()
          : q.isNotEmpty && ApiService.looksLikeQrCode(q)
              ? await ApiService.unitsByQrCode(q)
              : await ApiService.unitsOfTypes(_matchingTypes());
      final items = source.where(_matches).toList();
      if (!mounted) return;
      if (items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No items match the filters.'),
            behavior: SnackBarBehavior.floating));
        return;
      }
      // Only items with a QR code get a label (QrLabels.withCode); the rest
      // are named, so the count matches the PDF (2026-10-07).
      final labelled = QrLabels.withCode(items);
      final noCode = [
        for (final e in items)
          if (!labelled.contains(e)) '${e['equipment_name'] ?? 'Unnamed'}',
      ];
      if (labelled.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('None of these items has a QR code, so there is nothing to print.'),
            behavior: SnackBarBehavior.floating));
        return;
      }
      final which = [
        if (_filter != 'All') _filter,
        if (_search.isNotEmpty) 'matching "$_search"',
      ].join(', ');
      final pages = QrLabels.pages(labelled.length);
      final leftOut = noCode.isEmpty
          ? ''
          : '\n\n${noCode.length == 1 ? '1 item has' : '${noCode.length} items have'} '
              'no QR code and ${noCode.length == 1 ? 'is' : 'are'} left out: '
              '${noCode.take(3).join(', ')}'
              '${noCode.length > 3 ? ' and ${noCode.length - 3} more' : ''}.';
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.qr_code_2_rounded, color: AppTheme.primary, size: 40),
          title: const Text('QR labels'),
          content: Text(
              'A PDF of ${labelled.length} labels${which.isEmpty ? '' : ' ($which)'}: '
              '${QrLabels.perPage} per A4 sheet, $pages ${pages == 1 ? 'sheet' : 'sheets'}.'
              '$leftOut\n\n'
              'Print at 100% ("Actual size"), cut along the grey lines, and stick '
              'each label on its unit.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('Download PDF')),
          ],
        ),
      );
      if (go != true || !mounted) return;
      final bytes = await QrLabels.build(labelled);
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final ok = downloadBytes(
          'labtrack-qr-labels-${now.year}-${two(now.month)}-${two(now.day)}.pdf', bytes,
          mimeType: 'application/pdf');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Downloaded ${labelled.length} labels.'
            : 'Labels can be downloaded from the web portal.'),
        backgroundColor: ok ? AppTheme.success : AppTheme.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not make the labels. Try again.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _makingLabels = false);
    }
  }

  Color _conditionColor(String c) {
    switch (c) {
      case 'Available': return AppTheme.success;
      case 'Borrowed':  return AppTheme.warning;
      case 'Reserved':  return AppTheme.accent;
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
    if (_byType ? _finding : _loadingMore) {
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
    if (!(_byType ? _queue.isNotEmpty : _hasMore)) {
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

  // One equipment card: a list row on a phone, one cell of a grid row on a
  // wide window.
  Widget _itemCard(Map<String, dynamic> e) {
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
                  Text(joinParts([e['qr_code'], e['category']], separator: '  ·  '),
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                  if (ApiService.asDate(e['created_at']) case final added?) ...[
                    const SizedBox(height: 2),
                    Text('Added ${formatDate(added)}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textLight)),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
                    // Stretched across a browser-wide card the
                    // badge read as a progress bar, so the web
                    // keeps it to its text.
                    if (kIsWeb)
                      Flexible(child: StatusBadge(label: status, color: condColor))
                    else
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

    // With the type list, a search or category shows the units found for it
    // (1.0.19); otherwise the pages loaded so far, filtered.
    final shown = _byType ? _found : filtered;

    if (_byType) {
      // Fill the screen from the next matching types.
      if (_found.length < _pageSize && _queue.isNotEmpty && !_finding && !_loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _findMore());
      }
    } else if (filtered.length < _pageSize && _hasMore && !_loadingMore && !_loading) {
      // An active search or category can hide everything loaded so far while
      // matches remain further down the collection; pull more until the list
      // fills or the inventory runs out. (Only before the type list exists.)
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }
    // Four cards a row on a wide window can leave a page too short to scroll,
    // and then no scroll ever asks for the next one; check once laid out.
    if (_hasMore && !_loadingMore && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
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
                  onChanged: (v) {
                    setState(() => _search = v);
                    _scheduleFind();
                  },
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
                // Category filter chips, and on the web portal the QR-label
                // sheets for what the filters show (2026-10-06).
                Row(children: [
                  Expanded(child: _categoryChips()),
                  if (kIsWeb) ...[
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _makingLabels ? null : _qrLabels,
                      icon: _makingLabels
                          ? const SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 18),
                      label: const Text('QR labels',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ],
                  // Rebuild the item-type list (1.0.19), managers only.
                  if (Session.canManage)
                    IconButton(
                      tooltip: 'Rebuild item list',
                      onPressed: _rebuilding ? null : _rebuild,
                      icon: _rebuilding
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.sync_rounded, color: Colors.white, size: 20),
                    ),
                ]),
              ],
            ),
          ),

          // Until the item-type list is built, students' lists read every
          // unit (1.0.19); say so to the people who can build it.
          if (_types == null && Session.canManage)
            Container(
              width: double.infinity,
              color: const Color(0x1AF5A623),
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded, color: AppTheme.warning, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                      "The item list isn't set up yet, so the student catalog and borrow "
                      'form read every unit. Build it once to make them fast and cheap.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textDark)),
                ),
                TextButton(
                    onPressed: _rebuilding ? null : _rebuild,
                    child: const Text('Build now')),
              ]),
            ),

          // ── Equipment list ──
          // Rows of cards on a wide window, one card per row on a phone.
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final cols = gridColumns(box.maxWidth - 32, minWidth: 400);
              final rows = (shown.length + cols - 1) ~/ cols;
              return ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                // One extra row for the paging footer.
                itemCount: rows + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  if (i == rows) return _listFooter(shown.isEmpty);
                  return gridRow(i, cols, shown.length, (j) => _itemCard(shown[j]));
                },
              );
            }),
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
  // The picked photo's bytes: Image.memory works on the phone and on the web
  // (Image.file has no file system in a browser).
  Uint8List? _pickedBytes;
  bool _saving = false;

  final _imagePicker = ImagePicker();
  final _statuses    = kStatuses;
  final _categories  = kCategories;

  // Out on a loan right now (see the Status picker).
  bool get _onLoan => widget.equipment['status'] == 'Borrowed';
  // Held for a student's pending request (2026-10-06).
  bool get _reserved => widget.equipment['status'] == 'Reserved';

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
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (mounted) setState(() => _pickedBytes = bytes);
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
      final bytes = _pickedBytes;
      if (bytes != null) {
        final saved = await ApiService.saveEquipmentPhoto(equipmentId, bytes);
        photoError = saved.error;
      }
      final res = await ApiService.updateEquipment(equipmentId, {
        'equipment_name': _nameCtrl.text.trim(),
        'category':       _selectedCategory ?? widget.equipment['category'],
        // Only a status staff changed here. Saving other details used to
        // write back the status the form opened with, so an item approved,
        // returned or reserved meanwhile went back to the old one.
        if (_selectedStatus != (widget.equipment['status'] ?? 'Available'))
          'status':       _selectedStatus,
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
                if (_pickedBytes != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(_pickedBytes!,
                          height: 160, width: double.infinity, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _pickedBytes = null),
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
                  // A computer opens the same file picker for both, so the
                  // web shows the one button.
                  if (!kIsWeb) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('Take Photo'),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(kIsWeb ? 'Choose Photo' : 'From Gallery'),
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
                      // "Borrowed" belongs to a loan: only an approval sets it
                      // and only a return clears it. Picking it here left an
                      // item out with no loan to return, and picking anything
                      // else for an item on loan orphaned the loan (QA
                      // 2026-10-06). So it is never offered, and an item on
                      // loan keeps it until it comes back.
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedStatus,
                          // "Reserved" works the same way: a request sets it
                          // and deciding or cancelling the request clears it.
                          // It is listed only for the item that has it.
                          items: (_onLoan
                                  ? const ['Borrowed']
                                  : [
                                      if (_reserved) 'Reserved',
                                      ..._statuses.where((s) => s != 'Borrowed'),
                                    ])
                              .map((s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(s, style: const TextStyle(fontSize: 13))))
                              .toList(),
                          onChanged: _onLoan
                              ? null
                              : (v) => setState(() => _selectedStatus = v!),
                        ),
                      ),
                    ),
                    if (_onLoan)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('On loan. Its return will change this.',
                            style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
                      ),
                    if (_reserved)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('Held for a pending request. Approving or '
                            'rejecting it will change this.',
                            style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
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

