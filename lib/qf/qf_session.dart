import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_api.dart';
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

class QfLoginOutcome {
  final bool dualVerifyRequired;
  final String message;

  const QfLoginOutcome({this.dualVerifyRequired = false, this.message = ''});
}

class QfSessionController extends ChangeNotifier {
  static const String _kMode = 'qf_mode';
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

  String serverBaseUrl = QfConfig.fallbackServerBaseUrl;
  QfMode mode = QfMode.unknown;
  String? email;
  String? username;
  int? userId;
  bool accountDeleting = false;
  int? deletionEffectiveAt;
  QfGuestUsage? guestUsage;
  bool guestExhausted = false;
  String? heartbeatNotice;
  Map<String, dynamic>? pointsMe;

  bool Function()? isRunningFn;
  int Function()? trafficTotalFn;
  Future<void> Function()? onGuestExhaustedFn;

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

  void consumeBanNotice() {
    banNotice = null;
  }

  static String formatBanNotice(Map<String, dynamic> data) {
    final buffer = StringBuffer();
    if (data['permanent'] == true) {
      buffer.write('该账户已被永久封禁');
    } else {
      final until = (data['bannedUntil'] as num?)?.toInt();
      if (until != null && until > 0) {
        final time = DateTime.fromMillisecondsSinceEpoch(until * 1000);
        String two(int v) => v.toString().padLeft(2, '0');
        buffer.write(
          '该账户已被封禁，解除时间：${time.year}-${two(time.month)}-${two(time.day)} '
          '${two(time.hour)}:${two(time.minute)}',
        );
      } else {
        buffer.write('该账户已被封禁');
      }
    }
    final reason = (data['reason'] ?? '').toString();
    if (reason.isNotEmpty) {
      buffer.write('（$reason）');
    }
    buffer.write('\n如有疑问，可通过意见反馈或邮箱 a718983610@gmail.com 申诉。');
    return buffer.toString();
  }

  Future<void> handleBanned(QfApiException e) async {
    banNotice = formatBanNotice(e.data);
    stopHeartbeat();
    await _clearUserSession();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    mode = QfMode.entry;
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
    _accessToken = prefs.getString(_kAccess);
    _refreshToken = prefs.getString(_kRefresh);
    _accessExpiresAt = prefs.getInt(_kAccessExp) ?? 0;
    _heartbeatKey = prefs.getString(_kHeartbeatKey);
    email = prefs.getString(_kEmail);
    username = prefs.getString(_kUsername);
    userId = prefs.getInt(_kUserId);
    _guestToken = prefs.getString(_kGuestToken);
    _guestHeartbeatKey = prefs.getString(_kGuestKey);
    _pointsSeq = prefs.getInt(_kPointsSeq) ?? 0;
    _guestSeq = prefs.getInt(_kGuestSeq) ?? 0;
    final storedMode = prefs.getString(_kMode);
    if (storedMode == 'user' && _refreshToken != null) {
      mode = QfMode.user;
      await _refreshIfNeeded(force: true);
      if (_accessToken != null) {
        await _loadAccountState();
      } else {
        await _clearUserSession();
        mode = QfMode.entry;
      }
    } else if (storedMode == 'guest' && _guestToken != null) {
      mode = QfMode.guest;
      await refreshGuestUsage();
    } else {
      mode = QfMode.entry;
    }
    notifyListeners();
  }

  Future<void> _persistUserSession(Map<String, dynamic> data) async {
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
    await prefs.setString(_kAccess, _accessToken ?? '');
    await prefs.setString(_kRefresh, _refreshToken ?? '');
    await prefs.setInt(_kAccessExp, _accessExpiresAt);
    await prefs.setString(_kHeartbeatKey, _heartbeatKey ?? '');
    await prefs.setString(_kEmail, email ?? '');
    await prefs.setString(_kUsername, username ?? '');
    if (userId != null) await prefs.setInt(_kUserId, userId!);
    await prefs.setString(_kMode, 'user');
    mode = QfMode.user;
    guestExhausted = false;
    notifyListeners();
  }

  Future<void> _clearUserSession() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _kAccess,
      _kRefresh,
      _kHeartbeatKey,
      _kEmail,
      _kUsername,
      _kUserId,
    ]) {
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
  }) async {
    await _refreshIfNeeded();
    try {
      return await QfHttp.send(
        method,
        '$serverBaseUrl$path',
        body: body,
        bearer: _accessToken,
      );
    } on QfApiException catch (e) {
      if (e.code == 'ACCOUNT_BANNED') {
        await handleBanned(e);
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
          );
        }
        await _clearUserSession();
        mode = QfMode.entry;
        notifyListeners();
      }
      rethrow;
    }
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
      final prefs = await SharedPreferences.getInstance();
      _accessToken = (data['accessToken'] ?? '').toString();
      _refreshToken = (data['refreshToken'] ?? '').toString();
      _accessExpiresAt = (data['accessExpiresAt'] as num?)?.toInt() ?? 0;
      _heartbeatKey = (data['heartbeatKey'] ?? _heartbeatKey ?? '').toString();
      await prefs.setString(_kAccess, _accessToken ?? '');
      await prefs.setString(_kRefresh, _refreshToken ?? '');
      await prefs.setInt(_kAccessExp, _accessExpiresAt);
      await prefs.setString(_kHeartbeatKey, _heartbeatKey ?? '');
      return true;
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
  }) async {
    final device = await _deviceBody();
    final data = await QfHttp.send('POST', '$serverBaseUrl/auth/login', body: {
      'email': emailInput.trim(),
      'account': emailInput.trim(),
      'password': password,
      if (emailCode != null && emailCode.isNotEmpty) 'emailCode': emailCode,
      ...device,
    });
    if (data['dualVerifyRequired'] == true) {
      return QfLoginOutcome(
        dualVerifyRequired: true,
        message: (data['message'] ?? '').toString(),
      );
    }
    await _persistUserSession(data);
    await refreshPoints();
    return const QfLoginOutcome();
  }

  Future<void> loginRequestCode(String emailInput) async {
    await QfHttp.send(
      'POST',
      '$serverBaseUrl/auth/login/request-code',
      body: {'email': emailInput.trim()},
    );
  }

  Future<void> googleLogin(String idToken) async {
    final device = await _deviceBody();
    final data = await QfHttp.send('POST', '$serverBaseUrl/auth/google', body: {
      'idToken': idToken,
      ...device,
    });
    await _persistUserSession(data);
    await refreshPoints();
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
    await _clearUserSession();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    mode = QfMode.entry;
    notifyListeners();
  }

  Future<void> enterGuest() async {
    final identity = await QfDeviceIdentity.resolve();
    final data = await QfHttp.send(
      'POST',
      '$serverBaseUrl/guest/register',
      body: {'deviceHash': identity.deviceHash, 'platform': identity.platform},
    );
    final prefs = await SharedPreferences.getInstance();
    _guestToken = (data['guestToken'] ?? '').toString();
    _guestHeartbeatKey = (data['heartbeatKey'] ?? '').toString();
    await prefs.setString(_kGuestToken, _guestToken ?? '');
    await prefs.setString(_kGuestKey, _guestHeartbeatKey ?? '');
    await prefs.setString(_kMode, 'guest');
    guestUsage = QfGuestUsage.fromJson(data);
    guestExhausted = guestUsage?.exhausted ?? false;
    mode = QfMode.guest;
    notifyListeners();
  }

  Future<void> refreshGuestUsage() async {
    if (_guestToken == null) return;
    try {
      final data = await QfHttp.send(
        'GET',
        '$serverBaseUrl/guest/usage',
        bearer: _guestToken,
      );
      guestUsage = QfGuestUsage.fromJson(data);
      final was = guestExhausted;
      guestExhausted = guestUsage?.exhausted ?? false;
      notifyListeners();
      if (guestExhausted && !was) {
        await onGuestExhaustedFn?.call();
      }
    } on QfApiException catch (e) {
      if (e.code == 'GUEST_TOKEN_INVALID') {
        try {
          await enterGuest();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> exitGuestToEntry() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, 'entry');
    mode = QfMode.entry;
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

  Future<void> beat() async {
    if (_beating) return;
    final running = isRunningFn?.call() ?? false;
    if (!running) return;
    _beating = true;
    try {
      final total = trafficTotalFn?.call() ?? 0;
      var delta = total - _lastTrafficTotal;
      if (delta < 0) delta = total;
      _lastTrafficTotal = total;
      final clientTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final envFlags = _envEmulator ? 1 : 0;
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
        final data = await authed('POST', '/points/heartbeat', body: {
          'deviceHash': identity.deviceHash,
          'seq': _pointsSeq,
          'clientTs': clientTs,
          'trafficBytes': delta,
          'env': {
            'emulator': _envEmulator,
            'rooted': false,
            'multiOpen': false,
          },
          'sig': sig,
        });
        if (data['accepted'] == false &&
            data['reason'] == 'seq_out_of_order') {
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
        _guestSeq += 1;
        await prefs.setInt(_kGuestSeq, _guestSeq);
        final sig = qfHeartbeatSignature(
          key: _guestHeartbeatKey!,
          seq: _guestSeq,
          clientTs: clientTs,
          trafficBytes: delta,
          envFlags: envFlags,
        );
        final data = await QfHttp.send(
          'POST',
          '$serverBaseUrl/guest/heartbeat',
          bearer: _guestToken,
          body: {
            'seq': _guestSeq,
            'clientTs': clientTs,
            'trafficBytes': delta,
            'env': {
              'emulator': _envEmulator,
              'rooted': false,
              'multiOpen': false,
            },
            'sig': sig,
          },
        );
        if (data['accepted'] == false &&
            data['reason'] == 'seq_out_of_order') {
          _guestSeq = (data['serverSeq'] as num?)?.toInt() ?? _guestSeq;
          await prefs.setInt(_kGuestSeq, _guestSeq);
        }
        guestUsage = QfGuestUsage.fromJson(data);
        final was = guestExhausted;
        guestExhausted = guestUsage?.exhausted ?? false;
        notifyListeners();
        if (guestExhausted && !was) {
          await onGuestExhaustedFn?.call();
        }
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

  Future<Map<String, dynamic>> pointsRules() {
    return QfHttp.send('GET', '$serverBaseUrl/points/rules');
  }

  Future<Map<String, dynamic>> redeemProducts() {
    return authed('GET', '/redeem/products');
  }

  Future<Map<String, dynamic>> redeemCreate(int productId) {
    return authed('POST', '/redeem/orders', body: {
      'productId': productId,
      'idempotencyKey':
          'qf-${DateTime.now().millisecondsSinceEpoch}-$productId',
    });
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

  Future<void> submitFeedback({
    required String content,
    String? contact,
    required String appVersion,
  }) async {
    final identity = await QfDeviceIdentity.resolve();
    await QfHttp.send('POST', '$serverBaseUrl/feedback', body: {
      'content': content,
      if (contact != null && contact.isNotEmpty) 'contact': contact,
      'source': 'app',
      'platform': identity.platform,
      'appVersion': appVersion,
      'deviceHash': identity.deviceHash,
    }, bearer: _accessToken ?? _guestToken);
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
  }) {
    return authed('POST', '/forum/posts', body: {
      'board': board,
      'title': title,
      'content': content,
    });
  }

  Future<Map<String, dynamic>> forumCreateReply(int postId, String content) {
    return authed('POST', '/forum/posts/$postId/replies', body: {
      'content': content,
    });
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
}
