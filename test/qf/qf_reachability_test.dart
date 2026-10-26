import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_egress.dart';
import 'package:fl_clash/qf/qf_google.dart';
import 'package:fl_clash/qf/qf_http_client.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_providers.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

class _HitServer {
  HttpServer? _server;
  int hits = 0;
  final int statusCode;
  final Map<String, dynamic> payload;

  _HitServer({this.statusCode = 200, this.payload = const {'ok': true}});

  String get base => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      hits++;
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() {
    QfEndpoints.resetForTest();
    QfHttpClient.coreRunningProbe = null;
    QfHttpClient.coreReachabilityOverride = null;
    QfHttpClient.corePort = 7890;
  });

  tearDown(() {
    QfEndpoints.resetForTest();
    QfHttpClient.coreRunningProbe = null;
    QfHttpClient.coreReachabilityOverride = null;
    QfRuntime.googleClientId = '';
    QfRuntime.googleWebClientId = '';
  });

  group('QfEndpoints rotation', () {
    test('order is manifest primary, manifest fallback, built-in', () {
      QfEndpoints.apply(
        primaryUrl: 'http://a.example/',
        backupUrl: 'http://b.example/',
      );
      expect(QfEndpoints.rotationFor('http://a.example/auth/login'), [
        'http://a.example/auth/login',
        'http://b.example/auth/login',
        '${QfConfig.directServerBaseUrl}/auth/login',
        '${QfConfig.fallbackServerBaseUrl}/auth/login',
      ]);
      // The order is global, not per-URL: a URL built on the fallback
      // still tries the manifest primary first.
      expect(QfEndpoints.rotationFor('http://b.example/auth/login'), [
        'http://a.example/auth/login',
        'http://b.example/auth/login',
        '${QfConfig.directServerBaseUrl}/auth/login',
        '${QfConfig.fallbackServerBaseUrl}/auth/login',
      ]);
    });

    test('foreign URLs are returned unchanged', () {
      QfEndpoints.apply(primaryUrl: 'http://a.example');
      expect(QfEndpoints.rotationFor('https://other.example/x'), [
        'https://other.example/x',
      ]);
    });

    test('the last successful base is tried first next time', () {
      QfEndpoints.apply(
        primaryUrl: 'http://a.example',
        backupUrl: 'http://b.example',
      );
      QfEndpoints.noteSuccess('http://b.example/auth/login');
      expect(QfEndpoints.lastGood, 'http://b.example');
      expect(QfEndpoints.rotationFor('http://a.example/auth/login'), [
        'http://b.example/auth/login',
        'http://a.example/auth/login',
        '${QfConfig.directServerBaseUrl}/auth/login',
        '${QfConfig.fallbackServerBaseUrl}/auth/login',
      ]);
    });

    test('the persisted last-good base is restored on launch', () async {
      SharedPreferences.setMockInitialValues({
        'qf_endpoints_last_good': 'http://b.example',
      });
      await QfEndpoints.loadPersisted();
      expect(QfEndpoints.lastGood, 'http://b.example');
    });

    test('apply trims trailing slashes and ignores an empty primary', () {
      QfEndpoints.apply(primaryUrl: 'http://a.example/');
      expect(QfEndpoints.primary, 'http://a.example');
      QfEndpoints.apply(primaryUrl: '');
      expect(QfEndpoints.primary, 'http://a.example');
      QfEndpoints.apply(backupUrl: 'http://b.example/');
      expect(QfEndpoints.fallback, 'http://b.example');
    });
  });

  group('manifest backup field', () {
    test('serverBaseUrlFallback survives a JSON round trip', () {
      final manifest = QfReleaseManifest.fromJson({
        'latestVersion': '1.1.2',
        'retiredBelowVersion': '0.0.0',
        'maintenance': false,
        'serverBaseUrl': 'https://primary.example',
        'serverBaseUrlFallback': 'https://backup.example',
        'googleClientId': 'web-id',
        'platforms': {},
      });
      expect(manifest.serverBaseUrlFallback, 'https://backup.example');
      expect(
        QfReleaseManifest.fromJson(manifest.toJson()).serverBaseUrlFallback,
        'https://backup.example',
      );
    });

    test('a manifest without the field parses with an empty backup', () {
      final manifest = QfReleaseManifest.fromJson({
        'latestVersion': '1.1.2',
        'maintenance': false,
        'serverBaseUrl': 'https://primary.example',
        'googleClientId': 'web-id',
      });
      expect(manifest.serverBaseUrlFallback, '');
    });
  });

  group('QfHttp dual entry', () {
    test('a dead primary falls over to the backup endpoint', () async {
      final backup = _HitServer(payload: {'ok': true, 'via': 'backup'});
      await backup.start();
      addTearDown(backup.stop);
      QfEndpoints.apply(
        primaryUrl: 'http://127.0.0.1:1',
        backupUrl: backup.base,
      );
      final data = await QfHttp.send('GET', 'http://127.0.0.1:1/health');
      expect(data['via'], 'backup');
      expect(backup.hits, 1);
    });

    test('a business error on the primary is not rotated away', () async {
      final primary = _HitServer(
        statusCode: 401,
        payload: {'ok': false, 'code': 'BAD_CREDENTIALS', 'message': '邮箱或密码不对'},
      );
      final backup = _HitServer();
      await primary.start();
      await backup.start();
      addTearDown(primary.stop);
      addTearDown(backup.stop);
      QfEndpoints.apply(primaryUrl: primary.base, backupUrl: backup.base);
      await expectLater(
        QfHttp.send('POST', '${primary.base}/auth/login', body: {}),
        throwsA(
          isA<QfApiException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.code, 'code', 'BAD_CREDENTIALS'),
        ),
      );
      expect(backup.hits, 0);
    });

    test('a login POST rotates past a dead first base', () async {
      final backup = _HitServer(payload: {'ok': true, 'via': 'backup'});
      await backup.start();
      addTearDown(backup.stop);
      QfEndpoints.apply(
        primaryUrl: 'http://127.0.0.1:1',
        backupUrl: backup.base,
      );
      final data = await QfHttp.send(
        'POST',
        'http://127.0.0.1:1/auth/login',
        body: {'email': 'a@b.c', 'password': 'secret'},
      );
      expect(data['via'], 'backup');
      expect(backup.hits, 1);
      expect(QfEndpoints.lastGood, backup.base);
    });

    test('a guest register POST rotates past a dead first base', () async {
      final backup = _HitServer(payload: {'ok': true, 'via': 'backup'});
      await backup.start();
      addTearDown(backup.stop);
      QfEndpoints.apply(
        primaryUrl: 'http://127.0.0.1:1',
        backupUrl: backup.base,
      );
      final data = await QfHttp.send(
        'POST',
        'http://127.0.0.1:1/guest/register',
        body: {'deviceHash': 'abc'},
      );
      expect(data['via'], 'backup');
      expect(backup.hits, 1);
    });

    test('an ordinary write POST still gets a single attempt', () async {
      final backup = _HitServer();
      await backup.start();
      addTearDown(backup.stop);
      QfEndpoints.apply(
        primaryUrl: 'http://127.0.0.1:1',
        backupUrl: backup.base,
      );
      await expectLater(
        QfHttp.send(
          'POST',
          'http://127.0.0.1:1/camps',
          body: {'name': 'x'},
        ),
        throwsA(
          isA<QfApiException>().having((e) => e.code, 'code', 'NETWORK'),
        ),
      );
      expect(backup.hits, 0);
    });

    test(
      'the built-in direct base serves when manifest bases are dead',
      () async {
        final direct = _HitServer(payload: {'ok': true, 'via': 'direct'});
        await direct.start();
        addTearDown(direct.stop);
        QfEndpoints.builtinDirect = direct.base;
        QfEndpoints.builtinFallback = 'http://127.0.0.1:2';
        QfEndpoints.apply(
          primaryUrl: 'http://127.0.0.1:1',
          backupUrl: 'http://127.0.0.1:3',
        );
        final data = await QfHttp.send(
          'POST',
          'http://127.0.0.1:1/auth/login',
          body: {'email': 'a@b.c', 'password': 'secret'},
        );
        expect(data['via'], 'direct');
        expect(direct.hits, 1);
      },
    );

    test('a dead remembered base does not block the rotation', () async {
      final backup = _HitServer(payload: {'ok': true, 'via': 'backup'});
      await backup.start();
      addTearDown(backup.stop);
      QfEndpoints.apply(
        primaryUrl: 'http://127.0.0.1:1',
        backupUrl: backup.base,
      );
      QfEndpoints.noteSuccess('http://127.0.0.1:1/auth/login');
      expect(QfEndpoints.lastGood, 'http://127.0.0.1:1');
      final data = await QfHttp.send(
        'POST',
        'http://127.0.0.1:1/auth/login',
        body: {'email': 'a@b.c', 'password': 'secret'},
      );
      expect(data['via'], 'backup');
      expect(QfEndpoints.lastGood, backup.base);
    });

    test(
      'a core that accepts then drops cannot blackhole the request',
      () async {
        final server = _HitServer(payload: {'ok': true, 'via': 'direct'});
        await server.start();
        addTearDown(server.stop);
        // A listener that takes the TCP connection (so the core probe
        // passes) and then drops it, like a core whose outbound is dead.
        final dropper = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => dropper.close());
        dropper.listen((socket) {
          socket.listen((_) {}, onDone: socket.destroy);
          socket.destroy();
        });
        QfHttpClient.corePort = dropper.port;
        QfHttpClient.coreRunningProbe = () => true;
        QfEndpoints.apply(primaryUrl: server.base, backupUrl: '');
        final data = await QfHttp.send('GET', '${server.base}/health');
        expect(data['via'], 'direct');
      },
    );
  });

  group('google config delivery', () {
    test('built-in IDs configure sign-in with no manifest ever fetched', () {
      QfRuntime.googleClientId = '';
      QfRuntime.googleWebClientId = '';
      expect(
        QfGoogleAuth.webClientIdForTest,
        QfConfig.builtinGoogleWebClientId,
      );
      expect(
        QfGoogleAuth.platformClientIdForTest,
        QfConfig.builtinGoogleAndroidClientId,
      );
      expect(QfGoogleAuth.webClientIdForTest, isNotEmpty);
    });

    test('a manifest overrides runtime IDs and endpoints together', () {
      final manifest = QfReleaseManifest.fromJson({
        'latestVersion': '1.1.2',
        'maintenance': false,
        'serverBaseUrl': 'https://primary.example',
        'serverBaseUrlFallback': 'https://backup.example',
        'googleClientId': 'manifest-web-id',
        'platforms': {
          'windows': {'googleClientId': 'manifest-windows-id'},
        },
      });
      qfApplyGoogleRuntime(manifest);
      expect(QfRuntime.googleWebClientId, 'manifest-web-id');
      expect(QfEndpoints.primary, 'https://primary.example');
      expect(QfEndpoints.fallback, 'https://backup.example');
    });
  });

  group('egress classification', () {
    test('timestamp and handshake errors read as handshake failures', () {
      expect(
        qfClassifyProbeFailure(
          errorKind: 'failed',
          message: 'dial tcp 1.2.3.4:443: bad timestamp in response',
        ),
        QfEgressStatus.handshakeFailed,
      );
      expect(
        qfClassifyProbeFailure(
          errorKind: 'failed',
          message: 'TLS handshake failed: authentication error',
        ),
        QfEgressStatus.handshakeFailed,
      );
    });

    test('timeouts and refusals read as an unreachable node', () {
      expect(
        qfClassifyProbeFailure(errorKind: 'timeout', message: 'i/o timeout'),
        QfEgressStatus.nodeUnreachable,
      );
      expect(
        qfClassifyProbeFailure(
          errorKind: 'failed',
          message: 'connect: connection refused',
        ),
        QfEgressStatus.nodeUnreachable,
      );
      expect(
        qfClassifyProbeFailure(errorKind: 'failed', message: ''),
        QfEgressStatus.nodeUnreachable,
      );
    });

    test('combine puts probe failure first, then takeover failure', () {
      expect(
        qfCombineEgress(
          probeOk: false,
          probeFailure: QfEgressStatus.nodeUnreachable,
          takeoverExpected: true,
          takeoverOk: false,
        ),
        QfEgressStatus.nodeUnreachable,
      );
      expect(
        qfCombineEgress(
          probeOk: true,
          probeFailure: QfEgressStatus.nodeUnreachable,
          takeoverExpected: true,
          takeoverOk: false,
        ),
        QfEgressStatus.takeoverFailed,
      );
      expect(
        qfCombineEgress(
          probeOk: true,
          probeFailure: QfEgressStatus.nodeUnreachable,
          takeoverExpected: false,
          takeoverOk: false,
        ),
        QfEgressStatus.ok,
      );
      expect(
        qfCombineEgress(
          probeOk: true,
          probeFailure: QfEgressStatus.nodeUnreachable,
          takeoverExpected: true,
          takeoverOk: true,
        ),
        QfEgressStatus.ok,
      );
    });
  });
}
