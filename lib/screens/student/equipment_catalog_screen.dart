// -----------------------------------------------------------------------------
// LabTrack - student: equipment catalog screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
  List<dynamic> _items = [];

  // Pagination — the catalog loads a screenful at a time rather than the whole
  // equipment collection (see ApiService.getEquipmentPage).
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  DocumentSnapshot? _cursor;
  bool _hasMore = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadEquipment();
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

  // First page / pull-to-refresh — resets the cursor.
  Future<void> _loadEquipment() async {
    setState(() {
      _loading = true;
      _hasError = false;
      _items = [];
      _cursor = null;
      _hasMore = true;
    });
    try {
      final page = await ApiService.getEquipmentPage(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
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
        _items = [..._items, ...page.items];
        _cursor = page.cursor ?? _cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Keep what is already loaded; the next scroll retries.
      setState(() => _loadingMore = false);
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

  // Trailing row of the catalog list: paging spinner, an empty-result message,
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
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Column(children: [
          Icon(Icons.search_off_rounded, size: 44, color: AppTheme.textLight),
          SizedBox(height: 10),
          Text('No equipment matches your filters',
              style: TextStyle(color: AppTheme.textMid)),
        ]),
      );
    }
    if (!_hasMore) {
      return const Padding(
        padding: EdgeInsets.only(top: 16, bottom: 4),
        child: Center(
          child: Text('End of catalog',
              style: TextStyle(fontSize: 11, color: AppTheme.textLight)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }

  @override
  Widget build(BuildContext context) {
    final studentCourse = Session.course;
    final filtered = _items.where((e) {
      final matchCat = _selectedCategories.isEmpty ||
          _selectedCategories.contains(e['category']);
      final matchSearch = _search.isEmpty ||
          (e['equipment_name'] as String).toLowerCase().contains(_search.toLowerCase());
      final itemCourses = (e['courses'] as List?)?.cast<String>() ?? [];
      final matchCourse = _showAllCourses ||
          studentCourse.isEmpty ||
          itemCourses.isEmpty ||
          itemCourses.contains(studentCourse);
      return matchCat && matchSearch && matchCourse;
    }).toList();

    // Filters run over the pages loaded so far, so an active search or category
    // can leave the screen looking empty while matches sit further down the
    // collection. Pull the next page until there is enough to fill the list or
    // the collection runs out.
    if (filtered.length < _pageSize && _hasMore && !_loadingMore && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

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
                                  '${_items.where((e) => e['category'] == cat).length}',
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
            child: ListView.separated(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              cacheExtent: 500,
              // One extra row for the paging footer.
              itemCount: filtered.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                if (i == filtered.length) return _listFooter(filtered.isEmpty);
                final e = filtered[i];
                final isAvailable = (e['status'] ?? 'Available') == 'Available';
                final category = e['category'] as String? ?? '';
                return GestureDetector(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => EquipmentDetailScreen(equipment: e))),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border(
                        left: BorderSide(
                          color: isAvailable ? AppTheme.success : AppTheme.danger,
                          width: 4,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        EquipmentThumb(
                          bytes: photoThumbOf(e),
                          category: category,
                          color: isAvailable ? AppTheme.success : AppTheme.danger,
                          size: 50,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e['equipment_name'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: AppTheme.textDark)),
                              const SizedBox(height: 2),
                              Text('${e['qr_code']}  •  $category',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textMid)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  StatusBadge(
                                    label: e['status'] ?? 'Available',
                                    color: isAvailable ? AppTheme.success : AppTheme.danger,
                                  ),
                                  if (e['location'] != null && e['location'].toString().isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    StatusBadge(label: e['location'], color: AppTheme.textMid),
                                  ],
                                ],
                              ),
                              if (((e['courses'] as List?)?.isNotEmpty ?? false)) ...[
                                const SizedBox(height: 6),
                                Row(children: [
                                  const Icon(Icons.school_outlined,
                                      size: 12, color: AppTheme.primary),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'For: ${(e['courses'] as List).map((c) => courseLabel('$c')).join(', ')}',
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
                        Icon(
                            isAvailable
                                ? Icons.arrow_forward_ios_rounded
                                : Icons.block_rounded,
                            size: 16,
                            color: isAvailable
                                ? AppTheme.accent
                                : AppTheme.danger),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

