import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';

class StaffProfileScreen extends StatefulWidget {
  /// When false, the screen renders its body without an AppBar so it can be
  /// embedded as a tab inside the staff dashboard's bottom-nav shell.
  final bool showAppBar;

  const StaffProfileScreen({super.key, this.showAppBar = true});

  @override
  State<StaffProfileScreen> createState() => _StaffProfileScreenState();
}

class _StaffProfileScreenState extends State<StaffProfileScreen> {
  // --- Profile data (live from Supabase) ---
  Map<String, dynamic>? _profile;
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
      final yearStart = DateTime(DateTime.now().year, 1, 1);
      final results = await Future.wait([
        AuthService.getCurrentProfile(),
        DatabaseService.getMySemesterStats(since: yearStart),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0];
        _stats = Map<String, int>.from(results[1] as Map<dynamic, dynamic>);
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
  String get _position => (_profile?['position'] as String?) ?? '—';

  String get _staffGrade => (_profile?['staff_grade'] as String?) ?? '—';
  String get _status => (_profile?['employment_status'] as String?) ?? '—';

  String get _semesterLabel {
    final now = DateTime.now();
    final half = now.month <= 6 ? 1 : 2;
    return 'Sem $half / ${now.year}';
  }

  int get _sessionsAttended => _stats['present']! + _stats['late']!;
  int get _sessionsTotal =>
      _sessionsAttended + _stats['absent']! + _stats['leave']!;
  int get _totalPresentPercent {
    if (_sessionsTotal == 0) return 0;
    return ((_stats['present']! + _stats['late']!) / _sessionsTotal * 100)
        .round();
  }

  int get _mcTaken => _stats['leave']!;
  int get _appealsApproved {
    // Approximation: count of late entries treated as approved appeals
    return _stats['late']!;
  }

  String get _reportDateRange {
    final now = DateTime.now();
    final start = DateTime(now.year, 1, 1);
    final mid = DateTime(now.year, 6, 30);
    final end = now.isBefore(mid) ? mid : DateTime(now.year, 12, 31);
    final months = [
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
    return '${months[start.month - 1]} – ${months[end.month - 1]} ${now.year}';
  }

  String get _initials {
    final parts = _staffName.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBottom,
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text(
                "Staff Profile",
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
                    onPressed: _loadProfileData,
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
                  _buildProfileHeader(),
                  const SizedBox(height: 20),
                  _buildEmploymentDetailsCard(),
                  const SizedBox(height: 20),
                  _buildSemesterOverviewCard(),
                  const SizedBox(height: 20),
                  _ReportDownloadCard(dateRange: _reportDateRange),
                ],
              ),
            ),
    );
  }

  // --- HEADER ---
  Widget _buildProfileHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF002060), Color(0xFF0040A0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Stack(
            children: [
              Container(
                width: 70,
                height: 70,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.goldLight, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.gold.withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Text(
                  _initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_isActive)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.greenAccent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF002060),
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _staffName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.badge_outlined,
                        color: Colors.white70,
                        size: 13,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Nombor Gaji: $_staffId',
                        style: const TextStyle(
                          // A generic monospace fallback — add the
                          // google_fonts package + GoogleFonts.jetBrainsMono()
                          // if you want the exact font from the mockup.
                          fontFamily: 'monospace',
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _department,
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- EMPLOYMENT DETAILS CARD ---
  Widget _buildEmploymentDetailsCard() {
    return _sectionCard(
      title: "EMPLOYMENT DETAILS",
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _detailItem("JAWATAN", _position)),
              Expanded(child: _detailItem("GRED GAJI", _staffGrade)),
            ],
          ),
          const SizedBox(height: 18),
          Row(children: [Expanded(child: _detailItem("STATUS", _status))]),
        ],
      ),
    );
  }

  Widget _detailItem(String label, String value) {
    return Column(
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
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }

  // --- SEMESTER OVERVIEW CARD ---
  Widget _buildSemesterOverviewCard() {
    return _sectionCard(
      title: "SEMESTER OVERVIEW",
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF002060).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFF002060).withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          _semesterLabel,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF002060),
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _statColumn(
                  "$_totalPresentPercent%",
                  "TOTAL PRESENT",
                  Colors.green,
                ),
              ),
              Expanded(
                child: _statColumn("$_mcTaken", "MC TAKEN", Colors.orange),
              ),
              Expanded(
                child: _statColumn(
                  "$_appealsApproved",
                  "APPEALS APPROVED",
                  Colors.blue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Attendance Rate",
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              Text(
                "$_sessionsAttended / $_sessionsTotal sessions",
                style: const TextStyle(
                  color: Colors.green,
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
              value: _sessionsAttended / _sessionsTotal,
              minHeight: 8,
              backgroundColor: Colors.grey[200],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statColumn(String value, String label, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey[500],
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  // --- Shared card wrapper (matches the white rounded-card style used
  // across your Admin/Staff dashboards) ---
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
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 5, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: const Color(0xFF002060),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                      letterSpacing: 0.5,
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

// --- REPORT DOWNLOAD CARD (with its own animated button state) ---
class _ReportDownloadCard extends StatefulWidget {
  final String dateRange;
  const _ReportDownloadCard({required this.dateRange});

  @override
  State<_ReportDownloadCard> createState() => _ReportDownloadCardState();
}

class _ReportDownloadCardState extends State<_ReportDownloadCard> {
  bool _isPreparing = false;
  bool _isDone = false;

  Future<void> _handleDownload() async {
    if (_isPreparing) return;
    setState(() => _isPreparing = true);

    // TODO: replace with your real report generation/download call
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    setState(() {
      _isPreparing = false;
      _isDone = true;
    });

    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _isDone = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 5, offset: Offset(0, 3)),
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
                  gradient: const LinearGradient(
                    colors: [Color(0xFF002060), Color(0xFF0040A0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
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
                      "Semester Performance Report",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      "Full attendance, MC, and appeals breakdown for the last 6 months.",
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
              const _MetaChip("PDF Format"),
              _MetaChip(widget.dateRange),
              const _MetaChip("Verified"),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _handleDownload,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isDone
                    ? Colors.green
                    : (_isPreparing
                          ? Colors.green[700]
                          : const Color(0xFF002060)),
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
                          "Preparing Download...",
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
                          "Downloaded",
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
                        Text(
                          "Download 6-Month PDF Report",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
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
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: Colors.grey[700],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
