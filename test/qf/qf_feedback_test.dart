import 'dart:async';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_google.dart';
import 'package:fl_clash/qf/qf_http_client.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_passkey.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLoginSession extends QfSessionController {
  _FakeLoginSession() {
    mode = QfMode.entry;
    serverBaseUrl = 'http://127.0.0.1:1';
  }

  Object? loginError;
  Completer<void>? loginGate;

  @override
  Future<QfLoginOutcome> login({
    required String emailInput,
    required String password,
    String? emailCode,
    bool remember = true,
  }) async {
    final gate = loginGate;
    if (gate != null) await gate.future;
    final error = loginError;
    if (error != null) throw error;
    return const QfLoginOutcome();
  }
}

void main() {
  group('auth failure classification (F-01)', () {
    test('network failure maps to the approved unreachable copy', () {
      QfHttpClient.lastDecision = const QfProxyDecision(
        'PROXY 127.0.0.1:7890',
        QfProxySource.core,
      );
      const error = QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
      final failure = qfClassifyAuthError(error);
      expect(failure.kind, QfFailureKind.network);
      expect(failure.message, QfCopy.networkAccountUnreachable);
      final guestFailure = qfClassifyAuthError(error, guest: true);
      expect(guestFailure.kind, QfFailureKind.network);
      expect(guestFailure.message, QfCopy.networkGuestUnreachable);
    });

    test('credential failures are their own kind with the server text', () {
      const byStatus = QfApiException(401, 'UNAUTHORIZED', '登录已过期');
      expect(qfClassifyAuthError(byStatus).kind, QfFailureKind.credential);
      const byCode = QfApiException(400, 'BAD_CREDENTIALS', '邮箱或密码不正确');
      final failure = qfClassifyAuthError(byCode);
      expect(failure.kind, QfFailureKind.credential);
      expect(failure.message, '邮箱或密码不正确');
    });

    test('business rejection keeps the server message', () {
      const error = QfApiException(429, 'TOO_FREQUENT', '操作过于频繁，请稍后再试');
      final failure = qfClassifyAuthError(error);
      expect(failure.kind, QfFailureKind.rejected);
      expect(failure.message, '操作过于频繁，请稍后再试');
    });

    test('not configured is unsupported with the approved hint', () {
      const error = QfApiException(
        0,
        'NOT_CONFIGURED',
        QfCopy.googleNotConfiguredHint,
      );
      final failure = qfClassifyAuthError(error);
      expect(failure.kind, QfFailureKind.unsupported);
      expect(failure.message, QfCopy.googleNotConfiguredHint);
    });

    test('passkey and google cancellations classify as cancelled', () {
      expect(
        qfClassifyAuthError(const QfPasskeyException('通行密钥验证已取消。')).kind,
        QfFailureKind.cancelled,
      );
      expect(
        qfClassifyAuthError(
          const QfPasskeyException('当前设备不支持通行密钥，请改用密码方式。'),
        ).kind,
        QfFailureKind.unsupported,
      );
      expect(
        qfClassifyAuthError(const QfGoogleAuthException('已取消谷歌登录。')).kind,
        QfFailureKind.cancelled,
      );
    });

    test('unknown errors get the actionable fallback, never raw text', () {
      final failure = qfClassifyAuthError(Exception('socket exploded #42'));
      expect(failure.kind, QfFailureKind.unknown);
      expect(failure.message, QfCopy.actionFailedRetry);
      expect(failure.message, isNot(contains('socket exploded')));
    });
  });

  group('action button feedback (F-01)', () {
    testWidgets('busy state is immediate and locks only itself', (
      tester,
    ) async {
      final gate = Completer<void>();
      var siblingTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                QfActionButton(
                  label: '主按钮',
                  busyLabel: '正在处理……',
                  onAction: () => gate.future,
                ),
                QfActionButton(
                  label: '旁按钮',
                  filled: false,
                  onAction: () async {
                    siblingTaps++;
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, '主按钮'));
      await tester.pump();
      expect(find.byType(CommonCircleLoading), findsOneWidget);
      expect(find.text('正在处理……'), findsOneWidget);
      final sibling = find.widgetWithText(OutlinedButton, '旁按钮');
      expect(tester.widget<OutlinedButton>(sibling).onPressed, isNotNull);
      await tester.tap(sibling);
      await tester.pump();
      expect(siblingTaps, 1);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(CommonCircleLoading), findsNothing);
      expect(find.text('主按钮'), findsOneWidget);
    });

    testWidgets('failure is presented inline by category', (tester) async {
      QfHttpClient.lastDecision = const QfProxyDecision(
        'PROXY 127.0.0.1:7890',
        QfProxySource.core,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QfActionButton(
              label: '提交',
              onAction: () async {
                throw const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, '提交'));
      await tester.pump();
      await tester.pump();
      expect(find.text(QfCopy.networkAccountUnreachable), findsOneWidget);
      final button = find.widgetWithText(FilledButton, '提交');
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    });

    testWidgets('unknown failure shows the actionable fallback', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QfActionButton(
              label: '提交',
              onAction: () async {
                throw Exception('raw boom');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, '提交'));
      await tester.pump();
      await tester.pump();
      expect(find.text(QfCopy.actionFailedRetry), findsOneWidget);
      expect(find.textContaining('raw boom'), findsNothing);
    });
  });

  group('login form feedback wiring (F-01)', () {
    Future<void> pumpForm(WidgetTester tester, _FakeLoginSession session) {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QfLoginForm(session: session)),
        ),
      );
    }

    testWidgets('network failure lands inline under the login button', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final session = _FakeLoginSession()
        ..loginError = const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
      await pumpForm(tester, session);
      await tester.pump();
      // 表单初始化的清单刷新会按宿主环境重算代理决策，点前再钉直连决策。
      QfHttpClient.lastDecision = const QfProxyDecision(
        'DIRECT',
        QfProxySource.direct,
      );
      await tester.enterText(find.byType(TextField).at(0), 'a@b.c');
      await tester.enterText(find.byType(TextField).at(1), 'password123');
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pump();
      await tester.pump();
      expect(find.text(QfCopy.networkAccountNeedsProxy), findsOneWidget);
    });

    testWidgets('bad credentials land on the password field', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = _FakeLoginSession()
        ..loginError = const QfApiException(
          400,
          'BAD_CREDENTIALS',
          '邮箱或密码不正确，请重新输入',
        );
      await pumpForm(tester, session);
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), 'a@b.c');
      await tester.enterText(find.byType(TextField).at(1), 'wrong-password');
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pump();
      await tester.pump();
      expect(find.text('邮箱或密码不正确，请重新输入'), findsOneWidget);
    });

    testWidgets('a pending login shows progress and leaves google usable', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final session = _FakeLoginSession()..loginGate = Completer<void>();
      await pumpForm(tester, session);
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), 'a@b.c');
      await tester.enterText(find.byType(TextField).at(1), 'password123');
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pump();
      expect(find.text('正在登录……'), findsOneWidget);
      final google = find.widgetWithText(OutlinedButton, '使用谷歌账号登录');
      expect(tester.widget<OutlinedButton>(google).onPressed, isNotNull);
      final passkey = find.widgetWithText(OutlinedButton, '使用通行密钥登录');
      expect(tester.widget<OutlinedButton>(passkey).onPressed, isNotNull);
      session.loginGate!.complete();
      await tester.pump();
      await tester.pump();
    });
  });
}
