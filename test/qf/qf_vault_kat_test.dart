import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/qf/qf_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/argon2.dart';

Uint8List _bytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// Same generator construction as the private _argon2id in qf_vault.dart:
// Argon2id, 32-byte output, UTF-8 password, caller-supplied t/m/p.
Uint8List _deriveLikeVault(
  String password,
  Uint8List salt, {
  required int t,
  required int m,
  required int p,
}) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: t,
        memory: m,
        lanes: p,
      ),
    );
  final out = Uint8List(32);
  generator.deriveKey(Uint8List.fromList(utf8.encode(password)), 0, out, 0);
  return out;
}

void main() {
  group('qf vault known-answer vectors', () {
    // Source: libsodium test/default/pwhash_argon2id.c, tv3 encoded strings
    // ($argon2id$v=19$...), decoded to raw salt and 32-byte output here.
    test('argon2id libsodium pwhash vectors', () {
      expect(
        _hex(
          _deriveLikeVault(
            '',
            _bytes('6c0f356abb225f2b1ddd66d34739843b'),
            t: 2,
            m: 4882,
            p: 1,
          ),
        ),
        '366f1004cfbb447d435e8f6bbe9e5cc0a10e38e7c3da0e89bb19578a1a0d7291',
      );
      expect(
        _hex(
          _deriveLikeVault(
            'K3S=KyH#)36_?]LxeR8QNKw6X=gFbxai\$C%29V*',
            _bytes('3e4120707265747479206c6f6e672073616c74'),
            t: 1,
            m: 4096,
            p: 3,
          ),
        ),
        '1d4ab1e59d5bfd9ca99d4aefbc9e540b643e4fa4355b00122bf2abf5d45b180d',
      );
    });

    // Source: RFC 9106 section 5.3 (Argon2id, version 0x13, m=32 KiB, t=3,
    // p=4, secret and associated data set; the vault wrapper passes neither,
    // so this exercises the same generator with the RFC inputs verbatim).
    test('argon2id RFC 9106 section 5.3 vector', () {
      final generator = Argon2BytesGenerator()
        ..init(
          Argon2Parameters(
            Argon2Parameters.ARGON2_id,
            Uint8List.fromList(List<int>.filled(16, 0x02)),
            desiredKeyLength: 32,
            secret: Uint8List.fromList(List<int>.filled(8, 0x03)),
            additional: Uint8List.fromList(List<int>.filled(12, 0x04)),
            iterations: 3,
            memory: 32,
            lanes: 4,
          ),
        );
      final out = Uint8List(32);
      generator.deriveKey(
        Uint8List.fromList(List<int>.filled(32, 0x01)),
        0,
        out,
        0,
      );
      expect(
        _hex(out),
        '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
      );
    });

    // Source: draft-irtf-cfrg-xchacha-03 section 2.2.1 (HChaCha20 block
    // function test vector; expected value is the resultant subkey as
    // printed there, byte for byte).
    test('hchacha20 draft-irtf-cfrg-xchacha-03 vector', () {
      final out = qfHChaCha20(
        _bytes(
          '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f',
        ),
        _bytes('000000090000004a0000000031415927'),
      );
      expect(
        _hex(out),
        '82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853'
        'c12ec41326d3ecdc',
      );
    });

    // Source: Wycheproof xchacha20_poly1305_test.json tcId 34 (valid,
    // empty AAD, matching the vault AEAD which fixes associated data empty).
    test('xchacha20-poly1305 wycheproof tcId 34', () {
      final key = _bytes(
        '6a1f808358461e75072a054e2fc4e4c3e7f882c57920dda3278d0c860ca704e3',
      );
      final nonce = _bytes('25dc279923c1bcdaa7a36e7b884b51f62343abad71986037');
      final plain = _bytes('f242209c67698ea32c2152f8785b7d82');
      final sealed = qfXChaCha20Poly1305Encrypt(key, nonce, plain);
      expect(
        _hex(sealed),
        '732715c60018fb0ed55c14c1fa9a5273'
        'afe3c4f050bf001e1dfcb2313dd8edd2',
      );
      expect(qfXChaCha20Poly1305Decrypt(key, nonce, sealed), plain);
    });

    // Source: Wycheproof xchacha20_poly1305_test.json tcId 2 (valid, empty
    // AAD and empty message, so the sealed output is the tag alone).
    test('xchacha20-poly1305 wycheproof tcId 2 empty message', () {
      final key = _bytes(
        'ab1562faea9f47af3ae1c3d6d030e3af230255dff3df583ced6fbbcbf9d606a9',
      );
      final nonce = _bytes('6a5e0c4617e07091b605a4de2c02dde117de2ebd53b23497');
      final sealed = qfXChaCha20Poly1305Encrypt(key, nonce, Uint8List(0));
      expect(_hex(sealed), 'e2697ea6877aba39d9555a00e14db041');
      expect(qfXChaCha20Poly1305Decrypt(key, nonce, sealed), isEmpty);
    });
  });
}
