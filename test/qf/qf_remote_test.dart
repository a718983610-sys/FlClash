import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_remote.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QfReleaseManifest qfRemoteWebBaseUrl', () {
    test('parses the field and round-trips it', () {
      final manifest = QfReleaseManifest.fromJson({
        'latestVersion': '2.0.3',
        'retiredBelowVersion': '1.0.0',
        'maintenance': false,
        'serverBaseUrl': 'https://example.test',
        'googleClientId': 'client',
        'qfRemoteWebBaseUrl': 'https://remote.example.test',
        'platforms': {},
      });

      expect(manifest.qfRemoteWebBaseUrl, 'https://remote.example.test');
      expect(
        manifest.toJson()['qfRemoteWebBaseUrl'],
        'https://remote.example.test',
      );
      expect(
        manifest.withMaintenance(true).qfRemoteWebBaseUrl,
        'https://remote.example.test',
      );
    });

    test('defaults to empty when the field is absent', () {
      final manifest = QfReleaseManifest.fromJson({
        'latestVersion': '2.0.3',
        'retiredBelowVersion': '1.0.0',
        'maintenance': false,
        'serverBaseUrl': 'https://example.test',
        'googleClientId': 'client',
        'platforms': {},
      });

      expect(manifest.qfRemoteWebBaseUrl, '');
      expect(QfConfig.builtinQfRemoteWebBaseUrl, startsWith('https://'));
    });
  });

  group('QfrAccess', () {
    test('reads an allow verdict', () {
      final access = QfrAccess.fromJson({
        'ok': true,
        'allow': true,
        'code': 'OK',
        'planName': 'QFRemote 永久套餐',
        'displayStatus': '正常',
      });

      expect(access?.allow, isTrue);
      expect(access?.code, 'OK');
      expect(access?.isBanned, isFalse);
      expect(access?.planName, 'QFRemote 永久套餐');
    });

    test('reads deny codes and flags bans', () {
      final noKey = QfrAccess.fromJson({'allow': false, 'code': 'G1'});
      expect(noKey?.allow, isFalse);
      expect(noKey?.isBanned, isFalse);

      final banned = QfrAccess.fromJson({'allow': false, 'code': 'BAN_UNTIL'});
      expect(banned?.isBanned, isTrue);

      expect(QfrAccess.fromJson('nope'), isNull);
      expect(QfrAccess.fromJson(null), isNull);
    });
  });

  group('QfrProfile', () {
    test('maps the /license/api/me view fields', () {
      final profile = QfrProfile.fromJson({
        'username': 'qfuser01',
        'planName': 'QFRemote 30日套餐',
        'maskedKey': 'ABCDE-*****-*****-*****-12345',
        'displayStatus': '正常',
        'statusNote': '',
        'webEnabled': true,
      });

      expect(profile?.username, 'qfuser01');
      expect(profile?.planName, 'QFRemote 30日套餐');
      expect(profile?.maskedKey, contains('ABCDE'));
      expect(profile?.webEnabled, isTrue);
    });
  });
}
