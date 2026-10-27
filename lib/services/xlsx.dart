// -----------------------------------------------------------------------------
// LabTrack - a small .xlsx writer
//
// Added 2026-10-06 for the Reports workbook (report_xlsx.dart). An .xlsx file
// is a zip of a few XML parts; this writes just the parts the report needs:
// text, numbers, real dates, bold headers, column widths and a frozen,
// filterable header row. The `excel` package would have pulled the photo
// code's `image` package back two versions, so this is done directly with
// `archive`, which the app already had. Pure Dart: unit-tested.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import 'package:archive/archive.dart';

// One cell: a String, a num, a DateTime (stored as a real Excel date), or
// null for an empty cell, with one of the Xlsx.* styles.
class XCell {
  final Object? value;
  final int style;
  const XCell(this.value, [this.style = Xlsx.normal]);
}

class XSheet {
  final String name;
  final List<List<XCell?>> rows;
  // Column widths in characters, from column A.
  final List<double> widths;
  // Freeze row 1 and put filter buttons on it (a table of records).
  final bool tableHeader;
  const XSheet(this.name, this.rows, {this.widths = const [], this.tableHeader = false});
}

class Xlsx {
  // Styles (the order of cellXfs in styles.xml).
  static const normal = 0, header = 1, dateTime = 2, title = 3, percent = 4,
      note = 5, bold = 6, wrap = 7;

  static Uint8List build(List<XSheet> sheets) {
    final archive = Archive();
    void add(String name, String xml) => archive.addFile(ArchiveFile.string(name, xml));

    add('[Content_Types].xml', _contentTypes(sheets.length));
    add('_rels/.rels', _rootRels);
    add('xl/workbook.xml', _workbook(sheets));
    add('xl/_rels/workbook.xml.rels', _workbookRels(sheets.length));
    add('xl/styles.xml', _styles);
    for (var i = 0; i < sheets.length; i++) {
      add('xl/worksheets/sheet${i + 1}.xml', sheetXml(sheets[i]));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  // "A", "B", ... "Z", "AA" for column [i] (from 0).
  static String column(int i) {
    var s = '';
    for (var n = i + 1; n > 0; n = (n - 1) ~/ 26) {
      s = String.fromCharCode(65 + (n - 1) % 26) + s;
    }
    return s;
  }

  // Excel's day number for a wall-clock time: days since 1899-12-30, the
  // time of day as the fraction. Taken from the local date and time as
  // written, so a daylight-saving change cannot shift it.
  static double serial(DateTime t) {
    final wall = DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
    return wall.difference(DateTime.utc(1899, 12, 30)).inSeconds / 86400;
  }

  // Text for XML, without the control characters XML forbids.
  static String esc(String s) => s
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String sheetXml(XSheet sheet) {
    final b = StringBuffer(_xmlHead)
      ..write('<worksheet xmlns="$_main" xmlns:r="$_rel">');
    if (sheet.tableHeader) {
      b.write('<sheetViews><sheetView workbookViewId="0">'
          '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
          '</sheetView></sheetViews>');
    }
    if (sheet.widths.isNotEmpty) {
      b.write('<cols>');
      for (var i = 0; i < sheet.widths.length; i++) {
        b.write('<col min="${i + 1}" max="${i + 1}" width="${sheet.widths[i]}" customWidth="1"/>');
      }
      b.write('</cols>');
    }
    b.write('<sheetData>');
    var lastCol = 0;
    for (var r = 0; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      b.write('<row r="${r + 1}">');
      for (var c = 0; c < row.length; c++) {
        final cell = row[c];
        if (cell == null) continue;
        if (c > lastCol) lastCol = c;
        b.write(_cell('${column(c)}${r + 1}', cell));
      }
      b.write('</row>');
    }
    b.write('</sheetData>');
    if (sheet.tableHeader && sheet.rows.isNotEmpty) {
      b.write('<autoFilter ref="A1:${column(lastCol)}${sheet.rows.length}"/>');
    }
    b.write('<pageMargins left="0.5" right="0.5" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>'
        '<pageSetup orientation="landscape"/>'
        '</worksheet>');
    return b.toString();
  }

  static String _cell(String ref, XCell cell) {
    final v = cell.value;
    final s = cell.style == normal ? '' : ' s="${cell.style}"';
    if (v == null) return '<c r="$ref"$s/>';
    if (v is DateTime) return '<c r="$ref"$s><v>${serial(v)}</v></c>';
    if (v is num) return '<c r="$ref"$s><v>$v</v></c>';
    // Text is written inline: no shared-strings part to keep in step, and a
    // typed value that looks like a formula ("=...") stays text.
    return '<c r="$ref" t="inlineStr"$s><is><t xml:space="preserve">${esc('$v')}</t></is></c>';
  }

  static const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  static const _main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  static const _rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const _pkgRel = 'http://schemas.openxmlformats.org/package/2006/relationships';

  static String _contentTypes(int sheets) => '$_xmlHead'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '${[
        for (var i = 1; i <= sheets; i++)
          '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      ].join()}'
      '</Types>';

  static const _rootRels = '$_xmlHead'
      '<Relationships xmlns="$_pkgRel">'
      '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';

  static String _workbook(List<XSheet> sheets) {
    final names = StringBuffer();
    for (var i = 0; i < sheets.length; i++) {
      final s = sheets[i];
      if (!s.tableHeader || s.rows.isEmpty) continue;
      final width = s.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
      // Excel keeps a filter's range under this hidden name.
      names.write('<definedName name="_xlnm._FilterDatabase" localSheetId="$i" hidden="1">'
          "'${esc(s.name.replaceAll("'", "''"))}'!\$A\$1:\$${column(width - 1)}\$${s.rows.length}"
          '</definedName>');
    }
    return '$_xmlHead'
        '<workbook xmlns="$_main" xmlns:r="$_rel"><sheets>'
        '${[
          for (var i = 0; i < sheets.length; i++)
            '<sheet name="${esc(sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'
        ].join()}'
        '</sheets>'
        '${names.isEmpty ? '' : '<definedNames>$names</definedNames>'}'
        '</workbook>';
  }

  static String _workbookRels(int sheets) => '$_xmlHead'
      '<Relationships xmlns="$_pkgRel">'
      '${[
        for (var i = 1; i <= sheets; i++)
          '<Relationship Id="rId$i" Type="$_rel/worksheet" Target="worksheets/sheet$i.xml"/>'
      ].join()}'
      '<Relationship Id="rId${sheets + 1}" Type="$_rel/styles" Target="styles.xml"/>'
      '</Relationships>';

  // normal, header (bold on light blue), dateTime, title (bold 14), percent,
  // note (grey italic, wrapped), bold, wrap.
  static const _styles = '$_xmlHead'
      '<styleSheet xmlns="$_main">'
      '<numFmts count="1"><numFmt numFmtId="164" formatCode="mmm d, yyyy h:mm AM/PM"/></numFmts>'
      '<fonts count="4">'
      '<font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
      '<font><b/><sz val="14"/><name val="Calibri"/><family val="2"/></font>'
      '<font><i/><sz val="10"/><color rgb="FF5A6A8A"/><name val="Calibri"/><family val="2"/></font>'
      '</fonts>'
      '<fills count="3">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F5"/><bgColor indexed="64"/></patternFill></fill>'
      '</fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="8">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'
      '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="left"/></xf>'
      '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '<xf numFmtId="9" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
      '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>'
      '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>'
      '</cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';
}
