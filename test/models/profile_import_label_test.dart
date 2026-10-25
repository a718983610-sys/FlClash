import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_paths.dart';

void main() {
  group('profile-title header parsing', () {
    test('base64 prefix decodes the merged subscription title', () {
      expect(getTitleForProfileTitleHeader('base64:QVdT'), 'AWS');
    });

    test('base64 prefix decodes UTF-8 titles', () {
      expect(getTitleForProfileTitleHeader('base64:5rWL6K+V'), '测试');
    });

    test('plain title passes through unchanged', () {
      expect(
        getTitleForProfileTitleHeader('My Subscription'),
        'My Subscription',
      );
    });

    test('percent-encoded plain title decodes', () {
      expect(getTitleForProfileTitleHeader('My%20Sub'), 'My Sub');
    });

    test('absent or undecodable values count as absent', () {
      expect(getTitleForProfileTitleHeader(null), isNull);
      expect(getTitleForProfileTitleHeader(''), isNull);
      expect(getTitleForProfileTitleHeader('base64:!!!'), isNull);
    });
  });

  group('import label priority', () {
    test('base64 profile-title names the import without a disposition', () {
      expect(qfImportLabel(profileTitle: 'base64:QVdT'), 'AWS');
    });

    test('content-disposition still wins over profile-title', () {
      expect(
        qfImportLabel(
          disposition: 'attachment; filename="provider.yaml"',
          profileTitle: 'base64:QVdT',
        ),
        'provider.yaml',
      );
    });

    test('no naming headers falls back (null)', () {
      expect(qfImportLabel(), isNull);
      expect(qfImportLabel(disposition: 'attachment'), isNull);
    });
  });

  group('update() naming over a real socket', () {
    HttpOverrides? testOverrides;
    late HttpServer server;
    late Map<String, String> responseHeaders;

    setUpAll(() async {
      await useAppPaths(Directory.systemTemp.createTempSync('qf-import-'));
      // The shared bundle may leave the global request attached to a
      // disposed container; give it a reader that outlives this file.
      request.attach(ProviderContainer().read);
      testOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) {
          responseHeaders.forEach(request.response.headers.set);
          request.response.write('proxies: []\n');
          unawaited(request.response.close());
        }),
      );
    });

    tearDownAll(() async {
      await server.close(force: true);
      HttpOverrides.global = testOverrides;
    });

    setUp(() {
      responseHeaders = {};
    });

    String url() => 'http://${server.address.host}:${server.port}/sub/tok';

    test('a fresh import takes the profile-title name', () async {
      responseHeaders = {'profile-title': 'base64:QVdT57uE'};
      final updated = await Profile.normal(
        url: url(),
      ).update(validate: (_, _) async => '');
      expect(updated.label, 'AWS组');
    });

    test('a fresh import takes the content-disposition name', () async {
      responseHeaders = {
        'content-disposition': 'attachment; filename="provider.yaml"',
        'profile-title': 'base64:QVdT57uE',
      };
      final updated = await Profile.normal(
        url: url(),
      ).update(validate: (_, _) async => '');
      expect(updated.label, 'provider.yaml');
    });

    test(
      'a fresh import without naming headers falls back to the host',
      () async {
        final updated = await Profile.normal(
          url: url(),
        ).update(validate: (_, _) async => '');
        expect(updated.label, server.address.host);
      },
    );

    test(
      'a profile stuck with the host fallback adopts the server name',
      () async {
        responseHeaders = {'profile-title': 'base64:QVdT57uE'};
        final profile = Profile.normal(
          url: url(),
        ).copyWith(label: server.address.host);
        final updated = await profile.update(validate: (_, _) async => '');
        expect(updated.label, 'AWS组');
      },
    );

    test('a user-chosen name is never overridden by the server', () async {
      responseHeaders = {'profile-title': 'base64:QVdT57uE'};
      final profile = Profile.normal(url: url()).copyWith(label: '我的订阅');
      final updated = await profile.update(validate: (_, _) async => '');
      expect(updated.label, '我的订阅');
    });
  });
}
