import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/presence_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin_ui.dart';
import '../../navigation/app_page_route.dart';
import '../auth/login_page.dart';
import '../staff/report_generator_screen.dart';
import 'approval_center_screen.dart';
import 'attendance_list_screen.dart';
import 'departments_screen.dart';
import 'geofence_zones_screen.dart';
import 'staff_directory_screen.dart';

/// Breakpoint above which the sidebar is permanently docked instead of
/// living in a Drawer. Tablets/desktop web get the "real" dashboard
/// layout; phones get the same content behind a hamburger menu.
const double _wideBreakpoint = 900;

enum _RosterFilter { all, active, inactive, onLeave }

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard>
    with WidgetsBindingObserver {
  // 0 = Dashboard, 1 = Staff Directory, 2 = Reports
  int _currentIndex = 0;

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
  Set<String> _presentTodayIds = {};
  Set<String> _lateTodayIds = {};
  List<_DayAttendance> _weekAttendance = [];
  bool _weekLoading = true;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _RosterFilter _rosterFilter = _RosterFilter.all;

  // Realtime subscriptions — auto-refresh stats when attendance OR staff
  // records change (add/delete/edit staff must update the Present X/Y card).
  StreamSubscription<List<Map<String, dynamic>>>? _attendanceSub;
  StreamSubscription<List<Map<String, dynamic>>>? _staffSub;
  bool _resubscribing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    _loadWeekAttendance();
    _subscribeToRealtimeChanges();
    // Report this admin as online for as long as the app runs.
    PresenceService.start();
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
    _searchController.dispose();
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
      ]);
      if (!mounted) return;

      final todayList = results[8] as List<Map<String, dynamic>>;
      // Matched by staff_number: the attendance query's staff join doesn't
      // select an `id` column (only full_name/staff_number/role/dept), so
      // staff_number — present on both sides — is the reliable join key.
      final presentIds = <String>{};
      final lateIds = <String>{};
      for (final row in todayList) {
        final staffNum =
            (row['staff'] as Map<String, dynamic>?)?['staff_number'] as String?;
        final status = row['status'] as String?;
        if (staffNum == null) continue;
        if (status == 'late') {
          lateIds.add(staffNum);
        } else if (status == 'present') {
          presentIds.add(staffNum);
        }
      }

      setState(() {
        _loadError = null;
        _profile = results[0] as Map<String, dynamic>?;
        _presentCount = results[1] as int;
        _totalStaff = results[2] as int;
        _pendingApprovals = (results[3] as int) + (results[4] as List).length;
        _staffList = results[5] as List<Map<String, dynamic>>;
        _departments = results[6] as List<Map<String, dynamic>>;
        _pendingLeaves = results[7] as List<Map<String, dynamic>>;
        _presentTodayIds = presentIds;
        _lateTodayIds = lateIds;
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

  /// Attendance for the current week (Mon–Fri), bucketed by status, for the
  /// "Weekly Attendance" bars. Five small queries — fine for a dashboard
  /// that's viewed occasionally, not polled.
  Future<void> _loadWeekAttendance() async {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final days = <_DayAttendance>[];
    for (var i = 0; i < 5; i++) {
      final d = monday.add(Duration(days: i));
      try {
        final rows = await DatabaseService.getAttendanceListForDate(
          year: d.year,
          month: d.month,
          day: d.day,
        );
        int present = 0, late = 0, absentOrLeave = 0;
        for (final r in rows) {
          switch (r['status'] as String?) {
            case 'present':
              present++;
            case 'late':
              late++;
            default:
              absentOrLeave++;
          }
        }
        days.add(
          _DayAttendance(
            label: _weekdayShort(d.weekday),
            present: present,
            late: late,
            absentOrLeave: absentOrLeave,
          ),
        );
      } on Exception {
        days.add(
          _DayAttendance(
            label: _weekdayShort(d.weekday),
            present: 0,
            late: 0,
            absentOrLeave: 0,
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
    Navigator.push(context, appPageRoute(const ApprovalCenterScreen())).then((
      _,
    ) {
      if (mounted) _loadData();
    });
  }

  void _openAttendanceList() {
    Navigator.push(context, appPageRoute(const AttendanceListScreen()));
  }

  void _openStaffDirectory() async {
    await Navigator.push(context, appPageRoute(const StaffDirectoryScreen()));
    // Returning from the directory (staff added/edited/deleted) — the
    // Present X/Y stats may have changed, so reload them immediately.
    if (mounted) _loadData();
  }

  void _openDepartments() async {
    await Navigator.push(context, appPageRoute(const DepartmentsScreen()));
    if (mounted) _loadData();
  }

  void _openGeofenceSettings() {
    Navigator.push(context, appPageRoute(const GeofenceZonesScreen()));
  }

  Future<void> _handleLogout() async {
    // Stop the heartbeat first so it can't fire after the session is gone.
    PresenceService.stop();
    await AuthService.signOut();
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
    final today = DateTime.now();
    for (final leave in _pendingLeaves) {
      if (leave['staff_id'] != staffId) continue;
      final start = DateTime.tryParse(leave['start_date'] as String? ?? '');
      final end = DateTime.tryParse(leave['end_date'] as String? ?? '');
      if (start == null || end == null) continue;
      if (!today.isBefore(start) && !today.isAfter(end)) return true;
    }
    return false;
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
    return Theme(
      data: AdminUi.theme(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= _wideBreakpoint;
          if (isWide) {
            return Scaffold(
              backgroundColor: AdminUi.background,
              body: SafeArea(
                child: Row(
                  children: [
                    SizedBox(width: 240, child: _buildSidebar(isWide: true)),
                    Expanded(child: _buildMainArea(isWide: true)),
                  ],
                ),
              ),
            );
          }
          return Scaffold(
            backgroundColor: AdminUi.background,
            drawer: Drawer(width: 260, child: _buildSidebar(isWide: false)),
            body: SafeArea(child: _buildMainArea(isWide: false)),
          );
        },
      ),
    );
  }

  // Fixed height shared by the sidebar's brand block and the (wide-mode)
  // header, so their bottom borders/dividers land on the exact same Y and
  // read as one continuous line across the screen instead of two
  // mismatched segments.
  static const double _topBarHeight = 88;

  // --- SIDEBAR — branded navigation, light theme, active-state highlight
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
          color: Colors.white,
          border: Border(right: BorderSide(color: AdminUi.border)),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Brand — same logos as the staff app's top bar.
              SizedBox(
                height: _topBarHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Row(
                    children: [
                      SizedBox(
                        height: 52,
                        width: 52,
                        child: Image.asset(
                          'assets/images/mara_logo.png',
                          fit: BoxFit.contain,
                          errorBuilder: (c, e, s) => const Icon(
                            Icons.school_rounded,
                            color: AppTheme.navy,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: Image.asset(
                            'assets/images/tvetmara_logo.png',
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                            errorBuilder: (c, e, s) => const Text(
                              'TVETMARA',
                              style: TextStyle(
                                color: AppTheme.navy,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 16, 12, 14),
                      child: Text(
                        'WORKSPACE',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.8,
                          color: AdminUi.muted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
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
                      badgeCount: _pendingApprovals,
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openApprovalCenter();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.manage_accounts_rounded,
                      label: 'Staff Directory',
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openStaffDirectory();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.assignment_turned_in_rounded,
                      label: 'Attendance Records',
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
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Divider(height: 1),
                    ),
                    _sidebarItem(
                      icon: Icons.business_rounded,
                      label: 'Departments',
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openDepartments();
                      },
                    ),
                    _sidebarItem(
                      icon: Icons.location_on_rounded,
                      label: 'Campus zones',
                      onTap: () {
                        Scaffold.of(context).closeDrawer();
                        _openGeofenceSettings();
                      },
                    ),
                  ],
                ),
              ),
              // User profile footer.
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: AppTheme.navy,
                      child: Text(
                        _adminName.isNotEmpty
                            ? _adminName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
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
                            _adminName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            _adminRole,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.logout_rounded,
                        color: AppTheme.maraRed,
                        size: 20,
                      ),
                      tooltip: 'Logout',
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

  Widget _sidebarItem({
    required IconData icon,
    required String label,
    bool selected = false,
    int badgeCount = 0,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? AdminUi.navy : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? Colors.white : AdminUi.muted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: selected ? Colors.white : AdminUi.ink,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
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
    );
  }

  // --- MAIN AREA — header + scrollable content, shared by wide/narrow ---
  Widget _buildMainArea({required bool isWide}) {
    return Column(
      children: [
        _buildHeader(isWide: isWide),
        Expanded(
          child: _currentIndex == 2
              ? const ReportGeneratorScreen(adminMode: true, showAppBar: false)
              : RefreshIndicator(
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
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1440),
                        child: _buildDashboardContent(isWide: isWide),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildHeader({required bool isWide}) {
    // In wide mode this sits beside the sidebar's brand block, so it uses
    // the exact same fixed height — that's what makes the two bottom
    // borders line up into one continuous line instead of a broken one.
    if (isWide) {
      return Container(
        height: _topBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFEAEDF5))),
        ),
        child: Row(
          children: [
            Text(
              _currentIndex == 0
                  ? 'Dashboard'
                  : _currentIndex == 1
                  ? 'Staff Directory'
                  : 'System Reports',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppTheme.navy,
              ),
            ),
            const Spacer(),
            if (_currentIndex == 0)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: SizedBox(height: 44, child: _searchField()),
                ),
              ),
            const SizedBox(width: 12),
            _addStaffButton(),
            const SizedBox(width: 16),
            CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.navy,
              child: Text(
                _adminName.isNotEmpty ? _adminName[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Narrow mode: sidebar is a drawer, not shown alongside the header, so
    // there's no alignment constraint — free to wrap onto two rows.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEAEDF5))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu_rounded, color: AppTheme.navy),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
              Text(
                _currentIndex == 0
                    ? 'Dashboard'
                    : _currentIndex == 1
                    ? 'Staff Directory'
                    : 'System Reports',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.navy,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.logout_rounded, color: AppTheme.maraRed),
                tooltip: 'Logout',
                onPressed: _handleLogout,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: SizedBox(height: 44, child: _searchField())),
              const SizedBox(width: 8),
              _addStaffButton(iconOnly: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchController,
      decoration: InputDecoration(
        hintText: 'Search staff by name or ID…',
        prefixIcon: const Icon(Icons.search, size: 20),
        filled: true,
        fillColor: const Color(0xFFF4F5F8),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 12,
          horizontal: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        isDense: true,
      ),
    );
  }

  Widget _addStaffButton({bool iconOnly = false}) {
    return ElevatedButton.icon(
      onPressed: _openStaffDirectory,
      icon: const Icon(Icons.add, size: 18),
      label: Text(iconOnly ? '' : 'Staff directory'),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.navy,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(
          horizontal: iconOnly ? 12 : 16,
          vertical: 12,
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
        AdminPageHeading(
          title: 'Your institution at a glance',
          subtitle:
              'Welcome back, $_adminName. Here’s what’s happening with your team today.',
        ),
        // --- 4 stat cards ---
        _buildStatCards(isWide: isWide),
        const SizedBox(height: 24),

        // View Attendance Records
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _openAttendanceList,
            icon: const Icon(
              Icons.assignment_turned_in_outlined,
              color: AppTheme.navy,
            ),
            label: const Text(
              'View Attendance Records',
              style: TextStyle(
                color: AppTheme.navy,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.navy),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),

        // --- Roster + Leave Requests: side-by-side on wide, stacked on narrow
        if (MediaQuery.sizeOf(context).width >= 1250)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: _buildStaffRosterCard()),
                const SizedBox(width: 20),
                Expanded(flex: 1, child: _buildLeaveRequestsCard()),
              ],
            ),
          )
        else ...[
          _buildStaffRosterCard(),
          const SizedBox(height: 20),
          _buildLeaveRequestsCard(),
        ],
        const SizedBox(height: 20),

        // --- Quick Actions ---
        _buildQuickActionsCard(),
        const SizedBox(height: 20),

        // --- Weekly Attendance + Department Overview ---
        if (isWide)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildWeeklyAttendanceCard()),
                const SizedBox(width: 20),
                Expanded(child: _buildDepartmentOverviewCard()),
              ],
            ),
          )
        else ...[
          _buildWeeklyAttendanceCard(),
          const SizedBox(height: 20),
          _buildDepartmentOverviewCard(),
        ],
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _buildStatCards({required bool isWide}) {
    final stats = [
      _StatData(
        'Total Staff',
        '$_totalStaff',
        Icons.groups_rounded,
        AppTheme.maraBlue,
      ),
      _StatData(
        'Present Today',
        '$_presentCount',
        Icons.how_to_reg_rounded,
        const Color(0xFF2E9E5B),
      ),
      _StatData(
        'Pending Approvals',
        '$_pendingApprovals',
        Icons.pending_actions_rounded,
        const Color(0xFFE0A32C),
      ),
      _StatData(
        'Departments',
        '${_departments.length}',
        Icons.business_rounded,
        AppTheme.maraRed,
      ),
    ];
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: isWide ? 4 : 2,
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      mainAxisExtent: 164,
      children: stats.map((s) => _statCard(s)).toList(),
    );
  }

  Widget _statCard(_StatData s) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AdminUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AdminUi.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(s.icon, color: AdminUi.navy, size: 20),
          ),
          const Spacer(),
          Text(
            s.value,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          Text(
            s.label,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AdminUi.panel(),
      child: child,
    );
  }

  // --- Staff Roster table ---
  Widget _buildStaffRosterCard() {
    final rows = _filteredStaff;
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'Staff Roster',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _openStaffDirectory,
                child: const Text('View Full Directory'),
              ),
            ],
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
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'No staff match this filter.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
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
                ],
                rows: rows.take(50).map((s) {
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
                                backgroundColor: AppTheme.maraBlue.withValues(
                                  alpha: 0.15,
                                ),
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : '?',
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
                              ? const Color(0xFFE0A32C)
                              : (isActive
                                    ? const Color(0xFF2E9E5B)
                                    : AppTheme.textFaint),
                        ),
                      ),
                      DataCell(
                        _statusPill(
                          present ? 'Present' : (late ? 'Late' : '—'),
                          present
                              ? const Color(0xFF2E9E5B)
                              : (late ? AppTheme.maraRed : AppTheme.textFaint),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
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
      selectedColor: AppTheme.navy,
      backgroundColor: const Color(0xFFF4F5F8),
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
          Row(
            children: [
              const Text(
                'Leave Requests',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              if (_pendingLeaves.isNotEmpty)
                Container(
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
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
                    _statusPill('Pending', const Color(0xFFE0A32C)),
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
        _openStaffDirectory,
      ),
      _QuickAction(
        Icons.event_note_rounded,
        'Holiday Setup',
        Colors.purple,
        () {},
      ),
      _QuickAction(
        Icons.notifications_active_rounded,
        'Send Alert',
        AppTheme.maraRed,
        () {},
      ),
      _QuickAction(Icons.rule_rounded, 'Working Hours', Colors.teal, () {}),
      _QuickAction(
        Icons.location_city_rounded,
        'Campus Zones',
        Colors.orange,
        () {},
      ),
      _QuickAction(
        Icons.settings_system_daydream_rounded,
        'System Logs',
        Colors.grey,
        () {},
      ),
    ];
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quick Actions',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 700
                  ? 3
                  : (constraints.maxWidth >= 420 ? 2 : 1);
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: cols,
                mainAxisSpacing: 4,
                crossAxisSpacing: 8,
                childAspectRatio: 4.2,
                children: actions.map((a) => _quickActionTile(a)).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _quickActionTile(_QuickAction a) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: a.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: a.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(a.icon, color: a.color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  a.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppTheme.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Weekly Attendance stacked bars ---
  Widget _buildWeeklyAttendanceCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Weekly Attendance',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
              _legendDot(const Color(0xFF2E9E5B), 'Present'),
              const SizedBox(width: 10),
              _legendDot(AppTheme.gold, 'Late'),
              const SizedBox(width: 10),
              _legendDot(AppTheme.maraRed, 'Absent'),
            ],
          ),
          const SizedBox(height: 16),
          if (_weekLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            ..._weekAttendance.map((d) => _weekBar(d)),
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
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _weekBar(_DayAttendance d) {
    final total = d.present + d.late + d.absentOrLeave;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            d.label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 14,
              child: total == 0
                  ? Container(color: const Color(0xFFF0F1F5))
                  : Row(
                      children: [
                        Expanded(
                          flex: d.present,
                          child: Container(color: const Color(0xFF2E9E5B)),
                        ),
                        Expanded(
                          flex: d.late,
                          child: Container(color: AppTheme.gold),
                        ),
                        Expanded(
                          flex: d.absentOrLeave,
                          child: Container(color: AppTheme.maraRed),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${d.present} present · ${d.late} late · ${d.absentOrLeave} absent/leave',
            style: const TextStyle(fontSize: 10, color: AppTheme.textFaint),
          ),
        ],
      ),
    );
  }

  // --- Department Overview table ---
  Widget _buildDepartmentOverviewCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Department Overview',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          if (_departments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No departments configured yet.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            )
          else
            ..._departments.map((dept) {
              final deptId = dept['id'] as String?;
              final deptStaff = _staffList
                  .where((s) => s['department_id'] == deptId)
                  .toList();
              final headcount = deptStaff.length;
              final activeCount = deptStaff
                  .where((s) => (s['is_active'] as bool?) ?? true)
                  .length;
              final utilization = headcount == 0
                  ? 0.0
                  : activeCount / headcount;
              final utilColor = utilization >= 0.9
                  ? const Color(0xFF2E9E5B)
                  : (utilization >= 0.75 ? AppTheme.gold : AppTheme.maraRed);
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            (dept['name'] as String?) ?? 'Unnamed',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '$headcount staff',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: headcount == 0 ? 0 : utilization,
                        minHeight: 8,
                        backgroundColor: const Color(0xFFF0F1F5),
                        valueColor: AlwaysStoppedAnimation(utilColor),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      headcount == 0
                          ? 'No staff assigned'
                          : '${(utilization * 100).round()}% active',
                      style: TextStyle(fontSize: 10, color: utilColor),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _StatData {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  _StatData(this.label, this.value, this.icon, this.color);
}

class _QuickAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  _QuickAction(this.icon, this.label, this.color, this.onTap);
}

class _DayAttendance {
  final String label;
  final int present;
  final int late;
  final int absentOrLeave;
  _DayAttendance({
    required this.label,
    required this.present,
    required this.late,
    required this.absentOrLeave,
  });
}
