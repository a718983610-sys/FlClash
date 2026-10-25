import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/key_derivators/argon2.dart';
import 'package:pointycastle/macs/poly1305.dart';
import 'package:pointycastle/stream/chacha20poly1305.dart' hide State;
import 'package:pointycastle/stream/chacha7539.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_api.dart';
import 'qf_session.dart';
import 'qf_social.dart';

class QfSignalStore extends SignalProtocolStore {
  static const String _prefsKey = 'qf_signal_store_v1';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  // 500ms was far too tight: one slow read on a busy keystore (cold
  // start, low-end device) used to condemn the secure store for the
  // whole process and flip the chat identity (C-42). Five seconds and
  // one retry, and a failure is only latched for a minute.
  static const Duration _secureTimeout = Duration(seconds: 5);
  static bool? _secureOk;
  static DateTime? _secureFailedAt;
  static bool lastSecureReadFailed = false;
  static bool _pluginMissing = false;

  static bool get _secureRetryDue {
    final at = _secureFailedAt;
    return at == null ||
        DateTime.now().difference(at) > const Duration(seconds: 60);
  }

  static Future<String?> _secureRead() async {
    if (_pluginMissing) return null;
    if (_secureOk == false && !_secureRetryDue) {
      lastSecureReadFailed = true;
      return null;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final value = await _secure
            .read(key: _prefsKey)
            .timeout(_secureTimeout);
        _secureOk = true;
        lastSecureReadFailed = false;
        return value;
      } on MissingPluginException {
        // No secure-storage plugin on this platform at all: the
        // preferences fallback is the only store, by design - this is
        // not the transient failure the identity guard protects
        // against (C-42).
        _pluginMissing = true;
        _secureOk = false;
        lastSecureReadFailed = false;
        return null;
      } catch (_) {
        // One retry before the store is judged unreachable.
      }
    }
    _secureOk = false;
    _secureFailedAt = DateTime.now();
    lastSecureReadFailed = true;
    return null;
  }

  static Future<bool> _secureWrite(String value) async {
    if (_pluginMissing) return false;
    if (_secureOk == false && !_secureRetryDue) return false;
    try {
      await _secure
          .write(key: _prefsKey, value: value)
          .timeout(_secureTimeout);
      _secureOk = true;
      return true;
    } on MissingPluginException {
      _pluginMissing = true;
      _secureOk = false;
      return false;
    } catch (_) {
      _secureOk = false;
      _secureFailedAt = DateTime.now();
      return false;
    }
  }

  static int _blobSavedAt(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return (decoded['savedAt'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    return 0;
  }

  /// When both stores hold a copy of the identity blob, the newer one
  /// wins (C-42): a persist() that fell back to preferences while the
  /// secure store was briefly unavailable must not be shadowed by the
  /// stale secure copy on the next launch.
  static String newerBlob(String secureRaw, String legacyRaw) {
    return _blobSavedAt(legacyRaw) > _blobSavedAt(secureRaw)
        ? legacyRaw
        : secureRaw;
  }

  IdentityKeyPair _identityPair;
  int _registrationId;
  final Map<String, String> _entries;
  bool bundlePublished;

  QfSignalStore._(this._identityPair, this._registrationId, this._entries)
    : bundlePublished = false;

  static QfSignalStore? _cached;

  static Future<QfSignalStore> load() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    final raw = await _secureRead();
    final legacy = prefs.getString(_prefsKey);
    String? resolved = raw;
    if (raw != null && legacy != null && legacy.isNotEmpty) {
      resolved = newerBlob(raw, legacy);
      if (resolved == legacy) {
        if (await _secureWrite(legacy)) {
          await prefs.remove(_prefsKey);
        }
      } else {
        await prefs.remove(_prefsKey);
      }
    } else if (resolved == null) {
      // Migrate the legacy plaintext copy (identity private key included)
      // into secure storage; the plaintext is dropped only once the secure
      // copy actually landed, so a broken secure store cannot lose it.
      if (legacy != null && legacy.isNotEmpty) {
        resolved = legacy;
        if (await _secureWrite(legacy)) {
          await prefs.remove(_prefsKey);
        }
      }
    } else {
      await prefs.remove(_prefsKey);
    }
    if ((resolved == null || resolved.isEmpty) && lastSecureReadFailed) {
      // The secure store could not be read at all and there is no
      // legacy copy: the identity may well exist in secure storage and
      // merely be unreachable right now. Minting a fresh identity here
      // is what flipped users' chat identity between launches (C-42) -
      // fail loudly so the caller can ask for a retry instead.
      throw StateError('安全存储暂时不可用，请稍后重试。');
    }
    if (resolved != null && resolved.isNotEmpty) {
      final data = Map<String, dynamic>.from(jsonDecode(resolved) as Map);
      final store = QfSignalStore._(
        IdentityKeyPair.fromSerialized(
          base64Decode((data['identity'] ?? '').toString()),
        ),
        (data['registrationId'] as num?)?.toInt() ?? 0,
        Map<String, String>.from(
          (data['entries'] as Map?)?.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              ) ??
              const {},
        ),
      );
      store.bundlePublished = data['bundlePublished'] == true;
      _cached = store;
      return store;
    }
    final store = QfSignalStore._(
      generateIdentityKeyPair(),
      generateRegistrationId(false),
      <String, String>{},
    );
    await store.persist();
    _cached = store;
    return store;
  }

  /// Whether an identity blob exists locally, without loading or
  /// minting one; for surfaces that only report key presence (C-35).
  static Future<bool> hasLocalIdentity() async {
    if (_cached != null) return true;
    try {
      final raw = await _secureRead();
      if (raw != null && raw.isNotEmpty) return true;
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_prefsKey);
      return legacy != null && legacy.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static void resetCache() {
    _cached = null;
  }

  static Future<void> replaceFromJson(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final stamped = {
      ...data,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (await _secureWrite(jsonEncode(stamped))) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, jsonEncode(stamped));
    }
    resetCache();
  }

  Map<String, dynamic> toJson() {
    return {
      'identity': base64Encode(_identityPair.serialize()),
      'registrationId': _registrationId,
      'bundlePublished': bundlePublished,
      'entries': _entries,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (await _secureWrite(jsonEncode(toJson()))) {
      await prefs.remove(_prefsKey);
    } else {
      // Secure storage unavailable: keep the blob in preferences rather
      // than losing the identity; load() migrates it on a later launch.
      await prefs.setString(_prefsKey, jsonEncode(toJson()));
    }
  }

  String get identityPublicB64 =>
      base64Encode(_identityPair.getPublicKey().serialize());

  /// 服务端公钥包要求 32 字节原始公钥（不带 libsignal 序列化首字节的类型标记）。
  String get identityRawB64 => base64Encode(_rawPublicBytes(identityKey));

  static Uint8List _rawPublicBytes(IdentityKey key) =>
      rawPublicBytes(key.publicKey);

  static Uint8List rawPublicBytes(ECPublicKey key) {
    final serialized = key.serialize();
    return serialized.length == 33
        ? Uint8List.fromList(serialized.sublist(1))
        : serialized;
  }

  static Uint8List typedPublicBytes(Uint8List raw) {
    if (raw.length == 33) return raw;
    return Uint8List.fromList([Curve.djbType, ...raw]);
  }

  int get nextPreKeyId {
    var next = int.tryParse(_entries['meta:nextPreKeyId'] ?? '') ?? 0;
    for (final key in _entries.keys) {
      if (key.startsWith('pre:')) {
        final id = int.tryParse(key.substring(4));
        if (id != null && id + 1 > next) next = id + 1;
      }
    }
    return next;
  }

  Future<void> syncPreKeyCounter() async {
    _entries['meta:nextPreKeyId'] = '$nextPreKeyId';
    await persist();
  }

  IdentityKey get identityKey => _identityPair.getPublicKey();

  int get registrationId => _registrationId;

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identityPair;

  @override
  Future<int> getLocalRegistrationId() async => _registrationId;

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) {
      _entries.remove('identity:${address.getName()}:${address.getDeviceId()}');
    } else {
      _entries['identity:${address.getName()}:${address.getDeviceId()}'] =
          base64Encode(identityKey.serialize());
    }
    await persist();
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    final existing = await getIdentity(address);
    if (existing == null || identityKey == null) return true;
    return existing == identityKey;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final saved =
        _entries['identity:${address.getName()}:${address.getDeviceId()}'];
    if (saved == null) return null;
    return IdentityKey.fromBytes(base64Decode(saved), 0);
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final saved = _entries['pre:$preKeyId'];
    if (saved == null) {
      throw InvalidKeyIdException('PreKey $preKeyId not found');
    }
    return PreKeyRecord.fromBuffer(base64Decode(saved));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    _entries['pre:$preKeyId'] = base64Encode(record.serialize());
    await persist();
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    return _entries.containsKey('pre:$preKeyId');
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    _entries.remove('pre:$preKeyId');
    await persist();
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final saved = _entries['signed:$signedPreKeyId'];
    if (saved == null) {
      throw InvalidKeyIdException('SignedPreKey $signedPreKeyId not found');
    }
    return SignedPreKeyRecord.fromSerialized(base64Decode(saved));
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final records = <SignedPreKeyRecord>[];
    for (final entry in _entries.entries) {
      if (entry.key.startsWith('signed:')) {
        records.add(
          SignedPreKeyRecord.fromSerialized(base64Decode(entry.value)),
        );
      }
    }
    return records;
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    _entries['signed:$signedPreKeyId'] = base64Encode(record.serialize());
    await persist();
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    return _entries.containsKey('signed:$signedPreKeyId');
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    _entries.remove('signed:$signedPreKeyId');
    await persist();
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final saved =
        _entries['session:${address.getName()}:${address.getDeviceId()}'];
    if (saved == null) return SessionRecord();
    return SessionRecord.fromSerialized(base64Decode(saved));
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final devices = <int>[];
    for (final key in _entries.keys) {
      if (key.startsWith('session:$name:')) {
        final id = int.tryParse(key.split(':').last);
        if (id != null) devices.add(id);
      }
    }
    return devices;
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    _entries['session:${address.getName()}:${address.getDeviceId()}'] =
        base64Encode(record.serialize());
    await persist();
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    return _entries.containsKey(
      'session:${address.getName()}:${address.getDeviceId()}',
    );
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    _entries.remove('session:${address.getName()}:${address.getDeviceId()}');
    await persist();
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    _entries.removeWhere((key, _) => key.startsWith('session:$name:'));
    await persist();
  }
}

class QfSignalManager {
  static const int _prekeyLowWatermark = 20;
  static const int _prekeyBatchSize = 50;

  static SignalProtocolAddress _address(int userId) {
    return SignalProtocolAddress('$userId', 1);
  }

  static Future<List<Map<String, dynamic>>> _oneTimeList(
    QfSignalStore store,
    Iterable<int> ids,
  ) async {
    final list = <Map<String, dynamic>>[];
    for (final id in ids) {
      if (await store.containsPreKey(id)) {
        final record = await store.loadPreKey(id);
        list.add({
          'keyId': id,
          'pubkey': base64Encode(
            QfSignalStore.rawPublicBytes(record.getKeyPair().publicKey),
          ),
        });
      }
    }
    return list;
  }

  static Future<Map<String, dynamic>> _fullBundle(QfSignalStore store) async {
    final signed = await store.loadSignedPreKey(0);
    final ids = <int>[];
    for (var id = 0; id < store.nextPreKeyId; id++) {
      if (await store.containsPreKey(id)) ids.add(id);
    }
    return {
      // 本机身份密钥为 X25519 单密钥：服务端要求 Ed25519 与 X25519 双字段，
      // Ed25519 字段镜像同一公钥以满足契约，会话协商只使用 X25519 字段。
      'identityKeyEd25519': store.identityRawB64,
      'identityKeyX25519': store.identityRawB64,
      'signedPrekey': {
        'keyId': 0,
        'pubkey': base64Encode(
          QfSignalStore.rawPublicBytes(signed.getKeyPair().publicKey),
        ),
        'signature': base64Encode(signed.signature),
      },
      'oneTimePrekeys': await _oneTimeList(store, ids),
    };
  }

  static Future<void> ensureInstalledQuietly(
    QfSessionController session,
  ) async {
    try {
      await ensureInstalled(session);
    } catch (_) {}
  }

  static Future<void> ensureInstalled(QfSessionController session) async {
    final store = await QfSignalStore.load();
    if (!await store.containsSignedPreKey(0)) {
      final signed = generateSignedPreKey(await store.getIdentityKeyPair(), 0);
      await store.storeSignedPreKey(0, signed);
      final preKeys = generatePreKeys(0, 100);
      for (final preKey in preKeys) {
        await store.storePreKey(preKey.id, preKey);
      }
      await store.syncPreKeyCounter();
      store.bundlePublished = false;
      await store.persist();
    }
    if (!store.bundlePublished) {
      try {
        await session.socialPutPrekeyBundle(await _fullBundle(store));
        store.bundlePublished = true;
        await store.persist();
      } catch (_) {}
      return;
    }
    await _replenishIfLow(session, store);
  }

  /// 公钥包余量低时自动补仓：只增量上传新的一次性预钥，不动身份与签名预钥。
  static Future<void> _replenishIfLow(
    QfSessionController session,
    QfSignalStore store,
  ) async {
    try {
      final mine = await session.socialGetMyPrekeyBundle();
      final remoteIdentity = (mine['identityKeyX25519'] ?? '').toString();
      if (remoteIdentity.isNotEmpty && remoteIdentity != store.identityRawB64) {
        await session.socialPutPrekeyBundle(await _fullBundle(store));
        return;
      }
      final count = (mine['oneTimePrekeyCount'] as num?)?.toInt() ?? 0;
      if (count >= _prekeyLowWatermark) return;
      final start = store.nextPreKeyId;
      final fresh = generatePreKeys(start, _prekeyBatchSize);
      final ids = <int>[];
      for (final preKey in fresh) {
        await store.storePreKey(preKey.id, preKey);
        ids.add(preKey.id);
      }
      await store.syncPreKeyCounter();
      await session.socialPutPrekeyBundle({
        'oneTimePrekeys': await _oneTimeList(store, ids),
      });
    } catch (_) {}
  }

  static Future<bool> peerReachable(
    QfSessionController session,
    int userId,
  ) async {
    try {
      final store = await QfSignalStore.load();
      if (await store.containsSession(_address(userId))) return true;
      return await _fetchBundle(session, userId) != null;
    } catch (_) {
      return false;
    }
  }

  static Future<PreKeyBundle?> _fetchBundle(
    QfSessionController session,
    int userId,
  ) async {
    Map<String, dynamic> data;
    try {
      data = await session.socialGetPrekeyBundle(userId);
    } on QfApiException catch (e) {
      if (e.code == 'PREKEY_BUNDLE_NOT_FOUND' || e.status == 404) return null;
      rethrow;
    }
    final identityRaw = (data['identityKeyX25519'] ?? '').toString();
    final signedRaw = data['signedPrekey'];
    if (identityRaw.isEmpty || signedRaw is! Map) return null;
    final signed = Map<String, dynamic>.from(signedRaw);
    Map<String, dynamic>? oneTime;
    final single = data['oneTimePrekey'];
    if (single is Map) {
      oneTime = Map<String, dynamic>.from(single);
    } else {
      final list = data['oneTimePrekeys'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        oneTime = Map<String, dynamic>.from(list.first as Map);
      }
    }
    final oneTimeRaw = (oneTime?['pubkey'] ?? '').toString();
    return PreKeyBundle(
      0,
      1,
      (oneTime?['keyId'] as num?)?.toInt(),
      oneTime == null || oneTimeRaw.isEmpty
          ? null
          : Curve.decodePoint(
              QfSignalStore.typedPublicBytes(base64Decode(oneTimeRaw)),
              0,
            ),
      (signed['keyId'] as num?)?.toInt() ?? 0,
      Curve.decodePoint(
        QfSignalStore.typedPublicBytes(
          base64Decode((signed['pubkey'] ?? '').toString()),
        ),
        0,
      ),
      base64Decode((signed['signature'] ?? '').toString()),
      IdentityKey.fromBytes(
        QfSignalStore.typedPublicBytes(base64Decode(identityRaw)),
        0,
      ),
    );
  }

  /// 加密一条消息并组装服务端中继格式：ciphertext 首字节为 Signal 消息类型、
  /// 其余为密文本体（服务端只作不透明转发）；nonce 为独立随机串，满足中继校验。
  static Future<({String ciphertext, String nonce})> encryptFor(
    QfSessionController session,
    int userId,
    String text,
  ) async {
    final store = await QfSignalStore.load();
    final address = _address(userId);
    if (!await store.containsSession(address)) {
      final bundle = await _fetchBundle(session, userId);
      if (bundle == null) {
        throw StateError('peer-bundle-missing');
      }
      final builder = SessionBuilder.fromSignalStore(store, address);
      await builder.processPreKeyBundle(bundle);
    }
    final cipher = SessionCipher.fromStore(store, address);
    final message = await cipher.encrypt(Uint8List.fromList(utf8.encode(text)));
    final packed = Uint8List.fromList([
      message.getType(),
      ...message.serialize(),
    ]);
    final nonce = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    return (ciphertext: base64Encode(packed), nonce: base64Encode(nonce));
  }

  static Future<String> decryptFrom(
    QfSessionController session,
    int fromUserId,
    String ciphertextB64,
  ) async {
    final store = await QfSignalStore.load();
    final cipher = SessionCipher.fromStore(store, _address(fromUserId));
    final packed = base64Decode(ciphertextB64);
    if (packed.isEmpty) throw const FormatException('empty-ciphertext');
    final type = packed.first;
    final bytes = Uint8List.fromList(packed.sublist(1));
    final plain = type == CiphertextMessage.prekeyType
        ? await cipher.decrypt(PreKeySignalMessage(bytes))
        : await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
    return utf8.decode(plain);
  }

  static Future<Fingerprint?> safetyFingerprint(
    QfSessionController session,
    int peerUserId,
  ) async {
    final store = await QfSignalStore.load();
    var remote = await store.getIdentity(_address(peerUserId));
    if (remote == null) {
      final bundle = await _fetchBundle(session, peerUserId);
      remote = bundle?.getIdentityKey();
    }
    final myId = session.userId;
    if (remote == null || myId == null) return null;
    final generator = NumericFingerprintGenerator(5200);
    return generator.createFor(
      0,
      Uint8List.fromList(utf8.encode('$myId')),
      store.identityKey,
      Uint8List.fromList(utf8.encode('$peerUserId')),
      remote,
    );
  }

  static Map<String, String> encryptBackupPlain(
    Uint8List plain,
    String password,
  ) {
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => Random.secure().nextInt(256)),
    );
    final kek = _argon2id(password, salt);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(kek), 128, nonce, Uint8List(0)));
    final sealed = cipher.process(plain);
    return {
      'v': '2',
      'kdf': 'argon2id',
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'data': base64Encode(sealed),
    };
  }

  static Uint8List decryptBackupPlain(
    Map<String, dynamic> backup,
    String password,
  ) {
    final salt = base64Decode((backup['salt'] ?? '').toString());
    final nonce = base64Decode((backup['nonce'] ?? '').toString());
    final data = base64Decode((backup['data'] ?? '').toString());
    final kek = _argon2id(password, Uint8List.fromList(salt));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(kek),
          128,
          Uint8List.fromList(nonce),
          Uint8List(0),
        ),
      );
    return cipher.process(Uint8List.fromList(data));
  }

  static Map<String, String>? rewrapBackupMap(
    Map<String, dynamic> backup, {
    required String oldPassword,
    required String newPassword,
  }) {
    try {
      final plain = decryptBackupPlain(backup, oldPassword);
      return encryptBackupPlain(plain, newPassword);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> rewrapKeyBackup({
    required QfSessionController session,
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      final data = await session.socialGetKeyBackup();
      final backupRaw = data['backup'];
      if (backupRaw is! String || backupRaw.isEmpty) return true;
      final decoded = jsonDecode(utf8.decode(base64Decode(backupRaw)));
      if (decoded is! Map) return false;
      final rewrapped = rewrapBackupMap(
        Map<String, dynamic>.from(decoded),
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
      if (rewrapped == null) return false;
      await session.socialPutKeyBackup(
        base64Encode(utf8.encode(jsonEncode(rewrapped))),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, String>> buildBackup(String password) async {
    final store = await QfSignalStore.load();
    return encryptBackupPlain(
      Uint8List.fromList(utf8.encode(jsonEncode(store.toJson()))),
      password,
    );
  }

  static Future<bool> restoreBackup(
    Map<String, dynamic> backup,
    String password,
  ) async {
    try {
      final plain = decryptBackupPlain(backup, password);
      final decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(plain)) as Map,
      );
      decoded['bundlePublished'] = false;
      await QfSignalStore.replaceFromJson(decoded);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Uint8List _argon2id(String password, Uint8List salt) {
    final generator = Argon2BytesGenerator()
      ..init(
        Argon2Parameters(
          Argon2Parameters.ARGON2_id,
          salt,
          desiredKeyLength: 32,
          iterations: 3,
          memory: 16384,
          lanes: 1,
        ),
      );
    final out = Uint8List(32);
    generator.deriveKey(Uint8List.fromList(utf8.encode(password)), 0, out, 0);
    return out;
  }
}

class QfChatHistoryException implements Exception {
  final String message;

  const QfChatHistoryException(this.message);

  @override
  String toString() => message;
}

class QfHistoryRecord {
  final String localId;
  final int peerId;
  final bool mine;
  final String text;
  final int ts;

  const QfHistoryRecord({
    required this.localId,
    required this.peerId,
    required this.mine,
    required this.text,
    required this.ts,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': localId,
      'peer': peerId,
      'mine': mine,
      'text': text,
      'ts': ts,
    };
  }

  static QfHistoryRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final text = (raw['text'] ?? '').toString();
    final localId = (raw['id'] ?? '').toString();
    if (text.isEmpty || localId.isEmpty) return null;
    return QfHistoryRecord(
      localId: localId,
      peerId: (raw['peer'] as num?)?.toInt() ?? 0,
      mine: raw['mine'] == true,
      text: text,
      ts: (raw['ts'] as num?)?.toInt() ?? 0,
    );
  }
}

enum QfHistoryDeleteResult { synced, pendingRetry, localOnly }

int _historyRotl32(int value, int shift) =>
    ((value << shift) | (value >> (32 - shift))) & 0xffffffff;

void _historyQuarterRound(List<int> x, int a, int b, int c, int d) {
  x[a] = (x[a] + x[b]) & 0xffffffff;
  x[d] = _historyRotl32(x[d] ^ x[a], 16);
  x[c] = (x[c] + x[d]) & 0xffffffff;
  x[b] = _historyRotl32(x[b] ^ x[c], 12);
  x[a] = (x[a] + x[b]) & 0xffffffff;
  x[d] = _historyRotl32(x[d] ^ x[a], 8);
  x[c] = (x[c] + x[d]) & 0xffffffff;
  x[b] = _historyRotl32(x[b] ^ x[c], 7);
}

Uint8List _historyHChaCha20(Uint8List key, Uint8List nonce) {
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
    _historyQuarterRound(x, 0, 4, 8, 12);
    _historyQuarterRound(x, 1, 5, 9, 13);
    _historyQuarterRound(x, 2, 6, 10, 14);
    _historyQuarterRound(x, 3, 7, 11, 15);
    _historyQuarterRound(x, 0, 5, 10, 15);
    _historyQuarterRound(x, 1, 6, 11, 12);
    _historyQuarterRound(x, 2, 7, 8, 13);
    _historyQuarterRound(x, 3, 4, 9, 14);
  }
  final out = ByteData(32);
  const indices = [0, 1, 2, 3, 12, 13, 14, 15];
  for (var i = 0; i < indices.length; i++) {
    out.setUint32(i * 4, x[indices[i]], Endian.little);
  }
  return out.buffer.asUint8List();
}

Uint8List _historyIetfChaChaPoly(
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

Uint8List _historyXEncrypt(Uint8List key, Uint8List nonce, Uint8List plain) {
  final subKey = _historyHChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
  final ietfNonce = Uint8List(12)
    ..setRange(4, 12, Uint8List.sublistView(nonce, 16, 24));
  return _historyIetfChaChaPoly(true, subKey, ietfNonce, plain);
}

Uint8List _historyXDecrypt(Uint8List key, Uint8List nonce, Uint8List sealed) {
  final subKey = _historyHChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
  final ietfNonce = Uint8List(12)
    ..setRange(4, 12, Uint8List.sublistView(nonce, 16, 24));
  return _historyIetfChaChaPoly(false, subKey, ietfNonce, sealed);
}

class QfChatHistoryVault {
  static const int maxEntries = 20000;
  static const int maxBytes = 64 * 1024 * 1024;
  static const String _kLocal = 'qf_chathistory_local_v1';
  static const String _kUploaded = 'qf_chathistory_uploaded_v1';
  static const String _kSeqMap = 'qf_chathistory_seqmap_v1';
  static const String _kPendingDelete = 'qf_chathistory_pending_delete_v1';
  static const String _kMaxSeq = 'qf_chathistory_max_seq';
  static const String _kTotalEntries = 'qf_chathistory_total_entries';
  static const String _kTotalBytes = 'qf_chathistory_total_bytes';
  static const Map<String, dynamic> _kdfParams = {'t': 3, 'm': 32768, 'p': 1};
  static const String _decryptFailed = '账户密码不正确或备份数据已损坏，无法解密。';

  static Uint8List? _historyKey;
  static bool capacityExceeded = false;

  static bool get historyUnlocked => _historyKey != null;

  static bool isNearCapacity(int entries, int bytes) {
    return entries >= 18000 || bytes >= (maxBytes * 0.9).floor();
  }

  static Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => Random.secure().nextInt(256)),
    );
  }

  static Uint8List _argon2History(
    String password,
    Uint8List salt,
    Map<String, dynamic> params,
  ) {
    final generator = Argon2BytesGenerator()
      ..init(
        Argon2Parameters(
          Argon2Parameters.ARGON2_id,
          salt,
          desiredKeyLength: 32,
          iterations: (params['t'] as num?)?.toInt() ?? 3,
          memory: (params['m'] as num?)?.toInt() ?? 32768,
          lanes: (params['p'] as num?)?.toInt() ?? 1,
        ),
      );
    final out = Uint8List(32);
    generator.deriveKey(Uint8List.fromList(utf8.encode(password)), 0, out, 0);
    return out;
  }

  static Map<String, dynamic> _parseParams(dynamic raw) {
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

  static Map<String, dynamic> _wrapHistoryKey(
    Uint8List historyKey,
    String password,
  ) {
    final salt = _randomBytes(16);
    final kek = _argon2History(password, salt, _kdfParams);
    final nonce = _randomBytes(24);
    final wrapped = _historyXEncrypt(kek, nonce, historyKey);
    final packed = Uint8List(24 + wrapped.length)
      ..setRange(0, 24, nonce)
      ..setRange(24, 24 + wrapped.length, wrapped);
    return {
      'wrappedKey': base64Encode(packed),
      'kdfAlgo': 'argon2id',
      'kdfSalt': base64Encode(salt),
      'kdfParams': Map<String, dynamic>.of(_kdfParams),
      'aeadAlgo': 'xchacha20poly1305',
    };
  }

  static Uint8List _unwrapHistoryKey(
    Map<String, dynamic> fields,
    String password,
  ) {
    try {
      final salt = base64Decode((fields['kdfSalt'] ?? '').toString());
      final kek = _argon2History(
        password,
        Uint8List.fromList(salt),
        _parseParams(fields['kdfParams']),
      );
      final packed = base64Decode((fields['wrappedKey'] ?? '').toString());
      final key = _historyXDecrypt(
        kek,
        Uint8List.sublistView(packed, 0, 24),
        Uint8List.sublistView(packed, 24),
      );
      if (key.length != 32) {
        throw const QfChatHistoryException(_decryptFailed);
      }
      return key;
    } on QfChatHistoryException {
      rethrow;
    } catch (_) {
      throw const QfChatHistoryException(_decryptFailed);
    }
  }

  static String _encryptRecord(Uint8List key, QfHistoryRecord record) {
    final nonce = _randomBytes(24);
    final sealed = _historyXEncrypt(
      key,
      nonce,
      Uint8List.fromList(utf8.encode(jsonEncode(record.toJson()))),
    );
    final packed = Uint8List(24 + sealed.length)
      ..setRange(0, 24, nonce)
      ..setRange(24, 24 + sealed.length, sealed);
    return base64Encode(packed);
  }

  static QfHistoryRecord? _decryptEntry(Uint8List key, String ciphertext) {
    try {
      final packed = base64Decode(ciphertext);
      final plain = _historyXDecrypt(
        key,
        Uint8List.sublistView(packed, 0, 24),
        Uint8List.sublistView(packed, 24),
      );
      return QfHistoryRecord.fromJson(jsonDecode(utf8.decode(plain)));
    } catch (_) {
      return null;
    }
  }

  static Future<List<QfHistoryRecord>> localRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLocal);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map(QfHistoryRecord.fromJson)
          .whereType<QfHistoryRecord>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<QfHistoryRecord>> localRecordsFor(int peerId) async {
    final all = await localRecords();
    return all.where((record) => record.peerId == peerId).toList();
  }

  static Future<void> _saveLocal(List<QfHistoryRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kLocal,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
  }

  static Future<Set<String>> _loadUploaded() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUploaded);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
    } catch (_) {}
    return {};
  }

  static Future<void> _saveUploaded(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUploaded, jsonEncode(ids.toList()));
  }

  static Future<Map<String, String>> _loadSeqMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSeqMap);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _saveSeqMap(Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSeqMap, jsonEncode(map));
  }

  static Future<Set<int>> _loadPendingDeletes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPendingDelete);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => (e as num?)?.toInt())
            .whereType<int>()
            .toSet();
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _savePendingDeletes(Set<int> peers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPendingDelete, jsonEncode(peers.toList()));
  }

  static Future<({int maxSeq, int totalEntries, int totalBytes})>
  knownTotals() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      maxSeq: prefs.getInt(_kMaxSeq) ?? 0,
      totalEntries: prefs.getInt(_kTotalEntries) ?? 0,
      totalBytes: prefs.getInt(_kTotalBytes) ?? 0,
    );
  }

  static Future<void> _saveTotals({
    int? maxSeq,
    int? totalEntries,
    int? totalBytes,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (maxSeq != null) await prefs.setInt(_kMaxSeq, maxSeq);
    if (totalEntries != null) await prefs.setInt(_kTotalEntries, totalEntries);
    if (totalBytes != null) await prefs.setInt(_kTotalBytes, totalBytes);
  }

  static Future<
    ({int localCount, int maxSeq, int totalEntries, int totalBytes})
  >
  status() async {
    final totals = await knownTotals();
    final records = await localRecords();
    return (
      localCount: records.length,
      maxSeq: totals.maxSeq,
      totalEntries: totals.totalEntries,
      totalBytes: totals.totalBytes,
    );
  }

  static Future<bool> archiveMessage(QfHistoryRecord record) async {
    if (record.text == '无法解密的消息' || record.text == '已加密发送的消息') {
      return false;
    }
    // A record the user deleted on this device stays deleted: the
    // server still returns it, but it must never be re-archived (C-38).
    final tombstones = await _loadTombstones();
    if (tombstones.contains(record.localId)) return false;
    final records = await localRecords();
    if (records.any((item) => item.localId == record.localId)) return false;
    records.add(record);
    records.sort((a, b) => a.ts.compareTo(b.ts));
    await _saveLocal(records);
    return true;
  }

  static const String _kTombstones = 'qf_chathistory_tombstones_v1';

  static Future<Set<String>> _loadTombstones() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTombstones);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
    } catch (_) {}
    return {};
  }

  /// Local ids the user deleted on this device. History rebuilds must
  /// filter these out even though the server still returns them (C-38).
  static Future<Set<String>> deletedLocalIds() => _loadTombstones();

  static Future<void> removeLocalRecord(String localId) async {
    final records = await localRecords();
    await _saveLocal(
      records.where((record) => record.localId != localId).toList(),
    );
    final prefs = await SharedPreferences.getInstance();
    final tombstones = await _loadTombstones()
      ..add(localId);
    await prefs.setString(_kTombstones, jsonEncode(tombstones.toList()));
  }

  static Future<void> unlock({
    required QfSessionController session,
    required String password,
  }) async {
    Map<String, dynamic>? keyRow;
    try {
      keyRow = await session.authed('GET', '/me/chathistory/key');
    } on QfApiException catch (e) {
      if (e.status != 404 && e.code != 'HISTORY_KEY_NOT_FOUND') rethrow;
    }
    if (keyRow == null) {
      final fresh = _randomBytes(32);
      await session.authed(
        'PUT',
        '/me/chathistory/key',
        body: _wrapHistoryKey(fresh, password),
      );
      _historyKey = fresh;
      return;
    }
    _historyKey = _unwrapHistoryKey(keyRow, password);
  }

  static Future<int> pullIncremental(QfSessionController session) async {
    final key = _historyKey;
    if (key == null) return 0;
    final totals = await knownTotals();
    var afterSeq = totals.maxSeq;
    final records = await localRecords();
    final knownIds = records.map((record) => record.localId).toSet();
    final uploaded = await _loadUploaded();
    final seqMap = await _loadSeqMap();
    final pendingDeletes = await _loadPendingDeletes();
    final tombstones = await _loadTombstones();
    var restored = 0;
    var maxSeq = totals.maxSeq;
    var totalEntries = totals.totalEntries;
    var totalBytes = totals.totalBytes;
    while (true) {
      final data = await session.authed(
        'GET',
        '/me/chathistory/entries?afterSeq=$afterSeq&limit=500',
      );
      final entries = data['entries'];
      if (entries is List) {
        for (final raw in entries) {
          if (raw is! Map) continue;
          final seq = (raw['seq'] as num?)?.toInt();
          final record = _decryptEntry(
            key,
            (raw['ciphertext'] ?? '').toString(),
          );
          if (record == null || seq == null) continue;
          if (pendingDeletes.contains(record.peerId)) continue;
          if (tombstones.contains(record.localId)) continue;
          seqMap['$seq'] = record.localId;
          uploaded.add(record.localId);
          if (knownIds.add(record.localId)) {
            records.add(record);
            restored += 1;
          }
        }
      }
      maxSeq = (data['maxSeq'] as num?)?.toInt() ?? maxSeq;
      totalEntries = (data['totalEntries'] as num?)?.toInt() ?? totalEntries;
      totalBytes = (data['totalBytes'] as num?)?.toInt() ?? totalBytes;
      afterSeq = (data['nextAfterSeq'] as num?)?.toInt() ?? afterSeq;
      if (data['hasMore'] != true) break;
    }
    records.sort((a, b) => a.ts.compareTo(b.ts));
    await _saveLocal(records);
    await _saveUploaded(uploaded);
    await _saveSeqMap(seqMap);
    await _saveTotals(
      maxSeq: maxSeq,
      totalEntries: totalEntries,
      totalBytes: totalBytes,
    );
    capacityExceeded = totalEntries >= maxEntries || totalBytes >= maxBytes;
    return restored;
  }

  static const String _kUploadBlocked = 'qf_chathistory_upload_blocked_v1';

  static Future<Set<String>> _loadUploadBlocked() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUploadBlocked);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
    } catch (_) {}
    return {};
  }

  static Future<void> _saveUploadBlocked(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUploadBlocked, jsonEncode(ids.toList()));
  }

  static Future<void> pushPending(QfSessionController session) async {
    final key = _historyKey;
    if (key == null) return;
    final uploaded = await _loadUploaded();
    final blocked = await _loadUploadBlocked();
    final records = await localRecords()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    final pending = records
        .where(
          (record) =>
              !uploaded.contains(record.localId) &&
              !blocked.contains(record.localId),
        )
        .toList();
    if (pending.isEmpty) return;
    final seqMap = await _loadSeqMap();
    var index = 0;
    while (index < pending.length) {
      final batch = <QfHistoryRecord>[];
      final entries = <String>[];
      var batchBytes = 0;
      while (index < pending.length && batch.length < 100) {
        final entry = _encryptRecord(key, pending[index]);
        final size = utf8.encode(entry).length;
        if (batch.isNotEmpty && batchBytes + size > 800000) break;
        batch.add(pending[index]);
        entries.add(entry);
        batchBytes += size;
        index += 1;
      }
      Map<String, dynamic> data;
      try {
        data = await session.authed(
          'POST',
          '/me/chathistory/entries',
          body: {'entries': entries},
        );
      } on QfApiException catch (e) {
        if (e.code == 'HISTORY_CAPACITY_EXCEEDED') capacityExceeded = true;
        rethrow;
      }
      final stored = (data['stored'] as num?)?.toInt() ?? batch.length;
      final batchMaxSeq = (data['maxSeq'] as num?)?.toInt() ?? 0;
      for (var i = 0; i < batch.length && i < stored; i++) {
        seqMap['${batchMaxSeq - stored + 1 + i}'] = batch[i].localId;
        uploaded.add(batch[i].localId);
      }
      await _saveUploaded(uploaded);
      await _saveSeqMap(seqMap);
      await _saveTotals(
        maxSeq: batchMaxSeq,
        totalEntries: (data['totalEntries'] as num?)?.toInt(),
        totalBytes: (data['totalBytes'] as num?)?.toInt(),
      );
    }
  }

  static Future<void> _rewriteAll(QfSessionController session) async {
    final key = _historyKey;
    if (key == null) throw const QfChatHistoryException(_decryptFailed);
    final totals = await knownTotals();
    final blocked = await _loadUploadBlocked();
    final records = (await localRecords())
        .where((record) => !blocked.contains(record.localId))
        .toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    final entries = records.map((r) => _encryptRecord(key, r)).toList();
    final data = await session.authed(
      'PUT',
      '/me/chathistory/entries',
      body: {'entries': entries, 'baseMaxSeq': totals.maxSeq},
    );
    final stored = (data['stored'] as num?)?.toInt() ?? records.length;
    final newMaxSeq = (data['maxSeq'] as num?)?.toInt() ?? 0;
    final seqMap = <String, String>{};
    for (var i = 0; i < records.length && i < stored; i++) {
      seqMap['${newMaxSeq - stored + 1 + i}'] = records[i].localId;
    }
    await _saveSeqMap(seqMap);
    await _saveUploaded(records.map((r) => r.localId).toSet());
    await _saveTotals(
      maxSeq: newMaxSeq,
      totalEntries: (data['totalEntries'] as num?)?.toInt() ?? records.length,
      totalBytes: (data['totalBytes'] as num?)?.toInt(),
    );
  }

  static Future<QfHistoryDeleteResult> deleteConversation(
    QfSessionController session,
    int peerId,
  ) async {
    final records = await localRecords();
    await _saveLocal(
      records.where((record) => record.peerId != peerId).toList(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('qf_chat_sent_$peerId');
    final pendingDeletes = await _loadPendingDeletes()
      ..add(peerId);
    await _savePendingDeletes(pendingDeletes);
    if (!session.isLoggedIn || _historyKey == null) {
      return QfHistoryDeleteResult.localOnly;
    }
    try {
      await _rewriteAll(session);
    } on QfApiException catch (e) {
      if (e.status != 409) return QfHistoryDeleteResult.pendingRetry;
      try {
        await pullIncremental(session);
        await _rewriteAll(session);
      } catch (_) {
        return QfHistoryDeleteResult.pendingRetry;
      }
    } catch (_) {
      return QfHistoryDeleteResult.pendingRetry;
    }
    final remaining = await _loadPendingDeletes()
      ..remove(peerId);
    await _savePendingDeletes(remaining);
    return QfHistoryDeleteResult.synced;
  }

  static Future<void> clearCloud(QfSessionController session) async {
    await session.authed('DELETE', '/me/chathistory');
    _historyKey = null;
    capacityExceeded = false;
    // Everything archived locally right now was just wiped from the
    // cloud on purpose: mark it never-upload, or the next vault unlock
    // would quietly push the whole local archive back up and the
    // 'cleared for good' promise would be a lie (C-41). Records
    // created after the clear are unaffected and sync normally.
    final blocked = await _loadUploadBlocked()
      ..addAll((await localRecords()).map((record) => record.localId));
    await _saveUploadBlocked(blocked);
    await _saveUploaded({});
    await _saveSeqMap({});
    await _savePendingDeletes({});
    await _saveTotals(maxSeq: 0, totalEntries: 0, totalBytes: 0);
  }

  // 改密弹窗（qf_pages2）当前密码路径改密成功后与 QfVaultService.rewrapAll 并列调用本方法。
  static Future<bool> rewrapHistoryKey({
    required QfSessionController session,
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      Map<String, dynamic> keyRow;
      try {
        keyRow = await session.authed('GET', '/me/chathistory/key');
      } on QfApiException catch (e) {
        if (e.status == 404 || e.code == 'HISTORY_KEY_NOT_FOUND') return true;
        rethrow;
      }
      final key = _unwrapHistoryKey(keyRow, oldPassword);
      await session.authed(
        'PUT',
        '/me/chathistory/key',
        body: _wrapHistoryKey(key, newPassword),
      );
      _historyKey = key;
      return true;
    } catch (_) {
      return false;
    }
  }
}
