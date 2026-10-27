import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_gate.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_providers.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every core start/stop request so a test can prove that an
/// update decision change never asks for the core to stop.
class _RecordingSetupAction extends SetupAction {
  static final requests = <bool>[];

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    requests.add(running);
    return true;
  }
}

QfReleaseManifest _manifest({
  String latestVersion = '1.0.0',
  String retiredBelowVersion = '0.0.0',
  String minUsableVersion = '0.0.0',
  bool maintenance = false,
}) {
  return QfReleaseManifest(
    latestVersion: latestVersion,
    retiredBelowVersion: retiredBelowVersion,
    minUsableVersion: minUsableVersion,
    maintenance: maintenance,
    serverBaseUrl: 'http://127.0.0.1:1',
    googleClientId: '',
    platforms: const {
      'windows': QfPlatformRelease(
        downloadUrl: 'https://example.invalid/QFClash-Windows.exe',
        notes: '测试说明',
      ),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );

  late QfSessionController session;
  QfReleaseManifest scripted = _manifest();

  setUp(() {
    scripted = _manifest();
    _RecordingSetupAction.requests.clear();
    QfUpdateService.platformKeyOverride = 'windows';
    QfUpdateService.manifestFetcherForTest = () async => scripted;
    QfManifestService.fetcherForTest = () async => scripted;
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (
      call,
    ) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>();
      return switch (call.method) {
        'read' => switch (args?['key']) {
          'qf_access_token' => 'access-token',
          'qf_refresh_token' => 'refresh-token',
          _ => null,
        },
        'readAll' => <String, String>{
          'qf_access_token': 'access-token',
          'qf_refresh_token': 'refresh-token',
        },
        _ => null,
      };
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      packageInfoChannel,
      (call) async {
        if (call.method != 'getAll') return null;
        return <String, dynamic>{
          'appName': 'QFClash',
          'packageName': 'com.qingfeng.qfclash',
          'version': '1.0.0',
          'buildNumber': '1',
          'buildSignature': '',
          'installerStore': '',
        };
      },
    );
    SharedPreferences.setMockInitialValues({
      'qf_mode': 'user',
      'qf_user_email': 'member@example.com',
      'qf_user_id': 7,
    });
    session = QfSessionController();
    session.serverBaseUrl = 'http://127.0.0.1:1';
  });

  tearDown(() {
    QfUpdateService.onFreshCheck = null;
    QfUpdateService.manifestFetcherForTest = null;
    QfManifestService.fetcherForTest = null;
    QfUpdateService.platformKeyOverride = null;
    session.dispose();
  });

  Future<void> bootGate(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          qfSessionProvider.overrideWithValue(session),
          setupActionProvider.overrideWith(_RecordingSetupAction.new),
        ],
        child: const MaterialApp(
          home: QfSessionGate(child: Text('MAIN-UI-MARKER')),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('MAIN-UI-MARKER'), findsOneWidget);
    expect(find.byType(QfBlockingPage), findsNothing);
    expect(_RecordingSetupAction.requests, isNot(contains(false)));
  }

  Future<void> flipDecision(
    WidgetTester tester,
    QfReleaseManifest next,
  ) async {
    scripted = next;
    QfUpdateService.onFreshCheck?.call(QfUpdateCheck.none);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    // Flush the boot-time manifest/region timeouts, then disarm the
    // session timers before the widget tree goes away.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 30));
    }
    session.stopHeartbeat();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpWidget(const SizedBox());
  }

  // One boot drives every flip: the gate is a once-per-process surface,
  // and a second mount in the same test process starves on statics left
  // over from the first boot's fake-async zone.
  testWidgets('update decision flips mid-session never stop the core', (
    tester,
  ) async {
    await bootGate(tester);

    await flipDecision(
      tester,
      _manifest(latestVersion: '2.0.0', minUsableVersion: '2.0.0'),
    );
    expect(find.byType(QfBlockingPage), findsOneWidget);
    expect(find.text(QfCopy.forceUpdateTitle), findsOneWidget);
    expect(_RecordingSetupAction.requests, isNot(contains(false)));

    await flipDecision(tester, _manifest(maintenance: true));
    expect(find.byType(QfBlockingPage), findsOneWidget);
    expect(find.text(QfCopy.maintenanceTitle), findsOneWidget);
    expect(_RecordingSetupAction.requests, isNot(contains(false)));

    await flipDecision(
      tester,
      _manifest(latestVersion: '2.0.0', retiredBelowVersion: '2.0.0'),
    );
    expect(find.byType(QfBlockingPage), findsOneWidget);
    expect(find.text(QfCopy.retiredTitle), findsOneWidget);
    expect(_RecordingSetupAction.requests, isNot(contains(false)));

    await flipDecision(tester, _manifest());
    expect(find.byType(QfBlockingPage), findsNothing);
    expect(find.text('MAIN-UI-MARKER'), findsOneWidget);
    expect(_RecordingSetupAction.requests, isNot(contains(false)));

    await settle(tester);
  });
}
