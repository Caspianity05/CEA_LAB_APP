// -----------------------------------------------------------------------------
// LabTrack - student: equipment detail screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 6 of the module split.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:qr_flutter/qr_flutter.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'borrow_request_screen.dart';

// ─── Equipment Detail Screen ───────────────────────────────────────────────────

class EquipmentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> equipment;
  // Opened from the student catalog (1.0.19), the page is about an item TYPE:
  // [equipment] is one of its units, standing in for the details and photo,
  // [available] how many are free right now and [inLab] how many can be lent
  // at all. Staff (Inventory) open one unit, with these left null.
  final String? typeName;
  final int? available;
  final int? inLab;
  const EquipmentDetailScreen({
    super.key,
    required this.equipment,
    this.typeName,
    this.available,
    this.inLab,
  });
  @override
  State<EquipmentDetailScreen> createState() => _EquipmentDetailScreenState();
}

class _EquipmentDetailScreenState extends State<EquipmentDetailScreen> {
  Map<String, dynamic> get equipment => widget.equipment;

  // The list thumbnail is already on the record; the larger copy lives in its
  // own document and is fetched only here, when someone actually looks at it.
  Uint8List? _fullPhoto;

  @override
  void initState() {
    super.initState();
    _fullPhoto = photoThumbOf(widget.equipment);
    final id = '${widget.equipment['equipment_id'] ?? ''}';
    if (id.isNotEmpty) {
      ApiService.getEquipmentPhoto(id).then((bytes) {
        if (!mounted || bytes == null) return;
        setState(() => _fullPhoto = bytes);
      }).catchError((_) {});
    }
  }

  IconData _categoryIcon(String cat) {
    switch (cat.toLowerCase()) {
      case 'electronics':     return Icons.electric_bolt_rounded;
      case 'tools':           return Icons.build_rounded;
      case 'measurement':     return Icons.straighten_rounded;
      case 'optics':          return Icons.remove_red_eye_rounded;
      case 'microcontroller': return Icons.memory_rounded;
      default:                return Icons.science_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeName  = widget.typeName;
    final byType    = typeName != null;
    final free      = widget.available ?? 0;
    final name      = typeName ?? equipment['equipment_name'] as String? ?? '';
    final category  = equipment['category']       as String? ?? '';
    // For a type: whether any unit is free, said as a count.
    final status    = byType
        ? (free > 0 ? '$free available' : 'None free right now')
        : equipment['status'] as String? ?? 'Available';
    final location  = equipment['location']       as String? ?? '';
    final qrCode    = equipment['qr_code']        as String? ?? '';
    final brand     = equipment['brand']          as String? ?? '';
    final model     = equipment['model']          as String? ?? '';
    final serial    = equipment['serial_number']  as String? ?? '';
    final iin       = '${equipment['iin'] ?? ''}'.trim();
    final acquired  = ApiService.asDate(equipment['date_acquired']);
    final added     = ApiService.asDate(equipment['created_at']);
    final addedBy   = '${equipment['created_by_name'] ?? ''}'.trim();
    final desc      = equipment['description']    as String? ?? '';
    final photo     = _fullPhoto;
    final hasPhoto  = photo != null && photo.isNotEmpty;
    final courses   = (equipment['courses'] as List?)?.cast<String>() ?? [];
    final equipId   = '${equipment['equipment_id'] ?? ''}';
    final isAvail   = byType ? free > 0 : status == 'Available';
    final isStudent = Session.role == 'student';

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: CustomScrollView(
        slivers: [
          // ── App bar with collapsing image ──
          SliverAppBar(
            expandedHeight: hasPhoto ? 260 : 160,
            pinned: true,
            backgroundColor: AppTheme.primary,
            iconTheme: const IconThemeData(color: Colors.white),
            flexibleSpace: FlexibleSpaceBar(
              background: hasPhoto
                  ? Stack(fit: StackFit.expand, children: [
                      // Starts as the thumbnail already in hand, then swaps to
                      // the full-size copy once it arrives.
                      Image.memory(
                        photo,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) =>
                            _imageFallback(category),
                      ),
                      // Dark gradient so text is readable
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x33000000), Color(0xAA000000)],
                          ),
                        ),
                      ),
                    ])
                  : _imageFallback(category),
              title: Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              titlePadding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: readablePadding(context, const EdgeInsets.all(20), maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Status + Category row ──
                  Row(children: [
                    StatusBadge(
                      label: status,
                      color: isAvail ? AppTheme.success : AppTheme.danger,
                    ),
                    const SizedBox(width: 8),
                    StatusBadge(label: category, color: AppTheme.primary),
                    if (location.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      StatusBadge(
                        label: location,
                        color: AppTheme.textMid,
                      ),
                    ],
                  ]),
                  const SizedBox(height: 20),

                  // ── Description ──
                  if (desc.isNotEmpty) ...[
                    const Text('About this equipment',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textDark)),
                    const SizedBox(height: 8),
                    Text(desc,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMid,
                            height: 1.6)),
                    const SizedBox(height: 20),
                  ],

                  // ── Specifications table ──
                  const Text('Specifications',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textDark)),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: Column(children: [
                      for (final (i, row) in [
                        if (brand.isNotEmpty) ('Brand / Manufacturer', brand),
                        if (model.isNotEmpty) ('Model', model),
                        // A type page leaves out what belongs to one unit.
                        if (!byType && serial.isNotEmpty) ('Serial Number', serial),
                        if (!byType && iin.isNotEmpty) ('IIN', iin),
                        ('Category', category),
                        if (location.isNotEmpty) ('Storage Location', location),
                        if (byType)
                          ('Available now',
                              widget.inLab == null ? status : '$free of ${widget.inLab} in the lab')
                        else
                          ('Status', status),
                        if (courses.isNotEmpty)
                          ('Available to', courses.map((c) => courseLabel(c)).join(', ')),
                        if (!byType && acquired != null) ('Date Acquired', formatDate(acquired)),
                        // When staff put it in the system; students don't need it.
                        if (!isStudent && added != null)
                          ('Date Added',
                              addedBy.isEmpty ? formatDate(added) : '${formatDate(added)} by $addedBy'),
                      ].indexed)
                        specRow(row.$1, row.$2, isFirst: i == 0),
                    ]),
                  ),
                  // ── QR Code card (one unit's) ──
                  if (!byType && qrCode.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('QR Code',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textDark)),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.divider),
                      ),
                      child: Column(children: [
                        QrImageView(
                          data: qrCode,
                          version: QrVersions.auto,
                          size: 180,
                          eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: AppTheme.primary),
                          dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: AppTheme.primary),
                        ),
                        const SizedBox(height: 8),
                        Text(qrCode,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMid,
                                letterSpacing: 1.2)),
                      ]),
                    ),
                  ],

                  // ── Loan history (staff only) ──
                  if (!isStudent && equipId.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _LoanHistory(equipmentId: equipId),
                  ],
                  const SizedBox(height: 28),

                  // ── Borrow button (students only, available only) ──
                  if (isStudent)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: isAvail
                            ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => BorrowRequestScreen(
                                        equipmentName: name,
                                        equipmentId: equipId,
                                        equipment: equipment,
                                        available: byType ? free : null)))
                            : null,
                        icon: Icon(isAvail
                            ? Icons.assignment_outlined
                            : Icons.block_rounded),
                        label: Text(isAvail
                            ? 'Borrow This Equipment'
                            : byType
                                ? 'None Free Right Now'
                                : 'Currently Unavailable'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              isAvail ? AppTheme.primary : AppTheme.textLight,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageFallback(String category) {
    return Container(
      color: AppTheme.primary,
      child: Center(
        child: Icon(_categoryIcon(category), size: 72, color: Colors.white24),
      ),
    );
  }
}

// Who has had this unit, newest first, and what became of each loan (staff
// only, 2026-10-06: "who had it last?" used to mean searching every
// request). Students cannot read other students' records, so it is not shown
// to them.
class _LoanHistory extends StatefulWidget {
  final String equipmentId;
  const _LoanHistory({required this.equipmentId});
  @override
  State<_LoanHistory> createState() => _LoanHistoryState();
}

class _LoanHistoryState extends State<_LoanHistory> {
  static const _shown = 20;
  late final Future<List<dynamic>> _history = ApiService.getItemHistory(widget.equipmentId);

  Color _color(String outcome) => switch (outcome) {
        'Overdue' || 'Returned late' || 'Rejected' => AppTheme.danger,
        'On loan' || 'Returned on time' => AppTheme.success,
        'Ready for pick-up' => AppTheme.primary,
        'Waiting for approval' => AppTheme.accent,
        _ => AppTheme.textMid,
      };

  @override
  Widget build(BuildContext context) {
    String when(dynamic v) {
      final d = ApiService.asDate(v);
      return d == null ? '' : '${formatDate(d)}, ${TimeOfDay.fromDateTime(d).format(context)}';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Loan History',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
      const SizedBox(height: 10),
      FutureBuilder<List<dynamic>>(
        future: _history,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final all = snap.data ?? const [];
          if (snap.hasError || all.isEmpty) {
            return Text(
                snap.hasError
                    ? 'Could not load the history.'
                    : 'No one has asked for this item yet.',
                style: const TextStyle(fontSize: 12, color: AppTheme.textMid));
          }
          return Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.divider),
            ),
            child: Column(children: [
              for (final (i, t) in all.take(_shown).indexed) ...[
                if (i > 0) const Divider(height: 1, color: AppTheme.divider),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${t['borrower_name'] ?? 'Student'}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
                        Text(
                            [
                              if ('${t['student_number'] ?? ''}'.isNotEmpty) '${t['student_number']}',
                              'Requested ${when(t['borrow_date'])}',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                        if (ApiService.asDate(t['return_date']) != null)
                          Text(
                              'Returned ${when(t['return_date'])}'
                              '${'${t['condition_returned'] ?? ''}' == 'Damaged' ? ' · damaged' : ''}',
                              style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Builder(builder: (_) {
                      final outcome = ApiService.loanOutcome(t);
                      return StatusBadge(label: outcome, color: _color(outcome));
                    }),
                  ]),
                ),
              ],
              if (all.length > _shown)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text('Showing the latest $_shown of ${all.length}.',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textLight)),
                ),
            ]),
          );
        },
      ),
    ]);
  }
}

