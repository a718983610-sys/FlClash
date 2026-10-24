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

/// Whether the latest system-proxy apply actually took effect, so a
/// failed apply surfaces in the UI instead of only in the log.
enum QfTakeoverStatus { unknown, ok, failed }

class QfTakeoverNotifier extends Notifier<QfTakeoverStatus> {
  @override
  QfTakeoverStatus build() => QfTakeoverStatus.unknown;

  void report(bool ok) {
    state = ok ? QfTakeoverStatus.ok : QfTakeoverStatus.failed;
  }

  void reset() {
    state = QfTakeoverStatus.unknown;
  }
}

final qfTakeoverStatusProvider =
    NotifierProvider<QfTakeoverNotifier, QfTakeoverStatus>(
      QfTakeoverNotifier.new,
    );
