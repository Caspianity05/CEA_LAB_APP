// -----------------------------------------------------------------------------
// LabTrack - shared UI widgets
//
// Extracted from firstFile.dart on 2026-08-03 as step 4 of the module split.
// Small presentational pieces used by more than one screen. Widgets belonging
// to a single screen (_RoleTab, _HeroStat, _LoanItemCard, _PolicyReminder, ...)
// deliberately stay behind and will travel with their screen.
//
// Names that were library-private are public here because they now cross a
// library boundary. FieldLabel alone has 44 call sites.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../constants.dart';
import '../theme.dart';

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const StatusBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

IconData equipmentIcon(String category) {
  switch (category.toLowerCase()) {
    case 'electronics':     return Icons.electric_bolt_rounded;
    case 'tools':           return Icons.build_rounded;
    case 'measurement':     return Icons.straighten_rounded;
    case 'optics':          return Icons.remove_red_eye_rounded;
    case 'microcontroller': return Icons.memory_rounded;
    default:                return Icons.science_outlined;
  }
}


// Equipment photo thumbnail. Students rely on the photo to confirm they are
// requesting — and being handed — the right item, so every list that names a
// piece of equipment should show it. Falls back to a category icon when no
// photo was uploaded or the bytes cannot be decoded.
class EquipmentThumb extends StatelessWidget {
  final Uint8List? bytes;
  final String category;
  final Color color;
  final double size;
  const EquipmentThumb({
    super.key,
    required this.bytes,
    required this.category,
    required this.color,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 4;
    final fallback = Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(equipmentIcon(category), color: color, size: size / 2),
    );
    final data = bytes;
    if (data == null || data.isEmpty) return fallback;
    // Decode straight to the display size rather than the stored 192px: a list
    // of these otherwise holds full-resolution bitmaps in memory.
    final cachePx =
        (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.memory(
        data,
        width: size, height: size, fit: BoxFit.cover,
        cacheWidth: cachePx,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader({super.key, required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark)),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Text(action!,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

class SectionDivider extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const SectionDivider(
      {super.key, required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color)),
        const SizedBox(width: 12),
        const Expanded(child: Divider(color: AppTheme.divider)),
      ],
    );
  }
}

Widget FieldLabel(String label) => Text(label,
    style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppTheme.textDark));

// Confirm a request rejection and collect an optional reason for the student.
// Returns the (trimmed, possibly empty) reason, or null if cancelled. Shared by
// the Requests screen and the Dashboard so both Deny paths ask first.
Future<String?> showRejectRequestDialog(BuildContext context) async {
  final reasonCtrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (dCtx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Reject Request'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Optionally add a reason the student will see.',
            style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
        const SizedBox(height: 12),
        TextField(
          controller: reasonCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
              hintText: 'e.g. Equipment reserved for a class'),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
        ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Reject')),
      ],
    ),
  );
  // Not disposed here: the dialog's TextField is still mounted during its exit
  // animation, after this future has already completed.
  return ok == true ? reasonCtrl.text.trim() : null;
}

class SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  const SectionTitle({super.key, required this.title, required this.icon, required this.color});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
            color: color.withAlpha(31),
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: color, size: 15),
      ),
      const SizedBox(width: 8),
      Text(title, style: TextStyle(
          fontSize: 14, fontWeight: FontWeight.bold, color: color)),
    ]);
  }
}

class AlertCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, body;
  const AlertCard({super.key, required this.icon, required this.color,
      required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 4)),
        boxShadow: [BoxShadow(color: color.withAlpha(15),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
              color: color.withAlpha(26),
              borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: color, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold,
                color: Color(0xFF1A1D2E))),
            const SizedBox(height: 2),
            Text(body, style: const TextStyle(
                fontSize: 12, color: Color(0xFF6B7280), height: 1.3)),
          ])),
      ]),
    );
  }
}

class EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  const EmptyCard({super.key, required this.icon, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: const Color(0x08000000),
              blurRadius: 8, offset: const Offset(0, 2))]),
      child: Center(child: Column(children: [
        Icon(icon, size: 36, color: const Color(0xFF9CA3AF)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 14,
            color: Color(0xFF374151))),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(
            fontSize: 12, color: Color(0xFF9CA3AF))),
      ])),
    );
  }
}

Widget specRow(String label, String value,
    {bool isFirst = false, bool isLast = false}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      border: Border(
        top: isFirst ? BorderSide.none : const BorderSide(color: AppTheme.divider),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMid,
                  fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textDark,
                  fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}


// Label/value row used by the staff student-detail and equipment-registration
// screens. Promoted here when the staff cluster was split, since three screens
// in two different libraries use it.
class DetailRow extends StatelessWidget {
  final String label, value;
  const DetailRow({super.key, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textDark)),
        ],
      ),
    );
  }
}

// A tap-to-pick calendar date that may stay empty, e.g. an equipment's date
// acquired, which the lab's records often do not have. Past dates only; the
// clear button sets it back to empty. Used by Register Equipment and
// Inventory → Edit.
class DateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final String hint;
  const DateField(
      {super.key, required this.value, required this.onChanged, this.hint = 'Unknown'});

  @override
  Widget build(BuildContext context) {
    final v = value;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: v != null && v.isBefore(now) ? v : now,
          firstDate: DateTime(1950),
          lastDate: now,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.event_outlined, color: AppTheme.textMid),
          suffixIcon: v == null
              ? null
              : IconButton(
                  tooltip: 'Clear date',
                  icon: const Icon(Icons.close_rounded, size: 18, color: AppTheme.textMid),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(v == null ? hint : formatDate(v),
            style: TextStyle(
                fontSize: 14,
                color: v == null ? AppTheme.textLight : AppTheme.textDark)),
      ),
    );
  }
}


// ─── Wide windows (the web staff portal) ──────────────────────────────────────
// The web build fills the browser window (2026-10-06), so lists of cards lay
// out in rows of cards there. A phone is too narrow for more than one column
// and keeps the plain list it always had.

/// How many cards at least [minWidth] wide fit across [width] (1 to [max]).
int gridColumns(double width, {double minWidth = 440, int max = 4}) {
  final fit = (width + 12) ~/ (minWidth + 12);
  return fit < 1 ? 1 : (fit > max ? max : fit);
}

/// One row of a card grid: [cells] side by side at equal widths, all as tall
/// as the tallest. A short last row leaves its remaining columns empty.
class GridRow extends StatelessWidget {
  final List<Widget> cells;
  final int columns;
  const GridRow({super.key, required this.cells, required this.columns});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < columns; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: i < cells.length ? cells[i] : const SizedBox.shrink()),
          ],
        ],
      ),
    );
  }
}

/// Row [row] of a lazily built list of [count] cards in [columns]: the cards
/// from [cardAt] as a [GridRow], or the single card when [columns] is 1.
Widget gridRow(int row, int columns, int count, Widget Function(int i) cardAt) {
  final cells = [
    for (var i = row * columns; i < (row + 1) * columns && i < count; i++)
      cardAt(i),
  ];
  return columns == 1 ? cells.single : GridRow(columns: columns, cells: cells);
}

/// [cards] grouped into [GridRow]s of [columns]; unchanged when [columns] is 1.
List<Widget> gridRows(List<Widget> cards, int columns) {
  if (columns <= 1) return cards;
  return [
    for (var i = 0; i < cards.length; i += columns)
      GridRow(
        columns: columns,
        cells: cards.sublist(
            i, i + columns < cards.length ? i + columns : cards.length),
      ),
  ];
}

/// [padding] with its sides widened so a form or detail page sits centred at
/// no more than [maxWidth] in a wide window. Used as the page's scroll padding,
/// so the whole window still scrolls. A phone gets [padding] unchanged.
EdgeInsets readablePadding(BuildContext context, EdgeInsets padding,
    {double maxWidth = 760}) {
  final side = (MediaQuery.sizeOf(context).width - maxWidth) / 2;
  return padding.copyWith(
    left: side > padding.left ? side : padding.left,
    right: side > padding.right ? side : padding.right,
  );
}
