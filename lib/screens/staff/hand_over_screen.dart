// -----------------------------------------------------------------------------
// LabTrack - staff: hand over an approved request
//
// Added 2026-10-06 (usability update). The student comes to the counter and
// staff scan each item as it leaves; the loan starts then, and an item nobody
// collected is never counted as overdue. A scanned unit that is not the one
// approval set aside is fine if it is a free unit of the same type: the loan
// swaps to it, so the record names the unit the student actually holds. A
// phone scans with its camera; the web portal takes a typed code or a USB
// scanner, as Process a Return does, with the computer's camera one tap away.
// -----------------------------------------------------------------------------

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'loan_card.dart' show returnTimeLabel;

class HandOverScreen extends StatefulWidget {
  // The records of one request.
  final List<dynamic> request;
  // A code already scanned (Scan QR found a unit waiting for pick-up).
  final String? firstCode;
  const HandOverScreen({super.key, required this.request, this.firstCode});

  @override
  State<HandOverScreen> createState() => _HandOverScreenState();
}

class _HandOverScreenState extends State<HandOverScreen> {
  late List<dynamic> _records = widget.request;
  // False until the live records arrive. Opened from the snackbar right after
  // an approval, the list handed in is the request as it was before (still
  // Pending), which looked like a request with nothing left to hand over
  // (2026-10-07). See the loading check in build().
  bool _fresh = false;
  StreamSubscription<List<dynamic>>? _sub;
  MobileScannerController? _camera;
  bool _useCamera = !kIsWeb;
  final _codeCtrl  = TextEditingController();
  final _codeFocus = FocusNode();
  bool _busy = false;
  // The last result, shown above the checklist.
  String? _message;
  bool _messageOk = true;
  // The camera reports a code many times a second while it is in view.
  String _lastCode = '';
  DateTime _lastAt = DateTime(2000);

  @override
  void initState() {
    super.initState();
    final ids = [for (final t in widget.request) '${t['transaction_id']}'];
    _sub = ApiService.recordsStream(ids).listen((r) {
      if (mounted) {
        setState(() {
          _fresh = true;
          if (r.isNotEmpty) _records = r;
        });
      }
    }, onError: (_) {
      if (mounted) setState(() => _fresh = true);
    });
    if (_useCamera) _camera = MobileScannerController();
    final first = widget.firstCode;
    if (first != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onCode(first));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _camera?.dispose();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _say(String message, bool ok) {
    if (mounted) setState(() { _message = message; _messageOk = ok; });
  }

  Future<void> _onCode(String raw) async {
    final code = raw.trim().toUpperCase();
    if (code.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await ApiService.getEquipmentByQr(code);
      if (res['success'] != true) {
        _say('No equipment has the code $code.', false);
        return;
      }
      final unit = res['data'] as Map<String, dynamic>;
      final name = '${unit['equipment_name'] ?? code}';
      if (_records.any((t) =>
          ApiService.isOut(t) && '${t['equipment_id']}' == '${unit['equipment_id']}')) {
        _say('$name is already handed over.', true);
        return;
      }
      final target = ApiService.handOverTarget(_records, unit);
      if (target == null) {
        final waiting = _records.where(ApiService.awaitingPickup).toList();
        _say(
            waiting.isNotEmpty
                ? '$name is not part of this request. It is waiting for '
                    '${ApiService.requestSummary(waiting)}.'
                : ApiService.handOverState(_records) == 'over'
                    ? 'This request is no longer waiting for pick-up.'
                    : 'Everything in this request is already handed over.',
            false);
        return;
      }
      final r = await ApiService.handOver('${target['transaction_id']}', unit);
      _say('${r['message'] ?? (r['success'] == true ? 'Handed over.' : 'Failed.')}',
          r['success'] == true);
    } catch (_) {
      _say('Could not reach the server. Try again.', false);
    } finally {
      if (mounted) setState(() => _busy = false);
      if (!_useCamera) {
        _codeCtrl.clear();
        _codeFocus.requestFocus();
      }
    }
  }

  void _onDetect(BarcodeCapture capture) {
    final code = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty || _busy) return;
    final now = DateTime.now();
    if (code == _lastCode && now.difference(_lastAt) < const Duration(seconds: 3)) return;
    _lastCode = code;
    _lastAt = now;
    _onCode(code);
  }

  // A unit registered before QR codes (the Digital Multimeter, live test
  // 2026-10-07) has nothing to scan or type, so it could never be handed over
  // and its request could only end as Not picked up. Its row gets its own
  // button: the set-aside unit itself is handed over, no swap.
  static bool _hasNoCode(dynamic t) => '${t['qr_code'] ?? ''}'.trim().isEmpty;

  Future<void> _handOverWithoutCode(dynamic t) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await ApiService.handOver('${t['transaction_id']}', {
        'equipment_id':   t['equipment_id'],
        'equipment_name': t['equipment_name'],
      });
      _say('${r['message'] ?? (r['success'] == true ? 'Handed over.' : 'Failed.')}',
          r['success'] == true);
    } catch (_) {
      _say('Could not reach the server. Try again.', false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final first   = _records.first;
    final name    = '${first['borrower_name'] ?? first['student_number'] ?? 'Student'}';
    final waiting = _records.where(ApiService.awaitingPickup).toList();
    final done    = waiting.isEmpty;
    // Nothing waits and nothing is out: cancelled (Not picked up), rejected
    // or returned meanwhile. It is not "handed over" (live test 2026-10-07).
    final over    = done && ApiService.handOverState(_records) == 'over';
    final due     = ApiService.asDate(first['due_date']);

    // Still loading: the live records have not arrived, or what arrived first
    // is the cached copy from before the approval. A request never goes back
    // to Pending, so a Pending record here is always out of date.
    if (done && (!_fresh || _records.any((t) => '${t['status']}' == 'Pending'))) {
      return Scaffold(
        backgroundColor: AppTheme.surface,
        appBar: AppBar(title: const Text('Hand Over')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('Hand Over'),
        actions: [
          if (!done)
            IconButton(
              tooltip: _useCamera ? 'Type the code instead' : 'Use the camera',
              icon: Icon(_useCamera ? Icons.keyboard_alt_outlined : Icons.photo_camera_outlined),
              onPressed: () => setState(() {
                _useCamera = !_useCamera;
                _camera ??= MobileScannerController();
              }),
            ),
        ],
      ),
      body: ListView(
        padding: readablePadding(context, const EdgeInsets.all(16), maxWidth: 640),
        children: [
          Text('To $name', style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
          const SizedBox(height: 2),
          Text(
              over
                  ? 'This request is no longer waiting for pick-up, so there '
                      'is nothing to hand over. The items below say why.'
                  : done
                  ? 'Everything is handed over.'
                  : 'Scan each item as you hand it over. Another free unit of '
                      'the same item also works; the loan changes to it.'
                      '${waiting.any(_hasNoCode) ? ' An item without a QR code '
                          'has its own Hand over button.' : ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
          const SizedBox(height: 12),

          if (!done && _useCamera && _camera != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 220,
                child: Stack(fit: StackFit.expand, children: [
                  MobileScanner(controller: _camera!, onDetect: _onDetect),
                  if (_busy)
                    Container(
                      color: Colors.black45,
                      child: const Center(
                          child: CircularProgressIndicator(color: AppTheme.accent)),
                    ),
                ]),
              ),
            ),
          if (!done) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  focusNode: _codeFocus,
                  autofocus: !_useCamera,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.done,
                  onSubmitted: _onCode,
                  decoration: const InputDecoration(
                      hintText: 'Or type the code, e.g. OTH-137911',
                      prefixIcon: Icon(Icons.qr_code_rounded)),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _busy ? null : () => _onCode(_codeCtrl.text),
                child: const Text('Hand over'),
              ),
            ]),
          ],

          if (_message != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: (_messageOk ? AppTheme.success : AppTheme.danger)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(_messageOk ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                    size: 18, color: _messageOk ? AppTheme.success : AppTheme.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(_message!,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textDark))),
              ]),
            ),
          ],

          const SizedBox(height: 16),
          const Text('ITEMS', style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textMid,
              letterSpacing: 1)),
          const SizedBox(height: 6),
          for (final t in _records) _itemRow(t),

          if (due != null) ...[
            const SizedBox(height: 8),
            Text('Return by ${returnTimeLabel(context, due)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: done && !over
                ? ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Done'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
                  )
                : TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(over || waiting.length == _records.length
                        ? 'Close'
                        : 'Close (${waiting.length} still waiting)'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(dynamic t) {
    final waiting = ApiService.awaitingPickup(t);
    final out = ApiService.isOut(t);
    final (IconData icon, Color color, String state) = waiting
        ? (Icons.hourglass_top_rounded, AppTheme.accent, 'Waiting')
        : out
            ? (Icons.check_circle_rounded, AppTheme.success, 'Handed over')
            : (Icons.info_outline_rounded, AppTheme.textMid, '${t['status'] ?? ''}');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t['equipment_name'] ?? ''}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
            Text(_hasNoCode(t) ? 'No QR code' : '${t['qr_code']}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
          ]),
        ),
        if (waiting && _hasNoCode(t))
          TextButton(
            onPressed: _busy ? null : () => _handOverWithoutCode(t),
            child: const Text('Hand over'),
          )
        else
          StatusBadge(label: state, color: color),
      ]),
    );
  }
}
