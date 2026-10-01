import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/malaysia_time.dart';

// ─────────────────────────────────────────────────────────────────────
// Design tokens — mirrored from the admin dashboard shell so the page
// reads as one more panel of the same application.
// ─────────────────────────────────────────────────────────────────────
const Color _canvas = Color(0xFFF4F6FB);
const Color _hairline = Color(0xFFE2E8F0);
const Color _surfaceInset = Color(0xFFF1F5F9);
const Color _ink = Color(0xFF0F172A);
const Color _muted = Color(0xFF64748B);

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

/// Admin attendance records page.
///
/// Deliberately **not** a `Scaffold`: it renders *inside* the admin
/// dashboard shell (sticky left rail + top navbar) so the navigation
/// chrome never disappears behind a full-screen route.
///
/// Shows every staff member who punched in/out for the selected date,
/// with their punch-in time, punch-out time, and a status chip. Defaults
/// to today; the admin can pick any past date via the calendar. All rows,
/// the Punched in / Completed / Pending metrics and the records list come
/// live from the Supabase `attendance` table — an empty day renders the
/// empty state, never dummy rows.
class AttendanceListScreen extends StatefulWidget {
  const AttendanceListScreen({super.key});

  @override
  State<AttendanceListScreen> createState() => _AttendanceListScreenState();
}

class _AttendanceListScreenState extends State<AttendanceListScreen> {
  DateTime _selectedDate = MalaysiaTime.now();
  int _loadVersion = 0;
  List<Map<String, dynamic>> _records = [];
  bool _isLoading = true;

  /// Realtime subscription on the `attendance` table for the selected date,
  /// so the register refreshes the moment staff punch in or out. Guarded:
  /// with Supabase uninitialised (offline preview / tests) subscribing
  /// throws, and the page simply works without live push until the next
  /// manual reload.
  StreamSubscription<List<Map<String, dynamic>>>? _attendanceSub;

  /// True while a silent (realtime-triggered) reload is in flight, so
  /// rapid push events never stack overlapping queries.
  bool _silentLoading = false;

  @override
  void initState() {
    super.initState();
    _loadForDate(_selectedDate);
    _subscribeForDate(_selectedDate);
  }

  @override
  void dispose() {
    _attendanceSub?.cancel();
    super.dispose();
  }

  /// (Re)subscribes the realtime feed to [date]. Never throws: when
  /// Supabase isn't initialised the subscription stays null and the page
  /// falls back to manual reload.
  void _subscribeForDate(DateTime date) {
    try {
      _attendanceSub?.cancel();
      _attendanceSub =
          DatabaseService.attendanceForDateStream(
            year: date.year,
            month: date.month,
            day: date.day,
          ).listen(
            (_) {
              if (mounted && !_silentLoading) {
                _loadForDate(_selectedDate, silent: true);
              }
            },
            onError: (_) {},
            cancelOnError: false,
          );
    } catch (_) {
      _attendanceSub = null;
    }
  }

  /// Loads one day live from the Supabase `attendance` table. Date
  /// navigation, the calendar picker, the Today shortcut and pull-to-
  /// refresh all funnel through here, so every one of them pulls live
  /// data. [silent] skips the full-page spinner so realtime push events
  /// can refresh the list without flashing the page.
  Future<void> _loadForDate(DateTime date, {bool silent = false}) async {
    if (silent && _silentLoading) return;
    final version = ++_loadVersion;
    if (silent) {
      if (_silentLoading) return;
      _silentLoading = true;
    } else {
      setState(() {
        _isLoading = true;
      });
    }
    try {
      final rows = await DatabaseService.getAttendanceListForDate(
        year: date.year,
        month: date.month,
        day: date.day,
      );
      if (!mounted || version != _loadVersion) return;
      _silentLoading = false;
      setState(() {
        _records = rows;
        _isLoading = false;
      });
    } catch (_) {
      // Bare catch on purpose: with Supabase uninitialised (offline
      // preview, tests) `Supabase.instance` throws an *AssertionError* —
      // an Error, not an Exception — which `on Exception` would let
      // escape as an unhandled async failure. The register stays
      // live-only: an empty list renders the empty state, and the date
      // controls / pull-to-refresh retry.
      _silentLoading = false;
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _records = [];
        _isLoading = false;
      });
      if (!silent && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _toast('Could not load live attendance — pull to retry.');
          }
        });
      }
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

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2025, 1, 1),
      lastDate: MalaysiaTime.now(),
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
    _subscribeForDate(picked);
    await _loadForDate(picked);
  }

  void _goToPreviousDay() {
    final prev = _selectedDate.subtract(const Duration(days: 1));
    setState(() => _selectedDate = prev);
    _subscribeForDate(prev);
    _loadForDate(prev);
  }

  void _goToNextDay() {
    final next = _selectedDate.add(const Duration(days: 1));
    if (next.isAfter(MalaysiaTime.now())) return; // can't go past today
    setState(() => _selectedDate = next);
    _subscribeForDate(next);
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
    final dt = MalaysiaTime.parse(iso);
    if (dt == null) return '--';
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${hour.toString().padLeft(2, '0')}:$minute $ampm';
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ── Derived counts ──────────────────────────────────────────────────
  int get _punchedIn => _records.length;
  int get _completed => _records.where((r) => r['punch_out'] != null).length;
  int get _pending => _punchedIn - _completed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isWide = width >= 760;
        final contentWidth = width - (isWide ? 56 : 32);

        return Container(
          color: _canvas,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: isWide ? 28 : 16),
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => _loadForDate(_selectedDate),
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 18, bottom: 28),
                      children: [
                        _pageHeader(width),
                        const SizedBox(height: 16),
                        _dateNavCard(),
                        const SizedBox(height: 16),
                        _summaryRow(contentWidth),
                        const SizedBox(height: 20),
                        _sectionHeader(),
                        const SizedBox(height: 10),
                        if (_records.isEmpty)
                          _emptyState()
                        else
                          for (final row in _records) _buildCard(row),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  // ── Page header ─────────────────────────────────────────────────────
  Widget _pageHeader(double width) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Daily Attendance Log',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: _ink,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Punch-in and punch-out records for the selected date.',
          style: TextStyle(fontSize: 13, color: _muted),
        ),
      ],
    );

    if (width < 640) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 12),
          if (!_isSameDay(_selectedDate, DateTime.now())) _todayButton(),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: heading),
        const SizedBox(width: 16),
        if (!_isSameDay(_selectedDate, DateTime.now())) _todayButton(),
      ],
    );
  }

  Widget _todayButton() {
    return TextButton.icon(
      onPressed: () {
        final now = DateTime.now();
        setState(() => _selectedDate = now);
        _subscribeForDate(now);
        _loadForDate(now);
      },
      style: TextButton.styleFrom(
        foregroundColor: _ink,
        backgroundColor: Colors.white,
        side: const BorderSide(color: _hairline),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: const Icon(Icons.today_rounded, size: 17),
      label: const Text(
        'Back to today',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }

  // ── Date navigation ─────────────────────────────────────────────────
  Widget _dateNavCard() {
    final isToday = _isSameDay(_selectedDate, DateTime.now());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
        boxShadow: _shadowSm(),
      ),
      child: Row(
        children: [
          _navArrow(icon: Icons.chevron_left_rounded, onTap: _goToPreviousDay),
          Expanded(
            child: GestureDetector(
              onTap: _pickDate,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.navy.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.navy.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.calendar_today_rounded,
                      color: AppTheme.navy,
                      size: 16,
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        _formatDate(_selectedDate),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isToday
                            ? AppTheme.success
                            : const Color(0xFF64748B),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        isToday ? 'TODAY' : 'PAST',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _navArrow(
            icon: Icons.chevron_right_rounded,
            onTap: isToday ? null : _goToNextDay,
          ),
        ],
      ),
    );
  }

  Widget _navArrow({required IconData icon, required VoidCallback? onTap}) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? _surfaceInset : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: enabled ? _hairline : Colors.transparent),
        ),
        child: Icon(
          icon,
          size: 22,
          color: enabled ? AppTheme.navy : const Color(0xFFCBD5E1),
        ),
      ),
    );
  }

  // ── Summary cards ───────────────────────────────────────────────────
  /// [contentWidth] is the scroll view's inner width (page padding
  /// already removed) so the three cards can divide it exactly.
  Widget _summaryRow(double contentWidth) {
    final cards =
        <
          ({
            IconData icon,
            String label,
            String value,
            String caption,
            String badge,
            List<Color> colors,
          })
        >[
          (
            icon: Icons.login_rounded,
            label: 'Punched in',
            value: '$_punchedIn',
            caption: 'Checked in on this day',
            badge: 'TODAY',
            colors: const [Color(0xFF2563EB), Color(0xFF1D4ED8)],
          ),
          (
            icon: Icons.task_alt_rounded,
            label: 'Completed',
            value: '$_completed',
            caption: 'Punch-out recorded',
            badge: 'DONE',
            colors: const [Color(0xFF10B981), Color(0xFF047857)],
          ),
          (
            icon: Icons.hourglass_bottom_rounded,
            label: 'Pending',
            value: '$_pending',
            caption: 'Still on duty',
            badge: 'OPEN',
            colors: const [Color(0xFFF59E0B), Color(0xFFB45309)],
          ),
        ];

    // Three across on desktop, two-up (wrapping) on phones.
    final cardWidth = contentWidth >= 640
        ? (contentWidth - 24) / 3
        : (contentWidth - 12) / 2;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final c in cards)
          SizedBox(width: cardWidth, child: _summaryCard(c)),
      ],
    );
  }

  Widget _summaryCard(
    ({
      IconData icon,
      String label,
      String value,
      String caption,
      String badge,
      List<Color> colors,
    })
    c,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: c.colors,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: c.colors.last.withValues(alpha: 0.32),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: c.colors.last.withValues(alpha: 0.16),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
                child: Icon(c.icon, size: 18, color: Colors.white),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  c.badge,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            c.value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              height: 1.0,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            c.label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.94),
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.55),
                      blurRadius: 5,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  c.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── List section ────────────────────────────────────────────────────
  Widget _sectionHeader() {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: AppTheme.navy,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 9),
        const Text(
          'Records',
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
            color: _ink,
            letterSpacing: -0.2,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _hairline),
          ),
          child: Text(
            '${_records.length} staff',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: _muted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        children: [
          Icon(
            Icons.event_busy_rounded,
            color: const Color(0xFFCBD5E1),
            size: 52,
          ),
          const SizedBox(height: 12),
          const Text(
            'No attendance records for this date.',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick another date, or check back after staff punch in.',
            style: TextStyle(fontSize: 13, color: _muted),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> row) {
    final staff = row['staff'] as Map<String, dynamic>?;
    final name = (staff?['full_name'] as String?) ?? 'Unknown';
    final dept = (staff?['departments']?['name'] as String?) ?? '—';
    final punchInStr = row['punch_in'] as String?;
    final punchOutStr = row['punch_out'] as String?;
    final statusStr = row['status'] as String? ?? 'present';

    final String chipLabel;
    final Color chipColor;
    if (punchOutStr != null) {
      chipLabel = 'Completed';
      chipColor = AppTheme.success;
    } else if (statusStr == 'late') {
      chipLabel = 'Late';
      chipColor = AppTheme.maraRed;
    } else {
      chipLabel = 'On duty';
      chipColor = AppTheme.maraBlue;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
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
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppTheme.maraBlue.withValues(alpha: 0.14),
                  AppTheme.navy.withValues(alpha: 0.18),
                ],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
              style: const TextStyle(
                color: AppTheme.navy,
                fontWeight: FontWeight.w800,
                fontSize: 16,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dept,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _timePair(
                      icon: Icons.login_rounded,
                      color: AppTheme.navy,
                      value: _formatTime(punchInStr),
                    ),
                    _timePair(
                      icon: Icons.logout_rounded,
                      color: punchOutStr == null
                          ? const Color(0xFF94A3B8)
                          : AppTheme.success,
                      value: _formatTime(punchOutStr),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: chipColor.withValues(alpha: 0.30)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: chipColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  chipLabel,
                  style: TextStyle(
                    color: chipColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _timePair({
    required IconData icon,
    required Color color,
    required String value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(color: Color(0xFF475569), fontSize: 12.5),
        ),
      ],
    );
  }
}
