import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/reports/attendance_report_pdf_service.dart';
import '../../services/presence_service.dart';
import '../../models/attendance_report.dart';
import '../../theme/app_theme.dart';
import '../auth/login_page.dart';

class StaffProfileScreen extends StatefulWidget {
  const StaffProfileScreen({super.key});

  @override
  State<StaffProfileScreen> createState() => _StaffProfileScreenState();
}

class _StaffProfileScreenState extends State<StaffProfileScreen> {
  // --- Profile data (live from Supabase) ---
  Map<String, dynamic>? _profile;
  StaffAttendanceReport? _report;
  Map<String, int> _stats = {'present': 0, 'late': 0, 'absent': 0, 'leave': 0};
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final profile = await AuthService.getCurrentProfile();
      if (profile == null) throw Exception('Staff profile not found.');
      final period = ReportPeriod.recent().first;
      final report = await DatabaseService.getStaffReport(
        staffId: profile['id'] as String,
        start: period.start,
        end: period.end,
      );
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _report = report;
        _stats = {
          'present': report.present,
          'late': report.late,
          'absent': report.absent,
          'leave': report.approvedLeave,
        };
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
  String get _staffId => (_profile?['staff_number'] as String?) ?? '—';
  String get _department =>
      (_profile?['departments']?['name'] as String?) ?? '—';
  bool get _isActive => (_profile?['is_active'] as bool?) ?? false;
  String get _baseSalary {
    final s = _profile?['base_salary'];
    final salary = s is num ? s : num.tryParse(s?.toString() ?? '');
    return salary == null ? '—' : 'RM ${salary.toStringAsFixed(0)}';
  }

  String get _teachingCourse =>
      (_profile?['teaching_course'] as String?) ?? '—';
  String get _serviceYears {
    final hire = _profile?['hire_date'];
    if (hire == null) return '—';
    final hireDate = DateTime.tryParse(hire.toString());
    if (hireDate == null) return '—';
    final years = DateTime.now().difference(hireDate).inDays ~/ 365;
    return '$years Years';
  }

  String get _staffGrade => (_profile?['staff_grade'] as String?) ?? '—';
  String get _position => (_profile?['position'] as String?) ?? '—';
  String get _campus => (_profile?['campus'] as String?) ?? '—';
  String get _status => (_profile?['employment_status'] as String?) ?? '—';
  String get _email => AuthService.currentUser?.email ?? '—';

  String get _semesterLabel {
    final period = ReportPeriod.recent().first;
    return 'Sem ${period.start.month == 1 ? 1 : 2} / ${period.start.year}';
  }

  int get _sessionsAttended => _stats['present']! + _stats['late']!;
  int get _sessionsTotal => _report?.attendanceTarget ?? 0;
  int get _totalPresentPercent {
    return _report?.attendanceRate.round() ?? 0;
  }

  int get _mcTaken => _stats['leave']!;
  int get _appealsApproved => _stats['late']!;

  String get _reportDateRange {
    return ReportPeriod.recent().first.label;
  }

  String get _initials {
    final parts = _staffName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '—';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Log out?'),
        content: const Text('You will need to sign in again to check in/out.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.maraRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    PresenceService.stop();
    try {
      await AuthService.signOut();
    } catch (error) {
      PresenceService.start();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not log out: $error')));
      }
      return;
    }
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBottom,
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
                    onPressed: _loadProfileData,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeroHeader(),
                  Transform.translate(
                    offset: const Offset(0, -26),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildContactCard(),
                          const SizedBox(height: 16),
                          _buildEmploymentDetailsCard(),
                          const SizedBox(height: 16),
                          _buildSemesterOverviewCard(),
                          const SizedBox(height: 16),
                          _ReportDownloadCard(
                            report: _report!,
                            dateRange: _reportDateRange,
                          ),
                          const SizedBox(height: 16),
                          _buildLogoutButton(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // --- Sleek hero header: avatar + identity block on deep corporate navy ---
  Widget _buildHeroHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.of(context).padding.top + 20,
        20,
        52,
      ),
      decoration: const BoxDecoration(gradient: AppTheme.heroGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TVET MARA',
            style: TextStyle(
              color: AppTheme.goldLight,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Profile',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Stack(
                children: [
                  Container(
                    width: 68,
                    height: 68,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Text(
                      _initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (_isActive)
                    Positioned(
                      right: 1,
                      bottom: 1,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: AppTheme.success,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _staffName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$_position · $_staffGrade',
                      style: const TextStyle(
                        color: AppTheme.onDarkSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.gold,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _department,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: _isActive
                                      ? AppTheme.success
                                      : AppTheme.textFaint,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _isActive ? 'Active' : 'Inactive',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Contact / identity card overlapping the hero ---
  Widget _buildContactCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEAEDF5)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.08),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'STAFF INFORMATION',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: AppTheme.textFaint,
            ),
          ),
          const SizedBox(height: 14),
          _contactRow(
            icon: Icons.badge_outlined,
            iconBg: AppTheme.navy.withValues(alpha: 0.08),
            iconFg: AppTheme.navy,
            label: 'Staff ID',
            value: _staffId,
          ),
          const Divider(height: 24, color: Color(0xFFEFF1F7)),
          _contactRow(
            icon: Icons.location_on_outlined,
            iconBg: AppTheme.maraBlue.withValues(alpha: 0.10),
            iconFg: AppTheme.maraBlue,
            label: 'Campus',
            value: _campus,
          ),
          const Divider(height: 24, color: Color(0xFFEFF1F7)),
          _contactRow(
            icon: Icons.mail_outline_rounded,
            iconBg: AppTheme.success.withValues(alpha: 0.12),
            iconFg: AppTheme.successDeep,
            label: 'Email',
            value: _email,
          ),
        ],
      ),
    );
  }

  Widget _contactRow({
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: iconBg,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 19, color: iconFg),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textFaint,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- EMPLOYMENT DETAILS CARD ---
  Widget _buildEmploymentDetailsCard() {
    return _sectionCard(
      title: 'EMPLOYMENT DETAILS',
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: _detailItem('JAWATAN', _position),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _detailItem('BASE SALARY', _baseSalary)),
              const SizedBox(width: 12),
              Expanded(child: _detailItem('TEACHING COURSE', _teachingCourse)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _detailItem('SERVICE YEARS', _serviceYears)),
              const SizedBox(width: 12),
              Expanded(child: _detailItem('STAFF GRADE', _staffGrade)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _detailItem('CAMPUS', _campus)),
              const SizedBox(width: 12),
              Expanded(child: _detailItem('STATUS', _status)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detailItem(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEAEDF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
              color: AppTheme.textFaint,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  // --- SEMESTER OVERVIEW CARD ---
  Widget _buildSemesterOverviewCard() {
    return _sectionCard(
      title: 'SEMESTER OVERVIEW',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.navy.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.navy.withValues(alpha: 0.2)),
        ),
        child: Text(
          _semesterLabel,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppTheme.navy,
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _statColumn(
                  '$_totalPresentPercent%',
                  'TOTAL PRESENT',
                  AppTheme.success,
                ),
              ),
              Expanded(
                child: _statColumn(
                  '$_mcTaken',
                  'APPROVED LEAVE',
                  Colors.orange,
                ),
              ),
              Expanded(
                child: _statColumn(
                  '$_appealsApproved',
                  'APPROVED LATE',
                  AppTheme.maraBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              const Text(
                'Attendance Rate',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '$_sessionsAttended / $_sessionsTotal sessions',
                style: const TextStyle(
                  color: AppTheme.success,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: _sessionsTotal == 0
                  ? 0
                  : _sessionsAttended / _sessionsTotal,
              minHeight: 8,
              backgroundColor: const Color(0xFFEDF0F7),
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.success),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statColumn(String value, String label, Color color) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: AppTheme.textFaint,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildLogoutButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton.icon(
        onPressed: _handleLogout,
        icon: const Icon(
          Icons.logout_rounded,
          color: AppTheme.maraRed,
          size: 19,
        ),
        label: const Text(
          'Log out',
          style: TextStyle(
            color: AppTheme.maraRed,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: AppTheme.maraRed.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  // --- Shared card wrapper ---
  Widget _sectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: AppTheme.navy,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

// --- REPORT DOWNLOAD CARD: exports the calculated attendance report ---
class _ReportDownloadCard extends StatefulWidget {
  final StaffAttendanceReport report;
  final String dateRange;

  const _ReportDownloadCard({required this.report, required this.dateRange});

  @override
  State<_ReportDownloadCard> createState() => _ReportDownloadCardState();
}

class _ReportDownloadCardState extends State<_ReportDownloadCard> {
  bool _isPreparing = false;
  bool _isDone = false;

  Future<void> _handleDownload() async {
    if (_isPreparing) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isPreparing = true);

    try {
      final delivered = await AttendanceReportPdfService.share(
        reports: [widget.report],
        periodLabel: widget.dateRange,
      );
      if (!delivered) {
        if (mounted) setState(() => _isPreparing = false);
        return;
      }

      if (!mounted) return;
      setState(() {
        _isPreparing = false;
        _isDone = true;
      });
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'PDF report sent to your device.',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            backgroundColor: AppTheme.successDeep,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 3),
          ),
        );

      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      setState(() => _isDone = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPreparing = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Could not download the PDF report: $e',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: AppTheme.maraRed,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.navy,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.description_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Semester Performance Report',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Attendance, approved leave and pending late approvals for this semester.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              const _MetaChip('PDF Format'),
              _MetaChip(widget.dateRange),
              const _MetaChip('Live records'),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isPreparing ? null : _handleDownload,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isDone
                    ? AppTheme.success
                    : (_isPreparing ? AppTheme.successDeep : AppTheme.navy),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isPreparing
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Preparing Download...',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    )
                  : _isDone
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_outline, color: Colors.white),
                        SizedBox(width: 8),
                        Text(
                          'Downloaded',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.download, color: Colors.white),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Download PDF Report',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  const _MetaChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4FA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.navy,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
