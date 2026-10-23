import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/qf/qf_signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _storeKey = 'qf_signal_store_v1';

Future<QfSignalStore> _installPersona() async {
  final store = await QfSignalStore.load();
  final signed = generateSignedPreKey(await store.getIdentityKeyPair(), 0);
  await store.storeSignedPreKey(0, signed);
  for (final preKey in generatePreKeys(0, 10)) {
    await store.storePreKey(preKey.id, preKey);
  }
  return store;
}

Future<String> _snapshot() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_storeKey)!;
}

Future<void> _restore(String snapshot) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_storeKey, snapshot);
  QfSignalStore.resetCache();
}

Future<PreKeyBundle> _bundleOf(QfSignalStore store) async {
  final signed = await store.loadSignedPreKey(0);
  final preKey = await store.loadPreKey(0);
  return PreKeyBundle(
    store.registrationId,
    1,
    preKey.id,
    preKey.getKeyPair().publicKey,
    signed.id,
    signed.getKeyPair().publicKey,
    signed.signature,
    store.identityKey,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signal session roundtrip between two persisted stores', () async {
    SharedPreferences.setMockInitialValues({});
    final alice = await _installPersona();
    final aliceSnapshot = await _snapshot();
    final aliceBundle = await _bundleOf(alice);

    SharedPreferences.setMockInitialValues({});
    QfSignalStore.resetCache();
    final bob = await _installPersona();

    final bobAddress = SignalProtocolAddress('1001', 1);
    await SessionBuilder.fromSignalStore(
      bob,
      bobAddress,
    ).processPreKeyBundle(aliceBundle);
    final bobCipher = SessionCipher.fromStore(bob, bobAddress);
    final first = await bobCipher.encrypt(
      Uint8List.fromList(utf8.encode('你好，这是第一条加密消息')),
    );
    expect(first.getType(), CiphertextMessage.prekeyType);
    final firstBytes = first.serialize();
    final firstType = first.getType();
    final bobSnapshot = await _snapshot();

    await _restore(aliceSnapshot);
    final aliceStore = await QfSignalStore.load();
    final aliceAddress = SignalProtocolAddress('1001', 1);
    final aliceCipher = SessionCipher.fromStore(aliceStore, aliceAddress);
    final plain = firstType == CiphertextMessage.prekeyType
        ? await aliceCipher.decrypt(PreKeySignalMessage(firstBytes))
        : await aliceCipher.decryptFromSignal(
            SignalMessage.fromSerialized(firstBytes),
          );
    expect(utf8.decode(plain), '你好，这是第一条加密消息');

    final reply = await aliceCipher.encrypt(
      Uint8List.fromList(utf8.encode('收到，回复一条')),
    );
    final replyBytes = reply.serialize();
    final replyType = reply.getType();
    final aliceSnapshot2 = await _snapshot();

    await _restore(bobSnapshot);
    final bobStore = await QfSignalStore.load();
    final bobCipher2 = SessionCipher.fromStore(
      bobStore,
      SignalProtocolAddress('1001', 1),
    );
    final replyPlain = replyType == CiphertextMessage.prekeyType
        ? await bobCipher2.decrypt(PreKeySignalMessage(replyBytes))
        : await bobCipher2.decryptFromSignal(
            SignalMessage.fromSerialized(replyBytes),
          );
    expect(utf8.decode(replyPlain), '收到，回复一条');

    await _restore(aliceSnapshot2);
    final fingerprint = NumericFingerprintGenerator(5200).createFor(
      0,
      Uint8List.fromList(utf8.encode('1001')),
      (await QfSignalStore.load()).identityKey,
      Uint8List.fromList(utf8.encode('2002')),
      bob.identityKey,
    );
    expect(fingerprint.displayableFingerprint.getDisplayText().length, 60);
    expect(fingerprint.scannableFingerprint.fingerprints, isNotEmpty);
    expect(
      fingerprint.scannableFingerprint.compareTo(
        fingerprint.scannableFingerprint.fingerprints,
      ),
      isFalse,
    );
  });

  test('argon2id backup roundtrip restores the signal store', () async {
    SharedPreferences.setMockInitialValues({});
    QfSignalStore.resetCache();
    final store = await _installPersona();
    final identityBefore = store.identityPublicB64;
    final backup = await QfSignalManager.buildBackup('correct horse 42');
    expect(backup['kdf'], 'argon2id');

    SharedPreferences.setMockInitialValues({});
    QfSignalStore.resetCache();
    await QfSignalStore.load();
    final restored = await QfSignalManager.restoreBackup(backup, 'wrong');
    expect(restored, isFalse);
    final ok = await QfSignalManager.restoreBackup(backup, 'correct horse 42');
    expect(ok, isTrue);
    final restoredStore = await QfSignalStore.load();
    expect(restoredStore.identityPublicB64, identityBefore);
    expect(await restoredStore.containsSignedPreKey(0), isTrue);
  });
}
