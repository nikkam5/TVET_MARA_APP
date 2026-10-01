import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/geofence_service.dart';
import '../../services/presence_service.dart';
import '../../utils/malaysia_time.dart';
import '../../theme/app_theme.dart';
import '../../widgets/staff/scrollable_bottom_nav.dart';
import 'attendance_history_screen.dart';
import 'staff_profile_screen.dart';
import '../reports/report_generator_screen.dart';
import 'tasks_screen.dart';

/// Root shell for the redesigned staff app: 4 bottom-nav tabs (Home,
/// Tasks, Attendance, Profile) — matches the new mockups exactly, no
/// side drawer. "Reports" (the old report generator) is now reached via
/// the "Documents" quick action on Home instead of living in the nav
/// bar, and "Punch" is folded directly into the Home tab's live
/// attendance card instead of being a separate tab.
class StaffDashboard extends StatefulWidget {
  const StaffDashboard({super.key});

  @override
  State<StaffDashboard> createState() => _StaffDashboardState();
}

class _StaffDashboardState extends State<StaffDashboard>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  static const List<NavTabItem> _navItems = [
    NavTabItem(
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      label: 'Home',
    ),
    NavTabItem(
      icon: Icons.checklist_outlined,
      activeIcon: Icons.checklist_rounded,
      label: 'Tasks',
    ),
    NavTabItem(
      icon: Icons.event_available_outlined,
      activeIcon: Icons.event_available_rounded,
      label: 'Attendance',
    ),
    NavTabItem(
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: 'Profile',
    ),
  ];

  void _switchToTab(int index) => setState(() => _currentIndex = index);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Report this staff member as online for as long as the dashboard runs.
    PresenceService.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PresenceService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a slept/suspended machine: the last heartbeat may be
    // stale, so stamp one immediately instead of waiting up to a minute.
    if (state == AppLifecycleState.resumed) {
      PresenceService.markNow();
    }
  }

  void _openReports() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ReportGeneratorScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _HomeTab(
        onOpenTasks: () => _switchToTab(1),
        onOpenAttendance: () => _switchToTab(2),
        onOpenReports: _openReports,
      ),
      const TasksScreen(),
      const AttendanceHistoryScreen(),
      const StaffProfileScreen(),
    ];

    return Scaffold(
      backgroundColor: AppTheme.bgBottom,
      extendBody: true,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: KeyedSubtree(
          key: ValueKey(_currentIndex),
          child: screens[_currentIndex],
        ),
      ),
      bottomNavigationBar: ScrollableBottomNav(
        items: _navItems,
        currentIndex: _currentIndex,
        onTap: _switchToTab,
      ),
    );
  }
}

// ==========================================================================
// HOME TAB — hero header + live attendance (punch in/out + geofence +
// late-arrival dialog + status banner, all restored from the old
// PunchcardScreen) + shift elapsed + monthly score + quick actions +
// next-priority task preview.
// ==========================================================================
class _HomeTab extends StatefulWidget {
  final VoidCallback onOpenTasks;
  final VoidCallback onOpenAttendance;
  final VoidCallback onOpenReports;

  const _HomeTab({
    required this.onOpenTasks,
    required this.onOpenAttendance,
    required this.onOpenReports,
  });

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  static const Duration _shiftDuration = Duration(hours: 8);

  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _today;
  bool _isLoading = true;
  String? _loadError;
  int _monthlyScorePercent = 0;

  bool _isPunching = false;
  String? _lateRemark;

  // Live geofence state.
  GeofenceResult? _geofenceResult;
  bool _isCheckingLocation = true;
  StreamSubscription<GeofenceResult>? _geofenceSub;
  StreamSubscription<Map<String, dynamic>?>? _attendanceSub;

  // Ticking clock — drives the live time-of-day readout and the shift
  // elapsed / remaining counters.
  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadData();
    _startLocationStream();
    _attendanceSub = DatabaseService.myAttendanceStream().listen((today) {
      if (!mounted) return;
      setState(() {
        _today = today;
        _lateRemark = today?['late_reason'] as String?;
      });
    }, onError: (Object error) => debugPrint('[StaffHome] attendance: $error'));
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final previousDay = MalaysiaTime.dateString(MalaysiaTime.fromUtc(_now));
      setState(() => _now = DateTime.now());
      if (previousDay != MalaysiaTime.dateString(MalaysiaTime.fromUtc(_now))) {
        _loadData();
      }
    });
  }

  @override
  void dispose() {
    _geofenceSub?.cancel();
    _attendanceSub?.cancel();
    _clockTimer?.cancel();
    super.dispose();
  }

  void _startLocationStream() {
    _geofenceSub?.cancel();
    setState(() => _isCheckingLocation = true);
    _geofenceSub = GeofenceService.geofenceStream().listen(
      (result) {
        if (!mounted) return;
        setState(() {
          _geofenceResult = result;
          _isCheckingLocation = false;
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _geofenceResult = GeofenceResult(
            isInside: false,
            distanceMeters: double.infinity,
            error: e.toString(),
          );
          _isCheckingLocation = false;
        });
      },
    );
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final now = MalaysiaTime.now();
      final monthStart = DateTime(now.year, now.month, 1);
      final results = await Future.wait([
        AuthService.getCurrentProfile(),
        DatabaseService.getTodayAttendance(),
        DatabaseService.getMySemesterStats(since: monthStart),
      ]);
      if (!mounted) return;
      final stats = Map<String, int>.from(results[2] as Map<dynamic, dynamic>);
      setState(() {
        _profile = results[0];
        _today = results[1];
        _lateRemark = _today?['late_reason'] as String?;
        _monthlyScorePercent = stats['rate'] ?? 0;
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

  String get _staffName => (_profile?['full_name'] as String?) ?? 'Loading...';
  String get _staffRole => (_profile?['position'] as String?) ?? 'Staff';
  String get _staffDepartment =>
      (_profile?['departments']?['name'] as String?) ?? '—';
  String get _campus => (_profile?['campus'] as String?) ?? '—';
  String get _initials {
    final parts = _staffName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '—';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  bool get _hasPunchedOut => _today?['punch_out'] != null;
  bool get _isInsideZone => _geofenceResult?.isInside ?? false;

  DateTime? get _punchInTime {
    final raw = _today?['punch_in'] as String?;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  // Status derived from today's attendance row — identical logic to the
  // old PunchcardScreen so nothing about the approval workflow changes.
  String get _statusKey {
    final row = _today;
    if (row == null) return 'none';
    if (row['punch_out'] != null) return 'done';
    final lateApproved = row['late_approved'] == true;
    if (lateApproved) {
      return (row['status'] == 'late') ? 'late-approved' : 'on-time';
    }
    final reason = row['late_reason'] as String?;
    final punchIn = row['punch_in'] as String?;
    if (punchIn == null) return 'none';
    final dt = DateTime.tryParse(
      punchIn,
    )?.toUtc().add(const Duration(hours: 8));
    final isLate = dt != null && dt.hour * 60 + dt.minute >= 8 * 60;
    if (!isLate) return 'on-time';
    if (reason == null || reason.isEmpty) return 'late-pending';
    return 'late-review';
  }

  bool get _isOnDuty => _statusKey != 'none' && _statusKey != 'done';

  Future<void> _handlePunchIn() async {
    if (_isPunching) return;
    if (_statusKey != 'none') return;
    if (!_isInsideZone) {
      _showSnack(
        'You must be inside a TVET MARA zone to check in.',
        AppTheme.maraRed,
      );
      return;
    }

    setState(() => _isPunching = true);
    try {
      final isLate = MalaysiaTime.isLate(DateTime.now());
      String? remark;
      if (isLate) {
        remark = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => const _LateRemarksDialog(),
        );
        if (remark == null || !mounted) return;
      }
      // Recheck at the moment of punching; a streamed fix may be stale.
      final location = await GeofenceService.checkGeofence();
      final position = location.position;
      if (!location.isInside || position == null) {
        throw Exception(
          location.error ?? 'You must be inside a TVET MARA zone to check in.',
        );
      }

      await DatabaseService.punchIn(
        latitude: position.latitude,
        longitude: position.longitude,
        geofenceZoneId: location.matchedZone?['id'] as String?,
        lateReason: remark,
      );

      if (!mounted) return;
      _showSnack(
        isLate
            ? 'Late check-in recorded — awaiting admin approval.'
            : 'Checked in successfully!',
        isLate ? Colors.orange : AppTheme.success,
      );
      await _loadData();
    } on Exception catch (e) {
      if (!mounted) return;
      _showSnack('Check-in failed: $e', AppTheme.maraRed);
    } finally {
      if (mounted) setState(() => _isPunching = false);
    }
  }

  Future<void> _handlePunchOut() async {
    if (_isPunching || _today == null || _hasPunchedOut) return;
    // Preserve approval workflow: late check-ins must be approved before checkout.
    final status = _statusKey;
    if (status != 'on-time' && status != 'late-approved') {
      _showSnack(
        'Check-out is available after your check-in is approved.',
        Colors.orange,
      );
      return;
    }
    setState(() => _isPunching = true);
    try {
      final position = await GeofenceService.getCurrentPosition();

      await DatabaseService.punchOut(
        latitude: position.latitude,
        longitude: position.longitude,
      );

      if (!mounted) return;
      _showSnack(
        'Checked out successfully. Have a great day!',
        AppTheme.success,
      );
      await _loadData();
    } on Exception catch (e) {
      if (!mounted) return;
      _showSnack('Check-out failed: $e', AppTheme.maraRed);
    } finally {
      if (mounted) setState(() => _isPunching = false);
    }
  }

  Future<void> _submitMissingLateReason() async {
    if (_isPunching) return;
    setState(() => _isPunching = true);
    try {
      final reason = await showDialog<String>(
        context: context,
        builder: (_) => const _LateRemarksDialog(),
      );
      if (reason == null || !mounted) return;
      await DatabaseService.submitLateReason(reason);
      if (mounted) await _loadData();
    } catch (error) {
      if (mounted) _showSnack('$error', AppTheme.maraRed);
    } finally {
      if (mounted) setState(() => _isPunching = false);
    }
  }

  void _showSnack(String text, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(15),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
    );
  }

  String _formatClock(DateTime dt) {
    dt = MalaysiaTime.fromUtc(dt);
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'am' : 'pm';
    return '${hour.toString().padLeft(2, '0')}:$minute:$second $ampm';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatDate(DateTime dt) {
    dt = MalaysiaTime.fromUtc(dt);
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
    return '${weekdays[dt.weekday - 1]}, ${dt.day} ${months[dt.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.maraRed, size: 48),
            const SizedBox(height: 12),
            Text(
              'Failed to load: $_loadError',
              style: const TextStyle(color: AppTheme.maraRed, fontSize: 12),
            ),
            TextButton(onPressed: _loadData, child: const Text('Retry')),
          ],
        ),
      );
    }

    final punchIn = _punchInTime;
    final end =
        DateTime.tryParse(_today?['punch_out']?.toString() ?? '') ?? _now;
    final rawElapsed = punchIn != null
        ? end.difference(punchIn)
        : Duration.zero;
    final elapsed = rawElapsed.isNegative ? Duration.zero : rawElapsed;
    final remaining = _shiftDuration - elapsed;
    final shiftProgress = (elapsed.inSeconds / _shiftDuration.inSeconds).clamp(
      0.0,
      1.0,
    );

    return RefreshIndicator(
      onRefresh: _loadData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        clipBehavior: Clip.none,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeroHeader(),
            Transform.translate(
              offset: const Offset(0, -28),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _buildLiveAttendanceCard(punchIn),
              ),
            ),
            Padding(
              // pb-24 equivalent + clearance for the overlaying bottom nav
              // (extendBody: true), so the last card scrolls fully into view
              // instead of being cut off behind the nav bar.
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + MediaQuery.of(context).padding.bottom + 80,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildShiftElapsedCard(
                          elapsed,
                          remaining,
                          shiftProgress,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: _buildMonthlyScoreCard()),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Quick actions',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildQuickActions(),
                  const SizedBox(height: 22),
                  _buildLatestActivitiesSection(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.of(context).padding.top + 18,
        20,
        60,
      ),
      decoration: const BoxDecoration(gradient: AppTheme.heroGradient),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDate(_now),
                  style: const TextStyle(
                    color: AppTheme.onDarkSecondary,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Good morning, $_staffName',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_staffRole · $_staffDepartment',
                  style: const TextStyle(
                    color: AppTheme.onDarkSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _isOnDuty
                              ? AppTheme.success
                              : AppTheme.textFaint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isOnDuty ? 'On Duty · $_campus' : 'Off Duty',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: widget.onOpenTasks,
            child: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Text(
                _initials,
                style: const TextStyle(
                  color: AppTheme.heroEnd,
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

  Widget _buildLiveAttendanceCard(DateTime? punchIn) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.navy, AppTheme.heroEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Live attendance',
                style: TextStyle(
                  color: AppTheme.onDarkSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.access_time_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            punchIn != null ? _formatClock(_now) : '— : — : —',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                _isCheckingLocation
                    ? Icons.gps_not_fixed_rounded
                    : (_isInsideZone
                          ? Icons.gps_fixed_rounded
                          : Icons.gps_off_rounded),
                color: _isCheckingLocation
                    ? AppTheme.onDarkSecondary
                    : (_isInsideZone ? AppTheme.success : AppTheme.maraRedSoft),
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _isCheckingLocation
                      ? 'Checking location…'
                      : (_isInsideZone
                            ? '${_geofenceResult!.zoneName} · GPS ±${_geofenceResult!.accuracyMeters?.round() ?? '—'} m'
                            : (_geofenceResult?.error ??
                                  'Outside a TVET MARA zone')),
                  style: const TextStyle(
                    color: AppTheme.onDarkSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Refresh GPS',
                onPressed: _startLocationStream,
                icon: Icon(
                  _isInsideZone
                      ? Icons.check_circle_rounded
                      : Icons.refresh_rounded,
                  color: _isInsideZone
                      ? AppTheme.success
                      : AppTheme.maraRedSoft,
                  size: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildPunchButton(),
          const SizedBox(height: 10),
          _buildStatusBanner(),
          if (_statusKey == 'late-pending')
            TextButton(
              onPressed: _isPunching ? null : _submitMissingLateReason,
              child: const Text(
                'Submit late reason',
                style: TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPunchButton() {
    final status = _statusKey;
    final canPunchIn = status == 'none';
    final malaysiaNow = MalaysiaTime.now();
    final punchInEnabled =
        !_isCheckingLocation && _isInsideZone && malaysiaNow.hour >= 5;
    // Only allow punch-out after the punch-in is approved:
    //   - 'on-time' (auto-approved)
    //   - 'late-approved' (admin approved)
    // 'late-pending' / 'late-review' must wait for admin approval.
    final canPunchOut = status == 'on-time' || status == 'late-approved';

    if (status == 'done') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: const Text(
          'Day completed',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: _isPunching
            ? null
            : (canPunchIn
                  ? (punchInEnabled ? _handlePunchIn : null)
                  : (canPunchOut ? _handlePunchOut : null)),
        icon: _isPunching
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : Icon(
                canPunchIn ? Icons.login_rounded : Icons.logout_rounded,
                color: Colors.white,
              ),
        label: Text(
          _isPunching
              ? 'Please wait…'
              : (canPunchIn ? 'Check in' : 'Check out'),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.success,
          disabledBackgroundColor: AppTheme.success.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    final (label, color) = switch (_statusKey) {
      'none' => ('You have not checked in yet', Colors.white70),
      'on-time' => ('Checked in — remember to check out', AppTheme.success),
      'late-pending' => ('Late — please submit a reason', Colors.orangeAccent),
      'late-review' => (
        'Late reason submitted — awaiting admin approval',
        Colors.orangeAccent,
      ),
      'late-approved' => (
        'Late reason approved — remember to check out',
        AppTheme.success,
      ),
      'done' => ('', Colors.white),
      _ => ('', Colors.white70),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, color: color, size: 15),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            (_statusKey == 'late-review' || _statusKey == 'late-pending') &&
                    _lateRemark != null
                ? '$label. Reason: $_lateRemark'
                : label,
            style: TextStyle(color: color, fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  Widget _buildShiftElapsedCard(
    Duration elapsed,
    Duration remaining,
    double progress,
  ) {
    final remainingLabel = remaining.isNegative
        ? 'Shift complete'
        : '${remaining.inHours}h ${remaining.inMinutes % 60}m remaining';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.glassCard(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Shift elapsed',
            style: TextStyle(fontSize: 12, color: AppTheme.textFaint),
          ),
          const SizedBox(height: 6),
          Text(
            _punchInTime == null ? '--:--:--' : _formatDuration(elapsed),
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _punchInTime == null ? 0 : progress,
              minHeight: 6,
              backgroundColor: const Color(0xFFEDEFF7),
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.navy),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _punchInTime == null ? 'Not started' : remainingLabel,
            style: const TextStyle(fontSize: 11, color: AppTheme.textFaint),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthlyScoreCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.navy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.track_changes_rounded,
              color: AppTheme.goldLight,
              size: 16,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '$_monthlyScorePercent%',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Monthly score',
            style: TextStyle(fontSize: 11.5, color: AppTheme.onDarkSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _QuickActionTile(
            icon: Icons.checklist_rounded,
            label: 'My tasks',
            onTap: widget.onOpenTasks,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionTile(
            icon: Icons.event_available_rounded,
            label: 'Attendance',
            onTap: widget.onOpenAttendance,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionTile(
            icon: Icons.description_rounded,
            label: 'Documents',
            onTap: _onDocumentsTap,
          ),
        ),
      ],
    );
  }

  // Documents card: clean confirm modal first — nothing downloads or
  // opens until the user taps Proceed.
  Future<void> _onDocumentsTap() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Semester performance report',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: const Text(
          'Do you want to print/download the semester performance report?',
          style: TextStyle(fontSize: 13.5, color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(
              Icons.download_rounded,
              size: 17,
              color: Colors.white,
            ),
            label: const Text(
              'Proceed / Download',
              style: TextStyle(color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    widget.onOpenReports();
  }

  // Official IKM Besut site — the single "Latest news & announcements"
  // card is a strict external hyperlink: it calls window.open(url,
  // '_blank') on web (via launchUrl with webOnlyWindowName '_blank',
  // i.e. <a target="_blank" rel="noopener noreferrer">) and the external
  // browser / OS handler on mobile — no internal routing, modal, picture
  // preview or dialog of any kind.
  static const String _besutWebsiteUrl = 'https://tvetmara.edu.my/';

  Future<void> _openBesutWebsite() => _openExternal(_besutWebsiteUrl);

  Future<void> _openExternal(String url) async {
    try {
      final launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
      if (!launched && mounted) {
        _showSnack('Could not open the website.', AppTheme.maraRed);
      }
    } catch (error) {
      if (mounted) {
        _showSnack('Could not open the website: $error', AppTheme.maraRed);
      }
    }
  }

  Widget _buildLatestActivitiesSection() {
    // Exactly ONE card in this section — nothing else.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Latest @ TVETMARA Besut',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        _buildActivityTile(),
      ],
    );
  }

  /// The single external-link card. Tapping it launches the official
  /// TVET MARA Besut website in the external browser — no modal, image
  /// preview or dialog of any kind.
  Widget _buildActivityTile() {
    return InkWell(
      onTap: _openBesutWebsite,
      borderRadius: BorderRadius.circular(16),
      child: Container(
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
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppTheme.navy,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.campaign_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Latest news & announcements',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'From the official TVETMARA Besut website',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.open_in_new_rounded,
                size: 16,
                color: AppTheme.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: AppTheme.glassCard(radius: 16),
        child: Column(
          children: [
            Icon(icon, color: AppTheme.success, size: 24),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- LATE ARRIVAL REMARKS DIALOG (unchanged from the old app) -----------
// Shown automatically when checking in after the cutoff time. Requires
// acknowledging the checkbox before it can be submitted — the resulting
// remark is saved as a read-only part of the attendance record, so no
// separate lateness appeal is needed afterward.
class _LateRemarksDialog extends StatefulWidget {
  const _LateRemarksDialog();

  @override
  State<_LateRemarksDialog> createState() => _LateRemarksDialogState();
}

class _LateRemarksDialogState extends State<_LateRemarksDialog> {
  static const List<String> _reasons = [
    "Traffic congestion",
    "Public transport delay",
    "Personal / family emergency",
    "Other",
  ];

  String _selectedReason = _reasons.first;
  final TextEditingController _otherController = TextEditingController();
  bool _acknowledged = false;

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (!_acknowledged) return false;
    if (_selectedReason == "Other") {
      return _otherController.text.trim().isNotEmpty;
    }
    return true;
  }

  void _submit() {
    final remark = _selectedReason == "Other"
        ? _otherController.text.trim()
        : _selectedReason;
    Navigator.pop(context, remark);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      title: const Text(
        "Late Arrival Remarks",
        style: TextStyle(color: AppTheme.navy, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "You're checking in after 8:00 AM. Please select a reason before continuing.",
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 16),
            RadioGroup<String>(
              groupValue: _selectedReason,
              onChanged: (value) => setState(() => _selectedReason = value!),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _reasons
                    .map(
                      (reason) => RadioListTile<String>(
                        value: reason,
                        title: Text(
                          reason,
                          style: const TextStyle(fontSize: 14),
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        activeColor: AppTheme.navy,
                      ),
                    )
                    .toList(),
              ),
            ),
            if (_selectedReason == "Other") ...[
              const SizedBox(height: 8),
              TextField(
                controller: _otherController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: "Please specify...",
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _acknowledged,
              onChanged: (value) =>
                  setState(() => _acknowledged = value ?? false),
              title: const Text(
                "I acknowledge this late arrival will be recorded in my attendance log.",
                style: TextStyle(fontSize: 12),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: AppTheme.navy,
              dense: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: _canSubmit ? _submit : null,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.navy),
          child: const Text("Confirm", style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
