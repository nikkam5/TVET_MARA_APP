import 'package:flutter/material.dart';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/geofence_service.dart';
import '../../services/presence_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/scrollable_bottom_nav.dart';
import '../auth/login_page.dart';
import 'attendance_history.dart';
import 'staff_profile.dart';
import 'report_generator_screen.dart';

class StaffDashboard extends StatefulWidget {
  const StaffDashboard({super.key});

  @override
  State<StaffDashboard> createState() => _StaffDashboardState();
}

class _StaffDashboardState extends State<StaffDashboard>
    with WidgetsBindingObserver {
  // 0 = Home, 1 = Punch, 2 = Appeals, 3 = Reports, 4 = Profile.
  // All five tabs live inside this Scaffold's body (via `screens` in
  // build()) so the bottom nav — and the rest of the app chrome — stays
  // on screen no matter which tab is active, instead of Appeals/Reports/
  // Profile pushing their own full-screen routes with their own AppBar.
  int _currentIndex = 0;

  static const List<NavTabItem> _navItems = [
    NavTabItem(
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      label: 'Home',
    ),
    NavTabItem(icon: Icons.fingerprint, label: 'Punch'),
    NavTabItem(
      icon: Icons.assignment_late_outlined,
      activeIcon: Icons.assignment_late_rounded,
      label: 'Appeals',
    ),
    NavTabItem(
      icon: Icons.insert_chart_outlined_rounded,
      activeIcon: Icons.insert_chart_rounded,
      label: 'Reports',
    ),
    NavTabItem(
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: 'Profile',
    ),
  ];

  // --- Dashboard Data (live from Supabase) ---
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _announcements = [];
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    // Report this staff member as online for as long as the app runs.
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

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        AuthService.getCurrentProfile(),
        DatabaseService.getAnnouncements(),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as Map<String, dynamic>?;
        _announcements = List<Map<String, dynamic>>.from(results[1] as List);
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
  String get _staffDepartment =>
      (_profile?['departments']?['name'] as String?) ?? '—';

  // Switches the active tab in place — no route push, so the bottom nav
  // and app chrome never disappear.
  void _switchToTab(int index) {
    setState(() => _currentIndex = index);
  }

  // Used by drawer items: closes the drawer, then switches tab.
  void _setScreen(int index) {
    Navigator.pop(context); // Close side drawer after selection
    _switchToTab(index);
  }

  // Handles taps on the scrollable bottom nav.
  void _onNavTap(int index) => _switchToTab(index);

  // Back button shown at the top of every tab. Any tab other than Home
  // returns to Home; Home itself (nothing left to go back to in-app)
  // offers to exit.
  Future<void> _handleBackTap() async {
    if (_currentIndex != 0) {
      _switchToTab(0);
      return;
    }
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Exit app?'),
        content: const Text('Are you sure you want to close TVET MARA Staff?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.violet),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Exit', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (shouldExit == true && mounted) {
      Navigator.of(context).maybePop();
    }
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

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      _buildDashboardView(), // Index 0 — Home
      const PunchcardScreen(), // Index 1 — Punch
      const AttendanceHistoryScreen(showAppBar: false), // Index 2 — Appeals
      const ReportGeneratorScreen(showAppBar: false), // Index 3 — Reports
      const StaffProfileScreen(showAppBar: false), // Index 4 — Profile
    ];

    const titles = [
      "TVET MARA Staff",
      "Punchcard",
      "Attendance History",
      "Report Generator",
      "My Profile",
    ];

    return Scaffold(
      backgroundColor: AppTheme.bgBottom,
      extendBody: true,
      appBar: AppTopBar(
        title: titles[_currentIndex],
        onBack: _handleBackTap,
        trailing: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu_rounded, color: AppTheme.navy),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: _buildSideDrawer(),
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.pageGradient),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: KeyedSubtree(
            key: ValueKey(_currentIndex),
            child: screens[_currentIndex],
          ),
        ),
      ),
      bottomNavigationBar: ScrollableBottomNav(
        items: _navItems,
        currentIndex: _currentIndex,
        onTap: _onNavTap,
      ),
    );
  }

  // --- 1. SIDE DRAWER (HAMBURGER MENU) ---
  Widget _buildSideDrawer() {
    return Drawer(
      child: Column(
        children: [
          // Header (Clickable to open Staff Profile)
          InkWell(
            onTap: () => _setScreen(4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.only(
                top: 50,
                bottom: 20,
                left: 20,
                right: 20,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF002060), Color(0xFF0040A0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border(
                  bottom: BorderSide(color: AppTheme.gold, width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Good Morning,",
                    style: TextStyle(color: AppTheme.goldLight, fontSize: 16),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _staffName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      const Icon(Icons.badge, color: Colors.white70, size: 16),
                      const SizedBox(width: 5),
                      Text(
                        _staffDepartment,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Drawer Menu Navigation
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _drawerTile(Icons.home, "Home Dashboard", 0),
                _drawerTile(Icons.person, "My Profile", 4),
                _drawerTile(Icons.fingerprint, "Attendance (Punchcard)", 1),
                _drawerTile(Icons.history, "Leave & Appeals", 2),
                _drawerTile(Icons.picture_as_pdf, "Report Generator", 3),
                const Divider(),
                _drawerTile(Icons.people, "Staff Directory", 0),
                _drawerTile(Icons.support_agent, "IT Support", 0),
                _drawerTile(Icons.settings, "Settings", 0),
              ],
            ),
          ),

          // Logout Action
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lock_outline, color: AppTheme.maraRed),
            title: const Text(
              "Logout",
              style: TextStyle(
                color: AppTheme.maraRed,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: _handleLogout,
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _drawerTile(IconData icon, String title, int indexTarget) {
    return ListTile(
      leading: Icon(icon, color: Colors.grey[700]),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      onTap: () => _setScreen(indexTarget),
    );
  }

  // --- 2. HOME DASHBOARD VIEW ---
  Widget _buildDashboardView() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Banner with Quick Actions — vivid navy gradient + a gold
          // trim along the bottom edge for a bit more warmth/depth.
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              gradient: AppTheme.headerGradient,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
              border: const Border(
                bottom: BorderSide(color: AppTheme.gold, width: 3),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.navy.withValues(alpha: 0.25),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: AppTheme.gold.withValues(alpha: 0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _topActionIcon(
                  Icons.fingerprint,
                  "Punchcard",
                  () => _switchToTab(1),
                ),
                _topActionIcon(Icons.history, "Appeals", () => _switchToTab(2)),
                _topActionIcon(
                  Icons.insert_chart,
                  "Reports",
                  () => _switchToTab(3),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // News & Announcements
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "News & Announcements",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  "Stay ahead, stay inspired",
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Announcements (live from Supabase)
          _buildAnnouncementsSection(),

          const SizedBox(height: 30),

          // Quick Tools Grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TweenAnimationBuilder(
              tween: Tween<double>(begin: 0.5, end: 1.0),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (context, scale, child) {
                return Transform.scale(scale: scale, child: child);
              },
              child: GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 4,
                mainAxisSpacing: 20,
                crossAxisSpacing: 10,
                children: [
                  _gridIcon(Icons.article, "What's New", Colors.orange, () {}),
                  _gridIcon(Icons.map, "Campus Map", AppTheme.maraRed, () {}),
                  _gridIcon(Icons.people, "Directory", Colors.purple, () {}),
                  _gridIcon(
                    Icons.local_hospital,
                    "Health",
                    Colors.green,
                    () {},
                  ),
                  _gridIcon(Icons.phone, "Contact", Colors.teal, () {}),
                  _gridIcon(Icons.help, "Support", Colors.blue, () {}),
                  _gridIcon(
                    Icons.assessment,
                    "Reports",
                    Colors.indigo,
                    () => _switchToTab(3),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  // Announcements section — live data with loading / error / empty states
  Widget _buildAnnouncementsSection() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: AppTheme.maraRed),
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
    if (_announcements.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Text(
          'No announcements yet.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    return Column(
      children: _announcements.asMap().entries.map((entry) {
        final a = entry.value;
        final title = (a['title'] as String?) ?? 'Untitled';
        final publishedAt = a['published_at'] as String?;
        final dateText = publishedAt != null
            ? _formatDate(DateTime.tryParse(publishedAt) ?? DateTime.now())
            : '';
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: 350 + (entry.key * 80)),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 14),
              child: child,
            ),
          ),
          child: Container(
            margin: const EdgeInsets.only(left: 20, right: 20, bottom: 12),
            padding: const EdgeInsets.all(15),
            decoration: AppTheme.glassCard(radius: 16),
            child: Row(
              children: [
                Container(
                  height: 60,
                  width: 60,
                  decoration: BoxDecoration(
                    gradient: AppTheme.announcementGradient,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.teal.withValues(alpha: 0.35),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.campaign,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        dateText,
                        style: const TextStyle(
                          color: AppTheme.textFaint,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _formatDate(DateTime dt) {
    final days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return "${days[dt.weekday - 1]}, ${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}";
  }

  Widget _topActionIcon(IconData icon, String label, VoidCallback onTap) {
    return BouncingWidget(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppTheme.gold.withValues(alpha: 0.35),
                  Colors.white.withValues(alpha: 0.08),
                ],
              ),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: AppTheme.goldLight.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(icon, color: AppTheme.goldLight, size: 24),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _gridIcon(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return BouncingWidget(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF3B6FE0), // vivid blue
                  Color(0xFF7B3FE4), // vivid purple
                ],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF3B6FE0).withValues(alpha: 0.30),
                  blurRadius: 10,
                ),
                BoxShadow(
                  color: const Color(0xFF7B3FE4).withValues(alpha: 0.30),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

// --- 3. PUNCHCARD VIEW ---
class PunchcardScreen extends StatefulWidget {
  const PunchcardScreen({super.key});

  @override
  State<PunchcardScreen> createState() => _PunchcardScreenState();
}

class _PunchcardScreenState extends State<PunchcardScreen> {
  // Cutoff time — punching in after this counts as late.
  static const int _cutoffHour = 8;
  static const int _cutoffMinute = 0;

  bool _isPunching = false;
  bool _loadingStatus = true;
  Map<String, dynamic>? _today;
  String? _error;
  String? _lateRemark;

  // Geofence state (LIVE — updates as the user moves)
  GeofenceResult? _geofenceResult;
  bool _isCheckingLocation = true;
  StreamSubscription<GeofenceResult>? _geofenceSub;
  Position? _lastPosition;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _startLocationStream();
  }

  @override
  void dispose() {
    _geofenceSub?.cancel();
    super.dispose();
  }

  void _startLocationStream() {
    _geofenceSub = GeofenceService.geofenceStream().listen(
      (result) {
        if (!mounted) return;
        // Capture the latest position for punchIn (result carries the
        // position it was computed from — no extra GPS fetch needed)
        if (result.position != null) _lastPosition = result.position;
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

  Future<void> _refreshStatus() async {
    setState(() {
      _loadingStatus = true;
      _error = null;
    });
    try {
      final row = await DatabaseService.getTodayAttendance();
      if (!mounted) return;
      setState(() {
        _today = row;
        _lateRemark = row?['late_reason'] as String?;
        _loadingStatus = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingStatus = false;
      });
    }
  }

  // Status derived from today's attendance row:
  //  none          -> hasn't punched in yet
  //  on-time       -> punched in < 08:00 (late_approved = true)
  //  late-pending  -> punched in >= 08:00, reason not yet submitted
  //  late-review   -> reason submitted, waiting for admin
  //  late-approved -> admin approved the reason
  String get _statusKey {
    final row = _today;
    if (row == null) return 'none';

    // Already punched out → done for the day
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

  bool get _hasPunchedOut => _today?['punch_out'] != null;
  bool get _isInsideZone => _geofenceResult?.isInside ?? false;

  Future<void> _handlePunchOut() async {
    if (_isPunching) return;
    if (_today == null) return;
    if (_hasPunchedOut) return;

    setState(() => _isPunching = true);
    try {
      Position? position = _lastPosition;
      if (position == null) {
        try {
          position = await GeofenceService.getCurrentPosition();
        } on Exception {
          // fallback if GPS not available
        }
      }

      await DatabaseService.punchOut(
        latitude: position?.latitude ?? 0,
        longitude: position?.longitude ?? 0,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "Punched out successfully. Have a great day!",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.green[700],
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(15),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
      );
      await _refreshStatus();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Punch out failed: $e'),
          backgroundColor: AppTheme.maraRed,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(15),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isPunching = false);
    }
  }

  Future<void> _handlePunchIn() async {
    if (_isPunching) return;
    if (_statusKey != 'none') return; // already punched in today
    if (!_isInsideZone) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must be inside a TVET MARA zone to punch in.'),
          backgroundColor: AppTheme.maraRed,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.all(15),
        ),
      );
      return;
    }

    final now = DateTime.now();
    final cutoff = DateTime(
      now.year,
      now.month,
      now.day,
      _cutoffHour,
      _cutoffMinute,
    );
    final isLate = now.isAfter(cutoff);

    String? remark;
    if (isLate) {
      remark = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _LateRemarksDialog(),
      );
      if (remark == null) return; // user cancelled
    }

    setState(() => _isPunching = true);
    try {
      // Use the latest GPS position from the live stream (fallback to a
      // fresh fetch if the stream hasn't emitted yet)
      Position? position = _lastPosition;
      if (position == null) {
        try {
          position = await GeofenceService.getCurrentPosition();
        } on Exception {
          // Fallback — zone check already passed, use 0,0 if GPS times out
        }
      }

      await DatabaseService.punchIn(
        latitude: position?.latitude ?? 0,
        longitude: position?.longitude ?? 0,
        geofenceZoneId:
            (_geofenceResult?.matchedZone ??
                    _geofenceResult?.nearestZone)?['id']
                as String?,
      );

      if (isLate && remark != null) {
        await DatabaseService.submitLateReason(remark);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isLate
                ? "Late punch-in recorded — awaiting admin approval."
                : "Punched in successfully!",
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: isLate ? Colors.orange : Colors.green,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(15),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
      );
      await _refreshStatus();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Punch failed: $e'),
          backgroundColor: AppTheme.maraRed,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(15),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isPunching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final timeText =
        '${hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} ${now.hour < 12 ? 'AM' : 'PM'}';
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
    final dateText =
        '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}';

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ShaderMask(
                shaderCallback: (bounds) =>
                    AppTheme.accentGradient.createShader(bounds),
                child: Text(
                  timeText,
                  style: const TextStyle(
                    fontSize: 50,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                dateText,
                style: const TextStyle(
                  fontSize: 16,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 40),
              _buildLocationCard(),
              const SizedBox(height: 50),
              _buildPunchButton(),
              const SizedBox(height: 20),
              _buildPunchOutButton(),
              const SizedBox(height: 20),
              _buildStatusBanner(),
            ],
          ),
        ),
      ),
    );
  }

  // --- LOCATION STATUS CARD ---
  Widget _buildLocationCard() {
    if (_isCheckingLocation) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: AppTheme.glassCard(),
        child: const Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.navy,
              ),
            ),
            SizedBox(width: 15),
            Text(
              'Getting GPS lock...',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    final result = _geofenceResult;
    final hasError = result?.error != null;
    final isInside = result?.isInside ?? false;
    final zoneName = result?.zoneName ?? 'TVET MARA zone';
    final distance = result?.distanceMeters ?? double.infinity;

    final Color statusColor;
    final String statusText;
    final IconData statusIcon;

    if (hasError) {
      statusColor = AppTheme.maraRed;
      statusText = result!.error!;
      statusIcon = Icons.error_outline;
    } else if (isInside) {
      statusColor = Colors.green;
      statusText = 'Inside $zoneName';
      statusIcon = Icons.location_on;
    } else {
      statusColor = Colors.orange;
      statusText = 'Outside zone';
      statusIcon = Icons.location_searching;
    }

    // Build the distance meter bar
    Widget? distanceMeter;
    if (!hasError && distance != double.infinity) {
      // Show how far you are from the zone edge (not the center).
      // Prefer the zone containing the position; when outside all zones,
      // measure against the nearest zone so the meter stays meaningful.
      final meterZone = result?.matchedZone ?? result?.nearestZone;
      final radiusM = (meterZone?['radius_m'] as num?)?.toInt() ?? 200;
      final distFromEdge = (distance - radiusM).clamp(0, 1000).toDouble();
      final progress = isInside
          ? 1.0
          : (1.0 - (distFromEdge / 500)).clamp(0.05, 0.99);
      final distLabel = isInside
          ? '✓ Inside zone'
          : '${distFromEdge.round()}m to zone edge';

      distanceMeter = Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFEAEDF5),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isInside ? Colors.green : Colors.orange,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  distLabel,
                  style: TextStyle(
                    color: isInside ? Colors.green : Colors.orange,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!isInside)
                  const Text(
                    'Move closer to punch in',
                    style: TextStyle(color: AppTheme.textFaint, fontSize: 11),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppTheme.glassCard(glow: statusColor, glowOpacity: 0.14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 40),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Location Status",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    Text(statusText, style: TextStyle(color: statusColor)),
                  ],
                ),
              ),
              if (!hasError)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: Icon(Icons.my_location, color: Colors.green, size: 14),
                ),
            ],
          ),
          ?distanceMeter,
          if (!hasError &&
              result?.accuracyMeters != null &&
              result!.accuracyMeters! > 50)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 13, color: Colors.amber),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'GPS accuracy ±${result.accuracyMeters!.round()}m — '
                      'move near a window or wait for a better fix.',
                      style: TextStyle(color: AppTheme.textFaint, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          if (hasError)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Enable location in Settings → Privacy → Location, then reopen this page.',
                style: TextStyle(color: AppTheme.textFaint, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPunchButton() {
    if (_loadingStatus) {
      return const SizedBox(
        height: 150,
        width: 150,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final status = _statusKey;
    final hasPunched = status != 'none';
    final isLate =
        status == 'late-pending' ||
        status == 'late-review' ||
        status == 'late-approved';
    final canPunch = !hasPunched && _isInsideZone && !_isCheckingLocation;

    // Button colors:
    //  - Not punched + INSIDE zone → green (ready to punch)
    //  - Not punched + OUTSIDE zone → grey (disabled, can't punch)
    //  - Punched + late → red
    //  - Punched + on-time → navy blue
    final List<Color> gradientColors;
    final Color shadowColor;

    if (hasPunched && isLate) {
      gradientColors = [AppTheme.maraRed, AppTheme.maraRedDeep];
      shadowColor = AppTheme.maraRed;
    } else if (hasPunched) {
      gradientColors = const [Color(0xFF002060), Color(0xFF0040A0)];
      shadowColor = Colors.blue;
    } else if (canPunch) {
      // Inside zone — green light!
      gradientColors = [Colors.green[700]!, Colors.green[500]!];
      shadowColor = Colors.green;
    } else {
      // Outside zone — greyed out
      gradientColors = [Colors.grey[500]!, Colors.grey[400]!];
      shadowColor = Colors.grey;
    }

    return GestureDetector(
      onTap: (_isPunching || !canPunch) ? null : _handlePunchIn,
      child: Container(
        height: 150,
        width: 150,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: gradientColors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: canPunch ? Border.all(color: AppTheme.gold, width: 3) : null,
          boxShadow: [
            BoxShadow(
              color: shadowColor.withValues(alpha: 0.4),
              blurRadius: 20,
              spreadRadius: 5,
            ),
            if (canPunch)
              BoxShadow(
                color: AppTheme.gold.withValues(alpha: 0.35),
                blurRadius: 18,
                spreadRadius: 1,
              ),
          ],
        ),
        child: _isPunching
            ? const CircularProgressIndicator(color: Colors.white)
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    hasPunched
                        ? Icons.check_circle
                        : (canPunch ? Icons.touch_app : Icons.location_off),
                    color: Colors.white,
                    size: 50,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    hasPunched
                        ? (isLate ? "PUNCHED IN\n(LATE)" : "PUNCHED IN")
                        : (canPunch ? "PUNCH IN" : "OUTSIDE\nZONE"),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // --- PUNCH OUT BUTTON ---
  // Only shows after the user has punched in (and hasn't punched out yet).
  Widget _buildPunchOutButton() {
    if (_loadingStatus) return const SizedBox.shrink();

    final status = _statusKey;
    final alreadyOut = status == 'done';
    // Only show PUNCH OUT after the punch-in is approved:
    //   - 'on-time' (auto-approved) ✓
    //   - 'late-approved' (admin approved) ✓
    //   - 'late-pending' / 'late-review' ✗ (not yet approved as present)
    final canPunchOut = status == 'on-time' || status == 'late-approved';

    if (alreadyOut) {
      // Show the completed-state chip instead of a button
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt, color: Colors.green, size: 20),
            SizedBox(width: 8),
            Text(
              'Day completed — punched out',
              style: TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    if (!canPunchOut) return const SizedBox.shrink();

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppTheme.criticalGradient,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [
            BoxShadow(
              color: AppTheme.maraRed.withValues(alpha: 0.35),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ElevatedButton.icon(
          onPressed: _isPunching ? null : _handlePunchOut,
          icon: _isPunching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.logout),
          label: Text(
            _isPunching ? 'Punching out...' : 'PUNCH OUT',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            elevation: 0,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    if (_loadingStatus) {
      return const SizedBox.shrink();
    }
    if (_error != null) {
      return Text(
        'Error: $_error',
        style: const TextStyle(color: AppTheme.maraRed, fontSize: 12),
      );
    }

    final (label, color) = switch (_statusKey) {
      'none' => ('You have not punched in yet', Colors.grey),
      'on-time' => (
        'Punched in (on time) — remember to punch out',
        Colors.green,
      ),
      'late-pending' => ('Late — please submit a reason', Colors.orange),
      'late-review' => (
        'Late reason submitted — awaiting admin approval',
        Colors.orange,
      ),
      'late-approved' => (
        'Late reason approved — remember to punch out',
        Colors.green,
      ),
      'done' => ('Day completed', Colors.green),
      _ => ('', Colors.grey),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusKey == 'late-review' || _statusKey == 'late-pending'
                  ? '$label. Reason: ${_lateRemark ?? "--"}'
                  : label,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// --- LATE PUNCH-IN REMARKS DIALOG ---
// Shown automatically when a staff member punches in after the cutoff time.
// Requires acknowledging the checkbox before it can be submitted — the
// resulting remark is saved as a read-only part of the attendance record,
// so no separate lateness appeal is needed afterward.
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
        style: TextStyle(color: Color(0xFF002060), fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "You're punching in after 8:00 AM. Please select a reason before continuing.",
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
                        activeColor: const Color(0xFF002060),
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
              activeColor: const Color(0xFF002060),
              dense: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context), // returns null -> punch-in cancelled
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: _canSubmit ? _submit : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF002060),
          ),
          child: const Text("Confirm", style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

// --- BOUNCING ANIMATION HELPER ---
class BouncingWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const BouncingWidget({super.key, required this.child, required this.onTap});

  @override
  State<BouncingWidget> createState() => _BouncingWidgetState();
}

class _BouncingWidgetState extends State<BouncingWidget>
    with SingleTickerProviderStateMixin {
  late double _scale;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 100),
          lowerBound: 0.0,
          upperBound: 0.15,
        )..addListener(() {
          setState(() {});
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scale = 1 - _controller.value;
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: Transform.scale(scale: _scale, child: widget.child),
    );
  }
}
