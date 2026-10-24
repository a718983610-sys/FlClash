import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_vault.dart';
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

void _mockSecureOk() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async => null);
}

/// A loopback account server whose behavior each test programs by path.
class _Server {
  HttpServer? _http;
  final Map<String, FutureOr<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> body,
    int call,
  )> handlers = {};
  final Map<String, int> calls = {};
  final Map<String, List<Map<String, dynamic>>> bodies = {};

  String get base => 'http://127.0.0.1:${_http!.port}';

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http!.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      Map<String, dynamic> body = {};
      if (raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) body = Map<String, dynamic>.from(decoded);
        } catch (_) {}
      }
      final path = request.uri.path;
      calls[path] = (calls[path] ?? 0) + 1;
      (bodies[path] ??= []).add(body);
      final handler = handlers[path];
      Map<String, dynamic> payload = {'ok': true};
      var status = 200;
      if (handler != null) {
        try {
          payload = await handler(request.method, body, calls[path]!);
        } on _Status catch (e) {
          status = e.status;
          payload = e.payload;
        }
      }
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  }

  Future<void> stop() async {
    await _http?.close(force: true);
  }
}

class _Status implements Exception {
  final int status;
  final Map<String, dynamic> payload;
  const _Status(this.status, this.payload);
}

Map<String, dynamic> _loginPayload({
  int accessExpiresAt = 9999999999,
  String access = 'acc-1',
  String refresh = 'ref-1',
}) {
  return {
    'accessToken': access,
    'refreshToken': refresh,
    'accessExpiresAt': accessExpiresAt,
    'heartbeatKey': 'hk',
    'user': {'id': 7, 'email': 'a@b.c', 'username': 'tester123'},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = _RealHttpOverrides();
    _mockSecureOk();
    SharedPreferences.setMockInitialValues({
      'qf_device_hash': 'hash-1',
      'qf_device_name': 'test-box',
    });
    QfEndpoints.resetForTest();
  });

  tearDown(() {
    HttpOverrides.global = null;
    QfEndpoints.resetForTest();
  });

  group('C-02 malformed 2xx is not a success', () {
    test('HTML interception page on 200 throws BAD_RESPONSE', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html><body>portal</body></html>');
        await request.response.close();
      });
      await expectLater(
        QfHttp.send('GET', 'http://127.0.0.1:${server.port}/points/me'),
        throwsA(
          isA<QfApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE'),
        ),
      );
    });

    test('empty body on 200 throws BAD_RESPONSE', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 200;
        await request.response.close();
      });
      await expectLater(
        QfHttp.send('GET', 'http://127.0.0.1:${server.port}/points/me'),
        throwsA(
          isA<QfApiException>().having((e) => e.code, 'code', 'BAD_RESPONSE'),
        ),
      );
    });

    test('well-formed JSON 200 still succeeds', () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      server.handlers['/points/me'] = (method, body, call) async => {'points': 12};
      final data = await QfHttp.send('GET', '${server.base}/points/me');
      expect(data['points'], 12);
    });
  });

  group('C-01 account response body cannot stall forever', () {
    test(
      'a trickling body times out and rotates to the healthy entry',
      () async {
        final drip = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => drip.close(force: true));
        var dripHits = 0;
        drip.listen((request) async {
          dripHits++;
          final response = request.response;
          response.contentLength = 100;
          response.write('0123456789');
          await response.flush();
          // The body then trickles: without a stall timeout the read
          // would only end when the server finally closes at 25s, and
          // would surface as a fake empty success.
          await Future<void>.delayed(const Duration(seconds: 25));
          try {
            await response.close();
          } catch (_) {}
        });
        final healthy = _Server();
        await healthy.start();
        addTearDown(healthy.stop);
        healthy.handlers['/points/me'] =
            (method, body, call) async => {'ok': true, 'done': true};
        QfEndpoints.apply(
          primaryUrl: 'http://127.0.0.1:${drip.port}',
          backupUrl: healthy.base,
        );
        final watch = Stopwatch()..start();
        final data = await QfHttp.send(
          'GET',
          'http://127.0.0.1:${drip.port}/points/me',
        );
        watch.stop();
        expect(data['done'], true);
        // One stall-bound attempt plus its cross-path retry on the
        // dead entry, then the healthy fallback answers.
        expect(dripHits, 2);
        expect(healthy.calls['/points/me'], 1);
        expect(watch.elapsed, lessThan(const Duration(seconds: 55)));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('C-04 refresh single-flight and empty-token guard', () {
    Future<(_Server, QfSessionController)> loggedIn({
      required FutureOr<Map<String, dynamic>> Function(
        String method,
        Map<String, dynamic> body,
        int call,
      ) refresh,
      int accessExpiresAt = 9999999999,
    }) async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      server.handlers['/auth/login'] =
          (method, body, call) async => _loginPayload(accessExpiresAt: accessExpiresAt);
      server.handlers['/auth/refresh'] = refresh;
      server.handlers['/security/me'] = (method, body, call) async => {
        'id': 7,
        'email': 'a@b.c',
        'status': 'active',
      };
      final session = QfSessionController();
      session.serverBaseUrl = server.base;
      await session.login(emailInput: 'a@b.c', password: 'pw-123456');
      return (server, session);
    }

    test('concurrent authed calls share one refresh', () async {
      final (server, session) = await loggedIn(
        accessExpiresAt: 1, // already expired: authed() refreshes first
        refresh: (method, body, call) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          // The first refreshes keep returning an expired access token
          // (login's own follow-up calls may consume one), so the
          // concurrent phase below is guaranteed to face an expired
          // token too; only later refreshes turn long-lived.
          if (call <= 2) {
            return _loginPayload(
              access: 'acc-x$call',
              refresh: 'ref-x$call',
              accessExpiresAt: 1,
            )
              ..remove('user')
              ..remove('heartbeatKey');
          }
          return _loginPayload(access: 'acc-2', refresh: 'ref-2')
            ..remove('user')
            ..remove('heartbeatKey');
        },
      );
      // Whatever login itself consumed, the concurrent phase below
      // must add exactly ONE refresh for three simultaneous callers.
      final before = server.calls['/auth/refresh'] ?? 0;
      final results = await Future.wait([
        session.authed('GET', '/security/me'),
        session.authed('GET', '/security/me'),
        session.authed('GET', '/security/me'),
      ]);
      expect(results.length, 3);
      expect((server.calls['/auth/refresh'] ?? 0) - before, 1);
    });

    test('tokenless refresh response keeps the old credentials', () async {
      var serveEmpty = true;
      final (server, session) = await loggedIn(
        accessExpiresAt: 1,
        refresh: (method, body, call) async {
          if (serveEmpty) return <String, dynamic>{'ok': true};
          return _loginPayload(access: 'acc-2', refresh: 'ref-2')
            ..remove('user')
            ..remove('heartbeatKey');
        },
      );
      // The refresh answers without tokens: the session must keep
      // using (and offering) the OLD tokens instead of rotating to
      // empty strings.
      final me = await session.authed('GET', '/security/me');
      expect(me['id'], 7);
      serveEmpty = false;
      await session.authed('GET', '/security/me');
      final refreshBodies = server.bodies['/auth/refresh']!;
      expect(refreshBodies.length, greaterThanOrEqualTo(2));
      expect(
        refreshBodies
            .every((b) => b['refreshToken'] == 'ref-1'),
        isTrue,
      );
    });
  });

  group('C-05 heartbeat commits seq and traffic only after success', () {
    test('failed heartbeat re-reports the same delta with the same seq',
        () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      server.handlers['/auth/login'] = (method, body, call) async => _loginPayload();
      server.handlers['/points/heartbeat'] = (method, body, call) async {
        if (call == 1) {
          throw const _Status(500, {'code': 'ERR', 'message': 'boom'});
        }
        return {'accepted': true};
      };
      final session = QfSessionController();
      session.serverBaseUrl = server.base;
      await session.login(emailInput: 'a@b.c', password: 'pw-123456');
      session.isRunningFn = () => true;
      var total = 1000;
      session.trafficTotalFn = () => total;

      await session.beat(); // server 500s: nothing may be committed
      await session.beat(); // succeeds: full delta, seq still 1

      final bodies = server.bodies['/points/heartbeat']!;
      expect(bodies.length, 2);
      expect(bodies[0]['seq'], 1);
      expect(bodies[0]['trafficBytes'], 1000);
      expect(bodies[1]['seq'], 1);
      expect(bodies[1]['trafficBytes'], 1000);

      total = 1500;
      await session.beat(); // next round: only the new delta, seq 2
      final third = server.bodies['/points/heartbeat']![2];
      expect(third['seq'], 2);
      expect(third['trafficBytes'], 500);
    });
  });

  group('C-06 redeem idempotency key is bound to the order intent', () {
    test('a retried create reuses the key; a successful one rotates it',
        () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      server.handlers['/auth/login'] = (method, body, call) async => _loginPayload();
      server.handlers['/redeem/orders'] = (method, body, call) async {
        if (call == 1) {
          throw const _Status(500, {'code': 'ERR', 'message': 'boom'});
        }
        return {'orderId': call};
      };
      final session = QfSessionController();
      session.serverBaseUrl = server.base;
      await session.login(emailInput: 'a@b.c', password: 'pw-123456');

      await expectLater(
        session.redeemCreate(42),
        throwsA(isA<QfApiException>()),
      );
      await session.redeemCreate(42);
      await session.redeemCreate(42);

      final keys = server.bodies['/redeem/orders']!
          .map((b) => b['idempotencyKey'])
          .toList();
      expect(keys.length, 3);
      expect(keys[1], keys[0]);
      expect(keys[2], isNot(keys[0]));
    });
  });

  group('C-19 refreshAccountState reflects the server status', () {
    test('deleting flag follows /security/me after refresh', () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      server.handlers['/auth/login'] = (method, body, call) async => _loginPayload();
      var status = 'deleting';
      server.handlers['/security/me'] = (method, body, call) async => {
        'id': 7,
        'email': 'a@b.c',
        'status': status,
      };
      final session = QfSessionController();
      session.serverBaseUrl = server.base;
      await session.login(emailInput: 'a@b.c', password: 'pw-123456');
      await session.refreshAccountState();
      expect(session.accountDeleting, isTrue);
      status = 'active';
      await session.refreshAccountState();
      expect(session.accountDeleting, isFalse);
    });
  });

  group('C-29 settings sync decision', () {
    test('same-second tie with unsynced changes uploads', () {
      expect(
        QfSettingsSync.decide(
          cloudUpdatedAt: 100,
          localUpdatedAt: 100,
          localDirty: true,
        ),
        QfSettingsSyncDecision.localNewer,
      );
      expect(
        QfSettingsSync.decide(cloudUpdatedAt: 100, localUpdatedAt: 100),
        QfSettingsSyncDecision.inSync,
      );
      expect(
        QfSettingsSync.decide(cloudUpdatedAt: 101, localUpdatedAt: 100),
        QfSettingsSyncDecision.cloudNewer,
      );
      expect(
        QfSettingsSync.decide(cloudUpdatedAt: 100, localUpdatedAt: 101),
        QfSettingsSyncDecision.localNewer,
      );
    });
  });

  group('C-42 identity blob choice', () {
    test('the newer savedAt wins; ties keep the secure copy', () {
      final older = jsonEncode({'identity': 'a', 'savedAt': 100});
      final newer = jsonEncode({'identity': 'b', 'savedAt': 200});
      expect(QfSignalStore.newerBlob(older, newer), newer);
      expect(QfSignalStore.newerBlob(newer, older), newer);
      expect(QfSignalStore.newerBlob(older, older), older);
      final unstamped = jsonEncode({'identity': 'c'});
      expect(QfSignalStore.newerBlob(older, unstamped), older);
    });

    test('a failing secure store never mints a new identity', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureChannel, (call) async {
        throw PlatformException(code: 'io_error', message: 'keystore busy');
      });
      QfSignalStore.resetCache();
      SharedPreferences.setMockInitialValues({});
      await expectLater(
        QfSignalStore.load(),
        throwsA(isA<StateError>()),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('qf_signal_store_v1'), isNull);
      QfSignalStore.resetCache();
      _mockSecureOk();
    });
  });

  group('C-38/C-41 chat history vault', () {
    test('tombstoned records are never re-archived', () async {
      const record = QfHistoryRecord(
        localId: 'm-1',
        peerId: 7,
        mine: true,
        text: 'secret',
        ts: 1000,
      );
      expect(await QfChatHistoryVault.archiveMessage(record), isTrue);
      await QfChatHistoryVault.removeLocalRecord('m-1');
      expect(await QfChatHistoryVault.deletedLocalIds(), contains('m-1'));
      expect(await QfChatHistoryVault.archiveMessage(record), isFalse);
      expect(await QfChatHistoryVault.localRecordsFor(7), isEmpty);
    });

    test('cleared cloud records are never re-uploaded on unlock',
        () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      server.handlers['/auth/login'] = (method, body, call) async => _loginPayload();
      server.handlers['/me/chathistory/key'] = (method, body, call) async {
        if (method == 'GET') {
          // The vault key is gone (never created, or deleted together
          // with the archive by the clear): unlock must create it.
          throw const _Status(404, {'code': 'HISTORY_KEY_NOT_FOUND'});
        }
        return {'ok': true};
      };
      server.handlers['/me/chathistory/entries'] =
          (method, body, call) async => {
            'maxSeq': 1,
            'totalEntries': 1,
            'totalBytes': 10,
            'stored': 1,
          };
      server.handlers['/me/chathistory'] = (method, body, call) async => {'ok': true};
      final session = QfSessionController();
      session.serverBaseUrl = server.base;
      await session.login(emailInput: 'a@b.c', password: 'pw-123456');
      await QfChatHistoryVault.unlock(session: session, password: 'pw-123456');

      const old = QfHistoryRecord(
        localId: 'm-old',
        peerId: 7,
        mine: true,
        text: 'old secret',
        ts: 1000,
      );
      await QfChatHistoryVault.archiveMessage(old);
      await QfChatHistoryVault.pushPending(session);
      expect(server.calls['/me/chathistory/entries'], 1);

      await QfChatHistoryVault.clearCloud(session);
      // Unlocking again (the daily path) must not resurrect the
      // cleared archive either.
      await QfChatHistoryVault.unlock(session: session, password: 'pw-123456');
      await QfChatHistoryVault.pushPending(session);
      // The cleared record must not come back: no further uploads.
      expect(server.calls['/me/chathistory/entries'], 1);

      const fresh = QfHistoryRecord(
        localId: 'm-new',
        peerId: 7,
        mine: false,
        text: 'fresh',
        ts: 2000,
      );
      await QfChatHistoryVault.archiveMessage(fresh);
      await QfChatHistoryVault.pushPending(session);
      // New records still sync - exactly one more upload.
      expect(server.calls['/me/chathistory/entries'], 2);
    });
  });
}
