import 'package:flutter/material.dart';

import '../../models/attendance_report.dart';
import '../../services/reports/attendance_report_pdf_service.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../widgets/admin/admin_ui.dart';

class ReportGeneratorScreen extends StatefulWidget {
  final bool adminMode;
  final bool showAppBar;
  final ReportPeriod? initialPeriod;

  const ReportGeneratorScreen({
    super.key,
    this.adminMode = false,
    this.showAppBar = true,
    this.initialPeriod,
  });

  @override
  State<ReportGeneratorScreen> createState() => _ReportGeneratorScreenState();
}

class _ReportGeneratorScreenState extends State<ReportGeneratorScreen> {
  late final List<ReportPeriod> _periods;
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _departments = [];
  List<StaffAttendanceReport> _reports = [];
  late ReportPeriod _period;
  String? _departmentId;
  String? _staffId;
  bool _loading = true;
  bool _generating = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _periods = [
      if (widget.initialPeriod != null) widget.initialPeriod!,
      ...ReportPeriod.recent().where(
        (period) =>
            widget.initialPeriod == null ||
            period.start != widget.initialPeriod!.start ||
            period.end != widget.initialPeriod!.end,
      ),
    ];
    _period = _periods.first;
    _loadFilters();
  }

  Future<void> _loadFilters() async {
    try {
      if (widget.adminMode) {
        final results = await Future.wait([
          DatabaseService.getDepartments(),
          DatabaseService.getStaffDirectoryFull(),
        ]);
        _departments = results[0];
        _staff = results[1]
            .where((row) => row['is_active'] == true && row['role'] != 'admin')
            .toList();
      } else {
        final profile = await AuthService.getCurrentProfile();
        if (profile == null) throw Exception('Staff profile not found.');
        _staff = [profile];
        _staffId = profile['id']?.toString();
      }
      if (!mounted) return;
      setState(() => _loading = false);
      await _generate();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _filteredStaff => _staff.where((row) {
    if (_departmentId != null &&
        row['department_id']?.toString() != _departmentId) {
      return false;
    }
    if (_staffId != null && row['id']?.toString() != _staffId) return false;
    return true;
  }).toList();

  Future<void> _generate() async {
    if (_generating) return;
    final selected = _filteredStaff;
    if (selected.isEmpty) {
      setState(() {
        _reports = [];
        _error = 'No active staff match the selected filters.';
      });
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final reports = await Future.wait(selected.map(_loadReport));
      reports.sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() => _reports = reports);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not generate report: $error');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<StaffAttendanceReport> _loadReport(Map<String, dynamic> staff) async {
    final id = staff['id'].toString();
    final results = await Future.wait([
      DatabaseService.getAttendanceForReport(
        staffId: id,
        start: _period.start,
        end: _period.end,
      ),
      DatabaseService.getLeavesForReport(
        staffId: id,
        start: _period.start,
        end: _period.end,
      ),
    ]);
    return AttendanceReportCalculator.calculate(
      staff: staff,
      attendance: results[0],
      leaves: results[1],
      periodStart: _period.start,
      periodEnd: _period.end,
    );
  }

  Future<void> _pdf(bool print) async {
    if (_reports.isEmpty || _exporting) return;
    setState(() => _exporting = true);
    try {
      if (print) {
        await AttendanceReportPdfService.printReport(
          reports: _reports,
          periodLabel: _period.label,
        );
      } else {
        await AttendanceReportPdfService.share(
          reports: _reports,
          periodLabel: _period.label,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _generate,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.adminMode)
                  const AdminPageHeading(
                    title: 'Reports & insights',
                    subtitle:
                        'Turn attendance data into a clear picture. Filter, review and export your reports.',
                  ),
                _filters(),
                if (_error != null) _errorCard(),
                if (_generating)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_reports.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _summary(),
                  const SizedBox(height: 16),
                  ..._reports.map(_staffCard),
                ],
              ],
            ),
          );
    if (!widget.showAppBar) {
      return widget.adminMode
          ? Theme(
              data: AdminUi.theme(context),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: content,
                ),
              ),
            )
          : content;
    }
    if (widget.adminMode) {
      return AdminPage(
        title: 'System reports',
        subtitle: 'Attendance insights for your institution.',
        body: content,
      );
    }
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Text(
          widget.adminMode ? 'System Reports' : 'My Attendance Report',
        ),
        backgroundColor: const Color(0xFF002060),
        foregroundColor: Colors.white,
        actions: _actions(),
      ),
      body: content,
    );
  }

  List<Widget> _actions() => [
    IconButton(
      tooltip: 'Print report',
      onPressed: _reports.isEmpty || _exporting ? null : () => _pdf(true),
      icon: const Icon(Icons.print_outlined),
    ),
    IconButton(
      tooltip: 'Export PDF',
      onPressed: _reports.isEmpty || _exporting ? null : () => _pdf(false),
      icon: const Icon(Icons.picture_as_pdf_outlined),
    ),
  ];

  Widget _filters() {
    final availableStaff = _staff
        .where(
          (row) =>
              _departmentId == null ||
              row['department_id']?.toString() == _departmentId,
        )
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Report settings',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF002060),
                    ),
                  ),
                ),
                if (!widget.showAppBar) ..._actions(),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.adminMode) ...[
              DropdownButtonFormField<String?>(
                isExpanded: true,
                initialValue: _departmentId,
                decoration: const InputDecoration(
                  labelText: 'Department',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All Departments'),
                  ),
                  ..._departments.map(
                    (row) => DropdownMenuItem(
                      value: row['id'].toString(),
                      child: Text(row['name']?.toString() ?? '-'),
                    ),
                  ),
                ],
                onChanged: _generating
                    ? null
                    : (value) => setState(() {
                        _departmentId = value;
                        _staffId = null;
                        _reports = [];
                      }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: ValueKey(_departmentId),
                isExpanded: true,
                initialValue: _staffId,
                decoration: const InputDecoration(
                  labelText: 'Staff',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Staff')),
                  ...availableStaff.map(
                    (row) => DropdownMenuItem(
                      value: row['id'].toString(),
                      child: Text(
                        '${row['full_name']} (${row['staff_number']})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: _generating
                    ? null
                    : (value) => setState(() {
                        _staffId = value;
                        _reports = [];
                      }),
              ),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<ReportPeriod>(
              isExpanded: true,
              initialValue: _period,
              decoration: const InputDecoration(
                labelText: 'Reporting period',
                border: OutlineInputBorder(),
              ),
              items: _periods
                  .map(
                    (period) => DropdownMenuItem(
                      value: period,
                      child: Text(period.label),
                    ),
                  )
                  .toList(),
              onChanged: _generating
                  ? null
                  : (period) => setState(() {
                      if (period != null) _period = period;
                      _reports = [];
                    }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generating ? null : _generate,
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('Generate Report'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF002060),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard() => Card(
    color: Colors.red[50],
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    ),
  );

  Widget _summary() {
    final expected = _reports.fold(0, (sum, item) => sum + item.expectedDays);
    final present = _reports.fold(0, (sum, item) => sum + item.present);
    final late = _reports.fold(0, (sum, item) => sum + item.late);
    final leave = _reports.fold(0, (sum, item) => sum + item.approvedLeave);
    final absent = _reports.fold(0, (sum, item) => sum + item.absent);
    final target = expected - leave;
    final rate = target <= 0
        ? 0.0
        : ((present + late) / target * 100).clamp(0, 100);
    return Card(
      color: const Color(0xFF002060),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_period.label} | ${_reports.length} staff',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _metric('Expected', expected.toString()),
                _metric('Present', present.toString()),
                _metric('Late', late.toString()),
                _metric('Leave', leave.toString()),
                _metric('Absent', absent.toString()),
                _metric('Rate', '${rate.toStringAsFixed(1)}%'),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Sunday-Thursday workweek. Public holidays are not excluded.',
              style: TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Container(
    width: 105,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.white10,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );

  Widget _staffCard(StaffAttendanceReport report) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ExpansionTile(
      title: Text(
        report.name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text('${report.staffNumber} | ${report.department}'),
      trailing: Text(
        '${report.attendanceRate.toStringAsFixed(1)}%',
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Color(0xFF002060),
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              Text('Present ${report.present}'),
              Text('Late ${report.late}'),
              Text('Leave ${report.approvedLeave}'),
              Text('Absent ${report.absent}'),
              Text('Pending ${report.pendingLate}'),
              Text('No punch-out ${report.missingPunchOut}'),
            ],
          ),
        ),
        const Divider(height: 1),
        ...report.days.map(
          (day) => ListTile(
            dense: true,
            title: Text(_date(day.date)),
            subtitle: Text('${_time(day.punchIn)} - ${_time(day.punchOut)}'),
            trailing: Text(
              day.status,
              style: TextStyle(color: _statusColor(day.status)),
            ),
          ),
        ),
      ],
    ),
  );

  Color _statusColor(String status) {
    if (status == 'Present') return Colors.green;
    if (status == 'Approved leave') return Colors.blue;
    if (status == 'Absent') return Colors.red;
    return Colors.orange;
  }

  String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  String _time(DateTime? date) => date == null
      ? '-'
      : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
