import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

// The naming chain end to end against a real socket server that
// declares its name in profile-title, as the merged subscription does:
// a fresh import takes the name, and a refresh renames a profile that
// still carries only the URL-host fallback, while a user-chosen name
// is never overridden.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late HttpServer server;
  late _MockCoreHandlerInterface core;
  HttpOverrides? testOverrides;

  String url() => 'http://${server.address.host}:${server.port}/sub/token123';

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
    request.attach(ProviderContainer().read);
    db.database = db.Database(NativeDatabase.memory());
    home = Directory.systemTemp.createTempSync('qf-import-label-chain-');
    await useAppPaths(home);
    testOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) {
        request.response.headers.set('profile-title', 'base64:QVdT57uE');
        request.response.write('proxies: []\n');
        unawaited(request.response.close());
      }),
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    HttpOverrides.global = testOverrides;
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  setUp(() {
    globalState.packageInfo = PackageInfo(
      appName: 'QFClash',
      packageName: 'com.qingfeng.qfclash',
      version: '2.0.1',
      buildNumber: '2026106308',
      buildSignature: '',
    );
    core = _MockCoreHandlerInterface();
    when(() => core.validateConfig(any())).thenAnswer((_) async => '');
  });

  testWidgets('a fresh URL import is named by the profile-title header, '
      'in state and in the stored row', (tester) async {
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    const size = Size(1200, 1000);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container.read(viewSizeProvider.notifier).value = size;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(withStatusManager: true, child: SizedBox()),
      ),
    );
    await tester.runAsync(
      () => container
          .read(profilesActionProvider.notifier)
          .addProfileFromLink(url()),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final profiles = container.read(profilesProvider);
    expect(profiles, hasLength(1));
    expect(profiles.single.label, 'AWS组');
    final rows = await tester.runAsync(
      () => db.database.profilesDao.query().get(),
    );
    expect(rows?.map((row) => row.label), ['AWS组']);
  });

  Future<Profile> refresh(Profile existing) async {
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([existing])),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    addTearDown(container.dispose);
    globalState.container = container;
    await container
        .read(profilesActionProvider.notifier)
        .updateProfile(existing);
    return container.read(profilesProvider).single;
  }

  test(
    'a refresh renames a host-fallback profile to the server name',
    () async {
      final existing = Profile.normal(
        url: url(),
      ).copyWith(label: server.address.host);
      expect((await refresh(existing)).label, 'AWS组');
    },
  );

  test('a refresh keeps a user-chosen name', () async {
    final existing = Profile.normal(url: url()).copyWith(label: '我的订阅');
    expect((await refresh(existing)).label, '我的订阅');
  });
}
