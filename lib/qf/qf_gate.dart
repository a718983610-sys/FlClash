import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../application.dart';
import '../providers/providers.dart';
import '../views/about.dart';
import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_pages.dart';
import 'qf_pages2.dart';
import 'qf_providers.dart';
import 'qf_session.dart';
import 'qf_update.dart';
import 'qf_version.dart';

class QfSessionGate extends ConsumerStatefulWidget {
  final Widget child;

  const QfSessionGate({super.key, required this.child});

  @override
  ConsumerState<QfSessionGate> createState() => _QfSessionGateState();
}

class _QfSessionGateState extends ConsumerState<QfSessionGate> {
  QfUpdateCheck? _check;
  bool _booted = false;
  bool _minorShown = false;

  QfSessionController get _session => ref.read(qfSessionProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _stopCore() async {
    try {
      await ref.read(setupActionProvider.notifier).setRunning(false);
    } catch (_) {}
  }

  Future<void> _boot() async {
    final session = _session;
    var emulator = false;
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        emulator = !info.isPhysicalDevice;
      }
    } catch (_) {}
    session.isRunningFn = () => ref.read(isStartProvider);
    session.trafficTotalFn = () {
      final traffic = ref.read(totalTrafficProvider);
      return (traffic.up + traffic.down).toInt();
    };
    session.onGuestExhaustedFn = _stopCore;
    try {
      QfRuntime.appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    await session.init(envEmulator: emulator);
    final manifest = await QfManifestService.fetchRemote();
    if (manifest != null) {
      session.applyServerBaseUrl(manifest.serverBaseUrl);
      QfRuntime.googleClientId = manifest.googleClientIdFor(
        QfUpdateService.platformKey,
      );
      if (session.isGuest) {
        await session.refreshGuestUsage();
      }
    }
    if (session.isGuest && session.guestExhausted) {
      await _stopCore();
    }
    session.startHeartbeat();
    final check = await QfUpdateService.check(QfRuntime.appVersion);
    if (!mounted) return;
    setState(() {
      _check = check;
      _booted = true;
    });
    if (check.decision == QfUpdateDecision.minor && !_minorShown) {
      _minorShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (_) => QfMinorUpdateDialog(result: check),
        );
        if (accepted == true && mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
              content: QfUpdateDownloadPanel(result: check),
            ),
          );
        }
      });
    }
  }

  void _openAbout() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AboutView()),
    );
  }

  void _openAgreement() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('QFClash 用户使用协议')),
          body: const SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Text(qfAgreementText),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!_booted || session.mode == QfMode.unknown) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final decision = _check?.decision ?? QfUpdateDecision.none;
        if (decision == QfUpdateDecision.maintenance ||
            decision == QfUpdateDecision.retired ||
            decision == QfUpdateDecision.force) {
          final text = qfUpdateBlockText(decision);
          return QfBlockingPage(
            title: text[0],
            body: text[1],
            update: decision == QfUpdateDecision.maintenance
                ? null
                : _check,
          );
        }
        if (session.mode == QfMode.entry) {
          final notice = session.banNotice;
          if (notice != null) {
            session.consumeBanNotice();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              showDialog<void>(
                context: context,
                builder: (dialogContext) {
                  return AlertDialog(
                    title: const Text('账户已被封禁'),
                    content: Text(notice),
                    actions: [
                      FilledButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('我知道了'),
                      ),
                    ],
                  );
                },
              );
            });
          }
          return QfEntryPage(
            session: session,
            onAbout: _openAbout,
            onCheckUpdate: () => QfUpdateFlow.runManualCheck(context),
            onAgreement: _openAgreement,
          );
        }
        if (session.isGuest && session.guestExhausted) {
          return QfBlockingPage(
            title: QfCopy.quotaTitle,
            body: QfCopy.quotaBody,
            onSwitchAccount: () => session.exitGuestToEntry(),
          );
        }
        return widget.child;
      },
    );
  }
}
