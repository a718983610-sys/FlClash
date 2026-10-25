import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Rule-mode regression: the exact proxy views the core returns for the
// merged subscription (captured from the Go full-path repro: base merge
// + ApplyConfig + getProxies) must survive buildGroups and the rule-mode
// visibility filter, or the dashboard tree shows "no groups" while the
// global mode looks fine.
void main() {
  const taipeiSs = '🇹🇼台北（SS协议首选）';
  const taipeiHy2 = '🇹🇼台北（Hy2协议备用）';
  const tokyoSs = '🇯🇵东京（SS协议首选）';
  const tokyoHy2 = '🇯🇵东京（Hy2协议 备选）';

  Map<String, dynamic> node(String name, String type) => {
    'name': name,
    'type': type,
  };

  // The core's answer for the current merged subscription shape.
  ProxiesData coreAnswer() {
    return ProxiesData.fromJson({
      'all': ['GLOBAL', 'AWS组'],
      'proxies': {
        'GLOBAL': {
          'name': 'GLOBAL',
          'type': 'Selector',
          'now': 'DIRECT',
          'all': [
            'DIRECT',
            'REJECT',
            tokyoSs,
            tokyoHy2,
            taipeiSs,
            taipeiHy2,
            'AWS组',
          ],
          'hidden': true,
          'icon': '',
          'testUrl': '',
          'emptyFallback': 'COMPATIBLE',
        },
        'AWS组': {
          'name': 'AWS组',
          'type': 'Selector',
          'now': 'DIRECT',
          'all': ['DIRECT', 'REJECT', tokyoSs, tokyoHy2, taipeiSs, taipeiHy2],
          'hidden': false,
          'icon': '',
          'testUrl': '',
          'emptyFallback': 'COMPATIBLE',
        },
        taipeiSs: node(taipeiSs, 'Shadowsocks'),
        taipeiHy2: node(taipeiHy2, 'Hysteria2'),
        tokyoSs: node(tokyoSs, 'Shadowsocks'),
        tokyoHy2: node(tokyoHy2, 'Hysteria2'),
        'DIRECT': node('DIRECT', 'Direct'),
        'REJECT': node('REJECT', 'Reject'),
      },
    });
  }

  // The core's answer for a bare profile once the host wraps it.
  ProxiesData bareAnswer() {
    return ProxiesData.fromJson({
      'all': ['GLOBAL', '节点选择'],
      'proxies': {
        'GLOBAL': {
          'name': 'GLOBAL',
          'type': 'Selector',
          'now': 'DIRECT',
          'all': [
            'DIRECT',
            'REJECT',
            tokyoSs,
            tokyoHy2,
            taipeiSs,
            taipeiHy2,
            '节点选择',
          ],
          'hidden': true,
          'icon': '',
          'testUrl': '',
          'emptyFallback': 'COMPATIBLE',
        },
        '节点选择': {
          'name': '节点选择',
          'type': 'Selector',
          'now': tokyoSs,
          'all': [tokyoSs, tokyoHy2, taipeiSs, taipeiHy2, 'DIRECT'],
          'hidden': false,
          'icon': '',
          'testUrl': '',
          'emptyFallback': 'COMPATIBLE',
        },
        taipeiSs: node(taipeiSs, 'Shadowsocks'),
        taipeiHy2: node(taipeiHy2, 'Hysteria2'),
        tokyoSs: node(tokyoSs, 'Shadowsocks'),
        tokyoHy2: node(tokyoHy2, 'Hysteria2'),
        'DIRECT': node('DIRECT', 'Direct'),
        'REJECT': node('REJECT', 'Reject'),
      },
    });
  }

  Future<List<Group>> build(ProxiesData data) => buildGroups(
    ComputeGroupsState(
      proxiesData: data,
      sortType: ProxiesSortType.none,
      delayMap: const {},
      selectedMap: const {},
      defaultTestUrl: 'https://www.gstatic.com/generate_204',
    ),
  );

  test(
    'buildGroups keeps the subscription group, filter keeps it in rule mode',
    () async {
      final groups = await build(coreAnswer());
      final names = groups.map((g) => g.name).toList();
      expect(names, containsAll(['GLOBAL', 'AWS组']));
      final aws = groups.firstWhere((g) => g.name == 'AWS组');
      expect(aws.hidden, isFalse);
      expect(aws.all.map((p) => p.name), [
        'DIRECT',
        'REJECT',
        tokyoSs,
        tokyoHy2,
        taipeiSs,
        taipeiHy2,
      ]);

      // The rule-mode visibility rule: visible unless explicitly hidden.
      final ruleVisible = groups.where((item) => item.hidden != true).toList();
      expect(ruleVisible.map((g) => g.name), ['AWS组']);
    },
  );

  test('the synthesized group of a bare profile shows in rule mode with '
      'every member', () async {
    final groups = await build(bareAnswer());
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(groupsProvider.notifier).value = groups;
    List<String> shownNames(Mode mode) {
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(mode: mode));
      return container
          .read(currentGroupsStateProvider)
          .value
          .map((g) => g.name)
          .toList();
    }

    expect(shownNames(Mode.rule), ['节点选择']);
    final shown = container.read(currentGroupsStateProvider).value.single;
    expect(shown.all.map((p) => p.name), [
      tokyoSs,
      tokyoHy2,
      taipeiSs,
      taipeiHy2,
      'DIRECT',
    ]);
    expect(shownNames(Mode.global), ['GLOBAL', '节点选择']);
    expect(shownNames(Mode.rule), ['节点选择']);
  });

  test(
    'a group whose hidden flag is absent must not vanish in rule mode',
    () async {
      // Some payloads omit the hidden key entirely; null must behave like
      // false (visible), never like true, or the rule-mode list empties
      // while global mode looks fine.
      final data = ProxiesData.fromJson({
        'all': ['G1'],
        'proxies': {
          'G1': {
            'name': 'G1',
            'type': 'Selector',
            'now': 'N1',
            'all': ['N1'],
            'testUrl': '',
          },
          'N1': node('N1', 'Shadowsocks'),
        },
      });
      final groups = await build(data);
      expect(groups.single.hidden, isNull);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(groupsProvider.notifier).value = groups;
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(mode: Mode.rule));
      final shown = container.read(currentGroupsStateProvider).value;
      expect(shown.map((g) => g.name), ['G1']);
      container
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(mode: Mode.global));
      expect(
        container.read(currentGroupsStateProvider).value.map((g) => g.name),
        ['G1'],
      );
    },
  );
}
