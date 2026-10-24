import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/qf/qf_gate.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_providers.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

void _mockSecureStore(Map<String, String> store) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        final args = call.arguments is Map
            ? Map<dynamic, dynamic>.from(call.arguments as Map)
            : const <dynamic, dynamic>{};
        final key = (args['key'] ?? '').toString();
        switch (call.method) {
          case 'read':
            return store[key];
          case 'write':
            store[key] = (args['value'] ?? '').toString();
            return null;
          case 'delete':
            store.remove(key);
            return null;
          case 'readAll':
            return store;
          default:
            return null;
        }
      });
}

QfReleaseManifest _forceManifest() {
  return const QfReleaseManifest(
    latestVersion: '2.0.0',
    retiredBelowVersion: '0.0.0',
    minUsableVersion: '2.0.0',
    maintenance: false,
    serverBaseUrl: '',
    googleClientId: '',
    platforms: {
      'windows': QfPlatformRelease(
        downloadUrl: 'https://example.com/QFClash-Windows-v2.0.0.exe',
        notes: 'notes',
      ),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('force update requires a fresh manifest', () {
    setUp(() {
      QfUpdateService.platformKeyOverride = 'windows';
    });

    tearDown(() {
      QfUpdateService.platformKeyOverride = null;
      QfUpdateService.manifestFetcherForTest = null;
    });

    test('fresh manifest above min usable forces', () async {
      SharedPreferences.setMockInitialValues({});
      QfUpdateService.manifestFetcherForTest = () async => _forceManifest();
      final check = await QfUpdateService.check('1.0.0');
      expect(check.decision, QfUpdateDecision.force);
      expect(check.manifestFresh, isTrue);
    });

    test('cached force manifest never blocks when fetch fails', () async {
      SharedPreferences.setMockInitialValues({
        'qf_release_manifest_cache': jsonEncode(_forceManifest().toJson()),
      });
      QfUpdateService.manifestFetcherForTest = () async => null;
      final check = await QfUpdateService.check('1.0.0');
      expect(check.decision, QfUpdateDecision.none);
      expect(check.manifestFresh, isFalse);
      expect(check.manifest, isNotNull);
      expect(check.latestVersion, '2.0.0');
    });

    test('no manifest at all does not block', () async {
      SharedPreferences.setMockInitialValues({});
      QfUpdateService.manifestFetcherForTest = () async => null;
      final check = await QfUpdateService.check('1.0.0');
      expect(check.decision, QfUpdateDecision.none);
      expect(check.manifestFresh, isFalse);
    });
  });

  group('offline cold start restores the cached session at once', () {
    HttpServer? server;

    setUp(() {
      HttpOverrides.global = _RealHttpOverrides();
    });

    tearDown(() async {
      HttpOverrides.global = null;
      await server?.close(force: true);
      server = null;
    });

    Future<String> stallingServerUrl() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((request) {
        // Accept and never answer: a walled network where requests hang
        // until the client-side timeout instead of failing fast.
      });
      return 'http://127.0.0.1:${server!.port}';
    }

    test('user session: init returns promptly with a hanging server', () async {
      _mockSecureStore({
        'qf_access_token': 'acc-old',
        'qf_refresh_token': 'ref-old',
        'qf_access_expires_at': '1',
        'qf_heartbeat_key': 'hk',
      });
      SharedPreferences.setMockInitialValues({
        'qf_mode': 'user',
        'qf_user_email': 'a@b.c',
        'qf_user_id': 7,
      });
      final session = QfSessionController();
      session.serverBaseUrl = await stallingServerUrl();
      final watch = Stopwatch()..start();
      await session.init(envEmulator: false);
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(session.mode, QfMode.user);
      expect(session.userId, 7);
      await server!.close(force: true);
      server = null;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(session.mode, QfMode.user);
    });

    test('guest session: init returns promptly with a hanging server', () async {
      _mockSecureStore({
        'qf_guest_token': 'guest-token',
        'qf_guest_heartbeat_key': 'gk',
      });
      SharedPreferences.setMockInitialValues({'qf_mode': 'guest'});
      final session = QfSessionController();
      session.serverBaseUrl = await stallingServerUrl();
      final watch = Stopwatch()..start();
      await session.init(envEmulator: false);
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(session.mode, QfMode.guest);
      await server!.close(force: true);
      server = null;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(session.mode, QfMode.guest);
    });
  });

  group('install outcome contract', () {
    final calls = <(String, Object?)>[];
    Object? scripted;
    var throwOnCall = false;

    setUp(() async {
      calls.clear();
      scripted = null;
      throwOnCall = false;
      QfUpdateService.isAndroidForTest = true;
      QfUpdateService.appChannelInvokerForTest = (method, arguments) async {
        calls.add((method, arguments));
        if (throwOnCall) throw StateError('channel down');
        return scripted;
      };
    });

    tearDown(() {
      QfUpdateService.isAndroidForTest = null;
      QfUpdateService.isWindowsForTest = null;
      QfUpdateService.appChannelInvokerForTest = null;
    });

    Future<File> tempApk() async {
      final dir = await Directory.systemTemp.createTemp('qf_install_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/QFClash-Android-v2.0.0.apk');
      await file.writeAsBytes([1, 2, 3]);
      return file;
    }

    test('launched result maps to launched with the file path', () async {
      final file = await tempApk();
      scripted = 'launched';
      final outcome = await QfUpdateService.installOutcome(file);
      expect(outcome, QfInstallOutcome.launched);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'installApk');
      expect((calls.single.$2 as Map)['path'], file.path);
      expect(await QfUpdateService.install(file), isTrue);
    });

    test('needs_permission stays distinct from failure', () async {
      final file = await tempApk();
      scripted = 'needs_permission';
      final outcome = await QfUpdateService.installOutcome(file);
      expect(outcome, QfInstallOutcome.needsPermission);
      expect(await QfUpdateService.install(file), isFalse);
    });

    test('legacy bool results keep working', () async {
      final file = await tempApk();
      scripted = true;
      expect(
        await QfUpdateService.installOutcome(file),
        QfInstallOutcome.launched,
      );
      scripted = false;
      expect(
        await QfUpdateService.installOutcome(file),
        QfInstallOutcome.failed,
      );
      scripted = null;
      expect(
        await QfUpdateService.installOutcome(file),
        QfInstallOutcome.failed,
      );
    });

    test('missing file and wrong extension never reach the channel', () async {
      final missing = File('${Directory.systemTemp.path}/qf-nope-2.0.0.apk');
      expect(
        await QfUpdateService.installOutcome(missing),
        QfInstallOutcome.failed,
      );
      final dir = await Directory.systemTemp.createTemp('qf_install_test');
      addTearDown(() => dir.delete(recursive: true));
      final zip = File('${dir.path}/QFClash-Windows-v2.0.0.zip');
      await zip.writeAsBytes([1]);
      expect(await QfUpdateService.installOutcome(zip), QfInstallOutcome.failed);
      expect(calls, isEmpty);
    });

    test('channel errors collapse to failed', () async {
      final file = await tempApk();
      throwOnCall = true;
      expect(
        await QfUpdateService.installOutcome(file),
        QfInstallOutcome.failed,
      );
    });

    test('permission settings opens through its own channel method', () async {
      scripted = true;
      expect(await QfUpdateService.openInstallPermissionSettings(), isTrue);
      expect(calls.single.$1, 'openUnknownAppSettings');
      scripted = false;
      expect(await QfUpdateService.openInstallPermissionSettings(), isFalse);
    });
  });

  testWidgets('qfToast renders fully above the bottom navigation bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => qfToast(context, '网络异常，请稍后重试'),
                child: const Text('TRIGGER'),
              ),
            ),
          ),
          bottomNavigationBar: NavigationBar(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: '首页'),
              NavigationDestination(icon: Icon(Icons.person), label: '我的'),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('TRIGGER'));
    await tester.pump();
    final toast = find.text('网络异常，请稍后重试');
    expect(toast, findsOneWidget);
    final toastRect = tester.getRect(toast);
    final barRect = tester.getRect(find.byType(NavigationBar));
    expect(toastRect.bottom, lessThanOrEqualTo(barRect.top));
    await tester.pump(const Duration(seconds: 5));
    expect(toast, findsNothing);
  });

  testWidgets('gate renders the main UI with every network dead', (
    tester,
  ) async {
    _mockSecureStore({
      'qf_access_token': 'acc-old',
      'qf_refresh_token': 'ref-old',
      'qf_access_expires_at': '1',
      'qf_heartbeat_key': 'hk',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (call) async => {
            'appName': 'QFClash',
            'packageName': 'com.qingfeng.qfclash',
            'version': '1.0.0',
            'buildNumber': '1',
            'buildSignature': '',
          },
        );
    SharedPreferences.setMockInitialValues({
      'qf_mode': 'user',
      'qf_user_email': 'a@b.c',
      'qf_user_id': 7,
    });
    QfUpdateService.manifestFetcherForTest = () async => null;
    addTearDown(() => QfUpdateService.manifestFetcherForTest = null);
    final session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:1';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [qfSessionProvider.overrideWithValue(session)],
        child: const MaterialApp(
          home: QfSessionGate(
            child: Scaffold(body: Center(child: Text('MAIN-UI-MARKER'))),
          ),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('MAIN-UI-MARKER'), findsOneWidget);
    expect(find.byType(QfBlockingPage), findsNothing);
    // Drain the boot background fetches and their timeout timers so the
    // test does not end with timers still pending. The heartbeat only
    // starts once the background phase reaches it, so stop it after the
    // drain as well as before.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 30));
    }
    session.stopHeartbeat();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
