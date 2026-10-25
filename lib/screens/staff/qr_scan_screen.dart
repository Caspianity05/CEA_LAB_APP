// -----------------------------------------------------------------------------
// LabTrack - staff: qr scan screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// The return sheet and the damage follow-up moved to return_flow.dart on
// 2026-10-05, so the Dashboard's "Mark as Returned" can use the same step.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import 'return_flow.dart';

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
        final equipment = res['data'] as Map<String, dynamic>;
        await showReturnSheet(
          context,
          equipment: equipment,
          doReturn: (condition) => ApiService.returnEquipmentByQr(
              '${equipment['equipment_id']}', condition),
        );
        if (mounted) setState(() => _scanning = true);
      } else {
        _showNotFound(code);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showError();
    }
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
