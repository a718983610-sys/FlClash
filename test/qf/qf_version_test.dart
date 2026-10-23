import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter_test/flutter_test.dart';

QfReleaseManifest _manifest({
  String latest = '1.0.0',
  String retiredBelow = '0.0.0',
  bool maintenance = false,
}) {
  return QfReleaseManifest.fromJson({
    'latestVersion': latest,
    'retiredBelowVersion': retiredBelow,
    'maintenance': maintenance,
    'serverBaseUrl': 'https://example.invalid',
    'googleClientId': 'top-level-id',
    'platforms': {
      'android': {
        'downloadUrl': '',
        'notes': 'n',
        'googleClientId': 'android-id',
      },
      'windows': {'downloadUrl': '', 'notes': 'n'},
    },
  });
}

void main() {
  test('version parse and compare', () {
    expect(QfVersion.tryParse('1.2.3')!.compareTo(QfVersion(1, 2, 4)), -1);
    expect(QfVersion.tryParse('v1.0.0'), QfVersion(1, 0, 0));
    expect(QfVersion.tryParse('bad'), isNull);
  });

  test('update decision matrix', () {
    QfUpdateDecision decide(String current, QfReleaseManifest manifest) {
      return decideQfUpdate(
        current: QfVersion.tryParse(current)!,
        manifest: manifest,
      );
    }

    expect(decide('1.0.0', _manifest()), QfUpdateDecision.none);
    expect(decide('1.0.0', _manifest(latest: '1.1.0')), QfUpdateDecision.minor);
    expect(decide('1.9.9', _manifest(latest: '2.0.0')), QfUpdateDecision.force);
    expect(
      decide('0.9.1', _manifest(retiredBelow: '1.0.0')),
      QfUpdateDecision.retired,
    );
    expect(
      decide('1.0.0', _manifest(maintenance: true)),
      QfUpdateDecision.maintenance,
    );
    expect(
      decide('0.9.1', _manifest(retiredBelow: '1.0.0', maintenance: true)),
      QfUpdateDecision.maintenance,
    );
  });

  test('manifest platform google client id override', () {
    final manifest = _manifest();
    expect(manifest.googleClientIdFor('android'), 'android-id');
    expect(manifest.googleClientIdFor('windows'), 'top-level-id');
    expect(manifest.serverBaseUrl, 'https://example.invalid');
  });

  test('username validation rules', () {
    expect(qfUsernameError(''), isNotNull);
    expect(qfUsernameError('abc123'), isNotNull);
    expect(qfUsernameError('12345678'), isNotNull);
    expect(qfUsernameError('abcd 1234'), isNotNull);
    expect(qfUsernameError('abcd-1234'), isNotNull);
    expect(qfUsernameError('abcd1234'), isNull);
    expect(qfUsernameError('Alex2026ok'), isNull);
  });

  test('heartbeat signature format and sensitivity', () {
    final sig = qfHeartbeatSignature(
      key: 'secret-key',
      seq: 7,
      clientTs: 1700000000,
      trafficBytes: 2048,
      envFlags: 0,
    );
    expect(sig.length, 64);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(sig), isTrue);
    final other = qfHeartbeatSignature(
      key: 'secret-key',
      seq: 8,
      clientTs: 1700000000,
      trafficBytes: 2048,
      envFlags: 0,
    );
    expect(other, isNot(sig));
  });
}
