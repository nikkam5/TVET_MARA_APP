import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/presence_service.dart';
import '../../utils/malaysia_time.dart';
import '../../theme/app_theme.dart';
import '../../widgets/shared/lucide_icon.dart';
import '../auth/login_page.dart';
import 'approval_center_screen.dart';
import 'attendance_list_screen.dart';
import 'departments_screen.dart';
import 'geofence_zones_screen.dart';
import 'staff_directory_screen.dart';
import 'staff_report_preview.dart';
import 'system_reports_screen.dart';

/// Breakpoint above which the sidebar is permanently docked instead of
/// living in a Drawer. Tablets/desktop web get the "real" dashboard
/// layout; phones get the same content behind a hamburger menu.
const double _wideBreakpoint = 900;

/// Page canvas behind every panel. A cool near-white instead of pure white
/// so the white cards visibly float on it — combined with the slate-900
/// rail this gives the screen three distinct depth planes (rail / canvas /
/// card) rather than one flat white field.
const Color _pageCanvas = Color(0xFFF4F6FB);

/// --- Surface system ----------------------------------------------------
/// Every card, panel and table on this screen is an opaque white surface
/// defined by the same three tokens: a slate-200 hairline, a slate-300
/// hover hairline and a slate-50 fill for inset controls. Keeping the
/// surfaces flat (no translucency, no blur) is what gives the dashboard
/// its crisp, print-clean corporate read.
const Color _border = Color(0xFFE2E8F0); // slate-200
const Color _borderHover = Color(0xFFCBD5E1); // slate-300
const Color _surfaceMuted = Color(0xFFF8FAFC); // slate-50
const Color _surfaceInset = Color(0xFFF1F5F9); // slate-100

/// Shared institutional ink used by headings and dark type.
const Color _inkNavy = Color(0xFF0F172A); // deep corporate navy / slate-900

/// Neutral structural tone (slate-700) — for accents that must read as
/// "structure" rather than a status: Departments, System Logs, the
/// department breakdown panel.
const Color _slate700 = Color(0xFF334155);

/// Clean elevation used by every surface — a slate-tinted `shadow-sm`
/// equivalent (Tailwind: 0 1px 3px rgb(15 23 42 / 0.08)).
List<BoxShadow> _shadowSm({bool hover = false}) => [
  BoxShadow(
    color: _inkNavy.withValues(alpha: hover ? 0.14 : 0.08),
    blurRadius: hover ? 18 : 8,
    offset: hover ? const Offset(0, 8) : const Offset(0, 2),
  ),
  BoxShadow(
    color: _inkNavy.withValues(alpha: 0.04),
    blurRadius: 2,
    offset: const Offset(0, 1),
  ),
];

enum _RosterFilter { all, active, inactive, onLeave }

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard>
    with WidgetsBindingObserver {
  // 0 = Dashboard, 1 = Staff Directory, 2 = System Reports, 3 = Approvals,
  // 4 = Attendance Records, 5 = Manage Departments, 6 = Geofence Settings
  //
  // Every one of these is an *in-shell* page (rather than a pushed route):
  // the sticky rail + top navbar stay mounted while browsing staff,
  // working the approval queue, reading reports, reviewing attendance or
  // editing departments/zones, so navigation never disappears underneath
  // a full-screen redirect.
  int _currentIndex = 0;

  /// Bumped every time the admin presses "Add Staff" in the chrome; the
  /// embedded directory watches it and opens its slide-over drawer.
  int _addStaffRequest = 0;

  // --- Dashboard data (live from Supabase) ---
  Map<String, dynamic>? _profile;
  int _presentCount = 0;
  int _totalStaff = 0;
  int _pendingApprovals = 0;
  bool _isLoading = true;
  String? _loadError;

  // Extra data for the new dashboard sections — same services the rest of
  // the app already uses, just displayed differently.
  List<Map<String, dynamic>> _staffList = [];
  List<Map<String, dynamic>> _departments = [];
  List<Map<String, dynamic>> _pendingLeaves = [];
  Set<String> _approvedLeaveStaffIds = {};
  Set<String> _presentTodayIds = {};
  Set<String> _lateTodayIds = {};
  Set<String> _pendingTodayIds = {};
  List<_DayAttendance> _weekAttendance = [];
  bool _weekLoading = true;

  /// Wall-clock time of the last successful stats refresh — shown by the
  /// toolbar's live chip so the dashboard never looks stale.
  DateTime? _lastUpdated;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _RosterFilter _rosterFilter = _RosterFilter.all;

  /// Whether the roster table is showing every match (true) or just the
  /// first page (false). Collapsed by default so the two dashboard columns
  /// stay roughly the same height.
  bool _rosterExpanded = false;

  // Realtime subscriptions — auto-refresh stats when attendance OR staff
  // records change (add/delete/edit staff must update the Present X/Y card).
  StreamSubscription<List<Map<String, dynamic>>>? _attendanceSub;
  StreamSubscription<List<Map<String, dynamic>>>? _staffSub;
  bool _resubscribing = false;
  Timer? _refreshTimer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PresenceService.start();
    _loadData();
    _loadWeekAttendance();
    _subscribeToRealtimeChanges();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) {
        _loadData();
        _loadWeekAttendance();
      }
    });
    _searchController.addListener(() {
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PresenceService.stop();
    _attendanceSub?.cancel();
    _staffSub?.cancel();
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PresenceService.markNow();
      _loadData();
      _loadWeekAttendance();
    }
  }

  void _subscribeToRealtimeChanges() {
    // Any INSERT/UPDATE/DELETE on attendance triggers a refresh of the stats.
    // The staff stream does the same for total-staff count (add/delete staff).
    // onError: a dropped WebSocket (network blip / hot reload) is logged and
    // the subscriptions are re-established instead of crashing the app.
    _attendanceSub = Supabase.instance.client
        .from('attendance')
        .stream(primaryKey: ['id'])
        .listen(
          (_) {
            if (mounted) {
              _loadData();
              _loadWeekAttendance();
            }
          },
          onError: (Object error) {
            debugPrint('[AdminDashboard] attendance stream error: $error');
            _resubscribe();
          },
          cancelOnError: false,
        );

    _staffSub = Supabase.instance.client
        .from('staff')
        .stream(primaryKey: ['id'])
        .listen(
          (_) {
            if (mounted) _loadData();
          },
          onError: (Object error) {
            debugPrint('[AdminDashboard] staff stream error: $error');
            _resubscribe();
          },
          cancelOnError: false,
        );
  }

  /// Re-establish the realtime streams after a transient error.
  /// Guarded so multiple simultaneous stream errors only resubscribe once.
  void _resubscribe() {
    if (!mounted || _resubscribing) return;
    _resubscribing = true;
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) {
        _resubscribing = false;
        return;
      }
      _attendanceSub?.cancel();
      _staffSub?.cancel();
      _subscribeToRealtimeChanges();
      _resubscribing = false;
    });
  }

  Future<void> _loadData() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final results = await Future.wait([
        AuthService.getCurrentProfile(),
        DatabaseService.getPresentTodayCount(),
        DatabaseService.getTotalStaffCount(),
        DatabaseService.getPendingLeavesCount(),
        DatabaseService.getPendingLateApprovals(),
        DatabaseService.getStaffDirectoryFull(),
        DatabaseService.getDepartments(),
        DatabaseService.getPendingLeaves(),
        DatabaseService.getTodayAttendanceList(),
        DatabaseService.getPendingAttendanceAppeals(),
        DatabaseService.getApprovedLeavesForDate(MalaysiaTime.now()),
      ]);
      if (!mounted) return;

      final todayList = results[8] as List<Map<String, dynamic>>;
      // Matched by staff_number: the attendance query's staff join doesn't
      // select an `id` column (only full_name/staff_number/role/dept), so
      // staff_number — present on both sides — is the reliable join key.
      final presentIds = <String>{};
      final lateIds = <String>{};
      final pendingIds = <String>{};
      for (final row in todayList) {
        final staffNum =
            (row['staff'] as Map<String, dynamic>?)?['staff_number'] as String?;
        final status = row['status'] as String?;
        if (staffNum == null) continue;
        if (row['late_approved'] != true) {
          if (status == 'present' || status == 'late') pendingIds.add(staffNum);
          continue;
        }
        if (status == 'late') {
          lateIds.add(staffNum);
        } else if (status == 'present') {
          presentIds.add(staffNum);
        }
      }

      setState(() {
        _profile = results[0] as Map<String, dynamic>?;
        _presentCount = results[1] as int;
        _totalStaff = results[2] as int;
        _pendingApprovals =
            (results[3] as int) +
            (results[4] as List).length +
            (results[9] as List).length;
        _staffList = results[5] as List<Map<String, dynamic>>;
        _departments = results[6] as List<Map<String, dynamic>>;
        _pendingLeaves = results[7] as List<Map<String, dynamic>>;
        _approvedLeaveStaffIds = (results[10] as List<Map<String, dynamic>>)
            .map((leave) => leave['staff_id'] as String)
            .toSet();
        _presentTodayIds = presentIds;
        _lateTodayIds = lateIds;
        _pendingTodayIds = pendingIds;
        _lastUpdated = DateTime.now();
        _isLoading = false;
        _loadError = null;
      });
    } catch (e) {
      // Bare catch on purpose: with Supabase uninitialised (offline
      // preview, tests) `Supabase.instance` throws an *AssertionError* —
      // an Error, not an Exception — which `on Exception` would let escape
      // as an unhandled async failure. Either way the shell should land on
      // its own error state instead of taking the page down.
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  /// Attendance for the current week (Sun–Thu), bucketed for the trend
  /// chart. Each punch is split into **in-office** (matched a campus
  /// geofence zone) vs **remote** (punched in from outside every zone) —
  /// see `_usesGeofence` for the graceful fallback when geofencing hasn't
  /// been configured yet. Five small queries — fine for a dashboard that's
  /// viewed occasionally, not polled.
  Future<void> _loadWeekAttendance() async {
    final now = MalaysiaTime.now();
    final sunday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday % 7));
    final days = <_DayAttendance>[];
    for (var i = 0; i < 5; i++) {
      final d = sunday.add(Duration(days: i));
      try {
        final rows = await DatabaseService.getAttendanceListForDate(
          year: d.year,
          month: d.month,
          day: d.day,
        );
        var inOffice = 0, remote = 0, late = 0;
        for (final r in rows) {
          final staff = r['staff'] as Map<String, dynamic>?;
          if (staff?['role'] != 'staff' ||
              staff?['is_active'] != true ||
              r['late_approved'] != true ||
              (r['status'] != 'present' && r['status'] != 'late')) {
            continue;
          }
          // A row only exists when `punch_in` fell inside this day, so
          // every row is a real check-in — the zone just says *where*.
          final zone = r['geofence_zone_id'] as String?;
          if (zone != null && zone.isNotEmpty) {
            inOffice++;
          } else {
            remote++;
          }
          if (r['status'] == 'late') late++;
        }
        days.add(
          _DayAttendance(
            label: _weekdayShort(d.weekday),
            date: d,
            inOffice: inOffice,
            remote: remote,
            late: late,
          ),
        );
      } on Exception {
        days.add(
          _DayAttendance(
            label: _weekdayShort(d.weekday),
            date: d,
            inOffice: 0,
            remote: 0,
            late: 0,
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _weekAttendance = days;
      _weekLoading = false;
    });
  }

  /// True once at least one punch this week matched a campus zone. When
  /// geofencing is still unconfigured (every zone id null) the in-office /
  /// remote split would be meaningless, so the chart collapses to
  /// "everything checked in = in-office" instead of showing a wall of
  /// remote workers that aren't really remote.
  bool get _usesGeofence => _weekAttendance.any((d) => d.inOffice > 0);

  /// People expected to punch in on a given weekday (active, non-admin).
  int get _expectedOnDuty {
    final n = _staffList.where((s) {
      final active = (s['is_active'] as bool?) ?? true;
      final role = (s['role'] as String?) ?? 'staff';
      return active && role == 'staff';
    }).length;
    return n > 0 ? n : _totalStaff;
  }

  int get _expectedToday {
    final onLeave = _staffList
        .where(
          (staff) =>
              staff['role'] == 'staff' &&
              staff['is_active'] == true &&
              _approvedLeaveStaffIds.contains(staff['id']) &&
              !_presentTodayIds.contains(staff['staff_number']) &&
              !_lateTodayIds.contains(staff['staff_number']),
        )
        .length;
    return (_expectedOnDuty - onLeave).clamp(0, _expectedOnDuty);
  }

  /// In-office / remote / absent split for one day, honouring the
  /// geofence fallback described above.
  ({int inOffice, int remote, int absent, int checkedIn}) _splitFor(
    _DayAttendance d,
  ) {
    final inOffice = _usesGeofence ? d.inOffice : d.inOffice + d.remote;
    final remote = _usesGeofence ? d.remote : 0;
    final checkedIn = inOffice + remote;
    final today = MalaysiaTime.now();
    final currentDay = DateTime(today.year, today.month, today.day);
    final expected = _isSameDay(d.date, today)
        ? _expectedToday
        : _expectedOnDuty;
    final absent = d.date.isAfter(currentDay)
        ? 0
        : (expected - checkedIn).clamp(0, expected);
    return (
      inOffice: inOffice,
      remote: remote,
      absent: absent,
      checkedIn: checkedIn,
    );
  }

  String _weekdayShort(int weekday) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[weekday - 1];
  }

  String get _adminName => (_profile?['full_name'] as String?) ?? 'Loading...';
  String get _adminRole => 'System Administrator';

  // Function to switch screens
  void _setScreen(int index) {
    setState(() => _currentIndex = index);
    if (index == 0) _loadData(); // refresh stats when returning to dashboard
  }

  void _openApprovalCenter() {
    // In-shell page: the rail + navbar stay mounted while the queue is
    // worked through, exactly like the dashboard and staff directory.
    _setScreen(3);
  }

  void _openAttendanceList() {
    // In-shell page: the rail + navbar stay mounted while the register is
    // browsed, exactly like the dashboard, directory and approvals queue.
    _setScreen(4);
  }

  void _openStaffDirectory({bool addStaff = false}) {
    setState(() {
      _currentIndex = 1;
      // Plain navigation resets the token so returning to the directory
      // never re-opens a drawer the admin closed earlier.
      _addStaffRequest = addStaff ? _addStaffRequest + 1 : 0;
    });
  }

  /// Convenience callback for the chrome's "Add Staff" action: jumps to the
  /// directory (rail intact) and slides the create form over it.
  void _addStaff() => _openStaffDirectory(addStaff: true);

  void _openDepartments() {
    // In-shell page — department edits call `_loadData` back through the
    // page's onChanged so the dashboard breakdown stays in sync.
    _setScreen(5);
  }

  void _openGeofenceSettings() {
    _setScreen(6);
  }

  Future<void> _handleLogout() async {
    try {
      await AuthService.signOut();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not log out: $error')));
      }
      return;
    }
    PresenceService.stop();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginPage()),
      (Route<dynamic> route) => false,
    );
  }

  // --- Derived data for the roster table -------------------------------
  String? _deptNameFor(Map<String, dynamic> staff) {
    return staff['departments']?['name'] as String?;
  }

  bool _isOnLeaveToday(String staffId) {
    return _approvedLeaveStaffIds.contains(staffId);
  }

  List<Map<String, dynamic>> get _filteredStaff {
    return _staffList.where((s) {
      final name = (s['full_name'] as String? ?? '').toLowerCase();
      final staffNum = (s['staff_number'] as String? ?? '').toLowerCase();
      final matchesSearch =
          _searchQuery.isEmpty ||
          name.contains(_searchQuery) ||
          staffNum.contains(_searchQuery);
      if (!matchesSearch) return false;

      final isActive = (s['is_active'] as bool?) ?? true;
      final onLeave = _isOnLeaveToday(s['id'] as String? ?? '');
      switch (_rosterFilter) {
        case _RosterFilter.all:
          return true;
        case _RosterFilter.active:
          return isActive;
        case _RosterFilter.inactive:
          return !isActive;
        case _RosterFilter.onLeave:
          return onLeave;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideBreakpoint;
        if (isWide) {
          return Scaffold(
            backgroundColor: _pageCanvas,
            body: Row(
              children: [
                SizedBox(width: 250, child: _buildSidebar(isWide: true)),
                Expanded(child: _buildMainArea(isWide: true)),
              ],
            ),
          );
        }
        return Scaffold(
          backgroundColor: _pageCanvas,
          drawer: Drawer(width: 260, child: _buildSidebar(isWide: false)),
          body: _buildMainArea(isWide: false),
        );
      },
    );
  }

  // Fixed height shared by the sidebar's brand block and the (wide-mode)
  // header banner, so the two end on the exact same Y and the navy band
  // runs unbroken across the entire top of the window.
  static const double _topBarHeight = 88;

  // Narrow (drawer) bar height — two fixed 44px rows plus padding. Keeping
  // it fixed means the narrow bar behaves exactly like the wide one.
  static const double _topBarHeightNarrow = 118;

  // --- SIDEBAR -----------------------------------------------------------
  // Deep slate-900 rail. It is deliberately *much* darker than the light
  // page canvas so the navigation reads as a separate structural plane and
  // can never melt into the content area beside it — the previous white-on-
  // white version had no visual boundary at all.
  static const Color _railBg = Color(0xFF0F172A); // slate-900
  static const Color _railBgDeep = Color(0xFF0A1120); // near-black base
  static const Color _railEdge = Color(0xFF020617); // slate-950 — sharp edge
  static const Color _railText = Color(0xFF94A3B8); // slate-400
  static const Color _railTextDim = Color(0xFF64748B); // slate-500
  static const Color _railTextActive = Color(0xFFF8FAFC); // slate-50
  static const Color _railActiveFrom = Color(0xFF243656);
  static const Color _railActiveTo = Color(0xFF15203A);

  Widget _buildSidebar({required bool isWide}) {
    // Builder hands us a fresh BuildContext that IS a descendant of the
    // Scaffold this sidebar sits inside (either the permanent wide layout
    // or the Drawer) — that's what Scaffold.of(context) below needs in
    // order to actually find that Scaffold and close the drawer / navigate.
    // Without this, `context` here would resolve to the outer build()'s
    // context, which sits ABOVE the Scaffold — Scaffold.of() would throw,
    // silently failing every tap.
    return Builder(
      builder: (context) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_railBg, _railBgDeep],
          ),
          border: Border(
            right: BorderSide(
              color: _railEdge,
              width: 1,
            ), // sharp, high-contrast
          ),
          boxShadow: [
            // Long, directional drop shadow so the rail casts onto the page.
            BoxShadow(
              color: Color(0x59020617),
              blurRadius: 30,
              spreadRadius: -8,
              offset: Offset(14, 0),
            ),
            BoxShadow(
              color: Color(0x2E000000),
              blurRadius: 6,
              offset: Offset(3, 0),
            ),
          ],
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Brand — the left-hand end of the top banner. It carries the
              // exact navy the banner starts with (#0F172A) and no seam of
              // its own, so the logo block and the header to its right read
              // as one continuous navy band across the entire top width.
              // The emblem artwork is navy/red on an opaque white square, so
              // it keeps a white roundel to stay legible on the dark rail.
              Container(
                height: _topBarHeight,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(color: _railBg),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      padding: const EdgeInsets.all(3.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/mara_logo.png',
                          fit: BoxFit.cover,
                          errorBuilder: (c, e, s) => const Icon(
                            Icons.school_rounded,
                            color: AppTheme.navy,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TVET MARA',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                              height: 1.1,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Admin Console',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _railText,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppTheme.gold.withValues(alpha: 0.55),
                        ),
                        color: AppTheme.gold.withValues(alpha: 0.12),
                      ),
                      child: const Text(
                        'ADMIN',
                        style: TextStyle(
                          color: AppTheme.gold,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _sidebarSectionLabel('NAVIGATION'),
                    _sidebarItem(
                      icon: Icons.dashboard_rounded,
                      label: 'Dashboard',
                      selected: _currentIndex == 0,
                      onTap: () {
                        _setScreen(0);
                        Scaffold.of(context).closeDrawer();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.fact_check_rounded,
                      label: 'Approvals',
                      selected: _currentIndex == 3,
                      badgeCount: _pendingApprovals,
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openApprovalCenter();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.manage_accounts_rounded,
                      label: 'Staff Directory',
                      selected: _currentIndex == 1,
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openStaffDirectory();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.assignment_turned_in_rounded,
                      label: 'Attendance Records',
                      selected: _currentIndex == 4,
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openAttendanceList();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.analytics_rounded,
                      label: 'System Reports',
                      selected: _currentIndex == 2,
                      onTap: () {
                        _setScreen(2);
                        Scaffold.of(context).closeDrawer();
                      },
                    ),
                    _sidebarSectionLabel('CONFIGURATION'),
                    _sidebarItem(
                      icon: Icons.business_rounded,
                      label: 'Manage Departments',
                      selected: _currentIndex == 5,
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openDepartments();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.location_on_rounded,
                      label: 'Geofence Settings',
                      selected: _currentIndex == 6,
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openGeofenceSettings();
                      },
                    ),
                  ],
                ),
              ),
              // Live system-status strip — gives the rail a "running" feel and
              // closes the vertical gap the old flat nav list left behind.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    children: [
                      const _LiveDot(),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Realtime sync active',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _railText,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Text(
                        '${_staffList.length} users',
                        style: const TextStyle(
                          color: _railTextDim,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // User profile footer.
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [AppTheme.gold, AppTheme.goldDeep],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.gold.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFF1E293B),
                        child: Text(
                          _adminName.isNotEmpty
                              ? _adminName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _adminName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: _railTextActive,
                            ),
                          ),
                          Text(
                            _adminRole,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: _railTextDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.logout_rounded,
                        color: AppTheme.maraRedSoft,
                        size: 20,
                      ),
                      tooltip: 'Logout',
                      hoverColor: Colors.white.withValues(alpha: 0.10),
                      onPressed: _handleLogout,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tiny uppercase group heading that breaks the nav into sections — the
  /// standard enterprise-rail pattern, and it uses the vertical space the
  /// old flat list left empty.
  Widget _sidebarSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: _railTextDim,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.6,
        ),
      ),
    );
  }

  Widget _sidebarItem({
    required IconData icon,
    required String label,
    bool selected = false,
    int badgeCount = 0,
    required VoidCallback onTap,
  }) {
    // Active: raised slate panel + indigo glow + a gold tab on the left
    // edge. Inactive: muted slate-400 text that brightens on hover.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: selected
                  ? const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [_railActiveFrom, _railActiveTo],
                    )
                  : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.transparent,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF33207A).withValues(alpha: 0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : const [],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                hoverColor: Colors.white.withValues(alpha: 0.06),
                highlightColor: Colors.white.withValues(alpha: 0.10),
                splashColor: Colors.white.withValues(alpha: 0.14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        icon,
                        size: 20,
                        color: selected ? AppTheme.goldLight : _railText,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: selected ? _railTextActive : _railText,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (badgeCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.maraRed,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.maraRed.withValues(alpha: 0.55),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Text(
                            '$badgeCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (selected)
            Positioned(
              left: 0,
              top: 9,
              bottom: 9,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: AppTheme.gold,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.gold.withValues(alpha: 0.7),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- MAIN AREA — top bar + scrollable content, shared by wide/narrow ---
  Widget _buildMainArea({required bool isWide}) {
    return Column(
      children: [
        _buildHeader(isWide: isWide),
        // The Staff Directory manages its own scrolling (pull-to-refresh
        // over the grid), so it sits *outside* the dashboard's scroll view
        // while staying inside the same shell — rail and navbar untouched.
        // Attendance, Departments and Geofence do the same: each owns its
        // own scroll view, none of them own a Scaffold.
        Expanded(
          child: switch (_currentIndex) {
            1 => StaffDirectoryScreen(addStaffRequest: _addStaffRequest),
            // The approval queue runs its own list, so it sits outside the
            // dashboard's scroll view — still inside the same shell.
            3 => ApprovalCenterScreen(onChanged: _loadData),
            4 => const AttendanceListScreen(),
            5 => DepartmentsScreen(onChanged: _loadData),
            6 => GeofenceZonesScreen(onChanged: _loadData),
            _ => RefreshIndicator(
              onRefresh: () async {
                await _loadData();
                await _loadWeekAttendance();
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: isWide ? 32 : 16,
                  vertical: 20,
                ),
                child: _currentIndex == 0
                    ? _buildDashboardContent(isWide: isWide)
                    : _buildReportsContent(),
              ),
            ),
          },
        ),
      ],
    );
  }

  /// Week buckets shaped for the reports page — records instead of the
  /// dashboard's private `_DayAttendance` class.
  List<({String label, int inOffice, int remote, int late})>
  get _weekForReports => [
    for (final d in _weekAttendance)
      (label: d.label, inOffice: d.inOffice, remote: d.remote, late: d.late),
  ];

  /// System Reports: analytics + export console built from the data the
  /// shell already loaded (no extra queries, no second data source).
  Widget _buildReportsContent() {
    return SystemReportsScreen(
      staff: _staffList,
      departments: _departments,
      weekAttendance: _weekForReports,
      presentToday: _presentTodayIds,
      lateToday: _lateTodayIds,
      pendingToday: _pendingTodayIds,
      approvedLeaveStaffIds: _approvedLeaveStaffIds,
      pendingApprovals: _pendingApprovals,
      lastUpdated: _lastUpdated,
      isLoading: _isLoading,
    );
  }

  Widget _buildHeader({required bool isWide}) {
    // In wide mode this sits beside the sidebar's brand block at the exact
    // same fixed height, so the navy band at the top of the screen never
    // breaks into two mismatched segments.
    if (isWide) {
      return SizedBox(
        height: _topBarHeight,
        child: LayoutBuilder(
          builder: (context, c) {
            // Search joins the action row only where it still fits beside
            // the title; below that the field simply drops out.
            final showSearch = c.maxWidth >= 780;
            return _topBar(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Row(
                  children: [
                    // Expanded, *not* Flexible: a loose flex child sizes to
                    // its text and leaves the leftover space at the END of
                    // the row, which parked the controls mid-bar. Expanded
                    // hands every spare pixel to the title block (its text
                    // still hugs the left) so the control group is pinned
                    // to the right edge — and it bounds the title so long
                    // names ellipsize instead of overflowing.
                    Expanded(child: _headerTitleBlock(withBreadcrumb: true)),
                    const SizedBox(width: 20),
                    _headerActions(showSearch: showSearch),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    // Narrow mode: sidebar is a drawer, not shown alongside the header, so
    // the banner stands on its own — title/logout/avatar on row one, search
    // and the primary action on row two, all on the same navy surface.
    return SizedBox(
      height: _topBarHeightNarrow,
      child: _topBar(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    // Builder: this context has to sit *below* the Scaffold
                    // for Scaffold.of() to find it and open the drawer.
                    Builder(
                      builder: (context) => _navIconButton(
                        icon: Icons.menu_rounded,
                        tooltip: 'Menu',
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: _headerTitleBlock(withBreadcrumb: false)),
                    const SizedBox(width: 8),
                    _navIconButton(
                      icon: Icons.logout_rounded,
                      tooltip: 'Logout',
                      onPressed: _handleLogout,
                    ),
                    const SizedBox(width: 4),
                    _profileAvatar(radius: 15),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Expanded(child: _searchField()),
                    const SizedBox(width: 8),
                    _addStaffButton(iconOnly: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Top navigation bar -------------------------------------------------
  //
  // One continuous, fully opaque banner across the whole top of the main
  // area: deep corporate navy drifting into the brand's deeper indigo. Its
  // left edge is the exact navy of the sidebar's brand block, so rail +
  // banner read as a single band spanning the full screen width. Title and
  // breadcrumb sit hard left; every control sits hard right.
  Widget _topBar({required Widget child}) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFF0F172A), Color(0xFF1B1240)],
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x590F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: SizedBox(width: double.infinity, child: child),
    );
  }

  String get _pageTitle => switch (_currentIndex) {
    0 => 'Dashboard',
    1 => 'Staff Directory',
    3 => 'Approval Center',
    4 => 'Attendance Records',
    5 => 'Manage Departments',
    6 => 'Geofence Settings',
    _ => 'System Reports',
  };

  /// Title (left of the bar) with an optional breadcrumb line under it.
  /// Light type — this block always sits on the deep navy banner.
  Widget _headerTitleBlock({required bool withBreadcrumb}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _pageTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.3,
          ),
        ),
        if (withBreadcrumb) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.home_rounded,
                size: 13,
                color: Color(0xFF94A3B8),
              ),
              const SizedBox(width: 5),
              const Text(
                'Home',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
              ),
              const SizedBox(width: 5),
              const Icon(
                Icons.chevron_right_rounded,
                size: 14,
                color: Color(0xFF64748B),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  _pageTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.gold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Right-hand control group — search, primary action, logout and avatar —
  /// pinned to the far right edge of the banner in one evenly spaced row.
  Widget _headerActions({required bool showSearch}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSearch) ...[
          SizedBox(width: 260, height: 40, child: _searchField()),
          _barDivider(),
        ],
        _addStaffButton(),
        _barDivider(),
        _navIconButton(
          icon: Icons.logout_rounded,
          tooltip: 'Logout',
          onPressed: _handleLogout,
        ),
        _profileAvatar(radius: 15),
      ],
    );
  }

  Widget _barDivider() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Container(
      width: 1,
      height: 26,
      color: Colors.white.withValues(alpha: 0.18),
    ),
  );

  /// Fixed-size icon button so rows inside the bar keep their exact height.
  Widget _navIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 19, color: color ?? const Color(0xFFCBD5E1)),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      splashRadius: 18,
      hoverColor: Colors.white.withValues(alpha: 0.12),
      highlightColor: Colors.white.withValues(alpha: 0.18),
    );
  }

  /// Admin roundel — white disc, navy initial, hairline gold ring: the one
  /// deliberate gold flourish on the banner.
  Widget _profileAvatar({required double radius}) {
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(
          color: AppTheme.gold.withValues(alpha: 0.85),
          width: 1.4,
        ),
      ),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: Colors.white,
        child: Text(
          _adminName.isNotEmpty ? _adminName[0].toUpperCase() : '?',
          style: TextStyle(
            color: _inkNavy,
            fontSize: radius,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /// Search field styled for the dark banner: translucent white fill,
  /// white type, gold focus ring.
  Widget _searchField() {
    return TextField(
      controller: _searchController,
      style: const TextStyle(color: Colors.white, fontSize: 13.5),
      cursorColor: Colors.white,
      decoration: InputDecoration(
        hintText: 'Search staff by name or ID…',
        hintStyle: TextStyle(
          color: Colors.white.withValues(alpha: 0.60),
          fontSize: 13.5,
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 18,
          color: Colors.white.withValues(alpha: 0.75),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.12),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 11,
          horizontal: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.gold, width: 1.4),
        ),
        isDense: true,
      ),
    );
  }

  /// Primary action on the banner: solid white with navy type so it reads
  /// as the one bright control against the dark surface.
  Widget _addStaffButton({bool iconOnly = false}) {
    return ElevatedButton.icon(
      onPressed: _addStaff,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: Text(
        iconOnly ? '' : 'Add Staff',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: _inkNavy,
        shadowColor: Colors.black.withValues(alpha: 0.40),
        padding: EdgeInsets.symmetric(
          horizontal: iconOnly ? 12 : 16,
          vertical: 11,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
    );
  }

  // --- DASHBOARD CONTENT --------------------------------------------------
  Widget _buildDashboardContent({required bool isWide}) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: AppTheme.maraRed, size: 32),
            const SizedBox(height: 8),
            Text(
              'Failed to load: $_loadError',
              style: const TextStyle(color: AppTheme.maraRed, fontSize: 12),
            ),
            TextButton(onPressed: _loadData, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- 4 stat cards ---
        _buildStatCards(isWide: isWide),
        const SizedBox(height: 24),

        // --- Two self-sizing content columns --------------------------
        // Left  : Staff Roster + Weekly Attendance Trend chart
        // Right : Leave Requests + Today's Coverage + Department Breakdown
        //
        // The old layout was one tall card (roster) beside one short card
        // (leave requests), which left a dead white band under the roster
        // and beside the leave panel. Splitting the lower half into two
        // independently-stacked columns fills both of those gaps with real
        // widgets instead of empty canvas.
        //
        // NOTE: no IntrinsicHeight here — the roster card contains a
        // LayoutBuilder (for the responsive table width), and LayoutBuilder
        // cannot report intrinsic dimensions, which crashes IntrinsicHeight.
        if (isWide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStaffRosterCard(),
                    const SizedBox(height: 20),
                    _buildWeeklyAttendanceCard(),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLeaveRequestsCard(),
                    const SizedBox(height: 20),
                    _buildCoverageCard(),
                    const SizedBox(height: 20),
                    _buildDepartmentBreakdownCard(),
                  ],
                ),
              ),
            ],
          )
        else ...[
          _buildStaffRosterCard(),
          const SizedBox(height: 20),
          _buildLeaveRequestsCard(),
          const SizedBox(height: 20),
          _buildCoverageCard(),
          const SizedBox(height: 20),
          _buildWeeklyAttendanceCard(),
          const SizedBox(height: 20),
          _buildDepartmentBreakdownCard(),
        ],
        const SizedBox(height: 20),

        // --- Quick Actions ---
        _buildQuickActionsCard(),
        const SizedBox(height: 30),
      ],
    );
  }

  String _fmtClock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Live "last refreshed" pill. It used to sit next to a standalone
  /// "View Attendance Records" button in its own toolbar row — that box is
  /// gone (the action now lives inside the Present Today card), so the
  /// chip rides in the Quick Actions panel header instead.
  Widget _freshnessChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: _surfaceMuted,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _LiveDot(),
          const SizedBox(width: 7),
          // Flexible: in the panel-header trailing slot this chip gets a
          // narrow budget (≈125px at phone width) — without it the label
          // sizes to its intrinsic width and blows past the header edge.
          Flexible(
            child: Text(
              _lastUpdated == null
                  ? 'Loading live data…'
                  : 'Updated ${_fmtClock(_lastUpdated!)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCards({required bool isWide}) {
    final staffTotal = _staffList.isEmpty ? _totalStaff : _staffList.length;
    final activeCount = _staffList
        .where((s) => (s['is_active'] as bool?) ?? true)
        .length;
    final activePct = staffTotal == 0
        ? 100
        : (activeCount * 100 / staffTotal).round();

    // Staff added during the current calendar month. `created_at` rides
    // along with the directory's `select('*')`; on schemas without the
    // column nothing matches and the card falls back to the active-rate
    // badge instead of showing a fabricated "+0".
    var addedThisMonth = 0;
    final now = DateTime.now();
    for (final s in _staffList) {
      final created = DateTime.tryParse(s['created_at'] as String? ?? '');
      if (created != null &&
          created.year == now.year &&
          created.month == now.month) {
        addedThisMonth++;
      }
    }

    final vsYesterday = _deltaVsYesterday();
    final presentPct = _totalStaff == 0
        ? 0
        : (_presentCount * 100 / _totalStaff).round();
    final avgPerDept = _departments.isEmpty
        ? 0
        : (staffTotal / _departments.length).round();

    final stats = [
      _StatData(
        label: 'Total Staff',
        value: '$_totalStaff',
        icon: Icons.groups_rounded,
        color: AppTheme.maraBlue,
        trend: addedThisMonth > 0 ? '+$addedThisMonth' : '$activePct%',
        caption: addedThisMonth > 0 ? 'this month' : 'active',
        tone: addedThisMonth > 0 ? _TrendTone.up : _TrendTone.neutral,
      ),
      _StatData(
        label: 'Present Today',
        value: '$_presentCount',
        icon: Icons.how_to_reg_rounded,
        color: AppTheme.success,
        trend: vsYesterday ?? '$presentPct%',
        caption: vsYesterday != null ? 'vs yesterday' : 'attendance rate',
        tone: (vsYesterday?.startsWith('-') ?? false)
            ? _TrendTone.down
            : _TrendTone.up,
        actionLabel: 'View attendance records',
        onAction: _openAttendanceList,
      ),
      _StatData(
        label: 'Pending Approvals',
        value: '$_pendingApprovals',
        icon: Icons.pending_actions_rounded,
        color: AppTheme.gold,
        trend: _pendingApprovals == 0
            ? 'All clear'
            : '$_pendingApprovals waiting',
        caption: '',
        tone: _pendingApprovals == 0 ? _TrendTone.up : _TrendTone.warning,
      ),
      _StatData(
        label: 'Departments',
        value: '${_departments.length}',
        icon: Icons.business_rounded,
        // Slate, not red: red is reserved for critical states, and this
        // tile is neutral structure — slate also ties it back to the rail.
        color: _slate700,
        trend: 'Avg $avgPerDept',
        caption: 'staff / dept',
        tone: _TrendTone.neutral,
      ),
    ];
    // Plain Row/Column of Expanded cards — no manual pixel-width math and
    // no Wrap. The previous LayoutBuilder+Wrap version could, on some
    // frames, report a collapsed height back to the parent Column while
    // still painting its full content, which let the toolbar button below
    // render on top of the cards instead of under them. IntrinsicHeight +
    // Expanded is the same battle-tested pattern already used for every
    // other side-by-side pair on this dashboard.
    Widget statRow(List<_StatData> row) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < row.length; i++) ...[
              if (i != 0) const SizedBox(width: 14),
              Expanded(child: _statCard(row[i])),
            ],
          ],
        ),
      );
    }

    if (isWide) return statRow(stats);
    return Column(
      children: [
        statRow(stats.sublist(0, 2)),
        const SizedBox(height: 14),
        statRow(stats.sublist(2, 4)),
      ],
    );
  }

  /// Week-on-week change in daily check-ins: today's total against
  /// yesterday's, from the same Sun–Thu series the trend chart draws.
  /// Returns null when there's no comparable weekday (weekends, Sunday,
  /// or a day with zero recorded punches) so the badge falls back to a
  /// plain percentage instead of inventing a delta.
  String? _deltaVsYesterday() {
    if (_weekAttendance.length < 2) return null;
    final idx = MalaysiaTime.now().weekday % 7; // Sunday -> 0
    if (idx < 1 || idx >= _weekAttendance.length) return null;
    final yesterday = _weekAttendance[idx - 1].checkedIn;
    if (yesterday == 0) return null;
    final delta =
        ((_weekAttendance[idx].checkedIn - yesterday) * 100 / yesterday)
            .round();
    return '${delta >= 0 ? '+' : ''}$delta%';
  }

  Widget _statCard(_StatData s) {
    return SizedBox(
      height: 158,
      child: _HoverCard(
        radius: 16,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Colour-coded accent rule so each tile reads at a glance.
            Container(
              height: 4,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [s.color, s.color.withValues(alpha: 0.45)],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        _glowingIcon(s),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            // scaleDown keeps the pill from overflowing the
                            // tile on very narrow phone widths.
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: _trendBadge(s),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.value,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                            height: 1.05,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    if (s.actionLabel != null) ...[
                      const SizedBox(height: 8),
                      _CardLink(label: s.actionLabel!, onTap: s.onAction!),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Gradient icon tile with a two-layer coloured glow — the "lit from
  /// inside" look the redesign calls for.
  Widget _glowingIcon(_StatData s) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [s.color, s.color.withValues(alpha: 0.66)],
        ),
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: s.color.withValues(alpha: 0.50),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: s.color.withValues(alpha: 0.28),
            blurRadius: 3,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Icon(s.icon, color: Colors.white, size: 21),
    );
  }

  /// Small trend pill (e.g. "+12% this month") — green when the number is
  /// moving the right way, red/amber when it isn't, navy when it's simply
  /// a reference figure.
  Widget _trendBadge(_StatData s) {
    final (Color fg, Color bg) = switch (s.tone) {
      _TrendTone.up => (AppTheme.successDeep, AppTheme.successSoft),
      _TrendTone.down => (AppTheme.maraRedDeep, const Color(0xFFFBEAE7)),
      _TrendTone.warning => (AppTheme.goldDeep, const Color(0xFFFCF3DE)),
      _TrendTone.neutral => (_slate700, _surfaceInset),
    };
    final icon = switch (s.tone) {
      _TrendTone.up => Icons.trending_up_rounded,
      _TrendTone.down => Icons.trending_down_rounded,
      _TrendTone.warning => Icons.pending_rounded,
      _TrendTone.neutral => Icons.trending_flat_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            s.trend,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
          if (s.caption.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              s.caption,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: fg.withValues(alpha: 0.85),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionCard({
    required Widget child,
    double radius = 16,
    EdgeInsets padding = const EdgeInsets.all(18),
  }) {
    return _HoverCard(radius: radius, padding: padding, child: child);
  }

  // Small icon-chip + title used to head every panel below the stat
  // cards — the same "icon badge next to a bold label" language pic2
  // uses for its "Current Vitals" / "Radiology" panels, in our palette.
  Widget _panelTitle(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: color),
        ),
        const SizedBox(width: 8),
        // Flexible + ellipsis: the label gives up width instead of pushing
        // its parent Row past the card's edge (long titles, wide fonts).
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  /// Panel header with an optional trailing chip/legend: sits beside the
  /// title when there's room and drops underneath it when there isn't.
  ///
  /// Both branches are deliberately overflow-proof rather than estimated:
  /// the wide branch gives the title every pixel the trailing widget does
  /// *not* use (so a long label ellipsizes instead of colliding), and the
  /// trailing widget is capped to the leftover budget so it can never
  /// squeeze the title below its estimated width.
  Widget _panelHeader({
    required IconData icon,
    required String title,
    required Color color,
    required Widget trailing,
  }) {
    return LayoutBuilder(
      builder: (context, c) {
        // Title + the 12px gap, budgeted at roughly one glyph per pixel of
        // font size — comfortably above the real text width, so the wide
        // branch is only taken when there genuinely is spare room.
        final titleBand = title.length * 9.5 + 48;
        final slack = c.maxWidth - titleBand;
        if (slack >= 120) {
          return Row(
            children: [
              Expanded(child: _panelTitle(icon, title, color)),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: slack),
                child: trailing,
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _panelTitle(icon, title, color),
            const SizedBox(height: 10),
            trailing,
          ],
        );
      },
    );
  }

  // --- Staff Roster table ---
  Widget _buildStaffRosterCard() {
    final allRows = _filteredStaff;
    // Collapsed by default: a 50-row table beside a fixed-height right
    // column was the single biggest source of dead space on the page.
    // Eight rows keeps both columns roughly the same length, with a
    // one-click "Show all" that still exposes the full result set.
    final limit = _rosterExpanded ? 50 : 8;
    final rows = allRows.length > limit ? allRows.sublist(0, limit) : allRows;
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            icon: Icons.groups_rounded,
            title: 'Staff Roster',
            color: AppTheme.maraBlue,
            trailing: TextButton(
              onPressed: _openStaffDirectory,
              child: const Text(
                'View Full Directory',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _filterChip('All', _RosterFilter.all),
              _filterChip('Active', _RosterFilter.active),
              _filterChip('Inactive', _RosterFilter.inactive),
              _filterChip('On Leave', _RosterFilter.onLeave),
            ],
          ),
          const SizedBox(height: 12),
          if (allRows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'No staff match this filter.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                // ConstrainedBox forces the table to at least fill the
                // card's width — Table then distributes the extra space
                // across columns instead of leaving it blank on the
                // right. On a narrow screen where content needs more
                // than that, it just scrolls horizontally as before.
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    headingRowHeight: 40,
                    dataRowMinHeight: 52,
                    // No fixed cap: with ellipsis+maxLines:1 on every cell,
                    // rows never actually need extra height — but this
                    // guarantees it (double.infinity = size to content) so a
                    // long name/department/role can never overflow a fixed
                    // box again, whatever gets typed into it later.
                    dataRowMaxHeight: double.infinity,
                    columnSpacing: 24,
                    columns: const [
                      DataColumn(label: Text('Staff')),
                      DataColumn(label: Text('ID')),
                      DataColumn(label: Text('Role')),
                      DataColumn(label: Text('Department')),
                      DataColumn(label: Text('Status')),
                      DataColumn(label: Text('Today')),
                      DataColumn(label: Text('Print / Export')),
                    ],
                    rows: rows.map((s) {
                      final name = (s['full_name'] as String?) ?? 'Unknown';
                      final staffId = s['id'] as String? ?? '';
                      final staffNum = s['staff_number'] as String? ?? '';
                      final isActive = (s['is_active'] as bool?) ?? true;
                      final onLeave = _isOnLeaveToday(staffId);
                      final present = _presentTodayIds.contains(staffNum);
                      final late = _lateTodayIds.contains(staffNum);
                      return DataRow(
                        cells: [
                          DataCell(
                            SizedBox(
                              width: 160,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 14,
                                    backgroundColor: AppTheme.maraBlue
                                        .withValues(alpha: 0.15),
                                    child: Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: AppTheme.navy,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              (s['staff_number'] as String?) ?? '—',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DataCell(
                            Text(
                              (s['role'] as String?) ?? 'staff',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 160,
                              child: Text(
                                _deptNameFor(s) ?? '—',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            _statusPill(
                              onLeave
                                  ? 'On Leave'
                                  : (isActive ? 'Active' : 'Inactive'),
                              onLeave
                                  ? AppTheme.gold
                                  : (isActive
                                        ? AppTheme.success
                                        : AppTheme.textFaint),
                            ),
                          ),
                          DataCell(
                            _statusPill(
                              present ? 'Present' : (late ? 'Late' : '—'),
                              present
                                  ? AppTheme.success
                                  : (late
                                        ? AppTheme.maraRed
                                        : AppTheme.textFaint),
                            ),
                          ),
                          DataCell(_printExportButton(s)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
            // Collapsed-table footer: tells the user there's more and
            // offers a one-click expand, instead of leaving a huge empty
            // column beside a 50-row table.
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F9FC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE9EDF5)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Showing ${rows.length} of ${allRows.length} matching staff',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                  if (allRows.length > limit)
                    TextButton(
                      onPressed: () =>
                          setState(() => _rosterExpanded = !_rosterExpanded),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.navy,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        _rosterExpanded
                            ? 'Show fewer'
                            : 'Show all ${allRows.length}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Clean, compact print/export action for a single roster row — opens
  /// the staff's official report (profile + attendance + leave/logbook)
  /// in a print-friendly modal preview.
  Widget _printExportButton(Map<String, dynamic> staff) {
    return Tooltip(
      message: 'Print / Export staff report',
      child: OutlinedButton.icon(
        onPressed: () => StaffReportPreview.show(context, staff),
        icon: LucideIcon(LucideIcon.printerPaths, size: 14),
        label: const Text('Print', style: TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.navy,
          side: const BorderSide(color: AppTheme.navy, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _filterChip(String label, _RosterFilter value) {
    final selected = _rosterFilter == value;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: selected ? Colors.white : AppTheme.textPrimary,
        ),
      ),
      selected: selected,
      onSelected: (_) => setState(() => _rosterFilter = value),
      selectedColor: _slate700,
      backgroundColor: _surfaceInset,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      showCheckmark: false,
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // --- Leave Requests panel ---
  Widget _buildLeaveRequestsCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            icon: Icons.event_busy_rounded,
            title: 'Leave Requests',
            color: AppTheme.gold,
            trailing: _pendingLeaves.isEmpty
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.maraRed,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${_pendingLeaves.length} Pending',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          if (_pendingLeaves.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No pending leave requests.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            )
          else
            ..._pendingLeaves.take(6).map((leave) {
              final staff = leave['staff'] as Map<String, dynamic>?;
              final name = (staff?['full_name'] as String?) ?? 'Unknown';
              final type = (leave['leave_type'] as String?) ?? 'leave';
              final start = DateTime.tryParse(
                leave['start_date'] as String? ?? '',
              );
              final end = DateTime.tryParse(leave['end_date'] as String? ?? '');
              final range = (start != null && end != null)
                  ? '${_fmtShort(start)} → ${_fmtShort(end)}'
                  : '—';
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 15,
                      backgroundColor: AppTheme.gold.withValues(alpha: 0.2),
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                          color: AppTheme.goldDeep,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            '${_capitalize(type)} · $range',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _statusPill('Pending', AppTheme.gold),
                  ],
                ),
              );
            }),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _openApprovalCenter,
              child: const Text('Review in Approval Center →'),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtShort(DateTime d) {
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
    return '${d.day} ${months[d.month - 1]}';
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  // --- Quick Actions (same tools/functions as before, list styling) ---
  Widget _buildQuickActionsCard() {
    final actions = [
      _QuickAction(
        Icons.add_business_rounded,
        'Add Staff',
        AppTheme.maraBlue,
        _addStaff,
      ),
      _QuickAction(
        Icons.event_note_rounded,
        'Holiday Setup',
        AppTheme.navy,
        () {},
      ),
      _QuickAction(
        Icons.notifications_active_rounded,
        'Send Alert',
        AppTheme.gold,
        () {},
      ),
      _QuickAction(
        Icons.rule_rounded,
        'Working Hours',
        AppTheme.success,
        () {},
      ),
      _QuickAction(
        Icons.location_city_rounded,
        'Campus Zones',
        AppTheme.goldDeep,
        () {},
      ),
      _QuickAction(
        Icons.settings_system_daydream_rounded,
        'System Logs',
        _slate700,
        () {},
      ),
    ];
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            icon: Icons.bolt_rounded,
            title: 'Quick Actions',
            color: AppTheme.navy,
            trailing: _freshnessChip(),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 700
                  ? 3
                  : (constraints.maxWidth >= 420 ? 2 : 1);
              const spacing = 8.0;
              final tileWidth =
                  (constraints.maxWidth - spacing * (cols - 1)) / cols;
              // Wrap + LayoutBuilder for a responsive column count. Unlike
              // the stat cards above, there's no sibling directly below this
              // Wrap inside the same Column, so even a transient
              // mis-reported height here can't cause the paint-over-siblings
              // symptom the stat cards had — left as Wrap since this grid's
              // item count varies.
              return Wrap(
                spacing: spacing,
                runSpacing: 4,
                children: actions
                    .map(
                      (a) => SizedBox(
                        width: tileWidth,
                        height: 52,
                        child: _quickActionTile(a),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _quickActionTile(_QuickAction a) => _QuickActionTile(action: a);

  // --- Weekly Attendance Trend chart ------------------------------------
  //
  // A real column chart — gridlines, a y-axis scale, animated columns and
  // a dashed average reference line — instead of the old five horizontal
  // bars. Each column is a full-height "everyone on duty" track (the soft
  // red headroom = absent) with the checked-in portion filled from the
  // bottom, split into in-office vs remote.
  //
  // Slot geometry (total 220px):
  //   value label 16 + gap 4 + track 180 + gap 6 + day label 14
  static const double _plotTrackH = 180;
  static const double _plotTotalH = 220;
  static const double _plotBottomPad = 20; // day gap 6 + day label 14
  static const Color _absentTop = Color(0x18C0392B); // mara red ~9%
  static const Color _absentBottom = Color(0x33C0392B); // mara red ~20%

  Widget _buildWeeklyAttendanceCard() {
    final splits = _weekAttendance.map(_splitFor).toList();
    final geo = _usesGeofence;

    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            icon: Icons.insert_chart_rounded,
            title: 'Weekly Attendance Trend',
            color: AppTheme.success,
            trailing: Wrap(
              spacing: 10,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                _legendDot(AppTheme.success, geo ? 'In-office' : 'Checked in'),
                if (geo) _legendDot(AppTheme.maraBlue, 'Remote'),
                _legendDot(const Color(0xFFE3A9A2), 'Absent'),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            geo
                ? 'Daily check-ins split by campus geofence · $_expectedOnDuty staff on duty'
                : 'Daily check-ins · $_expectedOnDuty staff on duty · geofence zones not configured yet',
            style: const TextStyle(
              fontSize: 11.5,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          if (_weekLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _trendPlot(splits),
            const SizedBox(height: 14),
            _trendSummaryStrip(splits),
          ],
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _trendPlot(
    List<({int inOffice, int remote, int absent, int checkedIn})> splits,
  ) {
    final days = _weekAttendance;
    if (days.isEmpty) return const SizedBox(height: _plotTotalH);

    // Scale to headcount (or the busiest day, if punches ever exceed it)
    // so the track always represents "everyone on duty".
    var scaleMax = _expectedOnDuty.toDouble();
    var checkedSum = 0;
    for (final s in splits) {
      if (s.checkedIn > scaleMax) scaleMax = s.checkedIn.toDouble();
      checkedSum += s.checkedIn;
    }
    if (scaleMax <= 0) scaleMax = 1;
    final avg = checkedSum / splits.length;

    return LayoutBuilder(
      builder: (context, c) {
        final axisW = c.maxWidth < 460 ? 26.0 : 34.0;
        final plotW = (c.maxWidth - axisW - 10).clamp(0.0, double.infinity);
        final slotW = plotW / days.length;
        final barW = (slotW * 0.46).clamp(14.0, 64.0);

        Widget axisLabel(String text) => SizedBox(
          width: axisW,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textFaint,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

        return SizedBox(
          height: _plotTotalH,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Y axis, nudged down by the value-label band so max / mid /
              // zero land exactly on the track's top, middle and baseline.
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: SizedBox(
                  width: axisW,
                  height: _plotTrackH,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      axisLabel(scaleMax.round().toString()),
                      axisLabel('${(scaleMax / 2).round()}'),
                      axisLabel('0'),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: _plotTotalH,
                  child: Stack(
                    children: [
                      // Horizontal gridlines behind the columns.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: _plotBottomPad,
                        height: _plotTrackH,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            _Gridline(Color(0xFFE9EDF5)),
                            _Gridline(Color(0xFFE9EDF5)),
                            _Gridline(Color(0xFFCBD5E1)),
                          ],
                        ),
                      ),
                      // Dashed weekly-average reference line.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom:
                            _plotBottomPad +
                            (avg / scaleMax * _plotTrackH).clamp(
                              0.0,
                              _plotTrackH,
                            ),
                        child: const SizedBox(
                          height: 1,
                          child: CustomPaint(painter: _DashedLinePainter()),
                        ),
                      ),
                      // The columns themselves.
                      Positioned.fill(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (var i = 0; i < days.length; i++)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: _trendColumn(
                                    day: days[i],
                                    split: splits[i],
                                    scaleMax: scaleMax,
                                    barW: barW,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _trendColumn({
    required _DayAttendance day,
    required ({int inOffice, int remote, int absent, int checkedIn}) split,
    required double scaleMax,
    required double barW,
  }) {
    final fillH = (split.checkedIn / scaleMax * _plotTrackH).clamp(
      0.0,
      _plotTrackH,
    );
    final inH = (split.inOffice / scaleMax * _plotTrackH).clamp(0.0, fillH);
    final inShare = fillH == 0 ? 0.0 : inH / fillH;
    final isToday = _isSameDay(day.date, DateTime.now());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 16,
          child: Center(
            child: Text(
              '${split.checkedIn}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: split.checkedIn == 0
                    ? AppTheme.textFaint
                    : AppTheme.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: _plotTrackH,
          child: Center(
            child: Tooltip(
              message:
                  '${day.label} · ${split.checkedIn} of $_expectedOnDuty checked in\n'
                  'In-office ${split.inOffice} · Remote ${split.remote} · Absent ${split.absent}\n'
                  '${day.late} late arrival${day.late == 1 ? '' : 's'}',
              child: SizedBox(
                width: barW,
                height: _plotTrackH,
                child: Stack(
                  children: [
                    // Absent headroom — everyone on duty who never punched in.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [_absentTop, _absentBottom],
                          ),
                        ),
                      ),
                    ),
                    // Checked-in column, grown from the baseline.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: fillH),
                        duration: const Duration(milliseconds: 750),
                        curve: Curves.easeOutCubic,
                        builder: (context, h, _) => ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                          child: SizedBox(
                            height: h,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (h > 0 && inShare > 0)
                                  Container(
                                    height: h * inShare,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          AppTheme.success,
                                          AppTheme.successDeep,
                                        ],
                                      ),
                                    ),
                                  ),
                                if (h > 0 && inShare < 1)
                                  Container(
                                    height: h * (1 - inShare),
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          AppTheme.maraBlue,
                                          AppTheme.navy,
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 14,
          child: Center(
            child: Text(
              day.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                color: isToday ? AppTheme.navy : AppTheme.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Four compact read-outs under the chart — the summary strip that keeps
  /// the panel feeling data-dense rather than decorative.
  Widget _trendSummaryStrip(
    List<({int inOffice, int remote, int absent, int checkedIn})> splits,
  ) {
    var checked = 0, inOffice = 0, late = 0, absent = 0;
    var bestIdx = -1, bestVal = -1;
    for (var i = 0; i < splits.length; i++) {
      final s = splits[i];
      checked += s.checkedIn;
      inOffice += s.inOffice;
      late += _weekAttendance[i].late;
      absent += s.absent;
      if (s.checkedIn > bestVal) {
        bestVal = s.checkedIn;
        bestIdx = i;
      }
    }
    final avg = splits.isEmpty ? 0.0 : checked / splits.length;
    final geo = _usesGeofence;
    final inShare = checked == 0 ? 0 : inOffice * 100 / checked;

    final tiles = <(String, String)>[
      (avg.toStringAsFixed(1), 'Avg / day'),
      (bestIdx < 0 ? '—' : _weekAttendance[bestIdx].label, 'Best day'),
      (
        geo ? '${inShare.round()}%' : '$late',
        geo ? 'In-office share' : 'Late arrivals',
      ),
      ('$absent', 'Absent / week'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE9EDF5)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i != 0)
              Container(width: 1, height: 30, color: const Color(0xFFE4E9F2)),
            Expanded(child: _summaryTile(tiles[i].$1, tiles[i].$2)),
          ],
        ],
      ),
    );
  }

  Widget _summaryTile(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Today's Sun–Thu bucket, or null on weekends / before the series loads.
  _DayAttendance? _todayAttendance() {
    final idx = MalaysiaTime.now().weekday % 7;
    if (idx < 0 || idx >= _weekAttendance.length) return null;
    return _weekAttendance[idx];
  }

  // --- Today's Coverage (fills the gap under Leave Requests) ------------
  static const Color _coverageInk = Color(0xFF002060);

  Widget _buildCoverageCard() {
    final expected = MalaysiaTime.now().weekday % 7 < 5 ? _expectedToday : 0;
    final today = _todayAttendance();
    final split = today == null
        ? (inOffice: 0, remote: 0, absent: expected, checkedIn: 0)
        : _splitFor(today);
    final rate = expected == 0 ? 0.0 : split.checkedIn / expected;

    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            icon: Icons.pie_chart_rounded,
            title: "Today's Coverage",
            color: _coverageInk,
            trailing: _weekLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    '${(rate * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: _coverageInk,
                    ),
                  ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  if (split.inOffice > 0)
                    Expanded(
                      flex: split.inOffice,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AppTheme.success, AppTheme.successDeep],
                          ),
                        ),
                      ),
                    ),
                  if (split.remote > 0)
                    Expanded(
                      flex: split.remote,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AppTheme.maraBlue, AppTheme.navy],
                          ),
                        ),
                      ),
                    ),
                  if (split.absent > 0)
                    Expanded(
                      flex: split.absent,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFFE8B7B0), Color(0xFFD79A92)],
                          ),
                        ),
                      ),
                    ),
                  if (split.inOffice + split.remote + split.absent == 0)
                    const Expanded(
                      flex: 1,
                      child: ColoredBox(color: Color(0xFFEFF2F7)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _coverageTile(
                  split.inOffice,
                  'In-office',
                  AppTheme.success,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _coverageTile(split.remote, 'Remote', AppTheme.maraBlue),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _coverageTile(split.absent, 'Absent', AppTheme.maraRed),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _coverageTile(int value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Department Breakdown (share bars + stacked organisation bar) -----
  static const List<Color> _deptPalette = [
    // Strictly institutional: navy family + emerald + amber + slate. No
    // violets/cyans — those were the one palette on the page that didn't
    // belong to the brand.
    AppTheme.maraBlue,
    AppTheme.success,
    AppTheme.gold,
    _slate700,
    AppTheme.navy,
    AppTheme.successDeep,
    AppTheme.goldDeep,
    Color(0xFF64748B),
  ];

  Widget _buildDepartmentBreakdownCard() {
    final items = <({String name, int headcount, int active, Color color})>[];
    for (var i = 0; i < _departments.length; i++) {
      final dept = _departments[i];
      final deptId = dept['id'] as String?;
      final deptStaff = _staffList.where((s) => s['department_id'] == deptId);
      final headcount = deptStaff.length;
      final active = deptStaff
          .where((s) => (s['is_active'] as bool?) ?? true)
          .length;
      items.add((
        name: (dept['name'] as String?) ?? 'Unnamed',
        headcount: headcount,
        active: active,
        color: _deptPalette[i % _deptPalette.length],
      ));
    }
    final totalStaff = _staffList.length;
    final denom = totalStaff == 0 ? 1 : totalStaff;
    final activeTotal = items.fold<int>(0, (a, b) => a + b.active);

    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader(
            icon: Icons.donut_small_rounded,
            title: 'Department Breakdown',
            color: _slate700,
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _surfaceInset,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _border),
              ),
              child: Text(
                '${_departments.length} depts · $totalStaff staff',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _slate700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No departments configured yet.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            )
          else ...[
            // One stacked bar = the whole organisation split by department.
            const Text(
              'Headcount share',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 14,
                child: Row(
                  children: [
                    for (final it in items)
                      if (it.headcount > 0)
                        Expanded(
                          flex: it.headcount,
                          child: Tooltip(
                            message: '${it.name} · ${it.headcount} staff',
                            child: Container(
                              height: 14,
                              decoration: BoxDecoration(
                                color: it.color,
                                border: Border(
                                  right: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    if (items.every((e) => e.headcount == 0))
                      const Expanded(
                        flex: 1,
                        child: ColoredBox(color: Color(0xFFEFF2F7)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final it in items) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: it.color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            it.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${it.headcount}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${(it.headcount * 100 / denom).round()}%',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: it.headcount / denom),
                        duration: const Duration(milliseconds: 750),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 7,
                          backgroundColor: const Color(0xFFEFF2F7),
                          valueColor: AlwaysStoppedAnimation(it.color),
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      it.headcount == 0
                          ? 'No staff assigned'
                          : '${(it.active * 100 / it.headcount).round()}% active',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: it.headcount == 0
                            ? AppTheme.textFaint
                            : (it.active == it.headcount
                                  ? AppTheme.successDeep
                                  : AppTheme.goldDeep),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Summary footer — closes the widget with a single headline
            // number instead of trailing off after the last thin bar. A
            // flat slate inset (not a navy slab): navy belongs to the rail.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _surfaceMuted,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _border),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.verified_user_rounded,
                    color: AppTheme.successDeep,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$activeTotal active staff',
                          style: const TextStyle(
                            color: _inkNavy,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'across ${items.length} departments',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    totalStaff == 0
                        ? '—'
                        : '${(activeTotal * 100 / totalStaff).round()}%',
                    style: const TextStyle(
                      color: AppTheme.successDeep,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Direction a stat-card trend pill should read: green when the number is
/// moving the right way, red when it isn't, amber when it needs action,
/// navy when it's simply a reference figure.
enum _TrendTone { up, down, warning, neutral }

class _StatData {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  /// Headline figure inside the trend pill, e.g. "+12%".
  final String trend;

  /// Small trailing caption, e.g. "this month".
  final String caption;

  final _TrendTone tone;

  /// Optional inline action rendered under the value (e.g. the old
  /// standalone "View Attendance Records" button, re-homed into the
  /// attendance metric card as a link).
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StatData({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.trend,
    required this.caption,
    required this.tone,
    this.actionLabel,
    this.onAction,
  });
}

class _QuickAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  _QuickAction(this.icon, this.label, this.color, this.onTap);
}

/// Quick-action tile: sits on a tinted slate chip and, on hover, lifts to
/// white with a coloured border + glow. The background lives on the
/// `Material` so InkWell's ripple still paints *above* it, while the
/// border/shadow animate through the inner `AnimatedContainer`.
class _QuickActionTile extends StatefulWidget {
  const _QuickActionTile({required this.action});

  final _QuickAction action;

  @override
  State<_QuickActionTile> createState() => _QuickActionTileState();
}

class _QuickActionTileState extends State<_QuickActionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    // Layering matters here: the glass fill lives on the outer container,
    // the `Material` stays transparent so InkWell's splash paints *above*
    // the fill, and the inner animated layer carries only the edge/shadow
    // so it never hides the ripple.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      // Solid white tile with a slate hairline and shadow-sm — the accent
      // colour only ever appears in the icon, never in the surface.
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: _shadowSm(hover: _hover),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: a.onTap,
          onHover: (v) => setState(() => _hover = v),
          hoverColor: _surfaceInset,
          highlightColor: _surfaceMuted,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _hover ? _borderHover : _border),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: _hover
                        ? LinearGradient(
                            colors: [a.color, a.color.withValues(alpha: 0.72)],
                          )
                        : null,
                    color: _hover ? null : a.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: _hover
                        ? [
                            BoxShadow(
                              color: a.color.withValues(alpha: 0.45),
                              blurRadius: 12,
                              offset: const Offset(0, 5),
                            ),
                          ]
                        : const [],
                  ),
                  child: Icon(
                    a.icon,
                    color: _hover ? Colors.white : a.color,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: _hover ? a.color : AppTheme.textFaint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DayAttendance {
  final String label;
  final DateTime date;

  /// Punched in from inside a campus geofence zone.
  final int inOffice;

  /// Punched in from outside every configured zone (field / WFH).
  final int remote;

  /// Rows whose attendance status is `late` — shown as chart tooltips and
  /// in the day summary line.
  final int late;

  _DayAttendance({
    required this.label,
    required this.date,
    required this.inOffice,
    required this.remote,
    required this.late,
  });

  int get checkedIn => inOffice + remote;
}

/// Pulsing green status dot for the sidebar's "realtime sync" strip.
class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 14 + 6 * _c.value,
                height: 14 + 6 * _c.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.success.withValues(
                    alpha: 0.35 * (1 - _c.value),
                  ),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.success,
                  boxShadow: [
                    BoxShadow(color: AppTheme.success, blurRadius: 6),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One horizontal gridline in the trend chart's plot area.
class _Gridline extends StatelessWidget {
  const _Gridline(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, decoration: BoxDecoration(color: color));
  }
}

/// Dashed weekly-average reference line drawn across the trend chart.
class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppTheme.gold.withValues(alpha: 0.70)
      ..strokeWidth = 1.2;
    const dash = 5.0;
    const gap = 4.0;
    final y = size.height / 2;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset(x + dash, y), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) => false;
}

/// Shared surface shell for every dashboard panel: a solid white card
/// with a slate-200 hairline, a crisp slate `shadow-sm` and a gentle lift
/// (4px rise + slightly deeper shadow) on pointer hover so the grid feels
/// responsive on desktop/web. The lift is a paint-only transform, so it
/// never reflows siblings.
///
/// Every panel uses this one shell — that uniformity is what makes the
/// page read as a single design system rather than a set of one-off boxes.
class _HoverCard extends StatefulWidget {
  const _HoverCard({
    required this.child,
    this.radius = 16,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hovered = _hover;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: double.infinity,
        transform: Matrix4.translationValues(0, hovered ? -4.0 : 0.0, 0),
        transformAlignment: Alignment.center,
        // Solid white surface + slate hairline + slate shadow-sm. No
        // translucency, gradients or backdrop blur anywhere in the stack.
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(color: hovered ? _borderHover : _border),
          boxShadow: _shadowSm(hover: hovered),
        ),
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
  }
}

/// Inline text action used inside the metric cards (e.g. the link that
/// replaced the standalone "View Attendance Records" button): navy by
/// default, lifting to the brighter institutional blue on hover.
class _CardLink extends StatefulWidget {
  const _CardLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_CardLink> createState() => _CardLinkState();
}

class _CardLinkState extends State<_CardLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? AppTheme.maraBlue : AppTheme.navy;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                  decoration: _hover
                      ? TextDecoration.underline
                      : TextDecoration.none,
                  decorationColor: color,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_forward_rounded, size: 13, color: color),
          ],
        ),
      ),
    );
  }
}
