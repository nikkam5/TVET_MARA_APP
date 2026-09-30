import 'package:flutter_test/flutter_test.dart';
import 'package:tvet_staff_app/models/attendance_report.dart';

void main() {
  const staff = {
    'id': 'staff-1',
    'full_name': 'Test Staff',
    'staff_number': 'S001',
    'staff_grade': 'DG9',
    'created_at': '2025-01-01T00:00:00Z',
    'departments': {'name': 'Technology'},
  };

  test('workweek is Sunday through Thursday', () {
    expect(AttendanceReportCalculator.isWorkday(DateTime(2026, 8, 23)), isTrue);
    expect(AttendanceReportCalculator.isWorkday(DateTime(2026, 8, 27)), isTrue);
    expect(AttendanceReportCalculator.isWorkday(DateTime(2026, 8, 28)), isFalse);
    expect(AttendanceReportCalculator.isWorkday(DateTime(2026, 8, 29)), isFalse);
  });

  test('counts attendance, approved leave, absence, and incomplete records', () {
    final report = AttendanceReportCalculator.calculate(
      staff: staff,
      periodStart: DateTime(2026, 8, 23),
      periodEnd: DateTime(2026, 8, 29),
      today: DateTime(2026, 8, 29),
      attendance: const [
        {
          'punch_in': '2026-08-23T00:00:00Z',
          'punch_out': '2026-08-23T09:00:00Z',
          'status': 'present',
          'late_approved': true,
        },
        {
          'punch_in': '2026-08-24T00:30:00Z',
          'punch_out': null,
          'status': 'late',
          'late_approved': true,
        },
        {
          'punch_in': '2026-08-25T01:00:00Z',
          'punch_out': null,
          'status': 'late',
          'late_approved': false,
        },
      ],
      leaves: const [
        {
          'start_date': '2026-08-26',
          'end_date': '2026-08-26',
          'leave_type': 'annual',
          'status': 'approved',
        },
      ],
    );

    expect(report.expectedDays, 5);
    expect(report.present, 1);
    expect(report.late, 1);
    expect(report.pendingLate, 1);
    expect(report.approvedLeave, 1);
    expect(report.absent, 1);
    expect(report.missingPunchOut, 2);
    expect(report.attendanceRate, 50);
  });

  test('current period stops at today and starts at account creation', () {
    final report = AttendanceReportCalculator.calculate(
      staff: {
        ...staff,
        'created_at': '2026-08-25T00:00:00Z',
      },
      attendance: const [],
      leaves: const [],
      periodStart: DateTime(2026, 8, 23),
      periodEnd: DateTime(2026, 12, 31),
      today: DateTime(2026, 8, 27),
    );

    expect(report.periodEnd, DateTime(2026, 8, 27));
    expect(report.expectedDays, 3);
    expect(report.absent, 3);
  });

  test('attendance takes precedence over overlapping approved leave', () {
    final report = AttendanceReportCalculator.calculate(
      staff: staff,
      attendance: const [
        {
          'punch_in': '2026-08-23T00:00:00Z',
          'punch_out': '2026-08-23T09:00:00Z',
          'status': 'present',
          'late_approved': true,
        },
      ],
      leaves: const [
        {
          'start_date': '2026-08-23',
          'end_date': '2026-08-23',
          'leave_type': 'annual',
          'status': 'approved',
        },
      ],
      periodStart: DateTime(2026, 8, 23),
      periodEnd: DateTime(2026, 8, 23),
      today: DateTime(2026, 8, 23),
    );

    expect(report.present, 1);
    expect(report.approvedLeave, 0);
    expect(report.attendanceRate, 100);
  });
}
