import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/qf/qf_data_migration.dart';
import 'package:fl_clash/qf/qf_qr.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zxing2/qrcode.dart';

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStore(Map<String, String> store) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        final args = Map<dynamic, dynamic>.from(call.arguments as Map);
        final key = args['key'].toString();
        return switch (call.method) {
          'read' => store[key],
          'write' => store[key] = args['value'].toString(),
          'delete' => store.remove(key),
          _ => null,
        };
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('W5-02 manifest fail-open extensions', () {
    QfReleaseManifest manifest({
      bool maintenance = false,
      String latest = '0.9.1',
      String minUsable = '0.0.0',
    }) {
      return QfReleaseManifest.fromJson({
        'latestVersion': latest,
        'maintenance': maintenance,
        'minUsableVersion': minUsable,
        'platforms': {
          'windows': {'downloadUrl': 'https://example.com/app.exe'},
        },
      });
    }

    setUp(() {
      QfUpdateService.platformKeyOverride = 'windows';
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      QfUpdateService.platformKeyOverride = null;
      QfUpdateService.manifestFetcherForTest = null;
      QfUpdateService.onFreshCheck = null;
    });

    test('stale cache cannot force-update or retire either', () async {
      SharedPreferences.setMockInitialValues({
        'qf_release_manifest_cache': jsonEncode(
          manifest(latest: '9.9.9', minUsable: '9.9.9').toJson(),
        ),
      });
      QfUpdateService.manifestFetcherForTest = () async => null;
      final check = await QfUpdateService.check('0.9.1');
      expect(check.decision, QfUpdateDecision.none);
      expect(check.manifestFresh, isFalse);
      expect(check.manifest, isNotNull);
    });

    test('fresh manifest reports manifestFresh for manual checks', () async {
      QfUpdateService.manifestFetcherForTest =
          () async => manifest(latest: '0.9.1');
      final check = await QfUpdateService.check('0.9.1');
      expect(check.decision, QfUpdateDecision.none);
      expect(check.manifestFresh, isTrue);
    });

    test('background retry re-judges immediately on success', () async {
      var fresh = false;
      QfUpdateService.manifestFetcherForTest =
          () async => fresh ? manifest(maintenance: true) : null;
      final first = await QfUpdateService.check('0.9.1');
      expect(first.decision, QfUpdateDecision.none);
      QfUpdateCheck? pushed;
      QfUpdateService.onFreshCheck = (check) => pushed = check;
      fresh = true;
      expect(await QfUpdateService.retryManifestOnce(), isTrue);
      expect(pushed, isNotNull);
      expect(pushed!.decision, QfUpdateDecision.maintenance);
    });
  });
}
