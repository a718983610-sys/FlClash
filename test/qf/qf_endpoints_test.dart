import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(QfEndpoints.resetForTest);

  test('rotation covers manifest base, fallback and the built-in hosts', () {
    QfEndpoints.apply(
      primaryUrl: 'https://203.0.113.10:8443',
      backupUrl: 'https://tunnel.example.com',
    );
    expect(QfEndpoints.orderedBases(), [
      'https://203.0.113.10:8443',
      'https://tunnel.example.com',
      QfConfig.directServerBaseUrl,
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
        '${QfConfig.directServerBaseUrl}/auth/login',
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
      QfConfig.directServerBaseUrl,
      QfConfig.fallbackServerBaseUrl,
    ]);
  });

  test('a network failure on the remembered base forgets it', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'qf_endpoints_last_good': 'http://dead.example',
    });
    QfEndpoints.lastGood = 'http://dead.example';
    QfEndpoints.noteNetworkFailure('http://dead.example/auth/login');
    expect(QfEndpoints.lastGood, '');
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('qf_endpoints_last_good'), isNull);
  });

  test('a network failure on another base keeps the remembered one', () {
    QfEndpoints.apply(
      primaryUrl: 'https://203.0.113.10:8443',
      backupUrl: 'https://tunnel.example.com',
    );
    QfEndpoints.noteSuccess('https://tunnel.example.com/auth/login');
    QfEndpoints.noteNetworkFailure('https://203.0.113.10:8443/auth/login');
    expect(QfEndpoints.lastGood, 'https://tunnel.example.com');
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

  test('entry POSTs rotate across bases, ordinary writes do not', () {
    expect(
      QfHttp.rotatesAcrossBases('POST', 'https://x.example/auth/login', {}),
      isTrue,
    );
    expect(
      QfHttp.rotatesAcrossBases(
        'POST',
        'https://x.example/auth/register/verify',
        {},
      ),
      isTrue,
    );
    expect(
      QfHttp.rotatesAcrossBases(
        'POST',
        'https://x.example/guest/register',
        {},
      ),
      isTrue,
    );
    expect(
      QfHttp.rotatesAcrossBases('POST', 'https://x.example/camps', {}),
      isFalse,
    );
    expect(
      QfHttp.rotatesAcrossBases('POST', 'https://x.example/chat/send', {
        'msgId': 'm1',
      }),
      isTrue,
    );
    expect(
      QfHttp.rotatesAcrossBases('GET', 'https://x.example/camps', null),
      isTrue,
    );
  });
}
