import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  final savedTimeouts = <String, Duration>{};
  var savedRetries = 1;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('qf_update_dl');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );
  });

  setUp(() {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    savedTimeouts['connect'] = QfUpdateService.connectTimeout;
    savedTimeouts['response'] = QfUpdateService.responseTimeout;
    savedTimeouts['stall'] = QfUpdateService.stallTimeout;
    savedTimeouts['overall'] = QfUpdateService.overallTimeout;
    savedTimeouts['retryDelay'] = QfUpdateService.retryDelay;
    savedTimeouts['install'] = QfUpdateService.installTimeout;
    savedRetries = QfUpdateService.maxAutoRetries;
    QfUpdateService.connectTimeout = const Duration(seconds: 2);
    QfUpdateService.responseTimeout = const Duration(seconds: 1);
    QfUpdateService.stallTimeout = const Duration(seconds: 1);
    QfUpdateService.overallTimeout = const Duration(seconds: 20);
    QfUpdateService.retryDelay = const Duration(milliseconds: 50);
    QfUpdateService.maxAutoRetries = 1;
    QfUpdateService.installTimeout = const Duration(milliseconds: 500);
  });

  tearDown(() {
    HttpOverrides.global = null;
    QfUpdateService.connectTimeout = savedTimeouts['connect']!;
    QfUpdateService.responseTimeout = savedTimeouts['response']!;
    QfUpdateService.stallTimeout = savedTimeouts['stall']!;
    QfUpdateService.overallTimeout = savedTimeouts['overall']!;
    QfUpdateService.retryDelay = savedTimeouts['retryDelay']!;
    QfUpdateService.installTimeout = savedTimeouts['install']!;
    QfUpdateService.maxAutoRetries = savedRetries;
    QfUpdateService.isAndroidForTest = null;
    QfUpdateService.isWindowsForTest = null;
    QfUpdateService.appChannelInvokerForTest = null;
  });

  Future<HttpServer> serve(
    FutureOr<void> Function(HttpRequest request, int hit) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    server.listen((request) {
      hits++;
      unawaited(Future<void>(() => handler(request, hits)));
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  String urlOf(HttpServer server) =>
      'http://${server.address.host}:${server.port}/QFClash-pkg.apk';

  test('stall before response times out and auto-retries once', () async {
    var hits = 0;
    final server = await serve((request, hit) {
      hits = hit;
      // Accept and never respond.
    });
    final sw = Stopwatch()..start();
    await expectLater(
      QfUpdateService.download(urlOf(server), onProgress: (_) {}),
      throwsA(
        isA<QfApiException>()
            .having((e) => e.code, 'code', 'TIMEOUT')
            .having(
              (e) => e.message,
              'message',
              contains('连接下载服务器超时'),
            ),
      ),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    expect(hits, 2, reason: 'one auto-retry after the first timeout');
  });

  test('stall mid-body times out instead of hanging', () async {
    final server = await serve((request, hit) async {
      request.response.statusCode = 200;
      request.response.contentLength = 100;
      request.response.add(List<int>.filled(10, 7));
      await request.response.flush();
      // Then silence: the body never completes.
    });
    await expectLater(
      QfUpdateService.download(urlOf(server), onProgress: (_) {}),
      throwsA(isA<QfApiException>().having((e) => e.code, 'code', 'TIMEOUT')),
    );
  });

  test('healthy download reports bytes and verifies sha256', () async {
    final body = List<int>.generate(8192, (i) => i % 251);
    final digest = crypto.sha256.convert(body).toString();
    final server = await serve((request, hit) async {
      request.response.statusCode = 200;
      request.response.contentLength = body.length;
      request.response.add(body.sublist(0, 3000));
      await request.response.flush();
      request.response.add(body.sublist(3000));
      await request.response.close();
    });
    var lastProgress = 0.0;
    int? lastTotal;
    final file = await QfUpdateService.download(
      urlOf(server),
      onProgress: (value) => lastProgress = value,
      onBytes: (received, total) => lastTotal = total,
      expectedSha256: digest,
      expectedSizeBytes: body.length,
    );
    expect(lastProgress, 1);
    expect(lastTotal, body.length);
    expect(await file.readAsBytes(), body);
  });

  test('auto-retry recovers when the second attempt is healthy', () async {
    final body = utf8.encode('second-attempt-body');
    final server = await serve((request, hit) async {
      if (hit == 1) return; // First attempt stalls forever.
      request.response.statusCode = 200;
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
    var retried = false;
    final file = await QfUpdateService.download(
      urlOf(server),
      onProgress: (_) {},
      onAutoRetry: () => retried = true,
    );
    expect(retried, isTrue);
    expect(await file.readAsBytes(), body);
  });

  test('cancel aborts a slow download promptly', () async {
    final server = await serve((request, hit) async {
      request.response.statusCode = 200;
      request.response.contentLength = 100000;
      request.response.bufferOutput = false;
      // Drip one chunk, then keep the body open indefinitely.
      request.response.add(List<int>.filled(100, 3));
      await request.response.flush();
    });
    final control = QfDownloadControl();
    var sawBytes = false;
    final future = QfUpdateService.download(
      urlOf(server),
      control: control,
      onProgress: (_) {},
      onBytes: (received, total) {
        if (received > 0) sawBytes = true;
      },
    );
    for (var i = 0; i < 30 && !sawBytes; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(sawBytes, isTrue);
    control.cancel();
    await expectLater(
      future.timeout(const Duration(seconds: 3)),
      throwsA(
        isA<QfApiException>().having((e) => e.code, 'code', 'CANCELLED'),
      ),
    );
  });

  test('http 404 fails fast without a retry', () async {
    var hits = 0;
    final server = await serve((request, hit) async {
      hits = hit;
      request.response.statusCode = 404;
      await request.response.close();
    });
    await expectLater(
      QfUpdateService.download(urlOf(server), onProgress: (_) {}),
      throwsA(
        isA<QfApiException>()
            .having((e) => e.code, 'code', 'DOWNLOAD')
            .having((e) => e.status, 'status', 404),
      ),
    );
    expect(hits, 1);
  });

  test('install channel that never answers times out as failed', () async {
    QfUpdateService.isAndroidForTest = true;
    QfUpdateService.appChannelInvokerForTest =
        (method, arguments) => Completer<Object?>().future;
    final apk = File('${tmp.path}/QFClash-pkg.apk');
    await apk.writeAsBytes([1, 2, 3]);
    final sw = Stopwatch()..start();
    final outcome = await QfUpdateService.installOutcome(apk);
    expect(outcome, QfInstallOutcome.failed);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('qfFormatBytes renders B, KB and MB', () {
    expect(qfFormatBytes(512), '512 B');
    expect(qfFormatBytes(2048), '2.0 KB');
    expect(qfFormatBytes(63 * 1024 * 1024), '63.0 MB');
  });
}
