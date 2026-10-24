import 'package:fl_clash/qf/qf_forum.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  group('qfUserIsOwner', () {
    test('reads the server user-view field', () {
      expect(qfUserIsOwner({'isOwner': true}), isTrue);
      expect(qfUserIsOwner({'is_owner': 1}), isTrue);
      expect(qfUserIsOwner({'is_owner': true}), isTrue);
    });

    test('reads the public-view badge field the server actually sends', () {
      expect(qfUserIsOwner({'ownerBadge': 'green'}), isTrue);
      expect(qfUserIsOwner({'ownerBadge': null}), isFalse);
      expect(qfUserIsOwner({'ownerBadge': 'none'}), isFalse);
    });

    test('non-owners and missing data stay unbadged', () {
      expect(qfUserIsOwner({'isOwner': false}), isFalse);
      expect(qfUserIsOwner({'is_owner': 0}), isFalse);
      expect(qfUserIsOwner({'nickname': '路人'}), isFalse);
      expect(qfUserIsOwner(null), isFalse);
      expect(qfUserIsOwner(const {}), isFalse);
    });
  });

  group('learned owner id (views that carry only a userId)', () {
    setUp(qfResetLearnedOwnerUserId);
    tearDown(qfResetLearnedOwnerUserId);

    test('nothing is badged before any badged view is seen', () {
      expect(qfIsOwnerUserId(15), isFalse);
      expect(
        qfForumAuthorIsOwner({
          'author': {'userId': 15, 'name': '站长'},
        }),
        isFalse,
      );
    });

    test('a badged profile view teaches the owner id', () {
      qfLearnOwnerFromView({
        'userId': 15,
        'nickname': '站长',
        'ownerBadge': 'green',
      });
      expect(qfIsOwnerUserId(15), isTrue);
      expect(qfIsOwnerUserId(16), isFalse);
      expect(qfIsOwnerUserId(null), isFalse);
      expect(
        qfForumAuthorIsOwner({
          'author': {'userId': 15, 'name': '站长'},
        }),
        isTrue,
      );
      expect(
        qfForumAuthorIsOwner({
          'author': {'userId': 16, 'name': '路人'},
        }),
        isFalse,
      );
    });

    test('learning scans nested lists and ignores unbadged views', () {
      qfLearnOwnerFromView({
        'friends': [
          {'userId': 9, 'ownerBadge': null},
        ],
      });
      expect(qfIsOwnerUserId(9), isFalse);
      qfLearnOwnerFromView({
        'data': {
          'user': {'id': 15, 'ownerBadge': 'green'},
        },
      });
      expect(qfIsOwnerUserId(15), isTrue);
    });
  });

  group('QfBadgedName', () {
    testWidgets('owner name carries the green badge', (tester) async {
      await tester.pumpWidget(
        const TestApp(child: QfBadgedName(name: '站长本人', isOwner: true)),
      );
      expect(find.text('站长本人'), findsOneWidget);
      expect(find.text('站长'), findsOneWidget);
      expect(find.byType(QfOwnerBadge), findsOneWidget);
    });

    testWidgets('plain name renders no badge', (tester) async {
      await tester.pumpWidget(
        const TestApp(child: QfBadgedName(name: '普通用户', isOwner: false)),
      );
      expect(find.text('普通用户'), findsOneWidget);
      expect(find.text('站长'), findsNothing);
      expect(find.byType(QfOwnerBadge), findsNothing);
    });
  });
}
