const _testUrl = 'http://www.gstatic.com/generate_204';
const _interval = 300;
const _tolerance = 50;

const _fakeKeywords = ['剩余流量', '到期', '官网'];

final _ratioPattern = RegExp(
  r'(?:^|[^0-9])([2-9]|\d{2,})(?:\.\d+)?\s*[x×倍]|(?:[x×]\s*([2-9]|\d{2,})(?:\.\d+)?)',
  caseSensitive: false,
);

bool _isFakeOrPricey(Object? name) {
  return name is String &&
      (_fakeKeywords.any(name.contains) || _ratioPattern.hasMatch(name));
}

/// Built-in equivalent of the override-select-to-urltest script: turns
/// manual `select` groups into `url-test` groups that pick the fastest
/// node. Groups listing DIRECT or REJECT stay manual, names that are
/// verifiably fake or high-ratio proxies leave the candidate pool, and
/// converted groups test lazily. Everything else is left untouched.
Map<String, dynamic> applyAutoSelectFastest(Map<String, dynamic> config) {
  final groups = config['proxy-groups'];
  if (groups is! List) {
    return config;
  }
  final groupNames = <String>{
    for (final group in groups)
      if (group is Map && group['name'] is String) group['name'] as String,
  };
  final proxies = config['proxies'];
  final proxyNames = <String>{
    if (proxies is List)
      for (final proxy in proxies)
        if (proxy is Map && proxy['name'] is String) proxy['name'] as String,
  };
  for (final group in groups) {
    if (group is! Map || group['type'] != 'select') {
      continue;
    }
    final members = group['proxies'];
    final hasProxies = members is List && members.isNotEmpty;
    final use = group['use'];
    final hasUse = use is List && use.isNotEmpty;
    if (!hasProxies && !hasUse) {
      continue;
    }
    if (hasProxies &&
        members.any((member) => member == 'DIRECT' || member == 'REJECT')) {
      continue;
    }
    if (hasProxies) {
      final kept = [
        for (final member in members)
          if (groupNames.contains(member) ||
              !proxyNames.contains(member) ||
              !_isFakeOrPricey(member))
            member,
      ];
      if (kept.isEmpty && !hasUse) {
        continue;
      }
      group['proxies'] = kept;
    }
    group['type'] = 'url-test';
    final url = group['url'];
    if (url == null || url == '') {
      group['url'] = _testUrl;
    }
    final interval = group['interval'];
    if (interval == null || interval == 0 || interval == '') {
      group['interval'] = _interval;
    }
    if (group['tolerance'] == null) {
      group['tolerance'] = _tolerance;
    }
    group['lazy'] = true;
  }
  return config;
}
