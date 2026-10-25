import 'package:fl_clash/common/http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settle resolves without a prior begin', () async {
    await FlClashHttpOverrides.settleTrustCoreRoots();
  });

  test('begin is idempotent and settle still resolves', () async {
    FlClashHttpOverrides.beginTrustCoreRoots();
    FlClashHttpOverrides.beginTrustCoreRoots();
    await FlClashHttpOverrides.settleTrustCoreRoots();
  });
}
