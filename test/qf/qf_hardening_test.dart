import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/qf/qf_data_migration.dart';
import 'package:fl_clash/qf/qf_qr.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_social.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as mui;
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

  group('W6-14 signal store secure migration', () {
    test('legacy plaintext store migrates to secure storage', () async {
      final secure = <String, String>{};
      _mockSecureStore(secure);
      final pair = generateIdentityKeyPair();
      final legacyJson = jsonEncode({
        'identity': base64Encode(pair.serialize()),
        'registrationId': 4242,
        'bundlePublished': true,
        'entries': <String, String>{},
      });
      SharedPreferences.setMockInitialValues({
        'qf_signal_store_v1': legacyJson,
      });
      QfSignalStore.resetCache();
      final store = await QfSignalStore.load();
      expect(
        store.identityPublicB64,
        base64Encode(pair.getPublicKey().serialize()),
      );
      expect(store.bundlePublished, isTrue);
      expect(secure['qf_signal_store_v1'], legacyJson);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('qf_signal_store_v1'), isNull);
      QfSignalStore.resetCache();
      final again = await QfSignalStore.load();
      expect(again.identityPublicB64, store.identityPublicB64);
    });

    test('fresh store persists to secure storage only', () async {
      final secure = <String, String>{};
      _mockSecureStore(secure);
      SharedPreferences.setMockInitialValues({});
      QfSignalStore.resetCache();
      final store = await QfSignalStore.load();
      expect(store.identityPublicB64, isNotEmpty);
      expect(secure['qf_signal_store_v1'], isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('qf_signal_store_v1'), isNull);
    });
  });

  group('W1-09 legacy data directory migration', () {
    test('decision table', () {
      expect(
        qfShouldMigrate(
          markerExists: false,
          newHasData: false,
          oldHasData: true,
        ),
        isTrue,
      );
      expect(
        qfShouldMigrate(
          markerExists: true,
          newHasData: false,
          oldHasData: true,
        ),
        isFalse,
      );
      expect(
        qfShouldMigrate(
          markerExists: false,
          newHasData: true,
          oldHasData: true,
        ),
        isFalse,
      );
      expect(
        qfShouldMigrate(
          markerExists: false,
          newHasData: false,
          oldHasData: false,
        ),
        isFalse,
      );
      expect(qfNamesContainAppData(['config.yaml', 'x.txt']), isTrue);
      expect(qfNamesContainAppData(['x.txt']), isFalse);
    });

    test('copies the legacy directory once and leaves a marker', () async {
      final root = await Directory.systemTemp.createTemp('qf-mig-');
      addTearDown(() => root.delete(recursive: true));
      final current = Directory(p.join(root.path, 'com.follow', 'QFClash'));
      final legacy = Directory(p.join(root.path, 'com.follow', 'clash'));
      await current.create(recursive: true);
      await Directory(p.join(legacy.path, 'profiles')).create(recursive: true);
      await File(p.join(legacy.path, 'config.yaml')).writeAsString('cfg');
      await File(p.join(legacy.path, 'database.sqlite')).writeAsString('db');
      await File(
        p.join(legacy.path, 'profiles', 'a.yaml'),
      ).writeAsString('profile-a');
      await File(
        p.join(legacy.path, 'shared_preferences.json'),
      ).writeAsString('{}');

      expect(await qfMigrateLegacyDataDir(current), isTrue);
      expect(
        await File(p.join(current.path, 'config.yaml')).readAsString(),
        'cfg',
      );
      expect(
        await File(p.join(current.path, 'profiles', 'a.yaml')).readAsString(),
        'profile-a',
      );
      expect(
        await File(p.join(current.path, qfLegacyMarkerName)).exists(),
        isTrue,
      );
      expect(await qfMigrateLegacyDataDir(current), isFalse);
    });

    test('does not touch a current directory that already has data', () async {
      final root = await Directory.systemTemp.createTemp('qf-mig-');
      addTearDown(() => root.delete(recursive: true));
      final current = Directory(p.join(root.path, 'com.follow', 'QFClash'));
      final legacy = Directory(p.join(root.path, 'com.follow', 'clash'));
      await current.create(recursive: true);
      await legacy.create(recursive: true);
      await File(p.join(current.path, 'config.yaml')).writeAsString('new');
      await File(p.join(legacy.path, 'config.yaml')).writeAsString('old');
      expect(await qfMigrateLegacyDataDir(current), isFalse);
      expect(
        await File(p.join(current.path, 'config.yaml')).readAsString(),
        'new',
      );
    });
  });

  group('W3-10 WinINET proxy backup', () {
    const sample = '''

HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http://corp.example:8080
    ProxyOverride    REG_SZ    *.local;<local>
''';

    test('parses reg query output', () {
      final backup = WinInetProxyBackup.fromRegOutput(sample);
      expect(backup.enable, isTrue);
      expect(backup.server, 'http://corp.example:8080');
      expect(backup.bypass, '*.local;<local>');
      expect(backup.pointsAtCore, isFalse);
    });

    test('restore commands write server, bypass and enable back', () {
      const backup = WinInetProxyBackup(
        enable: true,
        server: 'http://corp.example:8080',
        bypass: '*.local',
      );
      final commands = backup.restoreCommands(r'HKCU\Software\Test');
      expect(commands.length, 3);
      expect(commands[0], contains('ProxyServer'));
      expect(commands[0].last, '/f');
      expect(commands[1], contains('ProxyOverride'));
      expect(commands[2], contains('ProxyEnable'));
      expect(commands[2], contains('1'));
      const off = WinInetProxyBackup(enable: false, server: '', bypass: '');
      expect(off.restoreCommands('k')[2], contains('0'));
      expect(off.pointsAtCore, isFalse);
      const core = WinInetProxyBackup(
        enable: true,
        server: '127.0.0.1:7890',
        bypass: '',
      );
      expect(core.pointsAtCore, isTrue);
    });
  });

  group('W3-03 pure Dart QR decoding', () {
    (Int32List, int, int) renderQr(String content) {
      final code = Encoder.encode(content, ErrorCorrectionLevel.m);
      final matrix = code.matrix!;
      const scale = 6;
      const quiet = 4;
      final width = (matrix.width + quiet * 2) * scale;
      final height = (matrix.height + quiet * 2) * scale;
      final pixels = Int32List(width * height)
        ..fillRange(0, width * height, 0xFFFFFFFF);
      for (var y = 0; y < matrix.height; y++) {
        for (var x = 0; x < matrix.width; x++) {
          if (matrix.get(x, y) != 1) continue;
          for (var dy = 0; dy < scale; dy++) {
            for (var dx = 0; dx < scale; dx++) {
              final px = (x + quiet) * scale + dx;
              final py = (y + quiet) * scale + dy;
              pixels[py * width + px] = 0xFF000000;
            }
          }
        }
      }
      return (pixels, width, height);
    }

    test('decodes a rendered QR code from pixels and from PNG bytes', () {
      const content = 'https://example.com/sub?token=abc123';
      final (pixels, width, height) = renderQr(content);
      expect(qfDecodeQrPixels(width, height, pixels), content);
      final image = img.Image(width: width, height: height);
      for (var i = 0; i < pixels.length; i++) {
        final argb = pixels[i];
        image.setPixelRgba(
          i % width,
          i ~/ width,
          (argb >> 16) & 0xFF,
          (argb >> 8) & 0xFF,
          argb & 0xFF,
          0xFF,
        );
      }
      final png = img.encodePng(image);
      expect(qfDecodeQrImageBytes(Uint8List.fromList(png)), content);
    });

    test('returns null for images without a QR code', () {
      expect(qfDecodeQrImageBytes(Uint8List.fromList([1, 2, 3])), isNull);
      final blank = Int32List(100 * 100)..fillRange(0, 100 * 100, 0xFFFFFFFF);
      expect(qfDecodeQrPixels(100, 100, blank), isNull);
    });
  });

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
      QfUpdateService.manifestFetcherForTest = () async =>
          manifest(latest: '0.9.1');
      final check = await QfUpdateService.check('0.9.1');
      expect(check.decision, QfUpdateDecision.none);
      expect(check.manifestFresh, isTrue);
    });

    test('background retry re-judges immediately on success', () async {
      var fresh = false;
      QfUpdateService.manifestFetcherForTest = () async =>
          fresh ? manifest(maintenance: true) : null;
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

  group('avatar chain (user report: upload shows no change)', () {
    final pngA = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final pngB = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );

    test('mime normalization follows the server whitelist', () {
      expect(qfAvatarMimeFor('a.png', 'image/png'), 'image/png');
      expect(qfAvatarMimeFor('a.jpg', 'image/jpg'), 'image/jpeg');
      expect(qfAvatarMimeFor('a.jpg', 'image/bmp'), 'image/jpeg');
      expect(qfAvatarMimeFor('a.PNG', null), 'image/png');
      expect(qfAvatarMimeFor('a.jfif', 'image/bmp'), '');
      expect(qfAvatarMimeFor('a.webp', ''), 'image/webp');
    });

    test('uploaded avatar busts stale-stamp cache entries', () {
      const userId = 91001;
      qfStoreCachedAvatar(userId, 100, pngA);
      expect(qfCachedAvatar(userId, 100), pngA);
      qfApplyUploadedAvatar(userId, 200, pngB);
      expect(qfEffectiveAvatarStamp(userId, 100), 200);
      expect(qfCachedAvatar(userId, 100), pngB);
      expect(qfCachedAvatar(userId, 200), pngB);
      expect(qfCachedAvatar(userId, null), pngB);
    });

    testWidgets('mounted avatar widget swaps to the uploaded image', (
      tester,
    ) async {
      const userId = 91002;
      qfStoreCachedAvatar(userId, 100, pngA);
      final session = QfSessionController();
      Widget host() => MaterialApp(
        home: Scaffold(
          body: QfAvatarImage(
            session: session,
            userId: userId,
            name: '测',
            avatarUpdatedAt: 100,
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pump();
      mui.CircleAvatar avatar = tester.widget(find.byType(mui.CircleAvatar));
      expect((avatar.backgroundImage as MemoryImage).bytes, pngA);
      qfApplyUploadedAvatar(userId, 200, pngB);
      await tester.pumpWidget(host());
      await tester.pump();
      avatar = tester.widget(find.byType(mui.CircleAvatar));
      expect((avatar.backgroundImage as MemoryImage).bytes, pngB);
    });
  });
}
