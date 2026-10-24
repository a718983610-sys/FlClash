import 'package:fl_clash/qf/qf_pages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  group('qfUserIsOwner', () {
    test('reads the server user-view field', () {
      expect(qfUserIsOwner({'isOwner': true}), isTrue);
      expect(qfUserIsOwner({'is_owner': 1}), isTrue);
      expect(qfUserIsOwner({'is_owner': true}), isTrue);
    });

    test('non-owners and missing data stay unbadged', () {
      expect(qfUserIsOwner({'isOwner': false}), isFalse);
      expect(qfUserIsOwner({'is_owner': 0}), isFalse);
      expect(qfUserIsOwner({'nickname': '路人'}), isFalse);
      expect(qfUserIsOwner(null), isFalse);
      expect(qfUserIsOwner(const {}), isFalse);
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
