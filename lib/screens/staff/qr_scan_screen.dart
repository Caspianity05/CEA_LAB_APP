// -----------------------------------------------------------------------------
// LabTrack - staff: qr scan screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// The return sheet and the damage follow-up moved to return_flow.dart on
// 2026-10-05, so the Dashboard's "Mark as Returned" can use the same step.
// -----------------------------------------------------------------------------


import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import 'hand_over_screen.dart';
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

  // The web staff portal opens as a return desk: a code box with the focus in
  // it, so a USB QR scanner (which types the code and presses Enter) or the
  // keyboard does the job; the computer's camera is one tap away.
  bool _useCamera = !kIsWeb;
  final _deskCtrl  = TextEditingController();
  final _deskFocus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _manualCtrl.dispose();
    _deskCtrl.dispose();
    _deskFocus.dispose();
    super.dispose();
  }

  Future<void> _deskLookUp() async {
    final code = _deskCtrl.text.trim().toUpperCase();
    if (code.isEmpty || !_scanning) return;
    setState(() => _scanning = false);
    await _handleCode(code);
    if (!mounted) return;
    _deskCtrl.clear();
    _deskFocus.requestFocus();
  }

  Widget _returnDesk() {
    return Scaffold(
      appBar: AppBar(title: const Text('Hand Over or Return')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.qr_code_scanner_rounded, size: 56, color: AppTheme.primary),
              const SizedBox(height: 12),
              const Text(
                "Type the code on the item's label, or scan it with a USB QR scanner.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppTheme.textDark),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _deskCtrl,
                focusNode: _deskFocus,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _deskLookUp(),
                decoration: const InputDecoration(
                    hintText: 'e.g. OTH-137911',
                    prefixIcon: Icon(Icons.qr_code_rounded)),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _scanning ? _deskLookUp : null,
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Look Up'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _useCamera = true),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text("Use this computer's camera"),
              ),
            ]),
          ),
        ),
      ),
    );
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
      // A unit set aside for a student who has come to collect it is handed
      // over, not returned (2026-10-06).
      var waiting = const <dynamic>[];
      if (res['success'] == true &&
          (res['data'] as Map<String, dynamic>)['status'] == 'Borrowed') {
        waiting = await ApiService.awaitingRequestFor(
            '${(res['data'] as Map<String, dynamic>)['equipment_id']}');
      }
      if (!mounted) return;
      Navigator.pop(context); // close loading

      if (res['success'] == true && waiting.isNotEmpty) {
        // One camera at a time: the hand-over screen opens its own.
        try { await _controller.stop(); } catch (_) {}
        if (!mounted) return;
        await Navigator.push(context, MaterialPageRoute(
            builder: (_) => HandOverScreen(request: waiting, firstCode: code)));
        if (_useCamera) {
          try { await _controller.start(); } catch (_) {}
        }
        if (mounted) setState(() => _scanning = true);
      } else if (res['success'] == true) {
        final equipment = res['data'] as Map<String, dynamic>;
        await showReturnSheet(
          context,
          equipment: equipment,
          doReturn: (condition) => ApiService.returnEquipmentByQr(
              '${equipment['equipment_id']}', condition),
        );
        if (mounted) setState(() => _scanning = true);
      } else {
        await _showNotFound(code);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      await _showError();
    }
  }

  // Both dialogs resume scanning however they close. Back, Esc or a tap
  // outside used to skip the button and leave the scanner paused for good.
  Future<void> _showNotFound(String code) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.search_off_rounded, color: AppTheme.danger, size: 48),
        title: const Text('Not Found'),
        content: Text('No equipment found for:\n"$code"',
            textAlign: TextAlign.center),
        actions: [ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Scan Again'))],
      ),
    );
    if (mounted) setState(() => _scanning = true);
  }

  Future<void> _showError() async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.wifi_off_rounded, color: AppTheme.danger, size: 48),
        title: const Text('Connection Error'),
        content: const Text('Could not reach the server.',
            textAlign: TextAlign.center),
        actions: [ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Try Again'))],
      ),
    );
    if (mounted) setState(() => _scanning = true);
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
    if (!_useCamera) return _returnDesk();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan QR — Hand Over or Return'),
        backgroundColor: Colors.black,
        // A computer's camera has no torch; offer the way back to typing.
        actions: kIsWeb ? [
          IconButton(
            tooltip: 'Type the code instead',
            icon: const Icon(Icons.keyboard_alt_outlined, color: Colors.white),
            onPressed: () => setState(() => _useCamera = false),
          ),
        ] : [
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

          // Instructions just under the scan box, manual entry at the bottom.
          // Placed from the box rather than from the bottom edge, so a short,
          // wide browser window does not push the line into the box.
          LayoutBuilder(builder: (context, size) => Stack(children: [
            Positioned(
              left: 24, right: 24,
              top: size.maxHeight / 2 - _kScanBoxLift + _kScanBox / 2 + 16,
              // Unconstrained, this line ran off the edge on a narrow screen
              // (QA 2026-09-19, low #12). Side insets plus a centred wrap keep
              // it on-screen at any width.
              child: const Text('Scan an item to hand it over or to take it back',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            Positioned(
              left: 0, right: 0, bottom: 32,
              child: Center(
                child: TextButton.icon(
                  onPressed: _showManualEntry,
                  icon: const Icon(Icons.keyboard_alt_outlined, color: AppTheme.accent),
                  label: const Text('Enter code manually',
                      style: TextStyle(color: AppTheme.accent)),
                ),
              ),
            ),
          ])),

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
// The scan box: its size, and how far above the middle of the view it sits.
const double _kScanBox = 260;
const double _kScanBoxLift = 60;

class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const boxSize = _kScanBox;
    final cx = size.width / 2;
    final cy = size.height / 2 - _kScanBoxLift;
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
