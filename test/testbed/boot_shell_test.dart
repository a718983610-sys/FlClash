import 'package:fl_clash/boot_shell.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the shell shows the skeleton until the gate lands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final gate = BootGate();
    await tester.pumpWidget(BootShell(gate: gate));
    expect(find.byType(BootSkeletonPage), findsOneWidget);

    gate.show(const MaterialApp(home: Text('landed')));
    await tester.pump();
    expect(find.byType(BootSkeletonPage), findsNothing);
    expect(find.text('landed'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
