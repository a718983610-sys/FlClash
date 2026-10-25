import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_data_migration.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_social.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

class _ApiStub {
  HttpServer? _server;
  bool requestsFail = false;
  int heartbeatStatus = 200;
  String heartbeatErrorCode = '';
  Map<String, dynamic> heartbeatResponse = const {'accepted': true};
  Map<String, dynamic> guestHeartbeatResponse = const {'accepted': true};
  final List<Map<String, dynamic>> heartbeatBodies = [];
  final List<Map<String, dynamic>> guestHeartbeatBodies = [];

  String get base => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  Future<void> _reply(HttpRequest req, int status, Object body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    final body = raw.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final path = req.uri.path;
    if (path == '/auth/login') {
      await _reply(req, 200, {
        'accessToken': 'at',
        'refreshToken': 'rt',
        'accessExpiresAt':
            DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        'heartbeatKey': 'hk',
        'user': {'id': 7, 'username': 'tester7', 'email': 't@example.com'},
      });
      return;
    }
    if (path == '/guest/register') {
      await _reply(req, 200, {
        'guestToken': 'gt',
        'heartbeatKey': 'ghk',
        'dailyLimitSeconds': 7200,
        'usedSeconds': 0,
        'remainingSeconds': 7200,
        'exhausted': false,
      });
      return;
    }
    if (path == '/points/heartbeat') {
      heartbeatBodies.add(body);
      if (heartbeatStatus != 200) {
        await _reply(req, heartbeatStatus, {
          'code': heartbeatErrorCode,
          'message': 'rejected',
        });
        return;
      }
      await _reply(req, 200, heartbeatResponse);
      return;
    }
    if (path == '/guest/heartbeat') {
      guestHeartbeatBodies.add(body);
      await _reply(req, 200, {
        'dailyLimitSeconds': 7200,
        'usedSeconds': 0,
        'remainingSeconds': 7200,
        'exhausted': false,
        ...guestHeartbeatResponse,
      });
      return;
    }
    if (path == '/friends') {
      await _reply(req, 200, {'friends': const []});
      return;
    }
    if (path == '/friends/requests') {
      if (requestsFail) {
        await _reply(req, 500, {'code': 'BOOM', 'message': 'boom'});
        return;
      }
      await _reply(req, 200, {
        'incoming': [
          {'id': 9001, 'userId': 55, 'nickname': '申请人甲'},
        ],
        'outgoing': const [],
      });
      return;
    }
    if (path == '/friends/search') {
      final query = (body['query'] ?? '').toString();
      if (query == '慢') {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        await _reply(req, 200, {
          'users': [
            {'userId': 61, 'nickname': '慢结果'},
          ],
        });
        return;
      }
      await _reply(req, 200, {
        'users': [
          {'userId': 62, 'nickname': '快结果'},
        ],
      });
      return;
    }
    if (path == '/chat/conversations') {
      await _reply(req, 200, {'conversations': const []});
      return;
    }
    await _reply(req, 200, {'ok': true});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secureStore = <String, String>{};

  setUp(() {
    secureStore.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'qf_device_hash': 'test-device-hash',
      'qf_device_name': 'Test Device',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<dynamic, dynamic>.from(call.arguments as Map)
              : const {};
          final key = args['key']?.toString() ?? '';
          switch (call.method) {
            case 'read':
              return secureStore[key];
            case 'write':
              secureStore[key] = args['value'].toString();
              return null;
            case 'delete':
              secureStore.remove(key);
              return null;
            case 'deleteAll':
              secureStore.clear();
              return null;
            case 'containsKey':
              return secureStore.containsKey(key);
            case 'readAll':
              return Map<String, String>.from(secureStore);
            default:
              return null;
          }
        });
    HttpOverrides.global = _RealHttpOverrides();
    QfEndpoints.lastGood = '';
    QfSignalStore.bindUser(null);
    QfSignalStore.resetCache();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
    HttpOverrides.global = null;
    QfSignalStore.bindUser(null);
    QfSignalStore.resetCache();
  });

  group('N-03 retryable classification', () {
    test('only idempotent requests auto-retry', () {
      expect(QfHttp.isRetryable('GET', null), isTrue);
      expect(QfHttp.isRetryable('HEAD', null), isTrue);
      expect(QfHttp.isRetryable('PUT', {'a': 1}), isTrue);
      expect(QfHttp.isRetryable('DELETE', null), isTrue);
      expect(QfHttp.isRetryable('POST', null), isFalse);
      expect(QfHttp.isRetryable('POST', {'title': 'x'}), isFalse);
      expect(QfHttp.isRetryable('POST', {'msgId': 'm-1'}), isTrue);
      expect(QfHttp.isRetryable('POST', {'idempotencyKey': 'k-1'}), isTrue);
      expect(QfHttp.isRetryable('POST', {'msgId': ''}), isFalse);
      expect(QfHttp.isRetryable('PATCH', null), isFalse);
    });
  });

  group('N-01 session end fires the unlocked-key clearing hook', () {
    test('logout fires it exactly once', () async {
      final session = QfSessionController();
      var fired = 0;
      session.onUserSessionClearedFn = () => fired += 1;
      await session.logout();
      expect(fired, 1);
    });

    test('ban and freeze handling fire it too', () async {
      final session = QfSessionController();
      var fired = 0;
      session.onUserSessionClearedFn = () => fired += 1;
      await session.handleBanned(
        const QfApiException(403, 'ACCOUNT_BANNED', 'banned', {
          'reason': 'test',
        }),
      );
      expect(fired, 1);
      await session.handleFrozen(
        const QfApiException(403, 'ACCOUNT_FROZEN', 'frozen'),
      );
      expect(fired, 2);
    });
  });

  group('N-02 signal store is keyed per account', () {
    Future<bool> blobExists(String key) async {
      if (secureStore.containsKey(key)) return true;
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key) != null;
    }

    test('two accounts hold different identities in different slots',
        () async {
      QfSignalStore.bindUser(101);
      final a = await QfSignalStore.load();
      final aIdentity = a.identityRawB64;
      expect(await blobExists('qf_signal_store_v1_u101'), isTrue);

      QfSignalStore.bindUser(202);
      final b = await QfSignalStore.load();
      expect(b.identityRawB64, isNot(aIdentity));
      expect(await blobExists('qf_signal_store_v1_u202'), isTrue);
      expect(await blobExists('qf_signal_store_v1_u101'), isTrue);

      QfSignalStore.bindUser(101);
      final aAgain = await QfSignalStore.load();
      expect(aAgain.identityRawB64, aIdentity);
    });

    test('a pre-keying global blob is adopted by the first bound load',
        () async {
      final unbound = await QfSignalStore.load();
      final legacyIdentity = unbound.identityRawB64;
      final prefs = await SharedPreferences.getInstance();
      final rawSecure = secureStore['qf_signal_store_v1'];
      final rawPrefs = prefs.getString('qf_signal_store_v1');
      final blob = rawSecure ?? rawPrefs;
      expect(blob, isNotNull);

      secureStore.clear();
      await prefs.clear();
      QfSignalStore.resetCache();
      await prefs.setString('qf_signal_store_v1', blob!);

      QfSignalStore.bindUser(303);
      final adopted = await QfSignalStore.load();
      expect(adopted.identityRawB64, legacyIdentity);
      expect(prefs.getString('qf_signal_store_v1'), isNull);
      expect(await blobExists('qf_signal_store_v1_u303'), isTrue);
    });

    test('resetBoundStore remints a fresh identity for that account',
        () async {
      QfSignalStore.bindUser(404);
      final first = await QfSignalStore.load();
      await QfSignalStore.resetBoundStore();
      final second = await QfSignalStore.load();
      expect(second.identityRawB64, isNot(first.identityRawB64));
    });

    test('hasLocalIdentity honours the binding', () async {
      expect(await QfSignalStore.hasLocalIdentity(userId: 505), isFalse);
      QfSignalStore.bindUser(505);
      await QfSignalStore.load();
      QfSignalStore.bindUser(null);
      expect(await QfSignalStore.hasLocalIdentity(userId: 505), isTrue);
      expect(await QfSignalStore.hasLocalIdentity(userId: 606), isFalse);
    });
  });

  group('N-09 legacy migration resumes from staged state', () {
    Future<Directory> fixture(String label) async {
      final root = await Directory.systemTemp.createTemp('qf-n09-$label-');
      addTearDown(() => root.delete(recursive: true));
      return root;
    }

    Future<void> writeLegacyData(Directory dir, String tag) async {
      await Directory(p.join(dir.path, 'profiles')).create(recursive: true);
      await File(p.join(dir.path, 'config.yaml')).writeAsString('cfg-$tag');
      await File(
        p.join(dir.path, 'profiles', 'a.yaml'),
      ).writeAsString('profile-$tag');
    }

    test('pending marker plus staging completes the move', () async {
      final root = await fixture('resume');
      final current = Directory(p.join(root.path, 'app', 'QFClash'));
      final staging = Directory('${current.path}.qf-legacy-staging');
      await writeLegacyData(staging, 'staged');
      await current.create(recursive: true);
      await File(
        p.join(current.path, qfLegacyPendingName),
      ).writeAsString('staged');

      expect(await qfMigrateLegacyDataDir(current), isTrue);
      expect(
        await File(p.join(current.path, 'config.yaml')).readAsString(),
        'cfg-staged',
      );
      expect(
        await File(p.join(current.path, 'profiles', 'a.yaml')).readAsString(),
        'profile-staged',
      );
      expect(await File(p.join(current.path, qfLegacyMarkerName)).exists(),
          isTrue);
      expect(await staging.exists(), isFalse);
      expect(
        await File(p.join(current.path, qfLegacyPendingName)).exists(),
        isFalse,
      );
      expect(await qfMigrateLegacyDataDir(current), isFalse);
    });

    test('staging without pending is an abandoned copy and recopies',
        () async {
      final root = await fixture('abandoned');
      final current = Directory(p.join(root.path, 'app', 'QFClash'));
      final legacy = Directory(p.join(root.path, 'app', 'clash'));
      final staging = Directory('${current.path}.qf-legacy-staging');
      await writeLegacyData(legacy, 'legacy');
      await writeLegacyData(staging, 'partial');
      await current.create(recursive: true);

      expect(await qfMigrateLegacyDataDir(current), isTrue);
      expect(
        await File(p.join(current.path, 'config.yaml')).readAsString(),
        'cfg-legacy',
      );
      expect(await staging.exists(), isFalse);
    });

    test('done marker cleans a leftover staging directory', () async {
      final root = await fixture('leftover');
      final current = Directory(p.join(root.path, 'app', 'QFClash'));
      final staging = Directory('${current.path}.qf-legacy-staging');
      await writeLegacyData(staging, 'stale');
      await current.create(recursive: true);
      await File(
        p.join(current.path, qfLegacyMarkerName),
      ).writeAsString('migrated');

      expect(await qfMigrateLegacyDataDir(current), isFalse);
      expect(await staging.exists(), isFalse);
      expect(
        await File(p.join(current.path, 'config.yaml')).exists(),
        isFalse,
      );
    });
  });

  group('Q-a heartbeat discipline', () {
    late _ApiStub stub;

    setUp(() async {
      stub = _ApiStub();
      await stub.start();
    });

    tearDown(() async {
      await stub.stop();
    });

    Future<QfSessionController> loggedIn() async {
      final session = QfSessionController();
      session.applyServerBaseUrl(stub.base);
      await session.login(emailInput: 't@example.com', password: 'pw');
      return session;
    }

    test('seq_out_of_order resyncs seq and re-reports the traffic delta',
        () async {
      final session = await loggedIn();
      var total = 1000;
      session.isRunningFn = () => true;
      session.trafficTotalFn = () => total;
      stub.heartbeatResponse = {
        'accepted': false,
        'reason': 'seq_out_of_order',
        'serverSeq': 41,
      };
      await session.beat();
      expect(stub.heartbeatBodies.single['seq'], 1);
      expect(stub.heartbeatBodies.single['trafficBytes'], 1000);

      stub.heartbeatResponse = {'accepted': true};
      await session.beat();
      expect(stub.heartbeatBodies.last['seq'], 42);
      expect(stub.heartbeatBodies.last['trafficBytes'], 1000);

      total = 1500;
      await session.beat();
      expect(stub.heartbeatBodies.last['seq'], 43);
      expect(stub.heartbeatBodies.last['trafficBytes'], 500);
    });

    test('accepted with a notice commits and never resends the beat',
        () async {
      final session = await loggedIn();
      session.isRunningFn = () => true;
      session.trafficTotalFn = () => 800;
      stub.heartbeatResponse = {
        'accepted': true,
        'notice': '今日积分已达上限',
      };
      await session.beat();
      expect(session.heartbeatNotice, '今日积分已达上限');
      stub.heartbeatResponse = {'accepted': true};
      await session.beat();
      expect(
        stub.heartbeatBodies.map((body) => body['seq']).toList(),
        [1, 2],
      );
      expect(stub.heartbeatBodies.last['trafficBytes'], 0);
    });

    test('bad signature drops the session for a fresh sign-in', () async {
      final session = await loggedIn();
      session.isRunningFn = () => true;
      session.trafficTotalFn = () => 0;
      stub.heartbeatStatus = 403;
      stub.heartbeatErrorCode = 'BAD_SIGNATURE';
      await session.beat();
      expect(session.mode, QfMode.entry);
      expect(session.isLoggedIn, isFalse);
    });

    test('device not registered drops the session too', () async {
      final session = await loggedIn();
      session.isRunningFn = () => true;
      session.trafficTotalFn = () => 0;
      stub.heartbeatStatus = 403;
      stub.heartbeatErrorCode = 'DEVICE_NOT_REGISTERED';
      await session.beat();
      expect(session.mode, QfMode.entry);
      expect(session.isLoggedIn, isFalse);
    });

    test('guest seq_out_of_order resyncs and re-reports the delta',
        () async {
      final session = QfSessionController();
      session.applyServerBaseUrl(stub.base);
      await session.enterGuest();
      session.isRunningFn = () => true;
      session.trafficTotalFn = () => 600;
      stub.guestHeartbeatResponse = {
        'accepted': false,
        'reason': 'seq_out_of_order',
        'serverSeq': 9,
      };
      await session.beat();
      expect(stub.guestHeartbeatBodies.single['seq'], 1);
      expect(stub.guestHeartbeatBodies.single['trafficBytes'], 600);

      stub.guestHeartbeatResponse = {'accepted': true};
      await session.beat();
      expect(stub.guestHeartbeatBodies.last['seq'], 10);
      expect(stub.guestHeartbeatBodies.last['trafficBytes'], 600);
    });
  });

  group('N-06/N-07 friends page', () {
    testWidgets('a failed requests refresh keeps the pending list visible',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _FakeFriendsSession();
      await tester.pumpWidget(
        MaterialApp(home: QfFriendsPage(session: session)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('申请人甲'), findsOneWidget);

      session.requestsFail = true;
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(find.text('申请人甲'), findsOneWidget);
      expect(find.text('好友申请刷新失败，当前显示的是上次加载的列表。'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a slow stale search never overwrites the newest results',
        (tester) async {
      final session = _FakeFriendsSession();
      await tester.pumpWidget(
        MaterialApp(home: QfFriendsPage(session: session)),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '慢');
      await tester.tap(find.text('搜索'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '快');
      await tester.tap(find.text('搜索'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('快结果'), findsOneWidget);
      expect(find.text('慢结果'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// In-memory session for the friends page: every social call funnels
/// through authed(), so overriding it stubs the whole surface with
/// fake-clock-controllable timing.
class _FakeFriendsSession extends QfSessionController {
  _FakeFriendsSession() {
    mode = QfMode.user;
    userId = 7;
    username = 'tester7';
  }

  bool requestsFail = false;

  @override
  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    if (path == '/friends') return {'friends': const []};
    if (path == '/friends/requests') {
      if (requestsFail) {
        throw const QfApiException(500, 'BOOM', 'boom');
      }
      return {
        'incoming': [
          {
            'id': 9001,
            'user': {'userId': 55, 'nickname': '申请人甲'},
          },
        ],
        'outgoing': const [],
      };
    }
    if (path == '/friends/search') {
      final query = (body?['query'] ?? '').toString();
      if (query == '慢') {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        return {
          'users': [
            {'userId': 61, 'nickname': '慢结果'},
          ],
        };
      }
      return {
        'users': [
          {'userId': 62, 'nickname': '快结果'},
        ],
      };
    }
    if (path == '/chat/conversations') return {'conversations': const []};
    return const {};
  }
}
