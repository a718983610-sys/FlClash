import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
