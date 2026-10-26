import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'qf_config.dart';
import 'qf_http_client.dart';
import 'qf_version.dart';

// QFRemote embedded module (2.0.3): the tools page signs the user into
// their QFRemote account, asks the license service for the qfclash
// channel verdict, and either opens the web console in an embedded
// WebView (key active) or the purchase page (no key / expired). The
// QFClash channel never reports a device, so it never touches the
// "2 computers + 1 phone" binding quota on the QFRemote side.

enum QfrLoginOutcome { success, invalidCredentials, frozen, networkError }

class QfrAccess {
  final bool allow;
  final String code;
  final String planName;
  final String displayStatus;

  const QfrAccess({
    required this.allow,
    required this.code,
    required this.planName,
    required this.displayStatus,
  });

  static QfrAccess? fromJson(Object? value) {
    if (value is! Map) return null;
    return QfrAccess(
      allow: value['allow'] == true,
      code: (value['code'] ?? '').toString(),
      planName: (value['planName'] ?? '').toString(),
      displayStatus: (value['displayStatus'] ?? '').toString(),
    );
  }

  bool get isBanned => code == 'BAN_PERM' || code == 'BAN_UNTIL';
}

class QfrProfile {
  final String username;
  final String planName;
  final String maskedKey;
  final String displayStatus;
  final String statusNote;
  final bool webEnabled;

  const QfrProfile({
    required this.username,
    required this.planName,
    required this.maskedKey,
    required this.displayStatus,
    required this.statusNote,
    required this.webEnabled,
  });

  static QfrProfile? fromJson(Object? value) {
    if (value is! Map) return null;
    return QfrProfile(
      username: (value['username'] ?? '').toString(),
      planName: (value['planName'] ?? '').toString(),
      maskedKey: (value['maskedKey'] ?? '').toString(),
      displayStatus: (value['displayStatus'] ?? '').toString(),
      statusNote: (value['statusNote'] ?? '').toString(),
      webEnabled: value['webEnabled'] == true,
    );
  }
}

class QfrLoginResult {
  final QfrLoginOutcome outcome;
  final QfrProfile? profile;

  const QfrLoginResult(this.outcome, {this.profile});
}

class _QfrHttpResult {
  final int statusCode;
  final String body;
  final bool frozenSignal;

  const _QfrHttpResult(this.statusCode, this.body, this.frozenSignal);
}

class QfRemoteService {
  QfRemoteService._();

  static final QfRemoteService instance = QfRemoteService._();

  static const _cookiesKey = 'qfr_cookies_v1';
  static const _baseCacheKey = 'qfr_web_base_v1';
  static const _usernameKey = 'qfr_username_v1';
  static const _markerCookie = 'qfr_src=qfclash';

  Map<String, String>? _cookies;
  String? _base;

  Future<Map<String, String>> _jar() async {
    if (_cookies != null) return _cookies!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cookiesKey);
    final jar = <String, String>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            jar[key.toString()] = value.toString();
          });
        }
      } catch (_) {}
    }
    return _cookies = jar;
  }

  Future<void> _saveJar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cookiesKey, jsonEncode(_cookies ?? {}));
  }

  Future<void> clearSession() async {
    _cookies = {};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cookiesKey);
    await prefs.remove(_usernameKey);
  }

  Future<bool> get hasSession async {
    final jar = await _jar();
    return jar.containsKey('xid');
  }

  Future<String> webBase() async {
    if (_base != null) return _base!;
    final prefs = await SharedPreferences.getInstance();
    var resolved = prefs.getString(_baseCacheKey) ?? '';
    try {
      final uri = Uri.parse(QfConfig.manifestUrl);
      final client = await QfHttpClient.create(uri: uri);
      try {
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 6));
        final response = await request.close().timeout(
          const Duration(seconds: 6),
        );
        if (response.statusCode == 200) {
          final text = await response.transform(utf8.decoder).join();
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) {
            final manifest = QfReleaseManifest.fromJson(decoded);
            if (manifest.qfRemoteWebBaseUrl.isNotEmpty) {
              resolved = manifest.qfRemoteWebBaseUrl;
              await prefs.setString(_baseCacheKey, resolved);
            }
          }
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {}
    if (resolved.isEmpty) resolved = QfConfig.builtinQfRemoteWebBaseUrl;
    return _base = resolved.replaceAll(RegExp(r'/+$'), '');
  }

  String _cookieHeader(Map<String, String> jar, {bool marker = false}) {
    final parts = <String>[
      if (marker) _markerCookie,
      for (final entry in jar.entries) '${entry.key}=${entry.value}',
    ];
    return parts.join('; ');
  }

  void _absorbCookies(HttpClientResponse response, Map<String, String> jar) {
    for (final cookie in response.cookies) {
      final expired =
          (cookie.maxAge != null && cookie.maxAge! <= 0) ||
          (cookie.expires != null && cookie.expires!.isBefore(DateTime.now()));
      if (expired) {
        jar.remove(cookie.name);
      } else {
        jar[cookie.name] = cookie.value;
      }
    }
  }

  Future<_QfrHttpResult> _request(
    String method,
    Uri uri, {
    Map<String, String>? form,
    bool marker = false,
    int redirectsLeft = 5,
  }) async {
    final jar = await _jar();
    final client = await QfHttpClient.create(uri: uri);
    try {
      var currentMethod = method;
      var currentUri = uri;
      Map<String, String>? currentForm = form;
      var frozen = false;
      while (true) {
        final request = await client
            .openUrl(currentMethod, currentUri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        final cookieHeader = _cookieHeader(jar, marker: marker);
        if (cookieHeader.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
        }
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'QFClash QFRemote module',
        );
        if (currentForm != null) {
          final body = currentForm.entries
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
              )
              .join('&');
          request.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
          );
          request.write(body);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        _absorbCookies(response, jar);
        if (response.headers.value('x-qf-login-result') == 'frozen') {
          frozen = true;
        }
        final status = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (redirectsLeft > 0 &&
            location != null &&
            (status == 301 ||
                status == 302 ||
                status == 303 ||
                status == 307 ||
                status == 308)) {
          await response.drain<void>();
          currentUri = currentUri.resolve(location);
          if (status == 301 || status == 302 || status == 303) {
            currentMethod = 'GET';
            currentForm = null;
          }
          redirectsLeft--;
          continue;
        }
        final text = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20));
        await _saveJar();
        return _QfrHttpResult(status, text, frozen);
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<QfrLoginResult> login(String username, String password) async {
    final base = await webBase();
    try {
      final result = await _request(
        'POST',
        Uri.parse('$base/qf-login'),
        form: {
          'username': username.trim(),
          'password': password,
          'qfrememberdevice': '1',
        },
        marker: true,
      );
      if (result.frozenSignal) {
        return const QfrLoginResult(QfrLoginOutcome.frozen);
      }
      final profile = await fetchProfile();
      if (profile != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_usernameKey, username.trim());
        return QfrLoginResult(QfrLoginOutcome.success, profile: profile);
      }
      return const QfrLoginResult(QfrLoginOutcome.invalidCredentials);
    } catch (_) {
      return const QfrLoginResult(QfrLoginOutcome.networkError);
    }
  }

  Future<QfrProfile?> fetchProfile() async {
    final base = await webBase();
    try {
      final result = await _request('GET', Uri.parse('$base/license/api/me'));
      if (result.statusCode != 200) return null;
      return QfrProfile.fromJson(jsonDecode(result.body));
    } catch (_) {
      return null;
    }
  }

  Future<QfrAccess?> fetchAccess() async {
    final base = await webBase();
    try {
      final result = await _request(
        'GET',
        Uri.parse('$base/license/api/qfclash-access'),
      );
      if (result.statusCode != 200) return null;
      return QfrAccess.fromJson(jsonDecode(result.body));
    } catch (_) {
      return null;
    }
  }

  // MeshCentral's /changepassword answers success and failure with the
  // same redirect, so the change is verified by signing in with the new
  // password; a verified sign-in also becomes the stored session.
  Future<bool> changePassword(String current, String next) async {
    final base = await webBase();
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(_usernameKey) ?? '';
    try {
      await _request(
        'POST',
        Uri.parse('$base/changepassword'),
        form: {'apassword0': current, 'apassword1': next, 'apassword2': next},
      );
    } catch (_) {
      return false;
    }
    if (username.isEmpty) return false;
    final verify = await login(username, next);
    return verify.outcome == QfrLoginOutcome.success;
  }

  Future<void> logout() async {
    final base = await webBase();
    try {
      await _request('GET', Uri.parse('$base/logout'));
    } catch (_) {}
    await clearSession();
  }

  Future<Map<String, String>> cookieJar() => _jar();
}
