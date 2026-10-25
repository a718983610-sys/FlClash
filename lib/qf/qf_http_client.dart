import 'dart:async';
import 'dart:io';

enum QfProxySource { core, system, environment, direct }

class QfProxyDecision {
  final String proxy;
  final QfProxySource source;

  const QfProxyDecision(this.proxy, this.source);
}

String qfNormalizeProxyServer(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (value.contains('=')) {
    final parts = value.split(';');
    String? fallback;
    for (final part in parts) {
      final trimmed = part.trim();
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final scheme = trimmed.substring(0, eq).toLowerCase();
      final server = trimmed.substring(eq + 1);
      fallback ??= server;
      if (scheme == 'https') {
        fallback = server;
        break;
      }
    }
    value = (fallback ?? '').trim();
  }
  final schemeEnd = value.indexOf('://');
  if (schemeEnd > 0) value = value.substring(schemeEnd + 3);
  final slash = value.indexOf('/');
  if (slash > 0) value = value.substring(0, slash);
  return value.trim();
}

QfProxyDecision qfDecideProxy({
  required bool coreRunning,
  required int corePort,
  String? systemProxyServer,
  String? envProxy,
  String? host,
}) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return const QfProxyDecision('DIRECT', QfProxySource.direct);
  }
  if (coreRunning && corePort > 0) {
    return QfProxyDecision('PROXY 127.0.0.1:$corePort', QfProxySource.core);
  }
  final system = qfNormalizeProxyServer(systemProxyServer ?? '');
  if (system.isNotEmpty) {
    return QfProxyDecision('PROXY $system', QfProxySource.system);
  }
  final env = qfNormalizeProxyServer(envProxy ?? '');
  if (env.isNotEmpty) {
    return QfProxyDecision('PROXY $env', QfProxySource.environment);
  }
  return const QfProxyDecision('DIRECT', QfProxySource.direct);
}

class QfHttpClient {
  static bool Function()? coreRunningProbe;

  /// The mixed port is read fresh at every decision (C-03): the gate
  /// installs a resolver over the live patch config, so a port change
  /// in settings takes effect without an app restart. The plain setter
  /// remains as the fallback for contexts without a resolver.
  static int Function()? corePortResolver;
  static int _corePortFallback = 7890;

  static int get corePort {
    try {
      return corePortResolver?.call() ?? _corePortFallback;
    } catch (_) {
      return _corePortFallback;
    }
  }

  static set corePort(int value) => _corePortFallback = value;
  static QfProxyDecision lastDecision = const QfProxyDecision(
    'DIRECT',
    QfProxySource.direct,
  );
  static Future<String?> Function()? systemProxyReaderOverride;
  static Future<bool> Function(int port)? coreReachabilityOverride;

  static String? _systemProxyCache;
  static DateTime? _systemProxyCacheAt;

  static Future<HttpClient> create({
    Uri? uri,
    QfProxySource? forceSource,
  }) async {
    final client = HttpClient();
    final decision = await resolveDecision(
      host: uri?.host,
      forceSource: forceSource,
    );
    client.findProxy = (_) => decision.proxy;
    return client;
  }

  static Future<QfProxyDecision> resolveDecision({
    String? host,
    QfProxySource? forceSource,
  }) async {
    if (forceSource == QfProxySource.direct) {
      const decision = QfProxyDecision('DIRECT', QfProxySource.direct);
      lastDecision = decision;
      return decision;
    }
    if (forceSource == QfProxySource.core) {
      final decision = await _probeCore(corePort)
          ? QfProxyDecision('PROXY 127.0.0.1:$corePort', QfProxySource.core)
          : const QfProxyDecision('DIRECT', QfProxySource.direct);
      lastDecision = decision;
      return decision;
    }
    var core = false;
    try {
      core = coreRunningProbe?.call() ?? false;
    } catch (_) {
      core = false;
    }
    if (core && !await _probeCore(corePort)) core = false;
    String? system;
    if (Platform.isWindows) system = await _windowsSystemProxy();
    String? env;
    if (!Platform.isWindows) env = _envProxy();
    final decision = qfDecideProxy(
      coreRunning: core,
      corePort: corePort,
      systemProxyServer: system,
      envProxy: env,
      host: host,
    );
    lastDecision = decision;
    return decision;
  }

  static Future<bool> _probeCore(int port) async {
    final override = coreReachabilityOverride;
    if (override != null) return override(port);
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 250),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String? _envProxy() {
    final env = Platform.environment;
    return env['HTTPS_PROXY'] ??
        env['https_proxy'] ??
        env['HTTP_PROXY'] ??
        env['http_proxy'];
  }

  static Future<String?> _windowsSystemProxy() async {
    final override = systemProxyReaderOverride;
    if (override != null) return override();
    final cachedAt = _systemProxyCacheAt;
    if (cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 30)) {
      return _systemProxyCache;
    }
    String? result;
    try {
      result = await _readWindowsProxyFromRegistry();
    } catch (_) {
      result = null;
    }
    _systemProxyCache = result;
    _systemProxyCacheAt = DateTime.now();
    return result;
  }

  static Future<String?> _readWindowsProxyFromRegistry() async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final enable = await _regQuery(key, 'ProxyEnable');
    if (enable == null || !enable.contains('0x1')) return null;
    final server = await _regQuery(key, 'ProxyServer');
    if (server == null) return null;
    final match = RegExp(r'REG_SZ\s+(.+)$').firstMatch(server);
    final value = match?.group(1)?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  static Future<String?> _regQuery(String key, String valueName) async {
    final result = await Process.run('reg', [
      'query',
      key,
      '/v',
      valueName,
    ], runInShell: false).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) return null;
    return result.stdout.toString();
  }
}
