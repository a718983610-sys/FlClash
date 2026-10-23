import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_api.dart';
import 'qf_http_client.dart';
import 'qf_config.dart';

enum QfMode { unknown, entry, user, guest }

class QfGuestUsage {
  final int dailyLimitSeconds;
  final int usedSeconds;
  final int remainingSeconds;
  final bool exhausted;

  const QfGuestUsage({
    required this.dailyLimitSeconds,
    required this.usedSeconds,
    required this.remainingSeconds,
    required this.exhausted,
  });

  factory QfGuestUsage.fromJson(Map<String, dynamic> json) {
    return QfGuestUsage(
      dailyLimitSeconds: (json['dailyLimitSeconds'] as num?)?.toInt() ?? 7200,
      usedSeconds: (json['usedSeconds'] as num?)?.toInt() ?? 0,
      remainingSeconds: (json['remainingSeconds'] as num?)?.toInt() ?? 0,
      exhausted: json['exhausted'] == true,
    );
  }
}

String qfHeartbeatSignature({
  required String key,
  required int seq,
  required int clientTs,
  required int trafficBytes,
  required int envFlags,
}) {
  final mac = Hmac(sha256, utf8.encode(key));
  return mac
      .convert(utf8.encode('$seq|$clientTs|$trafficBytes|$envFlags'))
      .toString();
}

Map<String, dynamic> qfGoogleCompleteBody({
  required String completionToken,
  required String username,
  required String password,
  required Map<String, dynamic> device,
}) {
  return {
    'completionToken': completionToken,
    'username': username.trim(),
    'password': password,
    ...device,
  };
}

class QfLoginOutcome {
  final bool dualVerifyRequired;
  final String message;

  const QfLoginOutcome({this.dualVerifyRequired = false, this.message = ''});
}

class QfSessionController extends ChangeNotifier {
  static const String _kMode = 'qf_mode';
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  bool rememberDevice = true;

  static const String _kAccess = 'qf_access_token';
  static const String _kRefresh = 'qf_refresh_token';
  static const String _kAccessExp = 'qf_access_expires_at';
  static const String _kHeartbeatKey = 'qf_heartbeat_key';
  static const String _kEmail = 'qf_user_email';
  static const String _kUsername = 'qf_user_username';
  static const String _kUserId = 'qf_user_id';
  static const String _kGuestToken = 'qf_guest_token';
  static const String _kGuestKey = 'qf_guest_heartbeat_key';
  static const String _kPointsSeq = 'qf_points_seq';
  static const String _kGuestSeq = 'qf_guest_seq';
  static const String _kRemember = 'qf_remember_device';
  static const String _kGuestExhaustedLocal = 'qf_guest_exhausted_local';
  static const String _kGuestBlockedCore = 'qf_guest_blocked_core';
  static const String _kGuestLedgerDay = 'qf_guest_ledger_day';
  static const String _kGuestLedgerUsedSec = 'qf_guest_ledger_used_sec';
  static const String _kGuestOfflineSince = 'qf_guest_offline_since';
  static const String _kGuestOfflineAccruedSec = 'qf_guest_offline_accrued_sec';
  static const String _kGuestReconcileId = 'qf_guest_reconcile_id';
  static const int guestDailyLimitSeconds = 7200;

  static bool startupHeldForQuota = false;

  static Future<bool> localGuestQuotaHold() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kMode) == 'guest' &&
          (prefs.getBool(_kGuestExhaustedLocal) ?? false);
    } catch (_) {
      return false;
    }
  }

  String serverBaseUrl = QfConfig.fallbackServerBaseUrl;
  QfMode mode = QfMode.unknown;
  String? email;
  String? username;
  int? userId;
  bool accountDeleting = false;
  int? deletionEffectiveAt;
  bool canAnnounce = false;
  QfGuestUsage? guestUsage;
  bool guestExhausted = false;
  bool guestOffline = false;
  Timer? _offlineTimer;
  int _offlineLastTickSec = 0;
  int Function() nowSecFn = () => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String? heartbeatNotice;
  Map<String, dynamic>? pointsMe;

  bool Function()? isRunningFn;
  int Function()? trafficTotalFn;
  Future<void> Function()? onAuthenticatedFn;
  Future<void> Function()? onGuestExhaustedFn;
  Future<void> Function()? onForceDisconnectFn;

  String? _completionToken;
  String? _completionEmail;
  String? _stepUpToken;
  String? _stepUpMaskedEmail;
  bool _pendingRemember = true;
  bool _accountIncomplete = false;
  Future<bool>? _rootedFuture;
  Future<bool>? _multiOpenFuture;

  bool get googleCompletionPending => _completionToken != null;
  String? get googleCompletionEmail => _completionEmail;
  bool get stepUpPending => _stepUpToken != null;
  String? get stepUpMaskedEmail => _stepUpMaskedEmail;
  bool get accountIncomplete => _accountIncomplete;

  String? _accessToken;
  String? _refreshToken;
  int _accessExpiresAt = 0;
  String? _heartbeatKey;
  String? _guestToken;
  String? _guestHeartbeatKey;
  int _pointsSeq = 0;
  int _guestSeq = 0;
  int _lastTrafficTotal = 0;
  bool _envEmulator = false;
  Timer? _heartbeatTimer;
  bool _beating = false;

  bool get isLoggedIn => mode == QfMode.user;
  bool get isGuest => mode == QfMode.guest;

  String? banNotice;
  String banReason = '';
  String banAccount = '';

  void consumeBanNotice() {
    banNotice = null;
    banReason = '';
    banAccount = '';
  }

  String? frozenNotice;
  String frozenAccount = '';
  int? frozenAt;

  void consumeFrozenNotice() {
    frozenNotice = null;
    frozenAccount = '';
    frozenAt = null;
  }

  String? registrationFrozenNotice;
  int? registrationFrozenUntil;

  void consumeRegistrationFrozenNotice() {
    registrationFrozenNotice = null;
    registrationFrozenUntil = null;
  }

  void captureRegistrationFrozen(QfApiException e) {
    registrationFrozenNotice = e.message;
    registrationFrozenUntil = (e.data['registrationFrozenUntil'] as num?)
        ?.toInt();
  }

  static String formatBanNotice(Map<String, dynamic> data) {
    if (data['permanent'] == true) {
      return '该用户已被永久封禁';
    }
    DateTime? time;
    final raw = data['bannedUntil'];
    if (raw is num && raw > 0) {
      time = DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000).toLocal();
    } else if (raw is String && raw.isNotEmpty) {
      final seconds = num.tryParse(raw);
      if (seconds != null && seconds > 0) {
        time = DateTime.fromMillisecondsSinceEpoch(
          seconds.toInt() * 1000,
        ).toLocal();
      } else {
        time = DateTime.tryParse(raw)?.toLocal();
      }
    }
    if (time != null) {
      String two(int v) => v.toString().padLeft(2, '0');
      return '该账户已被封禁，解除时间：${time.year}-${two(time.month)}-${two(time.day)} '
          '${two(time.hour)}:${two(time.minute)}';
    }
    return '该账户已被封禁';
  }

  Future<void> handleBanned(QfApiException e) async {
    banNotice = formatBanNotice(e.data);
    banReason = (e.data['reason'] ?? '').toString();
    banAccount = email ?? '';
    await _disconnectProxy();
    await _clearUserSession();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    mode = QfMode.entry;
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  Future<void> handleFrozen(QfApiException e, {String? account}) async {
    frozenNotice = e.message;
    frozenAccount = account ?? email ?? '';
    frozenAt = (e.data['passwordFrozenAt'] as num?)?.toInt();
    await _disconnectProxy();
    await _clearUserSession();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    mode = QfMode.entry;
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  void applyServerBaseUrl(String url) {
    if (url.isNotEmpty && url != serverBaseUrl) {
      serverBaseUrl = url.replaceAll(RegExp(r'/+$'), '');
    }
  }

  Future<void> init({required bool envEmulator}) async {
    _envEmulator = envEmulator;
    final prefs = await SharedPreferences.getInstance();
    rememberDevice = prefs.getBool(_kRemember) ?? true;
    var secureOk = true;
    Future<String?> readSecure(String key) async {
      try {
        return await _secure.read(key: key);
      } catch (_) {
        secureOk = false;
        return null;
      }
    }

    _accessToken = await readSecure(_kAccess);
    _refreshToken = await readSecure(_kRefresh);
    _accessExpiresAt = int.tryParse(await readSecure(_kAccessExp) ?? '') ?? 0;
    _heartbeatKey = await readSecure(_kHeartbeatKey);
    _guestToken = await readSecure(_kGuestToken);
    _guestHeartbeatKey = await readSecure(_kGuestKey);
    if (!rememberDevice) {
      await _wipeStoredCredentials();
      _accessToken = null;
      _refreshToken = null;
      _accessExpiresAt = 0;
      _heartbeatKey = null;
    } else {
      // Legacy plaintext copies in preferences: adopt what secure storage
      // lacks, migrate into secure storage, then always purge the plaintext.
      final legacyAccess = prefs.getString(_kAccess);
      final legacyRefresh = prefs.getString(_kRefresh);
      if ((legacyAccess != null && legacyAccess.isNotEmpty) ||
          (legacyRefresh != null && legacyRefresh.isNotEmpty)) {
        _accessToken ??= legacyAccess;
        _refreshToken ??= legacyRefresh;
        if (_accessExpiresAt == 0) {
          _accessExpiresAt = prefs.getInt(_kAccessExp) ?? 0;
        }
        _heartbeatKey ??= prefs.getString(_kHeartbeatKey);
        try {
          await _storeCredentials();
        } catch (_) {}
      }
      for (final key in [_kAccess, _kRefresh, _kAccessExp, _kHeartbeatKey]) {
        await prefs.remove(key);
      }
      if (_guestToken == null) {
        final legacyGuest = prefs.getString(_kGuestToken);
        if (legacyGuest != null && legacyGuest.isNotEmpty) {
          _guestToken = legacyGuest;
          _guestHeartbeatKey = prefs.getString(_kGuestKey);
          await _storeGuestCredentials();
        }
      }
      await prefs.remove(_kGuestToken);
      await prefs.remove(_kGuestKey);
    }
    email = prefs.getString(_kEmail);
    username = prefs.getString(_kUsername);
    userId = prefs.getInt(_kUserId);
    _pointsSeq = prefs.getInt(_kPointsSeq) ?? 0;
    _guestSeq = prefs.getInt(_kGuestSeq) ?? 0;
    final storedMode = prefs.getString(_kMode);
    if (storedMode == 'guest') {
      guestExhausted = prefs.getBool(_kGuestExhaustedLocal) ?? false;
    }
    if (storedMode == 'user' && _refreshToken != null) {
      mode = QfMode.user;
      await _refreshIfNeeded(force: true);
      if (_accessToken != null) {
        await _loadAccountState();
      } else {
        await _clearUserSession();
        mode = QfMode.entry;
      }
    } else if (storedMode == 'guest' &&
        _guestToken == null &&
        (prefs.getInt(_kGuestOfflineSince) ?? 0) > 0) {
      mode = QfMode.guest;
      guestOffline = true;
      final used = await _guestLedgerUsedToday(prefs);
      guestUsage = _localGuestUsage(used);
      guestExhausted = guestUsage?.exhausted ?? false;
      if (!guestExhausted) {
        _offlineLastTickSec = nowSecFn();
        _startOfflineTimer();
      }
    } else if (storedMode == 'guest' && _guestToken != null) {
      mode = QfMode.guest;
      await refreshGuestUsage();
    } else {
      mode = QfMode.entry;
    }
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  Future<void> _storeCredentials() async {
    if (!rememberDevice) return;
    Future<void> writeAll() async {
      await _secure.write(key: _kAccess, value: _accessToken ?? '');
      await _secure.write(key: _kRefresh, value: _refreshToken ?? '');
      await _secure.write(key: _kAccessExp, value: '$_accessExpiresAt');
      await _secure.write(key: _kHeartbeatKey, value: _heartbeatKey ?? '');
    }

    try {
      await writeAll();
    } catch (_) {
      try {
        await writeAll();
      } catch (_) {
        throw const QfApiException(0, 'STORAGE', QfCopy.storageSaveFailed);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_kAccess, _kRefresh, _kAccessExp, _kHeartbeatKey]) {
      await prefs.remove(key);
    }
  }

  Future<void> _storeGuestCredentials() async {
    try {
      await _secure.write(key: _kGuestToken, value: _guestToken ?? '');
      await _secure.write(key: _kGuestKey, value: _guestHeartbeatKey ?? '');
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kGuestToken);
    await prefs.remove(_kGuestKey);
  }

  Future<void> _wipeStoredCredentials() async {
    for (final key in [_kAccess, _kRefresh, _kAccessExp, _kHeartbeatKey]) {
      try {
        await _secure.delete(key: key);
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_kAccess, _kRefresh, _kAccessExp, _kHeartbeatKey]) {
      await prefs.remove(key);
    }
  }

  Future<void> _persistUserSession(
    Map<String, dynamic> data, {
    bool? remember,
  }) async {
    if (remember != null) rememberDevice = remember;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = (data['accessToken'] ?? '').toString();
    _refreshToken = (data['refreshToken'] ?? '').toString();
    _accessExpiresAt = (data['accessExpiresAt'] as num?)?.toInt() ?? 0;
    _heartbeatKey = (data['heartbeatKey'] ?? '').toString();
    final user = data['user'];
    if (user is Map) {
      email = (user['email'] ?? '').toString();
      username = (user['username'] ?? username ?? '').toString();
      userId = (user['id'] as num?)?.toInt();
    }
    accountDeleting = data['accountDeleting'] == true;
    deletionEffectiveAt = (data['deletionEffectiveAt'] as num?)?.toInt();
    if (rememberDevice) {
      await _storeCredentials();
    } else {
      await _wipeStoredCredentials();
    }
    await prefs.setString(_kEmail, email ?? '');
    await prefs.setString(_kUsername, username ?? '');
    if (userId != null) await prefs.setInt(_kUserId, userId!);
    await prefs.setString(_kMode, 'user');
    await prefs.setBool(_kRemember, rememberDevice);
    mode = QfMode.user;
    guestExhausted = false;
    await prefs.setBool(_kGuestExhaustedLocal, false);
    await _syncGuestBlockedCore();
    _accountIncomplete = username == null || username!.isEmpty;
    notifyListeners();
    final onAuthenticated = onAuthenticatedFn;
    if (onAuthenticated != null) {
      unawaited(Future<void>.sync(onAuthenticated).catchError((_) {}));
    }
    await _refreshAccountCompleteness();
  }

  Future<void> _clearUserSession() async {
    await _wipeStoredCredentials();
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_kEmail, _kUsername, _kUserId, _kRemember]) {
      await prefs.remove(key);
    }
    _accessToken = null;
    _refreshToken = null;
    _heartbeatKey = null;
    email = null;
    username = null;
    userId = null;
    pointsMe = null;
    accountDeleting = false;
    deletionEffectiveAt = null;
    canAnnounce = false;
    _completionToken = null;
    _completionEmail = null;
    _stepUpToken = null;
    _stepUpMaskedEmail = null;
    _accountIncomplete = false;
  }

  Future<void> _syncGuestBlockedCore() async {
    final blocked = switch (mode) {
      QfMode.user => false,
      QfMode.guest => guestExhausted,
      _ => true,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGuestBlockedCore, blocked);
    } catch (_) {}
  }

  Future<void> _runDisconnectCallback() async {
    final disconnect = onForceDisconnectFn ?? onGuestExhaustedFn;
    try {
      await disconnect?.call();
    } catch (_) {}
  }

  Future<void> _disconnectProxy() async {
    stopHeartbeat();
    await _runDisconnectCallback();
  }

  bool _captureStepUp(Map<String, dynamic> data, {required bool remember}) {
    if (data['needsStepUp'] != true && data['stepUpRequired'] != true) {
      return false;
    }
    final token = (data['stepUpToken'] ?? '').toString();
    if (token.isEmpty) return false;
    _stepUpToken = token;
    _stepUpMaskedEmail = (data['maskedEmail'] ?? '').toString();
    _pendingRemember = remember;
    notifyListeners();
    return true;
  }

  void _clearStepUp() {
    _stepUpToken = null;
    _stepUpMaskedEmail = null;
  }

  Future<void> _refreshAccountCompleteness() async {
    if (mode != QfMode.user) return;
    try {
      final data = await authed('GET', '/profile');
      final profile = data['profile'];
      final source = profile is Map ? Map<String, dynamic>.from(profile) : data;
      final profileUsername = source['username'];
      if (profileUsername is String && profileUsername.isNotEmpty) {
        username = profileUsername;
      } else if (profileUsername == null || profileUsername == '') {
        if (source.containsKey('username')) username = '';
      }
      final incomplete = username == null || username!.isEmpty;
      if (incomplete != _accountIncomplete) {
        _accountIncomplete = incomplete;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _deviceBody() async {
    final identity = await QfDeviceIdentity.resolve();
    return {
      'deviceHash': identity.deviceHash,
      'deviceName': identity.deviceName,
      'platform': identity.platform,
    };
  }

  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    await _refreshIfNeeded();
    try {
      return await QfHttp.send(
        method,
        '$serverBaseUrl$path',
        body: body,
        bearer: _accessToken,
        headers: headers,
      );
    } on QfApiException catch (e) {
      if (e.code == 'ACCOUNT_BANNED') {
        await handleBanned(e);
        rethrow;
      }
      if (e.code == 'ACCOUNT_FROZEN') {
        await handleFrozen(e);
        rethrow;
      }
      if (e.status == 401 && _refreshToken != null) {
        final refreshed = await _refreshIfNeeded(force: true);
        if (refreshed) {
          return QfHttp.send(
            method,
            '$serverBaseUrl$path',
            body: body,
            bearer: _accessToken,
            headers: headers,
          );
        }
        await _clearUserSession();
        mode = QfMode.entry;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<Uint8List?> qfGetBinary(String path) async {
    await _refreshIfNeeded();
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = await QfHttpClient.create(
        uri: Uri.parse('$serverBaseUrl$path'),
      );
      client.connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse('$serverBaseUrl$path'));
        final token = _accessToken;
        if (token != null && token.isNotEmpty) {
          request.headers.set('Authorization', 'Bearer $token');
        }
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode == 401 && attempt == 0) {
          if (_refreshToken == null) return null;
          final refreshed = await _refreshIfNeeded(force: true);
          if (!refreshed) {
            await _clearUserSession();
            mode = QfMode.entry;
            await _syncGuestBlockedCore();
            notifyListeners();
            return null;
          }
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return null;
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      } catch (_) {
        return null;
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> qfPostBinary(
    String path,
    Uint8List bytes, {
    Map<String, String>? headers,
  }) async {
    await _refreshIfNeeded();
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = await QfHttpClient.create(
        uri: Uri.parse('$serverBaseUrl$path'),
      );
      client.connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.postUrl(Uri.parse('$serverBaseUrl$path'));
        if (headers != null) {
          headers.forEach((key, value) {
            request.headers.set(key, value);
          });
        }
        final token = _accessToken;
        if (token != null && token.isNotEmpty) {
          request.headers.set('Authorization', 'Bearer $token');
        }
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        final text = await response.transform(utf8.decoder).join();
        Map<String, dynamic> data = {};
        if (text.isNotEmpty) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is Map) data = Map<String, dynamic>.from(decoded);
          } catch (_) {}
        }
        if (response.statusCode == 401 && attempt == 0) {
          if (_refreshToken == null) {
            throw QfApiException(
              401,
              (data['code'] ?? '').toString(),
              (data['message'] ?? '登录状态已失效，请重新登录。').toString(),
              data,
            );
          }
          final refreshed = await _refreshIfNeeded(force: true);
          if (!refreshed) {
            await _clearUserSession();
            mode = QfMode.entry;
            notifyListeners();
            throw QfApiException(
              401,
              (data['code'] ?? '').toString(),
              '登录状态已失效，请重新登录。',
              data,
            );
          }
          continue;
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
      } catch (_) {
        throw const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
      } finally {
        client.close(force: true);
      }
    }
    throw const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
  }

  Future<bool> _refreshIfNeeded({bool force = false}) async {
    if (_refreshToken == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!force && _accessToken != null && _accessExpiresAt > now + 60) {
      return true;
    }
    try {
      final data = await QfHttp.send(
        'POST',
        '$serverBaseUrl/auth/refresh',
        body: {'refreshToken': _refreshToken},
      );
      _accessToken = (data['accessToken'] ?? '').toString();
      _refreshToken = (data['refreshToken'] ?? '').toString();
      _accessExpiresAt = (data['accessExpiresAt'] as num?)?.toInt() ?? 0;
      _heartbeatKey = (data['heartbeatKey'] ?? _heartbeatKey ?? '').toString();
      if (rememberDevice) {
        await _storeCredentials();
      } else {
        await _wipeStoredCredentials();
      }
      return true;
    } on QfApiException catch (e) {
      if (e.code == 'ACCOUNT_FROZEN') {
        await handleFrozen(e);
      } else if (e.code == 'ACCOUNT_BANNED') {
        await handleBanned(e);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadAccountState() async {
    try {
      final me = await authed('GET', '/security/me');
      email = (me['email'] ?? email ?? '').toString();
      final meUsername = me['username'];
      if (meUsername is String && meUsername.isNotEmpty) {
        username = meUsername;
      }
      userId = (me['id'] as num?)?.toInt() ?? userId;
      accountDeleting = me['status'] == 'deleting';
      deletionEffectiveAt = (me['deletionEffectiveAt'] as num?)?.toInt();
      canAnnounce = me['canAnnounce'] == true || me['can_announce'] == true;
      final points = me['points'];
      if (points is Map) {
        pointsMe = {...(pointsMe ?? {}), ...Map<String, dynamic>.from(points)};
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<QfLoginOutcome> login({
    required String emailInput,
    required String password,
    String? emailCode,
    bool remember = true,
  }) async {
    final device = await _deviceBody();
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/login',
      body: {
        'email': emailInput.trim(),
        'account': emailInput.trim(),
        'password': password,
        if (emailCode != null && emailCode.isNotEmpty) 'emailCode': emailCode,
        ...device,
      },
    );
    if (data['dualVerifyRequired'] == true) {
      return QfLoginOutcome(
        dualVerifyRequired: true,
        message: (data['message'] ?? '').toString(),
      );
    }
    if (_captureStepUp(data, remember: remember)) {
      return const QfLoginOutcome();
    }
    await _persistUserSession(data, remember: remember);
    await refreshPoints();
    return const QfLoginOutcome();
  }

  Future<void> verifyStepUp(String code) async {
    final token = _stepUpToken;
    if (token == null) {
      throw const QfApiException(401, 'STEPUP_INVALID', '本次验证已失效，请重新登录。');
    }
    final device = await _deviceBody();
    try {
      final data = await QfHttp.send(
        'POST',
        '$serverBaseUrl/auth/stepup/verify',
        body: {'stepUpToken': token, 'code': code.trim(), ...device},
      );
      _clearStepUp();
      if (_captureStepUp(data, remember: _pendingRemember)) return;
      await _persistUserSession(data, remember: _pendingRemember);
      await refreshPoints();
    } on QfApiException catch (e) {
      if (e.code == 'STEPUP_INVALID') _clearStepUp();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> resendStepUp() async {
    final token = _stepUpToken;
    if (token == null) {
      throw const QfApiException(401, 'STEPUP_INVALID', '本次验证已失效，请重新登录。');
    }
    try {
      await QfHttp.send(
        'POST',
        '$serverBaseUrl/auth/stepup/resend',
        body: {'stepUpToken': token},
      );
    } on QfApiException catch (e) {
      if (e.code == 'STEPUP_INVALID') {
        _clearStepUp();
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> loginRequestCode(String emailInput) async {
    await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/login/request-code',
      body: {'email': emailInput.trim()},
    );
  }

  Future<void> googleLogin(String idToken, {bool remember = true}) async {
    final device = await _deviceBody();
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/google',
      body: {'idToken': idToken, ...device},
    );
    if (data['needsCompletion'] == true) {
      _completionToken = (data['completionToken'] ?? '').toString();
      _completionEmail = (data['email'] ?? '').toString();
      _pendingRemember = remember;
      if (_completionToken!.isEmpty) _completionToken = null;
      notifyListeners();
      return;
    }
    if (_captureStepUp(data, remember: remember)) return;
    await _persistUserSession(data, remember: remember);
    await refreshPoints();
  }

  Future<void> completeGoogleSetup({
    required String username,
    required String password,
  }) async {
    final token = _completionToken;
    if (token == null || token.isEmpty) {
      throw const QfApiException(
        401,
        'GOOGLE_COMPLETION_INVALID',
        '这次设置已经失效了，请重新用谷歌登录一次',
      );
    }
    final device = await _deviceBody();
    try {
      final data = await QfHttp.send(
        'POST',
        '$serverBaseUrl/auth/google/complete',
        body: qfGoogleCompleteBody(
          completionToken: token,
          username: username,
          password: password,
          device: device,
        ),
      );
      _completionToken = null;
      _completionEmail = null;
      if (_captureStepUp(data, remember: _pendingRemember)) return;
      await _persistUserSession(data, remember: _pendingRemember);
      await refreshPoints();
    } on QfApiException catch (e) {
      if (e.code == 'GOOGLE_COMPLETION_INVALID' ||
          e.code == 'GOOGLE_ALREADY_COMPLETED') {
        _completionToken = null;
        _completionEmail = null;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> completeUsername(String username) async {
    final data = await authed(
      'PUT',
      '/profile',
      body: {'username': username.trim()},
    );
    final profile = data['profile'];
    final source = profile is Map ? Map<String, dynamic>.from(profile) : data;
    final saved = source['username'];
    this.username = (saved is String && saved.isNotEmpty)
        ? saved
        : username.trim();
    _accountIncomplete = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUsername, this.username ?? '');
    notifyListeners();
  }

  Future<void> registerRequestCode(String emailInput) async {
    await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/register/request-code',
      body: {'email': emailInput.trim()},
    );
  }

  Future<String> registerVerify(String emailInput, String code) async {
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/register/verify',
      body: {'email': emailInput.trim(), 'code': code.trim()},
    );
    return (data['ticket'] ?? '').toString();
  }

  Future<void> registerComplete({
    required String ticket,
    required String password,
    required String usernameInput,
  }) async {
    final device = await _deviceBody();
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/register/complete',
      body: {
        'ticket': ticket,
        'password': password,
        'username': usernameInput.trim(),
        ...device,
      },
    );
    await _persistUserSession(data);
    await refreshPoints();
  }

  Future<void> resetRequestCode(String emailInput) async {
    await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/password/reset/request-code',
      body: {'email': emailInput.trim()},
    );
  }

  Future<void> resetConfirm({
    required String emailInput,
    required String code,
    required String newPassword,
  }) async {
    await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/password/reset/confirm',
      body: {
        'email': emailInput.trim(),
        'code': code.trim(),
        'newPassword': newPassword,
      },
    );
  }

  Future<void> logout() async {
    try {
      if (_accessToken != null) {
        await QfHttp.send(
          'POST',
          '$serverBaseUrl/auth/logout',
          bearer: _accessToken,
        );
      }
    } catch (_) {}
    await _disconnectProxy();
    await _clearUserSession();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    mode = QfMode.entry;
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  Future<void> _applyGuestUsage(
    Map<String, dynamic> data, {
    required bool notifyExhaustedTransition,
  }) async {
    guestUsage = QfGuestUsage.fromJson(data);
    final was = guestExhausted;
    guestExhausted = guestUsage?.exhausted ?? false;
    final prefs = await SharedPreferences.getInstance();
    await _saveGuestLedger(prefs, guestUsage?.usedSeconds ?? 0);
    await prefs.setBool(_kGuestExhaustedLocal, guestExhausted);
    await _syncGuestBlockedCore();
    notifyListeners();
    if (notifyExhaustedTransition && guestExhausted && !was) {
      await _runDisconnectCallback();
    }
  }

  Future<void> enterGuest() async {
    final identity = await QfDeviceIdentity.resolve();
    final Map<String, dynamic> data;
    try {
      data = await QfHttp.send(
        'POST',
        '$serverBaseUrl/guest/register',
        body: {
          'deviceHash': identity.deviceHash,
          'platform': identity.platform,
        },
      );
    } on QfApiException catch (e) {
      if (!e.isNetworkFailure) rethrow;
      await _enterOfflineGuest();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _guestToken = (data['guestToken'] ?? '').toString();
    _guestHeartbeatKey = (data['heartbeatKey'] ?? '').toString();
    await _storeGuestCredentials();
    await prefs.setString(_kMode, 'guest');
    await prefs.setInt(_kGuestOfflineSince, 0);
    guestOffline = false;
    mode = QfMode.guest;
    await _applyGuestUsage(data, notifyExhaustedTransition: false);
  }

  String _guestTodayKey() {
    final now = DateTime.fromMillisecondsSinceEpoch(nowSecFn() * 1000);
    return '${now.year}-${now.month}-${now.day}';
  }

  Future<int> _guestLedgerUsedToday(SharedPreferences prefs) async {
    if (prefs.getString(_kGuestLedgerDay) != _guestTodayKey()) return 0;
    return prefs.getInt(_kGuestLedgerUsedSec) ?? 0;
  }

  Future<void> _saveGuestLedger(SharedPreferences prefs, int usedSec) async {
    await prefs.setString(_kGuestLedgerDay, _guestTodayKey());
    await prefs.setInt(_kGuestLedgerUsedSec, usedSec);
  }

  QfGuestUsage _localGuestUsage(int usedSec) {
    final exhausted = usedSec >= guestDailyLimitSeconds;
    return QfGuestUsage(
      dailyLimitSeconds: guestDailyLimitSeconds,
      usedSeconds: usedSec,
      remainingSeconds: exhausted ? 0 : guestDailyLimitSeconds - usedSec,
      exhausted: exhausted,
    );
  }

  void _startOfflineTimer() {
    _offlineTimer?.cancel();
    _offlineTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(tickOfflineGuest()),
    );
  }

  Future<void> _enterOfflineGuest() async {
    final prefs = await SharedPreferences.getInstance();
    final used = await _guestLedgerUsedToday(prefs);
    guestOffline = true;
    _guestToken = null;
    _guestHeartbeatKey = null;
    await prefs.setString(_kMode, 'guest');
    mode = QfMode.guest;
    guestUsage = _localGuestUsage(used);
    guestExhausted = guestUsage?.exhausted ?? false;
    await prefs.setBool(_kGuestExhaustedLocal, guestExhausted);
    if (!guestExhausted) {
      final now = nowSecFn();
      final freshSegment = (prefs.getInt(_kGuestOfflineSince) ?? 0) <= 0;
      await prefs.setInt(_kGuestOfflineSince, now);
      _offlineLastTickSec = now;
      // One stable reconcile id per offline segment: a fresh segment always
      // mints a new id; re-entering an ongoing segment keeps the old one.
      var reconcileId = prefs.getString(_kGuestReconcileId);
      if (freshSegment || reconcileId == null || reconcileId.isEmpty) {
        final identity = await QfDeviceIdentity.resolve();
        final hash = identity.deviceHash;
        reconcileId =
            'offline-${hash.length > 12 ? hash.substring(0, 12) : hash}-$now';
        await prefs.setString(_kGuestReconcileId, reconcileId);
      }
      _startOfflineTimer();
    }
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  Future<void> tickOfflineGuest() async {
    if (!guestOffline || guestExhausted) return;
    final now = nowSecFn();
    final delta = now - _offlineLastTickSec;
    if (delta <= 0) return;
    _offlineLastTickSec = now;
    final prefs = await SharedPreferences.getInstance();
    final used = await _guestLedgerUsedToday(prefs) + delta;
    final accrued = (prefs.getInt(_kGuestOfflineAccruedSec) ?? 0) + delta;
    await _saveGuestLedger(prefs, used);
    await prefs.setInt(_kGuestOfflineAccruedSec, accrued);
    guestUsage = _localGuestUsage(used);
    if ((guestUsage?.exhausted ?? false) && !guestExhausted) {
      guestExhausted = true;
      await prefs.setBool(_kGuestExhaustedLocal, true);
      await _syncGuestBlockedCore();
      _offlineTimer?.cancel();
      await _runDisconnectCallback();
    }
    notifyListeners();
  }

  Future<void> tryRecoverOfflineGuest() async {
    if (!guestOffline || mode != QfMode.guest) return;
    final identity = await QfDeviceIdentity.resolve();
    final Map<String, dynamic> data;
    try {
      data = await QfHttp.send(
        'POST',
        '$serverBaseUrl/guest/register',
        body: {
          'deviceHash': identity.deviceHash,
          'platform': identity.platform,
        },
      );
    } on QfApiException catch (e) {
      if (e.isNetworkFailure) return;
      heartbeatNotice = e.message;
      await exitGuestToEntry();
      return;
    } catch (_) {
      return;
    }
    await tickOfflineGuest();
    final prefs = await SharedPreferences.getInstance();
    _guestToken = (data['guestToken'] ?? '').toString();
    _guestHeartbeatKey = (data['heartbeatKey'] ?? '').toString();
    await _storeGuestCredentials();
    await prefs.setInt(_kGuestOfflineSince, 0);
    guestOffline = false;
    _offlineTimer?.cancel();
    await _applyGuestUsage(data, notifyExhaustedTransition: true);
  }

  Future<void> refreshGuestUsage() async {
    if (_guestToken == null) return;
    try {
      final data = await QfHttp.send(
        'GET',
        '$serverBaseUrl/guest/usage',
        bearer: _guestToken,
      );
      await _applyGuestUsage(data, notifyExhaustedTransition: true);
    } on QfApiException catch (e) {
      if (e.code == 'GUEST_TOKEN_INVALID') {
        try {
          await enterGuest();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> exitGuestToEntry() async {
    _offlineTimer?.cancel();
    guestOffline = false;
    await _disconnectProxy();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    await prefs.setInt(_kGuestOfflineSince, 0);
    mode = QfMode.entry;
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(beat()),
    );
    unawaited(beat());
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<bool> _detectRooted() {
    return _rootedFuture ??= () async {
      if (!Platform.isAndroid) return false;
      try {
        const suPaths = [
          '/system/bin/su',
          '/system/xbin/su',
          '/sbin/su',
          '/system/app/Superuser.apk',
          '/system/app/Magisk.apk',
        ];
        for (final path in suPaths) {
          if (await File(path).exists()) return true;
        }
      } catch (_) {}
      return false;
    }();
  }

  // Windows has no rooted/multi-open signal reachable from Dart, so it stays false there.
  Future<bool> _detectMultiOpen() {
    return _multiOpenFuture ??= () async {
      if (!Platform.isAndroid) return false;
      try {
        final probe = '${Platform.resolvedExecutable} ${Directory.current.path}'
            .toLowerCase();
        const markers = ['virtual', 'parallel', 'multiopen', 'vmos', 'sandbox'];
        return markers.any(probe.contains);
      } catch (_) {
        return false;
      }
    }();
  }

  Future<void> beat() async {
    if (_beating) return;
    final running = isRunningFn?.call() ?? false;
    if (!running) return;
    _beating = true;
    try {
      if (mode == QfMode.guest && guestOffline) {
        await tickOfflineGuest();
        await tryRecoverOfflineGuest();
        return;
      }
      final total = trafficTotalFn?.call() ?? 0;
      var delta = total - _lastTrafficTotal;
      if (delta < 0) delta = total;
      _lastTrafficTotal = total;
      final clientTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final envFlags = _envEmulator ? 1 : 0;
      final rooted = await _detectRooted();
      final multiOpen = await _detectMultiOpen();
      if (mode == QfMode.user && _heartbeatKey != null) {
        final prefs = await SharedPreferences.getInstance();
        _pointsSeq += 1;
        await prefs.setInt(_kPointsSeq, _pointsSeq);
        final identity = await QfDeviceIdentity.resolve();
        final sig = qfHeartbeatSignature(
          key: _heartbeatKey!,
          seq: _pointsSeq,
          clientTs: clientTs,
          trafficBytes: delta,
          envFlags: envFlags,
        );
        final data = await authed(
          'POST',
          '/points/heartbeat',
          body: {
            'deviceHash': identity.deviceHash,
            'seq': _pointsSeq,
            'clientTs': clientTs,
            'trafficBytes': delta,
            'env': {
              'emulator': _envEmulator,
              'rooted': rooted,
              'multiOpen': multiOpen,
            },
            'sig': sig,
          },
        );
        if (data['accepted'] == false && data['reason'] == 'seq_out_of_order') {
          _pointsSeq = (data['serverSeq'] as num?)?.toInt() ?? _pointsSeq;
          await prefs.setInt(_kPointsSeq, _pointsSeq);
        }
        final notice = data['notice'];
        if (notice is String && notice.isNotEmpty) {
          heartbeatNotice = notice;
          notifyListeners();
        }
        if (data['settled'] != null) {
          await refreshPoints();
        }
      } else if (mode == QfMode.guest &&
          _guestToken != null &&
          _guestHeartbeatKey != null) {
        final prefs = await SharedPreferences.getInstance();
        // The sequence is only committed after a successful response: a
        // rejected heartbeat (e.g. a reconcile 400, which the server raises
        // before consuming the sequence) must be retryable with the same seq.
        final nextSeq = _guestSeq + 1;
        final sig = qfHeartbeatSignature(
          key: _guestHeartbeatKey!,
          seq: nextSeq,
          clientTs: clientTs,
          trafficBytes: delta,
          envFlags: envFlags,
        );
        final pendingAccrued = prefs.getInt(_kGuestOfflineAccruedSec) ?? 0;
        final accruedSend = pendingAccrued.clamp(0, 7200);
        final reconcileId = prefs.getString(_kGuestReconcileId);
        final data = await QfHttp.send(
          'POST',
          '$serverBaseUrl/guest/heartbeat',
          bearer: _guestToken,
          body: {
            'seq': nextSeq,
            'clientTs': clientTs,
            'trafficBytes': delta,
            'env': {
              'emulator': _envEmulator,
              'rooted': rooted,
              'multiOpen': multiOpen,
            },
            'sig': sig,
            if (accruedSend > 0 && reconcileId != null)
              'offlineAccruedSec': accruedSend,
            if (accruedSend > 0 && reconcileId != null)
              'reconcileId': reconcileId,
          },
        );
        _guestSeq = nextSeq;
        await prefs.setInt(_kGuestSeq, _guestSeq);
        if (pendingAccrued > 0 && data['accepted'] != false) {
          await prefs.setInt(_kGuestOfflineAccruedSec, 0);
          await prefs.remove(_kGuestReconcileId);
        }
        if (data['accepted'] == false && data['reason'] == 'seq_out_of_order') {
          _guestSeq = (data['serverSeq'] as num?)?.toInt() ?? _guestSeq;
          await prefs.setInt(_kGuestSeq, _guestSeq);
        }
        await _applyGuestUsage(data, notifyExhaustedTransition: true);
      }
    } catch (_) {
    } finally {
      _beating = false;
    }
  }

  Future<void> refreshPoints() async {
    if (mode != QfMode.user) return;
    try {
      pointsMe = await authed('GET', '/points/me');
      notifyListeners();
    } catch (_) {}
  }

  Future<List<dynamic>> pointsLedger() async {
    final data = await authed('GET', '/points/ledger?limit=50');
    final entries = data['entries'];
    return entries is List ? entries : const [];
  }

  Future<Map<String, dynamic>> pointsRules() async {
    return QfHttp.send(
      'GET',
      '$serverBaseUrl/points/rules',
      headers: await QfProofHeaders.collect(),
    );
  }

  Future<Map<String, dynamic>> redeemProducts() {
    return authed('GET', '/redeem/products');
  }

  Future<Map<String, dynamic>> redeemCreate(
    int productId, {
    String? payoutMethod,
    String? payoutAddress,
    String? payoutEmail,
  }) async {
    return authed(
      'POST',
      '/redeem/orders',
      body: {
        'productId': productId,
        'idempotencyKey':
            'qf-${DateTime.now().millisecondsSinceEpoch}-$productId',
        if (payoutMethod != null) 'payoutMethod': payoutMethod,
        if (payoutAddress != null) 'payoutAddress': payoutAddress,
        if (payoutEmail != null) 'payoutEmail': payoutEmail,
      },
      headers: await QfProofHeaders.collect(),
    );
  }

  Future<void> redeemCodeRequest(int orderId) async {
    await authed('POST', '/redeem/orders/$orderId/code/request');
  }

  Future<String> redeemCodeReveal(
    int orderId,
    String password,
    String emailCode,
  ) async {
    final data = await authed(
      'POST',
      '/redeem/orders/$orderId/code/reveal',
      body: {'password': password, 'emailCode': emailCode.trim()},
    );
    return (data['code'] ?? '').toString();
  }

  Future<Map<String, dynamic>> passkeyRegisterOptions(String password) async {
    final data = await authed(
      'POST',
      '/passkeys/register/options',
      body: {'password': password},
    );
    final options = data['options'];
    return options is Map
        ? Map<String, dynamic>.from(options)
        : Map<String, dynamic>.from(data);
  }

  Future<void> passkeyRegisterVerify(
    Map<String, dynamic> response, {
    String? name,
  }) async {
    await authed(
      'POST',
      '/passkeys/register/verify',
      body: {'response': response, if (name != null) 'name': name},
    );
  }

  Future<List<dynamic>> passkeyList() async {
    final data = await authed('GET', '/passkeys');
    final list = data['passkeys'] ?? data['items'];
    return list is List ? list : const [];
  }

  Future<void> passkeyDelete(int id, String password) async {
    await authed('DELETE', '/passkeys/$id', body: {'password': password});
  }

  Future<Map<String, dynamic>> passkeyLoginOptions(String? identifier) async {
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/passkeys/login/options',
      body: {
        if (identifier != null && identifier.trim().isNotEmpty)
          'identifier': identifier.trim(),
      },
    );
    final options = data['options'];
    return options is Map
        ? Map<String, dynamic>.from(options)
        : Map<String, dynamic>.from(data);
  }

  Future<void> passkeyLoginVerify(
    Map<String, dynamic> response, {
    bool remember = true,
  }) async {
    final device = await _deviceBody();
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/passkeys/login/verify',
      body: {'response': response, ...device},
    );
    await _persistUserSession(data, remember: remember);
    await refreshPoints();
  }

  Future<List<dynamic>> myOrders() async {
    final data = await authed('GET', '/redeem/my');
    final orders = data['orders'];
    return orders is List ? orders : const [];
  }

  Future<List<dynamic>> securityDevices() async {
    final data = await authed('GET', '/security/devices');
    final devices = data['devices'];
    return devices is List ? devices : const [];
  }

  Future<void> securityUntrustDevice(int deviceId) async {
    await authed('POST', '/security/devices/$deviceId/untrust', body: {});
  }

  Future<void> deleteSettingsVault() async {
    await authed('DELETE', '/me/settingsvault');
  }

  Future<void> refreshCanAnnounce() async {
    if (mode != QfMode.user || _accessToken == null) return;
    try {
      final me = await authed(
        'GET',
        '/auth/me',
      ).timeout(const Duration(seconds: 3));
      if (me['canAnnounce'] is bool) canAnnounce = me['canAnnounce'] == true;
    } catch (_) {}
  }

  Future<Map<String, dynamic>> chatBlobs({int limit = 30, int offset = 0}) {
    return authed('GET', '/chat/blobs?limit=$limit&offset=$offset');
  }

  Future<void> redeemCancelOrder(int orderId) async {
    await authed('POST', '/redeem/orders/$orderId/cancel', body: {});
  }

  Future<void> redeemChangePayoutAddress(
    int orderId,
    String payoutAddress,
  ) async {
    await authed(
      'POST',
      '/redeem/orders/$orderId/payout-address',
      body: {'payoutAddress': payoutAddress.trim()},
    );
  }

  Future<void> submitFeedback({
    required String content,
    String? contact,
    required String appVersion,
  }) async {
    final identity = await QfDeviceIdentity.resolve();
    await QfHttp.send(
      'POST',
      '$serverBaseUrl/feedback',
      body: {
        'content': content,
        if (contact != null && contact.isNotEmpty) 'contact': contact,
        'source': 'app',
        'platform': identity.platform,
        'appVersion': appVersion,
        'deviceHash': identity.deviceHash,
      },
      bearer: _accessToken ?? _guestToken,
    );
  }

  Future<Map<String, dynamic>> forumBoards() {
    return QfHttp.send('GET', '$serverBaseUrl/forum/boards');
  }

  Future<Map<String, dynamic>> forumPosts({
    String? board,
    int offset = 0,
    int limit = 20,
  }) {
    final query = {
      if (board != null) 'board': board,
      'limit': '$limit',
      'offset': '$offset',
    };
    final qs = query.entries.map((e) => '${e.key}=${e.value}').join('&');
    return QfHttp.send(
      'GET',
      '$serverBaseUrl/forum/posts?$qs',
      bearer: _accessToken,
    );
  }

  Future<Map<String, dynamic>> forumPostDetail(int id) {
    return QfHttp.send(
      'GET',
      '$serverBaseUrl/forum/posts/$id',
      bearer: _accessToken,
    );
  }

  Future<Map<String, dynamic>> forumCreatePost({
    required String board,
    required String title,
    required String content,
    int? campId,
  }) {
    return authed(
      'POST',
      '/forum/posts',
      body: {
        'board': board,
        'title': title,
        'content': content,
        if (campId != null) 'campId': campId,
      },
    );
  }

  Future<Map<String, dynamic>> forumLikePost(int postId, bool liked) {
    return authed('POST', '/forum/posts/$postId/like', body: {'liked': liked});
  }

  Future<Map<String, dynamic>> forumSharePost(int postId) {
    return authed('POST', '/forum/posts/$postId/share', body: {});
  }

  Future<void> forumApplyReward(int postId) async {
    await authed('POST', '/forum/posts/$postId/reward-applications', body: {});
  }

  Future<Map<String, dynamic>> forumUserProfile(int userId) {
    return QfHttp.send(
      'GET',
      '$serverBaseUrl/forum/users/$userId/profile',
      bearer: _accessToken,
    );
  }

  Future<Map<String, dynamic>> forumMeHome() {
    return authed('GET', '/forum/me/forum-home');
  }

  Future<Map<String, dynamic>> forumAnalytics() {
    return authed('GET', '/forum/me/analytics');
  }

  Future<Map<String, dynamic>> forumCamps() {
    return QfHttp.send(
      'GET',
      '$serverBaseUrl/forum/camps',
      bearer: _accessToken,
    );
  }

  Future<Map<String, dynamic>> forumCampDetail(int campId) {
    return QfHttp.send(
      'GET',
      '$serverBaseUrl/forum/camps/$campId',
      bearer: _accessToken,
    );
  }

  Future<Map<String, dynamic>> forumJoinCamp(int campId, bool joined) {
    return authed(
      'POST',
      '/forum/camps/$campId/join',
      body: {'joined': joined},
    );
  }

  Future<Map<String, dynamic>> forumCreateCamp({
    required String name,
    required String description,
  }) {
    return authed(
      'POST',
      '/forum/camps',
      body: {'name': name, 'description': description},
    );
  }

  Future<Map<String, dynamic>> forumMyCamps() {
    return authed('GET', '/forum/me/camps');
  }

  Future<Map<String, dynamic>> forumEditCamp(
    int campId, {
    String? name,
    String? description,
  }) {
    return authed(
      'POST',
      '/forum/camps/$campId/edit',
      body: {'name': ?name, 'description': ?description},
    );
  }

  Future<void> forumDeleteCamp(int campId) async {
    await authed('DELETE', '/forum/camps/$campId');
  }

  Future<List<dynamic>> forumRewardApplications() async {
    final data = await authed('GET', '/forum/me/reward-applications');
    final applications = data['applications'];
    return applications is List ? applications : const [];
  }

  Future<Map<String, dynamic>> forumCreateReply(int postId, String content) {
    return authed(
      'POST',
      '/forum/posts/$postId/replies',
      body: {'content': content},
    );
  }

  Future<void> forumReport(int postId) async {
    await authed('POST', '/forum/posts/$postId/report', body: {});
  }

  Future<Map<String, dynamic>> forumProfile() {
    return authed('GET', '/forum/profile');
  }

  Future<void> forumUpdateNickname(String nickname) async {
    await authed('PUT', '/forum/profile', body: {'nickname': nickname});
  }

  Future<Map<String, dynamic>> supportSession() {
    return authed('GET', '/support/session');
  }

  Future<Map<String, dynamic>> supportAsk({
    String? sessionId,
    String? text,
    bool notThis = false,
    String? kbId,
  }) {
    return authed(
      'POST',
      '/support/ask',
      body: {
        'sessionId': ?sessionId,
        if (notThis) 'notThis': true else 'text': text ?? '',
        'kbId': ?kbId,
      },
    );
  }

  Future<Map<String, dynamic>> supportHandoff(String? sessionId) {
    return authed('POST', '/support/handoff', body: {'sessionId': ?sessionId});
  }

  Future<Map<String, dynamic>> supportInbox() {
    return authed('GET', '/support/inbox');
  }

  Future<Map<String, dynamic>> supportInboxDetail(String sessionId) {
    return authed('GET', '/support/inbox/${Uri.encodeComponent(sessionId)}');
  }

  Future<void> supportInboxReply(String sessionId, String text) async {
    await authed(
      'POST',
      '/support/inbox/${Uri.encodeComponent(sessionId)}/reply',
      body: {'text': text},
    );
  }

  Future<void> supportInboxClose(String sessionId) async {
    await authed(
      'POST',
      '/support/inbox/${Uri.encodeComponent(sessionId)}/close',
      body: {},
    );
  }
}
