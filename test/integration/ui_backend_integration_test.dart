import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tvet_staff_app/screens/admin/admin_dashboard.dart';
import 'package:tvet_staff_app/screens/admin/approval_center_screen.dart';
import 'package:tvet_staff_app/screens/admin/attendance_list_screen.dart';
import 'package:tvet_staff_app/screens/admin/departments_screen.dart';
import 'package:tvet_staff_app/screens/admin/geofence_zones_screen.dart';
import 'package:tvet_staff_app/screens/admin/system_reports_screen.dart';
import 'package:tvet_staff_app/screens/admin/staff_directory_screen.dart';
import 'package:tvet_staff_app/screens/auth/login_page.dart';
import 'package:tvet_staff_app/screens/staff/staff_dashboard.dart';
import 'package:tvet_staff_app/services/auth_service.dart';
import 'package:tvet_staff_app/services/database_service.dart';
import 'package:tvet_staff_app/services/presence_service.dart';
import 'package:tvet_staff_app/services/task_service.dart';
import 'package:tvet_staff_app/services/reports/attendance_report_pdf_service.dart';
import 'package:tvet_staff_app/models/attendance_report.dart';
import 'package:tvet_staff_app/utils/malaysia_time.dart';
import 'package:tvet_staff_app/widgets/staff/scrollable_bottom_nav.dart';
import 'package:tvet_staff_app/widgets/admin/staff_directory_card.dart';

const staffId = '11111111-1111-4111-8111-111111111111';

class _MemoryPkceStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}

/// All requests in these tests use an in-memory backend, never the live project.
class _Backend {
  String role = 'staff';
  bool active = true;
  bool failDepartments = false;
  final requests = <http.Request>[];
  Map<String, dynamic> metadata = {};
  List<Map<String, dynamic>> attendance = [];
  List<Map<String, dynamic>> leaves = [];

  Map<String, dynamic> get user => {
    'id': staffId,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': 'test@example.com',
    'app_metadata': {},
    'user_metadata': metadata,
    'created_at': '2026-01-01T00:00:00Z',
  };

  Map<String, dynamic> get profile => {
    'id': staffId,
    'full_name': 'Test Staff',
    'staff_number': 'S001',
    'email': 'test@example.com',
    'ic_number': '',
    'department_id': 'department-1',
    'departments': {'id': 'department-1', 'name': 'Technology'},
    'position': 'PPP',
    'staff_grade': 'DG9',
    'employment_status': 'TETAP',
    'role': role,
    'is_active': active,
    'created_at': DateTime.now()
        .subtract(const Duration(days: 10))
        .toIso8601String(),
  };

  http.Response json(Object? data, {int status = 200}) => http.Response(
    jsonEncode(data),
    status,
    request: requests.isEmpty ? null : requests.last,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/token')) {
      final payload = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'sub': staffId,
                'exp':
                    DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch ~/
                    1000,
              }),
            ),
          )
          .replaceAll('=', '');
      return json({
        'access_token': 'e30.$payload.test',
        'refresh_token': 'test-refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': user,
      });
    }
    if (path.endsWith('/auth/v1/user')) {
      if (request.method == 'PUT') {
        metadata = {
          ...metadata,
          ...Map<String, dynamic>.from(jsonDecode(request.body)['data'] as Map),
        };
      }
      return json(user);
    }
    if (path.endsWith('/logout')) return json({});
    if (path.contains('/rpc/')) return json(null);
    if (path.endsWith('/staff')) {
      if (request.method == 'PATCH') return json({'id': staffId});
      if (request.url.queryParameters.containsKey('id') &&
          !(request.url.queryParameters['id'] ?? '').startsWith('neq.')) {
        return json(profile);
      }
      return json([profile]);
    }
    if (path.endsWith('/departments')) {
      if (failDepartments) {
        return json({
          'message': 'Connection failed',
          'code': 'TEST',
        }, status: 503);
      }
      return json([
        {'id': 'department-1', 'name': 'Technology', 'code': 'TECH'},
      ]);
    }
    if (path.endsWith('/attendance')) {
      if (request.method == 'PATCH' || request.method == 'DELETE') {
        return json({'id': 'attendance-1'});
      }
      var rows = attendance;
      final query = request.url.queryParameters;
      if (query['late_approved'] == 'eq.false') {
        rows = rows.where((r) => r['late_approved'] == false).toList();
      }
      if (query['late_approved'] == 'eq.true') {
        rows = rows.where((r) => r['late_approved'] == true).toList();
      }
      if (query['appeal_status'] == 'eq.pending') {
        rows = rows.where((r) => r['appeal_status'] == 'pending').toList();
      }
      final object = (request.headers['accept'] ?? '').contains('object');
      return json(object ? (rows.isEmpty ? null : rows.first) : rows);
    }
    if (path.endsWith('/leaves') && request.method == 'POST') {
      return json({
        'id': 'leave-1',
        ...Map<String, dynamic>.from(jsonDecode(request.body) as Map),
      });
    }
    if (path.endsWith('/leaves')) {
      if (request.method == 'PATCH') return json({'id': 'leave-1'});
      final status = request.url.queryParameters['status'];
      return json(
        leaves
            .where(
              (row) =>
                  status == null ||
                  status == 'in.(pending,approved)' ||
                  status == 'eq.${row['status']}',
            )
            .toList(),
      );
    }
    return json([]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Backend backend;

  setUp(() async {
    backend = _Backend();
    await Supabase.initialize(
      url: 'https://tvet-test.invalid',
      publishableKey: 'test-public-key',
      httpClient: MockClient(backend.handle),
      debug: false,
      realtimeClientOptions: RealtimeClientOptions(
        timeout: const Duration(milliseconds: 20),
        transport: (_, _) =>
            throw StateError('Realtime sockets are disabled in mock tests'),
      ),
      authOptions: FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        authFlowType: AuthFlowType.implicit,
        localStorage: const EmptyLocalStorage(),
        pkceAsyncStorage: _MemoryPkceStorage(),
      ),
    );
    await AuthService.signIn(
      email: 'test@example.com',
      password: 'test-password',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async => switch (call.method) {
            'isLocationServiceEnabled' => true,
            'checkPermission' || 'requestPermission' => 2,
            _ => null,
          },
        );
  });

  tearDown(() async {
    PresenceService.stop();
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          null,
        );
  });

  test(
    'employment edits use the working position, grade and employment columns',
    () async {
      await DatabaseService.updateStaff(
        id: staffId,
        fullName: 'Updated Staff',
        staffNumber: 'S001',
        position: 'PPP',
        staffGrade: 'DG10',
        employmentStatus: 'KONTRAK',
        isActive: true,
      );
      final request = backend.requests.lastWhere((r) => r.method == 'PATCH');
      final body = jsonDecode(request.body) as Map;
      expect(body['position'], 'PPP');
      expect(body['staff_grade'], 'DG10');
      expect(body['employment_status'], 'KONTRAK');
      expect(body['ic_number'], '');
      expect(body.containsKey('teaching_course'), isFalse);
    },
  );

  test(
    'staff creation uses the Edge Function and leaves the admin session intact',
    () async {
      final currentUser = AuthService.currentUser!.id;
      late http.Request call;
      await http.runWithClient(
        () async {
          final id = await DatabaseService.addStaff(
            supabaseUrl: 'https://tvet-test.invalid',
            anonKey: 'public',
            fullName: 'New Staff',
            email: 'new@example.com',
            password: 'test-password',
            staffNumber: 'S002',
            position: 'PPP',
            staffGrade: 'DG9',
            employmentStatus: 'TETAP',
          );
          expect(id, 'new-staff');
        },
        () => MockClient((request) async {
          call = request;
          return backend.json({'user_id': 'new-staff'});
        }),
      );
      expect(call.url.path, '/functions/v1/create-staff');
      expect(call.headers['authorization'], startsWith('Bearer '));
      expect(jsonDecode(call.body)['position'], 'PPP');
      expect(AuthService.currentUser!.id, currentUser);
    },
  );

  test(
    'HTTP server failures stay readable instead of causing JSON errors',
    () async {
      await http.runWithClient(
        () async {
          await expectLater(
            DatabaseService.resetStaffPassword(
              supabaseUrl: 'https://tvet-test.invalid',
              anonKey: 'public',
              userId: staffId,
              newPassword: 'test-password',
            ),
            throwsA(predicate((e) => e.toString().contains('HTTP 502'))),
          );
        },
        () => MockClient(
          (_) async => http.Response('<html>Bad gateway</html>', 502),
        ),
      );
    },
  );

  test(
    'report and leave date ranges use Malaysia boundaries and exact date-only values',
    () async {
      await DatabaseService.getAttendanceForReport(
        staffId: staffId,
        start: DateTime(2026, 8, 23),
        end: DateTime(2026, 8, 27),
      );
      final attendance = backend.requests.last.url.query;
      expect(
        Uri.decodeComponent(attendance),
        contains('gte.2026-08-22T16:00:00.000Z'),
      );
      await DatabaseService.getLeavesForReport(
        staffId: staffId,
        start: DateTime(2026, 8, 23),
        end: DateTime(2026, 8, 27),
      );
      expect(
        backend.requests.last.url.queryParameters['end_date'],
        'gte.2026-08-23',
      );
      await DatabaseService.submitLeave(
        leaveType: 'annual',
        startDate: DateTime(2026, 8, 23),
        endDate: DateTime(2026, 8, 24),
        reason: 'Test',
      );
      final leave = jsonDecode(backend.requests.last.body);
      expect(leave['start_date'], '2026-08-23');
      expect(leave['end_date'], '2026-08-24');
    },
  );

  test('inactive accounts cannot obtain a dashboard role', () async {
    backend.active = false;
    await expectLater(
      AuthService.getCurrentRole(),
      throwsA(isA<AuthException>()),
    );
    expect(AuthService.currentUser, isNull);
  });

  test(
    'personal tasks persist on the staff account rather than global sample memory',
    () async {
      expect(await TaskService.getMyTasks(), isEmpty);
      final task = await TaskService.addTask(
        title: 'Prepare workshop',
        dueAt: DateTime(2026, 10, 1, 17),
      );
      expect((await TaskService.getMyTasks()).single.title, 'Prepare workshop');
      await TaskService.setProgress(task.id, 1);
      expect((await TaskService.getMyTasks()).single.isDone, isTrue);
      expect(backend.metadata['personal_tasks'], hasLength(1));
    },
  );

  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'staff login opens the redesigned four-tab UI at ${width.toInt()}px',
      (tester) async {
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 4));
          await tester.runAsync(
            () => Supabase.instance.client.removeAllChannels(),
          );
        });
        tester.view.physicalSize = Size(width, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const MaterialApp(home: LoginPage()));
        await tester.enterText(
          find.byType(TextFormField).first,
          'test@example.com',
        );
        await tester.enterText(
          find.byType(TextFormField).last,
          'test-password',
        );
        await tester.ensureVisible(find.text('Sign in'));
        await tester.tap(find.text('Sign in'));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(StaffDashboard), findsOneWidget);
        expect(find.text('Live attendance'), findsOneWidget);
        expect(find.byType(ScrollableBottomNav), findsOneWidget);
        for (final tab in ['Tasks', 'Attendance', 'Profile']) {
          final tabFinder = find.descendant(
            of: find.byType(ScrollableBottomNav),
            matching: find.text(tab),
          );
          await tester.tap(tabFinder);
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(tester.takeException(), isNull, reason: 'Failed on $tab');
        }
        expect(find.text('JAWATAN'), findsOneWidget);
        expect(find.text('PPP'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 4));
      },
    );

    testWidgets(
      'admin login opens the new dashboard and directory at ${width.toInt()}px',
      (tester) async {
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 4));
          await tester.runAsync(
            () => Supabase.instance.client.removeAllChannels(),
          );
        });
        backend.role = 'admin';
        tester.view.physicalSize = Size(width, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const MaterialApp(home: LoginPage()));
        await tester.enterText(
          find.byType(TextFormField).first,
          'test@example.com',
        );
        await tester.enterText(
          find.byType(TextFormField).last,
          'test-password',
        );
        await tester.ensureVisible(find.text('Sign in'));
        await tester.tap(find.text('Sign in'));
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(AdminDashboard), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: const Scaffold(body: StaffDirectoryScreen()),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('All Staff'), findsOneWidget);
        expect(find.byType(StaffDirectoryCard), findsOneWidget);
        await tester.tap(find.text('Edit').first);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Jawatan'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 4));
      },
    );
  }

  test(
    'pending late check-ins cannot check out and approvals use the existing columns',
    () async {
      final now = MalaysiaTime.now();
      backend.attendance = [
        {
          'id': 'attendance-1',
          'staff_id': staffId,
          'punch_in': DateTime.utc(
            now.year,
            now.month,
            now.day,
            0,
            30,
          ).toIso8601String(),
          'punch_out': null,
          'status': 'present',
          'late_approved': false,
          'late_reason': 'Traffic',
        },
      ];
      await expectLater(
        DatabaseService.punchOut(latitude: 5, longitude: 102),
        throwsA(
          predicate((error) => error.toString().contains('must be approved')),
        ),
      );
      expect(backend.requests.where((r) => r.method == 'PATCH'), isEmpty);
      await DatabaseService.approveLate('attendance-1');
      final approval = jsonDecode(backend.requests.last.body);
      expect(approval['late_approved'], isTrue);
      expect(approval['status'], 'late');
    },
  );

  test(
    'medical requests and emergency leave stay separate without duplicate late approval entries',
    () async {
      backend.leaves = [
        {'id': 'medical-1', 'leave_type': 'sick', 'status': 'pending'},
        {'id': 'emergency-1', 'leave_type': 'emergency', 'status': 'pending'},
      ];
      backend.attendance = [
        {
          'id': 'appeal-1',
          'late_approved': false,
          'appeal_status': 'pending',
          'late_reason': 'Traffic',
        },
        {
          'id': 'late-1',
          'late_approved': false,
          'appeal_status': null,
          'late_reason': 'Traffic',
        },
      ];
      final queue = await DatabaseService.getPendingApprovals();
      expect(queue.medicalCertificates.single['id'], 'medical-1');
      expect(queue.leaveRequests.single['id'], 'emergency-1');
      expect(queue.lateAppeals.single['id'], 'appeal-1');
      expect(queue.latePunches.single['id'], 'late-1');
      await DatabaseService.approveLeave('medical-1', 'Reviewed');
      final decision = jsonDecode(backend.requests.last.body);
      expect(decision['status'], 'approved');
      expect(decision['reviewed_by'], staffId);
    },
  );

  test('PDF reports build offline with the bundled fonts', () async {
    final now = MalaysiaTime.now();
    final report = AttendanceReportCalculator.calculate(
      staff: backend.profile,
      attendance: const [],
      leaves: const [],
      periodStart: DateTime(now.year, now.month, 1),
      periodEnd: DateTime(now.year, now.month, now.day),
    );
    final pdf = await AttendanceReportPdfService.build(
      reports: [report],
      periodLabel: 'Current month',
    );
    expect(utf8.decode(pdf.take(4).toList()), '%PDF');
    expect(pdf.length, greaterThan(1000));
  });

  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'remaining admin pages use live-data UI at ${width.toInt()}px',
      (tester) async {
        backend.role = 'admin';
        tester.view.physicalSize = Size(width, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 4));
          await tester.runAsync(
            () => Supabase.instance.client.removeAllChannels(),
          );
        });
        final pages = <Widget>[
          const ApprovalCenterScreen(),
          const AttendanceListScreen(),
          const DepartmentsScreen(),
          const GeofenceZonesScreen(),
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SystemReportsScreen(
                staff: [
                  {...backend.profile, 'role': 'staff'},
                ],
                departments: const [
                  {'id': 'department-1', 'name': 'Technology'},
                ],
                weekAttendance: const [
                  (label: 'Sun', inOffice: 0, remote: 0, late: 0),
                ],
                presentToday: const {},
                lateToday: const {},
                pendingApprovals: 0,
                lastUpdated: null,
              ),
            ),
          ),
        ];
        for (final page in pages) {
          await tester.pumpWidget(
            MaterialApp(
              key: UniqueKey(),
              home: Scaffold(body: page),
            ),
          );
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            tester.takeException(),
            isNull,
            reason: 'Failed on ${page.runtimeType}',
          );
        }
      },
    );
    testWidgets(
      'Add Staff shortcut opens a modal on the first directory visit at ${width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 4));
          await tester.runAsync(
            () => Supabase.instance.client.removeAllChannels(),
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: const Scaffold(
              body: StaffDirectoryScreen(addStaffRequest: 1),
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Create Staff'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    '08:00 Malaysia cutoff includes the exact minute and UTC day rollover',
    () {
      expect(MalaysiaTime.isLate(DateTime.utc(2026, 8, 23, 0)), isTrue);
      expect(
        MalaysiaTime.isLate(DateTime.utc(2026, 8, 22, 23, 59, 59)),
        isFalse,
      );
      expect(MalaysiaTime.parse('2026-08-22T23:55:00Z')!.day, 23);
    },
  );
}
