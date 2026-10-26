import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_config.dart';
import 'qf_http_client.dart';
import 'qf_version.dart';

class QfApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> data;

  const QfApiException(
    this.status,
    this.code,
    this.message, [
    this.data = const {},
  ]);

  bool get isNetworkFailure => status == 0 && code == 'NETWORK';

  @override
  String toString() => message;
}

String qfAccountErrorMessage(Object error) {
  if (error is QfApiException) {
    if (!error.isNetworkFailure) return error.message;
    return QfHttpClient.lastDecision.source == QfProxySource.direct
        ? QfCopy.networkAccountNeedsProxy
        : QfCopy.networkAccountUnreachable;
  }
  return error.toString();
}

String qfGuestErrorMessage(Object error) {
  if (error is QfApiException) {
    return error.isNetworkFailure
        ? QfCopy.networkGuestUnreachable
        : error.message;
  }
  return error.toString();
}

/// The account-server entrypoints, in try order: the base that last
/// succeeded (persisted across launches), the manifest's serverBaseUrl,
/// the manifest's serverBaseUrlFallback, the built-in direct-IP host,
/// and the built-in workers.dev host. Domestic networks often cannot
/// reach workers.dev directly, so no single one of these may be the
/// only door.
class QfEndpoints {
  static const String _lastGoodKey = 'qf_endpoints_last_good';

  static String primary = QfConfig.fallbackServerBaseUrl;
  static String fallback = '';
  static String lastGood = '';
  static String builtinDirect = QfConfig.directServerBaseUrl;
  static String builtinFallback = QfConfig.fallbackServerBaseUrl;
  static bool _loaded = false;

  static String _clean(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  static void apply({String? primaryUrl, String? backupUrl}) {
    final nextPrimary = _clean(primaryUrl ?? '');
    if (nextPrimary.isNotEmpty) primary = nextPrimary;
    if (backupUrl != null) fallback = _clean(backupUrl);
  }

  static void applyManifest(QfReleaseManifest manifest) {
    apply(
      primaryUrl: manifest.serverBaseUrl,
      backupUrl: manifest.serverBaseUrlFallback,
    );
  }

  static List<String> orderedBases() {
    final seen = <String>{};
    final ordered = <String>[];
    for (final base in [
      lastGood,
      primary,
      fallback,
      builtinDirect,
      builtinFallback,
    ]) {
      final cleaned = _clean(base);
      if (cleaned.isNotEmpty && seen.add(cleaned)) ordered.add(cleaned);
    }
    return ordered;
  }

  /// Try-order for [url]: when it sits on a known account base, the same
  /// path on every base in order; otherwise the URL unchanged.
  static List<String> rotationFor(String url) {
    final bases = orderedBases();
    for (final base in bases) {
      if (url.startsWith(base)) {
        final path = url.substring(base.length);
        return [for (final candidate in bases) '$candidate$path'];
      }
    }
    return [url];
  }

  static void noteSuccess(String url) {
    for (final base in orderedBases()) {
      if (!url.startsWith(base)) continue;
      if (base != lastGood) {
        lastGood = base;
        unawaited(_persistLastGood(base));
      }
      return;
    }
  }

  // A remembered base that now fails at the network layer must not
  // stay pinned at the head of the queue across launches.
  static void noteNetworkFailure(String url) {
    if (lastGood.isEmpty) return;
    for (final base in orderedBases()) {
      if (!url.startsWith(base)) continue;
      if (base == lastGood) {
        lastGood = '';
        unawaited(_clearLastGood());
      }
      return;
    }
  }

  static Future<void> loadPersisted() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = _clean(prefs.getString(_lastGoodKey) ?? '');
      if (stored.isNotEmpty) lastGood = stored;
    } catch (_) {}
  }

  static Future<void> _persistLastGood(String base) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastGoodKey, base);
    } catch (_) {}
  }

  static Future<void> _clearLastGood() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastGoodKey);
    } catch (_) {}
  }

  static void resetForTest() {
    primary = QfConfig.fallbackServerBaseUrl;
    fallback = '';
    lastGood = '';
    builtinDirect = QfConfig.directServerBaseUrl;
    builtinFallback = QfConfig.fallbackServerBaseUrl;
    _loaded = false;
  }
}

class QfHttp {
  /// Whether a network failure may be retried automatically. A retry
  /// replays the request, so when a response is lost after the server
  /// already processed a write, an unconditional retry submits it twice
  /// (duplicate posts, camp creations, and burned appeal attempts).
  /// Only idempotent methods and the POSTs whose client idempotency key
  /// the server deduplicates on (chat msgId, redeem idempotencyKey)
  /// qualify; every other write is attempted exactly once and its first
  /// failure surfaces for a manual retry instead.
  static bool isRetryable(String method, Map<String, dynamic>? body) {
    switch (method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'PUT':
      case 'DELETE':
        return true;
      case 'POST':
        if (body == null) return false;
        return (body['msgId'] ?? '').toString().isNotEmpty ||
            (body['idempotencyKey'] ?? '').toString().isNotEmpty;
      default:
        return false;
    }
  }

  // Entry POSTs (/auth/, /guest/) rotate across bases like reads do:
  // when the first base fails at the network layer the request never
  // reached a server, so replaying it on the next base cannot submit
  // the same write twice. Ordinary writes keep the one-attempt rule
  // that isRetryable guards.
  static bool rotatesAcrossBases(
    String method,
    String url,
    Map<String, dynamic>? body,
  ) {
    if (isRetryable(method, body)) return true;
    if (method.toUpperCase() != 'POST') return false;
    final path = Uri.tryParse(url)?.path ?? '';
    return path.startsWith('/auth/') || path.startsWith('/guest/');
  }

  static Future<Map<String, dynamic>> send(
    String method,
    String url, {
    Map<String, dynamic>? body,
    String? bearer,
    Map<String, String>? headers,
  }) async {
    QfApiException? lastNetworkError;
    // Overall cap for the whole rotation: each attempt is bounded on its
    // own (connect, headers, body stall), and the rotation as a whole
    // must not stretch account requests without limit either (C-01).
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    final rotates = rotatesAcrossBases(method, url, body);
    final bases = QfEndpoints.rotationFor(url);
    final candidates = rotates ? bases : bases.take(1);
    for (final candidate in candidates) {
      if (DateTime.now().isAfter(deadline)) break;
      QfProxySource? force;
      while (true) {
        try {
          final data = await _sendOnce(
            method,
            candidate,
            body: body,
            bearer: bearer,
            headers: headers,
            forceSource: force,
          );
          QfEndpoints.noteSuccess(candidate);
          return data;
        } on QfApiException catch (e) {
          if (!e.isNetworkFailure) rethrow;
          lastNetworkError = e;
          QfEndpoints.noteNetworkFailure(candidate);
          if (!rotates || force != null) break;
          // One cross-path retry per endpoint: a request that died on the
          // proxied path gets a direct attempt and vice versa, so a core
          // that is up but has no working outbound cannot blackhole
          // account traffic.
          force = QfHttpClient.lastDecision.source == QfProxySource.direct
              ? QfProxySource.core
              : QfProxySource.direct;
        }
      }
    }
    throw lastNetworkError ??
        const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
  }

  static Future<Map<String, dynamic>> _sendOnce(
    String method,
    String url, {
    Map<String, dynamic>? body,
    String? bearer,
    Map<String, String>? headers,
    QfProxySource? forceSource,
  }) async {
    final client = await QfHttpClient.create(
      uri: Uri.parse(url),
      forceSource: forceSource,
    );
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      request.headers.contentType = ContentType.json;
      if (headers != null) {
        headers.forEach((key, value) {
          request.headers.set(key, value);
        });
      }
      if (bearer != null && bearer.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $bearer');
      }
      if (body != null) {
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      // The body read needs its own stall timeout: headers can arrive
      // promptly while the body trickles or never finishes, and an
      // unbounded read hangs every account request forever (C-01).
      final text = await response
          .timeout(const Duration(seconds: 20))
          .transform(utf8.decoder)
          .join();
      Map<String, dynamic> data = {};
      var malformed = text.isEmpty;
      if (!malformed) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map) {
            data = Map<String, dynamic>.from(decoded);
          } else {
            malformed = true;
          }
        } catch (_) {
          malformed = true;
        }
      }
      if (malformed &&
          response.statusCode >= 200 &&
          response.statusCode < 300) {
        // A 2xx we cannot parse (captive portal, interception page, empty
        // body) is not a success: treating it as one fed empty maps into
        // callers that read missing fields as defaults - empty tokens,
        // zero balances (C-02).
        throw const QfApiException(
          0,
          'BAD_RESPONSE',
          '服务器返回了无法识别的内容，请稍后重试。',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw QfApiException(
          response.statusCode,
          (data['code'] ?? '').toString(),
          (data['message'] ?? '请求失败，请稍后重试').toString(),
          data,
        );
      }
      if (data['ok'] == false) {
        throw QfApiException(
          response.statusCode,
          (data['code'] ?? '').toString(),
          (data['message'] ?? '请求失败，请稍后重试').toString(),
          data,
        );
      }
      return data;
    } on QfApiException {
      rethrow;
    } catch (e) {
      throw QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
    } finally {
      client.close(force: true);
    }
  }
}

class QfProofHeaders {
  static Map<String, String>? _cached;

  static Future<Map<String, String>> collect() async {
    if (_cached != null) return _cached!;
    final headers = <String, String>{};
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      if (timezone.identifier.isNotEmpty) {
        headers['X-Device-Timezone'] = timezone.identifier;
      }
    } catch (_) {}
    try {
      final simCountry = await app?.getSimCountry();
      if (simCountry != null && simCountry.isNotEmpty) {
        headers['X-Sim-Country'] = simCountry.toLowerCase();
      }
    } catch (_) {}
    if (headers.isEmpty) return headers;
    return _cached = headers;
  }
}

class QfManifestService {
  static const String _cacheKey = 'qf_release_manifest_cache';

  static Future<QfReleaseManifest?> Function()? fetcherForTest;

  static Future<QfReleaseManifest?> fetchRemote() async {
    final fetcher = fetcherForTest;
    if (fetcher != null) return fetcher();
    try {
      final data = await QfHttp.send('GET', QfConfig.manifestUrl);
      final manifest = QfReleaseManifest.fromJson(data);
      if (QfVersion.tryParse(manifest.latestVersion) == null) {
        log(
          'release manifest parse failed; keeping last good cached manifest',
          name: 'QFClash',
        );
        return null;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(manifest.toJson()));
      QfEndpoints.applyManifest(manifest);
      return manifest;
    } catch (e) {
      log('release manifest fetch failed: $e', name: 'QFClash');
      return null;
    }
  }

  static Future<QfReleaseManifest?> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return QfReleaseManifest.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }
}

class QfDeviceIdentity {
  final String deviceHash;
  final String deviceName;
  final String platform;

  const QfDeviceIdentity({
    required this.deviceHash,
    required this.deviceName,
    required this.platform,
  });

  static QfDeviceIdentity? _cached;

  static Future<QfDeviceIdentity> resolve() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('qf_device_hash');
    final storedName = prefs.getString('qf_device_name');
    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isWindows
        ? 'windows'
        : 'other';
    if (stored != null && stored.isNotEmpty) {
      _cached = QfDeviceIdentity(
        deviceHash: stored,
        deviceName: storedName ?? 'QFClash 设备',
        platform: platform,
      );
      return _cached!;
    }
    final info = DeviceInfoPlugin();
    String seed;
    String name;
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      seed = '${android.id}|${android.brand}|${android.model}';
      name = '${android.brand} ${android.model}'.trim();
    } else if (Platform.isWindows) {
      final windows = await info.windowsInfo;
      seed = '${windows.deviceId}|${windows.computerName}';
      name = windows.computerName;
    } else {
      final base = await info.deviceInfo;
      seed = base.data.toString();
      name = 'QFClash 设备';
    }
    final hash = sha256.convert(utf8.encode('qfclash-device:$seed')).toString();
    await prefs.setString('qf_device_hash', hash);
    await prefs.setString('qf_device_name', name);
    _cached = QfDeviceIdentity(
      deviceHash: hash,
      deviceName: name,
      platform: platform,
    );
    return _cached!;
  }
}

bool qfLooksLikeEmulator(List<String> hints) {
  final joined = hints.join(' ').toLowerCase();
  const markers = ['generic', 'emulator', 'sdk_gphone', 'vbox', 'virtual'];
  return markers.any(joined.contains);
}
