// -----------------------------------------------------------------------------
// LabTrack - staff: equipment registration screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
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
  final _iinCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  // Optional: the lab's records often have no acquisition date.
  DateTime? _dateAcquired;
  // Pre-filled: the centred hintText '1' was indistinguishable from a real
  // value, so the form looked complete but failed validation with "Required".
  final _qtyCtrl = TextEditingController(text: '1');

  // The picked photo's bytes, previewed with Image.memory: it works on the
  // phone and in the web staff portal (Image.file has no file system on the
  // web).
  Uint8List? _pickedBytes;
  final _imagePicker = ImagePicker();

  String? _selectedCategory;
  String? _selectedCondition;
  final List<String> _selectedCourses = [];
  bool _qrGenerated = false;
  // One {equipment_name, qr_code} per physical unit, picked when "Generate QR
  // & Save" is pressed. Step 2 previews exactly these and Confirm writes them.
  List<Map<String, String>> _units = const [];
  bool _planning = false;
  // Step 2 used to open at step 1's scroll offset, i.e. near the bottom, past
  // the QR preview and the list of units.
  final _scrollCtrl = ScrollController();

  bool get _multi => _units.length > 1;
  String get _unitsLabel =>
      _units.length == 1 ? '1 unit' : '${_units.length} units';

  final _categories = kCategories;
  final _conditions = ['Good', 'Fair', 'Under Repair', 'For Disposal'];

  String? _validateRequired(String? v) =>
      (v == null || v.trim().isEmpty) ? 'This field is required' : null;

  String? _validateQty(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final n = int.tryParse(v.trim());
    if (n == null || n < 1) return 'Enter a valid quantity (min 1)';
    if (n > kMaxUnitsPerRegistration) {
      return 'At most $kMaxUnitsPerRegistration at a time';
    }
    return null;
  }

  // A serial number identifies one physical unit, so it cannot be stamped on
  // every unit of a lot. Each unit's own serial goes in via Inventory → Edit.
  String? _validateSerial(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 1;
    return qty > 1
        ? 'A serial number belongs to one unit. Leave it blank here and add '
            'each unit\'s serial in Inventory → Edit.'
        : null;
  }

  Future<void> _generateAndSubmit() async {
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

    // Pick the real names and QR codes now, so the preview matches what will
    // be stored and printed.
    setState(() => _planning = true);
    final res = await ApiService.planEquipmentUnits(
      name:     _nameCtrl.text.trim(),
      category: _selectedCategory!,
      quantity: int.parse(_qtyCtrl.text.trim()),
    );
    if (!mounted) return;
    final ok = res['success'] == true;
    setState(() {
      _planning = false;
      if (ok) {
        _units = res['units'] as List<Map<String, String>>;
        _qrGenerated = true;
      }
    });
    if (ok && _scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message'] ?? 'Could not prepare the QR codes.'),
          backgroundColor: AppTheme.danger));
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
        source: source, imageQuality: 80, maxWidth: 1200);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (mounted) setState(() => _pickedBytes = bytes);
  }

  Future<void> _confirmSave() async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final res = await ApiService.addEquipmentUnits({
        'category':       _selectedCategory,
        'location':       _locationCtrl.text.trim(),
        'courses':        List<String>.from(_selectedCourses),
        'description':    _descCtrl.text.trim(),
        'brand':          _brandCtrl.text.trim(),
        'model':          _modelCtrl.text.trim(),
        'serial_number':  _serialCtrl.text.trim(),
        'iin':            _iinCtrl.text.trim(),
        'date_acquired':  _dateAcquired,
        // The Condition field is required on this form but used to be dropped
        // on the way out, so every item was stored Available — a scope
        // registered as For Disposal was immediately borrowable (QA
        // 2026-09-19, M1).
        'condition':      _selectedCondition,
      }, _units);
      final saved = res['units'] as List<Map<String, dynamic>>;
      // Store the photo once the documents exist and their ids are known. The
      // units of one registration share it.
      String? photoError;
      final bytes = _pickedBytes;
      if (saved.isNotEmpty && bytes != null) {
        final stored = await ApiService.saveEquipmentPhotos(
            [for (final u in saved) u['equipment_id'] as String], bytes);
        photoError = stored.error;
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context); // close loading
      if (saved.isEmpty) {
        messenger.showSnackBar(SnackBar(
            content: Text(res['message'] ?? 'Failed to save.'),
            backgroundColor: AppTheme.danger));
        return;
      }
      Navigator.pop(context, {
        'equipment_name': saved.length == 1
            ? saved.first['equipment_name']
            : _nameCtrl.text.trim(),
        'count':          saved.length,
        'qr_code':        saved.first['qr_code'],
        'category':       _selectedCategory,
        // Whatever was actually stored, not an assumption — the inventory
        // list this pops back to shows this badge straight away.
        'status':         res['status'] ?? 'Available',
        'condition':      _selectedCondition,
        'location':       _locationCtrl.text.trim(),
      });
      // A batch failed part-way: the saved units are real and already in the
      // inventory, so say how many made it rather than report a plain failure.
      if (res['success'] != true) {
        messenger.showSnackBar(SnackBar(
          content: Text('Only ${saved.length} of ${_units.length} units were '
              'saved. ${res['message']} Register the other '
              '${_units.length - saved.length} again; the numbering carries '
              'on from the last one saved.'),
          backgroundColor: AppTheme.warning,
          duration: const Duration(seconds: 8),
        ));
      }
      if (photoError != null) {
        messenger.showSnackBar(SnackBar(
          content: Text('Equipment saved, but the photo could not be '
              'stored: $photoError'),
          backgroundColor: AppTheme.warning,
          duration: const Duration(seconds: 6),
        ));
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
    _modelCtrl.dispose(); _serialCtrl.dispose(); _iinCtrl.dispose();
    _locationCtrl.dispose(); _qtyCtrl.dispose();
    _scrollCtrl.dispose();
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
          controller: _scrollCtrl,
          padding: readablePadding(context, const EdgeInsets.fromLTRB(20, 20, 20, 40), maxWidth: 900),
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
                if (_pickedBytes != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _pickedBytes!,
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
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
                  validator: _validateSerial,
                  decoration: const InputDecoration(
                    hintText: 'e.g. SN-20241105-001',
                    prefixIcon: Icon(Icons.tag_rounded, color: AppTheme.textMid),
                    errorMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 16),

                FieldLabel('IIN (Item Identification No.)'),
                const SizedBox(height: 8),
                TextFormField(
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
                              // The column is only 120 wide, so a one-line
                              // error was cut off mid-sentence.
                              errorMaxLines: 3,
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
                          'Each unit gets its own record and a unique QR code, generated automatically. A quantity above 1 adds that many units, numbered #1, #2, and so on. You can print each code from its equipment detail page.',
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
                    onPressed: _planning ? null : _generateAndSubmit,
                    icon: _planning
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.qr_code_2_rounded),
                    label: Text(_planning
                        ? 'Preparing QR codes…'
                        : 'Generate QR & Save'),
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
                      Text(_multi ? _nameCtrl.text.trim() : _units.first['equipment_name']!,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 4),
                      Text('$_selectedCategory  ·  $_unitsLabel',
                          style: const TextStyle(color: AppTheme.textLight, fontSize: 13)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0x26F5A623),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_multi ? '${_units.length} QR codes' : _units.first['qr_code']!,
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
                        child: QrImageView(
                          data: _units.first['qr_code']!,
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
                      Text(_units.first['qr_code']!,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textDark, letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      Text(_units.first['equipment_name']!,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x0F1B3A8C),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(children: [
                          const Icon(Icons.info_outline_rounded,
                              color: AppTheme.primary, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text(
                            _multi
                                ? 'Each unit gets its own QR code, saved with '
                                  'it. This one is ${_units.first['equipment_name']}; '
                                  'all ${_units.length} are listed below. Reopen '
                                  'any unit\'s detail page to display or '
                                  'screenshot its code for printing.'
                                : 'This QR is saved with the equipment. You can '
                                  'reopen it any time from the equipment detail '
                                  'page to display or screenshot for printing.',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4),
                          )),
                        ]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Every unit this registration will add, with its code, so the
                // labels can be checked before anything is written.
                if (_multi) ...[
                  SectionDivider(
                      icon: Icons.format_list_numbered_rounded,
                      label: 'Units to Add (${_units.length})',
                      color: AppTheme.primary),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: Column(children: [
                      for (var i = 0; i < _units.length; i++) ...[
                        if (i > 0) const Divider(height: 1, color: AppTheme.divider),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(children: [
                            Expanded(
                              child: Text(_units[i]['equipment_name']!,
                                  style: const TextStyle(fontSize: 13, color: AppTheme.textDark)),
                            ),
                            const SizedBox(width: 12),
                            Text(_units[i]['qr_code']!,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primary,
                                    letterSpacing: 1)),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 24),
                ],

                // Equipment summary table
                SectionDivider(icon: Icons.summarize_outlined, label: 'Registration Summary', color: AppTheme.primary),
                const SizedBox(height: 12),
                DetailRow(
                    label: 'Equipment Name',
                    value: _multi ? _nameCtrl.text.trim() : _units.first['equipment_name']!),
                if (!_multi) DetailRow(label: 'Equipment ID', value: _units.first['qr_code']!),
                DetailRow(label: 'Category', value: _selectedCategory ?? ''),
                DetailRow(label: 'Condition', value: _selectedCondition ?? ''),
                DetailRow(label: 'Quantity', value: _unitsLabel),
                if (_brandCtrl.text.isNotEmpty) DetailRow(label: 'Brand', value: _brandCtrl.text),
                if (_modelCtrl.text.isNotEmpty) DetailRow(label: 'Model', value: _modelCtrl.text),
                if (_serialCtrl.text.isNotEmpty) DetailRow(label: 'Serial No.', value: _serialCtrl.text),
                if (_iinCtrl.text.trim().isNotEmpty) DetailRow(label: 'IIN', value: _iinCtrl.text.trim()),
                if (_dateAcquired != null)
                  DetailRow(label: 'Date Acquired', value: formatDate(_dateAcquired!)),
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

