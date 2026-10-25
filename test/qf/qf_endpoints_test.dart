import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(QfEndpoints.resetForTest);

  test('rotation covers manifest base, fallback and the built-in host', () {
    QfEndpoints.apply(
      primaryUrl: 'https://203.0.113.10:8443',
      backupUrl: 'https://tunnel.example.com',
    );
    expect(QfEndpoints.orderedBases(), [
      'https://203.0.113.10:8443',
      'https://tunnel.example.com',
      QfConfig.fallbackServerBaseUrl,
    ]);
  });

  test('rotationFor rewrites the same path onto every base in order', () {
    QfEndpoints.apply(
      primaryUrl: 'https://203.0.113.10:8443',
      backupUrl: 'https://tunnel.example.com',
    );
    expect(
      QfEndpoints.rotationFor('https://203.0.113.10:8443/auth/login'),
      [
        'https://203.0.113.10:8443/auth/login',
        'https://tunnel.example.com/auth/login',
        '${QfConfig.fallbackServerBaseUrl}/auth/login',
      ],
    );
  });

  test('last good base moves to the front without duplicates', () {
    QfEndpoints.apply(
      primaryUrl: 'https://203.0.113.10:8443',
      backupUrl: 'https://tunnel.example.com',
    );
    QfEndpoints.noteSuccess('https://tunnel.example.com/auth/login');
    expect(QfEndpoints.lastGood, 'https://tunnel.example.com');
    expect(QfEndpoints.orderedBases(), [
      'https://tunnel.example.com',
      'https://203.0.113.10:8443',
      QfConfig.fallbackServerBaseUrl,
    ]);
  });

  test('an empty manifest primary never wipes the current primary', () {
    QfEndpoints.apply(primaryUrl: 'https://203.0.113.10:8443');
    QfEndpoints.apply(primaryUrl: '');
    expect(QfEndpoints.primary, 'https://203.0.113.10:8443');
  });

  test('foreign urls are not rotated', () {
    QfEndpoints.apply(primaryUrl: 'https://203.0.113.10:8443');
    expect(QfEndpoints.rotationFor('https://example.org/x'), [
      'https://example.org/x',
    ]);
  });
}
