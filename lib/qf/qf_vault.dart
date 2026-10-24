import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/argon2.dart';
import 'package:pointycastle/macs/poly1305.dart';
import 'package:pointycastle/stream/chacha20poly1305.dart' hide State;
import 'package:pointycastle/stream/chacha7539.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../ui/ui.dart';
import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_pages.dart';
import 'qf_session.dart';

typedef QfSession = QfSessionController;

class QfVaultException implements Exception {
  final String message;

  const QfVaultException(this.message);

  @override
  String toString() => message;
}

const _kdfAlgo = 'argon2id';
const _aeadAlgo = 'xchacha20poly1305';
const _kdfParams = <String, dynamic>{'t': 3, 'm': 32768, 'p': 1};
const _decryptFailed = '账户密码不正确或备份数据已损坏，无法解密。';

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _argon2id(String password, Uint8List salt, Map<String, dynamic> p) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: (p['t'] as num?)?.toInt() ?? 3,
        memory: (p['m'] as num?)?.toInt() ?? 32768,
        lanes: (p['p'] as num?)?.toInt() ?? 1,
      ),
    );
  final out = Uint8List(32);
  generator.deriveKey(Uint8List.fromList(utf8.encode(password)), 0, out, 0);
  return out;
}

int _rotl32(int value, int shift) =>
    ((value << shift) | (value >> (32 - shift))) & 0xffffffff;

void _quarterRound(List<int> x, int a, int b, int c, int d) {
  x[a] = (x[a] + x[b]) & 0xffffffff;
  x[d] = _rotl32(x[d] ^ x[a], 16);
  x[c] = (x[c] + x[d]) & 0xffffffff;
  x[b] = _rotl32(x[b] ^ x[c], 12);
  x[a] = (x[a] + x[b]) & 0xffffffff;
  x[d] = _rotl32(x[d] ^ x[a], 8);
  x[c] = (x[c] + x[d]) & 0xffffffff;
  x[b] = _rotl32(x[b] ^ x[c], 7);
}

Uint8List qfHChaCha20(Uint8List key, Uint8List nonce) {
  final state = List<int>.filled(16, 0);
  state[0] = 0x61707865;
  state[1] = 0x3320646e;
  state[2] = 0x79622d32;
  state[3] = 0x6b206574;
  final keyData = ByteData.sublistView(key);
  for (var i = 0; i < 8; i++) {
    state[4 + i] = keyData.getUint32(i * 4, Endian.little);
  }
  final nonceData = ByteData.sublistView(nonce);
  for (var i = 0; i < 4; i++) {
    state[12 + i] = nonceData.getUint32(i * 4, Endian.little);
  }
  final x = List<int>.of(state);
  for (var round = 0; round < 10; round++) {
    _quarterRound(x, 0, 4, 8, 12);
    _quarterRound(x, 1, 5, 9, 13);
    _quarterRound(x, 2, 6, 10, 14);
    _quarterRound(x, 3, 7, 11, 15);
    _quarterRound(x, 0, 5, 10, 15);
    _quarterRound(x, 1, 6, 11, 12);
    _quarterRound(x, 2, 7, 8, 13);
    _quarterRound(x, 3, 4, 9, 14);
  }
  final out = ByteData(32);
  const indices = [0, 1, 2, 3, 12, 13, 14, 15];
  for (var i = 0; i < indices.length; i++) {
    out.setUint32(i * 4, x[indices[i]], Endian.little);
  }
  return out.buffer.asUint8List();
}

Uint8List _ietfChaChaPoly(
  bool encrypt,
  Uint8List key,
  Uint8List nonce,
  Uint8List data,
) {
  final cipher = ChaCha20Poly1305(
    ChaCha7539Engine(),
    Poly1305(),
  )..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  final out = Uint8List(cipher.getOutputSize(data.length));
  var length = cipher.processBytes(data, 0, data.length, out, 0);
  length += cipher.doFinal(out, length);
  return Uint8List.sublistView(out, 0, length);
}

Uint8List qfXChaCha20Poly1305Encrypt(
  Uint8List key,
  Uint8List nonce,
  Uint8List plain,
) {
  final subKey = qfHChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
  final ietfNonce = Uint8List(12)
    ..setRange(4, 12, Uint8List.sublistView(nonce, 16, 24));
  return _ietfChaChaPoly(true, subKey, ietfNonce, plain);
}

Uint8List qfXChaCha20Poly1305Decrypt(
  Uint8List key,
  Uint8List nonce,
  Uint8List sealed,
) {
  final subKey = qfHChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
  final ietfNonce = Uint8List(12)
    ..setRange(4, 12, Uint8List.sublistView(nonce, 16, 24));
  return _ietfChaChaPoly(false, subKey, ietfNonce, sealed);
}

Map<String, dynamic> _parseKdfParams(dynamic raw) {
  dynamic decoded = raw;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = null;
    }
  }
  if (decoded is Map) {
    return {
      't': (decoded['t'] as num?)?.toInt() ?? _kdfParams['t'],
      'm': (decoded['m'] as num?)?.toInt() ?? _kdfParams['m'],
      'p': (decoded['p'] as num?)?.toInt() ?? _kdfParams['p'],
    };
  }
  return Map<String, dynamic>.of(_kdfParams);
}

Map<String, dynamic> _wrapFieldsOf(Map<String, dynamic> source) {
  return {
    'wrappedKey': (source['wrappedKey'] ?? '').toString(),
    'kdfAlgo': _kdfAlgo,
    'kdfSalt': (source['kdfSalt'] ?? '').toString(),
    'kdfParams': _parseKdfParams(source['kdfParams']),
    'aeadAlgo': _aeadAlgo,
  };
}

Map<String, dynamic> _wrapKey(Uint8List vaultKey, String password) {
  final salt = _randomBytes(16);
  final kek = _argon2id(password, salt, _kdfParams);
  final nonce = _randomBytes(24);
  final wrapped = qfXChaCha20Poly1305Encrypt(kek, nonce, vaultKey);
  final packed = Uint8List(24 + wrapped.length)
    ..setRange(0, 24, nonce)
    ..setRange(24, 24 + wrapped.length, wrapped);
  return {
    'wrappedKey': base64Encode(packed),
    'kdfAlgo': _kdfAlgo,
    'kdfSalt': base64Encode(salt),
    'kdfParams': Map<String, dynamic>.of(_kdfParams),
    'aeadAlgo': _aeadAlgo,
  };
}

Uint8List _unwrapKey(Map<String, dynamic> fields, String password) {
  try {
    final salt = base64Decode((fields['kdfSalt'] ?? '').toString());
    final kek = _argon2id(
      password,
      Uint8List.fromList(salt),
      _parseKdfParams(fields['kdfParams']),
    );
    final packed = base64Decode((fields['wrappedKey'] ?? '').toString());
    final key = qfXChaCha20Poly1305Decrypt(
      kek,
      Uint8List.sublistView(packed, 0, 24),
      Uint8List.sublistView(packed, 24),
    );
    if (key.length != 32) {
      throw const QfVaultException(_decryptFailed);
    }
    return key;
  } on QfVaultException {
    rethrow;
  } catch (_) {
    throw const QfVaultException(_decryptFailed);
  }
}

({String ciphertext, String nonce}) _encryptContent(
  Uint8List key,
  Uint8List plain,
) {
  final nonce = _randomBytes(24);
  final sealed = qfXChaCha20Poly1305Encrypt(key, nonce, plain);
  return (ciphertext: base64Encode(sealed), nonce: base64Encode(nonce));
}

Uint8List _decryptContent(Uint8List key, String ciphertext, String nonce) {
  try {
    return qfXChaCha20Poly1305Decrypt(
      key,
      Uint8List.fromList(base64Decode(nonce)),
      Uint8List.fromList(base64Decode(ciphertext)),
    );
  } catch (_) {
    throw const QfVaultException(_decryptFailed);
  }
}

enum QfSettingsSyncDecision { cloudNewer, localNewer, inSync, noCloud }

class QfSettingsPullResult {
  final QfSettingsSyncDecision decision;
  final Map<String, dynamic>? settings;
  final int cloudUpdatedAt;

  const QfSettingsPullResult({
    required this.decision,
    this.settings,
    this.cloudUpdatedAt = 0,
  });
}

class QfSettingsSync {
  static const int structureVersion = 1;
  static const Duration debounceWindow = Duration(seconds: 30);
  static const int maxUploadRetries = 3;

  static const List<String> portableSections = [
    'appSettingProps',
    'themeProps',
    'proxiesStyleProps',
    'networkProps',
    'vpnProps',
    'patchClashConfig',
  ];

  static const Map<String, List<String>> portableFields = {
    'appSettingProps': [
      'locale',
      'dashboardWidgets',
      'onlyStatisticsProxy',
      'autoSelectFastest',
      'showNotificationStopAction',
      'autoLaunch',
      'silentLaunch',
      'autoRun',
      'openLogs',
      'closeConnections',
      'testUrl',
      'tabAnimation',
      'floatingNavigationBar',
      'autoCheckUpdate',
      'sidebarExpanded',
      'acceptedDisclaimerVersion',
      'minimizeOnExit',
      'hidden',
      'developerMode',
      'restoreStrategy',
      'showTrayTitle',
      'checkCertificate',
      'userAgents',
      'filters',
      'hideIp',
      'editorLineWrap',
      'editorFontSize',
    ],
    'themeProps': [
      'primaryColor',
      'primaryColors',
      'themeMode',
      'colorStyle',
      'pureBlack',
      'sidebarBlur',
      'liquidGlass',
      'textScale',
      'systemFontFamily',
    ],
    'proxiesStyleProps': [
      'type',
      'sortType',
      'layout',
      'iconStyle',
      'cardType',
      'hideTimeoutProxies',
    ],
    'networkProps': [
      'systemProxy',
      'bypassDomain',
      'bypassPrivateRoute',
      'autoSetSystemDns',
      'appendSystemDns',
      'authentication',
    ],
    'vpnProps': [
      'enable',
      'systemProxy',
      'ipv6',
      'allowBypass',
      'dnsHijacking',
      'accessControlProps',
    ],
    'patchClashConfig': [
      'mode',
      'allow-lan',
      'log-level',
      'ipv6',
      'unified-delay',
      'tcp-concurrent',
      'keep-alive-interval',
      'keep-alive-idle',
      'disable-keep-alive',
      'geodata-loader',
      'global-ua',
      'hosts',
      'geo-auto-update',
      'geo-update-interval',
      'dns',
      'dns-override-keys',
    ],
  };

  static const List<String> _authenticationFields = ['enable', 'username'];

  static const List<String> _accessControlFields = [
    'enable',
    'mode',
    'sort',
    'isFilterSystemApp',
    'isFilterNonInternetApp',
  ];

  static Map<String, dynamic> _pick(
    String section,
    Map<String, dynamic> source,
  ) {
    final picked = <String, dynamic>{};
    for (final field in portableFields[section] ?? const <String>[]) {
      if (!source.containsKey(field)) continue;
      final value = source[field];
      if (section == 'networkProps' && field == 'authentication') {
        if (value is Map) {
          final auth = Map<String, dynamic>.from(value);
          picked[field] = {
            for (final sub in _authenticationFields)
              if (auth.containsKey(sub)) sub: auth[sub],
          };
        }
        continue;
      }
      if (section == 'vpnProps' && field == 'accessControlProps') {
        if (value is Map) {
          final control = Map<String, dynamic>.from(value);
          picked[field] = {
            for (final sub in _accessControlFields)
              if (control.containsKey(sub)) sub: control[sub],
          };
        }
        continue;
      }
      picked[field] = value;
    }
    return picked;
  }

  static Map<String, dynamic> projectSettings(Map<String, dynamic> configJson) {
    return {
      for (final section in portableSections)
        if (configJson[section] is Map)
          section: _pick(
            section,
            Map<String, dynamic>.from(configJson[section] as Map),
          ),
    };
  }

  static Map<String, dynamic> filterImportedSettings(
    Map<String, dynamic> settings,
  ) {
    return projectSettings(settings);
  }

  static Map<String, dynamic> mergeIntoConfig(
    Map<String, dynamic> currentConfigJson,
    Map<String, dynamic> importedSettings,
  ) {
    final filtered = filterImportedSettings(importedSettings);
    final merged = Map<String, dynamic>.of(currentConfigJson);
    for (final section in portableSections) {
      final incoming = filtered[section];
      if (incoming is! Map) continue;
      final current = currentConfigJson[section];
      final base = current is Map
          ? Map<String, dynamic>.from(current)
          : <String, dynamic>{};
      merged[section] = _pick(section, {
        ...base,
        ...Map<String, dynamic>.from(incoming),
      });
    }
    return merged;
  }

  static QfSettingsSyncDecision decide({
    required int cloudUpdatedAt,
    required int localUpdatedAt,
    bool localDirty = false,
  }) {
    if (cloudUpdatedAt > localUpdatedAt) {
      return QfSettingsSyncDecision.cloudNewer;
    }
    if (localUpdatedAt > cloudUpdatedAt) {
      return QfSettingsSyncDecision.localNewer;
    }
    // The same second on both sides proves nothing about content: if
    // the local side carries changes that were never uploaded, they
    // must still go up instead of being silently judged in sync (C-29).
    return localDirty
        ? QfSettingsSyncDecision.localNewer
        : QfSettingsSyncDecision.inSync;
  }
}

class QfVaultService {
  static const String _kLocalSettingsUpdatedAt = 'qf_settings_local_updated_at';
  static const String _kCloudSettingsUpdatedAt = 'qf_settings_cloud_updated_at';
  static const String _kSettingsClockOffset = 'qf_settings_clock_offset';
  static const String _kSettingsDirty = 'qf_settings_dirty';

  /// Local settings stamps are anchored to server time (C-29): every
  /// successful upload teaches us the offset between this device's
  /// wall clock and the server's clock, and local change stamps are
  /// written in server time. A device whose clock runs minutes fast
  /// or slow can then neither dominate every sync decision nor be
  /// permanently silenced by one.
  static Future<int> _anchoredNowSecs() async {
    final prefs = await SharedPreferences.getInstance();
    return _nowSecs() + (prefs.getInt(_kSettingsClockOffset) ?? 0);
  }

  static Future<bool> _settingsDirty() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kSettingsDirty) ?? false;
  }

  static Future<void> _setSettingsDirty(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSettingsDirty, value);
  }

  static Uint8List? _subscriptionKey;
  static Uint8List? _settingsKey;
  static Map<String, dynamic>? _settingsWrapFields;

  static bool get subscriptionUnlocked => _subscriptionKey != null;

  static bool get settingsUnlocked => _settingsKey != null;

  static void clearUnlockedKeys() {
    _subscriptionKey = null;
    _settingsKey = null;
    _settingsWrapFields = null;
  }

  static Future<Map<String, dynamic>?> _getSubVault(QfSession session) async {
    try {
      return await session.authed('GET', '/me/subvault');
    } on QfApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  static Future<int?> subscriptionBackupUpdatedAt({
    required QfSession session,
  }) async {
    final data = await _getSubVault(session);
    return (data?['updatedAt'] as num?)?.toInt();
  }

  static Future<int?> backupSubscriptions({
    required QfSession session,
    required String password,
    required Map<String, dynamic> payload,
  }) async {
    final existing = await _getSubVault(session);
    final Uint8List key;
    final Map<String, dynamic> wrapFields;
    if (existing != null) {
      key = _unwrapKey(existing, password);
      wrapFields = _wrapFieldsOf(existing);
    } else {
      key = _randomBytes(32);
      wrapFields = _wrapKey(key, password);
    }
    final sealed = _encryptContent(
      key,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    final result = await session.authed(
      'PUT',
      '/me/subvault',
      body: {
        ...wrapFields,
        'ciphertext': sealed.ciphertext,
        'nonce': sealed.nonce,
      },
    );
    _subscriptionKey = key;
    return (result['updatedAt'] as num?)?.toInt();
  }

  static Future<Map<String, dynamic>?> restoreSubscriptions({
    required QfSession session,
    required String password,
  }) async {
    final data = await _getSubVault(session);
    if (data == null) return null;
    final key = _unwrapKey(data, password);
    final plain = _decryptContent(
      key,
      (data['ciphertext'] ?? '').toString(),
      (data['nonce'] ?? '').toString(),
    );
    _subscriptionKey = key;
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) {
      throw const QfVaultException(_decryptFailed);
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Future<bool> deleteSubscriptionBackup({
    required QfSession session,
  }) async {
    final result = await session.authed('DELETE', '/me/subvault');
    return result['deleted'] == true;
  }

  static Future<int> localSettingsUpdatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLocalSettingsUpdatedAt) ?? 0;
  }

  static Future<int> cloudSettingsUpdatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kCloudSettingsUpdatedAt) ?? 0;
  }

  static Future<void> deleteSettingsBackup({required QfSession session}) async {
    await session.deleteSettingsVault();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCloudSettingsUpdatedAt);
    await prefs.remove(_kSettingsDirty);
  }

  static Future<void> noteLocalSettingsChanged() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLocalSettingsUpdatedAt,
      await _anchoredNowSecs(),
    );
    await prefs.setBool(_kSettingsDirty, true);
  }

  static Future<void> _saveSettingsTimestamps({
    int? localUpdatedAt,
    int? cloudUpdatedAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (localUpdatedAt != null) {
      await prefs.setInt(_kLocalSettingsUpdatedAt, localUpdatedAt);
    }
    if (cloudUpdatedAt != null) {
      await prefs.setInt(_kCloudSettingsUpdatedAt, cloudUpdatedAt);
    }
  }

  static Map<String, dynamic> _decodeSettingsEnvelope(String ciphertext) {
    try {
      final decoded = jsonDecode(ciphertext);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw const QfVaultException(_decryptFailed);
  }

  static Future<Map<String, dynamic>?> _getSettingsVault(
    QfSession session,
  ) async {
    try {
      return await session.authed('GET', '/me/settingsvault');
    } on QfApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  static Future<void> unlockSettingsVault({
    required QfSession session,
    required String password,
  }) async {
    final data = await _getSettingsVault(session);
    if (data == null) {
      _settingsKey = _randomBytes(32);
      _settingsWrapFields = _wrapKey(_settingsKey!, password);
      return;
    }
    final envelope = _decodeSettingsEnvelope(
      (data['ciphertext'] ?? '').toString(),
    );
    _settingsKey = _unwrapKey(envelope, password);
    _settingsWrapFields = _wrapFieldsOf(envelope);
  }

  static Future<int?> uploadSettingsBackup({
    required QfSession session,
    required Map<String, dynamic> settings,
  }) async {
    final key = _settingsKey;
    final wrapFields = _settingsWrapFields;
    if (key == null || wrapFields == null) return null;
    var writtenAt = await localSettingsUpdatedAt();
    if (writtenAt == 0) {
      writtenAt = _nowSecs();
      await _saveSettingsTimestamps(localUpdatedAt: writtenAt);
    }
    final payload = {
      'version': QfSettingsSync.structureVersion,
      'writtenAt': writtenAt,
      'settings': settings,
    };
    final sealed = _encryptContent(
      key,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    final envelope = {
      ...wrapFields,
      'nonce': sealed.nonce,
      'ciphertext': sealed.ciphertext,
    };
    final result = await session.authed(
      'PUT',
      '/me/settingsvault',
      body: {'ciphertext': jsonEncode(envelope)},
    );
    final cloudUpdatedAt = (result['updatedAt'] as num?)?.toInt();
    if (cloudUpdatedAt != null) {
      // Learn this device's clock offset from the write just made and
      // re-anchor the local stamp to the server's, so later sync
      // comparisons are same-clock comparisons (C-29).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSettingsClockOffset, cloudUpdatedAt - writtenAt);
      await _saveSettingsTimestamps(
        localUpdatedAt: cloudUpdatedAt,
        cloudUpdatedAt: cloudUpdatedAt,
      );
    }
    await _setSettingsDirty(false);
    return cloudUpdatedAt;
  }

  static Future<QfSettingsPullResult> pullSettings({
    required QfSession session,
    required String password,
  }) async {
    final data = await _getSettingsVault(session);
    if (data == null) {
      if (_settingsKey == null) {
        _settingsKey = _randomBytes(32);
        _settingsWrapFields = _wrapKey(_settingsKey!, password);
      }
      final localUpdatedAt = await localSettingsUpdatedAt();
      return QfSettingsPullResult(
        decision: localUpdatedAt > 0
            ? QfSettingsSyncDecision.localNewer
            : QfSettingsSyncDecision.noCloud,
      );
    }
    final envelope = _decodeSettingsEnvelope(
      (data['ciphertext'] ?? '').toString(),
    );
    final key = _unwrapKey(envelope, password);
    _settingsKey = key;
    _settingsWrapFields = _wrapFieldsOf(envelope);
    final cloudUpdatedAt = (data['updatedAt'] as num?)?.toInt() ?? 0;
    final decision = QfSettingsSync.decide(
      cloudUpdatedAt: cloudUpdatedAt,
      localUpdatedAt: await localSettingsUpdatedAt(),
      localDirty: await _settingsDirty(),
    );
    if (decision != QfSettingsSyncDecision.cloudNewer) {
      return QfSettingsPullResult(
        decision: decision,
        cloudUpdatedAt: cloudUpdatedAt,
      );
    }
    final plain = _decryptContent(
      key,
      (envelope['ciphertext'] ?? '').toString(),
      (envelope['nonce'] ?? '').toString(),
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map || decoded['settings'] is! Map) {
      throw const QfVaultException(_decryptFailed);
    }
    await _saveSettingsTimestamps(
      localUpdatedAt: cloudUpdatedAt,
      cloudUpdatedAt: cloudUpdatedAt,
    );
    await _setSettingsDirty(false);
    return QfSettingsPullResult(
      decision: decision,
      settings: Map<String, dynamic>.from(decoded['settings'] as Map),
      cloudUpdatedAt: cloudUpdatedAt,
    );
  }

  static Future<bool> rewrapAll({
    required QfSession session,
    required String oldPassword,
    required String newPassword,
  }) async {
    var ok = true;
    try {
      final data = await _getSubVault(session);
      if (data != null) {
        final key = _unwrapKey(data, oldPassword);
        await session.authed(
          'PUT',
          '/me/subvault',
          body: {
            ..._wrapKey(key, newPassword),
            'ciphertext': (data['ciphertext'] ?? '').toString(),
            'nonce': (data['nonce'] ?? '').toString(),
          },
        );
        _subscriptionKey = key;
      }
    } catch (_) {
      ok = false;
    }
    try {
      final data = await _getSettingsVault(session);
      if (data != null) {
        final envelope = _decodeSettingsEnvelope(
          (data['ciphertext'] ?? '').toString(),
        );
        final key = _unwrapKey(envelope, oldPassword);
        final rewrapped = {
          ..._wrapKey(key, newPassword),
          'nonce': (envelope['nonce'] ?? '').toString(),
          'ciphertext': (envelope['ciphertext'] ?? '').toString(),
        };
        await session.authed(
          'PUT',
          '/me/settingsvault',
          body: {'ciphertext': jsonEncode(rewrapped)},
        );
        _settingsKey = key;
        _settingsWrapFields = _wrapFieldsOf(rewrapped);
      }
    } catch (_) {
      ok = false;
    }
    return ok;
  }
}

String _formatVaultTime(int secs) {
  final time = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

class QfVaultNotice extends StatelessWidget {
  const QfVaultNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyle.caption1.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('服务器仅存储加密后的密文，维护者无法解密您的备份。', style: style),
        const SizedBox(height: 4),
        Text('忘记账户密码后，备份将无法恢复，请妥善保管账户密码。', style: style),
        const SizedBox(height: 4),
        Text('备份由您的账户密码加密，通行密钥无法解密备份，请输入账户密码。', style: style),
      ],
    );
  }
}

class QfVaultEntry extends ConsumerStatefulWidget {
  final QfSessionController session;

  const QfVaultEntry({super.key, required this.session});

  @override
  ConsumerState<QfVaultEntry> createState() => _QfVaultEntryState();
}

class _QfVaultEntryState extends ConsumerState<QfVaultEntry> {
  ProviderSubscription<Config>? _configSubscription;
  Timer? _debounceTimer;
  Timer? _retryTimer;
  String _lastProjection = '';
  int _uploadAttempts = 0;
  bool _uploading = false;
  bool _applyingCloud = false;

  @override
  void initState() {
    super.initState();
    _lastProjection = jsonEncode(_projectedSettings());
    _configSubscription = ref.listenManual(configProvider, (_, _) {
      _onConfigChanged();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _configSubscription?.close();
    super.dispose();
  }

  Map<String, dynamic> _configJson() {
    return Map<String, dynamic>.from(ref.read(configProvider).toJson());
  }

  Map<String, dynamic> _projectedSettings() {
    return QfSettingsSync.projectSettings(_configJson());
  }

  void _applyMergedConfig(Config config) {
    ref.read(appSettingProvider.notifier).value = config.appSettingProps;
    ref.read(themeSettingProvider.notifier).value = config.themeProps;
    ref.read(proxiesStyleSettingProvider.notifier).value =
        config.proxiesStyleProps;
    ref.read(networkSettingProvider.notifier).value = config.networkProps;
    ref.read(vpnSettingProvider.notifier).value = config.vpnProps;
    ref.read(patchClashConfigProvider.notifier).value = config.patchClashConfig
        .ensureControllerSecret();
  }

  void _onConfigChanged() {
    final projected = _projectedSettings();
    final encoded = jsonEncode(projected);
    if (_applyingCloud) {
      _lastProjection = encoded;
      return;
    }
    if (encoded == _lastProjection) return;
    _lastProjection = encoded;
    unawaited(QfVaultService.noteLocalSettingsChanged());
    _uploadAttempts = 0;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(QfSettingsSync.debounceWindow, _attemptUpload);
  }

  Future<void> _attemptUpload() async {
    if (!mounted || _uploading) return;
    if (!widget.session.isLoggedIn || !QfVaultService.settingsUnlocked) {
      return;
    }
    _uploading = true;
    try {
      await QfVaultService.uploadSettingsBackup(
        session: widget.session,
        settings: _projectedSettings(),
      );
      _uploadAttempts = 0;
    } catch (_) {
      _uploadAttempts += 1;
      if (_uploadAttempts <= QfSettingsSync.maxUploadRetries) {
        _retryTimer?.cancel();
        _retryTimer = Timer(
          Duration(seconds: 15 * _uploadAttempts),
          _attemptUpload,
        );
      }
    } finally {
      _uploading = false;
    }
  }

  Future<void> _afterUnlock(String password) async {
    try {
      final result = await QfVaultService.pullSettings(
        session: widget.session,
        password: password,
      );
      if (!mounted) return;
      switch (result.decision) {
        case QfSettingsSyncDecision.cloudNewer:
          final settings = result.settings;
          if (settings == null) return;
          _applyingCloud = true;
          try {
            final merged = QfSettingsSync.mergeIntoConfig(
              _configJson(),
              settings,
            );
            _applyMergedConfig(
              Config.fromJson(Map<String, Object?>.from(merged)),
            );
            _lastProjection = jsonEncode(
              QfSettingsSync.projectSettings(merged),
            );
          } finally {
            _applyingCloud = false;
          }
          if (mounted) qfToast(context, '已应用云端设置。');
        case QfSettingsSyncDecision.localNewer:
          await QfVaultService.uploadSettingsBackup(
            session: widget.session,
            settings: _projectedSettings(),
          );
        case QfSettingsSyncDecision.inSync:
        case QfSettingsSyncDecision.noCloud:
          break;
      }
    } catch (_) {}
  }

  Future<void> _showLoginGuide() async {
    final goLogin = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('需要登录'),
          content: const Text('备份订阅与设置同步为登录用户功能。访客模式下无法使用，请先登录 QFClash 账号。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('我知道了'),
            ),
            if (widget.session.isGuest)
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('去登录'),
              ),
          ],
        );
      },
    );
    if (goLogin == true) {
      await widget.session.exitGuestToEntry();
    }
  }

  Future<void> _openBackup() async {
    if (!widget.session.isLoggedIn) {
      await _showLoginGuide();
      return;
    }
    final profiles = ref
        .read(profilesProvider)
        .where((profile) => profile.url.isNotEmpty)
        .toList();
    final payload = <String, dynamic>{
      'version': 1,
      'kind': 'subscriptions',
      'exportedAt': _nowSecs(),
      'profiles': [for (final profile in profiles) profile.toJson()],
    };
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _QfBackupDialog(
        session: widget.session,
        payload: payload,
        profileCount: profiles.length,
      ),
    );
    if (password != null && password.isNotEmpty && mounted) {
      await _afterUnlock(password);
    }
  }

  Future<void> _openRestore() async {
    if (!widget.session.isLoggedIn) {
      await _showLoginGuide();
      return;
    }
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _QfRestoreDialog(session: widget.session),
    );
    if (password != null && password.isNotEmpty && mounted) {
      await _afterUnlock(password);
    }
  }

  Future<void> _openVaultPanel() async {
    if (!widget.session.isLoggedIn) {
      await _showLoginGuide();
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _QfVaultSyncPanel(session: widget.session, onUnlock: _afterUnlock),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: _openBackup, child: const Text('备份订阅')),
        TextButton(onPressed: _openRestore, child: const Text('恢复订阅')),
        TextButton(
          onPressed: _openVaultPanel,
          child: const Text(QfCopy.vaultUnlockTitle),
        ),
      ],
    );
  }
}

class _QfVaultSyncPanel extends StatefulWidget {
  final QfSessionController session;
  final Future<void> Function(String password) onUnlock;

  const _QfVaultSyncPanel({required this.session, required this.onUnlock});

  @override
  State<_QfVaultSyncPanel> createState() => _QfVaultSyncPanelState();
}

class _QfVaultSyncPanelState extends State<_QfVaultSyncPanel> {
  final _password = TextEditingController();
  bool _unlocked = QfVaultService.settingsUnlocked;
  int _cloudUpdatedAt = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final cloud = await QfVaultService.cloudSettingsUpdatedAt();
    if (mounted) {
      setState(() {
        _unlocked = QfVaultService.settingsUnlocked;
        _cloudUpdatedAt = cloud;
      });
    }
  }

  Future<void> _unlock() async {
    if (_password.text.isEmpty) {
      qfToast(context, '请输入账户密码');
      return;
    }
    setState(() => _busy = true);
    try {
      await QfVaultService.unlockSettingsVault(
        session: widget.session,
        password: _password.text,
      );
      await widget.onUnlock(_password.text);
      if (mounted) qfToast(context, QfCopy.vaultUnlockedState);
      await _refresh();
    } on QfVaultException catch (e) {
      if (mounted) qfToast(context, e.message);
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCloud() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(QfCopy.vaultClearSettings),
          content: const Text(QfCopy.vaultClearSettingsConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await QfVaultService.deleteSettingsBackup(session: widget.session);
      if (mounted) qfToast(context, QfCopy.vaultSettingsCleared);
      await _refresh();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(QfCopy.vaultUnlockTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _unlocked ? QfCopy.vaultUnlockedState : QfCopy.vaultLockedState,
            ),
            const SizedBox(height: 4),
            Text(
              _cloudUpdatedAt > 0
                  ? '最近同步时间：${_formatVaultTime(_cloudUpdatedAt)}'
                  : '最近同步时间：暂无云端备份',
            ),
            if (!_unlocked) ...[
              const SizedBox(height: 12),
              QfField(controller: _password, label: '账户密码', obscure: true),
              const SizedBox(height: 12),
              const QfVaultNotice(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _clearCloud,
          child: const Text(QfCopy.vaultClearSettings),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (!_unlocked)
          FilledButton(
            onPressed: _busy ? null : _unlock,
            child: const Text(QfCopy.vaultUnlockTitle),
          ),
      ],
    );
  }
}

class _QfBackupDialog extends StatefulWidget {
  final QfSessionController session;
  final Map<String, dynamic> payload;
  final int profileCount;

  const _QfBackupDialog({
    required this.session,
    required this.payload,
    required this.profileCount,
  });

  @override
  State<_QfBackupDialog> createState() => _QfBackupDialogState();
}

class _QfBackupDialogState extends State<_QfBackupDialog> {
  final _password = TextEditingController();
  int? _existingUpdatedAt;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadMeta() async {
    try {
      final updatedAt = await QfVaultService.subscriptionBackupUpdatedAt(
        session: widget.session,
      );
      if (mounted) setState(() => _existingUpdatedAt = updatedAt);
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty) {
      qfToast(context, '请输入账户密码');
      return;
    }
    setState(() => _busy = true);
    try {
      await QfVaultService.backupSubscriptions(
        session: widget.session,
        password: _password.text,
        payload: widget.payload,
      );
      if (!mounted) return;
      Navigator.of(context).pop(_password.text);
      qfToast(context, '订阅备份已保存至云端保险库。');
    } on QfVaultException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, e.message);
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, e.message);
      }
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await QfVaultService.deleteSubscriptionBackup(session: widget.session);
      if (!mounted) return;
      Navigator.of(context).pop();
      qfToast(context, '云端备份已删除。');
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('备份订阅'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将把当前设备上的 ${widget.profileCount} 个订阅配置加密后保存至云端保险库。'
              '仅备份订阅链接类配置，本地文件与自定义配置不在备份范围内。',
            ),
            if (_existingUpdatedAt != null) ...[
              const SizedBox(height: 8),
              Text(
                '云端已有一份备份（更新时间：${_formatVaultTime(_existingUpdatedAt!)}），保存后将覆盖原备份。',
              ),
            ],
            const SizedBox(height: 12),
            QfField(controller: _password, label: '账户密码', obscure: true),
            const SizedBox(height: 12),
            const QfVaultNotice(),
          ],
        ),
      ),
      actions: [
        if (_existingUpdatedAt != null)
          TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('删除云端备份'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('备份订阅'),
        ),
      ],
    );
  }
}

class _QfRestoreDialog extends ConsumerStatefulWidget {
  final QfSessionController session;

  const _QfRestoreDialog({required this.session});

  @override
  ConsumerState<_QfRestoreDialog> createState() => _QfRestoreDialogState();
}

class _QfRestoreDialogState extends ConsumerState<_QfRestoreDialog> {
  final _password = TextEditingController();
  int? _existingUpdatedAt;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadMeta() async {
    try {
      final updatedAt = await QfVaultService.subscriptionBackupUpdatedAt(
        session: widget.session,
      );
      if (mounted) {
        setState(() {
          _existingUpdatedAt = updatedAt;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty) {
      qfToast(context, '请输入账户密码');
      return;
    }
    setState(() => _busy = true);
    try {
      final payload = await QfVaultService.restoreSubscriptions(
        session: widget.session,
        password: _password.text,
      );
      if (!mounted) return;
      if (payload == null) {
        setState(() => _busy = false);
        qfToast(context, '尚未备份。');
        return;
      }
      final existingUrls = ref
          .read(profilesProvider)
          .map((profile) => profile.url)
          .toSet();
      var added = 0;
      var skipped = 0;
      final restored = payload['profiles'];
      if (restored is List) {
        for (final raw in restored) {
          if (raw is! Map) {
            skipped += 1;
            continue;
          }
          try {
            final profile = Profile.fromJson(Map<String, Object?>.from(raw));
            if (profile.url.isEmpty || existingUrls.contains(profile.url)) {
              skipped += 1;
              continue;
            }
            ref.read(profilesProvider.notifier).put(profile);
            existingUrls.add(profile.url);
            added += 1;
          } catch (_) {
            skipped += 1;
          }
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(_password.text);
      qfToast(context, '恢复完成：新增 $added 个订阅配置，$skipped 个已存在或无法识别并跳过。');
    } on QfVaultException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, e.message);
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasBackup = _existingUpdatedAt != null;
    return AlertDialog(
      title: const Text('恢复订阅'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_loaded)
              const Text('正在查询云端备份。')
            else if (!hasBackup)
              const Text('尚未备份。')
            else ...[
              Text(
                '云端备份更新时间：${_formatVaultTime(_existingUpdatedAt!)}。恢复后将新增本机不存在的订阅配置，已存在的订阅不会重复添加。',
              ),
              const SizedBox(height: 12),
              QfField(controller: _password, label: '账户密码', obscure: true),
              const SizedBox(height: 12),
              const QfVaultNotice(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (hasBackup)
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('恢复订阅'),
          ),
      ],
    );
  }
}
