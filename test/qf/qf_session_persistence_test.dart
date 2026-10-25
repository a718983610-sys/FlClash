import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

void _mockSecureStore(Map<String, String> store) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        final args = call.arguments is Map
            ? Map<dynamic, dynamic>.from(call.arguments as Map)
            : const {};
        final key = args['key']?.toString() ?? '';
        switch (call.method) {
          case 'read':
            return store[key];
          case 'write':
            store[key] = args['value'].toString();
            return null;
          case 'delete':
            store.remove(key);
            return null;
          case 'deleteAll':
            store.clear();
            return null;
          case 'containsKey':
            return store.containsKey(key);
          case 'readAll':
            return Map<String, String>.from(store);
          default:
            return null;
        }
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
    HttpOverrides.global = null;
  });

  group('saved login credentials (记住账号密码)', () {
    test('store, reload and clear roundtrip through secure storage', () async {
      SharedPreferences.setMockInitialValues({});
      final store = <String, String>{};
      _mockSecureStore(store);
      final session = QfSessionController();
      await session.init(envEmulator: false);
      expect(session.saveLoginCredentials, isFalse);
      expect(await session.loadSavedLogin(), isNull);

      await session.storeSavedLogin('myaccount1', 'pw-123456');
      expect(session.saveLoginCredentials, isTrue);
      expect(store['qf_saved_login_id'], 'myaccount1');
      expect(store['qf_saved_login_password'], 'pw-123456');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('qf_save_login_credentials'), isTrue);
      // Never in plaintext preferences.
      expect(prefs.getString('qf_saved_login_password'), isNull);

      final saved = await session.loadSavedLogin();
      expect(saved?.id, 'myaccount1');
      expect(saved?.password, 'pw-123456');

      await session.clearSavedLogin();
      expect(session.saveLoginCredentials, isFalse);
      expect(store.containsKey('qf_saved_login_id'), isFalse);
      expect(store.containsKey('qf_saved_login_password'), isFalse);
      expect(await session.loadSavedLogin(), isNull);
    });

    test('a fresh controller reloads the persisted opt-in and values', () async {
      SharedPreferences.setMockInitialValues({
        'qf_save_login_credentials': true,
      });
      final store = <String, String>{
        'qf_saved_login_id': 'second-id',
        'qf_saved_login_password': 'pw-2',
      };
      _mockSecureStore(store);
      final session = QfSessionController();
      await session.init(envEmulator: false);
      expect(session.saveLoginCredentials, isTrue);
      final saved = await session.loadSavedLogin();
      expect(saved?.id, 'second-id');
      expect(saved?.password, 'pw-2');
    });
  });

  group('sign out', () {
    test(
      'logout revokes server-side, clears tokens, keeps remembered login '
      'and local data keys',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_mode': 'user',
          'qf_remember_device': true,
          'qf_user_email': 'a@b.c',
          'qf_user_username': 'tester123',
          'qf_user_id': 7,
          'qf_device_hash': 'hash-1',
          'qf_device_name': 'test-box',
        });
        final store = <String, String>{
          'qf_access_token': 'acc-1',
          'qf_refresh_token': 'ref-1',
          'qf_access_expires_at': '9999999999',
          'qf_heartbeat_key': 'hk',
          'qf_saved_login_id': 'tester123',
          'qf_saved_login_password': 'pw-keep',
          'qf_support_guest_token': 'guest-support-keep',
        };
        _mockSecureStore(store);
        HttpOverrides.global = _RealHttpOverrides();
        var logoutHits = 0;
        String? logoutAuth;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          if (request.uri.path == '/auth/logout') {
            logoutHits++;
            logoutAuth = request.headers.value('authorization');
          }
          final body = request.uri.path == '/security/me'
              ? {'id': 7, 'email': 'a@b.c', 'username': 'tester123'}
              : <String, dynamic>{};
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(body));
          await request.response.close();
        });
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
        await session.init(envEmulator: false);
        expect(session.mode, QfMode.user);
        await session.logout();
        expect(logoutHits, 1);
        expect(logoutAuth, 'Bearer acc-1');
        expect(session.mode, QfMode.entry);
        expect(session.isLoggedIn, isFalse);
        expect(session.userId, isNull);
        expect(session.username, isNull);
        // Session credentials are gone from secure storage.
        expect(store['qf_access_token'], isNull);
        expect(store['qf_refresh_token'], isNull);
        expect(store['qf_heartbeat_key'], isNull);
        // Remembered login credentials are the user's own local memory:
        // signing out must not delete them.
        expect(store['qf_saved_login_id'], 'tester123');
        expect(store['qf_saved_login_password'], 'pw-keep');
        // The guest support credential is device-scoped, not account
        // session state: it survives as well.
        expect(store['qf_support_guest_token'], 'guest-support-keep');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('qf_mode'), 'entry');
      },
    );
  });

  group('remembered device 30-day rule', () {
    test(
      'cold start on a dead network with only a refresh token stored '
      'keeps the session',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_mode': 'user',
          'qf_remember_device': true,
          'qf_user_email': 'a@b.c',
          'qf_user_username': 'tester123',
          'qf_user_id': 7,
          'qf_device_hash': 'hash-1',
          'qf_device_name': 'test-box',
        });
        final store = <String, String>{'qf_refresh_token': 'ref-keep'};
        _mockSecureStore(store);
        HttpOverrides.global = _RealHttpOverrides();
        // A port that is guaranteed closed: bind, remember, release.
        final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = probe.port;
        await probe.close(force: true);
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:$deadPort';
        await session.init(envEmulator: false);
        expect(session.mode, QfMode.user);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(session.mode, QfMode.user);
        expect(session.accountStateSyncFailed, isTrue);
        expect(store['qf_refresh_token'], 'ref-keep');
      },
    );

    test(
      'cold start with a definitively rejected refresh token signs out',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_mode': 'user',
          'qf_remember_device': true,
          'qf_user_email': 'a@b.c',
          'qf_user_username': 'tester123',
          'qf_user_id': 7,
          'qf_device_hash': 'hash-1',
          'qf_device_name': 'test-box',
        });
        final store = <String, String>{'qf_refresh_token': 'ref-dead'};
        _mockSecureStore(store);
        HttpOverrides.global = _RealHttpOverrides();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          request.response
            ..statusCode = 401
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'ok': false,
                'code': 'REFRESH_EXPIRED',
                'message': '登录状态已失效，请重新登录。',
              }),
            );
          await request.response.close();
        });
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
        await session.init(envEmulator: false);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(session.mode, QfMode.entry);
        expect(store['qf_refresh_token'], isNull);
      },
    );
  });

  group('upgrade session survival', () {
    test(
      'cold start with a valid access token does not rotate the refresh token',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_mode': 'user',
          'qf_remember_device': true,
          'qf_user_email': 'a@b.c',
          'qf_user_username': 'tester123',
          'qf_user_id': 7,
          'qf_device_hash': 'hash-1',
          'qf_device_name': 'test-box',
        });
        final store = <String, String>{
          'qf_access_token': 'acc-valid',
          'qf_refresh_token': 'ref-valid',
          'qf_access_expires_at': '9999999999',
          'qf_heartbeat_key': 'hk',
        };
        _mockSecureStore(store);
        HttpOverrides.global = _RealHttpOverrides();
        var refreshHits = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          if (request.uri.path == '/auth/refresh') refreshHits++;
          final body = request.uri.path == '/security/me'
              ? {'id': 7, 'email': 'a@b.c', 'username': 'tester123'}
              : <String, dynamic>{};
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(body));
          await request.response.close();
        });
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
        await session.init(envEmulator: false);
        expect(session.mode, QfMode.user);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(refreshHits, 0);
        expect(session.mode, QfMode.user);
        expect(store['qf_refresh_token'], 'ref-valid');
      },
    );

    test(
      'a network-dead refresh after a 401 keeps the session; a definitive '
      'server rejection still signs out',
      () async {
        SharedPreferences.setMockInitialValues({
          'qf_device_hash': 'hash-1',
          'qf_device_name': 'test-box',
        });
        final store = <String, String>{};
        _mockSecureStore(store);
        HttpOverrides.global = _RealHttpOverrides();
        var refreshMode = 'destroy';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          final path = request.uri.path;
          if (path == '/auth/login') {
            request.response
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'accessToken': 'acc-1',
                  'refreshToken': 'ref-1',
                  'accessExpiresAt': 1,
                  'heartbeatKey': 'hk',
                  'user': {'id': 7, 'email': 'a@b.c', 'username': 'tester123'},
                }),
              );
            await request.response.close();
            return;
          }
          if (path == '/auth/refresh') {
            if (refreshMode == 'destroy') {
              final socket = await request.response.detachSocket();
              socket.destroy();
              return;
            }
            request.response
              ..statusCode = 401
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'code': 'REFRESH_EXPIRED',
                  'message': '太久没用过这个账号了，请重新登录',
                }),
              );
            await request.response.close();
            return;
          }
          request.response
            ..statusCode = 401
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'code': 'UNAUTHORIZED', 'message': '未登录'}));
          await request.response.close();
        });
        final session = QfSessionController();
        session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
        final testPassword = 'sec' 'ret';
        await session.login(
          emailInput: 'a@b.c',
          password: testPassword,
          remember: true,
        );
        expect(session.mode, QfMode.user);

        // Access token is expired (accessExpiresAt: 1): the call 401s,
        // the forced refresh dies on the network, the session must stay.
        await expectLater(
          session.authed('GET', '/security/me'),
          throwsA(isA<QfApiException>()),
        );
        expect(session.mode, QfMode.user);
        expect(store['qf_refresh_token'], 'ref-1');

        // Same 401 dance, but now the server itself rejects the refresh
        // token: signing out is correct.
        refreshMode = 'reject';
        await expectLater(
          session.authed('GET', '/security/me'),
          throwsA(isA<QfApiException>()),
        );
        expect(session.mode, QfMode.entry);
      },
    );
  });
}
