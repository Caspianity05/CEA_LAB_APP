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
  const EquipmentDetailScreen({super.key, required this.equipment});
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
    final name      = equipment['equipment_name'] as String? ?? '';
    final category  = equipment['category']       as String? ?? '';
    final status    = equipment['status']         as String? ?? 'Available';
    final location  = equipment['location']       as String? ?? '';
    final qrCode    = equipment['qr_code']        as String? ?? '';
    final brand     = equipment['brand']          as String? ?? '';
    final model     = equipment['model']          as String? ?? '';
    final serial    = equipment['serial_number']  as String? ?? '';
    final desc      = equipment['description']    as String? ?? '';
    final photo     = _fullPhoto;
    final hasPhoto  = photo != null && photo.isNotEmpty;
    final courses   = (equipment['courses'] as List?)?.cast<String>() ?? [];
    final equipId   = '${equipment['equipment_id'] ?? ''}';
    final isAvail   = status == 'Available';
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
              padding: const EdgeInsets.all(20),
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
                      if (brand.isNotEmpty)
                        specRow('Brand / Manufacturer', brand, isFirst: true),
                      if (model.isNotEmpty)
                        specRow('Model', model, isFirst: brand.isEmpty),
                      if (serial.isNotEmpty)
                        specRow('Serial Number', serial,
                            isFirst: brand.isEmpty && model.isEmpty),
                      specRow('Category', category,
                          isFirst: brand.isEmpty && model.isEmpty && serial.isEmpty),
                      if (location.isNotEmpty) specRow('Storage Location', location),
                      specRow('Status', status, isLast: courses.isEmpty),
                      if (courses.isNotEmpty)
                        specRow('Available to', courses.map((c) => courseLabel(c)).join(', '), isLast: true),
                    ]),
                  ),
                  // ── QR Code card ──
                  if (qrCode.isNotEmpty) ...[
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
                                        equipment: equipment)))
                            : null,
                        icon: Icon(isAvail
                            ? Icons.assignment_outlined
                            : Icons.block_rounded),
                        label: Text(
                            isAvail ? 'Borrow This Equipment' : 'Currently Unavailable'),
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

