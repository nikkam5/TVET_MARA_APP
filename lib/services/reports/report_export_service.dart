import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// --- Report export ----------------------------------------------------
///
/// Turns plain table data into the two artefacts the admin console hands
/// out: a **PDF** (print-clean, black/white, Open Sans embedded) and a
/// **CSV** that Excel opens natively (UTF-8 BOM so Malay names and the
/// em-dash placeholders survive the round-trip).
///
/// No extra plugins: delivery rides on `printing`, whose platform
/// implementations hand the finished file to the OS —
///
///  * web   → a real `download` link (`.pdf` / `.csv` lands in Downloads)
///  * Windows/Linux → the file is written to `%TEMP%` and opened with the
///    default handler, so `.csv` opens straight into Excel
///  * Android/iOS → the system share sheet ("Save to Drive / Files")
///
/// and every path falls back gracefully (print layout → clipboard) instead
/// of throwing, so the export buttons can never crash the dashboard.

/// One table inside an exported report.
class ReportSection {
  const ReportSection({
    required this.title,
    this.note,
    required this.headers,
    required this.rows,
  });

  /// Section heading printed above the table (and used as the CSV banner).
  final String title;

  /// Optional one-line description under the heading.
  final String? note;

  final List<String> headers;

  /// One `[headers.length]`-long list per row. Cells are rendered as-is.
  final List<List<String>> rows;

  int get columnCount => headers.length;
}

class ReportExporter {
  ReportExporter._();

  /// Filesystem-safe file stem for a report title.
  static String slug(String title) {
    final cleaned = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return cleaned.isEmpty ? 'tvet-mara-report' : cleaned;
  }

  static String _nowLabel() {
    final now = DateTime.now();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '${now.day} ${months[now.month - 1]} ${now.year}, $hh:$mm';
  }

  /// RFC-4180 quoting: fields carrying a comma, quote or newline are
  /// quoted, embedded quotes are doubled.
  static String _cell(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  /// Builds the CSV payload for a set of sections. Sections are stacked
  /// with a banner line each, so one download covers the whole export.
  static String buildCsv({
    required String title,
    required String subtitle,
    required List<ReportSection> sections,
  }) {
    final buffer = StringBuffer()
      ..writeln('\uFEFF$title') // UTF-8 BOM — Excel reads the encoding right
      ..writeln(subtitle)
      ..writeln('Generated: ${_nowLabel()}');
    for (final section in sections) {
      buffer
        ..writeln()
        ..writeln(section.title);
      if (section.note != null && section.note!.isNotEmpty) {
        buffer.writeln(section.note);
      }
      buffer.writeln(section.headers.map(_cell).join(','));
      for (final row in section.rows) {
        buffer.writeln(row.map(_cell).join(','));
      }
    }
    return buffer.toString();
  }

  static Future<pw.ImageProvider?> _loadLogo() async {
    try {
      final bytes = await rootBundle.load('assets/images/tvetmara_logo.png');
      return pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {
      return null; // the PDF still renders with a text wordmark
    }
  }

  /// Builds the PDF bytes for a report — A4, portrait, one table per
  /// section, black & white so it prints cleanly on any office printer.
  static Future<Uint8List> buildPdf({
    required String title,
    required String subtitle,
    required List<ReportSection> sections,
  }) async {
    // Open Sans is bundled as an app asset (assets/fonts/) and embedded so
    // the export works offline and keeps full Unicode (Malay names, "—").
    pw.Font? base;
    pw.Font? bold;
    try {
      final regular = await rootBundle.load(
        'assets/fonts/OpenSans-Regular.ttf',
      );
      final strong = await rootBundle.load('assets/fonts/OpenSans-Bold.ttf');
      base = pw.Font.ttf(regular);
      bold = pw.Font.ttf(strong);
    } catch (_) {
      // Helvetica fallback — loses exotic glyphs but still exports.
      base = null;
      bold = null;
    }
    final logo = await _loadLogo();

    final doc = pw.Document(
      theme: (base != null && bold != null)
          ? pw.ThemeData.withFont(base: base, bold: bold)
          : null,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(40, 44, 40, 40),
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox.shrink()
            : _runningHead(title),
        footer: (context) => _runningFoot(context.pageNumber),
        build: (context) => [
          _titleBlock(title: title, subtitle: subtitle, logo: logo),
          for (final section in sections) ...[
            pw.SizedBox(height: 16),
            _sectionHeading(section),
            pw.SizedBox(height: 5),
            _table(section),
          ],
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
            ),
            child: pw.Text(
              'This report was generated automatically by the TVET MARA Staff '
              'Management System from live attendance, staffing and approval '
              'records.',
              style: const pw.TextStyle(
                fontSize: 7.5,
                color: PdfColors.grey700,
              ),
            ),
          ),
        ],
      ),
    );
    return doc.save();
  }

  static pw.Widget _runningHead(String title) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.6),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'TVET MARA · $title',
            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(
            'Official system report',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    );
  }

  static pw.Widget _runningFoot(int pageNumber) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'Generated: ${_nowLabel()} · TVET MARA Administration',
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
        ),
        pw.Text(
          'Page $pageNumber',
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
        ),
      ],
    );
  }

  static pw.Widget _titleBlock({
    required String title,
    required String subtitle,
    pw.ImageProvider? logo,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Container(
              height: 46,
              width: 62,
              alignment: pw.Alignment.center,
              child: logo != null
                  ? pw.Image(logo, fit: pw.BoxFit.contain)
                  : pw.Center(
                      child: pw.Text(
                        'TVET\nMARA',
                        textAlign: pw.TextAlign.center,
                        style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          fontSize: 9,
                        ),
                      ),
                    ),
            ),
            pw.SizedBox(width: 12),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'TVETMARA BESUT',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  pw.Text(
                    'Administration',
                    style: const pw.TextStyle(
                      fontSize: 8.5,
                      color: PdfColors.grey700,
                    ),
                  ),
                  pw.SizedBox(height: 8),
                  pw.Text(
                    title,
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  pw.Text(
                    subtitle,
                    style: const pw.TextStyle(
                      fontSize: 8.5,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        pw.Container(height: 1.4, color: PdfColors.black),
        pw.SizedBox(height: 8),
      ],
    );
  }

  static pw.Widget _sectionHeading(ReportSection section) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          section.title,
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10.5),
        ),
        if (section.note != null && section.note!.isNotEmpty)
          pw.Text(
            section.note!,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
      ],
    );
  }

  /// A hairline table whose columns are weighted by their widest entry, so
  /// long names get room instead of being crushed into equal columns.
  static pw.Widget _table(ReportSection section) {
    final widths = <int, double>{};
    for (var c = 0; c < section.headers.length; c++) {
      var widest = section.headers[c].length;
      for (final row in section.rows) {
        if (c < row.length && row[c].length > widest) widest = row[c].length;
      }
      widths[c] = widest.clamp(6, 42).toDouble();
    }

    pw.Widget cell(String text, {required bool header, required bool shaded}) {
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        decoration: pw.BoxDecoration(
          color: header
              ? PdfColors.grey900
              : shaded
              ? PdfColors.grey100
              : PdfColors.white,
          border: pw.Border.all(color: PdfColors.grey400, width: 0.4),
        ),
        child: pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: header ? 8 : 8.2,
            fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: header ? PdfColors.white : PdfColors.black,
          ),
        ),
      );
    }

    return pw.Table(
      columnWidths: {
        for (final entry in widths.entries)
          entry.key: pw.FlexColumnWidth(entry.value),
      },
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.top,
      children: [
        pw.TableRow(
          children: [
            for (final h in section.headers)
              cell(h, header: true, shaded: false),
          ],
        ),
        for (var r = 0; r < section.rows.length; r++)
          pw.TableRow(
            children: [
              for (var c = 0; c < section.headers.length; c++)
                cell(
                  c < section.rows[r].length ? section.rows[r][c] : '—',
                  header: false,
                  shaded: r.isOdd,
                ),
            ],
          ),
      ],
    );
  }

  /// Small floating confirmation used by both export paths.
  ///
  /// Takes the messenger captured *before* the first `await` so no build
  /// context is touched across an async gap.
  static void _toast(
    ScaffoldMessengerState? messenger,
    String message, {
    bool error = false,
  }) {
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(color: Colors.white)),
          backgroundColor: error
              ? const Color(0xFFC0392B)
              : const Color(0xFF0F172A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.all(14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
  }

  /// Hands a finished PDF to the OS (share sheet / downloads / viewer).
  static Future<void> exportPdf({
    required BuildContext context,
    required String title,
    required String subtitle,
    required List<ReportSection> sections,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final bytes = await buildPdf(
        title: title,
        subtitle: subtitle,
        sections: sections,
      );
      final file = '${slug(title)}.pdf';

      // 1) Direct hand-off: web downloads it, desktop opens it, mobile
      //    shares it — one call, correct extension on every platform.
      try {
        final delivered = await Printing.sharePdf(bytes: bytes, filename: file);
        if (delivered) {
          _toast(messenger, 'PDF report ready — $file');
          return;
        }
      } catch (_) {
        // Platform has no share implementation → fall back to the print
        // layout, whose dialog always offers "Save as PDF".
      }

      // 2) Print/preview layout — the classic save-as-PDF path.
      await Printing.layoutPdf(onLayout: (_) async => bytes);
      _toast(messenger, 'PDF report ready — choose "Save as PDF" to download.');
    } catch (e) {
      _toast(messenger, 'Could not export the PDF report: $e', error: true);
    }
  }

  /// Exports the same data as an Excel-friendly CSV.
  static Future<void> exportCsv({
    required BuildContext context,
    required String title,
    required String subtitle,
    required List<ReportSection> sections,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final csv = buildCsv(title: title, subtitle: subtitle, sections: sections);
    final file = '${slug(title)}.csv';
    try {
      final bytes = Uint8List.fromList(utf8.encode(csv));
      final delivered = await Printing.sharePdf(bytes: bytes, filename: file);
      if (delivered) {
        _toast(messenger, 'Spreadsheet ready — $file');
        return;
      }
    } catch (_) {
      // No file hand-off available here → clipboard instead.
    }
    try {
      await Clipboard.setData(ClipboardData(text: csv));
      _toast(
        messenger,
        'CSV copied to clipboard — paste it into Excel and save as .csv',
      );
    } catch (e) {
      _toast(messenger, 'Could not export the spreadsheet: $e', error: true);
    }
  }
}
