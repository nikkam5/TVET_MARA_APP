import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/reports/report_export_service.dart';
import '../../theme/app_theme.dart';
import '../../models/attendance_report.dart';
import '../../utils/malaysia_time.dart';
import '../reports/report_generator_screen.dart';

// ─────────────────────────────────────────────────────────────────────
// Design tokens — mirrored from the admin dashboard shell so the reports
// page reads as one more panel of the same application.
// ─────────────────────────────────────────────────────────────────────
/// Surface system.
const Color _hairline = Color(0xFFE2E8F0); // slate-200
const Color _surfaceMuted = Color(0xFFF8FAFC); // slate-50

/// Ink.
const Color _ink = Color(0xFF0F172A); // slate-900
const Color _muted = Color(0xFF64748B); // slate-500

/// Primary navy (MARA corporate) — used by export actions.
const Color _navy = Color(0xFF002060);

List<BoxShadow> _shadowSm() => [
  BoxShadow(
    color: _ink.withValues(alpha: 0.07),
    blurRadius: 12,
    offset: const Offset(0, 4),
  ),
  BoxShadow(
    color: _ink.withValues(alpha: 0.03),
    blurRadius: 2,
    offset: const Offset(0, 1),
  ),
];

/// A single department's slice of today's attendance.
class _DeptStat {
  const _DeptStat({
    required this.name,
    required this.staff,
    required this.onTime,
    required this.late,
    required this.absent,
    this.leave = 0,
    this.pending = 0,
  });

  final String name;
  final int staff;
  final int onTime;
  final int late;
  final int absent;
  final int leave;
  final int pending;

  int get present => onTime + late;

  int get rate => staff - leave <= 0
      ? 0
      : ((present * 100 / (staff - leave)).round()).clamp(0, 100);

  String get status {
    if (rate >= 90) return 'Excellent';
    if (rate >= 75) return 'Good';
    if (rate >= 60) return 'Watch';
    return 'At risk';
  }

  Color get statusColor {
    switch (status) {
      case 'Excellent':
        return AppTheme.success;
      case 'Good':
        return AppTheme.maraBlue;
      case 'Watch':
        return const Color(0xFFD97706);
      default:
        return AppTheme.maraRed;
    }
  }
}

/// One downloadable report offered on the page.
class _ReportSpec {
  const _ReportSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    required this.sections,
    required this.rowCount,
  });

  final String id;
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  final List<ReportSection> sections;
  final int rowCount;
}

/// System Reports — in-shell analytics + export console.
///
/// Deliberately **not** a `Scaffold`: it renders inside the admin shell
/// (sticky left rail + top navbar) exactly like the dashboard and the
/// staff directory, and inherits the shell's pull-to-refresh.
class SystemReportsScreen extends StatefulWidget {
  const SystemReportsScreen({
    super.key,
    required this.staff,
    required this.departments,
    required this.weekAttendance,
    required this.presentToday,
    required this.lateToday,
    required this.pendingApprovals,
    required this.lastUpdated,
    this.isLoading = false,
    this.approvedLeaveStaffIds = const {},
    this.pendingToday = const {},
  });

  /// Full staff roster (`is_active`, `staff_number`, `departments.name`…).
  final List<Map<String, dynamic>> staff;

  final List<Map<String, dynamic>> departments;

  /// Sun–Thu buckets for the weekly trend chart.
  final List<({String label, int inOffice, int remote, int late})>
  weekAttendance;

  /// `staff_number` values punched in today (status `present`).
  final Set<String> presentToday;

  /// `staff_number` values flagged `late` today.
  final Set<String> lateToday;

  final int pendingApprovals;
  final DateTime? lastUpdated;
  final bool isLoading;
  final Set<String> approvedLeaveStaffIds;
  final Set<String> pendingToday;

  @override
  State<SystemReportsScreen> createState() => _SystemReportsScreenState();
}

class _SystemReportsScreenState extends State<SystemReportsScreen> {
  /// 0 = week, 1 = month, 2 = semester — stamps the exported files.
  final int _period = 0;

  static const List<String> _periods = [
    'Today',
    'This Week',
    'This Month',
    'This Semester',
  ];

  // ── Derived analytics ───────────────────────────────────────────────
  List<Map<String, dynamic>> get _activeStaff => widget.staff
      .where((s) => s['is_active'] == true && s['role'] == 'staff')
      .toList(growable: false);

  String _staffNo(Map<String, dynamic> s) => s['staff_number'] as String? ?? '';

  bool _onApprovedLeave(Map<String, dynamic> staff) =>
      widget.approvedLeaveStaffIds.contains(staff['id']) &&
      !widget.presentToday.contains(_staffNo(staff)) &&
      !widget.lateToday.contains(_staffNo(staff));
  int get _leave => _activeStaff.where(_onApprovedLeave).length;
  int get _pending => _activeStaff
      .where(
        (staff) =>
            widget.pendingToday.contains(_staffNo(staff)) &&
            !_onApprovedLeave(staff),
      )
      .length;
  int get _expected => _activeStaff.length - _leave;

  List<Map<String, dynamic>> get _onTimeStaff {
    final late = widget.lateToday;
    return _activeStaff
        .where(
          (s) =>
              widget.presentToday.contains(_staffNo(s)) &&
              !late.contains(_staffNo(s)),
        )
        .toList(growable: false);
  }

  List<Map<String, dynamic>> get _lateStaff => _activeStaff
      .where((s) => widget.lateToday.contains(_staffNo(s)))
      .toList(growable: false);

  int get _onTime => _onTimeStaff.length;
  int get _late => _lateStaff.length;
  int get _absent => math.max(0, _expected - _onTime - _late - _pending);
  int get _checkedIn => _onTime + _late;

  int get _attendanceRate =>
      _expected == 0 ? 0 : ((_checkedIn * 100 / _expected).round());

  List<_DeptStat> get _deptStats {
    final names = <String>[];
    for (final d in widget.departments) {
      final name = d['name'] as String?;
      if (name != null && name.isNotEmpty) names.add(name);
    }
    for (final s in widget.staff) {
      final name = s['departments']?['name'] as String?;
      if (name != null && name.isNotEmpty && !names.contains(name)) {
        names.add(name);
      }
    }

    final stats = <_DeptStat>[];
    for (final name in names) {
      var staff = 0, onTime = 0, late = 0, leave = 0, pending = 0;
      for (final m in _activeStaff) {
        if (((m['departments']?['name'] as String?) ?? '') != name) continue;
        staff++;
        final no = _staffNo(m);
        if (widget.lateToday.contains(no)) {
          late++;
        } else if (widget.presentToday.contains(no)) {
          onTime++;
        } else if (_onApprovedLeave(m)) {
          leave++;
        } else if (widget.pendingToday.contains(no)) {
          pending++;
        }
      }
      stats.add(
        _DeptStat(
          name: name,
          staff: staff,
          onTime: onTime,
          late: late,
          absent: math.max(0, staff - onTime - late - leave - pending),
          leave: leave,
          pending: pending,
        ),
      );
    }
    stats.sort((a, b) {
      final byRate = b.rate.compareTo(a.rate);
      return byRate != 0 ? byRate : a.name.compareTo(b.name);
    });
    return stats;
  }

  String get _dateLabel {
    final now = MalaysiaTime.now();
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
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}';
  }

  String get _subtitle =>
      'TVET MARA administration · ${_periods[_period]} · Generated $_dateLabel';

  // ── Report definitions ──────────────────────────────────────────────
  List<_ReportSpec> _reportSpecs() {
    final depts = _deptStats;
    final roster = widget.staff;

    final attendance = ReportSection(
      title: "Today's attendance by department",
      note: 'On-time, late and absent split per department · $_dateLabel',
      headers: const [
        'Department',
        'Staff',
        'On time',
        'Late',
        'Absent',
        'Approved leave',
        'Pending late',
        'Attendance %',
      ],
      rows: [
        for (final d in depts)
          [
            d.name,
            '${d.staff}',
            '${d.onTime}',
            '${d.late}',
            '${d.absent}',
            '${d.leave}',
            '${d.pending}',
            '${d.rate}%',
          ],
      ],
    );

    final departments = ReportSection(
      title: 'Department performance',
      note: 'Ranked by approved attendance for today.',
      headers: const [
        'Rank',
        'Department',
        'Staff',
        'Present',
        'Attendance %',
        'Status',
      ],
      rows: [
        for (var i = 0; i < depts.length; i++)
          [
            '${i + 1}',
            depts[i].name,
            '${depts[i].staff}',
            '${depts[i].present}',
            '${depts[i].rate}%',
            depts[i].status,
          ],
      ],
    );

    final rosterSection = ReportSection(
      title: 'Staff directory & roster',
      note: '${roster.length} records · active and inactive staff.',
      headers: const [
        'Name',
        'Staff No.',
        'Position',
        'Department',
        'Status',
        "Today's attendance",
      ],
      rows: [
        for (final s in roster)
          [
            (s['full_name'] as String?) ?? '—',
            (s['staff_number'] as String?) ?? '—',
            (s['position'] as String?) ?? '—',
            (s['departments']?['name'] as String?) ?? '—',
            ((s['is_active'] as bool?) ?? true) ? 'Active' : 'Inactive',
            _attendanceLabelFor(s),
          ],
      ],
    );

    final weekly = ReportSection(
      title: 'Weekly attendance trend',
      note: 'Sunday–Thursday approved check-ins for the current week.',
      headers: const ['Day', 'In office', 'Remote', 'Checked in', 'Late'],
      rows: [
        for (final d in widget.weekAttendance)
          [
            d.label,
            '${d.inOffice}',
            '${d.remote}',
            '${d.inOffice + d.remote}',
            '${d.late}',
          ],
      ],
    );

    final punctuality = ReportSection(
      title: 'Punctuality & lateness',
      note: 'Late arrivals recorded on $_dateLabel.',
      headers: const ['Name', 'Staff No.', 'Department', 'Status'],
      rows: _lateStaff.isEmpty
          ? [
              ['—', '—', '—', 'No late arrivals recorded today'],
            ]
          : [
              for (final s in _lateStaff)
                [
                  (s['full_name'] as String?) ?? '—',
                  _staffNo(s),
                  (s['departments']?['name'] as String?) ?? '—',
                  'Late',
                ],
            ],
    );

    final overview = ReportSection(
      title: 'Administration overview',
      note: 'Headline metrics for the TVET MARA administration.',
      headers: const ['Metric', 'Value', 'Notes'],
      rows: [
        [
          'Attendance rate',
          '$_attendanceRate%',
          '$_checkedIn of $_expected expected',
        ],
        ['On time today', '$_onTime', 'Checked in before the grace window'],
        ['Late today', '$_late', 'Flagged by the attendance rules'],
        ['Absent today', '$_absent', 'No punch recorded yet'],
        ['Approved leave', '$_leave', 'Excluded from attendance target'],
        ['Pending late', '$_pending', 'Awaiting administrator approval'],
        [
          'Staff on roster',
          '${widget.staff.length}',
          '${_activeStaff.length} active',
        ],
        ['Departments', '${depts.length}', 'Reporting units'],
        [
          'Pending approvals',
          '${widget.pendingApprovals}',
          'Leave, MC and lateness',
        ],
        ['Reporting period', _periods[_period], _dateLabel],
      ],
    );

    return [
      _ReportSpec(
        id: 'attendance',
        title: 'Attendance Summary',
        description:
            "Today's on-time, late and absent split for every department, ready for the daily briefing.",
        icon: Icons.event_available_rounded,
        color: AppTheme.maraBlue,
        sections: [attendance],
        rowCount: attendance.rows.length,
      ),
      _ReportSpec(
        id: 'departments',
        title: 'Department Performance',
        description: 'Departments ranked by approved attendance for today.',
        icon: Icons.account_tree_rounded,
        color: AppTheme.success,
        sections: [departments],
        rowCount: departments.rows.length,
      ),
      _ReportSpec(
        id: 'roster',
        title: 'Staff Directory & Roster',
        description:
            'The complete staff list with position, department, account status and today’s attendance.',
        icon: Icons.groups_rounded,
        color: const Color(0xFF7C3AED),
        sections: [rosterSection],
        rowCount: rosterSection.rows.length,
      ),
      _ReportSpec(
        id: 'weekly',
        title: 'Weekly Attendance Trend',
        description:
            'In-office versus remote check-ins across the week — useful for capacity planning.',
        icon: Icons.insights_rounded,
        color: const Color(0xFF0E7490),
        sections: [weekly],
        rowCount: weekly.rows.length,
      ),
      _ReportSpec(
        id: 'punctuality',
        title: 'Punctuality & Lateness',
        description:
            'Every late arrival recorded today, with the department that owns each follow-up.',
        icon: Icons.schedule_rounded,
        color: const Color(0xFFD97706),
        sections: [punctuality],
        rowCount: punctuality.rows.length,
      ),
      _ReportSpec(
        id: 'overview',
        title: 'Administration Overview',
        description:
            'Headline KPIs in one page — attendance rate, roster size and pending approvals.',
        icon: Icons.space_dashboard_rounded,
        color: AppTheme.navy,
        sections: [overview],
        rowCount: overview.rows.length,
      ),
    ];
  }

  List<ReportSection> get _allSections => [
    for (final spec in _reportSpecs()) ...spec.sections,
  ];

  String _attendanceLabelFor(Map<String, dynamic> s) {
    if (!((s['is_active'] as bool?) ?? true)) return 'Inactive';
    if (s['role'] == 'admin') return 'Administrator';
    if (_onApprovedLeave(s)) return 'Approved leave';
    if (widget.pendingToday.contains(_staffNo(s))) return 'Pending approval';
    final no = _staffNo(s);
    if (widget.lateToday.contains(no)) return 'Late';
    if (widget.presentToday.contains(no)) return 'Present';
    return 'Absent';
  }

  // ── Actions ─────────────────────────────────────────────────────────
  Future<void> _exportPdf(List<ReportSection> sections, String title) {
    return ReportExporter.exportPdf(
      context: context,
      title: title,
      subtitle: _subtitle,
      sections: sections,
    );
  }

  Future<void> _exportCsv(List<ReportSection> sections, String title) {
    return ReportExporter.exportCsv(
      context: context,
      title: title,
      subtitle: _subtitle,
      sections: sections,
    );
  }

  Future<void> _emailSummary() async {
    final body = StringBuffer()
      ..writeln('TVET MARA Administration — ${_periods[_period]} summary')
      ..writeln('Generated: $_dateLabel')
      ..writeln()
      ..writeln('Attendance rate : $_attendanceRate% ($_checkedIn/$_expected)')
      ..writeln('On time today   : $_onTime')
      ..writeln('Late today      : $_late')
      ..writeln('Absent today    : $_absent')
      ..writeln('Staff on roster : ${widget.staff.length}')
      ..writeln('Pending approvals: ${widget.pendingApprovals}')
      ..writeln()
      ..writeln('Departments:');
    for (final d in _deptStats) {
      body.writeln('  ${d.name}: ${d.rate}% (${d.present}/${d.staff})');
    }

    try {
      final uri = Uri(
        scheme: 'mailto',
        queryParameters: {
          'subject': 'TVET MARA administration summary — ${_periods[_period]}',
          'body': body.toString(),
        },
      );
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        _toast('No email app is available on this device.');
      }
    } catch (_) {
      if (mounted) _toast('Could not open the email app.');
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(color: Colors.white)),
          backgroundColor: _ink,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
  }

  // ── Build ───────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final depts = _deptStats;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _toolbar(width),
            const SizedBox(height: 18),
            _kpiRow(width),
            const SizedBox(height: 18),
            if (width >= 720) ...[
              // The two chart cards line up at the taller one's height
              // (IntrinsicHeight measures, stretch fills) instead of
              // stepping down halfway across the row.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _summaryCard(
                        depts,
                        headerWidth: (width - 18) * 5 / 9 - 36,
                        fill: true,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      flex: 4,
                      child: _trendCard(headerWidth: (width - 18) * 4 / 9 - 36),
                    ),
                  ],
                ),
              ),
            ] else ...[
              _summaryCard(depts, headerWidth: width - 36, fill: false),
              const SizedBox(height: 18),
              _trendCard(headerWidth: width - 36),
            ],
            const SizedBox(height: 18),
            _departmentCard(depts, width),
            const SizedBox(height: 18),
            _reportCardGrid(width),
            const SizedBox(height: 18),
            _quickExportCard(width),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  // ── Toolbar ─────────────────────────────────────────────────────────
  Widget _toolbar(double width) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Reports & Exports',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: _ink,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          widget.isLoading && widget.staff.isEmpty
              ? 'Waiting for live data…'
              : _subtitle,
          style: const TextStyle(fontSize: 12.5, color: _muted),
        ),
      ],
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < _periods.length; i++) _periodChip(_periods[i], i),
        const SizedBox(width: 2),
        _primaryButton(
          label: 'Export all (PDF)',
          icon: Icons.picture_as_pdf_rounded,
          onPressed: () => _exportPdf(_allSections, 'TVET MARA System Report'),
        ),
      ],
    );

    if (width >= 860) {
      return Row(
        children: [
          // Both sides flex: the heading wraps its (long) subtitle instead
          // of stealing width from the action chips, and the chips stay
          // flush right instead of leaving a ragged gap.
          Expanded(child: heading),
          const SizedBox(width: 20),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: actions),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [heading, const SizedBox(height: 14), actions],
    );
  }

  Widget _periodChip(String label, int index) {
    final selected = _period == index;
    return GestureDetector(
      onTap: index == 0 ? null : () => _openPeriodReport(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _navy : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _navy : _hairline),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _navy.withValues(alpha: 0.22),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? Colors.white : _muted,
          ),
        ),
      ),
    );
  }

  void _openPeriodReport(int index) {
    final now = MalaysiaTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final period = switch (index) {
      1 => ReportPeriod(
        start: end.subtract(Duration(days: end.weekday % 7)),
        end: end,
      ),
      2 => ReportPeriod(start: DateTime(now.year, now.month, 1), end: end),
      _ => ReportPeriod.recent().first,
    };
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReportGeneratorScreen(adminMode: true, initialPeriod: period),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.navy, Color(0xFF0A4EA1)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: _navy.withValues(alpha: 0.28),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              // Loose fit: the label ellipsizes instead of pushing the
              // button past the toolbar's available width.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── KPI row ─────────────────────────────────────────────────────────
  Widget _kpiRow(double width) {
    double cardW;
    if (width >= 1180) {
      cardW = (width - 3 * 16) / 4;
    } else if (width >= 740) {
      cardW = (width - 16) / 2;
    } else {
      cardW = width;
    }

    final tiles = [
      (
        'Attendance Rate',
        '$_attendanceRate%',
        '$_checkedIn of $_expected expected today',
        Icons.trending_up_rounded,
        AppTheme.maraBlue,
      ),
      (
        'Present Today',
        '$_checkedIn',
        '$_onTime on time · $_late late',
        Icons.how_to_reg_rounded,
        AppTheme.success,
      ),
      (
        'Absent Today',
        '$_absent',
        'No punch recorded yet',
        Icons.event_busy_rounded,
        AppTheme.maraRed,
      ),
      (
        'Pending Approvals',
        '${widget.pendingApprovals}',
        'Leave, MC and lateness requests',
        Icons.fact_check_rounded,
        const Color(0xFFD97706),
      ),
    ];

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        for (final t in tiles)
          SizedBox(width: cardW, child: _kpiCard(t.$1, t.$2, t.$3, t.$4, t.$5)),
      ],
    );
  }

  Widget _kpiCard(
    String label,
    String value,
    String sub,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
        boxShadow: _shadowSm(),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 21, color: color),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: _muted,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: _muted,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Cards ───────────────────────────────────────────────────────────
  Widget _card({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _hairline),
        boxShadow: _shadowSm(),
      ),
      child: child,
    );
  }

  /// Card header: icon chip + title, with an optional status chip on the
  /// right.
  ///
  /// [available] is the card's inner width. It's passed in rather than
  /// read from a LayoutBuilder on purpose: the analytics row is wrapped in
  /// an [IntrinsicHeight] to line the cards up, and LayoutBuilder refuses
  /// to answer intrinsic queries ("does not support returning intrinsic
  /// dimensions").
  Widget _panelHeader({
    required double available,
    required IconData icon,
    required Color color,
    required String title,
    Widget? trailing,
  }) {
    final iconBox = Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 16, color: color),
    );
    final heading = Text(
      title,
      style: const TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w800,
        color: _ink,
      ),
    );

    // Below ~480px there isn't room for a title and a status chip on one
    // line without one of them being clipped, so the chip drops onto its
    // own row instead.
    if (trailing != null && available < 480) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              iconBox,
              const SizedBox(width: 10),
              Expanded(child: heading),
            ],
          ),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: trailing),
        ],
      );
    }

    // The title carries the heavier flex so it wins the space contest with
    // the chip — chart titles must never be the thing that ellipsizes.
    return Row(
      children: [
        iconBox,
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          Flexible(flex: 2, child: trailing),
        ],
      ],
    );
  }

  Widget _chip(String label, {Color color = AppTheme.maraBlue}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  // ── Attendance donut ────────────────────────────────────────────────
  Widget _summaryCard(
    List<_DeptStat> depts, {
    required double headerWidth,
    required bool fill,
  }) {
    final segments = <(double, Color)>[
      (_onTime.toDouble(), AppTheme.success),
      (_late.toDouble(), const Color(0xFFD97706)),
      (_absent.toDouble(), const Color(0xFFCBD5E1)),
      (_pending.toDouble(), const Color(0xFF7C3AED)),
      (_leave.toDouble(), AppTheme.maraBlue),
    ];
    final legend = [
      ('On time', _onTime, AppTheme.success),
      ('Late', _late, const Color(0xFFD97706)),
      ('Absent', _absent, const Color(0xFF94A3B8)),
      ('Pending', _pending, const Color(0xFF7C3AED)),
      ('Leave', _leave, AppTheme.maraBlue),
    ];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            available: headerWidth,
            icon: Icons.donut_small_rounded,
            color: AppTheme.maraBlue,
            title: 'Attendance Summary',
            trailing: _chip(
              '$_attendanceRate% today',
              color: AppTheme.maraBlue,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 124,
                height: 124,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(124, 124),
                      painter: _DonutPainter(segments: segments),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_attendanceRate%',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: _ink,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'attendance',
                          style: TextStyle(fontSize: 10.5, color: _muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  children: [
                    for (final (label, value, color) in legend)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: _muted,
                                ),
                              ),
                            ),
                            Text(
                              '$value',
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: _ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // When the trend card next door sets the row height, the extra
          // room collects under the donut — push the summary footer down so
          // the card reads as one balanced panel.
          if (fill) const Spacer(),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _surfaceMuted,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.business_rounded, size: 15, color: _muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${depts.length} departments · ${_activeStaff.length} active staff',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: _muted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Weekly bars ─────────────────────────────────────────────────────
  Widget _trendCard({required double headerWidth}) {
    final week = widget.weekAttendance;
    final checked = [for (final d in week) d.inOffice + d.remote];
    final maxVal = [
      ...checked,
      ...[for (final d in week) d.late],
      1,
    ].reduce(math.max);
    const track = 118.0;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            available: headerWidth,
            icon: Icons.bar_chart_rounded,
            color: AppTheme.success,
            title: 'Weekly Attendance Trend',
            trailing: _chip(
              week.isEmpty ? 'No data' : '${week.length} working days',
              color: AppTheme.success,
            ),
          ),
          const SizedBox(height: 16),
          // +60 rather than the theoretical minimum: the day column stacks
          // a value label, the 118px bar and the day name, and text line
          // heights vary by platform font — a little slack beats a clipped
          // label (children are bottom-aligned, so the slack sits on top).
          SizedBox(
            height: track + 60,
            child: week.isEmpty
                ? const Center(
                    child: Text(
                      'No check-ins recorded for this week yet.',
                      style: TextStyle(fontSize: 12.5, color: _muted),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < week.length; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  '${checked[i]}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _ink,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Container(
                                  height: track,
                                  alignment: Alignment.bottomCenter,
                                  child: TweenAnimationBuilder<double>(
                                    duration: Duration(
                                      milliseconds: 320 + i * 60,
                                    ),
                                    curve: Curves.easeOutCubic,
                                    tween: Tween<double>(
                                      begin: 0,
                                      end: checked[i].toDouble(),
                                    ),
                                    builder: (context, value, _) => Tooltip(
                                      message:
                                          '${week[i].label}: ${checked[i]} checked in '
                                          '· ${week[i].inOffice} in office · '
                                          '${week[i].remote} remote · ${week[i].late} late',
                                      child: _stackedBar(
                                        total: value,
                                        track: track,
                                        maxVal: maxVal,
                                        onTime: checked[i] - week[i].late,
                                        late: week[i].late,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  week[i].label,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: _muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          // Wrap, not Row: at phone widths the three labels together are
          // wider than the card, and a second run reads better than an
          // overflow stripe.
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _legendDot('On time', AppTheme.success),
              _legendDot('Late', const Color(0xFFD97706)),
              _legendDot('In office + remote', const Color(0xFF0A4EA1)),
            ],
          ),
        ],
      ),
    );
  }

  /// One vertical bar: the on-time slice in navy with the late slice in
  /// amber stacked on top, scaled against the busiest day of the week.
  Widget _stackedBar({
    required double total,
    required double track,
    required int maxVal,
    required int onTime,
    required int late,
  }) {
    final scale = (maxVal <= 0 || total <= 0) ? 0.0 : total / maxVal;
    final height = (track * scale).clamp(2.0, track);
    final people = onTime + late;
    final lateHeight = people == 0 ? 0.0 : height * late / people;
    final onTimeHeight = height - lateHeight;
    return Container(
      width: 22,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
        color: AppTheme.navy,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (lateHeight > 0)
            Container(height: lateHeight, color: const Color(0xFFD97706)),
          Container(
            height: onTimeHeight,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [AppTheme.navy, Color(0xFF0A4EA1)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: _muted),
          ),
        ),
      ],
    );
  }

  // ── Department table ────────────────────────────────────────────────
  Widget _departmentCard(List<_DeptStat> depts, double width) {
    final full = width >= 640;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            available: width - 36,
            icon: Icons.business_rounded,
            color: const Color(0xFF7C3AED),
            title: 'Department Performance',
            trailing: _chip(
              depts.isEmpty ? 'No departments' : 'Ranked by attendance',
              color: const Color(0xFF7C3AED),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: _surfaceMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            child: _deptRow(
              const _DeptStat(
                name: 'DEPARTMENT',
                staff: 0,
                onTime: 0,
                late: 0,
                absent: 0,
              ),
              header: true,
              full: full,
              index: -1,
            ),
          ),
          const SizedBox(height: 4),
          if (depts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Department figures appear once staff records are loaded.',
                  style: TextStyle(fontSize: 12.5, color: _muted),
                ),
              ),
            )
          else
            for (var i = 0; i < depts.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: _hairline),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                child: _deptRow(depts[i], full: full, index: i),
              ),
            ],
        ],
      ),
    );
  }

  Widget _deptRow(
    _DeptStat d, {
    required bool full,
    required int index,
    bool header = false,
  }) {
    final nameStyle = TextStyle(
      fontSize: header ? 10.5 : 13.5,
      fontWeight: FontWeight.w800,
      color: header ? _muted : _ink,
      letterSpacing: header ? 0.7 : 0,
    );
    final cellStyle = TextStyle(
      fontSize: header ? 10.5 : 13,
      fontWeight: header ? FontWeight.w800 : FontWeight.w600,
      color: header ? _muted : _ink,
      letterSpacing: header ? 0.7 : 0,
    );

    final name = header
        ? Text(
            'DEPARTMENT',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                d.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nameStyle,
              ),
              const SizedBox(height: 2),
              Text(
                '${d.staff} staff · ${d.late} late',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          );

    if (!full) {
      return Row(
        children: [
          Expanded(child: name),
          SizedBox(
            width: 54,
            child: Text(
              header ? 'PRESENT' : '${d.present}',
              textAlign: TextAlign.center,
              style: cellStyle,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              header ? 'RATE' : '${d.rate}%',
              textAlign: TextAlign.center,
              style: cellStyle,
            ),
          ),
          SizedBox(
            width: 78,
            child: header
                ? Text('STATUS', textAlign: TextAlign.center, style: cellStyle)
                : _statusPill(d),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: name),
        _numCell(header ? 'STAFF' : '${d.staff}', 56, cellStyle),
        _numCell(header ? 'ON TIME' : '${d.onTime}', 64, cellStyle),
        _numCell(header ? 'LATE' : '${d.late}', 52, cellStyle),
        SizedBox(
          width: 146,
          child: header
              ? Text(
                  'ATTENDANCE',
                  textAlign: TextAlign.center,
                  style: cellStyle,
                )
              : Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: TweenAnimationBuilder<double>(
                          duration: const Duration(milliseconds: 520),
                          curve: Curves.easeOutCubic,
                          tween: Tween<double>(begin: 0, end: d.rate / 100),
                          builder: (context, value, _) =>
                              _PercentBar(value: value),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 34,
                      child: Text(
                        '${d.rate}%',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: _ink,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        SizedBox(
          width: 92,
          child: header
              ? Text('STATUS', textAlign: TextAlign.center, style: cellStyle)
              : _statusPill(d),
        ),
      ],
    );
  }

  Widget _numCell(String text, double width, TextStyle style) {
    return SizedBox(
      width: width,
      child: Text(text, textAlign: TextAlign.center, style: style),
    );
  }

  Widget _statusPill(_DeptStat d) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: d.statusColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        d.status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: d.statusColor,
        ),
      ),
    );
  }

  // ── Downloadable report cards ───────────────────────────────────────
  Widget _reportCardGrid(double width) {
    final specs = _reportSpecs();
    const gap = 16.0;
    final columns = width >= 1120
        ? 3
        : width >= 700
        ? 2
        : 1;
    final cardW = (width - gap * (columns - 1)) / columns;
    final rows = <List<_ReportSpec>>[
      for (var i = 0; i < specs.length; i += columns)
        specs.sublist(
          i,
          i + columns < specs.length ? i + columns : specs.length,
        ),
    ];
    final updated = widget.lastUpdated == null
        ? 'Not synced yet'
        : 'Updated ${widget.lastUpdated!.hour.toString().padLeft(2, '0')}:${widget.lastUpdated!.minute.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelHeader(
          available: width - 36,
          icon: Icons.folder_open_rounded,
          color: AppTheme.navy,
          title: 'Downloadable Reports',
          trailing: const Text(
            'PDF for printing · Excel (CSV) for analysis',
            style: TextStyle(fontSize: 11.5, color: _muted),
          ),
        ),
        const SizedBox(height: 14),
        // Chunked into rows instead of a Wrap so that IntrinsicHeight can
        // line the cards up: cards in the same run share the taller one's
        // height and pin their export buttons to the bottom, instead of
        // ending at four different heights.
        for (var r = 0; r < rows.length; r++) ...[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: 16),
                  if (c < rows[r].length)
                    Expanded(child: _reportCard(rows[r][c], updated))
                  else
                    SizedBox(width: cardW),
                ],
              ],
            ),
          ),
          if (r < rows.length - 1) const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _reportCard(_ReportSpec spec, String updated) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
        boxShadow: _shadowSm(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: spec.color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(spec.icon, size: 20, color: spec.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      spec.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: _muted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _metaChip(
                '${spec.rowCount} ${spec.rowCount == 1 ? 'row' : 'rows'}',
              ),
              _metaChip('PDF · CSV'),
              _metaChip(updated),
            ],
          ),
          // The card shares the run's tallest height, so pin the export
          // buttons to the bottom rather than leaving a gap under them.
          const Spacer(),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _exportButton(
                  label: 'PDF',
                  icon: Icons.picture_as_pdf_rounded,
                  filled: true,
                  color: spec.color,
                  onPressed: () => _exportPdf(spec.sections, spec.title),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _exportButton(
                  label: 'Excel (CSV)',
                  icon: Icons.table_chart_rounded,
                  filled: false,
                  color: spec.color,
                  onPressed: () => _exportCsv(spec.sections, spec.title),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _surfaceMuted,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _hairline),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          color: _muted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _exportButton({
    required String label,
    required IconData icon,
    required bool filled,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onPressed,
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? color : Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: filled
                ? null
                : Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: filled ? Colors.white : color),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: filled ? Colors.white : color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Quick export bar ────────────────────────────────────────────────
  Widget _quickExportCard(double width) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            available: width - 36,
            icon: Icons.bolt_rounded,
            color: const Color(0xFFD97706),
            title: 'Quick Exports',
            trailing: _chip(_periods[_period], color: const Color(0xFFD97706)),
          ),
          const SizedBox(height: 14),
          const Text(
            'One-click delivery of the whole reporting pack for the TVET MARA administration.',
            style: TextStyle(fontSize: 12.5, color: _muted, height: 1.4),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _secondaryButton(
                label: 'Export all (PDF)',
                icon: Icons.picture_as_pdf_rounded,
                color: AppTheme.navy,
                filled: true,
                onPressed: () =>
                    _exportPdf(_allSections, 'TVET MARA System Report'),
              ),
              _secondaryButton(
                label: 'Download CSV',
                icon: Icons.download_rounded,
                color: AppTheme.success,
                filled: false,
                onPressed: () =>
                    _exportCsv(_allSections, 'TVET MARA System Report'),
              ),
              _secondaryButton(
                label: 'Email summary',
                icon: Icons.mail_outline_rounded,
                color: AppTheme.maraBlue,
                filled: false,
                onPressed: _emailSummary,
              ),
              _secondaryButton(
                label: 'Copy KPI summary',
                icon: Icons.copy_rounded,
                color: _slate,
                filled: false,
                onPressed: _copySummary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static const Color _slate = Color(0xFF475569);

  Future<void> _copySummary() async {
    final text = StringBuffer()
      ..writeln('TVET MARA Administration — ${_periods[_period]} summary')
      ..writeln('Generated: $_dateLabel')
      ..writeln('Attendance rate: $_attendanceRate% ($_checkedIn/$_expected)')
      ..writeln('On time: $_onTime · Late: $_late · Absent: $_absent')
      ..writeln(
        'Staff: ${widget.staff.length} · Departments: ${_deptStats.length}',
      )
      ..writeln('Pending approvals: ${widget.pendingApprovals}');
    for (final d in _deptStats) {
      text.writeln('${d.name}: ${d.rate}% (${d.present}/${d.staff})');
    }
    try {
      await Clipboard.setData(ClipboardData(text: text.toString()));
      _toast('KPI summary copied to the clipboard.');
    } catch (_) {
      _toast('Could not copy the summary.');
    }
  }

  Widget _secondaryButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool filled,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: filled ? color : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: filled
                ? null
                : Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15.5, color: filled ? Colors.white : color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: filled ? Colors.white : color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated horizontal progress bar used by the department table.
class _PercentBar extends StatelessWidget {
  const _PercentBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    final color = clamped >= 0.9
        ? AppTheme.success
        : clamped >= 0.75
        ? AppTheme.maraBlue
        : clamped >= 0.6
        ? const Color(0xFFD97706)
        : AppTheme.maraRed;
    return Container(
      height: 8,
      decoration: BoxDecoration(
        color: const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: clamped == 0 ? 0.001 : clamped,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

/// Donut chart: on-time / late / absent segments around a light track.
class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.segments});

  /// `(value, colour)` pairs; zero-value segments are skipped.
  final List<(double, Color)> segments;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const stroke = 17.0;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFFF1F5F9);
    canvas.drawArc(rect, 0, math.pi * 2, false, track);

    final total = segments.fold<double>(0, (sum, s) => sum + s.$1);
    if (total <= 0) return;

    var start = -math.pi / 2;
    for (final (value, color) in segments) {
      if (value <= 0) continue;
      final sweep = (value / total) * math.pi * 2;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..color = color;
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.segments != segments;
}
