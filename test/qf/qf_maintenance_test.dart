import 'dart:convert';

import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

QfReleaseManifest _manifest({required bool maintenance}) {
  return QfReleaseManifest(
    latestVersion: '1.0.0',
    retiredBelowVersion: '0.0.0',
    maintenance: maintenance,
    serverBaseUrl: '',
    googleClientId: '',
    platforms: const {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    QfUpdateService.platformKeyOverride = 'windows';
  });

  tearDown(() {
    QfUpdateService.platformKeyOverride = null;
    QfUpdateService.manifestFetcherForTest = null;
  });

  test(
    'stale cached maintenance=true does not block when fetch fails',
    () async {
      SharedPreferences.setMockInitialValues({
        'qf_release_manifest_cache': jsonEncode(
          _manifest(maintenance: true).toJson(),
        ),
      });
      QfUpdateService.manifestFetcherForTest = () async => null;
      final check = await QfUpdateService.check('1.0.0');
      expect(check.decision, isNot(QfUpdateDecision.maintenance));
      expect(check.decision, QfUpdateDecision.none);
      expect(check.manifestFresh, isFalse);
      expect(check.manifest, isNotNull);
    },
  );

  test('fresh maintenance=true blocks', () async {
    SharedPreferences.setMockInitialValues({});
    QfUpdateService.manifestFetcherForTest = () async =>
        _manifest(maintenance: true);
    final check = await QfUpdateService.check('1.0.0');
    expect(check.decision, QfUpdateDecision.maintenance);
  });

  test('fresh maintenance=false does not block', () async {
    SharedPreferences.setMockInitialValues({
      'qf_release_manifest_cache': jsonEncode(
        _manifest(maintenance: true).toJson(),
      ),
    });
    QfUpdateService.manifestFetcherForTest = () async =>
        _manifest(maintenance: false);
    final check = await QfUpdateService.check('1.0.0');
    expect(check.decision, QfUpdateDecision.none);
  });

  test('no manifest at all does not block', () async {
    SharedPreferences.setMockInitialValues({});
    QfUpdateService.manifestFetcherForTest = () async => null;
    final check = await QfUpdateService.check('1.0.0');
    expect(check.decision, QfUpdateDecision.none);
  });
}
