import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvet_staff_app/screens/auth/login_page.dart';

void main() {
  Future<void> openLogin(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('Rejects empty and malformed credentials before authentication', (
    tester,
  ) async {
    await openLogin(tester);
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter your email address'), findsOneWidget);
    expect(find.text('Please enter your password'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'staff-id');
    await tester.pumpAndSettle();
    expect(find.text('Please enter a valid email address'), findsOneWidget);
  });

  testWidgets('Password visibility and account help are usable', (
    tester,
  ) async {
    await openLogin(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isFalse,
    );
    await tester.ensureVisible(find.text('Forgot Password?'));
    await tester.tap(find.text('Forgot Password?'));
    await tester.pumpAndSettle();
    expect(find.text('Need help signing in?'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Small screens with enlarged text can scroll to sign in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const LoginPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in'));
    expect(tester.takeException(), isNull);
    expect(find.text('Sign in').hitTestable(), findsOneWidget);
  });
}
