import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────
// Design tokens — mirrored from the admin dashboard shell so the page
// reads as one more panel of the same application.
// ─────────────────────────────────────────────────────────────────────
const Color _canvas = Color(0xFFF4F6FB);
const Color _hairline = Color(0xFFE2E8F0);
const Color _surfaceMuted = Color(0xFFF8FAFC);
const Color _surfaceInset = Color(0xFFF1F5F9);
const Color _ink = Color(0xFF0F172A);
const Color _muted = Color(0xFF64748B);
const Color _slate700 = Color(0xFF334155);

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

/// Admin screen for managing departments.
///
/// Deliberately **not** a `Scaffold`: it renders *inside* the admin
/// dashboard shell (sticky left rail + top navbar) so navigation chrome
/// is never torn down. Every department is shown as a card with its
/// headcount, and the "Add Department" action lives in the page header
/// (top-right) rather than floating over the list.
class DepartmentsScreen extends StatefulWidget {
  const DepartmentsScreen({super.key, this.onChanged});

  /// Called after any mutation so the shell can refresh the dashboard's
  /// department breakdown.
  final VoidCallback? onChanged;

  @override
  State<DepartmentsScreen> createState() => _DepartmentsScreenState();
}

class _DepartmentsScreenState extends State<DepartmentsScreen> {
  List<Map<String, dynamic>> _departments = [];
  Map<String, int> _headcounts = {};
  bool _isLoading = true;

  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        DatabaseService.getDepartments(),
        DatabaseService.getStaffDirectoryFull(),
      ]);
      final depts = results[0];
      final staff = results[1];
      final counts = <String, int>{};
      for (final s in staff) {
        final deptId = s['department_id'] as String?;
        if (deptId == null) continue;
        counts[deptId] = (counts[deptId] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        _departments = depts;
        _headcounts = counts;
        _isLoading = false;
      });
    } catch (e) {
      // Bare catch: Supabase throws an AssertionError (an Error, not an
      // Exception) when it was never initialised — offline preview/tests.
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  int get _totalStaff => _headcounts.values.fold<int>(0, (sum, n) => sum + n);

  // ── Mutations ───────────────────────────────────────────────────────
  Future<void> _showDepartmentDialog({Map<String, dynamic>? existing}) async {
    final editing = existing;
    final isEdit = editing != null;
    final nameController = TextEditingController(
      text: editing?['name'] as String? ?? '',
    );
    final codeController = TextEditingController(
      text: editing?['code'] as String? ?? '',
    );

    // Pushed by hand instead of `showDialog` so we get hold of the route:
    // `popped` resolves the instant the dialog is dismissed, while its
    // TextFields keep rebuilding for the rest of the exit animation —
    // releasing the controllers at that point trips "A TextEditingController
    // was used after being disposed". `completed` fires only once the route
    // has fully left the overlay, which is the safe release point.
    final route = DialogRoute<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      barrierDismissible: true,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppTheme.maraBlue, AppTheme.navy],
                        ),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        isEdit
                            ? Icons.edit_rounded
                            : Icons.add_business_rounded,
                        color: Colors.white,
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isEdit ? 'Edit Department' : 'Add Department',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: _ink,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _muted,
                      ),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  isEdit
                      ? 'Update the department name or its short code.'
                      : 'Create a new department to group staff and reports.',
                  style: const TextStyle(fontSize: 12.5, color: _muted),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: _inputDecoration(
                    label: 'Department name',
                    hint: 'e.g. Automotive Technology',
                    icon: Icons.badge_outlined,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _inputDecoration(
                    label: 'Short code (optional)',
                    hint: 'e.g. AUT',
                    icon: Icons.tag_rounded,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        foregroundColor: _slate700,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.navy,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        isEdit ? 'Save changes' : 'Add department',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Navigator.of(context).push(route);
    unawaited(
      route.completed.then((_) {
        nameController.dispose();
        codeController.dispose();
      }),
    );
    final result = await route.popped;

    final name = nameController.text.trim();
    final code = codeController.text.trim();
    if (result != true || name.isEmpty || !mounted) return;

    try {
      if (isEdit) {
        await DatabaseService.updateDepartment(
          editing['id'] as String,
          name: name,
          code: code,
        );
      } else {
        await DatabaseService.addDepartment(name: name, code: code);
      }
      widget.onChanged?.call();
      if (mounted) {
        await _loadData();
        if (mounted) {
          _snack(isEdit ? 'Department updated.' : 'Department added.');
        }
      }
    } on Exception catch (e) {
      if (!mounted) return;
      _snack('Failed to save: $e');
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(fontSize: 13.5, color: _muted),
      prefixIcon: Icon(icon, size: 18, color: _muted),
      filled: true,
      fillColor: _surfaceMuted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: _hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: AppTheme.navy, width: 1.4),
      ),
    );
  }

  Future<void> _deleteDepartment(Map<String, dynamic> dept) async {
    final count = _headcounts[dept['id']] ?? 0;
    final confirm = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Delete Department',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Remove "${dept['name']}"'
          '${count > 0 ? ' and unlink its $count staff member${count == 1 ? '' : 's'}' : ''}'
          '? Staff keep their records but lose the department link.',
          style: const TextStyle(fontSize: 13.5, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.maraRed,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await DatabaseService.deleteDepartment(dept['id'] as String);
      widget.onChanged?.call();
      if (mounted) {
        await _loadData();
        if (mounted) _snack('Department deleted.');
      }
    } on Exception catch (e) {
      if (!mounted) return;
      _snack('Failed to delete: $e');
    }
  }

  void _snack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: _ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────
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
                    onRefresh: _loadData,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 18, bottom: 28),
                      children: [
                        _pageHeader(width),
                        const SizedBox(height: 16),
                        if (_loadError != null) ...[
                          _errorNotice(width),
                          const SizedBox(height: 16),
                        ],
                        _statsRow(contentWidth),
                        const SizedBox(height: 18),
                        if (_departments.isEmpty)
                          _emptyState()
                        else
                          _grid(contentWidth),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  // ── Header with the primary "Add Department" action ─────────────────
  Widget _pageHeader(double width) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Departments',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: _ink,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Group staff into departments for reporting and attendance.',
          style: TextStyle(fontSize: 13, color: _muted),
        ),
      ],
    );

    final addButton = ElevatedButton.icon(
      onPressed: () => _showDepartmentDialog(),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.navy,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        shadowColor: AppTheme.navy.withValues(alpha: 0.35),
      ),
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text(
        'Add Department',
        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      ),
    );

    if (width < 640) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: addButton),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: heading),
        const SizedBox(width: 16),
        addButton,
      ],
    );
  }

  Widget _errorNotice(double width) {
    final text = 'Could not refresh live departments: $_loadError';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: AppTheme.maraBlue,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, color: _ink),
            ),
          ),
          TextButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.cloud_sync_rounded, size: 16),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ── Summary counters ────────────────────────────────────────────────
  /// [contentWidth] is the scroll view's inner width (page padding
  /// already removed) so the counters divide it exactly.
  Widget _statsRow(double contentWidth) {
    final cardWidth = contentWidth >= 560
        ? (contentWidth - 12) / 2
        : contentWidth;
    final stats = <(IconData, Color, String, String)>[
      (
        Icons.business_rounded,
        AppTheme.maraBlue,
        '${_departments.length}',
        _departments.length == 1 ? 'Department' : 'Departments',
      ),
      (
        Icons.groups_2_rounded,
        AppTheme.gold,
        '$_totalStaff',
        _totalStaff == 1 ? 'Staff member' : 'Staff members',
      ),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final s in stats)
          SizedBox(
            width: cardWidth,
            child: Container(
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
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: s.$2.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(s.$1, size: 19, color: s.$2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.$3,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: _ink,
                            height: 1.1,
                          ),
                        ),
                        Text(
                          s.$4,
                          style: const TextStyle(fontSize: 12, color: _muted),
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

  // ── Department cards ────────────────────────────────────────────────
  Widget _grid(double contentWidth) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // One grid step that never squeezes the card's Edit/Delete row:
        // ~400px columns mean 1-up on phones, 2-up on tablets/desktop and
        // 3-up on wide desktops.
        maxCrossAxisExtent: 400,
        mainAxisExtent: 196,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: _departments.length,
      itemBuilder: (context, i) => _departmentCard(_departments[i]),
    );
  }

  Widget _departmentCard(Map<String, dynamic> dept) {
    final name = (dept['name'] as String?) ?? 'Unnamed';
    final code = (dept['code'] as String?) ?? '';
    final count = _headcounts[dept['id']] ?? 0;
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().substring(0, 1).toUpperCase();

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _hairline),
        boxShadow: _shadowSm(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.maraBlue, AppTheme.navy],
                  ),
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.navy.withValues(alpha: 0.24),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                        height: 1.25,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (code.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _surfaceInset,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _hairline),
                        ),
                        child: Text(
                          code.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                            color: _slate700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const Spacer(),
          // Headcount counter.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _surfaceMuted,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _hairline),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.people_alt_rounded,
                  size: 16,
                  color: AppTheme.navy.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    count == 1 ? 'staff member' : 'staff members',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              Expanded(
                child: _cardAction(
                  icon: Icons.edit_outlined,
                  label: 'Edit',
                  color: AppTheme.navy,
                  onTap: () => _showDepartmentDialog(existing: dept),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _cardAction(
                  icon: Icons.delete_outline_rounded,
                  label: 'Delete',
                  color: AppTheme.maraRed,
                  onTap: () => _deleteDepartment(dept),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Quiet outlined action used inside the department cards — readable
  /// label instead of a bare icon, with a tinted hover/press state.
  Widget _cardAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        hoverColor: color.withValues(alpha: 0.07),
        highlightColor: color.withValues(alpha: 0.10),
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _hairline),
            color: _surfaceMuted,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: AppTheme.maraBlue.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.business_rounded,
              size: 30,
              color: AppTheme.maraBlue,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No departments yet',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Create your first department to start grouping staff.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _muted),
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            onPressed: () => _showDepartmentDialog(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.navy,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text(
              'Add Department',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
