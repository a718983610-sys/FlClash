import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/views/profiles/qf_detail_pages.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _EmptyProfiles extends Profiles {
  @override
  List<Profile> build() => const [];
}

void main() {
  group('qfProxyDetailFields', () {
    final ss = <String, dynamic>{
      'name': '台北 SS',
      'type': 'ss',
      'server': '192.0.2.11',
      'port': 8388,
      'cipher': '2022-blake3-aes-128-gcm',
      'password': 'pw-one',
      'udp': true,
    };

    test('orders known fields and masks the password by default', () {
      final rows = qfProxyDetailFields(ss, revealSecrets: false);
      expect(rows.map((row) => row.label).toList(), [
        '名称',
        '类型',
        '服务器',
        '端口',
        '加密算法',
        '密码',
        'UDP',
      ]);
      expect(rows[5].value, '••••••');
      expect(rows[5].secret, isTrue);
      expect(rows[6].value, '开启');
    });

    test('reveals the password on request', () {
      final rows = qfProxyDetailFields(ss, revealSecrets: true);
      expect(rows.firstWhere((row) => row.secret).value, 'pw-one');
    });

    test('renders hysteria2 protocol fields in plain language', () {
      final rows = qfProxyDetailFields(
        <String, dynamic>{
          'name': '台北 Hy2',
          'type': 'hysteria2',
          'server': '192.0.2.12',
          'port': 443,
          'password': 'pw-two',
          'sni': 'example.com',
          'skip-cert-verify': true,
          'ports': '20000-40000',
          'obfs': 'salamander',
          'obfs-password': 'obfs-pw',
        },
        revealSecrets: false,
      );
      final byLabel = {for (final row in rows) row.label: row.value};
      expect(byLabel['SNI'], 'example.com');
      expect(byLabel['跳过证书验证'], '是');
      expect(byLabel['端口跳跃'], '20000-40000');
      expect(byLabel['混淆'], 'salamander');
      expect(byLabel['obfs-password'], 'obfs-pw');
    });

    test('serializes nested option maps as compact JSON', () {
      final rows = qfProxyDetailFields(
        <String, dynamic>{
          'name': 'ws 节点',
          'type': 'vmess',
          'server': '192.0.2.13',
          'port': 443,
          'uuid': '00000000-0000-0000-0000-000000000001',
          'network': 'ws',
          'ws-opts': {'path': '/ws', 'headers': {'Host': 'example.com'}},
        },
        revealSecrets: false,
      );
      final ws = rows.firstWhere((row) => row.label == 'ws-opts');
      expect(ws.value, contains('"/ws"'));
      expect(ws.value, contains('"Host":"example.com"'));
    });
  });

  group('qfLoadProxyDefinition', () {
    test('finds a custom proxy definition by name', () async {
      final profile = Profile.custom(label: '自定义');
      final found = await qfLoadProxyDefinition(
        profile: profile,
        proxyName: '节点甲',
        loadCustomProxies: () async => [
          CustomProxy.fromDefinition({'name': '节点甲', 'type': 'ss'}),
          CustomProxy.fromDefinition({'name': '节点乙', 'type': 'ss'}),
        ],
      );
      expect(found?['name'], '节点甲');
      final missing = await qfLoadProxyDefinition(
        profile: profile,
        proxyName: '节点丙',
        loadCustomProxies: () async => [
          CustomProxy.fromDefinition({'name': '节点甲', 'type': 'ss'}),
        ],
      );
      expect(missing, isNull);
    });
  });

  testWidgets('proxy detail page explains when parameters are unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [profilesProvider.overrideWith(() => _EmptyProfiles())],
        child: const MaterialApp(
          home: QfProxyDetailPage(
            profileId: 999999,
            proxyName: '不存在的节点',
            isCustom: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('暂时无法查看详细参数'), findsOneWidget);
  });

  testWidgets('info button uses the standard info glyph and fires', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QfInfoButton(onPressed: () => taps++)),
      ),
    );
    expect(find.byType(IconButton), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    expect(taps, 1);
  });
}
