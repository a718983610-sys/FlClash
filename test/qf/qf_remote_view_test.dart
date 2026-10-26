import 'dart:async';

import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/qf_remote_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    globalState.container = container;
    addTearDown(container.dispose);
  });

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('login stage lays out inside the viewport, nothing overlaps', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: QfRemoteView()),
      ),
    );
    // The restore pass resolves to "no kept session" and swaps the
    // checking spinner for the login form.
    await tester.pump();
    await tester.pump();

    expect(find.text('登录 QFRemote'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    for (final field in find.byType(TextField).evaluate()) {
      expect(tester.getSize(find.byWidget(field.widget)).height, lessThan(200));
    }

    final loginButton = find.widgetWithText(FilledButton, '登录');
    expect(loginButton, findsOneWidget);
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      tester.getRect(loginButton).bottom,
      lessThanOrEqualTo(viewportHeight),
    );

    // The page's own heading must clear the app bar title.
    final appBarTitle = tester.getRect(find.text('远程控制'));
    final loginTitle = tester.getRect(find.text('登录 QFRemote'));
    expect(loginTitle.top, greaterThanOrEqualTo(appBarTitle.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('web view page never sits silent: loading, then timeout panel', (
    tester,
  ) async {
    usePhoneViewport(tester);
    // The cookie future never completes, so the page stays in its
    // not-ready state; the platform web view itself cannot mount in a
    // widget test (no InAppWebViewPlatform implementation), which is
    // exactly the state worth pinning: no silent blank, bounded area.
    final stuckCookies = Completer<Map<String, String>>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: QfrWebViewPage(
            title: '远程控制',
            url: 'https://console.example.invalid/',
            cookies: stuckCookies.future,
            base: 'https://console.example.invalid',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在加载…'), findsOneWidget);
    final appBarTitle = tester.getRect(find.text('远程控制').first);
    final loading = tester.getRect(find.text('正在加载…'));
    expect(loading.top, greaterThanOrEqualTo(appBarTitle.bottom));

    // Past the watchdog deadline the timeout panel replaces the
    // spinner, with a retry that returns to the loading state.
    await tester.pump(const Duration(seconds: 26));
    expect(find.text('正在加载…'), findsNothing);
    expect(find.text('加载超时，网络可能不稳定，请检查网络后重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.text('正在加载…'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Unmount so the re-armed watchdog timer is disposed with the page.
    await tester.pumpWidget(const SizedBox());
  });
}
