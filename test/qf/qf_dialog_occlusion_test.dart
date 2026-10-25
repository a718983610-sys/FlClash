import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_recovery.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DialogSession extends QfSessionController {
  _DialogSession() {
    mode = QfMode.entry;
  }
}

/// Small surface + maximum text scale: the worst case for dialog
/// content being clipped, truncated or overflowing (owner audit,
/// 2026-10-25). Every dialog must keep its text reachable (scrolling
/// is fine) and must not throw a layout overflow.
Widget _host(void Function(BuildContext) opener) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => opener(context),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  void useSmallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('ban dialog keeps long notice and reason reachable', (
    tester,
  ) async {
    useSmallSurface(tester);
    final session = _DialogSession();
    await tester.pumpWidget(
      _host(
        (context) => qfShowBanDialog(
          context,
          session: session,
          account: 'tester123',
          data: const {
            'permanent': false,
            'message': '该账户已被封禁，解除时间：2027年1月1日。'
                '这是一段很长的封禁说明，用来验证弹窗在小屏幕和大字体下'
                '文字不会被遮挡、不会截断，可以滚动看完。',
            'reason': '多次发布违规内容，经人工审核确认。'
                '这也是一段很长的原因说明，同样需要完整可达。',
          },
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('账户已被封禁'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('qf-ban-support')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('frozen dialog keeps its long guidance reachable', (
    tester,
  ) async {
    useSmallSurface(tester);
    await tester.pumpWidget(
      _host(
        (context) => qfShowFrozenDialog(
          context,
          message: '登录失败次数过多，账户已被冻结。'
              '这是一段很长的冻结说明，用来验证弹窗在小屏幕和大字体下'
              '文字不会被遮挡、不会截断，可以滚动看完。',
          frozenAt: 1760000000,
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('账户已被冻结'), findsOneWidget);
    expect(find.byKey(const ValueKey('qf-frozen-support')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('minor update dialog and download panel fit small screens', (
    tester,
  ) async {
    useSmallSurface(tester);
    const check = QfUpdateCheck(
      decision: QfUpdateDecision.minor,
      manifest: null,
      latestVersion: '2.0.0',
      downloadUrl: 'https://example.com/QFClash.apk',
      notes: '本次更新内容很长：修复了规则模式下分组不显示的问题，'
          '新增订阅与节点详情页，优化启动速度与多处界面细节，'
          '并包含其他问题修复。这段文字用来验证更新弹窗可以滚动看完。',
    );
    await tester.pumpWidget(
      _host((context) async {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (_) => const QfMinorUpdateDialog(result: check),
        );
        if (accepted == true && context.mounted) {
          await showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              content: SingleChildScrollView(
                child: QfUpdateDownloadPanel(
                  result: check,
                  onClose: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ),
          );
        }
      }),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v2.0.0'), findsOneWidget);
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();
    expect(find.text('立即更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long toast stays fully on screen', (tester) async {
    useSmallSurface(tester);
    await tester.pumpWidget(
      _host(
        (context) => qfToast(
          context,
          '这是一条很长的提示信息，用来验证提示条在小屏幕上文字完整可见、'
          '不被底部导航栏遮挡，也不会被截断成省略号。',
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这是一条很长的提示信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}
