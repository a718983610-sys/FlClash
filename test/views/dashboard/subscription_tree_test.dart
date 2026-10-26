import 'dart:io';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/layout.dart';
import 'package:fl_clash/views/dashboard/widgets/subscription_tree.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/app_paths.dart';
import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

Profile _profile(int id, String label) => Profile(
  id: id,
  label: label,
  url: 'https://sub$id.example.com/link',
  autoUpdateDuration: Duration.zero,
);

const _awsYaml = '''
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 东京SS
      - DIRECT
''';

const _cyberYaml = '''
proxy-groups:
  - name: CyberGuard
    type: select
    proxies:
      - 节点甲
  - name: 自动选择
    type: url-test
    proxies:
      - 节点甲
  - name: 故障转移
    type: fallback
    proxies:
      - 节点甲
''';

void main() {
  late ProviderContainer container;

  setUpAll(() async {
    final home = Directory.systemTemp.createTempSync('subscription_tree');
    addTearDown(() => home.deleteSync(recursive: true));
    await useAppPaths(home);
    SharedPreferences.setMockInitialValues({});
    final profilesDir = Directory(p.join(home.path, 'profiles'));
    await profilesDir.create(recursive: true);
    await File(p.join(profilesDir.path, '1.yaml')).writeAsString(_awsYaml);
    await File(p.join(profilesDir.path, '2.yaml')).writeAsString(_cyberYaml);
  });

  setUp(() {
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(
          () => TestProfiles([_profile(1, 'AWS组'), _profile(2, 'CyberGuard')]),
        ),
        viewSizeProvider.overrideWithBuild((_, _) => const Size(1200, 1000)),
      ],
    );
    globalState.container = container;
    container.listen(currentProfileIdProvider, (_, _) {});
    container.read(currentProfileIdProvider.notifier).value = 1;
    addTearDown(container.dispose);
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    DashboardDensity density = DashboardDensity.standard,
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: density.isDesktop ? 480 : 360,
                child: DashboardDensityScope(
                  density: density,
                  scale: 1,
                  child: const SubscriptionTreeCard(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// File-backed groups resolve through real IO, which the fake-async
  /// zone cannot advance; pump in real time until [finder] lands.
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  testWidgets('one 我的订阅 root, profile names are row titles', (tester) async {
    await pumpCard(tester);

    expect(find.text('我的订阅'), findsOneWidget);
    expect(find.text('AWS组'), findsOneWidget);
    expect(find.text('CyberGuard'), findsOneWidget);
    expect(find.text('当前使用'), findsOneWidget);
    expect(find.text('添加订阅'), findsOneWidget);
    expect(find.text('添加节点'), findsOneWidget);

    // Row titles carry the title style, not the old caption treatment.
    final awsTitle = tester.widget<Text>(find.text('AWS组'));
    expect(awsTitle.style?.fontWeight, FontWeight.w600);
    final rootTitle = tester.widget<Text>(find.text('我的订阅'));
    expect(rootTitle.style?.fontWeight, FontWeight.w600);
    expect(awsTitle.style?.fontSize, rootTitle.style?.fontSize);

    expect(tester.takeException(), isNull);
  });

  testWidgets('same structure at mobile density', (tester) async {
    await pumpCard(tester, density: DashboardDensity.mobile);

    expect(find.text('我的订阅'), findsOneWidget);
    expect(find.text('AWS组'), findsOneWidget);
    expect(find.text('CyberGuard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanding a profile lists its groups', (tester) async {
    await pumpCard(tester);

    // The current profile starts expanded (restored default), so its
    // file groups show; the other profile stays folded.
    await pumpUntilFound(tester, find.text('节点选择'));
    expect(find.text('节点选择'), findsOneWidget);
    expect(find.text('自动选择'), findsNothing);
    expect(find.text('故障转移'), findsNothing);

    await tester.tap(find.text('CyberGuard').first);
    await tester.pump();
    await pumpUntilFound(tester, find.text('自动选择'));
    expect(find.text('自动选择'), findsOneWidget);
    expect(find.text('故障转移'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folding the root hides every profile row', (tester) async {
    await pumpCard(tester);
    expect(find.text('AWS组'), findsOneWidget);

    await tester.tap(find.text('我的订阅'));
    await tester.pump();
    expect(find.text('AWS组'), findsNothing);
    expect(find.text('CyberGuard'), findsNothing);
    // The add actions stay reachable with the root folded.
    expect(find.text('添加订阅'), findsOneWidget);

    await tester.tap(find.text('我的订阅'));
    await tester.pump();
    expect(find.text('AWS组'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
