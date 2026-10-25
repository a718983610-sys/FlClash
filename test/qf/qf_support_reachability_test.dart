import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_recovery.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Support reachability (2.0.0): the smart-support entry must exist
// before login, on the rejection landing spots (ban/frozen), not only
// inside the signed-in app.
class _ReachSession extends QfSessionController {
  _ReachSession() {
    mode = QfMode.entry;
  }

  @override
  Future<Map<String, dynamic>> guestSupportSession() async {
    return {'sessionId': 'g-1', 'messages': const []};
  }
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('entry page shows a smart-support entry before login', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        QfEntryPage(
          session: _ReachSession(),
          onAbout: () {},
          onCheckUpdate: () {},
          onAgreement: () {},
          onSupport: () => taps++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('qf-entry-support'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    expect(taps, 1);
  });

  testWidgets('ban dialog offers smart support and opens the page', (
    tester,
  ) async {
    final session = _ReachSession();
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => qfShowBanDialog(
              context,
              session: session,
              data: const {'permanent': true},
              account: 'tester123',
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final support = find.byKey(const ValueKey('qf-ban-support'));
    expect(support, findsOneWidget);
    await tester.tap(support);
    await tester.pumpAndSettle();
    expect(find.byType(QfSupportPage), findsOneWidget);
    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('frozen dialog offers smart support as an action', (
    tester,
  ) async {
    QfFrozenAction? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await qfShowFrozenDialog(context, message: '登录失败次数过多');
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final support = find.byKey(const ValueKey('qf-frozen-support'));
    expect(support, findsOneWidget);
    await tester.tap(support);
    await tester.pumpAndSettle();
    expect(result, QfFrozenAction.support);
  });
}
