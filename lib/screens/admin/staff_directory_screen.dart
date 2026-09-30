import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config/app_config.dart';
import '../../services/database_service.dart';
import '../../services/presence_service.dart';
import '../../widgets/admin_ui.dart';

// =====================================================================
// SLIDE-IN TOAST — small pill with ✓ (success) or ✗ (fail) icon that
// slides in from the RIGHT, holds ~2 s, then slides back out to the
// right. Rendered as a floating overlay (Stack/Positioned) so it never
// pushes surrounding content around.
// =====================================================================
class SlideToast extends StatefulWidget {
  final String message;
  final bool success;
  final Duration duration;

  const SlideToast({
    super.key,
    required this.message,
    required this.success,
    this.duration = const Duration(seconds: 2),
  });

  @override
  State<SlideToast> createState() => _SlideToastState();
}

class _SlideToastState extends State<SlideToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  /// Slides from just off the right edge into place; reversing (exit)
  /// slides it back out to the right.
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(1.6, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _controller.reverse();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: widget.success ? Colors.green : Colors.red,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.success ? Icons.check : Icons.close,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                widget.message,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Admin Staff Directory page.
///
/// Lists all staff with search + department filter + active/inactive filter.
/// Tap a staff card to open their detail profile. Admin can add new staff,
/// edit details, reset passwords, and delete staff.
// =====================================================================
// PRESENCE HELPERS — turn a raw `last_seen` timestamp into something
// readable. Online means the staff member's app sent a heartbeat within
// PresenceService.onlineThreshold (see presence_service.dart).
// =====================================================================

/// Short label for a card: "Online now", "5m ago", "Never signed in".
String _presenceLabel(DateTime? lastSeen) {
  if (lastSeen == null) return 'Never signed in';
  if (PresenceService.isOnline(lastSeen)) return 'Online now';
  return 'Last online ${_timeAgo(lastSeen)}';
}

/// Longer label for the detail screen, includes the exact date/time.
String _presenceLabelLong(DateTime? lastSeen) {
  if (lastSeen == null) return 'Never signed in';
  if (PresenceService.isOnline(lastSeen)) return 'Online now';
  final local = lastSeen.toLocal();
  final d =
      '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
  final t =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  return '${_timeAgo(lastSeen)}  ($d $t)';
}

/// "just now" / "5m ago" / "3h ago" / "2d ago" / "12/03/2026".
String _timeAgo(DateTime time) {
  final diff = DateTime.now().toUtc().difference(time.toUtc());
  if (diff.isNegative || diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  final local = time.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}

class StaffDirectoryScreen extends StatefulWidget {
  /// Maximum number of staff accounts allowed in the system.
  /// The directory header shows "current/limit" and the Add form is
  /// blocked once the limit is reached.
  static const int maxStaffLimit = 255;

  const StaffDirectoryScreen({super.key});

  @override
  State<StaffDirectoryScreen> createState() => _StaffDirectoryScreenState();
}

class _StaffDirectoryScreenState extends State<StaffDirectoryScreen> {
  List<Map<String, dynamic>> _allStaff = [];
  List<Map<String, dynamic>> _departments = [];
  bool _isLoading = true;
  String? _error;
  String _searchQuery = '';
  String? _selectedDeptId; // null = All
  bool _showInactive = false;
  bool _onlineOnly = false; // "Online" chip — show only staff online now

  // ── Presence freshness ──
  // The staff realtime stream pushes every heartbeat, so the dots update
  // themselves. The ticker only re-renders so the "5m ago" labels keep
  // counting up even when nothing changes in the database.
  StreamSubscription<List<Map<String, dynamic>>>? _staffSub;
  Timer? _presenceTicker;

  // ── In-page toast (shown just above the "X/255 staff" row) ──
  String? _toastMessage;
  bool _toastSuccess = true;
  int _toastKey = 0; // bump to replay the slide animation

  /// Shows the slide-in toast directly above the staff-counter row.
  void _showToast(String message, {bool success = true}) {
    setState(() {
      _toastMessage = message;
      _toastSuccess = success;
      _toastKey++;
    });
    // Clear the slot once the toast has finished sliding out so the
    // layout doesn't keep a collapsed pill forever.
    Future.delayed(const Duration(milliseconds: 2800), () {
      if (!mounted) return;
      if (_toastMessage == message) {
        setState(() => _toastMessage = null);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    _subscribeToStaffChanges();
    // Re-render every 30s so "Last online 5m ago" keeps counting up and a
    // staff member whose heartbeat stopped flips to offline on its own.
    _presenceTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _staffSub?.cancel();
    _presenceTicker?.cancel();
    super.dispose();
  }

  /// Live-refresh the list when any staff row changes — including the
  /// `last_seen` heartbeats that drive the online dots.
  void _subscribeToStaffChanges() {
    _staffSub = Supabase.instance.client
        .from('staff')
        .stream(primaryKey: ['id'])
        .listen(
          (_) {
            if (mounted) _loadData(silent: true);
          },
          onError: (Object error) {
            debugPrint('[StaffDirectory] staff stream error: $error');
          },
          cancelOnError: false,
        );
  }

  /// [silent] skips the loading spinner — used by the realtime stream so
  /// incoming heartbeats don't flash the list every minute.
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        DatabaseService.getStaffDirectoryFull(),
        DatabaseService.getDepartments(),
      ]);
      if (!mounted) return;
      setState(() {
        _allStaff = List<Map<String, dynamic>>.from(results[0] as List);
        _departments = List<Map<String, dynamic>>.from(results[1] as List);
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      // A failed background refresh keeps the list that's already on
      // screen — only a user-triggered load shows the error state.
      if (silent) {
        debugPrint('[StaffDirectory] silent refresh failed: $e');
        return;
      }
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredStaff {
    final list = _allStaff.where((s) {
      final matchesDept =
          _selectedDeptId == null || s['department_id'] == _selectedDeptId;
      final isActive = (s['is_active'] as bool?) ?? true;
      final matchesActive = _showInactive || isActive;
      final matchesOnline =
          !_onlineOnly ||
          PresenceService.isOnline(
            PresenceService.parseLastSeen(s['last_seen']),
          );
      final name = (s['full_name'] as String?) ?? '';
      final staffNum = (s['staff_number'] as String?) ?? '';
      final email = (s['email'] as String?) ?? '';
      final q = _searchQuery.toLowerCase();
      final matchesSearch =
          _searchQuery.isEmpty ||
          name.toLowerCase().contains(q) ||
          staffNum.toLowerCase().contains(q) ||
          email.toLowerCase().contains(q);
      return matchesDept && matchesSearch && matchesActive && matchesOnline;
    }).toList();

    // Online first, then most-recently-seen, then name. Keeps whoever is
    // working right now at the top of the list.
    list.sort((a, b) {
      final aSeen = PresenceService.parseLastSeen(a['last_seen']);
      final bSeen = PresenceService.parseLastSeen(b['last_seen']);
      final aOnline = PresenceService.isOnline(aSeen);
      final bOnline = PresenceService.isOnline(bSeen);
      if (aOnline != bOnline) return aOnline ? -1 : 1;
      if (aSeen != null && bSeen != null && aSeen != bSeen) {
        return bSeen.compareTo(aSeen);
      }
      if (aSeen == null && bSeen != null) return 1;
      if (aSeen != null && bSeen == null) return -1;
      final aName = (a['full_name'] as String?) ?? '';
      final bName = (b['full_name'] as String?) ?? '';
      return aName.toLowerCase().compareTo(bName.toLowerCase());
    });
    return list;
  }

  /// How many staff are online right now (drives the "Online" chip count).
  int get _onlineCount => _allStaff
      .where(
        (s) => PresenceService.isOnline(
          PresenceService.parseLastSeen(s['last_seen']),
        ),
      )
      .length;

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Staff directory',
      subtitle:
          'Your people, in one place. Manage profiles, departments and account access.',
      action: FilledButton.icon(
        onPressed: _openAddForm,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Add staff'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: Column(
          children: [
            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                decoration: InputDecoration(
                  hintText: 'Search by name, staff number, or email...',
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

            // ── Department filter chips ──
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _deptChip('All', null),
                  const SizedBox(width: 8),
                  ..._departments.map(
                    (d) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _deptChip(
                        d['name'] as String? ?? '',
                        d['id'] as String?,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Active / All toggle + staff counter row ──
            // The toast floats OVER this row (Stack + Clip.none) so the
            // staff list below never shifts when it appears/disappears.
            Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            setState(() => _showInactive = !_showInactive),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _showInactive
                                ? const Color(0xFF002060)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _showInactive
                                  ? const Color(0xFF002060)
                                  : Colors.grey[300]!,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _showInactive
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                                size: 14,
                                color: _showInactive
                                    ? Colors.white
                                    : Colors.grey[600],
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _showInactive ? 'Showing All' : 'Active Only',
                                style: TextStyle(
                                  color: _showInactive
                                      ? Colors.white
                                      : Colors.grey[700],
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // ── "Online" filter chip — tap to show only staff whose
                      //    app is running right now. Count updates live. ──
                      GestureDetector(
                        onTap: () => setState(() => _onlineOnly = !_onlineOnly),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _onlineOnly ? Colors.green : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _onlineOnly
                                  ? Colors.green
                                  : Colors.grey[300]!,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: _onlineOnly
                                    ? Colors.white
                                    : Colors.green,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Online ($_onlineCount)',
                                style: TextStyle(
                                  color: _onlineOnly
                                      ? Colors.white
                                      : Colors.grey[700],
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Text(
                        '${_allStaff.length}/${StaffDirectoryScreen.maxStaffLimit} staff',
                        style: TextStyle(
                          color:
                              _allStaff.length >=
                                  StaffDirectoryScreen.maxStaffLimit
                              ? Colors.red
                              : Colors.grey[500],
                          fontSize: 12,
                          fontWeight:
                              _allStaff.length >=
                                  StaffDirectoryScreen.maxStaffLimit
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Floating toast — slides in from the right edge and
                //    hovers just above the counter row. Pure overlay:
                //    nothing on screen moves when it appears. ──
                if (_toastMessage != null)
                  Positioned(
                    top: -42,
                    right: 16,
                    child: SlideToast(
                      key: ValueKey(_toastKey),
                      message: _toastMessage!,
                      success: _toastSuccess,
                      duration: const Duration(milliseconds: 2200),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 4),

            // ── Staff list ──
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Failed: $_error',
                            style: const TextStyle(color: Colors.red),
                          ),
                          TextButton(
                            onPressed: _loadData,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _filteredStaff.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.3,
                        ),
                        Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.people_outline,
                                color: Colors.grey[300],
                                size: 64,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No staff found.',
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) =>
                          constraints.maxWidth >= 850
                          ? _staffTable()
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                              itemCount: _filteredStaff.length,
                              itemBuilder: (context, i) =>
                                  _staffCard(_filteredStaff[i]),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deptChip(String label, String? deptId) {
    final isSelected =
        _selectedDeptId == deptId ||
        (_selectedDeptId == null && deptId == null);
    return GestureDetector(
      onTap: () => setState(() => _selectedDeptId = deptId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF002060) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF002060) : Colors.grey[300]!,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[700],
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _staffTable() {
    final staff = _filteredStaff;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: AdminUi.panel(),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                showCheckboxColumn: false,
                headingRowHeight: 50,
                dataRowMinHeight: 80,
                dataRowMaxHeight: 80,
                horizontalMargin: 24,
                columnSpacing: 28,
                columns: const [
                  DataColumn(label: Text('STAFF MEMBER')),
                  DataColumn(label: Text('STAFF ID')),
                  DataColumn(label: Text('DEPARTMENT')),
                  DataColumn(label: Text('STATUS')),
                  DataColumn(label: Text('LAST ACTIVE')),
                ],
                rows: staff.map((person) {
                  final name = person['full_name'] as String? ?? 'Unknown';
                  final active = person['is_active'] as bool? ?? true;
                  final seen = PresenceService.parseLastSeen(
                    person['last_seen'],
                  );
                  return DataRow(
                    onSelectChanged: (_) => _openDetail(person),
                    cells: [
                      DataCell(
                        SizedBox(
                          width: 230,
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 19,
                                backgroundColor: AdminUi.background,
                                child: Text(
                                  name.isEmpty ? '?' : name[0].toUpperCase(),
                                  style: const TextStyle(
                                    color: AdminUi.navy,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      person['email'] as String? ?? '—',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AdminUi.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      DataCell(Text(person['staff_number'] as String? ?? '—')),
                      DataCell(
                        SizedBox(
                          width: 170,
                          child: Text(
                            person['departments']?['name'] as String? ?? '—',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? const Color(0xFFEAF5F0)
                                : AdminUi.background,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            active ? 'Active' : 'Inactive',
                            style: TextStyle(
                              color: active ? AdminUi.success : AdminUi.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          _presenceLabel(seen),
                          style: TextStyle(
                            color: PresenceService.isOnline(seen)
                                ? AdminUi.success
                                : AdminUi.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _staffCard(Map<String, dynamic> staff) {
    final name = (staff['full_name'] as String?) ?? 'Unknown';
    final staffNum = (staff['staff_number'] as String?) ?? '—';
    final position = (staff['position'] as String?) ?? '—';
    final grade = (staff['staff_grade'] as String?) ?? '—';
    final employmentStatus = (staff['employment_status'] as String?) ?? '—';
    final deptName = (staff['departments']?['name'] as String?) ?? '—';
    final role = (staff['role'] as String?) ?? 'staff';
    final isActive = (staff['is_active'] as bool?) ?? true;
    final lastSeen = PresenceService.parseLastSeen(staff['last_seen']);
    final isOnline = PresenceService.isOnline(lastSeen);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _openDetail(staff),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(20),
        decoration: AdminUi.panel(),
        child: Row(
          children: [
            // Avatar with a presence dot in the bottom-right corner:
            // green = app open now, grey = offline.
            Stack(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: role == 'admin'
                      ? Colors.red.withValues(alpha: 0.1)
                      : const Color(0xFF002060).withValues(alpha: 0.1),
                  child: Text(
                    name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
                    style: TextStyle(
                      color: role == 'admin'
                          ? Colors.red
                          : const Color(0xFF002060),
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green : Colors.grey[400],
                      shape: BoxShape.circle,
                      // White ring keeps the dot readable over the avatar.
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (role == 'admin')
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'ADMIN',
                            style: TextStyle(color: Colors.red, fontSize: 9),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Nombor Gaji: $staffNum',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$position · $grade · $employmentStatus',
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    deptName,
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: isActive ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isActive ? 'Active' : 'Inactive',
                        style: TextStyle(
                          color: isActive ? Colors.green : Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Presence line — employment status (above) and online
                  // status (here) are deliberately separate things.
                  Text(
                    isOnline
                        ? '● ${_presenceLabel(lastSeen)}'
                        : '○ ${_presenceLabel(lastSeen)}',
                    style: TextStyle(
                      color: isOnline ? Colors.green : Colors.grey[500],
                      fontSize: 11,
                      fontWeight: isOnline
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  // ── ADD STAFF FORM ──────────────────────────────────────────────────
  Future<void> _openAddForm() async {
    // Staff limit guard — no new accounts once the cap is reached.
    if (_allStaff.length >= StaffDirectoryScreen.maxStaffLimit) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: const Text('Staff Limit Reached'),
          content: Text(
            'The system allows a maximum of ${StaffDirectoryScreen.maxStaffLimit} '
            'staff accounts (${_allStaff.length} in use).\n\n'
            'Delete an existing staff member before adding a new one.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final result = await Navigator.push<_ToastResult>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            StaffFormScreen(departments: _departments, isEdit: false),
      ),
    );
    await _loadData();
    if (result != null && mounted) {
      _showToast(result.message, success: result.success);
    }
  }

  // ── STAFF DETAIL PROFILE ────────────────────────────────────────────
  Future<void> _openDetail(Map<String, dynamic> staff) async {
    final result = await Navigator.push<_ToastResult>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            StaffDetailScreen(staff: staff, departments: _departments),
      ),
    );
    await _loadData();
    if (result != null && mounted) {
      _showToast(result.message, success: result.success);
    }
  }
}

/// Lightweight result passed back from the form / detail screen to the
/// directory so it can show the slide-in toast after refreshing.
class _ToastResult {
  final String message;
  final bool success;
  const _ToastResult(this.message, this.success);
}

// =====================================================================
// STAFF DETAIL PROFILE SCREEN
// =====================================================================
class StaffDetailScreen extends StatefulWidget {
  final Map<String, dynamic> staff;
  final List<Map<String, dynamic>> departments;

  const StaffDetailScreen({
    super.key,
    required this.staff,
    required this.departments,
  });

  @override
  State<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends State<StaffDetailScreen> {
  bool _isDeleting = false;
  Map<String, int>? _stats;
  bool _statsLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final stats = await DatabaseService.getStaffAttendanceStats(
        widget.staff['id'] as String,
      );
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _statsLoading = false;
      });
    } on Exception {
      if (!mounted) return;
      setState(() => _statsLoading = false);
    }
  }

  /// Opens the edit form from the detail screen. When the edit saves
  /// successfully it pops BOTH screens back to the directory, carrying
  /// the toast result so the directory can show it.
  Future<void> _openEditFromDetail() async {
    final result = await Navigator.push<_ToastResult>(
      context,
      MaterialPageRoute(
        builder: (context) => StaffFormScreen(
          departments: widget.departments,
          isEdit: true,
          existingStaff: widget.staff,
        ),
      ),
    );
    // Pop this detail screen too — but only if something actually
    // happened (edit saved or failed). If the user just backed out of
    // the edit form (result == null), stay on the detail screen.
    if (mounted && result != null) Navigator.pop(context, result);
  }

  Future<void> _confirmDelete() async {
    final staff = widget.staff;
    final name = (staff['full_name'] as String?) ?? 'this staff';
    final staffId = staff['id'] as String;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text('Delete Staff?'),
        content: Text(
          'Permanently delete $name?\n\n'
          'This removes their login, staff record, attendance history and '
          'leave records. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeleting = true);
    try {
      await DatabaseService.deleteStaff(
        supabaseUrl: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
        userId: staffId,
      );
      if (!mounted) return;
      // Pop back to the directory with a result so it shows the toast.
      Navigator.pop(context, _ToastResult('$name deleted.', true));
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      // Stay on the detail screen and show the toast locally? No — the
      // toast slot lives in the directory. For a failed delete just pop
      // with a failure result so the directory shows ✗ + reason.
      Navigator.pop(context, _ToastResult('Delete failed: $e', false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = widget.staff;
    final name = (staff['full_name'] as String?) ?? 'Unknown';
    final staffNum = (staff['staff_number'] as String?) ?? '—';
    final ic = (staff['ic_number'] as String?) ?? '—';
    final email = (staff['email'] as String?) ?? '—';
    final deptName = (staff['departments']?['name'] as String?) ?? '—';
    final jawatan = (staff['position'] as String?) ?? '—';
    final grade = (staff['staff_grade'] as String?) ?? '—';
    final employmentStatus = (staff['employment_status'] as String?) ?? '—';
    final role = (staff['role'] as String?) ?? 'staff';
    final isActive = (staff['is_active'] as bool?) ?? true;
    final lastSeen = PresenceService.parseLastSeen(staff['last_seen']);
    final isOnline = PresenceService.isOnline(lastSeen);

    return AdminPage(
      title: 'Staff profile',
      subtitle: 'Account details, attendance and access for $name.',
      maxWidth: 900,
      body: _isDeleting
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // ── Profile header card ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: AdminUi.panel(),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundColor: role == 'admin'
                              ? Colors.red.withValues(alpha: 0.1)
                              : const Color(0xFF002060).withValues(alpha: 0.1),
                          child: Text(
                            name.isNotEmpty
                                ? name.substring(0, 1).toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: role == 'admin'
                                  ? Colors.red
                                  : const Color(0xFF002060),
                              fontWeight: FontWeight.bold,
                              fontSize: 30,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          email,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (role == 'admin')
                              Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'ADMIN',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: (isActive ? Colors.green : Colors.grey)
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isActive ? 'Active' : 'Inactive',
                                style: TextStyle(
                                  color: isActive ? Colors.green : Colors.grey,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                            // Presence badge — separate from the Active /
                            // Inactive employment badge next to it.
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: (isOnline ? Colors.green : Colors.grey)
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.circle,
                                    size: 7,
                                    color: isOnline
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isOnline ? 'Online' : 'Offline',
                                    style: TextStyle(
                                      color: isOnline
                                          ? Colors.green
                                          : Colors.grey,
                                      fontSize: 10,
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

                  const SizedBox(height: 16),

                  // ── Staff details card ──
                  _sectionCard('STAFF DETAILS', [
                    _detailRow('Nombor Gaji', staffNum),
                    _detailRow('No IC', ic),
                    _detailRow('Jabatan', deptName),
                    _detailRow('Jawatan', jawatan),
                    _detailRow('Gred Gaji', grade),
                    _detailRow('Status', employmentStatus),
                    _detailRow('Email', email),
                    _detailRow('Last online', _presenceLabelLong(lastSeen)),
                  ]),

                  const SizedBox(height: 16),

                  // ── Attendance this month card ──
                  _sectionCard('ATTENDANCE THIS MONTH', [
                    _statsLoading
                        ? const Center(child: CircularProgressIndicator())
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _statTile(
                                'Total',
                                _stats?['total'] ?? 0,
                                Colors.blue,
                              ),
                              _statTile(
                                'Present',
                                _stats?['present'] ?? 0,
                                Colors.green,
                              ),
                              _statTile(
                                'Late',
                                _stats?['late'] ?? 0,
                                Colors.orange,
                              ),
                              _statTile(
                                'Absent',
                                _stats?['absent'] ?? 0,
                                Colors.red,
                              ),
                            ],
                          ),
                  ]),

                  const SizedBox(height: 16),

                  // ── Action buttons ──
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: _openEditFromDetail,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      label: const Text(
                        'Edit Details',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF002060),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: _isDeleting ? null : _confirmDelete,
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      label: const Text(
                        'Delete Staff',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _sectionCard(String title, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: AdminUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF002060),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile(String label, int value, Color color) {
    return Column(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$value',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 11)),
      ],
    );
  }
}

// =====================================================================
// STAFF FORM SCREEN (Add / Edit)
// =====================================================================
class StaffFormScreen extends StatefulWidget {
  final List<Map<String, dynamic>> departments;
  final bool isEdit;
  final Map<String, dynamic>? existingStaff;

  const StaffFormScreen({
    super.key,
    required this.departments,
    required this.isEdit,
    this.existingStaff,
  });

  @override
  State<StaffFormScreen> createState() => _StaffFormScreenState();
}

class _StaffFormScreenState extends State<StaffFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _staffNumberController = TextEditingController();
  final _icController = TextEditingController();

  String? _selectedDeptId; // Jabatan
  String? _selectedPosition; // Jawatan
  String? _selectedGrade; // Gred Gaji
  String? _selectedEmploymentStatus; // TETAP / KONTRAK
  bool _isActive = true;
  bool _isSaving = false;

  // ── In-page toast (password reset feedback) ──
  String? _toastMessage;
  bool _toastSuccess = true;
  int _toastKey = 0;

  /// Shows the slide-in toast at the top of the form (below the app bar).
  void _showToast(String message, {bool success = true}) {
    setState(() {
      _toastMessage = message;
      _toastSuccess = success;
      _toastKey++;
    });
    Future.delayed(const Duration(milliseconds: 2800), () {
      if (!mounted) return;
      if (_toastMessage == message) {
        setState(() => _toastMessage = null);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.isEdit && widget.existingStaff != null) {
      final s = widget.existingStaff!;
      _nameController.text = (s['full_name'] as String?) ?? '';
      _emailController.text = (s['email'] as String?) ?? '';
      _staffNumberController.text = (s['staff_number'] as String?) ?? '';
      _icController.text = _IcFormatter.format(
        (s['ic_number'] as String?) ?? '',
      );
      _selectedDeptId = s['department_id'] as String?;
      _selectedPosition = (s['position'] as String?)?.isNotEmpty == true
          ? s['position'] as String?
          : null;
      _selectedGrade = (s['staff_grade'] as String?)?.isNotEmpty == true
          ? s['staff_grade'] as String?
          : null;
      _selectedEmploymentStatus =
          (s['employment_status'] as String?)?.isNotEmpty == true
          ? s['employment_status'] as String?
          : 'TETAP';
      _isActive = (s['is_active'] as bool?) ?? true;
    }
    _selectedEmploymentStatus ??= 'TETAP';
  }

  static const List<String> _positionOptions = [
    'Pengarah',
    'TP HEA',
    'TP KPHP',
    'PPP',
    'PLV',
    'PPLV',
    'PPT(K)',
    'Kaunselor',
    'PPSM',
    'PPI',
    'PEM.TADBIR',
    'PEMANDU',
    'PENJAGA JEN.ELEK',
    'PEN.JURUTERA',
  ];

  static const List<String> _employmentStatusOptions = ['TETAP', 'KONTRAK'];

  List<String> get _gradesForPosition => switch (_selectedPosition) {
    'Pengarah' => ['DV13'],
    'TP HEA' || 'TP KPHP' => ['DV14', 'E12'],
    'PPP' => ['DG9', 'DG10', 'DG11', 'DG12', 'DG13', 'DG14'],
    'PLV' || 'PPLV' => ['DV5', 'DV6', 'DV7', 'DV8', 'DV9', 'DV10'],
    'PPT(K)' => ['N6'],
    'Kaunselor' => ['DG9', 'DG10'],
    'PPSM' || 'PPI' || 'PEM.TADBIR' => ['N1', 'N2', 'N3', 'FA6'],
    'PEMANDU' => ['H1'],
    'PENJAGA JEN.ELEK' => ['J1'],
    'PEN.JURUTERA' => ['JA5'],
    _ => [],
  };

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _staffNumberController.dispose();
    _icController.dispose();
    super.dispose();
  }

  /// Formats an exception into a short, human-friendly toast message.
  /// The raw exception text ("Exception: duplicate key value violates
  /// unique constraint ...") is useless to the admin, so we map the
  /// known cases to plain language and keep everything else short.
  String _friendlyError(Object e) {
    if (e is PostgrestException) {
      final details = [
        if (e.code != null) 'code ${e.code}',
        e.message,
        if (e.details != null && e.details.toString().isNotEmpty)
          e.details.toString(),
        if (e.hint != null && e.hint!.isNotEmpty) e.hint!,
      ].join(' — ');
      return 'Database error: $details';
    }
    final m = e.toString().toLowerCase();
    if (m.contains('already registered') ||
        m.contains('already exists') ||
        m.contains('duplicate key')) {
      return 'Duplicate entry — check email / No Gaji / No IC.';
    }
    if (m.contains('password should be at least')) {
      return 'Password must be at least 6 characters.';
    }
    if (m.contains('invalid email') || m.contains('unable to validate email')) {
      return 'Invalid email format.';
    }
    if (m.contains('staff limit reached')) {
      return 'Staff limit of ${StaffDirectoryScreen.maxStaffLimit} reached. '
          'Delete a staff member to add more.';
    }
    if (m.contains('too many sign-up emails') ||
        m.contains('over_email_send_rate_limit') ||
        m.contains('429')) {
      return 'Too many attempts — wait a while before trying again.';
    }
    if (m.contains('dup_ic')) {
      return 'This No IC is already used by another staff.';
    }
    if (m.contains('dup_staff_number')) {
      return 'This No Gaji is already used by another staff.';
    }
    if (m.contains('dup_email')) {
      return 'This email is already registered.';
    }
    return 'Save failed: ${e.toString().replaceAll('Exception: ', '')}';
  }

  Future<void> _save() async {
    // Guard against double-tap / re-entry while a save is already running.
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final ic = _icController.text.trim();
      final staffNo = _staffNumberController.text.trim();
      final email = _emailController.text.trim();

      if (widget.isEdit) {
        // ── EDIT existing staff ──
        final staffId = widget.existingStaff!['id'] as String;

        // Pre-flight duplicate checks — excludes this staff's own row
        // so saving without changing a field isn't flagged as a dup.
        // IC is optional, so skip its check when left blank.
        if (ic.isNotEmpty &&
            await DatabaseService.isStaffFieldTaken(
              column: 'ic_number',
              value: ic,
              excludeId: staffId,
            )) {
          throw Exception('dup_ic');
        }
        if (await DatabaseService.isStaffFieldTaken(
          column: 'staff_number',
          value: staffNo,
          excludeId: staffId,
        )) {
          throw Exception('dup_staff_number');
        }
        if (await DatabaseService.isStaffFieldTaken(
          column: 'email',
          value: email,
          excludeId: staffId,
        )) {
          throw Exception('dup_email');
        }

        await DatabaseService.updateStaff(
          id: staffId,
          fullName: _nameController.text.trim(),
          staffNumber: staffNo,
          icNumber: ic.isEmpty ? null : ic,
          departmentId: _selectedDeptId,
          position: _selectedPosition,
          staffGrade: _selectedGrade,
          employmentStatus: _selectedEmploymentStatus,
          isActive: _isActive,
        );

        if (!mounted) return;
        Navigator.pop(context, _ToastResult('Staff details updated.', true));
      } else {
        // ── ADD new staff ──
        // Re-check the limit with a fresh DB count — the directory list
        // may be stale if another admin added staff meanwhile.
        final currentCount = await DatabaseService.getStaffAccountCount();
        if (currentCount >= StaffDirectoryScreen.maxStaffLimit) {
          throw Exception(
            'Staff limit reached (${StaffDirectoryScreen.maxStaffLimit}). '
            'Delete an existing staff member before adding a new one.',
          );
        }

        // Pre-flight duplicate checks (no excludeId — new staff).
        // IC is optional, so skip its check when left blank.
        if (ic.isNotEmpty &&
            await DatabaseService.isStaffFieldTaken(
              column: 'ic_number',
              value: ic,
            )) {
          throw Exception('dup_ic');
        }
        if (await DatabaseService.isStaffFieldTaken(
          column: 'staff_number',
          value: staffNo,
        )) {
          throw Exception('dup_staff_number');
        }
        if (await DatabaseService.isStaffFieldTaken(
          column: 'email',
          value: email,
        )) {
          throw Exception('dup_email');
        }

        await DatabaseService.addStaff(
          supabaseUrl: AppConfig.supabaseUrl,
          anonKey: AppConfig.supabaseAnonKey,
          fullName: _nameController.text.trim(),
          email: email,
          password: _passwordController.text,
          staffNumber: staffNo,
          icNumber: ic.isEmpty ? null : ic,
          departmentId: _selectedDeptId,
          position: _selectedPosition,
          staffGrade: _selectedGrade,
          employmentStatus: _selectedEmploymentStatus,
        );

        if (!mounted) return;
        Navigator.pop(context, _ToastResult('New staff added.', true));
      }
    } on Exception catch (e) {
      // Stay on the form so the admin can fix the input. Show the
      // error as a local toast (top-right) instead of popping back
      // to the directory — that way the typed data is preserved.
      if (!mounted) return;
      _showToast(_friendlyError(e), success: false);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _resetPassword() async {
    if (widget.existingStaff == null) return;
    final staffId = widget.existingStaff!['id'] as String;
    final staffName =
        (widget.existingStaff!['full_name'] as String?) ?? 'this staff';

    final newPwd = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Text('Reset password for $staffName?'),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'New password',
              hintText: 'At least 6 characters',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF002060),
              ),
              child: const Text('Reset', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (newPwd == null || newPwd.length < 6) {
      if (mounted) {
        _showToast('Password must be at least 6 characters.', success: false);
      }
      return;
    }

    try {
      await DatabaseService.resetStaffPassword(
        supabaseUrl: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
        userId: staffId,
        newPassword: newPwd,
      );
      if (!mounted) return;
      _showToast('Password reset for $staffName.');
    } on Exception catch (e) {
      if (!mounted) return;
      _showToast('Reset failed: $e', success: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deptNames = widget.departments;

    return AdminPage(
      title: widget.isEdit ? 'Edit staff member' : 'Add staff member',
      subtitle: widget.isEdit
          ? 'Keep profile information and account access up to date.'
          : 'Create a profile and welcome a new member to your team.',
      maxWidth: 800,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── STAFF DETAILS (first) ──
                  _sectionTitle('STAFF DETAILS'),
                  const SizedBox(height: 12),

                  _textField(_nameController, 'Nama', validator: true),
                  const SizedBox(height: 12),

                  _textField(
                    _staffNumberController,
                    'Nombor Gaji',
                    validator: true,
                  ),
                  const SizedBox(height: 12),

                  _textField(
                    _icController,
                    'No KP',
                    keyboardType: TextInputType.number,
                    hint: 'e.g. 901231-02-1234',
                    maxLength: 14,
                    customValidator: (v) {
                      final value = (v ?? '').trim();
                      if (value.isEmpty) return null; // optional field
                      // Must be the complete MyKad pattern before saving.
                      if (!_IcFormatter.isValid(value)) {
                        return 'Incomplete — 12 digits, e.g. 901231-02-1234';
                      }
                      return null;
                    },
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      _IcFormatter(),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // ── Jabatan dropdown (required) ──
                  DropdownButtonFormField<String>(
                    initialValue: _selectedDeptId,
                    isExpanded: true,
                    decoration: _inputDecoration('Jabatan'),
                    validator: (v) => v == null ? 'Required' : null,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('— Pilih Jabatan —'),
                      ),
                      ...deptNames.map(
                        (d) => DropdownMenuItem(
                          value: d['id'] as String?,
                          child: Text(
                            d['name'] as String? ?? '',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => _selectedDeptId = v),
                  ),
                  const SizedBox(height: 12),

                  // ── Jawatan dropdown ──
                  DropdownButtonFormField<String>(
                    initialValue: _positionOptions.contains(_selectedPosition)
                        ? _selectedPosition
                        : null,
                    isExpanded: true,
                    decoration: _inputDecoration('Jawatan'),
                    validator: (v) => v == null ? 'Required' : null,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('— Select Jawatan —'),
                      ),
                      ..._positionOptions.map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      ),
                    ],
                    onChanged: (v) => setState(() {
                      _selectedPosition = v;
                      _selectedGrade = null;
                    }),
                  ),
                  const SizedBox(height: 12),

                  // ── Gred Gaji dropdown ──
                  DropdownButtonFormField<String>(
                    initialValue: _gradesForPosition.contains(_selectedGrade)
                        ? _selectedGrade
                        : null,
                    isExpanded: true,
                    decoration: _inputDecoration('Gred Gaji'),
                    validator: (v) => v == null ? 'Required' : null,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('— Select Gred Gaji —'),
                      ),
                      ..._gradesForPosition.map(
                        (grade) =>
                            DropdownMenuItem(value: grade, child: Text(grade)),
                      ),
                    ],
                    onChanged: _gradesForPosition.isEmpty
                        ? null
                        : (v) => setState(() => _selectedGrade = v),
                  ),
                  const SizedBox(height: 12),

                  // ── Employment status ──
                  DropdownButtonFormField<String>(
                    initialValue:
                        _employmentStatusOptions.contains(
                          _selectedEmploymentStatus,
                        )
                        ? _selectedEmploymentStatus
                        : 'TETAP',
                    isExpanded: true,
                    decoration: _inputDecoration('Status'),
                    validator: (v) => v == null ? 'Required' : null,
                    items: _employmentStatusOptions
                        .map(
                          (status) => DropdownMenuItem(
                            value: status,
                            child: Text(status),
                          ),
                        )
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _selectedEmploymentStatus = v),
                  ),

                  if (widget.isEdit) ...[
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text('Active'),
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                      activeThumbColor: const Color(0xFF002060),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],

                  const SizedBox(height: 24),

                  // ── LOGIN ACCOUNT (under staff details, add mode only) ──
                  if (!widget.isEdit) ...[
                    _sectionTitle('LOGIN ACCOUNT'),
                    const SizedBox(height: 12),
                    _textField(
                      _emailController,
                      'Email (login)',
                      keyboardType: TextInputType.emailAddress,
                      customValidator: (v) {
                        final value = v?.trim() ?? '';
                        if (value.isEmpty) return 'Required';
                        // Simple but reliable RFC-ish check.
                        final emailOk = RegExp(
                          r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$',
                        ).hasMatch(value);
                        if (!emailOk) {
                          return 'Enter a valid email, e.g. nama@tvet.gov.my';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    _textField(
                      _passwordController,
                      'Password (login)',
                      obscure: true,
                      hint: 'At least 6 characters',
                      customValidator: (v) {
                        final value = v ?? '';
                        if (value.isEmpty) return 'Required';
                        if (value.length < 6) return 'At least 6 characters.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── BUTTONS ──
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF002060),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isSaving
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text(
                              widget.isEdit ? 'Save Changes' : 'Create Staff',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                    ),
                  ),

                  // ── RESET PASSWORD (edit only) ──
                  if (widget.isEdit) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _resetPassword,
                        icon: const Icon(
                          Icons.lock_reset,
                          color: Colors.orange,
                        ),
                        label: const Text(
                          'Reset Password',
                          style: TextStyle(color: Colors.orange),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.orange),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ── Floating toast overlay (top-right, below the app bar) —
          //    floats over the form so fields never shift ──
          if (_toastMessage != null)
            Positioned(
              top: 16,
              right: 16,
              child: SlideToast(
                key: ValueKey('form-$_toastKey'),
                message: _toastMessage!,
                success: _toastSuccess,
                duration: const Duration(milliseconds: 2200),
              ),
            ),
        ],
      ),
    );
  }

  // ── Helpers ──
  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.bold,
        color: Color(0xFF002060),
        letterSpacing: 1,
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    bool validator = false,
    bool obscure = false,
    bool enabled = true,
    TextInputType? keyboardType,
    String? hint,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? customValidator,
  }) {
    String? defaultValidator(String? v) {
      if (v == null || v.trim().isEmpty) return 'Required';
      return null;
    }

    return TextFormField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      keyboardType: keyboardType,
      maxLength: maxLength,
      inputFormatters: inputFormatters,
      decoration: _inputDecoration(label, hint: hint),
      validator: customValidator ?? (validator ? defaultValidator : null),
    );
  }

  InputDecoration _inputDecoration(
    String label, {
    String? hint,
    bool enabled = true,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: enabled ? Colors.white : Colors.grey[100],
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.grey[300]!),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.grey[300]!),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF002060), width: 2),
      ),
    );
  }
}

/// Auto-formats the No IC field into the Malaysian MyKad pattern:
/// `XXXXXX-XX-XXXX` (12 digits + 2 dashes).
///
/// Runs after [FilteringTextInputFormatter.digitsOnly], so the text is
/// already digits-only. Dashes are inserted after the 6th and 8th digits
/// while typing, and re-applied when editing/deleting.
class _IcFormatter extends TextInputFormatter {
  static const int _maxDigits = 12;

  /// Formats a raw stored IC string (with or without dashes) into
  /// `XXXXXX-XX-XXXX`. Used when pre-filling the field in edit mode.
  static String format(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    final capped = digits.length > _maxDigits
        ? digits.substring(0, _maxDigits)
        : digits;
    final buffer = StringBuffer();
    for (var i = 0; i < capped.length; i++) {
      buffer.write(capped[i]);
      if ((i == 5 || i == 7) && capped.length > i + 1) {
        buffer.write('-');
      }
    }
    return buffer.toString();
  }

  /// True if [value] is a complete MyKad string: exactly 12 digits in
  /// `XXXXXX-XX-XXXX` form. Used to reject incomplete ICs at save.
  static bool isValid(String value) {
    return RegExp(r'^\d{6}-\d{2}-\d{4}$').hasMatch(value);
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = format(newValue.text);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
