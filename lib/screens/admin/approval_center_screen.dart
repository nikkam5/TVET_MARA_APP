import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/shared/slide_over.dart';
import '../../utils/malaysia_time.dart';

// ─────────────────────────────────────────────────────────────────────
// Design tokens — mirrored from the admin dashboard shell so the
// approval centre reads as one more panel of the same application.
// ─────────────────────────────────────────────────────────────────────
const Color _canvas = Color(0xFFF4F6FB);
const Color _hairline = Color(0xFFE2E8F0);
const Color _surfaceMuted = Color(0xFFF8FAFC);
const Color _ink = Color(0xFF0F172A);
const Color _muted = Color(0xFF64748B);
const Color _navy = Color(0xFF002060);
const Color _amber = Color(0xFFD97706);

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

enum SubmissionType { leaveRequest, lateAppeal, mcUpload, latePunch }

enum ApprovalSource { attendanceAppeal, leave, latePunch }

enum ApprovalStatus { pending, approved, rejected }

class ApprovalSubmission {
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
    this.attachmentUrl,
    this.status = ApprovalStatus.pending,
  });

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
  final String? attachmentUrl;

  /// Decision state — flips the card's badge, then the card leaves the
  /// pending queue.
  final ApprovalStatus status;

  ApprovalSubmission copyWith({ApprovalStatus? status}) => ApprovalSubmission(
    id: id,
    source: source,
    name: name,
    avatarColor: avatarColor,
    role: role,
    department: department,
    timeLabel: timeLabel,
    type: type,
    date: date,
    punchIn: punchIn,
    variance: variance,
    reason: reason,
    hasAttachment: hasAttachment,
    attachmentUrl: attachmentUrl,
    status: status ?? this.status,
  );

  bool get isPending => status == ApprovalStatus.pending;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  String get typeLabel {
    switch (type) {
      case SubmissionType.leaveRequest:
        return 'Leave Request';
      case SubmissionType.lateAppeal:
        return 'Lateness Appeal';
      case SubmissionType.mcUpload:
        return 'Medical (MC)';
      case SubmissionType.latePunch:
        return 'Late Punch-in';
    }
  }

  Color get typeColor {
    switch (type) {
      case SubmissionType.leaveRequest:
        return const Color(0xFF0E7490);
      case SubmissionType.lateAppeal:
        return _amber;
      case SubmissionType.mcUpload:
        return AppTheme.maraBlue;
      case SubmissionType.latePunch:
        return AppTheme.maraRed;
    }
  }
}

/// Approval Center — **in-shell** page.
///
/// Renders inside the admin dashboard (sticky rail + top navbar) instead
/// of pushing a full-screen route, so the navigation chrome never
/// disappears while an admin works through the queue. The review screen
/// itself is a slide-over for the same reason.
class ApprovalCenterScreen extends StatefulWidget {
  const ApprovalCenterScreen({super.key, this.onChanged});

  /// Called after every successful decision so the shell can refresh its
  /// pending-approvals badge.
  final VoidCallback? onChanged;

  @override
  State<ApprovalCenterScreen> createState() => _ApprovalCenterScreenState();
}

class _ApprovalCenterScreenState extends State<ApprovalCenterScreen> {
  List<ApprovalSubmission> _submissions = [];
  bool _isLoading = true;
  String? _loadError;

  /// Realtime subscriptions on the `leaves` and `attendance` tables so the
  /// queue refreshes the moment a staff member files — or another admin
  /// decides — a request. Guarded: with Supabase uninitialised (offline
  /// preview / tests) subscribing throws, and the page simply works
  /// without live push until the next manual refresh.
  StreamSubscription<List<Map<String, dynamic>>>? _leavesSub;
  StreamSubscription<List<Map<String, dynamic>>>? _appealsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _latePunchSub;
  Timer? _refreshTimer;

  /// True while a silent (realtime-triggered) reload is in flight, so
  /// rapid push events never stack overlapping queries.
  bool _silentLoading = false;

  final Set<String> _working = {};
  int _approvedCount = 0;
  int _rejectedCount = 0;

  int _selectedTab = 0;
  String _searchQuery = '';

  static const List<String> _tabLabels = [
    'All',
    'Leave Requests',
    'Lateness Appeals',
    'Medical (MC)',
    'Late Punches',
  ];

  // Avatar color palette — cycled per submission to keep the UI colorful
  static const _palette = [
    AppTheme.maraRed,
    AppTheme.maraBlue,
    Colors.purple,
    Colors.teal,
    _amber,
    Colors.green,
    Colors.pink,
    Colors.indigo,
  ];

  @override
  void initState() {
    super.initState();
    _loadSubmissions();
    _subscribeRealtime();
    // Leaves may not be in the deployed realtime publication yet.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_silentLoading) _loadSubmissions(silent: true);
    });
  }

  @override
  void dispose() {
    _leavesSub?.cancel();
    _appealsSub?.cancel();
    _latePunchSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Listens to the approval tables and silently reloads the queue on
  /// every push event, so Approve / Reject lands in realtime on every
  /// connected device. Never throws: when Supabase isn't initialised the
  /// subscriptions stay null and the page falls back to manual refresh.
  void _subscribeRealtime() {
    try {
      void onEvent(_) {
        if (mounted && !_silentLoading) _loadSubmissions(silent: true);
      }

      void onError(Object _) {}
      _leavesSub = DatabaseService.pendingLeavesStream().listen(
        onEvent,
        onError: onError,
        cancelOnError: false,
      );
      _appealsSub = DatabaseService.pendingAttendanceAppealsStream().listen(
        onEvent,
        onError: onError,
        cancelOnError: false,
      );
      _latePunchSub = DatabaseService.pendingLateApprovalsStream().listen(
        onEvent,
        onError: onError,
        cancelOnError: false,
      );
    } catch (_) {
      _leavesSub = null;
      _appealsSub = null;
      _latePunchSub = null;
    }
  }

  // ── Data ────────────────────────────────────────────────────────────
  /// Loads the whole approval queue live from Supabase — leave requests
  /// and medical certificates from `leaves`, lateness appeals and late
  /// punch-ins from `attendance`. No dummy records are ever mixed in: an
  /// empty queue renders the "everything reviewed" empty state.
  ///
  /// [silent] skips the full-page spinner so realtime push events can
  /// refresh the list without flashing the page.
  Future<void> _loadSubmissions({bool silent = false}) async {
    if (silent) {
      if (_silentLoading) return;
      _silentLoading = true;
    } else {
      setState(() {
        _isLoading = true;
      });
    }
    try {
      final queue = await DatabaseService.getPendingApprovals();
      final leaveRequests = queue.leaveRequests;
      final medical = queue.medicalCertificates;
      final appeals = queue.lateAppeals;
      final latePunches = queue.latePunches;

      final List<ApprovalSubmission> subs = [];
      var colorIdx = 0;

      // Late punch-ins awaiting approval → latePunch
      for (final row in latePunches) {
        final staff = row['staff'] as Map<String, dynamic>?;
        final punchInStr = row['punch_in'] as String?;
        final punchIn = MalaysiaTime.parse(punchInStr);
        subs.add(
          ApprovalSubmission(
            id: row['id'] as String,
            source: ApprovalSource.latePunch,
            name: (staff?['full_name'] as String?) ?? 'Unknown',
            avatarColor: _palette[colorIdx++ % _palette.length],
            role: (staff?['role'] as String?) ?? 'staff',
            department: (staff?['departments']?['name'] as String?) ?? '—',
            timeLabel: punchIn != null ? _formatRelative(punchIn) : '',
            type: SubmissionType.latePunch,
            date: punchIn != null ? _formatDate(punchIn) : '',
            punchIn: punchIn != null
                ? '${_formatTime(punchIn)} (expected 08:00 AM)'
                : null,
            variance: punchIn != null
                ? '+${punchIn.difference(DateTime(punchIn.year, punchIn.month, punchIn.day, 8, 0)).inMinutes} min late'
                : null,
            reason: (row['late_reason'] as String?) ?? '',
            hasAttachment: false,
          ),
        );
      }

      // Attendance appeals → lateAppeal
      for (final row in appeals) {
        final staff = row['staff'] as Map<String, dynamic>?;
        final punchInStr = row['punch_in'] as String?;
        final punchIn = MalaysiaTime.parse(punchInStr);
        subs.add(
          ApprovalSubmission(
            id: row['id'] as String,
            source: ApprovalSource.attendanceAppeal,
            name: (staff?['full_name'] as String?) ?? 'Unknown',
            avatarColor: _palette[colorIdx++ % _palette.length],
            role: (staff?['role'] as String?) ?? 'staff',
            department: (staff?['departments']?['name'] as String?) ?? '—',
            timeLabel: punchIn != null ? _formatRelative(punchIn) : '',
            type: SubmissionType.lateAppeal,
            date: punchIn != null ? _formatDate(punchIn) : '',
            punchIn: punchIn != null
                ? '${_formatTime(punchIn)} (expected 08:00 AM)'
                : null,
            variance: punchIn != null
                ? '+${punchIn.difference(DateTime(punchIn.year, punchIn.month, punchIn.day, 8, 0)).inMinutes} min late'
                : null,
            reason:
                (row['appeal_reason'] as String?) ??
                (row['notes'] as String?) ??
                '',
            hasAttachment: false,
          ),
        );
      }

      // Leave requests (non-medical) and medical certificates, both
      // live from `leaves`. The medical split lives in the data layer
      // (DatabaseService.isMedicalLeaveType); an MC row additionally
      // counts as having an attachment when a file URL was stored with it.
      for (final row in [...leaveRequests, ...medical]) {
        final staff = row['staff'] as Map<String, dynamic>?;
        final createdStr = row['created_at'] as String?;
        final created = MalaysiaTime.parse(createdStr);
        final leaveType = row['leave_type'] as String?;
        final isMedical = DatabaseService.isMedicalLeaveType(leaveType);
        final startStr = row['start_date'] as String?;
        final start = startStr != null ? DateTime.tryParse(startStr) : null;
        subs.add(
          ApprovalSubmission(
            id: row['id'] as String,
            source: ApprovalSource.leave,
            name: (staff?['full_name'] as String?) ?? 'Unknown',
            avatarColor: _palette[colorIdx++ % _palette.length],
            role: (staff?['role'] as String?) ?? 'staff',
            department: (staff?['departments']?['name'] as String?) ?? '—',
            timeLabel: created != null ? _formatRelative(created) : '',
            type: isMedical
                ? SubmissionType.mcUpload
                : SubmissionType.leaveRequest,
            date: start != null ? _formatDate(start) : '',
            reason: (row['reason'] as String?) ?? '',
            hasAttachment: _supportingUrl(row) != null,
            attachmentUrl: _supportingUrl(row),
          ),
        );
      }

      if (!mounted) return;
      _silentLoading = false;
      setState(() {
        _submissions = subs;
        _loadError = null;
        _isLoading = false;
      });
    } catch (error) {
      // Catches SupabaseExceptions *and* the AssertionError thrown when
      // Supabase was never initialised (offline preview / tests). The
      // queue stays live-only: an empty list renders the "everything
      // reviewed" empty state, and the Refresh action retries.
      _silentLoading = false;
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _isLoading = false;
      });
      if (!silent && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _toast('Could not load live approvals — pull to retry.');
        });
      }
    }
  }

  /// True when the leave row carries a stored attachment URL (any of the
  /// known file columns holds a non-empty value).
  static String? _supportingUrl(Map<String, dynamic> row) {
    for (final key in const [
      'attachment_url',
      'mc_url',
      'certificate_url',
      'attachment',
      'mc_attachment',
    ]) {
      final value = row[key] as String?;
      final uri = Uri.tryParse(value ?? '');
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        return uri.toString();
      }
    }
    return RegExp(
      r'Supporting document: (https://[^\s]+)',
    ).firstMatch(row['reason']?.toString() ?? '')?.group(1);
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${hour.toString().padLeft(2, '0')}:$minute $ampm';
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
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  String _formatRelative(DateTime dt) {
    final now = MalaysiaTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today, ${_formatTime(dt)}';
    if (diff.inDays == 1) return 'Yesterday, ${_formatTime(dt)}';
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return '${days[dt.weekday - 1]}, ${_formatTime(dt)}';
    }
    return _formatDate(dt);
  }

  // ── Filtering ───────────────────────────────────────────────────────
  List<ApprovalSubmission> get _filtered {
    return _submissions.where((s) {
      final matchesTab =
          _selectedTab == 0 ||
          (_selectedTab == 1 && s.type == SubmissionType.leaveRequest) ||
          (_selectedTab == 2 && s.type == SubmissionType.lateAppeal) ||
          (_selectedTab == 3 && s.type == SubmissionType.mcUpload) ||
          (_selectedTab == 4 && s.type == SubmissionType.latePunch);
      final query = _searchQuery.trim().toLowerCase();
      final matchesSearch =
          query.isEmpty ||
          s.name.toLowerCase().contains(query) ||
          s.department.toLowerCase().contains(query);
      return matchesTab && matchesSearch;
    }).toList();
  }

  int _countFor(int tabIndex) {
    if (tabIndex == 0) return _submissions.length;
    const types = [
      null,
      SubmissionType.leaveRequest,
      SubmissionType.lateAppeal,
      SubmissionType.mcUpload,
      SubmissionType.latePunch,
    ];
    final type = types[tabIndex];
    return _submissions.where((s) => s.type == type).length;
  }

  // ── Decisions ───────────────────────────────────────────────────────
  Future<void> _decide(
    ApprovalSubmission submission, {
    required bool approve,
    bool skipConfirm = false,
  }) async {
    if (!submission.isPending || _working.contains(submission.id)) return;

    if (!skipConfirm) {
      final confirmed = await _confirmDialog(submission, approve);
      if (confirmed != true || !mounted) return;
    }

    setState(() => _working.add(submission.id));

    try {
      // Every decision writes straight through to Supabase: leaves flip
      // status, attendance appeals flip appeal_status, late punch-ins are
      // approved in place (or the row is removed on reject so staff can
      // re-punch). See DatabaseService for the exact statements.
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

      if (!mounted) return;
      setState(() {
        _working.remove(submission.id);
        _submissions = [
          for (final s in _submissions)
            s.id == submission.id
                ? s.copyWith(
                    status: approve
                        ? ApprovalStatus.approved
                        : ApprovalStatus.rejected,
                  )
                : s,
        ];
        if (approve) {
          _approvedCount++;
        } else {
          _rejectedCount++;
        }
      });

      _toast(
        approve
            ? "${submission.name}'s request approved and the record updated."
            : "${submission.name}'s request rejected.",
        color: approve ? AppTheme.success : AppTheme.maraRed,
      );
      widget.onChanged?.call();

      // Let the new badge land, then retire the card from the queue.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      setState(() {
        _submissions = _submissions
            .where(
              (s) =>
                  s.id != submission.id || s.status == ApprovalStatus.pending,
            )
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _working.remove(submission.id));
      _toast('Could not update the record: $e', color: AppTheme.maraRed);
    }
  }

  Future<bool?> _confirmDialog(ApprovalSubmission submission, bool approve) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(approve ? 'Approve this request?' : 'Reject this request?'),
        content: Text(
          "${submission.name} · ${submission.typeLabel}\n\n"
          '${approve ? 'Approving' : 'Rejecting'} updates the attendance / leave '
          'record. The decision is saved with the reviewer and review time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: approve ? AppTheme.success : AppTheme.maraRed,
              foregroundColor: Colors.white,
            ),
            child: Text(approve ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );
  }

  void _toast(String message, {Color? color}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(color: Colors.white)),
          backgroundColor: color ?? _ink,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
  }

  Future<void> _openDetail(ApprovalSubmission submission) async {
    final result = await showSlideOver<String>(
      context: context,
      title: 'Review Submission',
      subtitle: '${submission.name} · ${submission.typeLabel}',
      width: 520,
      body: (_) => _ReviewPanel(submission: submission),
      footer: Builder(
        builder: (dialogContext) => Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(dialogContext).pop('rejected'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.maraRed,
                  side: const BorderSide(color: AppTheme.maraRed),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
                child: const Text(
                  'Reject',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop('approved'),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Approve & update record'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;
    await _decide(submission, approve: result == 'approved', skipConfirm: true);
  }

  // ── Build ───────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isWide = width >= 760;

        // One scroll view for the whole page — toolbar, banner, KPIs,
        // filters *and* the queue. Splitting the header into a fixed
        // column above an inner list only works when the header fits, and
        // on a 390px phone (4 stacked KPI cards + banner) it does not.
        return Container(
          color: _canvas,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: isWide ? 28 : 16),
            child: RefreshIndicator(
              onRefresh: _loadSubmissions,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 18, bottom: 28),
                children: [
                  _pageHeader(width),
                  if (_loadError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Could not load live approvals: $_loadError. Tap Refresh to retry.',
                        style: const TextStyle(color: AppTheme.maraRed),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _kpiRow(width),
                  const SizedBox(height: 14),
                  _searchField(),
                  const SizedBox(height: 14),
                  _tabsRow(width),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  if (_loadError == null) ..._queueChildren(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pageHeader(double width) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Pending Approvals',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: _ink,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Staff leave requests, lateness appeals and medical certificates '
          'waiting on an admin decision.',
          style: TextStyle(fontSize: 12.5, color: Colors.grey[600]),
        ),
      ],
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_approvedCount > 0)
          _counterChip('$_approvedCount approved', AppTheme.success),
        if (_rejectedCount > 0)
          _counterChip('$_rejectedCount rejected', AppTheme.maraRed),
        OutlinedButton.icon(
          onPressed: _isLoading ? null : _loadSubmissions,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Refresh'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _navy,
            side: const BorderSide(color: _hairline),
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: _navy.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _navy.withValues(alpha: 0.18)),
          ),
          child: Text(
            '${_submissions.length} pending',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: _navy,
            ),
          ),
        ),
      ],
    );

    if (width >= 820) {
      return Row(
        children: [
          Expanded(child: heading),
          const SizedBox(width: 18),
          actions,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [heading, const SizedBox(height: 14), actions],
    );
  }

  Widget _counterChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  // ── KPI cards ───────────────────────────────────────────────────────
  Widget _kpiRow(double width) {
    final cardW = width >= 1140
        ? (width - 3 * 14) / 4
        : width >= 720
        ? (width - 14) / 2
        : width;

    final tiles = [
      (
        'Leave Requests',
        _countFor(1),
        const Color(0xFF0E7490),
        Icons.beach_access_rounded,
      ),
      ('Lateness Appeals', _countFor(2), _amber, Icons.timer_off_rounded),
      (
        'Medical Certificates',
        _countFor(3),
        AppTheme.maraBlue,
        Icons.medical_services_rounded,
      ),
      (
        'Late Punch-ins',
        _countFor(4),
        AppTheme.maraRed,
        Icons.fingerprint_rounded,
      ),
    ];

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        for (final (label, count, color, icon) in tiles)
          SizedBox(
            width: cardW,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: _hairline),
                boxShadow: _shadowSm(),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 18, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // AnimatedSwitcher: the count rolls over the moment
                        // a request is approved or rejected.
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween<double>(
                                    begin: 0.86,
                                    end: 1,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: Text(
                            '$count',
                            key: ValueKey<int>(count),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: _ink,
                              height: 1.1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: _muted,
                            fontWeight: FontWeight.w600,
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
    );
  }

  // ── Tabs ────────────────────────────────────────────────────────────
  Widget _searchField() {
    return TextField(
      onChanged: (value) => setState(() => _searchQuery = value),
      decoration: InputDecoration(
        hintText: 'Search by staff name or department…',
        prefixIcon: const Icon(Icons.search_rounded, size: 19, color: _muted),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close_rounded, size: 18, color: _muted),
                onPressed: () => setState(() => _searchQuery = ''),
              ),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: _hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: _navy, width: 1.4),
        ),
      ),
    );
  }

  Widget _tabsRow(double width) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const AlwaysScrollableScrollPhysics(),
      child: Row(
        children: [
          for (var i = 0; i < _tabLabels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _tabChip(i, width),
          ],
        ],
      ),
    );
  }

  Widget _tabChip(int index, double width) {
    final selected = _selectedTab == index;
    final count = _countFor(index);
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? _navy : Colors.white,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: selected ? _navy : _hairline),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _navy.withValues(alpha: 0.24),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _tabLabels[index],
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? Colors.white : _muted,
              ),
            ),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.18)
                    : _surfaceMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : _muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Queue ───────────────────────────────────────────────────────────
  /// Queue items for the page's scroll view — spinner while loading, a
  /// friendly empty state, otherwise the pending cards separated by a
  /// 12px gap.
  List<Widget> _queueChildren() {
    if (_isLoading) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: 48, bottom: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final items = _filtered;
    if (items.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 44, bottom: 44),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _submissions.isEmpty
                    ? Icons.task_alt_rounded
                    : Icons.search_off_rounded,
                size: 44,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 12),
              Text(
                _submissions.isEmpty
                    ? 'Everything has been reviewed — nothing is pending.'
                    : 'No submissions match this filter.',
                style: TextStyle(color: Colors.grey[600], fontSize: 13.5),
              ),
              if (_submissions.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _selectedTab = 0;
                    _searchQuery = '';
                  }),
                  child: const Text('Clear filters'),
                ),
              ],
            ],
          ),
        ),
      ];
    }

    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i == 0) const SizedBox(height: 16),
        _submissionCard(items[i]),
        if (i < items.length - 1) const SizedBox(height: 12),
      ],
    ];
  }

  Widget _submissionCard(ApprovalSubmission submission) {
    final busy = _working.contains(submission.id);
    final decided = submission.status != ApprovalStatus.pending;
    final statusColor = submission.status == ApprovalStatus.approved
        ? AppTheme.success
        : submission.status == ApprovalStatus.rejected
        ? AppTheme.maraRed
        : _amber;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: decided ? statusColor.withValues(alpha: 0.045) : Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: decided ? statusColor.withValues(alpha: 0.45) : _hairline,
        ),
        boxShadow: _shadowSm(),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 620;

          final identity = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: submission.avatarColor.withValues(alpha: 0.14),
                child: Text(
                  submission.initials,
                  style: TextStyle(
                    color: submission.avatarColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            submission.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: _ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _statusBadge(submission),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: submission.typeColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              submission.typeLabel,
                              style: TextStyle(
                                fontSize: 12,
                                color: submission.typeColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${submission.department} · ${submission.role}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        Text(
                          submission.timeLabel,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );

          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 11),
              Text(
                submission.reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.8,
                  color: Color(0xFF334155),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _metaChip(
                    Icons.calendar_today_rounded,
                    submission.date,
                    color: _muted,
                  ),
                  if (submission.punchIn != null)
                    _metaChip(
                      Icons.login_rounded,
                      submission.punchIn!,
                      color: _muted,
                    ),
                  if (submission.variance != null)
                    _metaChip(
                      Icons.warning_amber_rounded,
                      submission.variance!,
                      color: _amber,
                    ),
                  if (submission.hasAttachment)
                    _metaChip(
                      Icons.attach_file_rounded,
                      'MC certificate',
                      color: AppTheme.maraBlue,
                    ),
                ],
              ),
            ],
          );

          final actions = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: busy || decided
                    ? null
                    : () => _openDetail(submission),
                icon: const Icon(Icons.visibility_rounded, size: 16),
                label: const Text('Review'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _navy,
                  side: BorderSide(
                    color: decided ? Colors.grey[300]! : _hairline,
                  ),
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy || decided
                          ? null
                          : () => _decide(submission, approve: false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.maraRed,
                        side: BorderSide(
                          color: decided ? Colors.grey[300]! : AppTheme.maraRed,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(
                              'Reject',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: busy || decided
                          ? null
                          : () => _decide(submission, approve: true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppTheme.success.withValues(
                          alpha: 0.45,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Approve',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          );

          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [identity, details],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(width: 208, child: actions),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [identity, details, const SizedBox(height: 14), actions],
          );
        },
      ),
    );
  }

  /// Badge that cross-fades from Pending to Approved / Rejected.
  Widget _statusBadge(ApprovalSubmission submission) {
    final (label, color, icon) = switch (submission.status) {
      ApprovalStatus.pending => ('Pending', _amber, Icons.schedule_rounded),
      ApprovalStatus.approved => (
        'Approved',
        AppTheme.success,
        Icons.check_circle_rounded,
      ),
      ApprovalStatus.rejected => (
        'Rejected',
        AppTheme.maraRed,
        Icons.cancel_rounded,
      ),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
          alignment: Alignment.centerRight,
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey<ApprovalStatus>(submission.status),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12.5, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String label, {required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _surfaceMuted,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: _hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          // Loose fit: the chip shrinks and ellipsizes instead of pushing
          // its parent Row past the card edge with a long punch-in stamp.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Review slide-over — the full record behind a queue row.
// ─────────────────────────────────────────────────────────────────────
class _ReviewPanel extends StatelessWidget {
  const _ReviewPanel({required this.submission});

  final ApprovalSubmission submission;

  @override
  Widget build(BuildContext context) {
    final showPunch = submission.punchIn != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: submission.avatarColor.withValues(alpha: 0.14),
              child: Text(
                submission.initials,
                style: TextStyle(
                  color: submission.avatarColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
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
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${submission.role} · ${submission.department}',
                    style: const TextStyle(fontSize: 13, color: _muted),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: submission.typeColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        submission.typeLabel,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: submission.typeColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          submission.timeLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: _muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _surfaceMuted,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: _hairline),
          ),
          child: Column(
            children: [
              _infoRow('DATE', submission.date),
              const Divider(height: 18),
              _infoRow('DEPARTMENT', submission.department),
              if (showPunch) ...[
                const Divider(height: 18),
                _infoRow('PUNCH IN', submission.punchIn ?? '—'),
                const Divider(height: 18),
                _infoRow(
                  'VARIANCE',
                  submission.variance ?? '—',
                  valueColor: _amber,
                ),
              ],
              const Divider(height: 18),
              _infoRow(
                'STATUS',
                submission.status == ApprovalStatus.pending
                    ? 'Awaiting decision'
                    : submission.status == ApprovalStatus.approved
                    ? 'Approved'
                    : 'Rejected',
                valueColor: submission.status == ApprovalStatus.approved
                    ? AppTheme.success
                    : submission.status == ApprovalStatus.rejected
                    ? AppTheme.maraRed
                    : _amber,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'REASON PROVIDED',
          style: TextStyle(
            fontSize: 11,
            color: _muted,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: _hairline),
          ),
          child: Text(
            submission.reason,
            style: const TextStyle(fontSize: 13.5, height: 1.5),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'ATTACHMENTS',
          style: TextStyle(
            fontSize: 11,
            color: _muted,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: submission.hasAttachment ? Colors.white : _surfaceMuted,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: submission.hasAttachment
                  ? AppTheme.maraBlue.withValues(alpha: 0.35)
                  : _hairline,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color:
                      (submission.hasAttachment
                              ? AppTheme.maraBlue
                              : Colors.grey)
                          .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  submission.hasAttachment
                      ? Icons.description_rounded
                      : Icons.insert_drive_file_outlined,
                  color: submission.hasAttachment
                      ? AppTheme.maraBlue
                      : Colors.grey,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      submission.hasAttachment
                          ? 'Medical certificate'
                          : 'No attachment provided',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      submission.hasAttachment
                          ? 'Supporting document link provided with the request.'
                          : 'This submission was made without supporting documents.',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (submission.attachmentUrl != null)
          TextButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open supporting document'),
            onPressed: () async {
              try {
                final opened = await launchUrl(
                  Uri.parse(submission.attachmentUrl!),
                  mode: LaunchMode.externalApplication,
                );
                if (!opened) {
                  throw Exception('No application could open this link.');
                }
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not open document: $error')),
                  );
                }
              }
            },
          ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.gpp_maybe_rounded, size: 18, color: _amber),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Approving or rejecting updates the attendance / leave record, '
                  'notifies the staff member and their reporting manager, and is '
                  'written to the audit log. The decision cannot be undone.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF5B6478),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            color: _muted,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: valueColor ?? _ink,
            ),
          ),
        ),
      ],
    );
  }
}
