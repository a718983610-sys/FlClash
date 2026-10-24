import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../application.dart';
import '../providers/providers.dart';
import '../views/about.dart';
import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_http_client.dart';
import 'qf_pages.dart';
import 'qf_pages2.dart';
import 'qf_providers.dart';
import 'qf_recovery.dart';
import 'qf_session.dart';
import 'qf_signal.dart';
import 'qf_update.dart';
import 'qf_update_notify.dart';
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
  bool _regionQueued = false;
  bool _banQueued = false;
  bool _frozenQueued = false;
  bool _minorQueued = false;
  bool _dialogBusy = false;
  QfUpdateCheck? _minorCheck;
  String _pendingBanNotice = '';
  String _pendingBanReason = '';
  String _pendingBanAccount = '';
  String _pendingFrozenNotice = '';
  String _pendingFrozenAccount = '';
  int? _pendingFrozenAt;

  QfSessionController get _session => ref.read(qfSessionProvider);

  Timer? _updateNotifyTimer;
  Timer? _manifestTimer;

  bool get _blockingActive {
    final decision = _check?.decision ?? QfUpdateDecision.none;
    return decision == QfUpdateDecision.maintenance ||
        decision == QfUpdateDecision.retired ||
        decision == QfUpdateDecision.force ||
        (_session.isGuest && _session.guestExhausted);
  }

  @override
  void initState() {
    super.initState();
    QfUpdateNotify.registerTapHandler(() {
      if (mounted) QfUpdateFlow.runManualCheck(context);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _updateNotifyTimer?.cancel();
    _manifestTimer?.cancel();
    super.dispose();
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
    QfHttpClient.coreRunningProbe = () {
      try {
        return ref.read(isStartProvider) && !ref.read(suspendProvider);
      } catch (_) {
        return false;
      }
    };
    try {
      QfHttpClient.corePort = ref.read(
        patchClashConfigProvider.select((state) => state.mixedPort),
      );
    } catch (_) {}
    session.trafficTotalFn = () {
      final traffic = ref.read(totalTrafficProvider);
      return (traffic.up + traffic.down).toInt();
    };
    session.onGuestExhaustedFn = _stopCore;
    session.onForceDisconnectFn = _stopCore;
    session.onAuthenticatedFn = () => QfSignalManager.ensureInstalled(session);
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
      QfRuntime.googleWebClientId = manifest.googleClientId;
      if (session.isGuest) {
        await session.refreshGuestUsage();
      }
    }
    if (session.isGuest && session.guestExhausted) {
      await _stopCore();
    }
    if (QfSessionController.startupHeldForQuota) {
      QfSessionController.startupHeldForQuota = false;
      if (!(session.isGuest && session.guestExhausted)) {
        await ref.read(setupActionProvider.notifier).initStatus();
      }
    }
    await _checkRegion();
    session.startHeartbeat();
    QfUpdateService.onFreshCheck = (_) => unawaited(_recheckManifest());
    final check = await QfUpdateService.check(QfRuntime.appVersion);
    if (!mounted) return;
    setState(() {
      _check = check;
      _booted = true;
    });
    _manifestTimer?.cancel();
    _manifestTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_recheckManifest()),
    );
    unawaited(QfUpdateNotify.registerBackgroundChecks());
    unawaited(QfUpdateNotify.requestPermissionOnce());
    if (Platform.isWindows) {
      _updateNotifyTimer = Timer.periodic(const Duration(hours: 6), (_) {
        unawaited(QfUpdateNotify.runBackgroundCheckNow());
      });
    }
    if ((check.decision == QfUpdateDecision.minor ||
            check.decision == QfUpdateDecision.force) &&
        check.manifest != null) {
      unawaited(QfUpdateNotify.markNotified(check.manifest!.latestVersion));
    }
    if (check.decision == QfUpdateDecision.none ||
        check.decision == QfUpdateDecision.minor) {
      final fromNotification = await QfUpdateNotify.launchedFromNotification();
      if (fromNotification && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) QfUpdateFlow.runManualCheck(context);
        });
      }
    }
    if (check.decision == QfUpdateDecision.minor &&
        !_minorShown &&
        !await _minorShownToday()) {
      _minorShown = true;
      _minorCheck = check;
      _minorQueued = true;
      _scheduleDialogs();
    }
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }

  Future<bool> _minorShownToday() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('qf_minor_shown_date') == _todayKey();
  }

  Future<void> _markMinorShownToday() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qf_minor_shown_date', _todayKey());
  }

  Future<void> _recheckManifest() async {
    if (!mounted || !_booted) return;
    final check = await QfUpdateService.check(QfRuntime.appVersion);
    if (!mounted || check.manifest == null) return;
    _session.applyServerBaseUrl(check.manifest!.serverBaseUrl);
    final previous = _check?.decision ?? QfUpdateDecision.none;
    if (check.decision == previous) return;
    setState(() => _check = check);
    if (check.decision == QfUpdateDecision.maintenance ||
        check.decision == QfUpdateDecision.retired ||
        check.decision == QfUpdateDecision.force) {
      await _stopCore();
    }
    if (check.decision == QfUpdateDecision.minor &&
        !_minorShown &&
        !await _minorShownToday()) {
      _minorShown = true;
      _minorCheck = check;
      _minorQueued = true;
      _scheduleDialogs();
    }
  }

  void _scheduleDialogs() {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_drainDialogs()),
    );
  }

  Future<void> _drainDialogs() async {
    if (_dialogBusy || !mounted || _blockingActive) return;
    if (_regionQueued) {
      _regionQueued = false;
      await _presentRegionDialog();
    } else if (_banQueued) {
      _banQueued = false;
      await _presentBanDialog();
    } else if (_frozenQueued) {
      _frozenQueued = false;
      await _presentFrozenDialog();
    } else if (_minorQueued) {
      _minorQueued = false;
      await _presentMinorDialog();
    } else {
      return;
    }
    if (mounted) _scheduleDialogs();
  }

  Future<void> _presentRegionDialog() async {
    final message = _regionMessage;
    if (message == null) return;
    _dialogBusy = true;
    var shown = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          shown = true;
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
    } catch (_) {
      shown = false;
    } finally {
      _dialogBusy = false;
    }
    if (shown) {
      _regionShown = true;
      _regionMessage = null;
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setString(
        'qf_region_last_shown',
        '${now.year}-${now.month}-${now.day}',
      );
    }
  }

  Future<void> _presentBanDialog() async {
    final notice = _pendingBanNotice;
    if (notice.isEmpty) return;
    final reason = _pendingBanReason;
    final account = _pendingBanAccount;
    final session = _session;
    _dialogBusy = true;
    try {
      await showDialog<void>(
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
                QfBanAppealEntry(
                  session: session,
                  identifier: account,
                  credential: null,
                  onAppeal: () {
                    Navigator.of(dialogContext).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => QfAppealPage(
                          serverBaseUrl: session.serverBaseUrl,
                          initialAccount: account,
                          permanent: notice.contains('永久封禁'),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('我知道了'),
              ),
            ],
          );
        },
      );
    } catch (_) {
    } finally {
      _dialogBusy = false;
      _pendingBanNotice = '';
      _pendingBanReason = '';
      _pendingBanAccount = '';
    }
  }

  Future<void> _presentFrozenDialog() async {
    final notice = _pendingFrozenNotice;
    if (notice.isEmpty) return;
    final account = _pendingFrozenAccount;
    final frozenAt = _pendingFrozenAt;
    _dialogBusy = true;
    try {
      final action = await qfShowFrozenDialog(
        context,
        message: notice,
        frozenAt: frozenAt,
      );
      if (mounted) {
        await qfHandleFrozenAction(
          context,
          session: _session,
          action: action,
          account: account,
        );
      }
    } catch (_) {
    } finally {
      _dialogBusy = false;
      _pendingFrozenNotice = '';
      _pendingFrozenAccount = '';
      _pendingFrozenAt = null;
    }
  }

  Future<void> _presentMinorDialog() async {
    final check = _minorCheck;
    if (check == null) return;
    await _markMinorShownToday();
    _dialogBusy = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (_) => QfMinorUpdateDialog(result: check),
      );
      if (accepted == true && mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              AlertDialog(content: QfUpdateDownloadPanel(result: check)),
        );
      }
    } catch (_) {
    } finally {
      _dialogBusy = false;
      _minorCheck = null;
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
          _regionMessage = message;
        }
      }
    } catch (_) {}
  }

  void _queueRegionDialog() {
    if (_regionMessage == null || _regionShown || _regionQueued) return;
    _regionQueued = true;
    _scheduleDialogs();
  }

  void _queueBanDialog(
    String notice,
    String reason,
    String account,
    void Function() consume,
  ) {
    if (_banQueued || _pendingBanNotice.isNotEmpty) {
      consume();
      return;
    }
    _pendingBanNotice = notice;
    _pendingBanReason = reason;
    _pendingBanAccount = account;
    consume();
    _banQueued = true;
    _scheduleDialogs();
  }

  void _queueFrozenDialog(
    String notice,
    String account,
    int? frozenAt,
    void Function() consume,
  ) {
    if (_frozenQueued || _pendingFrozenNotice.isNotEmpty) {
      consume();
      return;
    }
    _pendingFrozenNotice = notice;
    _pendingFrozenAccount = account;
    _pendingFrozenAt = frozenAt;
    consume();
    _frozenQueued = true;
    _scheduleDialogs();
  }

  void _openAbout() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AboutView()));
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
          return const Scaffold(body: Center(child: CommonCircleLoading()));
        }
        if (!_blockingActive &&
            (_regionQueued || _banQueued || _frozenQueued || _minorQueued)) {
          _scheduleDialogs();
        }
        final decision = _check?.decision ?? QfUpdateDecision.none;
        if (decision == QfUpdateDecision.maintenance ||
            decision == QfUpdateDecision.retired ||
            decision == QfUpdateDecision.force) {
          final text = qfUpdateBlockText(decision);
          return QfBlockingPage(
            title: text[0],
            body: text[1],
            update: decision == QfUpdateDecision.maintenance ? null : _check,
          );
        }
        if (session.mode == QfMode.entry) {
          _queueRegionDialog();
          final notice = session.banNotice;
          if (notice != null) {
            _queueBanDialog(
              notice,
              session.banReason,
              session.banAccount,
              session.consumeBanNotice,
            );
          }
          final frozenNotice = session.frozenNotice;
          if (frozenNotice != null) {
            _queueFrozenDialog(
              frozenNotice,
              session.frozenAccount,
              session.frozenAt,
              session.consumeFrozenNotice,
            );
          }
          return QfEntryPage(
            session: session,
            onAbout: _openAbout,
            onCheckUpdate: () => QfUpdateFlow.runManualCheck(context),
            onAgreement: _openAgreement,
          );
        }
        _queueRegionDialog();
        if (session.isGuest && session.guestExhausted) {
          return Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              Positioned.fill(
                child: ColoredBox(
                  color: context.colorScheme.scrim.withValues(alpha: 0.54),
                  child: Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(scaffoldBackgroundColor: Colors.transparent),
                    child: QfBlockingPage(
                      title: QfCopy.quotaTitle,
                      body: QfCopy.quotaBody,
                      onSwitchAccount: () => session.exitGuestToEntry(),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: SafeArea(
                  child: Center(
                    child: Material(
                      type: MaterialType.transparency,
                      child: TextButton(
                        onPressed: _openAbout,
                        style: TextButton.styleFrom(
                          backgroundColor: context.colorScheme.surface,
                          foregroundColor: context.colorScheme.onSurface,
                        ),
                        child: const Text('关于'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return widget.child;
      },
    );
  }
}
