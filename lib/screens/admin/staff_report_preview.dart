import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/shared/lucide_icon.dart';
import '../../models/attendance_report.dart';
import '../../utils/malaysia_time.dart';

/// Modal preview + print/export of one staff member's official report.
///
/// Shows the staff's complete profile summary, attendance history and
/// leave/logbook records laid out in the TVET MARA official report format
/// (same structure as the staff-side report generator preview).
///
/// The on-screen preview is intentionally styled like a sheet of paper —
/// black-and-white with clean corporate borders — so what the admin sees
/// matches what comes out of the printer / PDF export.
class StaffReportPreview extends StatefulWidget {
  /// Staff row from `getStaffDirectoryFull()` — must include the joined
  /// `departments(name)` map.
  final Map<String, dynamic> staff;

  const StaffReportPreview({super.key, required this.staff});

  /// Opens the report as a centred modal dialog. Keeps the dashboard
  /// context alive so no navigation stack juggling is needed.
  static Future<void> show(BuildContext context, Map<String, dynamic> staff) {
    return showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: const Color(
          0xFF5A5F6B,
        ), // dark "desktop" behind the paper
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: StaffReportPreview(staff: staff),
        ),
      ),
    );
  }

  @override
  State<StaffReportPreview> createState() => _StaffReportPreviewState();
}

class _StaffReportPreviewState extends State<StaffReportPreview> {
  bool _isLoading = true;
  String? _loadError;
  bool _isPrinting = false;

  Map<String, int> _monthStats = const {};
  Map<String, int> _sixMonthStats = const {};
  List<Map<String, dynamic>> _attendance = const [];
  List<Map<String, dynamic>> _leaves = const [];

  String get _name => (widget.staff['full_name'] as String?) ?? 'Unknown';
  String get _staffNum => (widget.staff['staff_number'] as String?) ?? '—';
  String get _deptName =>
      (widget.staff['departments']?['name'] as String?) ?? '—';
  String get _generatedDate => _fmtDate(MalaysiaTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final staffId = widget.staff['id'] as String?;
    if (staffId == null) {
      setState(() {
        _loadError = 'Missing staff id.';
        _isLoading = false;
      });
      return;
    }
    try {
      final period = ReportPeriod.recent().first;
      final results = await Future.wait([
        DatabaseService.getStaffAttendanceStats(staffId),
        DatabaseService.getStaffAttendanceStats(staffId, since: period.start),
        DatabaseService.getAttendanceForReport(
          staffId: staffId,
          start: period.start,
          end: period.end,
        ),
        DatabaseService.getLeavesForStaff(staffId),
      ]);
      if (!mounted) return;
      setState(() {
        _monthStats = Map<String, int>.from(results[0] as Map);
        _sixMonthStats = Map<String, int>.from(results[1] as Map);
        _attendance = (results[2] as List<Map<String, dynamic>>).reversed
            .toList();
        _leaves = results[3] as List<Map<String, dynamic>>;
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  // ── Print / Export ────────────────────────────────────────────────────
  Future<void> _print() async {
    if (_isPrinting) return;
    setState(() => _isPrinting = true);
    try {
      pw.ImageProvider? logo;
      try {
        final bytes = await rootBundle.load('assets/images/tvetmara_logo.png');
        logo = pw.MemoryImage(bytes.buffer.asUint8List());
      } on Exception {
        logo = null; // report still renders with a text wordmark
      }
      final doc = _buildPdfDocument(logo);
      // layout() → on web opens the browser's print preview in a new tab;
      // on desktop/mobile opens the OS print/share sheet (save-to-PDF
      // included). Either way: print on paper or export as PDF.
      await Printing.layoutPdf(onLayout: (_) => doc);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Print failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  Future<Uint8List> _buildPdfDocument(pw.ImageProvider? logo) async {
    final data = StaffReportData(
      name: _name,
      staffNumber: _staffNum,
      department: _deptName,
      icNumber: (widget.staff['ic_number'] as String?) ?? '-',
      position:
          '${widget.staff['position'] ?? '-'} · ${widget.staff['staff_grade'] ?? '-'}',
      program: (widget.staff['teaching_course'] as String?) ?? '-',
      email: (widget.staff['email'] as String?) ?? '-',
      role: (widget.staff['role'] as String?) ?? 'staff',
      isActive: (widget.staff['is_active'] as bool?) ?? true,
      generatedDate: _generatedDate,
      monthStats: _monthStats,
      sixMonthStats: _sixMonthStats,
      attendance: _attendance,
      leaves: _leaves,
    );
    return buildStaffReportPdf(data, logo);
  }

  // ── Formatting helpers (shared by preview + PDF via _ReportData) ──────
  static String _fmtDate(DateTime d) {
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
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// UTC punch timestamp → Malaysia wall-clock, "25 Sep 2026 · 7:58 AM".
  static String fmtPunch(String? iso, {bool withDate = true}) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toUtc().add(const Duration(hours: 8));
    if (dt == null) return '—';
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    final time = '$h12:${dt.minute.toString().padLeft(2, '0')} $ampm';
    if (!withDate) return time;
    return '${_fmtDate(dt)} · $time';
  }

  static String fmtDay(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toUtc().add(const Duration(hours: 8));
    return dt == null ? '—' : _fmtDate(dt);
  }

  static String cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static String attendanceStatus(Map<String, dynamic> row) {
    final status = row['status'] as String?;
    if ((status == 'present' || status == 'late') &&
        row['late_approved'] != true) {
      return 'Pending late approval';
    }
    return cap(status ?? '—');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToolbar(),
        Flexible(
          child: _isLoading
              ? const SizedBox(
                  height: 320,
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                )
              : _loadError != null
              ? SizedBox(
                  height: 320,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.white,
                          size: 40,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Failed to load report: $_loadError',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _isLoading = true;
                              _loadError = null;
                            });
                            _load();
                          },
                          child: const Text(
                            'Retry',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  // The "paper" is A4-width (794px). On screens narrower
                  // than that (phone), scroll horizontally instead of
                  // overflowing — the table columns stay A4-proportioned.
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Center(child: _buildPaper()),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    // Below ~520px the full "Print / Export PDF" label doesn't leave room
    // for the title (and on very narrow phones it overflows outright), so
    // the button collapses to its printer icon — still tooltip-labeled.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFF3C4048),
          child: Row(
            children: [
              const Icon(
                Icons.description_outlined,
                color: Colors.white,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Staff Report — $_name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              Tooltip(
                message: 'Print / Export staff report',
                child: TextButton.icon(
                  onPressed: (_isLoading || _loadError != null || _isPrinting)
                      ? null
                      : _print,
                  icon: _isPrinting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : LucideIcon(LucideIcon.printerPaths, size: 15),
                  label: compact
                      ? const SizedBox.shrink()
                      : Text(
                          _isPrinting
                              ? 'Preparing…'
                              : (kIsWeb
                                    ? 'Print / Save PDF'
                                    : 'Print / Export PDF'),
                        ),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: AppTheme.navy,
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 10 : 14,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: LucideIcon(
                  LucideIcon.xPaths,
                  size: 18,
                  color: Colors.white,
                ),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The "sheet of paper" — pure black & white, thin corporate borders,
  /// so the on-screen preview prints cleanly even if the user prints via
  /// the browser's Ctrl+P instead of the PDF pipeline.
  Widget _buildPaper() {
    const border = BorderSide(color: Color(0xFF9E9E9E), width: 0.8);
    return Container(
      width: 794, // ≈ A4 at 96dpi
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _paperHeader(border),
          const SizedBox(height: 18),
          _sectionRule('1', 'MAKLUMAT STAF / STAFF PROFILE SUMMARY'),
          const SizedBox(height: 10),
          _profileTable(border),
          const SizedBox(height: 18),
          _sectionRule('2', 'RINGKASAN KEHADIRAN / ATTENDANCE SUMMARY'),
          const SizedBox(height: 10),
          _attendanceSummary(border),
          const SizedBox(height: 18),
          _sectionRule('3', 'SEJARAH KEHADIRAN / ATTENDANCE HISTORY'),
          const SizedBox(height: 10),
          _attendanceTable(border),
          const SizedBox(height: 18),
          _sectionRule('4', 'REKOD CUTI & LOGBUK / LEAVE & LOGBOOK REPORTS'),
          const SizedBox(height: 10),
          _leaveTable(border),
          const SizedBox(height: 24),
          _signOff(),
          const SizedBox(height: 18),
          _paperFooter(border),
        ],
      ),
    );
  }

  Widget _paperHeader(BorderSide border) {
    return Container(
      padding: const EdgeInsets.only(bottom: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black, width: 2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 52,
            width: 96,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(border: Border.all(color: Colors.black)),
            child: Image.asset(
              'assets/images/tvetmara_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (c, e, s) => const Center(
                child: Text(
                  'TVET\nMARA',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TVETMARA BESUT',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    letterSpacing: 0.5,
                  ),
                ),
                const Text(
                  'Institut Kemahiran MARA',
                  style: TextStyle(fontSize: 11, color: Colors.black87),
                ),
                const SizedBox(height: 8),
                const Text(
                  'LAPORAN RASMI STAF / OFFICIAL STAFF REPORT',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                Text(
                  'Profil, Kehadiran & Rekod Cuti · Generated: $_generatedDate',
                  style: const TextStyle(fontSize: 10, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionRule(String number, String title) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 1.2),
          ),
          child: Text(
            number,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 1, color: Colors.black54)),
      ],
    );
  }

  TableRow _kvRow(String k1, String v1, String k2, String v2, BorderSide b) {
    Widget cell(String text, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
    return TableRow(
      children: [
        cell(k1, bold: true),
        cell(v1),
        cell(k2, bold: true),
        cell(v2),
      ],
    );
  }

  Widget _profileTable(BorderSide border) {
    final s = widget.staff;
    return Table(
      border: TableBorder(
        top: border,
        bottom: border,
        left: border,
        right: border,
        horizontalInside: border,
        verticalInside: border,
      ),
      columnWidths: const {
        0: FlexColumnWidth(1.1),
        1: FlexColumnWidth(1.9),
        2: FlexColumnWidth(1.1),
        3: FlexColumnWidth(1.9),
      },
      children: [
        _kvRow('Nama / Name', _name, 'No. Gaji / Staff ID', _staffNum, border),
        _kvRow(
          'No. IC / IC No.',
          (s['ic_number'] as String?) ?? '—',
          'Jawatan / Position',
          '${s['position'] ?? '—'} · ${s['staff_grade'] ?? '—'}',
          border,
        ),
        _kvRow(
          'Jabatan / Department',
          _deptName,
          'Program / Course',
          (s['teaching_course'] as String?) ?? '—',
          border,
        ),
        _kvRow(
          'Emel / Email',
          (s['email'] as String?) ?? '—',
          'Status',
          ((s['is_active'] as bool?) ?? true)
              ? 'Aktif / Active'
              : 'Tidak Aktif / Inactive',
          border,
        ),
      ],
    );
  }

  Widget _attendanceSummary(BorderSide border) {
    final total6 = _sixMonthStats['total'] ?? 0;
    final present6 = _sixMonthStats['present'] ?? 0;
    final late6 = _sixMonthStats['late'] ?? 0;
    final absent6 = _sixMonthStats['absent'] ?? 0;
    final attended = present6 + late6;
    final target = _sixMonthStats['target'] ?? total6;
    final rate = target == 0 ? 0.0 : (attended / target * 100).clamp(0, 100);

    Widget box(String label, String value) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border.all(color: Colors.black)),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 9, letterSpacing: 0.3),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            box('REKOD 6 BULAN\n6-MONTH RECORDS', '$total6'),
            box('HADIR\nPRESENT', '$present6'),
            box('LEWAT\nLATE', '$late6'),
            box('TIDAK HADIR\nABSENT', '$absent6'),
            box('KADAR KEHADIRAN\nATTENDANCE %', '${rate.toStringAsFixed(1)}%'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Bulan ini / This month: ${_monthStats['present'] ?? 0} hadir · '
          '${_monthStats['late'] ?? 0} lewat · ${_monthStats['absent'] ?? 0} tidak hadir '
          '(${_monthStats['total'] ?? 0} rekod)',
          style: const TextStyle(fontSize: 10, color: Colors.black87),
        ),
      ],
    );
  }

  Widget _attendanceTable(BorderSide border) {
    const headerStyle = TextStyle(fontSize: 10, fontWeight: FontWeight.bold);
    const cellStyle = TextStyle(fontSize: 10);
    Widget h(String t) => Padding(
      padding: const EdgeInsets.all(6),
      child: Text(t, style: headerStyle),
    );
    Widget c(String t) => Padding(
      padding: const EdgeInsets.all(6),
      child: Text(t, style: cellStyle),
    );

    final rows = _attendance.take(30).toList();
    return Table(
      border: TableBorder(
        top: border,
        bottom: border,
        left: border,
        right: border,
        horizontalInside: border,
        verticalInside: border,
      ),
      columnWidths: const {
        0: FlexColumnWidth(1.4),
        1: FlexColumnWidth(1.2),
        2: FlexColumnWidth(1.2),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(2),
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFFEDEDED)),
          children: [
            h('TARIKH / DATE'),
            h('MASUK / IN'),
            h('KELUAR / OUT'),
            h('STATUS'),
            h('CATATAN / REMARKS'),
          ],
        ),
        if (rows.isEmpty)
          TableRow(
            children: [
              c('Tiada rekod kehadiran. / No attendance records.'),
              c(''),
              c(''),
              c(''),
              c(''),
            ],
          )
        else
          ...rows.map((r) {
            final status = attendanceStatus(r);
            final reason = (r['late_reason'] as String?) ?? '';
            return TableRow(
              children: [
                c(fmtDay(r['punch_in'] as String?)),
                c(fmtPunch(r['punch_in'] as String?, withDate: false)),
                c(fmtPunch(r['punch_out'] as String?, withDate: false)),
                c(status),
                c(reason.isEmpty ? '—' : reason),
              ],
            );
          }),
      ],
    );
  }

  Widget _leaveTable(BorderSide border) {
    const headerStyle = TextStyle(fontSize: 10, fontWeight: FontWeight.bold);
    const cellStyle = TextStyle(fontSize: 10);
    Widget h(String t) => Padding(
      padding: const EdgeInsets.all(6),
      child: Text(t, style: headerStyle),
    );
    Widget c(String t) => Padding(
      padding: const EdgeInsets.all(6),
      child: Text(t, style: cellStyle),
    );
    String? d(String? iso) {
      final dt = DateTime.tryParse(iso ?? '');
      return dt == null ? null : _fmtDate(dt);
    }

    final rows = _leaves.take(15).toList();
    return Table(
      border: TableBorder(
        top: border,
        bottom: border,
        left: border,
        right: border,
        horizontalInside: border,
        verticalInside: border,
      ),
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(1.4),
        2: FlexColumnWidth(1.4),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(2),
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFFEDEDED)),
          children: [
            h('JENIS / TYPE'),
            h('MULA / FROM'),
            h('HINGGA / TO'),
            h('STATUS'),
            h('SEBAB / REASON'),
          ],
        ),
        if (rows.isEmpty)
          TableRow(
            children: [
              c('Tiada rekod cuti/logbuk. / No leave or logbook records.'),
              c(''),
              c(''),
              c(''),
              c(''),
            ],
          )
        else
          ...rows.map((r) {
            final from = d(r['start_date'] as String?);
            final to = d(r['end_date'] as String?);
            return TableRow(
              children: [
                c(cap((r['leave_type'] as String?) ?? '—')),
                c(from ?? '—'),
                c(to ?? '—'),
                c(cap((r['status'] as String?) ?? '—')),
                c(
                  (r['reason'] as String?)?.isNotEmpty == true
                      ? r['reason'] as String
                      : '—',
                ),
              ],
            );
          }),
      ],
    );
  }

  Widget _signOff() {
    Widget block(String label, String role) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 9,
              letterSpacing: 0.4,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 26),
          Container(height: 1, width: 170, color: Colors.black),
          const SizedBox(height: 4),
          Text(
            role,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
          ),
          const Text(
            'Tarikh / Date: ____ / ____ / ______',
            style: TextStyle(fontSize: 9, color: Colors.black54),
          ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        block(
          'DISEDIAKAN OLEH / PREPARED BY',
          'Pegawai Pentadbir / Admin Officer',
        ),
        const SizedBox(width: 24),
        block(
          'DISEMAK OLEH / VERIFIED BY',
          'Ketua Jabatan / Head of Department',
        ),
        const SizedBox(width: 24),
        block('DILULUSKAN OLEH / APPROVED BY', 'Pengarah / Director'),
      ],
    );
  }

  Widget _paperFooter(BorderSide border) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.black, width: 1.2)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'SULIT — UNTUK KEGUNAAN DALAMAN SAHAJA',
            style: TextStyle(fontSize: 9, letterSpacing: 0.3),
          ),
          Text('TVET MARA © 2026', style: TextStyle(fontSize: 9)),
        ],
      ),
    );
  }
}

/// Plain data bag passed to the PDF builder (kept separate so the PDF
/// pipeline never touches BuildContext / widget state).
class StaffReportData {
  final String name;
  final String staffNumber;
  final String department;
  final String icNumber;
  final String position;
  final String program;
  final String email;
  final String role;
  final bool isActive;
  final String generatedDate;
  final Map<String, int> monthStats;
  final Map<String, int> sixMonthStats;
  final List<Map<String, dynamic>> attendance;
  final List<Map<String, dynamic>> leaves;

  const StaffReportData({
    required this.name,
    required this.staffNumber,
    required this.department,
    required this.icNumber,
    required this.position,
    required this.program,
    required this.email,
    required this.role,
    required this.isActive,
    required this.generatedDate,
    required this.monthStats,
    required this.sixMonthStats,
    required this.attendance,
    required this.leaves,
  });
}

/// Builds the complete staff-report PDF (A4) and returns its bytes.
///
/// Open Sans is bundled as an app asset (OFL license, assets/fonts/) and
/// embedded into the PDF: it covers every Unicode glyph this report uses
/// (— em-dash, · middot, Malay diacritics) and works fully offline.
/// The default Helvetica base font has no Unicode support and silently
/// drops those glyphs, leaving blank cells for every "—" placeholder.
Future<Uint8List> buildStaffReportPdf(
  StaffReportData data,
  pw.ImageProvider? logo,
) async {
  final regularData = await rootBundle.load(
    'assets/fonts/OpenSans-Regular.ttf',
  );
  final boldData = await rootBundle.load('assets/fonts/OpenSans-Bold.ttf');
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(
      base: pw.Font.ttf(regularData),
      bold: pw.Font.ttf(boldData),
    ),
  );
  doc.addPage(
    pw.MultiPage(
      pageTheme: const pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(40),
      ),
      build: (context) => buildStaffReportPdfPages(data, logo),
    ),
  );
  return doc.save();
}

/// Builds the PDF pages for the staff report. Top-level (not a method) so
/// it stays easy to unit-test and doesn't capture widget state.
///
/// Strictly black & white: pure black text, black/gray table borders,
/// light-gray header shading only — prints cleanly on any B/W printer and
/// exports to a professional-looking PDF.
List<pw.Widget> buildStaffReportPdfPages(
  StaffReportData data,
  pw.ImageProvider? logo,
) {
  const black = PdfColors.black;
  final boxBorder = pw.Border.all(color: black, width: 0.7);
  final tableBorder = pw.TableBorder.all(color: black, width: 0.7);

  pw.Text h(String t) => pw.Text(
    t,
    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
  );
  pw.Text c(String t) => pw.Text(t, style: const pw.TextStyle(fontSize: 9));
  pw.Padding hc(String t, {bool header = false}) => pw.Padding(
    padding: const pw.EdgeInsets.all(5),
    child: header ? h(t) : c(t),
  );

  final total6 = data.sixMonthStats['total'] ?? 0;
  final present6 = data.sixMonthStats['present'] ?? 0;
  final late6 = data.sixMonthStats['late'] ?? 0;
  final absent6 = data.sixMonthStats['absent'] ?? 0;
  final target = data.sixMonthStats['target'] ?? total6;
  final rate = target == 0
      ? 0.0
      : ((present6 + late6) / target * 100).clamp(0, 100);

  pw.Widget sectionRule(String number, String title) => pw.Row(
    children: [
      pw.Container(
        width: 16,
        height: 16,
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(
          shape: pw.BoxShape.circle,
          border: pw.Border.all(color: black, width: 1),
        ),
        child: pw.Text(
          number,
          style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.SizedBox(width: 6),
      pw.Text(
        title,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          letterSpacing: 0.3,
        ),
      ),
      pw.SizedBox(width: 6),
      pw.Expanded(child: pw.Container(height: 0.7, color: black)),
    ],
  );

  pw.Widget statBox(String label, String value) => pw.Expanded(
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 8),
      decoration: pw.BoxDecoration(border: boxBorder),
      child: pw.Column(
        children: [
          pw.Text(
            value,
            style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            label,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 7),
          ),
        ],
      ),
    ),
  );

  return [
    // ── Header ──
    pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: black, width: 1.6)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            height: 44,
            width: 80,
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(border: boxBorder),
            child: logo != null
                ? pw.Image(logo, fit: pw.BoxFit.contain)
                : pw.Center(
                    child: pw.Text(
                      'TVET\nMARA',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 10,
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
                    fontSize: 14,
                  ),
                ),
                pw.Text(
                  'Administration',
                  style: const pw.TextStyle(fontSize: 9),
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'LAPORAN RASMI STAF / OFFICIAL STAFF REPORT',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                pw.Text(
                  'Profil, Kehadiran & Rekod Cuti · Generated: ${data.generatedDate}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    pw.SizedBox(height: 14),

    // ── 1. Profile ──
    sectionRule('1', 'MAKLUMAT STAF / STAFF PROFILE SUMMARY'),
    pw.SizedBox(height: 6),
    pw.Table(
      border: tableBorder,
      columnWidths: const {
        0: pw.FlexColumnWidth(1.1),
        1: pw.FlexColumnWidth(1.9),
        2: pw.FlexColumnWidth(1.1),
        3: pw.FlexColumnWidth(1.9),
      },
      children: [
        pw.TableRow(
          children: [
            hc('Nama / Name', header: true),
            hc(data.name),
            hc('No. Gaji / Staff ID', header: true),
            hc(data.staffNumber),
          ],
        ),
        pw.TableRow(
          children: [
            hc('No. IC / IC No.', header: true),
            hc(data.icNumber),
            hc('Jawatan / Position', header: true),
            hc(data.position),
          ],
        ),
        pw.TableRow(
          children: [
            hc('Jabatan / Department', header: true),
            hc(data.department),
            hc('Program / Course', header: true),
            hc(data.program),
          ],
        ),
        pw.TableRow(
          children: [
            hc('Emel / Email', header: true),
            hc(data.email),
            hc('Status', header: true),
            hc(data.isActive ? 'Aktif / Active' : 'Tidak Aktif / Inactive'),
          ],
        ),
      ],
    ),
    pw.SizedBox(height: 14),

    // ── 2. Attendance summary ──
    sectionRule('2', 'RINGKASAN KEHADIRAN / ATTENDANCE SUMMARY'),
    pw.SizedBox(height: 6),
    pw.Row(
      children: [
        statBox('REKOD 6 BULAN\n6-MONTH RECORDS', '$total6'),
        statBox('HADIR\nPRESENT', '$present6'),
        statBox('LEWAT\nLATE', '$late6'),
        statBox('TIDAK HADIR\nABSENT', '$absent6'),
        statBox('KADAR KEHADIRAN\nATTENDANCE %', '${rate.toStringAsFixed(1)}%'),
      ],
    ),
    pw.SizedBox(height: 6),
    pw.Text(
      'Bulan ini / This month: ${data.monthStats['present'] ?? 0} hadir · '
      '${data.monthStats['late'] ?? 0} lewat · ${data.monthStats['absent'] ?? 0} tidak hadir '
      '(${data.monthStats['total'] ?? 0} rekod)',
      style: const pw.TextStyle(fontSize: 8),
    ),
    pw.SizedBox(height: 14),

    // ── 3. Attendance history ──
    sectionRule('3', 'SEJARAH KEHADIRAN / ATTENDANCE HISTORY'),
    pw.SizedBox(height: 6),
    pw.Table(
      border: tableBorder,
      columnWidths: const {
        0: pw.FlexColumnWidth(1.4),
        1: pw.FlexColumnWidth(1.2),
        2: pw.FlexColumnWidth(1.2),
        3: pw.FlexColumnWidth(1),
        4: pw.FlexColumnWidth(2),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            hc('TARIKH / DATE', header: true),
            hc('MASUK / IN', header: true),
            hc('KELUAR / OUT', header: true),
            hc('STATUS', header: true),
            hc('CATATAN / REMARKS', header: true),
          ],
        ),
        if (data.attendance.isEmpty)
          pw.TableRow(
            children: [
              hc('Tiada rekod kehadiran. / No attendance records.'),
              hc(''),
              hc(''),
              hc(''),
              hc(''),
            ],
          )
        else
          ...data.attendance
              .take(40)
              .map(
                (r) => pw.TableRow(
                  children: [
                    hc(
                      _StaffReportPreviewState.fmtDay(r['punch_in'] as String?),
                    ),
                    hc(
                      _StaffReportPreviewState.fmtPunch(
                        r['punch_in'] as String?,
                        withDate: false,
                      ),
                    ),
                    hc(
                      _StaffReportPreviewState.fmtPunch(
                        r['punch_out'] as String?,
                        withDate: false,
                      ),
                    ),
                    hc(_StaffReportPreviewState.attendanceStatus(r)),
                    hc(
                      ((r['late_reason'] as String?)?.isNotEmpty ?? false)
                          ? r['late_reason'] as String
                          : '—',
                    ),
                  ],
                ),
              ),
      ],
    ),
    pw.SizedBox(height: 14),

    // ── 4. Leave & logbook records ──
    sectionRule('4', 'REKOD CUTI & LOGBUK / LEAVE & LOGBOOK REPORTS'),
    pw.SizedBox(height: 6),
    pw.Table(
      border: tableBorder,
      columnWidths: const {
        0: pw.FlexColumnWidth(1.2),
        1: pw.FlexColumnWidth(1.4),
        2: pw.FlexColumnWidth(1.4),
        3: pw.FlexColumnWidth(1),
        4: pw.FlexColumnWidth(2),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            hc('JENIS / TYPE', header: true),
            hc('MULA / FROM', header: true),
            hc('HINGGA / TO', header: true),
            hc('STATUS', header: true),
            hc('SEBAB / REASON', header: true),
          ],
        ),
        if (data.leaves.isEmpty)
          pw.TableRow(
            children: [
              hc('Tiada rekod cuti/logbuk. / No leave or logbook records.'),
              hc(''),
              hc(''),
              hc(''),
              hc(''),
            ],
          )
        else
          ...data.leaves.take(15).map((r) {
            String d(String? iso) {
              final dt = DateTime.tryParse(iso ?? '');
              if (dt == null) return '—';
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
              return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
            }

            return pw.TableRow(
              children: [
                hc(
                  _StaffReportPreviewState.cap(
                    (r['leave_type'] as String?) ?? '—',
                  ),
                ),
                hc(d(r['start_date'] as String?)),
                hc(d(r['end_date'] as String?)),
                hc(
                  _StaffReportPreviewState.cap((r['status'] as String?) ?? '—'),
                ),
                hc(
                  ((r['reason'] as String?)?.isNotEmpty ?? false)
                      ? r['reason'] as String
                      : '—',
                ),
              ],
            );
          }),
      ],
    ),
    pw.SizedBox(height: 26),

    // ── Sign-off ──
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final entry in const [
          (
            'DISEDIAKAN OLEH / PREPARED BY',
            'Pegawai Pentadbir / Admin Officer',
          ),
          ('DISEMAK OLEH / VERIFIED BY', 'Ketua Jabatan / Head of Department'),
          ('DILULUSKAN OLEH / APPROVED BY', 'Pengarah / Director'),
        ])
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(entry.$1, style: const pw.TextStyle(fontSize: 7)),
                pw.SizedBox(height: 22),
                pw.Container(height: 0.8, width: 140, color: black),
                pw.SizedBox(height: 3),
                pw.Text(
                  entry.$2,
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  'Tarikh / Date: ____ / ____ / ______',
                  style: const pw.TextStyle(fontSize: 7),
                ),
              ],
            ),
          ),
      ],
    ),
    pw.SizedBox(height: 16),

    // ── Footer ──
    pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: black, width: 1)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'SULIT — UNTUK KEGUNAAN DALAMAN SAHAJA',
            style: const pw.TextStyle(fontSize: 7),
          ),
          pw.Text('TVET MARA © 2026', style: const pw.TextStyle(fontSize: 7)),
        ],
      ),
    ),
  ];
}
