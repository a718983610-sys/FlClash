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

void _mockSecure() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async => null);
}

String _dayKeyFor(int epochSec) {
  final now = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  return '${now.year}-${now.month}-${now.day}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const t0 = 1760000000;

  QfSessionController offlineSession() {
    final session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:1';
    session.nowSecFn = () => t0;
    return session;
  }

  setUp(() {
    _mockSecure();
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({
      'qf_device_hash': 'hash-offline-1',
      'qf_device_name': 'test-box',
    });
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  test(
    'register transport failure enters offline guest, core unblocked',
    () async {
      final session = offlineSession();
      await session.enterGuest();
      expect(session.mode, QfMode.guest);
      expect(session.guestOffline, isTrue);
      expect(session.guestExhausted, isFalse);
      expect(session.guestUsage?.remainingSeconds, 7200);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('qf_guest_blocked_core'), isFalse);
      final reconcileId = prefs.getString('qf_guest_reconcile_id');
      expect(reconcileId, isNotNull);
      expect(reconcileId!.length, greaterThanOrEqualTo(8));
      expect(RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(reconcileId), isTrue);
      expect(reconcileId.split('').toSet().length, greaterThan(1));
    },
  );

  test('local ledger already full enters exhausted and blocks core', () async {
    SharedPreferences.setMockInitialValues({
      'qf_device_hash': 'hash-offline-1',
      'qf_device_name': 'test-box',
      'qf_guest_ledger_day': _dayKeyFor(t0),
      'qf_guest_ledger_used_sec': 7200,
    });
    final session = offlineSession();
    await session.enterGuest();
    expect(session.mode, QfMode.guest);
    expect(session.guestOffline, isTrue);
    expect(session.guestExhausted, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('qf_guest_blocked_core'), isTrue);
  });

  test('offline tick reaching the limit disconnects', () async {
    var now = t0;
    final session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:1';
    session.nowSecFn = () => now;
    var disconnected = false;
    session.onGuestExhaustedFn = () async {
      disconnected = true;
    };
    await session.enterGuest();
    expect(session.guestExhausted, isFalse);
    now = t0 + 7201;
    await session.tickOfflineGuest();
    expect(session.guestExhausted, isTrue);
    expect(disconnected, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('qf_guest_blocked_core'), isTrue);
  });

  test('business refusal does not fall back to offline guest', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'code': 'DEVICE_BANNED', 'message': '设备已被限制使用'}),
      );
      await request.response.close();
    });
    final session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
    session.nowSecFn = () => t0;
    await expectLater(
      session.enterGuest(),
      throwsA(
        isA<QfApiException>().having((e) => e.code, 'code', 'DEVICE_BANNED'),
      ),
    );
    expect(session.mode, isNot(QfMode.guest));
    expect(session.guestOffline, isFalse);
  });

  test(
    'recovery registers and the next heartbeat reconciles accrued seconds',
    () async {
      Map<String, dynamic>? heartbeatBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        final decoded = text.isEmpty
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(text) as Map);
        final Map<String, dynamic> body;
        if (request.uri.path == '/guest/register') {
          body = {
            'guestToken': 'gt-1',
            'heartbeatKey': 'ghk-1',
            'usedSeconds': 600,
            'dailyLimitSeconds': 7200,
            'remainingSeconds': 6600,
            'exhausted': false,
          };
        } else if (request.uri.path == '/guest/heartbeat') {
          heartbeatBody = decoded;
          body = {
            'usedSeconds': 660,
            'dailyLimitSeconds': 7200,
            'remainingSeconds': 6540,
            'exhausted': false,
            'offlineAppliedSeconds': 60,
            'offlineDuplicate': false,
          };
        } else {
          body = <String, dynamic>{};
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
        await request.response.close();
      });

      var now = t0;
      final session = QfSessionController();
      session.serverBaseUrl = 'http://127.0.0.1:1';
      session.nowSecFn = () => now;
      session.isRunningFn = () => true;
      await session.enterGuest();
      expect(session.guestOffline, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final reconcileId = prefs.getString('qf_guest_reconcile_id');
      expect(reconcileId, isNotNull);

      now = t0 + 60;
      await session.tickOfflineGuest();
      expect(prefs.getInt('qf_guest_offline_accrued_sec'), 60);

      session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
      await session.tryRecoverOfflineGuest();
      expect(session.guestOffline, isFalse);
      expect(session.guestUsage?.usedSeconds, 600);

      await session.beat();
      expect(heartbeatBody, isNotNull);
      expect(heartbeatBody!['offlineAccruedSec'], 60);
      expect(heartbeatBody!['reconcileId'], reconcileId);
      expect(session.guestUsage?.usedSeconds, 660);
      expect(prefs.getInt('qf_guest_offline_accrued_sec'), 0);
      expect(prefs.getString('qf_guest_reconcile_id'), isNull);
    },
  );

  test('rejected heartbeat keeps the guest sequence for retry', () async {
    final seqs = <int>[];
    var heartbeatCalls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final decoded = text.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(text) as Map);
      if (request.uri.path == '/guest/register') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'guestToken': 'gt-1',
            'heartbeatKey': 'ghk-1',
            'usedSeconds': 0,
            'dailyLimitSeconds': 7200,
            'remainingSeconds': 7200,
            'exhausted': false,
          }),
        );
      } else if (request.uri.path == '/guest/heartbeat') {
        heartbeatCalls++;
        seqs.add((decoded['seq'] as num).toInt());
        if (heartbeatCalls == 1) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'code': 'RECONCILE_ID_INVALID',
              'message': '对账编号无效',
            }),
          );
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'usedSeconds': 0,
              'dailyLimitSeconds': 7200,
              'remainingSeconds': 7200,
              'exhausted': false,
            }),
          );
        }
      }
      await request.response.close();
    });

    final session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
    session.nowSecFn = () => t0;
    session.isRunningFn = () => true;
    await session.enterGuest();
    expect(session.guestOffline, isFalse);
    await session.beat();
    await session.beat();
    expect(seqs.length, 2);
    expect(seqs[1], seqs[0]);
  });
}
