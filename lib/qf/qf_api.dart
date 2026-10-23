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

class QfHttp {
  static Future<Map<String, dynamic>> send(
    String method,
    String url, {
    Map<String, dynamic>? body,
    String? bearer,
    Map<String, String>? headers,
  }) async {
    final client = await QfHttpClient.create(uri: Uri.parse(url));
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
      final text = await response.transform(utf8.decoder).join();
      Map<String, dynamic> data = {};
      if (text.isNotEmpty) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map) data = Map<String, dynamic>.from(decoded);
        } catch (_) {
          data = {};
        }
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

  static Future<QfReleaseManifest?> fetchRemote() async {
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
