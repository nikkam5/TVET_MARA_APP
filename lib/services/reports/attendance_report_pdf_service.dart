import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../models/attendance_report.dart';

class AttendanceReportPdfService {
  AttendanceReportPdfService._();

  static Future<Uint8List> build({
    required List<StaffAttendanceReport> reports,
    required String periodLabel,
  }) async {
    final regular = await rootBundle.load('assets/fonts/OpenSans-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/OpenSans-Bold.ttf');
    final document = pw.Document(
      theme: pw.ThemeData.withFont(
        base: pw.Font.ttf(regular),
        bold: pw.Font.ttf(bold),
      ),
      title: 'TVET MARA Attendance Report - $periodLabel',
      author: 'TVET MARA Staff App',
    );
    final generated = DateTime.now();

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => _header(periodLabel, generated),
        footer: (context) => _footer(context),
        build: (context) => [
          pw.Text(
            'Attendance Summary',
            style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Staff',
              'Department',
              'Expected',
              'Present',
              'Late',
              'Leave',
              'Absent',
              'Pending',
              'No Punch-out',
              'Rate',
            ],
            data: reports
                .map(
                  (report) => [
                    '${report.name}\n${report.staffNumber}',
                    report.department,
                    '${report.expectedDays}',
                    '${report.present}',
                    '${report.late}',
                    '${report.approvedLeave}',
                    '${report.absent}',
                    '${report.pendingLate}',
                    '${report.missingPunchOut}',
                    '${report.attendanceRate.toStringAsFixed(1)}%',
                  ],
                )
                .toList(),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xff002060),
            ),
            headerStyle: pw.TextStyle(
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellPadding: const pw.EdgeInsets.all(5),
            columnWidths: {
              0: const pw.FlexColumnWidth(2.1),
              1: const pw.FlexColumnWidth(1.8),
            },
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            'Calculation: Sunday-Thursday workdays only. Approved leave is excluded '
            'from the attendance-rate denominator. Public holidays are not excluded.',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    if (reports.length == 1) {
      final report = reports.single;
      document.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          header: (context) => _header(periodLabel, generated),
          footer: (context) => _footer(context),
          build: (context) => [
            pw.Text(
              report.name,
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '${report.staffNumber} | ${report.department} | ${report.position}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 14),
            pw.TableHelper.fromTextArray(
              headers: const ['Date', 'Punch In', 'Punch Out', 'Status'],
              data: report.days
                  .map(
                    (day) => [
                      _date(day.date),
                      _time(day.punchIn),
                      _time(day.punchOut),
                      day.leaveType == null
                          ? day.status
                          : '${day.status} (${day.leaveType})',
                    ],
                  )
                  .toList(),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColor.fromInt(0xff002060),
              ),
              headerStyle: pw.TextStyle(
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.all(4),
            ),
          ],
        ),
      );
    }
    return document.save();
  }

  static Future<bool> share({
    required List<StaffAttendanceReport> reports,
    required String periodLabel,
  }) async {
    final bytes = await build(reports: reports, periodLabel: periodLabel);
    final safePeriod = periodLabel.replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '_');
    return Printing.sharePdf(
      bytes: bytes,
      filename: 'attendance_$safePeriod.pdf',
    );
  }

  static Future<void> printReport({
    required List<StaffAttendanceReport> reports,
    required String periodLabel,
  }) async {
    final bytes = await build(reports: reports, periodLabel: periodLabel);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'Attendance $periodLabel',
    );
  }

  static pw.Widget _header(String period, DateTime generated) => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 14),
    padding: const pw.EdgeInsets.only(bottom: 8),
    decoration: const pw.BoxDecoration(
      border: pw.Border(
        bottom: pw.BorderSide(color: PdfColor.fromInt(0xff002060)),
      ),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'TVET MARA',
          style: pw.TextStyle(
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
            color: const PdfColor.fromInt(0xff002060),
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'Attendance Report',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '$period | Generated ${_date(generated)}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ],
        ),
      ],
    ),
  );

  static pw.Widget _footer(pw.Context context) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Text('INTERNAL USE ONLY', style: const pw.TextStyle(fontSize: 7)),
      pw.Text(
        'Page ${context.pageNumber} of ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 7),
      ),
    ],
  );

  static String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  static String _time(DateTime? date) => date == null
      ? '-'
      : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
