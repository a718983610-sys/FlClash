import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:shared_preferences/shared_preferences.dart';

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
  String? _regionMessage;
  bool _regionShown = false;

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
    await _checkRegion();
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

  Future<void> _checkRegion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final today = '${now.year}-${now.month}-${now.day}';
      if (prefs.getString('qf_region_last_shown') == today) return;
      final data = await QfHttp.send(
        'GET',
        '${_session.serverBaseUrl}/region/status',
      );
      if (data['restricted'] == true) {
        final message = (data['message'] ?? '').toString();
        if (message.isNotEmpty) {
          await prefs.setString('qf_region_last_shown', today);
          _regionMessage = message;
        }
      }
    } catch (_) {}
  }

  void _showRegionDialog() {
    final message = _regionMessage;
    if (message == null || _regionShown) return;
    _regionShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            content: Text(message),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('确认'),
              ),
            ],
          );
        },
      );
    });
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
          _showRegionDialog();
          final notice = session.banNotice;
          if (notice != null) {
            final reason = session.banReason;
            final account = session.banAccount;
            final permanent = notice.contains('永久封禁');
            session.consumeBanNotice();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              showDialog<void>(
                context: context,
                builder: (dialogContext) {
                  return AlertDialog(
                    title: const Text('账户已被封禁'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(notice),
                        if (reason.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('封禁原因：$reason'),
                          ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => QfAppealPage(
                                serverBaseUrl: session.serverBaseUrl,
                                initialAccount: account,
                                permanent: permanent,
                              ),
                            ),
                          );
                        },
                        child: const Text('申诉'),
                      ),
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
        _showRegionDialog();
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
