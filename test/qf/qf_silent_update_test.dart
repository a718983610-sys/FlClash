import 'dart:io';

import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

QfReleaseManifest _manifest({bool silent = false}) {
  return QfReleaseManifest.fromJson({
    'latestVersion': '2.0.1',
    'retiredBelowVersion': '0.0.0',
    'maintenance': false,
    if (silent) 'silentUpdate': true,
    'serverBaseUrl': 'https://example.invalid',
    'googleClientId': 'top-level-id',
    'platforms': const <String, dynamic>{},
  });
}

QfUpdateCheck _check({
  QfUpdateDecision decision = QfUpdateDecision.minor,
  bool fresh = true,
  bool silent = true,
}) {
  return QfUpdateCheck(
    decision: decision,
    manifest: _manifest(silent: silent),
    notes: '',
    downloadUrl: 'https://example.invalid/app.apk',
    latestVersion: '2.0.1',
    manifestFresh: fresh,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    QfUpdateService.isAndroidForTest = true;
    QfUpdateService.isWindowsForTest = false;
  });

  tearDown(() {
    QfUpdateService.isAndroidForTest = null;
    QfUpdateService.isWindowsForTest = null;
    QfUpdateService.appChannelInvokerForTest = null;
  });

  group('silent attempt decision', () {
    test('silent minor on Android with a fresh manifest attempts', () {
      expect(
        QfUpdateService.shouldAttemptSilent(_check(), isAndroid: true),
        isTrue,
      );
    });

    test('force never goes silent', () {
      expect(
        QfUpdateService.shouldAttemptSilent(
          _check(decision: QfUpdateDecision.force),
          isAndroid: true,
        ),
        isFalse,
      );
    });

    test('a stale session-cached manifest never goes silent', () {
      expect(
        QfUpdateService.shouldAttemptSilent(
          _check(fresh: false),
          isAndroid: true,
        ),
        isFalse,
      );
    });

    test('an unflagged manifest stays on the normal path', () {
      expect(
        QfUpdateService.shouldAttemptSilent(
          _check(silent: false),
          isAndroid: true,
        ),
        isFalse,
      );
    });

    test('silent updates are Android-only', () {
      expect(
        QfUpdateService.shouldAttemptSilent(_check(), isAndroid: false),
        isFalse,
      );
    });

    test('a running core defers the attempt to the dialog path', () {
      expect(
        QfUpdateService.shouldAttemptSilent(
          _check(),
          isAndroid: true,
          coreRunning: true,
        ),
        isFalse,
      );
      expect(
        QfUpdateService.shouldAttemptSilent(
          _check(),
          isAndroid: true,
          coreRunning: false,
        ),
        isTrue,
      );
    });
  });

  group('one automatic attempt per version', () {
    test('the first claim wins and later claims are refused', () async {
      expect(await QfUpdateService.claimSilentAttempt('2.0.1'), isTrue);
      expect(await QfUpdateService.claimSilentAttempt('2.0.1'), isFalse);
      expect(await QfUpdateService.claimSilentAttempt('2.0.2'), isTrue);
      expect(await QfUpdateService.claimSilentAttempt(''), isFalse);
    });
  });

  group('silent install channel mapping', () {
    late Directory dir;
    late File apk;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('qf_silent_test');
      apk = File('${dir.path}/app.apk');
      await apk.writeAsBytes([1, 2, 3]);
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('native outcomes map onto the Dart outcomes', () async {
      final seen = <String>[];
      QfUpdateService.appChannelInvokerForTest = (method, args) async {
        seen.add(method);
        expect((args as Map?)?['path'], apk.path);
        return 'success';
      };
      expect(
        await QfUpdateService.installSilently(apk),
        QfSilentInstallOutcome.success,
      );
      expect(seen, ['installApkSilent']);

      QfUpdateService.appChannelInvokerForTest = (_, _) async =>
          'pending_user_action';
      expect(
        await QfUpdateService.installSilently(apk),
        QfSilentInstallOutcome.pendingUserAction,
      );

      QfUpdateService.appChannelInvokerForTest = (_, _) async =>
          'needs_permission';
      expect(
        await QfUpdateService.installSilently(apk),
        QfSilentInstallOutcome.needsPermission,
      );

      QfUpdateService.appChannelInvokerForTest = (_, _) async => 'failed';
      expect(
        await QfUpdateService.installSilently(apk),
        QfSilentInstallOutcome.failed,
      );

      QfUpdateService.appChannelInvokerForTest = (_, _) async => null;
      expect(
        await QfUpdateService.installSilently(apk),
        QfSilentInstallOutcome.failed,
      );
    });

    test('a missing file fails without touching the channel', () async {
      var called = false;
      QfUpdateService.appChannelInvokerForTest = (_, _) async {
        called = true;
        return 'success';
      };
      expect(
        await QfUpdateService.installSilently(File('${dir.path}/nope.apk')),
        QfSilentInstallOutcome.failed,
      );
      expect(called, isFalse);
    });
  });

  group('silent-first fallback chain', () {
    late Directory dir;
    late File apk;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('qf_silent_first_test');
      apk = File('${dir.path}/app.apk');
      await apk.writeAsBytes([1, 2, 3]);
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('a silent success never opens the ordinary installer', () async {
      final methods = <String>[];
      QfUpdateService.appChannelInvokerForTest = (method, _) async {
        methods.add(method);
        return 'success';
      };
      expect(
        await QfUpdateService.installSilentFirst(apk),
        QfSilentFirstOutcome.installed,
      );
      expect(methods, ['installApkSilent']);
    });

    test(
      'a pending user action falls back to the ordinary installer',
      () async {
        final methods = <String>[];
        QfUpdateService.appChannelInvokerForTest = (method, _) async {
          methods.add(method);
          return method == 'installApkSilent'
              ? 'pending_user_action'
              : 'launched';
        };
        expect(
          await QfUpdateService.installSilentFirst(apk),
          QfSilentFirstOutcome.launched,
        );
        expect(methods, ['installApkSilent', 'installApk']);
      },
    );

    test('a permission refusal surfaces from the fallback', () async {
      QfUpdateService.appChannelInvokerForTest = (method, _) async =>
          'needs_permission';
      expect(
        await QfUpdateService.installSilentFirst(apk),
        QfSilentFirstOutcome.needsPermission,
      );
    });

    test('a silent failure with a dead fallback reports failure', () async {
      QfUpdateService.appChannelInvokerForTest = (_, _) async => 'failed';
      expect(
        await QfUpdateService.installSilentFirst(apk),
        QfSilentFirstOutcome.failed,
      );
    });
  });
}
