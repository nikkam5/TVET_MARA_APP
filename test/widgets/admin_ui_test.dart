import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvet_staff_app/widgets/admin/admin_ui.dart';

void main() {
  for (final width in [375.0, 1440.0]) {
    testWidgets('Admin workspace adapts to ${width.toInt()}px', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: AdminPage(
            title: 'Staff directory',
            subtitle: 'Your people, in one place. Manage profiles and access.',
            action: FilledButton.icon(
              onPressed: () => tapped = true,
              icon: const Icon(Icons.add),
              label: const Text('Add staff'),
            ),
            body: ListView.builder(
              itemCount: 30,
              itemBuilder: (_, index) =>
                  ListTile(title: Text('Staff member $index')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Add staff'));
      expect(tapped, isTrue);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Staff directory'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
