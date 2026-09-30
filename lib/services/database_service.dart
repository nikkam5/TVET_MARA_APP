import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around the Supabase PostgREST client.
class DatabaseService {
  DatabaseService._();

  static SupabaseClient get _client => Supabase.instance.client;

  // ── Staff / Directory ────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getStaffDirectory() async {
    final response = await _client
        .from('staff')
        .select(
          'id, full_name, staff_number, role, is_active, departments(name)',
        )
        .eq('is_active', true)
        .order('full_name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Full directory listing — selects ALL columns including employment details
  static Future<List<Map<String, dynamic>>> getStaffDirectoryFull() async {
    final response = await _client
        .from('staff')
        .select('*, departments(id, name)')
        .order('full_name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Total staff accounts in the system (every row in the staff table —
  /// admins and inactive accounts included). Used to enforce the
  /// max-staff limit when adding new accounts.
  static Future<int> getStaffAccountCount() async {
    final response = await _client.from('staff').select('id');
    return (response as List).length;
  }

  /// Pre-flight duplicate check used by the Add/Edit form BEFORE the
  /// auth signup or staff-row update is attempted. Returns `true` if
  /// another staff row already uses the given value.
  ///
  /// [excludeId] is the staff's own id in edit mode, so editing your
  /// own row without changing the field isn't flagged as a duplicate.
  static Future<bool> isStaffFieldTaken({
    required String column,
    required String value,
    String? excludeId,
  }) async {
    var query = _client.from('staff').select('id').ilike(column, value);
    if (excludeId != null) {
      query = query.neq('id', excludeId);
    }
    final rows = await query;
    return (rows as List).isNotEmpty;
  }

  // ── Presence (online / offline / last seen) ─────────────────────────
  /// Stamps `staff.last_seen = now()` for the currently signed-in user.
  ///
  /// Uses the `update_last_seen` RPC (migration 0012) so the timestamp comes
  /// from the database clock, not the device clock — a wrong clock on a
  /// staff laptop can't fake presence. The function is scoped to
  /// `auth.uid()`, so it can only ever touch the caller's own row.
  static Future<void> updateMyLastSeen() async {
    await _client.rpc('update_last_seen');
  }

  /// Attendance stats for one staff member (used by the detail profile).
  static Future<Map<String, int>> getStaffAttendanceStats(
    String staffId,
  ) async {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    final monthStartIso = DateTime(
      startOfMonth.year,
      startOfMonth.month,
      startOfMonth.day,
    ).toIso8601String();

    final response = await _client
        .from('attendance')
        .select('punch_in, status')
        .eq('staff_id', staffId)
        .gte('punch_in', monthStartIso);

    final rows = List<Map<String, dynamic>>.from(response);
    int present = 0, late = 0, absent = 0;
    for (final r in rows) {
      switch (r['status'] as String?) {
        case 'present':
          present++;
        case 'late':
          late++;
        case 'absent':
          absent++;
      }
    }
    return {
      'total': rows.length,
      'present': present,
      'late': late,
      'absent': absent,
    };
  }

  static Future<Map<String, dynamic>?> getStaffRecord(String id) async {
    return _client
        .from('staff')
        .select('*, departments(name)')
        .eq('id', id)
        .maybeSingle();
  }

  // ── Staff: Add / Edit / Reset ────────────────────────────────────────

  /// Creates staff server-side without signing in or out on this device.
  ///
  /// [supabaseUrl] and [anonKey] come from AppConfig — passed in so the
  /// service stays testable.
  static Future<String> addStaff({
    required String supabaseUrl,
    required String anonKey,
    required String fullName,
    required String email,
    required String password,
    required String staffNumber,
    String? icNumber,
    String? departmentId,
    String? position,
    String? staffGrade,
    String? employmentStatus,
  }) async {
    final token = _client.auth.currentSession?.accessToken;
    if (token == null) {
      throw Exception('Please sign in with your admin account.');
    }
    final response = await http.post(
      Uri.parse('$supabaseUrl/functions/v1/create-staff'),
      headers: {
        'Authorization': 'Bearer $token',
        'apikey': anonKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'full_name': fullName.trim(),
        'email': email.trim(),
        'password': password,
        'staff_number': staffNumber,
        'ic_number': icNumber,
        'department_id': departmentId,
        'position': position,
        'staff_grade': staffGrade,
        'employment_status': employmentStatus,
      }),
    );
    if (response.statusCode == 404) {
      throw Exception(
        'The create-staff server function must be deployed before adding staff.',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200 || body['user_id'] is! String) {
      throw Exception(body['error'] ?? 'Staff creation failed.');
    }
    return body['user_id'] as String;
  }

  /// Updates an existing staff member's employment details.
  static Future<void> updateStaff({
    required String id,
    String? fullName,
    String? staffNumber,
    String? icNumber,
    String? departmentId,
    String? position,
    String? staffGrade,
    String? employmentStatus,
    bool? isActive,
  }) async {
    final updates = <String, dynamic>{};
    if (fullName != null) updates['full_name'] = fullName;
    if (staffNumber != null) updates['staff_number'] = staffNumber;
    updates['ic_number'] =
        icNumber; // nullable: always send so it can be cleared
    updates['department_id'] = departmentId; // nullable: dropdown can be empty
    updates['position'] = position;
    updates['staff_grade'] = staffGrade;
    updates['employment_status'] = employmentStatus;
    if (isActive != null) updates['is_active'] = isActive;

    await _client.from('staff').update(updates).eq('id', id);
  }

  /// Resets a staff member's password by calling the Edge Function.
  /// Requires the admin's access token for authorization.
  static Future<void> resetStaffPassword({
    required String supabaseUrl,
    required String anonKey,
    required String userId,
    required String newPassword,
  }) async {
    final adminToken = _client.auth.currentSession?.accessToken;
    if (adminToken == null) {
      throw Exception('Not authenticated.');
    }

    final response = await http.post(
      Uri.parse('$supabaseUrl/functions/v1/reset-staff-password'),
      headers: {
        'Authorization': 'Bearer $adminToken',
        'apikey': anonKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'user_id': userId, 'new_password': newPassword}),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'Failed to reset password.');
    }
  }

  /// Deletes a staff member permanently by calling the Edge Function.
  /// The auth user is removed with the service_role key server-side; the
  /// staff row, attendance and leaves cascade automatically.
  static Future<void> deleteStaff({
    required String supabaseUrl,
    required String anonKey,
    required String userId,
  }) async {
    final adminToken = _client.auth.currentSession?.accessToken;
    if (adminToken == null) {
      throw Exception('Not authenticated.');
    }

    final response = await http.post(
      Uri.parse('$supabaseUrl/functions/v1/delete-staff'),
      headers: {
        'Authorization': 'Bearer $adminToken',
        'apikey': anonKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'user_id': userId}),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'Failed to delete staff.');
    }
  }

  // ── Departments ─────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getDepartments() async {
    final response = await _client
        .from('departments')
        .select()
        .order('name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<void> addDepartment({
    required String name,
    String? code,
  }) async {
    await _client.from('departments').insert({
      'name': name,
      if (code != null && code.isNotEmpty) 'code': code,
    });
  }

  static Future<void> deleteDepartment(String id) async {
    await _client.from('departments').delete().eq('id', id);
  }

  /// Programs available for each Jabatan (department).
  /// Used to filter the Program dropdown in the Add/Edit Staff form:
  /// pick a Jabatan → show only programs under that department.
  static Future<List<Map<String, dynamic>>> getPrograms() async {
    final response = await _client
        .from('programs')
        .select('id, department_id, name, code')
        .order('name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<List<Map<String, dynamic>>> getStaffByDepartment(
    String departmentId,
  ) async {
    final response = await _client
        .from('staff')
        .select('id, full_name, staff_number, role')
        .eq('department_id', departmentId)
        .eq('is_active', true)
        .order('full_name', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  // ── Attendance (Punchcard) ───────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getMyAttendance({
    int limit = 30,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) return [];

    final response = await _client
        .from('attendance')
        .select()
        .eq('staff_id', user.id)
        .order('punch_in', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Attendance for a given month (1-12) of a year, for the current user.
  static Future<List<Map<String, dynamic>>> getMyAttendanceForMonth({
    required int year,
    required int month,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) return [];

    final start = DateTime(year, month, 1).toUtc().toIso8601String();
    final end = DateTime(year, month + 1, 1).toUtc().toIso8601String();

    final response = await _client
        .from('attendance')
        .select()
        .eq('staff_id', user.id)
        .gte('punch_in', start)
        .lt('punch_in', end)
        .order('punch_in', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  /// RLS-safe report records for one staff member over a Malaysia date range.
  /// Admins can request any staff member; regular staff can only read their own.
  static Future<List<Map<String, dynamic>>> getAttendanceForReport({
    required String staffId,
    required DateTime start,
    required DateTime end,
  }) async {
    final startUtc = DateTime.utc(
      start.year,
      start.month,
      start.day,
    ).subtract(const Duration(hours: 8));
    final endUtc = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).add(const Duration(days: 1)).subtract(const Duration(hours: 8));
    final response = await _client
        .from('attendance')
        .select('punch_in, punch_out, status, late_approved, late_reason')
        .eq('staff_id', staffId)
        .gte('punch_in', startUtc.toIso8601String())
        .lt('punch_in', endUtc.toIso8601String())
        .order('punch_in', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<List<Map<String, dynamic>>> getLeavesForReport({
    required String staffId,
    required DateTime start,
    required DateTime end,
  }) async {
    final startDate =
        '${start.year}-${start.month.toString().padLeft(2, '0')}-01';
    final endDate =
        '${end.year}-${end.month.toString().padLeft(2, '0')}-'
        '${end.day.toString().padLeft(2, '0')}';
    final response = await _client
        .from('leaves')
        .select('start_date, end_date, leave_type, status')
        .eq('staff_id', staffId)
        .eq('status', 'approved')
        .lte('start_date', endDate)
        .gte('end_date', startDate);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<Map<String, dynamic>> punchIn({
    required double latitude,
    required double longitude,
    String? geofenceZoneId,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    // Malaysia is UTC+8
    final nowUtc = DateTime.now().toUtc();
    final nowMy = nowUtc.add(const Duration(hours: 8));
    final localMinute = nowMy.hour * 60 + nowMy.minute;

    const openMinute = 5 * 60; // 05:00
    const lateMinute = 8 * 60; // 08:00 cutoff

    if (localMinute < openMinute) {
      throw Exception('Punch-in is only available after 05:00 AM (Malaysia).');
    }

    // Enforce one-punch-per-day client-side (DB also enforces via unique index)
    final existing = await _findTodayAttendance();
    if (existing != null) {
      throw Exception('You have already punched in today.');
    }

    final isLate = localMinute >= lateMinute;
    return _client
        .from('attendance')
        .insert({
          'staff_id': user.id,
          'punch_in': nowUtc.toIso8601String(),
          'punch_in_lat': latitude,
          'punch_in_lng': longitude,
          'geofence_zone_id': geofenceZoneId,
          'status': 'present',
          'late_approved': !isLate, // on-time punches auto-approved
        })
        .select()
        .single();
  }

  /// Returns the current user's attendance row for today (Malaysia day),
  /// or null if they haven't punched in yet.
  static Future<Map<String, dynamic>?> _findTodayAttendance() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final nowMy = DateTime.now().toUtc().add(const Duration(hours: 8));
    final startMy = DateTime.utc(nowMy.year, nowMy.month, nowMy.day);
    final startUtc = startMy.subtract(const Duration(hours: 8));
    final endUtc = startUtc.add(const Duration(days: 1));

    return _client
        .from('attendance')
        .select()
        .eq('staff_id', user.id)
        .gte('punch_in', startUtc.toIso8601String())
        .lt('punch_in', endUtc.toIso8601String())
        .maybeSingle();
  }

  /// Public alias — used by the PunchcardScreen to show today's status.
  static Future<Map<String, dynamic>?> getTodayAttendance() =>
      _findTodayAttendance();

  /// Staff submits a late reason. Sets `late_reason` on today's row.
  static Future<void> submitLateReason(String reason) async {
    final today = await _findTodayAttendance();
    if (today == null) {
      throw Exception('No punch-in record found for today.');
    }
    if (today['late_approved'] == true) {
      throw Exception('Your late punch has already been approved.');
    }
    if ((today['late_reason'] as String?)?.isNotEmpty ?? false) {
      throw Exception('You have already submitted a late reason.');
    }

    await _client
        .from('attendance')
        .update({'late_reason': reason})
        .eq('id', today['id']);
  }

  // ── Admin: late punch approvals (realtime) ──────────────────────────
  /// Realtime-updated list of late punches awaiting approval.
  /// Re-queries the full filtered set on every Realtime event so
  /// approved/rejected rows instantly disappear from the admin's list.
  static Stream<List<Map<String, dynamic>>> pendingLateApprovalsStream() {
    final realtimeStream = _client
        .from('attendance')
        .stream(primaryKey: ['id'])
        .eq('late_approved', false)
        .order('punch_in', ascending: false);

    return realtimeStream.asyncMap((_) => getPendingLateApprovals());
  }

  /// One-off fetch of late punches awaiting approval.
  static Future<List<Map<String, dynamic>>> getPendingLateApprovals() async {
    final response = await _client
        .from('attendance')
        .select(
          '*, staff:staff_id(full_name, staff_number, role, departments(name))',
        )
        .eq('late_approved', false)
        .order('punch_in', ascending: false);
    return List<Map<String, dynamic>>.from(response).where((r) {
      final reason = r['late_reason'] as String?;
      return reason != null && reason.isNotEmpty;
    }).toList();
  }

  /// Admin approves a late punch. Guards against double-approval.
  static Future<void> approveLate(String attendanceId) async {
    final current = await _client
        .from('attendance')
        .select('late_approved, late_reason')
        .eq('id', attendanceId)
        .maybeSingle();
    if (current == null) {
      throw Exception('This punch record no longer exists.');
    }
    if (current['late_approved'] == true) {
      throw Exception('Already approved.');
    }
    if ((current['late_reason'] as String?)?.isEmpty ?? true) {
      throw Exception('No late reason submitted for this record.');
    }

    await _client
        .from('attendance')
        .update({'late_approved': true, 'status': 'late'})
        .eq('id', attendanceId);
  }

  /// Admin rejects a late punch — deletes the row so staff can re-punch.
  static Future<void> rejectLate(String attendanceId) async {
    final current = await _client
        .from('attendance')
        .select('late_approved')
        .eq('id', attendanceId)
        .maybeSingle();
    if (current == null) {
      throw Exception('This punch record no longer exists.');
    }
    if (current['late_approved'] == true) {
      throw Exception('Already approved — cannot reject.');
    }

    await _client.from('attendance').delete().eq('id', attendanceId);
  }

  static Future<Map<String, dynamic>> punchOut({
    required double latitude,
    required double longitude,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    // Use Malaysia-day boundaries (consistent with punchIn)
    final nowMy = DateTime.now().toUtc().add(const Duration(hours: 8));
    final startUtc = DateTime.utc(
      nowMy.year,
      nowMy.month,
      nowMy.day,
    ).subtract(const Duration(hours: 8));
    final endUtc = startUtc.add(const Duration(days: 1));

    return _client
        .from('attendance')
        .update({
          'punch_out': DateTime.now().toUtc().toIso8601String(),
          'punch_out_lat': latitude,
          'punch_out_lng': longitude,
        })
        .eq('staff_id', user.id)
        .gte('punch_in', startUtc.toIso8601String())
        .lt('punch_in', endUtc.toIso8601String())
        .isFilter('punch_out', null) // don't overwrite an existing punch-out
        .select()
        .single();
  }

  // ── Leaves & Appeals ─────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getMyLeaves() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];

    final response = await _client
        .from('leaves')
        .select()
        .eq('staff_id', user.id)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<Map<String, dynamic>> submitLeave({
    required String leaveType,
    required DateTime startDate,
    required DateTime endDate,
    String? reason,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    return _client
        .from('leaves')
        .insert({
          'staff_id': user.id,
          'leave_type': leaveType,
          'start_date': startDate.toUtc().toIso8601String().substring(0, 10),
          'end_date': endDate.toUtc().toIso8601String().substring(0, 10),
          'reason': reason,
          'status': 'pending',
        })
        .select()
        .single();
  }

  // ── Announcements ────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getAnnouncements() async {
    final response = await _client
        .from('announcements')
        .select()
        .order('published_at', ascending: false)
        .limit(20);
    return List<Map<String, dynamic>>.from(response);
  }

  // ── Geofence Zones ──────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getGeofenceZones() async {
    final response = await _client.from('geofence_zones').select();
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<void> addGeofenceZone({
    required String name,
    required double centerLat,
    required double centerLng,
    required int radiusM,
  }) async {
    await _client.from('geofence_zones').insert({
      'name': name,
      'center_lat': centerLat,
      'center_lng': centerLng,
      'radius_m': radiusM,
      'is_active': true,
    });
  }

  static Future<void> setGeofenceZoneActive(String id, bool isActive) async {
    await _client
        .from('geofence_zones')
        .update({'is_active': isActive})
        .eq('id', id);
  }

  static Future<void> deleteGeofenceZone(String id) async {
    await _client.from('geofence_zones').delete().eq('id', id);
  }

  // ── Admin overview stats ────────────────────────────────────────────
  static Future<int> getTotalStaffCount() async {
    // Count only regular staff (exclude admins, who don't punch in)
    final response = await _client
        .from('staff')
        .select('id')
        .eq('is_active', true)
        .eq('role', 'staff');
    return (response as List).length;
  }

  static Future<int> getPresentTodayCount() async {
    final nowMy = DateTime.now().toUtc().add(const Duration(hours: 8));
    final startUtc = DateTime.utc(
      nowMy.year,
      nowMy.month,
      nowMy.day,
    ).subtract(const Duration(hours: 8));
    final endUtc = startUtc.add(const Duration(days: 1));

    // Only count punches by regular staff (not admins) that are approved:
    //   - on-time punches (late_approved = true, status = 'present')
    //   - approved late punches (late_approved = true, status = 'late')
    // Late punches still awaiting admin approval (late_approved = false)
    // are NOT counted as present.
    final response = await _client
        .from('attendance')
        .select('staff_id, staff:staff_id(role)')
        .eq('late_approved', true)
        .eq('staff.role', 'staff')
        .gte('punch_in', startUtc.toIso8601String())
        .lt('punch_in', endUtc.toIso8601String());
    final staffIds = (response as List)
        .map((r) => r['staff_id'] as String)
        .toSet();
    return staffIds.length;
  }

  static Future<int> getPendingLeavesCount() async {
    final response = await _client
        .from('leaves')
        .select('id')
        .eq('status', 'pending');
    return (response as List).length;
  }

  // ── Admin: today's attendance list ──────────────────────────────────
  /// Returns today's attendance rows (Malaysia day) joined with the
  /// staff name, so the admin dashboard can show who punched in/out.
  static Future<List<Map<String, dynamic>>> getTodayAttendanceList() async {
    final nowMy = DateTime.now().toUtc().add(const Duration(hours: 8));
    return getAttendanceListForDate(
      year: nowMy.year,
      month: nowMy.month,
      day: nowMy.day,
    );
  }

  /// Returns attendance rows for a specific Malaysia calendar date,
  /// joined with the staff name + department.
  static Future<List<Map<String, dynamic>>> getAttendanceListForDate({
    required int year,
    required int month,
    required int day,
  }) async {
    // Malaysia day boundaries → UTC
    final startMy = DateTime.utc(year, month, day);
    final startUtc = startMy.subtract(const Duration(hours: 8));
    final endUtc = startUtc.add(const Duration(days: 1));

    final response = await _client
        .from('attendance')
        .select(
          'id, punch_in, punch_out, status, late_approved, late_reason, '
          'staff:staff_id(full_name, staff_number, role, departments(name))',
        )
        .gte('punch_in', startUtc.toIso8601String())
        .lt('punch_in', endUtc.toIso8601String())
        .order('punch_in', ascending: true);
    return List<Map<String, dynamic>>.from(response);
  }

  // ── Admin: pending approvals (leaves + attendance appeals) ──────────
  static Future<List<Map<String, dynamic>>> getPendingLeaves() async {
    final response = await _client
        .from('leaves')
        .select(
          '*, staff:staff_id(full_name, staff_number, role, departments(name))',
        )
        .eq('status', 'pending')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<List<Map<String, dynamic>>>
  getPendingAttendanceAppeals() async {
    final response = await _client
        .from('attendance')
        .select(
          '*, staff:staff_id(full_name, staff_number, role, departments(name))',
        )
        .eq('appeal_status', 'pending')
        .order('punch_in', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  static Future<void> approveLeave(String leaveId, String reviewerNote) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client
        .from('leaves')
        .update({
          'status': 'approved',
          'reviewed_by': user.id,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'reviewer_note': reviewerNote,
        })
        .eq('id', leaveId);
  }

  static Future<void> rejectLeave(String leaveId, String reviewerNote) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client
        .from('leaves')
        .update({
          'status': 'rejected',
          'reviewed_by': user.id,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'reviewer_note': reviewerNote,
        })
        .eq('id', leaveId);
  }

  static Future<void> approveAttendanceAppeal(
    String attendanceId,
    String note,
  ) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client
        .from('attendance')
        .update({
          'appeal_status': 'approved',
          'reviewed_by': user.id,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'notes': note,
        })
        .eq('id', attendanceId);
  }

  static Future<void> rejectAttendanceAppeal(
    String attendanceId,
    String note,
  ) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    await _client
        .from('attendance')
        .update({
          'appeal_status': 'rejected',
          'reviewed_by': user.id,
          'reviewed_at': DateTime.now().toUtc().toIso8601String(),
          'notes': note,
        })
        .eq('id', attendanceId);
  }

  // ── Staff profile stats ─────────────────────────────────────────────
  static Future<Map<String, int>> getMySemesterStats({DateTime? since}) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      return {'present': 0, 'late': 0, 'absent': 0, 'leave': 0};
    }

    final fromDate = (since ?? DateTime(DateTime.now().year, 1, 1))
        .toUtc()
        .toIso8601String();

    final response = await _client
        .from('attendance')
        .select('status')
        .eq('staff_id', user.id)
        .gte('punch_in', fromDate);

    int present = 0, late = 0, absent = 0, leave = 0;
    for (final row in response as List) {
      switch (row['status'] as String?) {
        case 'present':
          present++;
          break;
        case 'late':
          late++;
          break;
        case 'absent':
          absent++;
          break;
        case 'leave':
          leave++;
          break;
      }
    }
    return {'present': present, 'late': late, 'absent': absent, 'leave': leave};
  }

  // ── Generic helpers ──────────────────────────────────────────────────
  static PostgrestFilterBuilder selectFrom(String table) =>
      _client.from(table).select();
}
