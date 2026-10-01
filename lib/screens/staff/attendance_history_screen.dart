import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/staff/staff_page_header.dart';
import '../../models/attendance_report.dart';
import '../../services/auth_service.dart';
import '../../utils/malaysia_time.dart';

// --- DATA MODELS ---
enum AttendanceStatus { onTime, late, absent, pending, leave }

class AttendanceLog {
  final DateTime date;
  final String? recordId;
  final String? appealStatus;
  final String dateLabel; // e.g. "July 21"
  final String weekday; // e.g. "Tuesday"
  final AttendanceStatus status;
  final String? badgeText; // e.g. "+22m", "On Time", "Absent"
  final String? checkIn;
  final String? checkOut;
  final String? lateNote; // e.g. "7 mins late"
  final String? absenceReason; // populated once the staff explains an absence
  final String?
  punchInRemark; // reason captured automatically at punch-in when late

  const AttendanceLog({
    required this.date,
    this.recordId,
    this.appealStatus,
    required this.dateLabel,
    required this.weekday,
    required this.status,
    this.badgeText,
    this.checkIn,
    this.checkOut,
    this.lateNote,
    this.absenceReason,
    this.punchInRemark,
  });
}

class AttendanceHistoryScreen extends StatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  State<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  // --- Calendar data (live from Supabase) ---
  late DateTime _viewedMonth;
  String _monthLabel = "";
  int _daysInMonth = 0;
  int _leadingEmptyCells = 0;
  int _selectedDay = 0;

  // day number -> status
  Map<int, AttendanceStatus> _attendanceMap = {};
  List<AttendanceLog> _logs = [];
  Map<String, dynamic>? _today;

  bool _isLoading = true;
  String? _loadError;
  int _loadVersion = 0;

  // index of the log card that's expanded
  int? _expandedIndex;

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _weekdayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  @override
  void initState() {
    super.initState();
    final now = MalaysiaTime.now();
    _viewedMonth = DateTime(now.year, now.month, 1);
    _selectedDay = 0;
    _loadFromSupabase();
  }

  Future<void> _loadFromSupabase() async {
    final version = ++_loadVersion;
    final month = _viewedMonth;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final rows = await DatabaseService.getMyAttendanceForMonth(
        year: month.year,
        month: month.month,
      );
      final todayRow = await DatabaseService.getTodayAttendance();
      final profile = await AuthService.getCurrentProfile();
      final leaves = await DatabaseService.getMyLeaves();
      if (profile == null) throw Exception('Staff profile not found.');
      final report = AttendanceReportCalculator.calculate(
        staff: profile,
        attendance: rows,
        leaves: leaves,
        periodStart: month,
        periodEnd: DateTime(month.year, month.month + 1, 0),
      );
      final byDay = <int, Map<String, dynamic>>{};
      for (final row in rows) {
        final punch = MalaysiaTime.parse(row['punch_in'] as String?);
        if (punch != null) byDay[punch.day] = row;
      }
      // Missing workdays and approved leave are calculated, not fabricated rows.
      for (final day in report.days) {
        byDay.putIfAbsent(
          day.date.day,
          () => {
            'status': day.status == 'Approved leave' ? 'leave' : 'absent',
            'display_date': day.date,
          },
        );
      }

      final Map<int, AttendanceStatus> dayMap = {};
      final List<AttendanceLog> logs = [];

      for (final entry
          in byDay.entries.toList()..sort((a, b) => b.key.compareTo(a.key))) {
        final row = entry.value;
        final punchIn = MalaysiaTime.parse(row['punch_in'] as String?);
        final date = punchIn ?? row['display_date'] as DateTime;
        final day = entry.key;
        final statusStr = row['status'] as String? ?? 'present';
        final AttendanceStatus status;
        switch (statusStr) {
          case 'late':
            status = row['late_approved'] == true
                ? AttendanceStatus.late
                : AttendanceStatus.pending;
            break;
          case 'absent':
            status = AttendanceStatus.absent;
            break;
          case 'leave':
            status = AttendanceStatus.leave;
            break;
          default:
            status = row['late_approved'] == true
                ? AttendanceStatus.onTime
                : AttendanceStatus.pending;
        }
        dayMap[day] = status;

        final punchOutStr = row['punch_out'] as String?;
        final punchOut = MalaysiaTime.parse(punchOutStr);
        final remark =
            (row['late_reason'] ?? row['punch_in_remark']) as String?;
        final notes = row['notes'] as String?;

        // Determine lateness in minutes (assuming 08:00 = on time)
        final lateMinutes = punchIn == null
            ? 0
            : (punchIn.hour * 60 + punchIn.minute - 8 * 60).clamp(0, 1440);

        logs.add(
          AttendanceLog(
            date: DateTime(date.year, date.month, date.day),
            recordId: row['id'] as String?,
            appealStatus: row['appeal_status'] as String?,
            dateLabel: "${_monthNames[date.month - 1]} ${date.day}",
            weekday: _weekdayNames[date.weekday - 1],
            status: status,
            badgeText: status == AttendanceStatus.late
                ? "+${lateMinutes}m"
                : switch (status) {
                    AttendanceStatus.pending => 'Pending',
                    AttendanceStatus.leave => 'Leave',
                    AttendanceStatus.absent => 'Absent',
                    _ => 'On Time',
                  },
            checkIn: punchIn == null || status == AttendanceStatus.absent
                ? null
                : _formatTime(punchIn),
            checkOut: punchOut != null && status != AttendanceStatus.absent
                ? _formatTime(punchOut)
                : null,
            lateNote: status == AttendanceStatus.late
                ? "$lateMinutes mins late"
                : null,
            absenceReason: status == AttendanceStatus.absent ? notes : null,
            punchInRemark: remark,
          ),
        );
      }

      if (!mounted || version != _loadVersion) return;
      setState(() {
        _attendanceMap = dayMap;
        _logs = logs;
        _today = todayRow;
        _monthLabel =
            "${_monthNames[_viewedMonth.month - 1]} ${_viewedMonth.year}";
        _daysInMonth = DateTime(
          _viewedMonth.year,
          _viewedMonth.month + 1,
          0,
        ).day;
        // weekday: Monday=1 .. Sunday=7 (Dart), convert to leading empties (Sunday=0)
        final firstWeekday = DateTime(
          _viewedMonth.year,
          _viewedMonth.month,
          1,
        ).weekday;
        _leadingEmptyCells = firstWeekday % 7; // Sun=0, Mon=1..Sat=6
        _expandedIndex = logs.isNotEmpty ? 0 : null;
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return "${hour.toString().padLeft(2, '0')}:$minute $ampm";
  }

  void _changeMonth(int delta) {
    setState(() {
      _viewedMonth = DateTime(_viewedMonth.year, _viewedMonth.month + delta, 1);
      _selectedDay = 0;
    });
    _loadFromSupabase();
  }

  Color _statusColor(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.onTime:
        return AppTheme.success;
      case AttendanceStatus.late:
        return AppTheme.goldDeep;
      case AttendanceStatus.absent:
        return AppTheme.maraRed;
      case AttendanceStatus.pending:
        return Colors.orange;
      case AttendanceStatus.leave:
        return AppTheme.maraBlue;
    }
  }

  IconData _statusIcon(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.onTime:
        return Icons.check;
      case AttendanceStatus.late:
        return Icons.access_time;
      case AttendanceStatus.absent:
        return Icons.close;
      case AttendanceStatus.pending:
        return Icons.hourglass_empty;
      case AttendanceStatus.leave:
        return Icons.event_available;
    }
  }

  Future<void> _openAppealModal(AttendanceLog log) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _AppealModalSheet(log: log),
    );
    if (saved == true && mounted) await _loadFromSupabase();
  }

  @override
  Widget build(BuildContext context) {
    final onTimeCount = _attendanceMap.values
        .where((s) => s == AttendanceStatus.onTime)
        .length;
    final lateCount = _attendanceMap.values
        .where((s) => s == AttendanceStatus.late)
        .length;
    final absentCount = _attendanceMap.values
        .where((s) => s == AttendanceStatus.absent)
        .length;

    return Scaffold(
      backgroundColor: AppTheme.bgBottom,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: AppTheme.maraRed,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Failed to load: $_loadError',
                    style: const TextStyle(
                      color: AppTheme.maraRed,
                      fontSize: 12,
                    ),
                  ),
                  TextButton(
                    onPressed: _loadFromSupabase,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StaffPageHeader(title: 'Attendance', subtitle: _monthLabel),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildTodayCard(),
                        const SizedBox(height: 12),
                        _buildMetricsRow(onTimeCount, lateCount, absentCount),
                        const SizedBox(height: 12),
                        _buildCalendarCard(),
                        const SizedBox(height: 20),
                        _buildLogsSection(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // --- "Today" status card: compact, structured, theme-matched ---
  Widget _buildTodayCard() {
    final now = MalaysiaTime.now();
    final label = "${now.day} ${_monthNames[now.month - 1]} ${now.year}";
    final punchIn = _today?['punch_in'] as String?;
    final punchOut = _today?['punch_out'] as String?;
    final punchInDt = MalaysiaTime.parse(punchIn);
    final punchOutDt = MalaysiaTime.parse(punchOut);
    final statusStr = _today?['status'] as String?;

    final String badgeText;
    final Color badgeColor;
    if (punchInDt == null) {
      badgeText = 'Not checked in';
      badgeColor = AppTheme.textFaint;
    } else if (_today?['late_approved'] != true) {
      badgeText = 'Pending approval';
      badgeColor = Colors.orange;
    } else if (statusStr == 'late') {
      badgeText = 'Late';
      badgeColor = AppTheme.goldDeep;
    } else {
      badgeText = 'Present';
      badgeColor = AppTheme.success;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEAEDF5)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Today',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppTheme.textFaint,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.30)),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _timeTile(
                  'CHECK-IN',
                  punchInDt != null ? _formatTime(punchInDt) : null,
                  null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _timeTile(
                  'CHECK-OUT',
                  punchOutDt != null ? _formatTime(punchOutDt) : null,
                  null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Summary metrics: Present / On Time / Late / Absent — 2×2 grid of
  // professional bordered cards in the navy/purple + gold + status palette.
  Widget _buildMetricsRow(int onTimeCount, int lateCount, int absentCount) {
    final presentCount = onTimeCount + lateCount;
    final metrics = <(String, String, IconData, Color)>[
      (
        '$presentCount',
        'Present',
        Icons.check_circle_rounded,
        AppTheme.success,
      ),
      ('$onTimeCount', 'On Time', Icons.verified_rounded, AppTheme.navy),
      ('$lateCount', 'Late', Icons.access_time_rounded, AppTheme.goldDeep),
      ('$absentCount', 'Absent', Icons.cancel_rounded, AppTheme.maraRed),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Monthly overview',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: metrics.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 86,
          ),
          itemBuilder: (context, i) => _metricCard(
            value: metrics[i].$1,
            label: metrics[i].$2,
            icon: metrics[i].$3,
            color: metrics[i].$4,
          ),
        ),
      ],
    );
  }

  Widget _metricCard({
    required String value,
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEAEDF5)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Compact monthly calendar: standard grid, themed accents ---
  Widget _buildCalendarCard() {
    final totalCells = _leadingEmptyCells + _daysInMonth;
    final today = DateTime.now();
    final isCurrentMonth =
        _viewedMonth.year == today.year && _viewedMonth.month == today.month;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEAEDF5)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Slim month navigator with mini themed buttons.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _monthNavButton(
                icon: Icons.chevron_left_rounded,
                onTap: () => _changeMonth(-1),
              ),
              Text(
                _monthLabel,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.navy,
                  letterSpacing: -0.2,
                ),
              ),
              _monthNavButton(
                icon: Icons.chevron_right_rounded,
                onTap: () => _changeMonth(1),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Weekday header
          Row(
            children: const ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: TextStyle(
                          color: AppTheme.textFaint,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 2),

          // Mini day grid — short fixed cells, minimal vertical footprint.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalCells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 42,
              crossAxisSpacing: 1,
              mainAxisSpacing: 1,
            ),
            itemBuilder: (context, index) {
              if (index < _leadingEmptyCells) return const SizedBox.shrink();
              final day = index - _leadingEmptyCells + 1;
              final status = _attendanceMap[day];
              final isSelected = day == _selectedDay;
              final isToday = isCurrentMonth && day == today.day;

              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _selectedDay = day),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.navy
                            : (status != null
                                  ? _statusColor(status).withValues(alpha: 0.12)
                                  : Colors.transparent),
                        shape: BoxShape.circle,
                        border: isToday && !isSelected
                            ? Border.all(color: AppTheme.navy, width: 1.2)
                            : null,
                      ),
                      child: Text(
                        "$day",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected || isToday
                              ? FontWeight.w800
                              : FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : (status == null
                                    ? AppTheme.textFaint
                                    : AppTheme.textPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: status != null
                            ? _statusColor(status)
                            : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          const SizedBox(height: 6),
          const Divider(height: 1, color: Color(0xFFEAEDF5)),
          const SizedBox(height: 6),

          // Compact legend.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendDot(AppTheme.success, "On Time"),
              const SizedBox(width: 16),
              _legendDot(AppTheme.goldDeep, "Late"),
              const SizedBox(width: 16),
              _legendDot(AppTheme.maraRed, "Absent"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _monthNavButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppTheme.navy.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, color: AppTheme.navy, size: 17),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  // --- Daily Logs: compact structured list with a tidy empty state ---
  Widget _buildLogsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                "Daily Logs (${_logs.length})",
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                _selectedDay = 0;
                _expandedIndex = null;
              }),
              child: const Text(
                "See All",
                style: TextStyle(
                  color: AppTheme.navy,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _logs.isEmpty
            ? Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 22,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFEAEDF5)),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.event_note_rounded,
                      size: 28,
                      color: AppTheme.textFaint,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'No attendance logs for this month yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _selectedDay == 0
                    ? _logs.length
                    : _logs.where((log) => log.date.day == _selectedDay).length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) => _buildLogCard(
                  _selectedDay == 0
                      ? index
                      : _logs.indexOf(
                          _logs
                              .where((log) => log.date.day == _selectedDay)
                              .elementAt(index),
                        ),
                ),
              ),
      ],
    );
  }

  Widget _buildLogCard(int index) {
    final log = _logs[index];
    final isExpanded = _expandedIndex == index;
    final color = _statusColor(log.status);

    return Container(
      decoration: AppTheme.glassCard(radius: 15),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () {
              setState(() {
                _expandedIndex = isExpanded ? null : index;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _statusIcon(log.status),
                      color: color,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          log.dateLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          log.weekday,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (log.badgeText != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        log.badgeText!,
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.grey[400],
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) _buildExpandedContent(log),
        ],
      ),
    );
  }

  Widget _buildExpandedContent(AttendanceLog log) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
      child: Column(
        children: [
          const Divider(),
          if (log.status != AttendanceStatus.absent)
            Row(
              children: [
                Expanded(
                  child: _timeTile("CHECK-IN", log.checkIn, log.lateNote),
                ),
                const SizedBox(width: 12),
                Expanded(child: _timeTile("CHECK-OUT", log.checkOut, null)),
              ],
            ),
          if ((log.status == AttendanceStatus.late ||
                  log.status == AttendanceStatus.pending) &&
              log.punchInRemark != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.gold.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.gold.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: AppTheme.goldDeep,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "PUNCH-IN REMARK (RECORDED)",
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey[500],
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          log.punchInRemark!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (log.status == AttendanceStatus.absent)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.maraRed.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.maraRed.withValues(alpha: 0.15),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "REASON FOR ABSENCE",
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    log.absenceReason ?? "No reason submitted yet.",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: log.absenceReason == null
                          ? Colors.grey[500]
                          : Colors.black87,
                      fontStyle: log.absenceReason == null
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
          // Lateness is recorded automatically at punch-in (see the
          // remark box above) and no longer needs a separate appeal — this
          // action is only for planned Leave Applications and MC uploads on
          // days marked absent.
          if (log.status == AttendanceStatus.absent) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: () => _openAppealModal(log),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text("Submit Leave Application / MC Request"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.navy,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
          if ((log.status == AttendanceStatus.late ||
                  log.status == AttendanceStatus.pending) &&
              log.recordId != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: log.appealStatus == 'pending'
                  ? null
                  : () => _openAppealModal(log),
              child: Text(
                log.appealStatus == 'pending'
                    ? 'Appeal awaiting review'
                    : 'Submit lateness appeal',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _timeTile(String label, String? value, String? note) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEAEDF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.textFaint,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value ?? "--",
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note,
              style: const TextStyle(
                color: AppTheme.goldDeep,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// --- APPEAL / MEDICAL LEAVE MODAL (kept from previous app, unchanged) ---
class _AppealModalSheet extends StatefulWidget {
  final AttendanceLog log;
  const _AppealModalSheet({required this.log});

  @override
  State<_AppealModalSheet> createState() => _AppealModalSheetState();
}

class _AppealModalSheetState extends State<_AppealModalSheet> {
  final TextEditingController _reasonController = TextEditingController();
  final TextEditingController _documentController = TextEditingController();
  String _leaveType = 'annual';
  String? _error;
  bool _isSubmitting = false;
  bool _isSuccess = false;

  @override
  void dispose() {
    _reasonController.dispose();
    _documentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_reasonController.text.trim().isEmpty || _isSubmitting) return;

    final document = _documentController.text.trim();
    final uri = Uri.tryParse(document);
    if (document.isNotEmpty &&
        (uri == null || uri.scheme != 'https' || uri.host.isEmpty)) {
      setState(() => _error = 'Enter a valid HTTPS document link.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      if (widget.log.status == AttendanceStatus.absent) {
        await DatabaseService.submitLeave(
          leaveType: _leaveType,
          startDate: widget.log.date,
          endDate: widget.log.date,
          reason: _reasonController.text.trim(),
          supportingDocumentUrl: document.isEmpty ? null : document,
        );
      } else {
        await DatabaseService.submitAttendanceAppeal(
          attendanceId: widget.log.recordId!,
          reason: _reasonController.text.trim(),
        );
      }
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _isSuccess = true;
      });
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.log;
    final canSubmit =
        _reasonController.text.trim().isNotEmpty &&
        !_isSubmitting &&
        !_isSuccess;

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    log.status == AttendanceStatus.absent
                        ? "Leave Application & MC Request"
                        : "Lateness Appeal",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.navy,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Text(
              "${log.dateLabel} · ${log.weekday}",
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 20),
            if (log.status == AttendanceStatus.absent) ...[
              DropdownButtonFormField<String>(
                initialValue: _leaveType,
                decoration: const InputDecoration(labelText: 'Leave type'),
                items: const [
                  DropdownMenuItem(
                    value: 'annual',
                    child: Text('Annual Leave'),
                  ),
                  DropdownMenuItem(
                    value: 'sick',
                    child: Text('Medical / Sick Leave'),
                  ),
                  DropdownMenuItem(
                    value: 'emergency',
                    child: Text('Emergency Leave'),
                  ),
                  DropdownMenuItem(
                    value: 'unpaid',
                    child: Text('Unpaid Leave'),
                  ),
                  DropdownMenuItem(
                    value: 'maternity',
                    child: Text('Maternity Leave'),
                  ),
                ],
                onChanged: _isSubmitting
                    ? null
                    : (value) => setState(() => _leaveType = value ?? 'annual'),
              ),
              const SizedBox(height: 16),
            ],
            const Text(
              "REASON / REMARKS",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _reasonController,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: "Briefly describe the reason for your absence...",
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (log.status == AttendanceStatus.absent)
              TextField(
                controller: _documentController,
                enabled: !_isSubmitting,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'MC / supporting document link (optional)',
                  hintText: 'https://…',
                  helperText:
                      'Paste a document link that your administrator can access.',
                  helperMaxLines: 2,
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.maraRed),
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: canSubmit ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isSuccess
                      ? AppTheme.success
                      : AppTheme.navy,
                  disabledBackgroundColor: Colors.grey[300],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : _isSuccess
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            "Submitted!",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        "Submit Application",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
