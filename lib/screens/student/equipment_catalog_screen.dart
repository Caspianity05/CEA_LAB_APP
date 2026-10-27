// -----------------------------------------------------------------------------
// LabTrack - student: equipment catalog screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
//
// 1.0.19 (2026-10-15): the catalog lists item TYPES ("Sieve (USA Standard
// Testing System) — 197 in the lab"), not every unit, from the item-type list:
// one read for the whole catalog, then search, categories and programs filter
// it on the phone. Paging through 1,067 units read up to all of them for one
// search. A type's free units are counted when the student opens it.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'equipment_detail_screen.dart';

// ─── Equipment Catalog Screen ─────────────────────────────────────────────────

class EquipmentCatalogScreen extends StatefulWidget {
  const EquipmentCatalogScreen({super.key});
  @override
  State<EquipmentCatalogScreen> createState() => _EquipmentCatalogScreenState();
}

class _EquipmentCatalogScreenState extends State<EquipmentCatalogScreen> {
  String _search = '';
  // Keeps the typed text on screen when a reload swaps the body for a
  // spinner; otherwise the box came back empty while _search still filtered
  // (same fault as staff Inventory, 2026-10-05).
  final _searchCtrl = TextEditingController();
  final Set<String> _selectedCategories = {};
  final _categories = kCategories;
  bool _dropdownOpen = false;
  bool _showAllCourses = false;
  bool _loading = true;
  bool _hasError = false;
  // The item types with a unit in service. Until staff build the type list
  // the old list is used (`_counted`): its numbers are units free right now
  // rather than units in the lab.
  List<Map<String, dynamic>> _types = [];
  bool _counted = false;
  // The type being opened (a spinner on its card).
  String _opening = '';

  @override
  void initState() {
    super.initState();
    _loadEquipment();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Pull-to-refresh asks for a fresh list rather than the one kept for a few
  // minutes.
  Future<void> _loadEquipment({bool refresh = false}) async {
    setState(() {
      _loading = _types.isEmpty;
      _hasError = false;
    });
    try {
      final res = await ApiService.getBorrowableTypes(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _types = res.types;
        _counted = res.counted;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _hasError = _types.isEmpty; });
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message), behavior: SnackBarBehavior.floating));
  }

  // A type's page: its free units counted now (one read) and one unit read to
  // show its details and photo (one more).
  Future<void> _open(Map<String, dynamic> t) async {
    if (_opening.isNotEmpty) return;
    final name = '${t['name']}';
    setState(() => _opening = name);
    try {
      final sampleF = ApiService.sampleUnitOf(name);
      final freeF = _counted
          ? Future.value(t['available'] as int? ?? 0)
          : ApiService.availableNow(name);
      final sample = await sampleF;
      final free = await freeF;
      if (!mounted) return;
      if (sample == null) {
        _snack('$name is no longer in the inventory.');
        _loadEquipment(refresh: true);
        return;
      }
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => EquipmentDetailScreen(
                  equipment: sample,
                  typeName: name,
                  available: free,
                  inLab: t['in_service'] as int?)));
    } catch (_) {
      if (mounted) _snack('Could not open $name. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _opening = '');
    }
  }

  String get _filterLabel {
    if (_selectedCategories.isEmpty) return 'All Categories';
    if (_selectedCategories.length == 1) return _selectedCategories.first;
    return '${_selectedCategories.length} categories';
  }

  void _toggleCategory(String cat) {
    setState(() {
      if (_selectedCategories.contains(cat)) _selectedCategories.remove(cat);
      else _selectedCategories.add(cat);
    });
  }

  void _clearFilters() => setState(() => _selectedCategories.clear());

  // Trailing row of the catalog list: an empty-result message, or a quiet
  // end-of-list marker.
  Widget _listFooter(bool isEmpty) {
    if (isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Column(children: [
          Icon(Icons.search_off_rounded, size: 44, color: AppTheme.textLight),
          SizedBox(height: 10),
          Text('No equipment matches your filters',
              style: TextStyle(color: AppTheme.textMid)),
        ]),
      );
    }
    return const Padding(
      padding: EdgeInsets.only(top: 16, bottom: 4),
      child: Center(
        child: Text('End of catalog',
            style: TextStyle(fontSize: 11, color: AppTheme.textLight)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final studentCourse = Session.course;
    // The whole list is in hand, so every filter is exact (they used to run
    // over the pages loaded so far).
    final q = _search.trim().toLowerCase();
    final filtered = _types.where((t) {
      final matchCat = _selectedCategories.isEmpty ||
          _selectedCategories.contains(t['category']);
      final matchSearch = q.isEmpty || '${t['name']}'.toLowerCase().contains(q);
      final itemCourses = (t['courses'] as List?)?.cast<String>() ?? [];
      final matchCourse = _showAllCourses ||
          studentCourse.isEmpty ||
          itemCourses.isEmpty ||
          itemCourses.contains(studentCourse);
      return matchCat && matchSearch && matchCourse;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Equipment Catalog')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _hasError
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.wifi_off_rounded, size: 52, color: AppTheme.textLight),
                      const SizedBox(height: 16),
                      const Text('Failed to load equipment',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      const Text('Check your internet connection and try again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _loadEquipment,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                    ]),
                  ),
                )
          : Column(
        children: [
          // Search + Filter
          Container(
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Search bar
                TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search equipment...',
                    hintStyle: const TextStyle(color: AppTheme.textLight),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: AppTheme.textLight),
                    filled: true,
                    fillColor: const Color(0x1AFFFFFF),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppTheme.accent, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 10),
                // Multi-select dropdown button
                GestureDetector(
                  onTap: () => setState(() => _dropdownOpen = !_dropdownOpen),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _selectedCategories.isNotEmpty
                              ? AppTheme.accent
                              : const Color(0x33FFFFFF),
                          width: _selectedCategories.isNotEmpty ? 1.5 : 1),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.filter_list_rounded,
                            color: AppTheme.textLight, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _filterLabel,
                            style: TextStyle(
                              color: _selectedCategories.isNotEmpty
                                  ? AppTheme.accent
                                  : AppTheme.textLight,
                              fontSize: 13,
                              fontWeight: _selectedCategories.isNotEmpty
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        // Active filter chips inline
                        if (_selectedCategories.isNotEmpty) ...[
                          GestureDetector(
                            onTap: _clearFilters,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: const Color(0x33F5A623),
                                  borderRadius: BorderRadius.circular(10)),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('Clear',
                                      style: TextStyle(
                                          color: AppTheme.accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold)),
                                  SizedBox(width: 2),
                                  Icon(Icons.close_rounded,
                                      size: 12, color: AppTheme.accent),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        AnimatedRotation(
                          turns: _dropdownOpen ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(Icons.keyboard_arrow_down_rounded,
                              color: AppTheme.textLight, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Dropdown panel (shown below header, above list)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            height: _dropdownOpen ? (_categories.length * 52.0) : 0,
            child: Container(
              color: Colors.white,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  children: [
                    // "Select All" / "Clear All" row
                    InkWell(
                      onTap: () {
                        setState(() {
                          if (_selectedCategories.length ==
                              _categories.length) {
                            _selectedCategories.clear();
                          } else {
                            _selectedCategories
                                .addAll(_categories);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: _selectedCategories.length ==
                                        _categories.length
                                    ? AppTheme.primary
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: _selectedCategories.length ==
                                            _categories.length
                                        ? AppTheme.primary
                                        : AppTheme.textLight),
                              ),
                              child: _selectedCategories.length ==
                                      _categories.length
                                  ? const Icon(Icons.check_rounded,
                                      color: Colors.white, size: 14)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            const Text('Select All',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.textDark)),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: AppTheme.divider),
                    ..._categories.map((cat) {
                      final checked =
                          _selectedCategories.contains(cat);
                      return InkWell(
                        onTap: () => _toggleCategory(cat),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: checked
                                      ? AppTheme.primary
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: checked
                                          ? AppTheme.primary
                                          : AppTheme.textLight),
                                ),
                                child: checked
                                    ? const Icon(Icons.check_rounded,
                                        color: Colors.white, size: 14)
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Text(cat,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: checked
                                          ? AppTheme.primary
                                          : AppTheme.textDark,
                                      fontWeight: checked
                                          ? FontWeight.w600
                                          : FontWeight.normal)),
                              const Spacer(),
                              // Item count badge per category
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: checked
                                      ? const Color(0x1A1B3A8C)
                                      : AppTheme.surface,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${_types.where((t) => t['category'] == cat).length}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: checked
                                          ? AppTheme.primary
                                          : AppTheme.textMid,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          // Active filter tags row
          if (_selectedCategories.isNotEmpty)
            Container(
              color: AppTheme.surface,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('Filtered: ',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMid,
                          fontWeight: FontWeight.w600)),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _selectedCategories.map((cat) {
                          return Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0x1A1B3A8C),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color:
                                      const Color(0x4D1B3A8C)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(cat,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.primary,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () => _toggleCategory(cat),
                                  child: const Icon(Icons.close_rounded,
                                      size: 12, color: AppTheme.primary),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (Session.course.isNotEmpty)
            Container(
              color: const Color(0xFFF0F4FF),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.school_outlined, size: 14, color: AppTheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    _showAllCourses
                        ? 'Showing all programs'
                        : 'Showing equipment for ${courseLabel(Session.course)}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _showAllCourses = !_showAllCourses),
                    child: Text(
                      _showAllCourses ? 'My program only' : 'Show all',
                      style: const TextStyle(fontSize: 12, color: AppTheme.accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadEquipment(refresh: true),
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                cacheExtent: 500,
                // One extra row for the footer.
                itemCount: filtered.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  if (i == filtered.length) return _listFooter(filtered.isEmpty);
                  final t = filtered[i];
                  final name = '${t['name']}';
                  final category = '${t['category'] ?? ''}';
                  final location = '${t['location'] ?? ''}';
                  final count = t['in_service'] as int? ?? 0;
                  final courses = (t['courses'] as List?)?.cast<String>() ?? const <String>[];
                  final opening = _opening == name;
                  return GestureDetector(
                    onTap: () => _open(t),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: const Border(
                          left: BorderSide(color: AppTheme.success, width: 4),
                        ),
                      ),
                      child: Row(
                        children: [
                          EquipmentThumb(
                            bytes: photoThumbOf(t),
                            category: category,
                            color: AppTheme.success,
                            size: 50,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: AppTheme.textDark)),
                                const SizedBox(height: 2),
                                Text(
                                    joinParts([
                                      _counted ? '$count available' : '$count in the lab',
                                      category,
                                    ]),
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textMid)),
                                if (location.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  StatusBadge(label: location, color: AppTheme.textMid),
                                ],
                                if (courses.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Row(children: [
                                    const Icon(Icons.school_outlined,
                                        size: 12, color: AppTheme.primary),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        'For: ${courses.map(courseLabel).join(', ')}',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.primary,
                                            fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ]),
                                ],
                              ],
                            ),
                          ),
                          if (opening)
                            const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                          else
                            const Icon(Icons.arrow_forward_ios_rounded,
                                size: 16, color: AppTheme.accent),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

