// -----------------------------------------------------------------------------
// LabTrack - staff: qr scan screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── QR Scan Screen (Admin — Return Processing) ───────────────────────────────

class QRScanScreen extends StatefulWidget {
  const QRScanScreen({super.key});
  @override
  State<QRScanScreen> createState() => _QRScanScreenState();
}

class _QRScanScreenState extends State<QRScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanning = true;
  bool _torchOn  = false;
  final _manualCtrl = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_scanning) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;
    setState(() => _scanning = false);
    await _handleCode(code);
  }

  Future<void> _handleCode(String code) async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Looking up equipment...'),
            ]),
          ),
        ),
      ),
    );

    try {
      final res = await ApiService.getEquipmentByQr(code);
      if (!mounted) return;
      Navigator.pop(context); // close loading

      if (res['success'] == true) {
        _showReturnSheet(res['data'] as Map<String, dynamic>);
      } else {
        _showNotFound(code);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showError();
    }
  }

  Future<void> _processReturn(
      String equipId, String equipName, String condition) async {
    Navigator.pop(context); // close the return sheet
    final res = await ApiService.returnEquipmentByQr(equipId, condition);
    if (!mounted) return;
    if (res['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res['message'] ?? 'Failed to process return.'),
        backgroundColor: AppTheme.danger,
        behavior: SnackBarBehavior.floating,
      ));
      setState(() => _scanning = true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(condition == 'Damaged'
          ? '"$equipName" returned and marked Under Repair.'
          : '"$equipName" marked as returned.'),
      backgroundColor:
          condition == 'Damaged' ? AppTheme.warning : AppTheme.success,
      behavior: SnackBarBehavior.floating,
    ));
    if (condition == 'Damaged') {
      await _offerDamageFollowUp(res, equipId, equipName);
    }
    if (mounted) setState(() => _scanning = true);
  }

  Future<void> _offerDamageFollowUp(
      Map<String, dynamic> res, String equipId, String equipName) async {
    final borrower  = '${res['borrower_name'] ?? 'the student'}';
    final studentId = '${res['student_id'] ?? ''}';
    final apply = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.gpp_maybe_outlined, color: AppTheme.danger, size: 44),
        title: const Text('Log Damage & Hold?'),
        content: Text(
            'Record a damage report for "$equipName" and place a borrowing hold '
            'on $borrower until it is settled?',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Skip', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Log & Hold')),
        ],
      ),
    );
    if (apply != true) return;
    await ApiService.submitDamageReport({
      'equipment_id':   equipId,
      'equipment_name': equipName,
      'student_id':     studentId,
      'borrower_name':  res['borrower_name'] ?? '',
      'student_number': res['student_number'] ?? '',
      'description':    'Reported damaged on return (staff QR return).',
      'reported_by':    'staff',
    });
    if (studentId.isNotEmpty) {
      await ApiService.setStudentHold(studentId, true,
          reason: 'Damaged equipment "$equipName" pending settlement.');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Damage report logged and hold placed.'),
      backgroundColor: AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showReturnSheet(Map<String, dynamic> equipment) {
    final status      = equipment['status'] ?? 'Unknown';
    final isBorrowed  = status == 'Borrowed';
    // Not-Borrowed does not mean Available: an item can be Under Repair or
    // For Disposal. This sheet used to paint the badge green and say "already
    // Available" for all three. Found on the emulator 2026-09-21 by scanning
    // an Under Repair item, which reported itself Available.
    final isAvailable = status == 'Available';
    final statusColor = isBorrowed
        ? AppTheme.warning
        : isAvailable
            ? AppTheme.success
            : AppTheme.danger;
    final equipName   = equipment['equipment_name'] ?? '';
    final equipId     = '${equipment['equipment_id']}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Handle
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppTheme.divider,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),

          // Equipment info
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16)),
            child: Icon(Icons.science_outlined, color: statusColor, size: 30),
          ),
          const SizedBox(height: 12),
          Text(equipName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                  color: AppTheme.textDark),
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text('${equipment['qr_code']}  •  ${equipment['category']}',
              style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 12),

          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            StatusBadge(label: status, color: statusColor),
            if (equipment['location'] != null) ...[
              const SizedBox(width: 8),
              StatusBadge(label: equipment['location'], color: AppTheme.textMid),
            ],
          ]),
          const SizedBox(height: 24),
          const Divider(color: AppTheme.divider),
          const SizedBox(height: 16),

          // Action
          if (isBorrowed) ...[
            const Text(
                'Confirm the student has returned this equipment, then record its condition.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _processReturn(equipId, equipName, 'Good'),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('Return — Good Condition'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.success,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _processReturn(equipId, equipName, 'Damaged'),
                icon: const Icon(Icons.report_problem_outlined),
                label: const Text('Return — Report Damage'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.warning,
                    side: const BorderSide(color: AppTheme.warning),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.info_outline_rounded, color: statusColor, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(
                  isAvailable
                      ? 'This equipment is already Available — no return '
                          'needed.'
                      : 'This equipment is marked $status and is not out on '
                          'loan, so there is nothing to return.',
                  style: const TextStyle(fontSize: 13, color: AppTheme.textDark),
                )),
              ]),
            ),
          ],

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() => _scanning = true);
              },
              child: const Text('Scan Another'),
            ),
          ),
        ]),
      ),
    ).then((_) => setState(() => _scanning = true));
  }

  void _showNotFound(String code) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.search_off_rounded, color: AppTheme.danger, size: 48),
        title: const Text('Not Found'),
        content: Text('No equipment found for:\n"$code"',
            textAlign: TextAlign.center),
        actions: [ElevatedButton(
          onPressed: () { Navigator.pop(context); setState(() => _scanning = true); },
          child: const Text('Scan Again'))],
      ),
    );
  }

  void _showError() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.wifi_off_rounded, color: AppTheme.danger, size: 48),
        title: const Text('Connection Error'),
        content: const Text('Could not reach the server.',
            textAlign: TextAlign.center),
        actions: [ElevatedButton(
          onPressed: () { Navigator.pop(context); setState(() => _scanning = true); },
          child: const Text('Try Again'))],
      ),
    );
  }

  void _showManualEntry() {
    _manualCtrl.clear();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Enter QR Code Manually'),
        content: TextField(
          controller: _manualCtrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
              hintText: 'e.g. ELE-001',
              prefixIcon: Icon(Icons.qr_code_rounded)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
            onPressed: () async {
              final code = _manualCtrl.text.trim().toUpperCase();
              if (code.isEmpty) return;
              Navigator.pop(context);
              setState(() => _scanning = false);
              await _handleCode(code);
            },
            child: const Text('Look Up'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan QR — Process Return'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: _torchOn ? AppTheme.accent : Colors.white),
            onPressed: () {
              _controller.toggleTorch();
              setState(() => _torchOn = !_torchOn);
            },
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Live camera
          MobileScanner(controller: _controller, onDetect: _onDetect),

          // Overlay
          CustomPaint(painter: _ScanOverlayPainter(), child: const SizedBox.expand()),

          // Instructions + manual entry
          Column(children: [
            const Spacer(),
            // Unconstrained, this line ran off the edge on a narrow screen
            // (QA 2026-09-19, low #12). Padding plus a centred wrap keeps it
            // on-screen at any width.
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text('Scan equipment QR code to process return',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            const SizedBox(height: 220),
            TextButton.icon(
              onPressed: _showManualEntry,
              icon: const Icon(Icons.keyboard_alt_outlined, color: AppTheme.accent),
              label: const Text('Enter code manually',
                  style: TextStyle(color: AppTheme.accent)),
            ),
            const SizedBox(height: 32),
          ]),

          // Loading overlay while processing
          if (!_scanning)
            Container(
              color: Colors.black45,
              child: const Center(child: CircularProgressIndicator(color: AppTheme.accent)),
            ),
        ],
      ),
    );
  }
}

// ── Scan overlay painter ──────────────────────────────────────────────────────
class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const boxSize = 260.0;
    final cx = size.width / 2;
    final cy = size.height / 2 - 60;
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: boxSize, height: boxSize);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = const Color(0x8C000000));

    canvas.drawRRect(rrect, Paint()
      ..color = const Color(0xFFF5A623)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);

    const cLen = 24.0;
    final cp = Paint()
      ..color = const Color(0xFFF5A623)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final l = rect.left; final t = rect.top;
    final r = rect.right; final b = rect.bottom;
    canvas.drawLine(Offset(l, t + cLen), Offset(l, t), cp);
    canvas.drawLine(Offset(l, t), Offset(l + cLen, t), cp);
    canvas.drawLine(Offset(r - cLen, t), Offset(r, t), cp);
    canvas.drawLine(Offset(r, t), Offset(r, t + cLen), cp);
    canvas.drawLine(Offset(l, b - cLen), Offset(l, b), cp);
    canvas.drawLine(Offset(l, b), Offset(l + cLen, b), cp);
    canvas.drawLine(Offset(r - cLen, b), Offset(r, b), cp);
    canvas.drawLine(Offset(r, b), Offset(r, b - cLen), cp);
  }

  @override
  bool shouldRepaint(_) => false;
}

