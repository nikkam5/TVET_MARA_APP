import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';

// --- DATA MODELS ---
enum AttendanceStatus { onTime, late, absent }

class AttendanceLog {
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
  /// When false, the screen renders its body without an AppBar so it can be
  /// embedded as a tab inside the staff dashboard's bottom-nav shell.
  final bool showAppBar;

  const AttendanceHistoryScreen({super.key, this.showAppBar = true});

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

  bool _isLoading = true;
  String? _loadError;

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
    _viewedMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
    _selectedDay = DateTime.now().day;
    _loadFromSupabase();
  }

  Future<void> _loadFromSupabase() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final rows = await DatabaseService.getMyAttendanceForMonth(
        year: _viewedMonth.year,
        month: _viewedMonth.month,
      );

      final Map<int, AttendanceStatus> dayMap = {};
      final List<AttendanceLog> logs = [];

      for (final row in rows) {
        final punchInStr = row['punch_in'] as String?;
        if (punchInStr == null) continue;
        final punchIn = DateTime.tryParse(punchInStr);
        if (punchIn == null) continue;

        final day = punchIn.day;
        final statusStr = row['status'] as String? ?? 'present';
        final AttendanceStatus status;
        switch (statusStr) {
          case 'late':
            status = AttendanceStatus.late;
            break;
          case 'absent':
            status = AttendanceStatus.absent;
            break;
          default:
            status = AttendanceStatus.onTime;
        }
        dayMap[day] = status;

        final punchOutStr = row['punch_out'] as String?;
        final punchOut = punchOutStr != null
            ? DateTime.tryParse(punchOutStr)
            : null;
        final remark = row['punch_in_remark'] as String?;
        final notes = row['notes'] as String?;

        // Determine lateness in minutes (assuming 08:00 = on time)
        final expected = DateTime(
          punchIn.year,
          punchIn.month,
          punchIn.day,
          8,
          0,
        );
        final diff = punchIn.difference(expected);
        final lateMinutes = diff.inMinutes;

        logs.add(
          AttendanceLog(
            dateLabel: "${_monthNames[punchIn.month - 1]} ${punchIn.day}",
            weekday: _weekdayNames[punchIn.weekday - 1],
            status: status,
            badgeText: status == AttendanceStatus.late
                ? "+${lateMinutes}m"
                : (status == AttendanceStatus.absent ? "Absent" : "On Time"),
            checkIn: status == AttendanceStatus.absent
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

      if (!mounted) return;
      setState(() {
        _attendanceMap = dayMap;
        _logs = logs;
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
      if (!mounted) return;
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
    });
    _loadFromSupabase();
  }

  Color _statusColor(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.onTime:
        return Colors.green;
      case AttendanceStatus.late:
        return Colors.orange;
      case AttendanceStatus.absent:
        return AppTheme.maraRed;
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
    }
  }

  void _openAppealModal(AttendanceLog log) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _AppealModalSheet(log: log),
    );
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
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text(
                "Attendance History",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: Colors.transparent,
              flexibleSpace: Container(
                decoration: const BoxDecoration(
                  gradient: AppTheme.headerGradient,
                ),
              ),
              iconTheme: const IconThemeData(color: Colors.white),
              elevation: 0,
              actions: [
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    // TODO: hook up search/filter for attendance logs
                  },
                ),
              ],
            )
          : null,
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
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCalendarCard(onTimeCount, lateCount, absentCount),
                  const SizedBox(height: 30),
                  _buildLogsSection(),
                ],
              ),
            ),
    );
  }

  // --- CALENDAR CARD ---
  Widget _buildCalendarCard(int onTimeCount, int lateCount, int absentCount) {
    final totalCells = _leadingEmptyCells + _daysInMonth;

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 5, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          // Month navigator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, color: Color(0xFF002060)),
                onPressed: () => _changeMonth(-1),
              ),
              Row(
                children: [
                  Text(
                    _monthLabel,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF002060),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down,
                    color: Color(0xFF002060),
                    size: 20,
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: Color(0xFF002060)),
                onPressed: () => _changeMonth(1),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Weekday header
          Row(
            children: const ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 5),

          // Day grid
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalCells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.9,
            ),
            itemBuilder: (context, index) {
              if (index < _leadingEmptyCells) return const SizedBox.shrink();
              final day = index - _leadingEmptyCells + 1;
              final status = _attendanceMap[day];
              final isSelected = day == _selectedDay;

              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF002060)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      "$day",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? Colors.white
                            : (status == null
                                  ? Colors.grey[400]
                                  : Colors.black87),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  if (status != null)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _statusColor(status),
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              );
            },
          ),

          const Divider(height: 30),

          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendDot(Colors.green, "On Time"),
              const SizedBox(width: 20),
              _legendDot(Colors.orange, "Late"),
              const SizedBox(width: 20),
              _legendDot(AppTheme.maraRed, "Absent"),
            ],
          ),
          const SizedBox(height: 15),

          // Summary pills
          Row(
            children: [
              Expanded(
                child: _summaryPill("$onTimeCount", "On Time", Colors.green),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _summaryPill("$lateCount", "Late", Colors.orange),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _summaryPill("$absentCount", "Absent", AppTheme.maraRed),
              ),
            ],
          ),
        ],
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
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }

  Widget _summaryPill(String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        ],
      ),
    );
  }

  // --- RECENT LOGS SECTION ---
  Widget _buildLogsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Recent Logs",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            TextButton(
              onPressed: () {
                // TODO: navigate to the full logs list
              },
              child: const Text(
                "See All",
                style: TextStyle(
                  color: Color(0xFF002060),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _logs.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) => _buildLogCard(index),
        ),
      ],
    );
  }

  Widget _buildLogCard(int index) {
    final log = _logs[index];
    final isExpanded = _expandedIndex == index;
    final color = _statusColor(log.status);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 5, offset: Offset(0, 3)),
        ],
      ),
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
          if (log.status == AttendanceStatus.late && log.punchInRemark != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 16, color: Colors.orange[700]),
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
          // Lateness is now recorded automatically at punch-in (see the
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
                label: const Text("Submit Leave Application / Upload MC"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF002060),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
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
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[500],
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value ?? "--",
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note,
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// --- APPEAL / MEDICAL LEAVE MODAL ---
class _AppealModalSheet extends StatefulWidget {
  final AttendanceLog log;
  const _AppealModalSheet({required this.log});

  @override
  State<_AppealModalSheet> createState() => _AppealModalSheetState();
}

class _AppealModalSheetState extends State<_AppealModalSheet> {
  final TextEditingController _reasonController = TextEditingController();
  String? _fileName;
  bool _isSubmitting = false;
  bool _isSuccess = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _pickFile() {
    // Placeholder tap-to-select. For a real file chooser, add the
    // file_picker package and call FilePicker.platform.pickFiles() here.
    setState(() => _fileName = "medical_certificate.pdf");
  }

  Future<void> _submit() async {
    if (_reasonController.text.trim().isEmpty || _isSubmitting) return;

    setState(() => _isSubmitting = true);

    // TODO: replace with your real API/Firebase submission call
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;

    setState(() {
      _isSubmitting = false;
      _isSuccess = true;
    });

    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.log;
    final canSubmit =
        _reasonController.text.trim().isNotEmpty &&
        !_isSubmitting &&
        !_isSuccess;

    return Padding(
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
              const Expanded(
                child: Text(
                  "Leave Application & Medical Certificate",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF002060),
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
            "${log.dateLabel} · ${log.weekday} · Absent",
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
          const SizedBox(height: 20),
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
          const Text(
            "MC / SUPPORTING DOCUMENT",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _pickFile,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 30),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF002060).withValues(alpha: 0.4),
                  width: 1.5,
                ),
                // Note: Flutter has no built-in dashed border. This uses a
                // solid border to keep things simple — add the
                // dotted_border package if you want the exact dashed look.
              ),
              child: Column(
                children: [
                  Icon(
                    _fileName == null
                        ? Icons.upload_outlined
                        : Icons.check_circle,
                    color: const Color(0xFF002060),
                    size: 28,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _fileName ?? "Tap to upload MC / Document",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fileName == null
                        ? "PDF, JPG, PNG · Max 10MB"
                        : "File selected",
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
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
                    ? Colors.green
                    : const Color(0xFF002060),
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
    );
  }
}
