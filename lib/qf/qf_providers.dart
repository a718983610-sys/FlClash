import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'qf_session.dart';

final qfSessionProvider = Provider<QfSessionController>(
  (ref) => QfSessionController(),
);

/// True while the applied profile declares no proxies and no proxy
/// providers: the core runs it direct-only and the dashboard shows the
/// red empty-subscription notice instead of refusing to start.
class QfDirectOnlyProfileNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void update(bool value) {
    state = value;
  }
}

final qfDirectOnlyProfileProvider =
    NotifierProvider<QfDirectOnlyProfileNotifier, bool>(
      QfDirectOnlyProfileNotifier.new,
    );

class QfRuntime {
  static String googleClientId = '';
  static String googleWebClientId = '';
  static String appVersion = '';
}
