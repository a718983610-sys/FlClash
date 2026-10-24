import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('qfBanAppealViewFor', () {
    test('unqueried keeps the default appeal entry', () {
      expect(
        qfBanAppealViewFor(loaded: false, status: null, remaining: null),
        QfBanAppealView.goAppeal,
      );
      expect(
        qfBanAppealViewFor(loaded: false, status: null, remaining: 0),
        QfBanAppealView.goAppeal,
      );
    });

    test('no appeal on record with quota left shows the appeal entry', () {
      expect(
        qfBanAppealViewFor(loaded: true, status: null, remaining: 3),
        QfBanAppealView.goAppeal,
      );
    });

    test('no appeal on record with quota spent shows the exhausted text', () {
      expect(
        qfBanAppealViewFor(loaded: true, status: null, remaining: 0),
        QfBanAppealView.exhausted,
      );
    });

    test('pending appeal shows the status only', () {
      expect(
        qfBanAppealViewFor(loaded: true, status: 'pending', remaining: 2),
        QfBanAppealView.pendingOnly,
      );
    });

    test('rejected appeal with quota left offers another application', () {
      expect(
        qfBanAppealViewFor(loaded: true, status: 'rejected', remaining: 2),
        QfBanAppealView.rejectedAgain,
      );
      expect(
        qfBanAppealViewFor(loaded: true, status: 'rejected', remaining: null),
        QfBanAppealView.rejectedAgain,
      );
    });

    test('rejected appeal with quota spent shows the exhausted text', () {
      expect(
        qfBanAppealViewFor(loaded: true, status: 'rejected', remaining: 0),
        QfBanAppealView.exhausted,
      );
    });

    test('approved appeal hides the entry entirely', () {
      expect(
        qfBanAppealViewFor(loaded: true, status: 'approved', remaining: 0),
        QfBanAppealView.hidden,
      );
    });
  });
}
