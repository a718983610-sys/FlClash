import 'dart:async';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'qf_providers.dart';

enum QfEgressStatus {
  idle,
  checking,
  ok,
  nodeUnreachable,
  handshakeFailed,
  takeoverFailed,
}

class QfEgressState {
  final QfEgressStatus status;

  /// The core's own error text behind a failure verdict, kept for the
  /// diagnostics log; user-facing copy is chosen by status alone.
  final String detail;

  const QfEgressState(this.status, [this.detail = '']);

  static const QfEgressState idle = QfEgressState(QfEgressStatus.idle);
  static const QfEgressState checking = QfEgressState(QfEgressStatus.checking);
  static const QfEgressState ok = QfEgressState(QfEgressStatus.ok);

  @override
  bool operator ==(Object other) =>
      other is QfEgressState &&
      other.status == status &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(status, detail);
}

class QfEgressNotifier extends Notifier<QfEgressState> {
  @override
  QfEgressState build() => QfEgressState.idle;

  void set(QfEgressState value) {
    state = value;
  }
}

final qfEgressStateProvider = NotifierProvider<QfEgressNotifier, QfEgressState>(
  QfEgressNotifier.new,
);

const _handshakeMarkers = [
  'timestamp',
  'too early',
  'too late',
  'clock',
  'skew',
  'handshake',
  'authentication',
  'auth failed',
  'decrypt',
  'cipher',
  'bad key',
  'invalid password',
  'replay',
];

/// Failure verdicts come from the core probe's own error text, never
/// from guessing: handshake/auth-class errors (the family a skewed
/// client clock produces with SS2022) are told apart from a node that
/// simply cannot be reached.
QfEgressStatus qfClassifyProbeFailure({
  required String errorKind,
  required String message,
}) {
  final text = message.toLowerCase();
  if (_handshakeMarkers.any(text.contains)) {
    return QfEgressStatus.handshakeFailed;
  }
  return QfEgressStatus.nodeUnreachable;
}

QfEgressStatus qfCombineEgress({
  required bool probeOk,
  required QfEgressStatus probeFailure,
  required bool takeoverExpected,
  required bool takeoverOk,
}) {
  if (!probeOk) return probeFailure;
  if (takeoverExpected && !takeoverOk) return QfEgressStatus.takeoverFailed;
  return QfEgressStatus.ok;
}

class QfEgressProbe {
  static Future<ProbeResult?> Function(CoreController core)? runnerForTest;

  /// One real request through the tunnel's own routing (empty proxy
  /// name), so the verdict is what user traffic would experience.
  static Future<QfEgressState> run(CoreController core) async {
    try {
      final runner = runnerForTest;
      final result = runner != null
          ? await runner(core)
          : await core.probe(
              const ProbeParams(url: defaultTestUrl, timeout: 8000),
            );
      if (result == null) {
        return const QfEgressState(
          QfEgressStatus.nodeUnreachable,
          'core probe gave no answer',
        );
      }
      final error = (result.error ?? '').trim();
      final message = (result.message ?? '').trim();
      if (error.isEmpty &&
          (result.statusCode == 200 || result.statusCode == 204)) {
        return QfEgressState.ok;
      }
      final failure = qfClassifyProbeFailure(
        errorKind: error,
        message: message,
      );
      final detail = message.isNotEmpty ? message : error;
      commonPrint.log(
        'egress probe failed ($failure): $detail',
        logLevel: LogLevel.warning,
      );
      return QfEgressState(failure, detail);
    } catch (e) {
      return QfEgressState(QfEgressStatus.nodeUnreachable, e.toString());
    }
  }
}

/// Runs the probe once and folds in the system-proxy takeover verdict.
Future<void> qfRunEgressCheck(
  WidgetRef ref, {
  required bool takeoverExpected,
}) async {
  ref.read(qfEgressStateProvider.notifier).set(QfEgressState.checking);
  final core = ref.read(coreHandlerProvider);
  final probe = await QfEgressProbe.run(core);
  final takeover = ref.read(qfTakeoverStatusProvider);
  final combined = qfCombineEgress(
    probeOk: probe.status == QfEgressStatus.ok,
    probeFailure: probe.status,
    takeoverExpected: takeoverExpected,
    takeoverOk: takeover != QfTakeoverStatus.failed,
  );
  ref
      .read(qfEgressStateProvider.notifier)
      .set(QfEgressState(combined, probe.detail));
}
