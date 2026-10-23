import 'dart:convert';
import 'dart:io';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockSecure();
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({
      'qf_device_hash': 'hash-1',
      'qf_device_name': 'test-box',
    });
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<QfSessionController> loggedInSession(
    Map<String, dynamic> Function(int heartbeatCall) heartbeatBody,
  ) async {
    var heartbeatCalls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      final Map<String, dynamic> body;
      if (request.uri.path == '/auth/login') {
        body = {
          'accessToken': 'acc-1',
          'refreshToken': 'ref-1',
          'accessExpiresAt': 9999999999,
          'heartbeatKey': 'hk',
          'user': {'id': 7, 'email': 'a@b.c', 'username': 'tester123'},
        };
      } else if (request.uri.path == '/points/heartbeat') {
        heartbeatCalls++;
        body = heartbeatBody(heartbeatCalls);
      } else {
        body = <String, dynamic>{};
      }
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
    final session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:${server.port}';
    await session.login(emailInput: 'a@b.c', password: 'pw-123456');
    session.isRunningFn = () => true;
    return session;
  }

  test(
    'disconnect command stops the core and keeps the session alive',
    () async {
      var disconnects = 0;
      final session = await loggedInSession(
        (call) => call == 1
            ? {
                'accepted': true,
                'commands': [
                  {'type': 'disconnect'},
                ],
              }
            : {'accepted': true},
      );
      session.onForceDisconnectFn = () async {
        disconnects++;
      };
      await session.beat();
      expect(disconnects, 1);
      expect(session.mode, QfMode.user);
      expect(session.userId, 7);
      // The command is consumed once: a later heartbeat without commands
      // must not disconnect again, so an immediate reconnect stays up.
      await session.beat();
      expect(disconnects, 1);
    },
  );

  test('heartbeat without commands leaves the core running', () async {
    var disconnects = 0;
    final session = await loggedInSession((_) => {'accepted': true});
    session.onForceDisconnectFn = () async {
      disconnects++;
    };
    await session.beat();
    expect(disconnects, 0);
  });

  test('unknown command types are ignored', () async {
    var disconnects = 0;
    final session = await loggedInSession(
      (_) => {
        'accepted': true,
        'commands': [
          {'type': 'reboot'},
          'disconnect',
        ],
      },
    );
    session.onForceDisconnectFn = () async {
      disconnects++;
    };
    await session.beat();
    expect(disconnects, 0);
    expect(session.mode, QfMode.user);
  });
}
