// -----------------------------------------------------------------------------
// LabTrack - staff: equipment registration screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Equipment Registration Screen ────────────────────────────────────────────

class EquipmentRegistrationScreen extends StatefulWidget {
  const EquipmentRegistrationScreen({super.key});
  @override
  State<EquipmentRegistrationScreen> createState() =>
      _EquipmentRegistrationScreenState();
}

class _EquipmentRegistrationScreenState
    extends State<EquipmentRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  // Pre-filled: the centred hintText '1' was indistinguishable from a real
  // value, so the form looked complete but failed validation with "Required".
  final _qtyCtrl = TextEditingController(text: '1');

  XFile? _pickedImage;
  final _imagePicker = ImagePicker();

  String? _selectedCategory;
  String? _selectedCondition;
  final List<String> _selectedCourses = [];
  bool _qrGenerated = false;
  String _generatedId = '';
  String _generatedQr = '';

  final _categories = kCategories;
  final _conditions = ['Good', 'Fair', 'Under Repair', 'For Disposal'];

  String? _validateRequired(String? v) =>
      (v == null || v.trim().isEmpty) ? 'This field is required' : null;

  String? _validateQty(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final n = int.tryParse(v.trim());
    if (n == null || n < 1) return 'Enter a valid quantity (min 1)';
    return null;
  }

  void _generateAndSubmit() {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select a category'),
          backgroundColor: AppTheme.danger));
      return;
    }
    if (_selectedCondition == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select equipment condition'),
          backgroundColor: AppTheme.danger));
      return;
    }

    // Build the real QR code now (same scheme the backend uses) so the preview
    // matches the code that will be stored and printed.
    final cat = _selectedCategory ?? 'EQ';
    final prefix = cat.length >= 3 ? cat.substring(0, 3).toUpperCase() : cat.toUpperCase();
    final suffix = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    setState(() {
      _generatedQr = '$prefix-$suffix';
      _generatedId = _generatedQr;
      _qrGenerated = true;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
        source: source, imageQuality: 80, maxWidth: 1200);
    if (picked != null) setState(() => _pickedImage = picked);
  }

  Future<void> _confirmSave() async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final res = await ApiService.addEquipment({
        'equipment_name': _nameCtrl.text.trim(),
        'category':       _selectedCategory,
        'location':       _locationCtrl.text.trim(),
        'courses':        List<String>.from(_selectedCourses),
        'description':    _descCtrl.text.trim(),
        'brand':          _brandCtrl.text.trim(),
        'model':          _modelCtrl.text.trim(),
        'serial_number':  _serialCtrl.text.trim(),
        'qr_code':        _generatedQr,
        // The Condition field is required on this form but used to be dropped
        // on the way out, so every item was stored Available — a scope
        // registered as For Disposal was immediately borrowable (QA
        // 2026-09-19, M1).
        'condition':      _selectedCondition,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        // Store the photo once the document exists and its id is known.
        String? photoError;
        if (_pickedImage != null) {
          final bytes = await _pickedImage!.readAsBytes();
          final saved = await ApiService.saveEquipmentPhoto(
              res['equipment_id'] as String, bytes);
          photoError = saved.error;
        }
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context); // close loading
        Navigator.pop(context, {
          'equipment_name': _nameCtrl.text.trim(),
          'qr_code':        res['qr_code'] ?? _generatedId,
          'category':       _selectedCategory,
          // Whatever was actually stored, not an assumption — the inventory
          // list this pops back to shows this badge straight away.
          'status':         res['status'] ?? 'Available',
          'condition':      _selectedCondition,
          'location':       _locationCtrl.text.trim(),
        });
        if (photoError != null) {
          messenger.showSnackBar(SnackBar(
            content: Text('Equipment saved, but the photo could not be '
                'stored: $photoError'),
            backgroundColor: AppTheme.warning,
            duration: const Duration(seconds: 6),
          ));
        }
      } else {
        Navigator.pop(context); // close loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message'] ?? 'Failed to save.'), backgroundColor: AppTheme.danger));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot connect to server.'), backgroundColor: AppTheme.danger));
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _descCtrl.dispose(); _brandCtrl.dispose();
    _modelCtrl.dispose(); _serialCtrl.dispose();
    _locationCtrl.dispose(); _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(title: const Text('Register Equipment')),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Progress indicator ──
              _ProgressSteps(step: _qrGenerated ? 2 : 1),
              const SizedBox(height: 24),

              if (!_qrGenerated) ...[
                // ══════════════════════════════════════════
                // STEP 1 — Equipment Information
                // ══════════════════════════════════════════

                SectionDivider(
                    icon: Icons.inventory_2_outlined,
                    label: 'Basic Information',
                    color: AppTheme.primary),
                const SizedBox(height: 16),

                FieldLabel('Equipment Name *'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameCtrl,
                  validator: _validateRequired,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Digital Multimeter',
                    prefixIcon: Icon(Icons.science_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('Description'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Brief description of the equipment and its purpose...',
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('Equipment Photo'),
                const SizedBox(height: 8),
                if (_pickedImage != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_pickedImage!.path),
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
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
                else
                  Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.image_outlined, size: 36, color: AppTheme.textLight),
                        SizedBox(height: 6),
                        Text('No photo selected',
                            style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
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
                const SizedBox(height: 16),

                // Category + Condition side by side
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                hint: const Text('Select', style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
                                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
                                onChanged: (v) => setState(() => _selectedCategory = v),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FieldLabel('Condition *'),
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
                                value: _selectedCondition,
                                hint: const Text('Select', style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
                                items: _conditions.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
                                onChanged: (v) => setState(() => _selectedCondition = v),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                FieldLabel('Available to Courses (leave empty for all)'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: kCourses.map((c) {
                    final selected = _selectedCourses.contains(c);
                    return FilterChip(
                      label: Text(courseLabel(c), style: TextStyle(fontSize: 12, color: selected ? Colors.white : AppTheme.textDark)),
                      selected: selected,
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.surface,
                      checkmarkColor: Colors.white,
                      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.divider),
                      onSelected: (v) => setState(() {
                        if (v) { _selectedCourses.add(c); } else { _selectedCourses.remove(c); }
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),

                SectionDivider(
                    icon: Icons.build_circle_outlined,
                    label: 'Technical Details',
                    color: AppTheme.primary),
                const SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FieldLabel('Brand / Manufacturer'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _brandCtrl,
                            decoration: const InputDecoration(hintText: 'e.g. Fluke'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FieldLabel('Model'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _modelCtrl,
                            decoration: const InputDecoration(hintText: 'e.g. 117'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                FieldLabel('Serial Number'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _serialCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. SN-20241105-001',
                    prefixIcon: Icon(Icons.tag_rounded, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 24),

                SectionDivider(
                    icon: Icons.warehouse_outlined,
                    label: 'Quantity & Location',
                    color: AppTheme.primary),
                const SizedBox(height: 16),

                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FieldLabel('Quantity *'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _qtyCtrl,
                            validator: _validateQty,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(
                              hintText: '1',
                              prefixIcon: Icon(Icons.numbers_rounded, color: AppTheme.textMid),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FieldLabel('Storage Location'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _locationCtrl,
                            decoration: const InputDecoration(
                              hintText: 'e.g. Cabinet A, Shelf 2',
                              prefixIcon: Icon(Icons.location_on_outlined, color: AppTheme.textMid),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Info note
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x0F1B3A8C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x261B3A8C)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.qr_code_rounded, color: AppTheme.primary, size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'A unique QR code will be automatically generated for this equipment after saving. You can print it from the equipment detail page.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMid, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _generateAndSubmit,
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('Generate QR & Save'),
                  ),
                ),
              ],

              if (_qrGenerated) ...[
                // ══════════════════════════════════════════
                // STEP 2 — QR Code Generated
                // ══════════════════════════════════════════

                // Summary card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 52, height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0x3306D6A0),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_rounded, color: AppTheme.success, size: 28),
                      ),
                      const SizedBox(height: 12),
                      Text(_nameCtrl.text,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 4),
                      Text('$_selectedCategory  ·  Qty: ${_qtyCtrl.text}',
                          style: const TextStyle(color: AppTheme.textLight, fontSize: 13)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0x26F5A623),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_generatedId,
                            style: const TextStyle(
                                color: AppTheme.accent,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                letterSpacing: 2)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // QR Code display
                SectionDivider(icon: Icons.qr_code_rounded, label: 'Generated QR Code', color: AppTheme.primary),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: const Color(0x141B3A8C), blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 180, height: 180,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppTheme.divider, width: 2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: _generatedQr.isEmpty
                            ? const SizedBox.shrink()
                            : QrImageView(
                                data: _generatedQr,
                                version: QrVersions.auto,
                                eyeStyle: const QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: AppTheme.primary),
                                dataModuleStyle: const QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: AppTheme.primary),
                              ),
                      ),
                      const SizedBox(height: 14),
                      Text(_generatedId,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textDark, letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      Text(_nameCtrl.text,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x0F1B3A8C),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(children: [
                          Icon(Icons.info_outline_rounded,
                              color: AppTheme.primary, size: 16),
                          SizedBox(width: 8),
                          Expanded(child: Text(
                            'This QR is saved with the equipment. You can reopen '
                            'it any time from the equipment detail page to display '
                            'or screenshot for printing.',
                            style: TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4),
                          )),
                        ]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Equipment summary table
                SectionDivider(icon: Icons.summarize_outlined, label: 'Registration Summary', color: AppTheme.primary),
                const SizedBox(height: 12),
                DetailRow(label: 'Equipment Name', value: _nameCtrl.text),
                DetailRow(label: 'Equipment ID', value: _generatedId),
                DetailRow(label: 'Category', value: _selectedCategory ?? ''),
                DetailRow(label: 'Condition', value: _selectedCondition ?? ''),
                DetailRow(label: 'Quantity', value: '${_qtyCtrl.text} units'),
                if (_brandCtrl.text.isNotEmpty) DetailRow(label: 'Brand', value: _brandCtrl.text),
                if (_modelCtrl.text.isNotEmpty) DetailRow(label: 'Model', value: _modelCtrl.text),
                if (_serialCtrl.text.isNotEmpty) DetailRow(label: 'Serial No.', value: _serialCtrl.text),
                if (_locationCtrl.text.isNotEmpty) DetailRow(label: 'Location', value: _locationCtrl.text),
                const SizedBox(height: 28),

                // Confirm save
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _confirmSave,
                    icon: const Icon(Icons.check_circle_rounded),
                    label: const Text('Confirm & Add to Inventory'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _qrGenerated = false),
                    icon: const Icon(Icons.arrow_back_rounded, size: 16),
                    label: const Text('Go Back & Edit'),
                    style: TextButton.styleFrom(foregroundColor: AppTheme.textMid),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Progress steps widget shown at top of registration form
class _ProgressSteps extends StatelessWidget {
  final int step; // 1 or 2
  const _ProgressSteps({required this.step});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Step(number: '1', label: 'Equipment Info', active: step >= 1, done: step > 1),
        Expanded(child: Container(height: 2, color: step > 1 ? AppTheme.success : AppTheme.divider)),
        _Step(number: '2', label: 'QR Code', active: step >= 2, done: false),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final String number, label;
  final bool active, done;
  const _Step({required this.number, required this.label, required this.active, required this.done});

  @override
  Widget build(BuildContext context) {
    final color = done ? AppTheme.success : (active ? AppTheme.primary : AppTheme.textLight);
    return Column(
      children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: done ? AppTheme.success : (active ? AppTheme.primary : Colors.white),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
                : Text(number, style: TextStyle(color: active ? Colors.white : AppTheme.textLight, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ],
    );
  }
}

