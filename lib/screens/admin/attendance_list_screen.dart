import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin_ui.dart';

/// Admin attendance list page with a calendar date picker.
///
/// Shows every staff member who punched in/out for the selected date,
/// with their punch-in time, punch-out time, and status chip.
/// Defaults to today; the admin can pick any past date via the calendar.
class AttendanceListScreen extends StatefulWidget {
  const AttendanceListScreen({super.key});

  @override
  State<AttendanceListScreen> createState() => _AttendanceListScreenState();
}

class _AttendanceListScreenState extends State<AttendanceListScreen> {
  DateTime _selectedDate = DateTime.now();
  List<Map<String, dynamic>> _records = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadForDate(_selectedDate);
  }

  Future<void> _loadForDate(DateTime date) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final rows = await DatabaseService.getAttendanceListForDate(
        year: date.year,
        month: date.month,
        day: date.day,
      );
      if (!mounted) return;
      setState(() {
        _records = rows;
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2025, 1, 1),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF002060),
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
    await _loadForDate(picked);
  }

  void _goToPreviousDay() {
    final prev = _selectedDate.subtract(const Duration(days: 1));
    setState(() => _selectedDate = prev);
    _loadForDate(prev);
  }

  void _goToNextDay() {
    final next = _selectedDate.add(const Duration(days: 1));
    if (next.isAfter(DateTime.now())) return; // can't go past today
    setState(() => _selectedDate = next);
    _loadForDate(next);
  }

  String _formatDate(DateTime dt) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
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
    return '${weekdays[dt.weekday - 1]}, ${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  String _formatTime(String? iso) {
    if (iso == null) return '--';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '--';
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${hour.toString().padLeft(2, '0')}:$minute $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final isToday = _isSameDay(_selectedDate, DateTime.now());

    return AdminPage(
      title: 'Attendance records',
      subtitle:
          'Every check-in, clearly accounted for. Explore your team’s daily attendance.',
      body: Column(
        children: [
          // --- DATE NAVIGATION BAR ---
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: AdminUi.panel(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous day',
                  icon: const Icon(
                    Icons.chevron_left,
                    color: Color(0xFF002060),
                  ),
                  onPressed: _goToPreviousDay,
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: _pickDate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF002060).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.calendar_today,
                            color: Color(0xFF002060),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _formatDate(_selectedDate),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF002060),
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (isToday)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'TODAY',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next day',
                  icon: const Icon(
                    Icons.chevron_right,
                    color: Color(0xFF002060),
                  ),
                  onPressed: isToday ? null : _goToNextDay,
                ),
              ],
            ),
          ),

          // --- SUMMARY ROW ---
          if (!_isLoading && _error == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  _miniStat('Punched in', '${_records.length}', Colors.green),
                  const SizedBox(width: 12),
                  _miniStat(
                    'Completed',
                    '${_records.where((r) => r['punch_out'] != null).length}',
                    Colors.blue,
                  ),
                  const SizedBox(width: 12),
                  _miniStat(
                    'Pending',
                    '${_records.where((r) => r['late_approved'] != true).length}',
                    Colors.orange,
                  ),
                ],
              ),
            ),

          // --- LIST ---
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
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
                          'Failed: $_error',
                          style: const TextStyle(color: AppTheme.maraRed),
                        ),
                        TextButton(
                          onPressed: () => _loadForDate(_selectedDate),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _records.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.event_busy,
                          color: Colors.grey[300],
                          size: 64,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No attendance records for this date.',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    itemCount: _records.length,
                    itemBuilder: (context, i) => _buildCard(_records[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: AdminUi.panel(),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: AdminUi.ink,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              style: TextStyle(color: Colors.grey[600], fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> row) {
    final staff = row['staff'] as Map<String, dynamic>?;
    final name = (staff?['full_name'] as String?) ?? 'Unknown';
    final dept = (staff?['departments']?['name'] as String?) ?? '—';
    final punchOutStr = row['punch_out'] as String?;
    final lateApproved = row['late_approved'] == true;
    final statusStr = row['status'] as String? ?? 'present';

    final String chipLabel;
    final Color chipColor;
    if (punchOutStr != null) {
      chipLabel = 'Completed';
      chipColor = Colors.green;
    } else if (!lateApproved) {
      chipLabel = 'Pending';
      chipColor = Colors.orange;
    } else if (statusStr == 'late') {
      chipLabel = 'Late';
      chipColor = Colors.orange;
    } else {
      chipLabel = 'Present';
      chipColor = Colors.green;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AdminUi.panel(),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFF002060).withValues(alpha: 0.1),
            child: Text(
              name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
              style: const TextStyle(
                color: Color(0xFF002060),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dept,
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 6,
                  children: [
                    const Icon(Icons.login, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(row['punch_in'] as String?),
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.logout, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(punchOutStr),
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: chipColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              chipLabel,
              style: TextStyle(
                color: chipColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
