import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'qf_session.dart';

final qfSessionProvider = Provider<QfSessionController>(
  (ref) => QfSessionController(),
);

class QfRuntime {
  static String googleClientId = '';
  static String googleWebClientId = '';
  static String appVersion = '';
}
