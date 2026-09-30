class ReportPeriod {
  final DateTime start;
  final DateTime end;

  const ReportPeriod({required this.start, required this.end});

  String get label =>
      '${_month(start.month)} ${start.year} - '
      '${_month(end.month)} ${end.year}';

  static List<ReportPeriod> recent({DateTime? now, int count = 4}) {
    final date = now ?? DateTime.now();
    var start = date.month <= 6
        ? DateTime(date.year, 1, 1)
        : DateTime(date.year, 7, 1);
    return List.generate(count, (_) {
      final period = ReportPeriod(
        start: start,
        end: DateTime(start.year, start.month + 6, 0),
      );
      start = DateTime(start.year, start.month - 6, 1);
      return period;
    });
  }

  static String _month(int month) => const [
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
  ][month - 1];
}

class AttendanceDay {
  final DateTime date;
  final DateTime? punchIn;
  final DateTime? punchOut;
  final String status;
  final String? leaveType;

  const AttendanceDay({
    required this.date,
    this.punchIn,
    this.punchOut,
    required this.status,
    this.leaveType,
  });
}

class StaffAttendanceReport {
  final String staffId;
  final String name;
  final String staffNumber;
  final String department;
  final String position;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int expectedDays;
  final int present;
  final int late;
  final int approvedLeave;
  final int absent;
  final int pendingLate;
  final int missingPunchOut;
  final List<AttendanceDay> days;

  const StaffAttendanceReport({
    required this.staffId,
    required this.name,
    required this.staffNumber,
    required this.department,
    required this.position,
    required this.periodStart,
    required this.periodEnd,
    required this.expectedDays,
    required this.present,
    required this.late,
    required this.approvedLeave,
    required this.absent,
    required this.pendingLate,
    required this.missingPunchOut,
    required this.days,
  });

  int get attended => present + late;
  int get attendanceTarget => expectedDays - approvedLeave;
  double get attendanceRate => attendanceTarget <= 0
      ? 0
      : (attended / attendanceTarget * 100).clamp(0, 100);
}

class AttendanceReportCalculator {
  const AttendanceReportCalculator._();

  static StaffAttendanceReport calculate({
    required Map<String, dynamic> staff,
    required List<Map<String, dynamic>> attendance,
    required List<Map<String, dynamic>> leaves,
    required DateTime periodStart,
    required DateTime periodEnd,
    DateTime? today,
  }) {
    final now = _dateOnly(today ?? DateTime.now());
    var end = _dateOnly(periodEnd);
    if (end.isAfter(now)) end = now;
    var start = _dateOnly(periodStart);
    final createdAt = DateTime.tryParse(staff['created_at']?.toString() ?? '');
    if (createdAt != null && _dateOnly(createdAt.toLocal()).isAfter(start)) {
      start = _dateOnly(createdAt.toLocal());
    }

    final attendanceByDate = <String, Map<String, dynamic>>{};
    for (final row in attendance) {
      final punchIn = DateTime.tryParse(row['punch_in']?.toString() ?? '');
      if (punchIn != null) {
        attendanceByDate[_key(punchIn.toLocal())] = row;
      }
    }

    final approvedLeaveByDate = <String, String>{};
    for (final leave in leaves.where((l) => l['status'] == 'approved')) {
      final leaveStart = DateTime.tryParse(
        leave['start_date']?.toString() ?? '',
      );
      final leaveEnd = DateTime.tryParse(leave['end_date']?.toString() ?? '');
      if (leaveStart == null || leaveEnd == null) continue;
      for (
        var day = _dateOnly(leaveStart);
        !day.isAfter(_dateOnly(leaveEnd));
        day = day.add(const Duration(days: 1))
      ) {
        approvedLeaveByDate[_key(day)] =
            leave['leave_type']?.toString() ?? 'Leave';
      }
    }

    var expected = 0;
    var present = 0;
    var late = 0;
    var approvedLeave = 0;
    var absent = 0;
    var pendingLate = 0;
    var missingPunchOut = 0;
    final days = <AttendanceDay>[];

    if (!start.isAfter(end)) {
      for (
        var day = start;
        !day.isAfter(end);
        day = day.add(const Duration(days: 1))
      ) {
        if (!isWorkday(day)) continue;
        expected++;
        final row = attendanceByDate[_key(day)];
        final leaveType = approvedLeaveByDate[_key(day)];
        DateTime? punchIn;
        DateTime? punchOut;
        String status;

        if (row != null) {
          punchIn = DateTime.tryParse(
            row['punch_in']?.toString() ?? '',
          )?.toLocal();
          punchOut = DateTime.tryParse(
            row['punch_out']?.toString() ?? '',
          )?.toLocal();
          if (punchOut == null) missingPunchOut++;
          if (row['late_approved'] != true) {
            pendingLate++;
            status = 'Pending late approval';
          } else if (row['status'] == 'late') {
            late++;
            status = 'Late';
          } else {
            present++;
            status = 'Present';
          }
        } else if (leaveType != null) {
          approvedLeave++;
          status = 'Approved leave';
        } else {
          absent++;
          status = 'Absent';
        }

        days.add(
          AttendanceDay(
            date: day,
            punchIn: punchIn,
            punchOut: punchOut,
            status: status,
            leaveType: leaveType,
          ),
        );
      }
    }

    final department = staff['departments'] is Map
        ? staff['departments']['name']?.toString()
        : null;
    return StaffAttendanceReport(
      staffId: staff['id'].toString(),
      name: staff['full_name']?.toString() ?? 'Unknown',
      staffNumber: staff['staff_number']?.toString() ?? '-',
      department: department ?? '-',
      position: staff['position']?.toString() ?? '-',
      periodStart: _dateOnly(periodStart),
      periodEnd: end,
      expectedDays: expected,
      present: present,
      late: late,
      approvedLeave: approvedLeave,
      absent: absent,
      pendingLate: pendingLate,
      missingPunchOut: missingPunchOut,
      days: days,
    );
  }

  /// TVET MARA workweek: Sunday through Thursday.
  static bool isWorkday(DateTime date) =>
      date.weekday == DateTime.sunday || date.weekday <= DateTime.thursday;

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static String _key(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
