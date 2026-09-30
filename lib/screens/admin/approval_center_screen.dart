import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin_ui.dart';
import '../../navigation/app_page_route.dart';

// Place this file in lib/admin/approval_center_screen.dart to match your
// existing folder structure (auth/, staff/, admin/).

enum SubmissionType { lateAppeal, mcUpload, latePunch }

enum ApprovalSource { attendanceAppeal, leave, latePunch }

class ApprovalSubmission {
  final String id; // Supabase row id
  final ApprovalSource source; // which table this came from
  final String name;
  final Color avatarColor;
  final String role;
  final String department;
  final String timeLabel; // e.g. "Today, 9:14 AM"
  final SubmissionType type;
  final String date; // e.g. "24 Jul 2026"
  final String? punchIn; // e.g. "08:22 AM (expected 08:00 AM)"
  final String? variance; // e.g. "+22 min late"
  final String reason;
  final bool hasAttachment;

  const ApprovalSubmission({
    required this.id,
    required this.source,
    required this.name,
    required this.avatarColor,
    required this.role,
    required this.department,
    required this.timeLabel,
    required this.type,
    required this.date,
    this.punchIn,
    this.variance,
    required this.reason,
    required this.hasAttachment,
  });

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  String get typeLabel {
    switch (type) {
      case SubmissionType.lateAppeal:
        return "Late Appeal";
      case SubmissionType.mcUpload:
        return "MC Upload";
      case SubmissionType.latePunch:
        return "Late Punch-in";
    }
  }

  Color get typeColor {
    switch (type) {
      case SubmissionType.lateAppeal:
        return Colors.orange;
      case SubmissionType.mcUpload:
        return Colors.blue;
      case SubmissionType.latePunch:
        return Colors.deepOrange;
    }
  }
}

class ApprovalCenterScreen extends StatefulWidget {
  const ApprovalCenterScreen({super.key});

  @override
  State<ApprovalCenterScreen> createState() => _ApprovalCenterScreenState();
}

class _ApprovalCenterScreenState extends State<ApprovalCenterScreen> {
  List<ApprovalSubmission> _submissions = [];
  bool _isLoading = true;
  String? _loadError;

  // Avatar color palette — cycled per submission to keep the UI colorful
  static const _palette = [AdminUi.navy, AdminUi.success, Color(0xFF637799)];

  @override
  void initState() {
    super.initState();
    _loadSubmissions();
  }

  Future<void> _loadSubmissions() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        DatabaseService.getPendingAttendanceAppeals(),
        DatabaseService.getPendingLeaves(),
        DatabaseService.getPendingLateApprovals(),
      ]);
      final appeals = results[0];
      final leaves = results[1];
      final latePunches = results[2];

      final List<ApprovalSubmission> subs = [];
      int colorIdx = 0;

      // Late punch-ins awaiting approval → latePunch
      for (final row in latePunches) {
        final staff = row['staff'] as Map<String, dynamic>?;
        final name = (staff?['full_name'] as String?) ?? 'Unknown';
        final role = (staff?['role'] as String?) ?? 'staff';
        final dept = (staff?['departments']?['name'] as String?) ?? '—';
        final punchInStr = row['punch_in'] as String?;
        final punchIn = punchInStr != null
            ? DateTime.tryParse(punchInStr)?.toLocal()
            : null;
        final reason = (row['late_reason'] as String?) ?? '';
        subs.add(
          ApprovalSubmission(
            id: row['id'] as String,
            source: ApprovalSource.latePunch,
            name: name,
            avatarColor: _palette[colorIdx++ % _palette.length],
            role: role,
            department: dept,
            timeLabel: punchIn != null ? _formatRelative(punchIn) : '',
            type: SubmissionType.latePunch,
            date: punchIn != null ? _formatDate(punchIn) : '',
            punchIn: punchIn != null
                ? "${_formatTime(punchIn)} (expected 08:00 AM)"
                : null,
            variance: punchIn != null
                ? "+${punchIn.difference(DateTime(punchIn.year, punchIn.month, punchIn.day, 8, 0)).inMinutes} min late"
                : null,
            reason: reason,
            hasAttachment: false,
          ),
        );
      }

      // Attendance appeals → lateAppeal
      for (final row in appeals) {
        final staff = row['staff'] as Map<String, dynamic>?;
        final name = (staff?['full_name'] as String?) ?? 'Unknown';
        final role = (staff?['role'] as String?) ?? 'staff';
        final dept = (staff?['departments']?['name'] as String?) ?? '—';
        final punchInStr = row['punch_in'] as String?;
        final punchIn = punchInStr != null
            ? DateTime.tryParse(punchInStr)
            : null;
        final reason =
            (row['appeal_reason'] as String?) ??
            (row['notes'] as String?) ??
            '';
        subs.add(
          ApprovalSubmission(
            id: row['id'] as String,
            source: ApprovalSource.attendanceAppeal,
            name: name,
            avatarColor: _palette[colorIdx++ % _palette.length],
            role: role,
            department: dept,
            timeLabel: punchIn != null ? _formatRelative(punchIn) : '',
            type: SubmissionType.lateAppeal,
            date: punchIn != null ? _formatDate(punchIn) : '',
            punchIn: punchIn != null
                ? "${_formatTime(punchIn)} (expected 08:00 AM)"
                : null,
            variance: punchIn != null
                ? "+${punchIn.difference(DateTime(punchIn.year, punchIn.month, punchIn.day, 8, 0)).inMinutes} min late"
                : null,
            reason: reason,
            hasAttachment: false,
          ),
        );
      }

      // Leaves → mcUpload if sick/emergency, else lateAppeal placeholder
      for (final row in leaves) {
        final staff = row['staff'] as Map<String, dynamic>?;
        final name = (staff?['full_name'] as String?) ?? 'Unknown';
        final role = (staff?['role'] as String?) ?? 'staff';
        final dept = (staff?['departments']?['name'] as String?) ?? '—';
        final createdStr = row['created_at'] as String?;
        final created = createdStr != null
            ? DateTime.tryParse(createdStr)
            : null;
        final leaveType = row['leave_type'] as String? ?? 'sick';
        final reason = (row['reason'] as String?) ?? '';
        final startStr = row['start_date'] as String?;
        final start = startStr != null ? DateTime.tryParse(startStr) : null;
        subs.add(
          ApprovalSubmission(
            id: row['id'] as String,
            source: ApprovalSource.leave,
            name: name,
            avatarColor: _palette[colorIdx++ % _palette.length],
            role: role,
            department: dept,
            timeLabel: created != null ? _formatRelative(created) : '',
            type: (leaveType == 'sick' || leaveType == 'emergency')
                ? SubmissionType.mcUpload
                : SubmissionType.lateAppeal,
            date: start != null ? _formatDate(start) : '',
            reason: reason,
            hasAttachment: false,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _submissions = subs;
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

  String _formatDate(DateTime dt) {
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
    return "${dt.day} ${months[dt.month - 1]} ${dt.year}";
  }

  String _formatRelative(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return "Today, ${_formatTime(dt)}";
    if (diff.inDays == 1) return "Yesterday, ${_formatTime(dt)}";
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return "${days[dt.weekday - 1]}, ${_formatTime(dt)}";
    }
    return _formatDate(dt);
  }

  int _selectedTab = 0; // 0 = All, 1 = Lateness, 2 = MC, 3 = Late Punches
  String _searchQuery = "";

  List<ApprovalSubmission> get _filtered {
    return _submissions.where((s) {
      final matchesTab =
          _selectedTab == 0 ||
          (_selectedTab == 1 && s.type == SubmissionType.lateAppeal) ||
          (_selectedTab == 2 && s.type == SubmissionType.mcUpload) ||
          (_selectedTab == 3 && s.type == SubmissionType.latePunch);
      final matchesSearch =
          _searchQuery.isEmpty ||
          s.name.toLowerCase().contains(_searchQuery.toLowerCase());
      return matchesTab && matchesSearch;
    }).toList();
  }

  int get _lateCount =>
      _submissions.where((s) => s.type == SubmissionType.lateAppeal).length;
  int get _mcCount =>
      _submissions.where((s) => s.type == SubmissionType.mcUpload).length;
  int get _latePunchCount =>
      _submissions.where((s) => s.type == SubmissionType.latePunch).length;

  Future<void> _openDetail(ApprovalSubmission submission) async {
    final result = await Navigator.push<String>(
      context,
      appPageRoute(_ApprovalDetailScreen(submission: submission)),
    );

    if (result == null || !mounted) return;

    setState(() {
      _submissions.remove(submission);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == "approved"
              ? "${submission.name}'s submission approved and record updated."
              : "${submission.name}'s submission denied.",
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: result == "approved" ? Colors.green : AppTheme.maraRed,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Approval inbox',
      subtitle: 'Review requests, resolve appeals and keep your team moving.',
      action: OutlinedButton.icon(
        onPressed: _loadSubmissions,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Refresh inbox'),
      ),
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
                    onPressed: _loadSubmissions,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Staff appeals & medical leave",
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF002060).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          "${_submissions.length} pending",
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF002060),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: TextField(
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      hintText: "Search staff...",
                      prefixIcon: const Icon(Icons.search, size: 20),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _filterTab("All", _submissions.length, 0),
                        const SizedBox(width: 20),
                        _filterTab("Lateness Appeals", _lateCount, 1),
                        const SizedBox(width: 20),
                        _filterTab("Medical Leave (MC)", _mcCount, 2),
                        const SizedBox(width: 20),
                        _filterTab("Late Punches", _latePunchCount, 3),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                Expanded(
                  child: _filtered.isEmpty
                      ? const AdminEmptyState(
                          icon: Icons.task_alt_rounded,
                          title: 'You’re all caught up',
                          message:
                              'No pending submissions match your current filters.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(20),
                          itemCount: _filtered.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) =>
                              _submissionCard(_filtered[index]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _filterTab(String label, int count, int index) {
    final isActive = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: isActive ? const Color(0xFF002060) : Colors.grey[600],
                ),
              ),
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF002060).withValues(alpha: 0.1)
                      : Colors.grey[200],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  "$count",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isActive
                        ? const Color(0xFF002060)
                        : Colors.grey[600],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 2,
            width: 30,
            color: isActive ? const Color(0xFF002060) : Colors.transparent,
          ),
        ],
      ),
    );
  }

  Widget _submissionCard(ApprovalSubmission submission) {
    return InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: () => _openDetail(submission),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: AdminUi.panel(),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: submission.avatarColor.withValues(alpha: 0.15),
              child: Text(
                submission.initials,
                style: TextStyle(
                  color: submission.avatarColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    submission.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: submission.typeColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        submission.typeLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: submission.typeColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "· ${submission.department}",
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(
              submission.timeLabel,
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }
}

// --- DETAIL / REVIEW SCREEN ---
class _ApprovalDetailScreen extends StatelessWidget {
  final ApprovalSubmission submission;
  const _ApprovalDetailScreen({required this.submission});

  Future<void> _confirmDecision(BuildContext context, bool approve) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text(approve ? "Approve submission?" : "Deny submission?"),
        content: Text(
          "This will update ${submission.name}'s record and notify them. This action is logged and cannot be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: approve ? Colors.green : AppTheme.maraRed,
            ),
            child: Text(
              approve ? "Approve" : "Deny",
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Call the real Supabase update based on the source
    try {
      if (submission.source == ApprovalSource.latePunch) {
        if (approve) {
          await DatabaseService.approveLate(submission.id);
        } else {
          await DatabaseService.rejectLate(submission.id);
        }
      } else if (submission.source == ApprovalSource.attendanceAppeal) {
        if (approve) {
          await DatabaseService.approveAttendanceAppeal(
            submission.id,
            'Approved by admin',
          );
        } else {
          await DatabaseService.rejectAttendanceAppeal(
            submission.id,
            'Rejected by admin',
          );
        }
      } else {
        if (approve) {
          await DatabaseService.approveLeave(
            submission.id,
            'Approved by admin',
          );
        } else {
          await DatabaseService.rejectLeave(submission.id, 'Rejected by admin');
        }
      }
      if (context.mounted) {
        Navigator.pop(context, approve ? "approved" : "denied");
      }
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $e'),
            backgroundColor: AppTheme.maraRed,
          ),
        );
      }
    }
  }

  void _openAttachmentPreview(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              height: 400,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
              ),
              // TODO: replace with a real Image.network(certificateUrl) once
              // the MC upload is backed by real file storage.
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.description, size: 60, color: Colors.grey),
                    SizedBox(height: 12),
                    Text(
                      "MC Certificate Preview",
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLate = submission.type != SubmissionType.mcUpload;

    return AdminPage(
      title: 'Review submission',
      subtitle: 'Review the details below before making your decision.',
      maxWidth: 900,
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Staff header
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: submission.avatarColor.withValues(
                          alpha: 0.15,
                        ),
                        child: Text(
                          submission.initials,
                          style: TextStyle(
                            color: submission.avatarColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              submission.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                            Text(
                              "${submission.role} · ${submission.department}",
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: submission.typeColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          submission.typeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: submission.typeColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          submission.timeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Info rows
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: AdminUi.panel(),
                    child: Column(
                      children: [
                        _infoRow("DATE", submission.date),
                        const Divider(),
                        _infoRow("DEPARTMENT", submission.department),
                        if (isLate) ...[
                          const Divider(),
                          _infoRow("PUNCH IN", submission.punchIn ?? "--"),
                          const Divider(),
                          _infoRow(
                            "VARIANCE",
                            submission.variance ?? "--",
                            valueColor: Colors.orange,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  Text(
                    "REASON PROVIDED",
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: AdminUi.panel(),
                    child: Text(
                      submission.reason,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 20),

                  Text(
                    "ATTACHMENTS",
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  submission.hasAttachment
                      ? GestureDetector(
                          onTap: () => _openAttachmentPreview(context),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(15),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black12,
                                  blurRadius: 5,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.description,
                                    color: Colors.blue,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text(
                                    "MC Certificate",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: Colors.grey[400],
                                ),
                              ],
                            ),
                          ),
                        )
                      : Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: Colors.grey[300]!,
                              width: 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.insert_drive_file_outlined,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                "No attachment provided",
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "No supporting document was included with this submission.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                  const SizedBox(height: 20),

                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.amber.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.amber,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            "Approving or denying this submission will update the attendance record and notify the staff member and their reporting manager via email. This action is logged and cannot be undone.",
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),

          // Bottom action bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Reviewing: ${submission.name} · ${submission.typeLabel}",
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _confirmDecision(context, false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.maraRed,
                            side: const BorderSide(color: AppTheme.maraRed),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            "Decline",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: () => _confirmDecision(context, true),
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text("Approve request"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AdminUi.navy,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[500],
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: valueColor ?? Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
