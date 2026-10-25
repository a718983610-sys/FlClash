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

int? _qfOwnerUserId;

/// A few server views (forum authors, camp creators, support tickets)
/// carry a userId but no owner marker. Once any badged view (profile,
/// friend, login) has identified the owner in this session, those views
/// badge by id. Nothing is hardcoded: unlearned means unbadged.
void qfLearnOwnerFromView(Object? view) {
  var budget = 300;
  void walk(Object? node, int depth) {
    if (budget <= 0 || depth > 3) return;
    if (node is Map) {
      budget--;
      if (node['ownerBadge'] == 'green') {
        final id = node['userId'] ?? node['id'];
        if (id is num && id > 0) _qfOwnerUserId = id.toInt();
      }
      for (final value in node.values) {
        walk(value, depth + 1);
        if (budget <= 0) return;
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item, depth + 1);
        if (budget <= 0) return;
      }
    }
  }

  walk(view, 0);
}

bool qfIsOwnerUserId(Object? userId) {
  return userId is num &&
      _qfOwnerUserId != null &&
      userId.toInt() == _qfOwnerUserId;
}

@visibleForTesting
void qfResetLearnedOwnerUserId() {
  _qfOwnerUserId = null;
}

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
  bool saveLoginCredentials = false;

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
  static const String _kSaveLoginFlag = 'qf_save_login_credentials';
  static const String _kSavedLoginId = 'qf_saved_login_id';
  static const String _kSavedPassword = 'qf_saved_login_password';
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

  /// Keeps the signed-in email in step after a rebind so surfaces
  /// that prefill from the session stop showing the old address (C-27).
  void updateEmail(String newEmail) {
    email = newEmail;
    notifyListeners();
  }
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
    QfEndpoints.apply(primaryUrl: serverBaseUrl);
  }

  String serverBaseUrlFallback = '';

  void applyServerBaseUrlFallback(String url) {
    serverBaseUrlFallback = url.replaceAll(RegExp(r'/+$'), '');
    QfEndpoints.apply(backupUrl: serverBaseUrlFallback);
  }

  Future<void> init({required bool envEmulator}) async {
    _envEmulator = envEmulator;
    final prefs = await SharedPreferences.getInstance();
    rememberDevice = prefs.getBool(_kRemember) ?? true;
    saveLoginCredentials = prefs.getBool(_kSaveLoginFlag) ?? false;
    Future<String?> readSecure(String key) async {
      try {
        return await _secure.read(key: key);
      } catch (_) {
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
      // The cached session opens the app at once; validation runs behind it.
      mode = QfMode.user;
      unawaited(_validateStoredUserSession());
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
      unawaited(refreshGuestUsage());
    } else {
      mode = QfMode.entry;
    }
    await _syncGuestBlockedCore();
    notifyListeners();
  }

  /// The saved sign-in form credentials ("记住账号密码"): account
  /// identifier and password kept in secure storage only, prefilled by
  /// the login form while the user keeps the option on.
  Future<({String id, String password})?> loadSavedLogin() async {
    if (!saveLoginCredentials) return null;
    try {
      final id = await _secure.read(key: _kSavedLoginId);
      final password = await _secure.read(key: _kSavedPassword);
      if (id == null || id.isEmpty) return null;
      return (id: id, password: password ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<void> storeSavedLogin(String id, String password) async {
    saveLoginCredentials = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSaveLoginFlag, true);
    await _secure.write(key: _kSavedLoginId, value: id);
    await _secure.write(key: _kSavedPassword, value: password);
  }

  Future<void> clearSavedLogin() async {
    saveLoginCredentials = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSaveLoginFlag, false);
    try {
      await _secure.delete(key: _kSavedLoginId);
      await _secure.delete(key: _kSavedPassword);
    } catch (_) {}
  }

  Future<void> _validateStoredUserSession() async {
    final startRefreshToken = _refreshToken;
    // No forced rotation at cold start: refreshing a still-valid access
    // token on every launch multiplies the chances of a lost rotation
    // response stranding the stored refresh token (server reuse rules
    // then revoke every session). Refresh happens when the access
    // token is actually near expiry, or on a 401 via authed().
    await _refreshIfNeeded();
    if (_accessToken != null) {
      await _loadAccountState();
    } else if (_lastRefreshWasNetworkFailure) {
      // Remembered-device 30-day rule: a cold start on a dead network
      // (or an unreadable refresh response) must never sign the user
      // out. The stored session stays untouched; the next launch or
      // authed() call retries the refresh. Only a definitive server
      // rejection of the refresh token ends the session.
      accountStateSyncFailed = true;
    } else if (_refreshToken == startRefreshToken) {
      // Same token as at start: nobody signed in again, safe to drop it.
      await _clearUserSession();
      mode = QfMode.entry;
    } else {
      return;
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
      qfLearnOwnerFromView(user);
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

  Future<void> _applyServerCommands(Map<String, dynamic> data) async {
    final commands = data['commands'];
    if (commands is! List) return;
    for (final command in commands) {
      if (command is Map && command['type'] == 'disconnect') {
        await _runDisconnectCallback();
        return;
      }
    }
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
      final data = await QfHttp.send(
        method,
        '$serverBaseUrl$path',
        body: body,
        bearer: _accessToken,
        headers: headers,
      );
      qfLearnOwnerFromView(data);
      return data;
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
          final data = await QfHttp.send(
            method,
            '$serverBaseUrl$path',
            body: body,
            bearer: _accessToken,
            headers: headers,
          );
          qfLearnOwnerFromView(data);
          return data;
        }
        if (_lastRefreshWasNetworkFailure) {
          // The refresh never reached a server verdict (dead network,
          // intercepted response): the stored session may still be
          // valid, so a bad network moment must not sign the user out.
          // The original 401 propagates; the session clears only when
          // the server itself rejects the refresh token.
          rethrow;
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
    for (final url in QfEndpoints.rotationFor('$serverBaseUrl$path')) {
      final bytes = await _getBinaryAt(url);
      if (bytes != null) {
        QfEndpoints.noteSuccess(url);
        return bytes;
      }
    }
    return null;
  }

  Future<Uint8List?> _getBinaryAt(String fullUrl) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = await QfHttpClient.create(uri: Uri.parse(fullUrl));
      client.connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse(fullUrl));
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
            // Same 30-day rule as authed(): a network-dead refresh is
            // not a server verdict — never clear the session for it.
            if (_lastRefreshWasNetworkFailure) return null;
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
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
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
    final candidates = QfEndpoints.rotationFor('$serverBaseUrl$path');
    for (var i = 0; i < candidates.length; i++) {
      try {
        final data = await _postBinaryAt(
          candidates[i],
          bytes,
          headers: headers,
        );
        QfEndpoints.noteSuccess(candidates[i]);
        return data;
      } on QfApiException catch (e) {
        if (!e.isNetworkFailure || i == candidates.length - 1) rethrow;
      }
    }
    throw const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
  }

  Future<Map<String, dynamic>> _postBinaryAt(
    String fullUrl,
    Uint8List bytes, {
    Map<String, String>? headers,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = await QfHttpClient.create(uri: Uri.parse(fullUrl));
      client.connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.postUrl(Uri.parse(fullUrl));
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
        final text = await response
            .timeout(const Duration(seconds: 20))
            .transform(utf8.decoder)
            .join();
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
            if (_lastRefreshWasNetworkFailure) {
              throw const QfApiException(
                0,
                'NETWORK',
                '网络连接失败，请检查网络后重试',
              );
            }
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

  Future<bool>? _refreshFlight;

  /// Why the last refresh attempt failed, when it did. A network-class
  /// failure means the server never judged the refresh token, so the
  /// stored session may still be perfectly valid.
  QfApiException? _lastRefreshFailure;

  bool get _lastRefreshWasNetworkFailure {
    final failure = _lastRefreshFailure;
    if (failure == null) return true;
    return failure.isNetworkFailure || failure.code == 'BAD_RESPONSE';
  }

  /// Token refresh, single-flighted (C-04): concurrent authed() calls
  /// that all decide to refresh share one in-flight request. Without
  /// this, parallel refreshes rotate the same refresh token against
  /// each other and every caller ends up holding a dead token.
  Future<bool> _refreshIfNeeded({bool force = false}) {
    final flight = _refreshFlight;
    if (flight != null) return flight;
    final future = _refreshTokens(force: force);
    _refreshFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshFlight, future)) _refreshFlight = null;
    });
  }

  Future<bool> _refreshTokens({bool force = false}) async {
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
      final newAccessToken = (data['accessToken'] ?? '').toString();
      final newRefreshToken = (data['refreshToken'] ?? '').toString();
      if (newAccessToken.isEmpty || newRefreshToken.isEmpty) {
        // A refresh response without tokens is a failure, not a
        // successful rotation to empty credentials (C-04): keep the
        // current tokens so the session is not silently destroyed.
        return false;
      }
      _accessToken = newAccessToken;
      _refreshToken = newRefreshToken;
      _accessExpiresAt = (data['accessExpiresAt'] as num?)?.toInt() ?? 0;
      _heartbeatKey = (data['heartbeatKey'] ?? _heartbeatKey ?? '').toString();
      _lastRefreshFailure = null;
      if (rememberDevice) {
        await _storeCredentials();
      } else {
        await _wipeStoredCredentials();
      }
      return true;
    } on QfApiException catch (e) {
      _lastRefreshFailure = e;
      if (e.code == 'ACCOUNT_FROZEN') {
        await handleFrozen(e);
      } else if (e.code == 'ACCOUNT_BANNED') {
        await handleBanned(e);
      }
      return false;
    } catch (_) {
      _lastRefreshFailure = const QfApiException(
        0,
        'NETWORK',
        '网络连接失败，请检查网络后重试',
      );
      return false;
    }
  }

  /// Set when the last account-state load failed; the cached session
  /// keeps the app usable, but pages can tell the data may be stale.
  bool accountStateSyncFailed = false;

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
      accountStateSyncFailed = false;
      notifyListeners();
    } catch (_) {
      accountStateSyncFailed = true;
      notifyListeners();
    }
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
        } catch (_) {
          // The stored guest token is dead and re-entry failed too:
          // staying in guest mode would strand the user on a session
          // the server no longer knows (C-07).
          await exitGuestToEntry();
        }
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
      // _lastTrafficTotal is only committed after a successful send
      // (both branches below): a failed heartbeat must re-report the
      // same traffic delta next round instead of losing it (C-05).
      final clientTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final envFlags = _envEmulator ? 1 : 0;
      final rooted = await _detectRooted();
      final multiOpen = await _detectMultiOpen();
      if (mode == QfMode.user && _heartbeatKey != null) {
        final prefs = await SharedPreferences.getInstance();
        // Same rule as the guest path: the sequence is only committed
        // after a successful response, so a failed send retries with
        // the same seq and the same traffic delta (C-05).
        final nextSeq = _pointsSeq + 1;
        final identity = await QfDeviceIdentity.resolve();
        final sig = qfHeartbeatSignature(
          key: _heartbeatKey!,
          seq: nextSeq,
          clientTs: clientTs,
          trafficBytes: delta,
          envFlags: envFlags,
        );
        final data = await authed(
          'POST',
          '/points/heartbeat',
          body: {
            'deviceHash': identity.deviceHash,
            'seq': nextSeq,
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
        _pointsSeq = nextSeq;
        _lastTrafficTotal = total;
        await prefs.setInt(_kPointsSeq, _pointsSeq);
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
        await _applyServerCommands(data);
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
        _lastTrafficTotal = total;
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

  /// Re-reads the account state (deletion status, announcement
  /// rights, points snapshot) and notifies listeners, so a page that
  /// just changed that state - e.g. cancelling a pending account
  /// deletion (C-19) - reflects it immediately instead of showing the
  /// stale status until the next full reload.
  Future<void> refreshAccountState() async {
    await _loadAccountState();
    notifyListeners();
  }

  /// Set when the last background points refresh failed, so pages can
  /// show stale data as stale instead of silently presenting it (C-07).
  bool pointsSyncFailed = false;

  Future<void> refreshPoints() async {
    if (mode != QfMode.user) return;
    try {
      pointsMe = await authed('GET', '/points/me');
      pointsSyncFailed = false;
      notifyListeners();
    } catch (_) {
      pointsSyncFailed = true;
      notifyListeners();
    }
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

  String? _redeemPendingKey;
  int? _redeemPendingProductId;

  /// The idempotency key belongs to one order intent, not to one HTTP
  /// attempt (C-06): a create that timed out (but may have succeeded
  /// server-side) is retried with the SAME key so the server dedupes
  /// it. The key is only replaced after a create actually succeeds, or
  /// when the user switches to a different product.
  String _redeemKeyFor(int productId) {
    if (_redeemPendingKey == null || _redeemPendingProductId != productId) {
      _redeemPendingKey =
          'qf-${DateTime.now().microsecondsSinceEpoch}-$productId';
      _redeemPendingProductId = productId;
    }
    return _redeemPendingKey!;
  }

  Future<Map<String, dynamic>> redeemCreate(
    int productId, {
    String? payoutMethod,
    String? payoutAddress,
    String? payoutEmail,
  }) async {
    final result = await authed(
      'POST',
      '/redeem/orders',
      body: {
        'productId': productId,
        'idempotencyKey': _redeemKeyFor(productId),
        if (payoutMethod != null) 'payoutMethod': payoutMethod,
        if (payoutAddress != null) 'payoutAddress': payoutAddress,
        if (payoutEmail != null) 'payoutEmail': payoutEmail,
      },
      headers: await QfProofHeaders.collect(),
    );
    _redeemPendingKey = null;
    _redeemPendingProductId = null;
    return result;
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

  /// 外站精选（免登录，与网页版资讯流同一接口）。
  Future<Map<String, dynamic>> forumExternal({int limit = 10}) {
    return QfHttp.send('GET', '$serverBaseUrl/forum/external?limit=$limit');
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

  /// 营地头像原图（服务端 GET /forum/camps/:id/avatar），无头像时返回 null。
  Future<Uint8List?> forumCampAvatarBytes(int campId) {
    return qfGetBinary('/forum/camps/$campId/avatar');
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

  // Guest support (contract: docs/QFClash-游客客服接口契约-v1.md).
  // No login bearer: the pair is the device hash plus a guest support
  // credential the server issues on session entry. The credential is
  // kept in secure storage; a null guestToken in the entry response
  // means the stored one stays valid, a fresh one replaces it (the old
  // one dies server-side at once). Verification links the account to
  // the device row server-side and issues nothing, so there is no link
  // token on the client at all.
  static const String _kGuestSupportToken = 'qf_support_guest_token';
  String? _guestSupportTokenCache;

  Future<String> _guestDeviceHash() async =>
      (await QfDeviceIdentity.resolve()).deviceHash;

  Future<String?> _supportGuestCredential() async {
    if (_guestSupportTokenCache != null) return _guestSupportTokenCache;
    try {
      _guestSupportTokenCache = await _secure.read(key: _kGuestSupportToken);
    } catch (_) {}
    return _guestSupportTokenCache;
  }

  Future<void> _storeGuestToken(dynamic raw) async {
    final token = (raw ?? '').toString();
    if (token.isEmpty) return;
    _guestSupportTokenCache = token;
    try {
      await _secure.write(key: _kGuestSupportToken, value: token);
    } catch (_) {}
  }

  /// Entry: creates or resumes the guest credential and reports the
  /// current session state (sessionId/status/verified).
  Future<Map<String, dynamic>> guestSupportSession() async {
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/support/guest/session',
      body: {
        'deviceHash': await _guestDeviceHash(),
        'guestToken': ?await _supportGuestCredential(),
      },
    );
    await _storeGuestToken(data['guestToken']);
    return data;
  }

  /// One guest call with the contract's 401 recovery: rotate the
  /// credential through the entry endpoint once, then retry.
  Future<Map<String, dynamic>> _guestCall(
    Future<Map<String, dynamic>> Function() run,
  ) async {
    if (await _supportGuestCredential() == null) {
      await guestSupportSession();
    }
    try {
      return await run();
    } on QfApiException catch (e) {
      if (e.code != 'SUPPORT_GUEST_UNAUTHORIZED') rethrow;
      await guestSupportSession();
      return run();
    }
  }

  Future<Map<String, dynamic>> _guestBody([
    Map<String, dynamic>? extra,
  ]) async {
    return {
      'deviceHash': await _guestDeviceHash(),
      'guestToken': await _supportGuestCredential(),
      ...?extra,
    };
  }

  /// Entry state plus the message stream in one load (page entry and
  /// the contact tile); polling afterwards uses guestSupportFetch.
  Future<Map<String, dynamic>> guestSupportSnapshot() async {
    final entry = await guestSupportSession();
    final sessionId = (entry['sessionId'] ?? '').toString();
    final flow = await guestSupportFetch(
      sessionId: sessionId.isEmpty ? null : sessionId,
    );
    return {...entry, ...flow};
  }

  Future<Map<String, dynamic>> guestSupportFetch({String? sessionId}) {
    return _guestCall(() async {
      final query = sessionId == null
          ? ''
          : '?sessionId=${Uri.encodeQueryComponent(sessionId)}';
      return QfHttp.send(
        'GET',
        '$serverBaseUrl/support/guest/session$query',
        headers: {
          'x-device-hash': await _guestDeviceHash(),
          'x-guest-support-token': (await _supportGuestCredential()) ?? '',
        },
      );
    });
  }

  Future<Map<String, dynamic>> guestSupportAsk({
    String? sessionId,
    String? text,
    bool notThis = false,
    String? kbId,
  }) {
    return _guestCall(() async {
      return QfHttp.send(
        'POST',
        '$serverBaseUrl/support/guest/ask',
        body: await _guestBody({
          'sessionId': ?sessionId,
          if (notThis) 'notThis': true else 'text': text ?? '',
          'kbId': ?kbId,
        }),
      );
    });
  }

  Future<Map<String, dynamic>> guestSupportHandoff(String? sessionId) {
    return _guestCall(() async {
      return QfHttp.send(
        'POST',
        '$serverBaseUrl/support/guest/handoff',
        body: await _guestBody({'sessionId': ?sessionId}),
      );
    });
  }

  Future<Map<String, dynamic>> guestSupportVerify({
    required String account,
    required String password,
  }) {
    return _guestCall(() async {
      return QfHttp.send(
        'POST',
        '$serverBaseUrl/support/guest/verify',
        body: await _guestBody({'account': account, 'password': password}),
      );
    });
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
