import 'package:fl_clash/qf/qf_owner.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

class _RecordedCall {
  _RecordedCall(this.method, this.path, this.body);

  final String method;
  final String path;
  final Map<String, dynamic>? body;
}

/// Stands in for the owner API: serves the user-detail payloads the page
/// asks for and records every write so the test can inspect the exact
/// body a sensitive action sent.
class _FakeOwnerSession extends QfSessionController {
  final List<_RecordedCall> calls = [];

  @override
  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    calls.add(_RecordedCall(method, path, body));
    if (path.endsWith('/basic')) {
      return {
        'nickname': '目标用户',
        'username': 'targetuser1',
        'emailMasked': 't***@example.com',
        'status': 'active',
        'createdAt': 1700000000,
        'googleBound': false,
        'passwordFrozen': false,
      };
    }
    if (path.endsWith('/view-email')) {
      return {'email': 'target@example.com'};
    }
    return {};
  }
}

void main() {
  testWidgets('sensitive action runs on confirm alone, no password prompt', (
    tester,
  ) async {
    final session = _FakeOwnerSession();
    await tester.pumpWidget(
      TestApp(child: QfOwnerUserPage(session: session, userId: 7)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('查看完整邮箱'), findsOneWidget);

    await tester.tap(find.text('查看完整邮箱'));
    await tester.pump();
    // The only dialog is the confirmation (object + consequence).
    expect(find.text('确认无误，继续'), findsOneWidget);
    expect(find.text('身份核验'), findsNothing);

    await tester.tap(find.text('确认无误，继续'));
    await tester.pump();
    await tester.pump();

    // No password/passkey step appeared at any point, and the action
    // executed with exactly the confirm marker and nothing else.
    expect(find.text('身份核验'), findsNothing);
    expect(find.text('登录密码'), findsNothing);
    final post = session.calls.firstWhere(
      (call) => call.method == 'POST' && call.path.endsWith('/view-email'),
    );
    expect(post.body, {'confirm': true});
    expect(find.text('完整邮箱'), findsOneWidget);
    expect(find.text('target@example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the confirmation sends nothing', (tester) async {
    final session = _FakeOwnerSession();
    await tester.pumpWidget(
      TestApp(child: QfOwnerUserPage(session: session, userId: 7)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('查看完整邮箱'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pump();

    expect(session.calls.where((call) => call.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
