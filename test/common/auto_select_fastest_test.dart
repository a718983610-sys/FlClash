import 'dart:convert';

import 'package:fl_clash/common/auto_select_fastest.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _roundTrip(Map<String, dynamic> config) {
  return json.decode(json.encode(config)) as Map<String, dynamic>;
}

Map<String, Map<String, dynamic>> _groupsByName(Map<String, dynamic> config) {
  return {
    for (final group in config['proxy-groups'] as List)
      (group as Map<String, dynamic>)['name'] as String: group,
  };
}

void main() {
  group('applyAutoSelectFastest', () {
    final sample = <String, dynamic>{
      'proxies': [
        {'name': 'HK-1', 'type': 'ss'},
        {'name': 'JP-1', 'type': 'ss'},
      ],
      'proxy-groups': [
        {
          'name': '节点选择',
          'type': 'select',
          'proxies': ['HK-1', 'JP-1', '自动选择'],
        },
        {
          'name': '自动选择',
          'type': 'url-test',
          'proxies': ['HK-1', 'JP-1'],
          'url': 'http://x/204',
          'interval': 120,
        },
        {
          'name': '故障转移',
          'type': 'fallback',
          'proxies': ['HK-1', 'JP-1'],
        },
        {'name': '空组', 'type': 'select', 'proxies': <String>[]},
        {
          'name': '订阅组',
          'type': 'select',
          'use': ['providerA'],
        },
        {
          'name': '带参手动组',
          'type': 'select',
          'proxies': ['HK-1'],
          'url': 'http://keep/204',
          'interval': 999,
        },
      ],
      'rules': ['DOMAIN-SUFFIX,google.com,节点选择', 'MATCH,节点选择'],
    };

    test('converts select groups and fills in test parameters', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['节点选择']!['type'], 'url-test');
      expect(groups['节点选择']!['url'], 'http://www.gstatic.com/generate_204');
      expect(groups['节点选择']!['interval'], 300);
      expect(groups['节点选择']!['tolerance'], 50);
      expect(groups['节点选择']!['proxies'], ['HK-1', 'JP-1', '自动选择']);
    });

    test('leaves non-select groups, empty groups, rules and proxies alone', () {
      final before = _roundTrip(sample);
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      final beforeGroups = _groupsByName(before);
      expect(groups['自动选择'], beforeGroups['自动选择']);
      expect(groups['故障转移'], beforeGroups['故障转移']);
      expect(groups['空组']!['type'], 'select');
      expect(out['rules'], before['rules']);
      expect(out['proxies'], before['proxies']);
    });

    test('converts a select group that only uses providers', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['订阅组']!['type'], 'url-test');
      expect(groups['订阅组']!['use'], ['providerA']);
    });

    test('keeps an existing url and interval on converted groups', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['带参手动组']!['type'], 'url-test');
      expect(groups['带参手动组']!['url'], 'http://keep/204');
      expect(groups['带参手动组']!['interval'], 999);
    });

    test('tolerates a config without proxy-groups', () {
      final out = applyAutoSelectFastest(<String, dynamic>{'proxies': []});
      expect(out.containsKey('proxy-groups'), isFalse);
    });
  });

  group('applyAutoSelectFastest safety gates', () {
    final sample = <String, dynamic>{
      'proxies': [
        {'name': 'HK-1', 'type': 'ss'},
        {'name': 'JP-1', 'type': 'ss'},
        {'name': '剩余流量：100GB', 'type': 'ss'},
        {'name': '到期时间：2026-01-01', 'type': 'ss'},
        {'name': '官网：example.com', 'type': 'ss'},
        {'name': 'HK-2x专线', 'type': 'ss'},
        {'name': 'US-3倍节点', 'type': 'ss'},
      ],
      'proxy-groups': [
        {
          'name': '含直连组',
          'type': 'select',
          'proxies': ['HK-1', 'DIRECT'],
        },
        {
          'name': '含拦截组',
          'type': 'select',
          'proxies': ['JP-1', 'REJECT'],
        },
        {
          'name': '混合组',
          'type': 'select',
          'proxies': ['HK-1', '剩余流量：100GB', 'JP-1', '自动选择'],
          'lazy': false,
        },
        {
          'name': '自动选择',
          'type': 'url-test',
          'proxies': ['HK-1'],
          'url': 'http://x/204',
        },
        {
          'name': '全假组',
          'type': 'select',
          'proxies': ['官网：example.com', '到期时间：2026-01-01'],
        },
        {
          'name': '高倍率组',
          'type': 'select',
          'proxies': ['HK-2x专线', 'US-3倍节点', 'HK-1'],
        },
        {
          'name': '外来成员组',
          'type': 'select',
          'proxies': ['剩余流量：provider来的', 'HK-1'],
        },
      ],
      'rules': ['MATCH,混合组'],
    };

    test('does not convert groups listing DIRECT or REJECT', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['含直连组']!['type'], 'select');
      expect(groups['含直连组']!['proxies'], ['HK-1', 'DIRECT']);
      expect(groups['含拦截组']!['type'], 'select');
    });

    test('drops fake proxies but keeps nested group names', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['混合组']!['proxies'], ['HK-1', 'JP-1', '自动选择']);
      expect(groups['混合组']!['proxies'], contains('自动选择'));
    });

    test('marks converted groups lazy', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['混合组']!['type'], 'url-test');
      expect(groups['混合组']!['lazy'], isTrue);
    });

    test('does not convert a group left empty by filtering', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['全假组']!['type'], 'select');
    });

    test('drops high-ratio proxies', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['高倍率组']!['proxies'], ['HK-1']);
    });

    test('keeps members that are not named proxies of the profile', () {
      final out = applyAutoSelectFastest(_roundTrip(sample));
      final groups = _groupsByName(out);
      expect(groups['外来成员组']!['proxies'], ['剩余流量：provider来的', 'HK-1']);
      expect(groups['外来成员组']!['type'], 'url-test');
    });

    test('converts a group whose proxies all filter out when it has use', () {
      final out = applyAutoSelectFastest(<String, dynamic>{
        'proxies': [
          {'name': '官网：example.com', 'type': 'ss'},
        ],
        'proxy-groups': [
          {
            'name': '订阅组',
            'type': 'select',
            'proxies': ['官网：example.com'],
            'use': ['providerA'],
          },
        ],
      });
      final groups = _groupsByName(out);
      expect(groups['订阅组']!['type'], 'url-test');
      expect(groups['订阅组']!['proxies'], isEmpty);
    });
  });
}
