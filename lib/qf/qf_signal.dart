import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/key_derivators/argon2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_session.dart';
import 'qf_social.dart';

class QfSignalStore extends SignalProtocolStore {
  static const String _prefsKey = 'qf_signal_store_v1';

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
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
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

  static void resetCache() {
    _cached = null;
  }

  static Future<void> replaceFromJson(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(data));
    resetCache();
  }

  Map<String, dynamic> toJson() {
    return {
      'identity': base64Encode(_identityPair.serialize()),
      'registrationId': _registrationId,
      'bundlePublished': bundlePublished,
      'entries': _entries,
    };
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  String get identityPublicB64 =>
      base64Encode(_identityPair.getPublicKey().serialize());

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
  static SignalProtocolAddress _address(int userId) {
    return SignalProtocolAddress('$userId', 1);
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
    }
    if (store.bundlePublished) return;
    final signed = await store.loadSignedPreKey(0);
    final preKeyList = <Map<String, dynamic>>[];
    for (var id = 0; id < 100; id++) {
      if (await store.containsPreKey(id)) {
        final record = await store.loadPreKey(id);
        preKeyList.add({
          'id': id,
          'publicKey': base64Encode(record.getKeyPair().publicKey.serialize()),
        });
      }
    }
    await session.socialUpdateProfile({
      'signalBundle': {
        'registrationId': store.registrationId,
        'identityKey': store.identityPublicB64,
        'signedPreKeyId': 0,
        'signedPreKey': base64Encode(signed.getKeyPair().publicKey.serialize()),
        'signedPreKeySignature': base64Encode(signed.signature),
        'preKeys': preKeyList,
      },
    });
    store.bundlePublished = true;
    await store.persist();
  }

  static Future<PreKeyBundle?> _fetchBundle(
    QfSessionController session,
    int userId,
  ) async {
    final profile = await session.socialGetUserProfile(userId);
    final bundle = profile['signalBundle'];
    if (bundle is! Map) return null;
    final data = Map<String, dynamic>.from(bundle);
    Map<String, dynamic>? oneTime;
    final single = data['preKey'];
    if (single is Map) {
      oneTime = Map<String, dynamic>.from(single);
    } else {
      final list = data['preKeys'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        oneTime = Map<String, dynamic>.from(list.first as Map);
      }
    }
    return PreKeyBundle(
      (data['registrationId'] as num?)?.toInt() ?? 0,
      1,
      (oneTime?['id'] as num?)?.toInt(),
      oneTime == null
          ? null
          : Curve.decodePoint(
              base64Decode((oneTime['publicKey'] ?? '').toString()),
              0,
            ),
      (data['signedPreKeyId'] as num?)?.toInt() ?? 0,
      Curve.decodePoint(
        base64Decode((data['signedPreKey'] ?? '').toString()),
        0,
      ),
      base64Decode((data['signedPreKeySignature'] ?? '').toString()),
      IdentityKey.fromBytes(
        base64Decode((data['identityKey'] ?? '').toString()),
        0,
      ),
    );
  }

  static Future<({int type, String body})> encryptFor(
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
    return (type: message.getType(), body: base64Encode(message.serialize()));
  }

  static Future<String> decryptFrom(
    QfSessionController session,
    int fromUserId,
    int type,
    String bodyB64,
  ) async {
    final store = await QfSignalStore.load();
    final cipher = SessionCipher.fromStore(store, _address(fromUserId));
    final bytes = base64Decode(bodyB64);
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

  static Future<Map<String, String>> buildBackup(String password) async {
    final store = await QfSignalStore.load();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => Random.secure().nextInt(256)),
    );
    final kek = _argon2id(password, salt);
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(store.toJson())));
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

  static Future<bool> restoreBackup(
    Map<String, dynamic> backup,
    String password,
  ) async {
    try {
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
      final plain = cipher.process(Uint8List.fromList(data));
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
