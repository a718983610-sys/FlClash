import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/qf/qf_egress.dart';
import 'package:fl_clash/qf/qf_providers.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:fl_clash/views/dashboard/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

// Banner clearance regression (2.0.1): the dashboard's floating bar
// overlays the body, so the banner group must start below the bar
// instead of sliding under the title, and the direct-only profile
// state must not surface any reminder anywhere on the page.
class _GuestSession extends QfSessionController {
  _GuestSession() {
    mode = QfMode.guest;
    guestUsage = const QfGuestUsage(
      dailyLimitSeconds: 7200,
      usedSeconds: 1800,
      remainingSeconds: 5400,
      exhausted: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  ProviderContainer makeContainer({
    QfSessionController? session,
    bool started = false,
    List<Profile> profiles = const [],
  }) {
    return ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles(profiles)),
        if (session != null) qfSessionProvider.overrideWithValue(session),
        if (started) isStartProvider.overrideWith((ref) => true),
      ],
    );
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    required SupportPlatform platform,
    required Size size,
    double statusBar = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: statusBar);
    addTearDown(tester.view.reset);
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = size;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(child: DashboardView(platform: platform)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  tearDown(() => container.dispose());

  testWidgets('guest banner clears the floating bar on a phone', (
    tester,
  ) async {
    container = makeContainer(session: _GuestSession());
    await pumpDashboard(
      tester,
      platform: SupportPlatform.Android,
      size: const Size(390, 840),
      statusBar: 24,
    );
    final banner = find.text('今日剩余免费时长：1 小时 30 分钟');
    expect(banner, findsOneWidget);
    final title = find.text('Dashboard');
    expect(title, findsOneWidget);
    final bannerRect = tester.getRect(banner);
    final titleRect = tester.getRect(title);
    // The whole banner sits below the bar's title text, never under it.
    expect(bannerRect.top, greaterThanOrEqualTo(titleRect.bottom));
    expect(bannerRect.overlaps(titleRect), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guest and egress banners stack without overlapping', (
    tester,
  ) async {
    container = makeContainer(session: _GuestSession(), started: true);
    await pumpDashboard(
      tester,
      platform: SupportPlatform.Android,
      size: const Size(390, 840),
      statusBar: 24,
    );
    container
        .read(qfEgressStateProvider.notifier)
        .set(const QfEgressState(QfEgressStatus.nodeUnreachable));
    await tester.pump();
    final guest = find.text('今日剩余免费时长：1 小时 30 分钟');
    final egress = find.text('已连接，但当前节点无法访问网络，请切换节点后重试。');
    expect(guest, findsOneWidget);
    expect(egress, findsOneWidget);
    final titleRect = tester.getRect(find.text('Dashboard'));
    final guestRect = tester.getRect(guest);
    final egressRect = tester.getRect(egress);
    expect(guestRect.top, greaterThanOrEqualTo(titleRect.bottom));
    expect(egressRect.top, greaterThanOrEqualTo(guestRect.bottom));
    expect(egressRect.overlaps(guestRect), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop keeps its designed full-area geometry', (tester) async {
    container = makeContainer(started: true);
    await pumpDashboard(
      tester,
      platform: SupportPlatform.Windows,
      size: const Size(1280, 800),
    );
    container
        .read(qfEgressStateProvider.notifier)
        .set(const QfEgressState(QfEgressStatus.nodeUnreachable));
    await tester.pump();
    // The banner still renders on desktop, and the dashboard below it
    // keeps the exact density geometry the layout contract fixes
    // (compact rows at this size): the Android clearance must not
    // shrink the desktop area.
    expect(find.text('已连接，但当前节点无法访问网络，请切换节点后重试。'), findsOneWidget);
    expect(tester.getRect(find.byType(CurrentOutboundCard).first).height, 176);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a direct-only profile shows no reminder anywhere', (
    tester,
  ) async {
    container = makeContainer(profiles: [Profile.normal(label: '空订阅')]);
    await pumpDashboard(
      tester,
      platform: SupportPlatform.Android,
      size: const Size(390, 840),
      statusBar: 24,
    );
    container.read(qfDirectOnlyProfileProvider.notifier).update(true);
    await tester.pump();
    expect(find.textContaining('直连模式运行'), findsNothing);
    expect(find.textContaining('当前订阅没有可用节点'), findsNothing);
    expect(find.textContaining('当前订阅没有任何可用节点'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
