import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/qf/qf_forum.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

// Dual-platform adaptation matrix (2.0.0): key pages pumped at the
// representative size/DPI/font-scale tiers of both platforms. A tier
// passes when the page builds with no layout exception (overflow,
// unbounded constraints) — the failure mode that actually breaks small
// screens, gesture bars, foldables and high-DPI windows. Real-device
// checks (API levels, Win10/11, physical gesture insets) stay in the
// EVIDENCE real-device list; this suite covers the layout layer.
class _Tier {
  const _Tier(this.label, this.logical, this.dpr, this.platform);
  final String label;
  final Size logical;
  final double dpr;
  final SupportPlatform platform;
}

const _tiers = <_Tier>[
  _Tier('安卓小屏 320x640@2x', Size(320, 640), 2, SupportPlatform.Android),
  _Tier('安卓主流 360x800@3x', Size(360, 800), 3, SupportPlatform.Android),
  _Tier('安卓大屏 412x915@2.625x', Size(412, 915), 2.625, SupportPlatform.Android),
  _Tier('安卓平板竖 800x1280@2x', Size(800, 1280), 2, SupportPlatform.Android),
  _Tier('安卓横屏/折叠展开 1280x800@2x', Size(1280, 800), 2, SupportPlatform.Android),
  _Tier('安卓手机横屏 800x360@2x', Size(800, 360), 2, SupportPlatform.Android),
  _Tier('Win 1080p 100%', Size(1920, 1080), 1, SupportPlatform.Windows),
  _Tier('Win 1080p 125%', Size(1536, 864), 1.25, SupportPlatform.Windows),
  _Tier('Win 2K 150%', Size(1707, 960), 1.5, SupportPlatform.Windows),
  _Tier('Win 4K 200%', Size(1920, 1080), 2, SupportPlatform.Windows),
  _Tier('Win 窄窗 560x800', Size(560, 800), 1, SupportPlatform.Windows),
  _Tier('Win 最小窗 400x500', Size(400, 500), 1, SupportPlatform.Windows),
];

void _setView(WidgetTester tester, _Tier tier, {double textScale = 1}) {
  tester.view.physicalSize = Size(
    tier.logical.width * tier.dpr,
    tier.logical.height * tier.dpr,
  );
  tester.view.devicePixelRatio = tier.dpr;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

class _AdaptSession extends QfSessionController {
  _AdaptSession() {
    mode = QfMode.user;
    userId = 7;
    username = 'tester123';
  }

  @override
  Future<Map<String, dynamic>> forumBoards() async => {
    'boards': [
      {'key': 'general', 'name': '综合讨论'},
      {'key': 'announcements', 'name': '公告'},
    ],
  };

  @override
  Future<Map<String, dynamic>> forumProfile() async => {
    'nickname': '测试昵称',
    'mutePermanent': false,
    'muteUntil': null,
  };

  @override
  Future<Map<String, dynamic>> forumPosts({
    String? board,
    int offset = 0,
    int limit = 20,
  }) async => {
    'posts': offset == 0
        ? [
            {
              'id': 1,
              'title': '适配测试帖子标题适配测试帖子标题',
              'content': '内容',
              'board': 'general',
              'author': {'userId': 7, 'name': '作者甲'},
              'replyCount': 1,
              'likeCount': 3,
              'shareCount': 2,
              'viewCount': 9,
              'likedByMe': false,
            },
          ]
        : const [],
  };

  @override
  Future<Map<String, dynamic>> forumCamps() async => {'camps': const []};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dashboard across tiers', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [profilesProvider.overrideWith(TestProfiles.new)],
      );
      globalState.container = container;
      container.listen(groupsProvider, (_, _) {});
      container.read(groupsProvider.notifier).value = [
        Group(
          type: GroupType.Selector,
          name: 'AWS组',
          hidden: false,
          all: [Proxy(name: 'N1', type: 'ss')],
        ),
      ];
    });

    tearDown(() => container.dispose());

    Future<void> pumpTier(WidgetTester tester, _Tier tier, {double textScale = 1}) async {
      _setView(tester, tier, textScale: textScale);
      container.read(viewSizeProvider.notifier).value = tier.logical;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(child: DashboardView(platform: tier.platform)),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '${tier.label} 字号x$textScale 不应有布局异常',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    }

    for (final tier in _tiers) {
      testWidgets('dashboard ${tier.label}', (tester) async {
        await pumpTier(tester, tier);
      });
    }

    testWidgets('dashboard 主流尺寸 + 系统字号最大档', (tester) async {
      await pumpTier(
        tester,
        const _Tier('x', Size(360, 800), 3, SupportPlatform.Android),
        textScale: 2,
      );
    });

    testWidgets('dashboard 小屏 + 系统字号最大档', (tester) async {
      await pumpTier(
        tester,
        const _Tier('x', Size(320, 640), 2, SupportPlatform.Android),
        textScale: 2,
      );
    });
  });

  group('login form across tiers', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    // Mirrors the production host (QfEntryPage): the form sits in a
    // scroll view capped at 420 wide, so vertical growth scrolls instead
    // of overflowing.
    Widget host(QfSessionController session) {
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: QfLoginForm(session: session),
            ),
          ),
        ),
      );
    }

    for (final tier in [
      const _Tier('安卓小屏', Size(320, 640), 2, SupportPlatform.Android),
      const _Tier('安卓主流', Size(360, 800), 3, SupportPlatform.Android),
      const _Tier('横屏', Size(1280, 800), 2, SupportPlatform.Android),
      const _Tier('Win 最小窗', Size(400, 500), 1, SupportPlatform.Windows),
    ]) {
      testWidgets('login ${tier.label}', (tester) async {
        _setView(tester, tier);
        await tester.pumpWidget(host(_AdaptSession()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tier.label);
        expect(find.text('记住账号密码'), findsOneWidget);
      });
    }

    testWidgets('login 主流尺寸 + 系统字号最大档', (tester) async {
      _setView(
        tester,
        const _Tier('x', Size(360, 800), 3, SupportPlatform.Android),
        textScale: 2,
      );
      await tester.pumpWidget(host(_AdaptSession()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('forum across tiers', () {
    for (final tier in [
      const _Tier('安卓小屏', Size(320, 640), 2, SupportPlatform.Android),
      const _Tier('安卓主流', Size(360, 800), 3, SupportPlatform.Android),
      const _Tier('平板竖', Size(800, 1280), 2, SupportPlatform.Android),
      const _Tier('Win 1080p', Size(1920, 1080), 1, SupportPlatform.Windows),
    ]) {
      testWidgets('forum ${tier.label}', (tester) async {
        _setView(tester, tier);
        await tester.pumpWidget(
          MaterialApp(home: QfForumPage(session: _AdaptSession())),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tier.label);
      });
    }

    testWidgets('forum 主流尺寸 + 系统字号最大档', (tester) async {
      _setView(
        tester,
        const _Tier('x', Size(360, 800), 3, SupportPlatform.Android),
        textScale: 2,
      );
      await tester.pumpWidget(
        MaterialApp(home: QfForumPage(session: _AdaptSession())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
