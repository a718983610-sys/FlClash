import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_http_client.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_passkey.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

class _FakeAccountSession extends QfSessionController {
  _FakeAccountSession() {
    mode = QfMode.entry;
    serverBaseUrl = 'http://127.0.0.1:1';
  }

  int registerCodeCalls = 0;
  int resetCodeCalls = 0;
  Object? codeError;
  Object? passkeyOptionsError;

  @override
  Future<void> registerRequestCode(String emailInput) async {
    registerCodeCalls++;
    final error = codeError;
    if (error != null) throw error;
  }

  @override
  Future<void> resetRequestCode(String emailInput) async {
    resetCodeCalls++;
    final error = codeError;
    if (error != null) throw error;
  }

  @override
  Future<Map<String, dynamic>> passkeyLoginOptions(String? identifier) async {
    final error = passkeyOptionsError;
    if (error != null) throw error;
    return {'challenge': 'x'};
  }
}

void _mockSecure({
  required bool throwOnRead,
  bool throwOnWrite = false,
  Map<String, String>? writes,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        if (call.method == 'read') {
          if (throwOnRead) {
            throw PlatformException(code: 'dpapi_error', message: 'DPAPI');
          }
          return null;
        }
        if (call.method == 'write') {
          if (throwOnWrite) {
            throw PlatformException(code: 'dpapi_error', message: 'DPAPI');
          }
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          writes?[args['key'].toString()] = args['value'].toString();
          return null;
        }
        return null;
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bindingOverrides = HttpOverrides.current;

  setUp(() {
    QfHttpClient.coreRunningProbe = null;
    QfHttpClient.coreReachabilityOverride = null;
    QfHttpClient.systemProxyReaderOverride = null;
    QfHttpClient.lastDecision = const QfProxyDecision(
      'DIRECT',
      QfProxySource.direct,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
    // Restore the test binding's mock overrides (not null, which would
    // silently switch later widget tests to the real network).
    HttpOverrides.global = bindingOverrides;
  });

  group('proxy decision table', () {
    test('core running wins and uses the core port', () {
      final d = qfDecideProxy(
        coreRunning: true,
        corePort: 7890,
        systemProxyServer: '127.0.0.1:1080',
        envProxy: '127.0.0.1:8888',
        host: 'example.workers.dev',
      );
      expect(d.proxy, 'PROXY 127.0.0.1:7890');
      expect(d.source, QfProxySource.core);
    });

    test('system proxy is second', () {
      final d = qfDecideProxy(
        coreRunning: false,
        corePort: 7890,
        systemProxyServer: '127.0.0.1:1080',
        envProxy: '127.0.0.1:8888',
      );
      expect(d.proxy, 'PROXY 127.0.0.1:1080');
      expect(d.source, QfProxySource.system);
    });

    test('winINET per-protocol value picks https entry', () {
      expect(
        qfNormalizeProxyServer('http=127.0.0.1:8080;https=127.0.0.1:8443'),
        '127.0.0.1:8443',
      );
      expect(
        qfNormalizeProxyServer('http://127.0.0.1:7890/'),
        '127.0.0.1:7890',
      );
      expect(qfNormalizeProxyServer('  '), '');
    });

    test('environment proxy is third and normalized', () {
      final d = qfDecideProxy(
        coreRunning: false,
        corePort: 7890,
        envProxy: 'http://127.0.0.1:8888/',
      );
      expect(d.proxy, 'PROXY 127.0.0.1:8888');
      expect(d.source, QfProxySource.environment);
    });

    test('no path falls back to direct; localhost always direct', () {
      final d = qfDecideProxy(coreRunning: false, corePort: 7890);
      expect(d.proxy, 'DIRECT');
      expect(d.source, QfProxySource.direct);
      final local = qfDecideProxy(
        coreRunning: true,
        corePort: 7890,
        host: '127.0.0.1',
      );
      expect(local.proxy, 'DIRECT');
    });

    test('resolveDecision skips an unreachable core', () async {
      QfHttpClient.coreRunningProbe = () => true;
      QfHttpClient.coreReachabilityOverride = (_) async => false;
      final d = await QfHttpClient.resolveDecision(host: 'example.workers.dev');
      expect(d.source, isNot(QfProxySource.core));
      QfHttpClient.coreReachabilityOverride = (_) async => true;
      final d2 = await QfHttpClient.resolveDecision(
        host: 'example.workers.dev',
      );
      expect(d2.source, QfProxySource.core);
      expect(d2.proxy, 'PROXY 127.0.0.1:7890');
    });
  });

  group('network failure copy mapping', () {
    const network = QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');

    test('direct decision maps to the needs-proxy account copy', () {
      QfHttpClient.lastDecision = const QfProxyDecision(
        'DIRECT',
        QfProxySource.direct,
      );
      expect(qfAccountErrorMessage(network), QfCopy.networkAccountNeedsProxy);
    });

    test('proxied decision maps to the plain unreachable copy', () {
      QfHttpClient.lastDecision = const QfProxyDecision(
        'PROXY 127.0.0.1:7890',
        QfProxySource.core,
      );
      expect(qfAccountErrorMessage(network), QfCopy.networkAccountUnreachable);
    });

    test('business errors keep the server message; guest copy differs', () {
      const business = QfApiException(400, 'BAD', '验证码不正确');
      expect(qfAccountErrorMessage(business), '验证码不正确');
      expect(qfGuestErrorMessage(network), QfCopy.networkGuestUnreachable);
      expect(qfGuestErrorMessage(business), '验证码不正确');
      expect(network.isNetworkFailure, isTrue);
      expect(business.isNetworkFailure, isFalse);
    });
  });

  group('session persistence hardening', () {
    test(
      'legacy prefs plaintext migrates to secure storage and is purged',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_remember_device': true,
          'qf_mode': 'user',
          'qf_access_token': 'acc-legacy',
          'qf_refresh_token': 'ref-legacy',
          'qf_access_expires_at': 9999999999,
          'qf_heartbeat_key': 'hk',
          'qf_user_email': 'a@b.c',
          'qf_user_username': 'tester123',
          'qf_user_id': 7,
        });
        final secureWrites = <String, String>{};
        _mockSecure(throwOnRead: false, writes: secureWrites);
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:1';
        await session.init(envEmulator: false);
        expect(session.mode, QfMode.user);
        expect(session.userId, 7);
        expect(secureWrites['qf_access_token'], 'acc-legacy');
        expect(secureWrites['qf_refresh_token'], 'ref-legacy');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('qf_access_token'), isNull);
        expect(prefs.getString('qf_refresh_token'), isNull);
        expect(prefs.getString('qf_heartbeat_key'), isNull);
      },
    );

    test('secure read failure without mirror does not throw', () async {
      SharedPreferences.setMockInitialValues({'qf_remember_device': true});
      _mockSecure(throwOnRead: true);
      final session = QfSessionController();
      session.serverBaseUrl = 'http://127.0.0.1:1';
      await session.init(envEmulator: false);
      expect(session.mode, QfMode.entry);
    });

    test(
      'login persists tokens to secure storage only before returning',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_device_hash': 'hash-1',
          'qf_device_name': 'test-box',
        });
        final secureWrites = <String, String>{};
        _mockSecure(throwOnRead: false, writes: secureWrites);
        HttpOverrides.global = _RealHttpOverrides();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          final body = request.uri.path == '/auth/login'
              ? {
                  'accessToken': 'acc-1',
                  'refreshToken': 'ref-1',
                  'accessExpiresAt': 9999999999,
                  'heartbeatKey': 'hk',
                  'user': {'id': 7, 'email': 'a@b.c', 'username': 'tester123'},
                }
              : <String, dynamic>{};
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(body));
          await request.response.close();
        });
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
        await session.login(
          emailInput: 'a@b.c',
          password: 'secret123',
          remember: true,
        );
        expect(session.mode, QfMode.user);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('qf_refresh_token'), isNull);
        expect(prefs.getString('qf_access_token'), isNull);
        expect(secureWrites['qf_access_token'], 'acc-1');
        expect(secureWrites['qf_refresh_token'], 'ref-1');
      },
    );

    test('secure write failure fails loudly without plaintext fallback', () async {
      SharedPreferences.setMockInitialValues({
        'qf_device_hash': 'hash-1',
        'qf_device_name': 'test-box',
      });
      _mockSecure(throwOnRead: false, throwOnWrite: true);
      HttpOverrides.global = _RealHttpOverrides();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        final body = request.uri.path == '/auth/login'
            ? {
                'accessToken': 'acc-2',
                'refreshToken': 'ref-2',
                'accessExpiresAt': 9999999999,
                'heartbeatKey': 'hk',
                'user': {'id': 7, 'email': 'a@b.c', 'username': 'tester123'},
              }
            : <String, dynamic>{};
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await request.response.close();
      });
      final session = QfSessionController();
      session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
      await expectLater(
        session.login(
          emailInput: 'a@b.c',
          password: 'secret123',
          remember: true,
        ),
        throwsA(
          isA<QfApiException>().having((e) => e.code, 'code', 'STORAGE'),
        ),
      );
      expect(session.mode, isNot(QfMode.user));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('qf_refresh_token'), isNull);
      expect(prefs.getString('qf_access_token'), isNull);
    });
  });

  group('unavailable login methods must explain themselves', () {
    testWidgets('google button explains when not configured', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final session = _FakeAccountSession();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QfLoginForm(session: session)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final button = find.widgetWithText(OutlinedButton, '使用谷歌账号登录');
      expect(button, findsOneWidget);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(QfCopy.googleNotConfiguredHint), findsOneWidget);
    });

    testWidgets('passkey login surfaces the network reason', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final session = _FakeAccountSession();
      session.passkeyOptionsError = const QfApiException(
        0,
        'NETWORK',
        '网络连接失败，请检查网络后重试',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QfLoginForm(session: session)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The form's init manifest refresh recomputes the proxy decision
      // from the host environment; pin the direct decision before the tap.
      QfHttpClient.lastDecision = const QfProxyDecision(
        'DIRECT',
        QfProxySource.direct,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, '使用通行密钥登录'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(QfCopy.networkAccountNeedsProxy), findsOneWidget);
    });

    test('passkey failure translator gives explicit reasons', () {
      expect(
        qfPasskeyFailureText(MissingPluginException('no plugin')),
        contains('不支持通行密钥'),
      );
      expect(
        qfPasskeyFailureText(PlatformException(code: 'NotAllowedError')),
        contains('已取消'),
      );
      expect(
        qfPasskeyFailureText(PlatformException(code: 'NotSupportedError')),
        contains('不支持通行密钥'),
      );
      expect(
        qfPasskeyFailureText(PlatformException(code: 'UnknownError')),
        contains('UnknownError'),
      );
    });
  });
}
