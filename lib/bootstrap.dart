import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/boot_guard.dart';
import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/launch.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/common/tray.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/disclaimer.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/palettes/tonal_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';

class Bootstrap {
  static Bootstrap? _instance;

  Bootstrap._internal();

  factory Bootstrap() {
    _instance ??= Bootstrap._internal();
    return _instance!;
  }

  BootDecision _bootDecision = const BootDecision();

  Future<ProviderContainer> init(int version) async {
    globalState.appEnv = const String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'pre',
    );
    windowPort = window;
    trayPort = appTray;
    navigationPort = navigation;
    // Display-only inputs stay off the pre-first-frame serial chain: the
    // fetches start now but complete whenever the platform answers, and
    // their consumers (theme seeds, version label, profile UA) all read
    // after the first frame.
    final dynamicColor = _initDynamicColor();
    final packageInfo = PackageInfo.fromPlatform();
    return _initData(version, dynamicColor, packageInfo);
  }

  Future<DynamicColorSeeds> _initDynamicColor() async {
    TonalPalette? primaryPalette;
    Color? accentColor;
    try {
      primaryPalette = await _getSystemPrimaryPalette();
    } catch (error) {
      commonPrint.log(
        'Failed to get core palette: $error',
        logLevel: LogLevel.warning,
      );
    }
    try {
      accentColor = await DynamicColorPlugin.getAccentColor();
    } catch (error) {
      commonPrint.log(
        'Failed to get accent color: $error',
        logLevel: LogLevel.warning,
      );
    }
    return (
      lightSeed: primaryPalette != null ? Color(primaryPalette.get(40)) : null,
      darkSeed: primaryPalette != null ? Color(primaryPalette.get(80)) : null,
      accentColor: accentColor ?? const Color(defaultPrimaryColor),
    );
  }

  /// Runs before migration and the database: a copy started from another
  /// install path gets past the platform's single-instance hand-off.
  Future<void> _claimDataDirectory() async {
    if (!system.isDesktop || await singleInstanceLock.acquire()) {
      return;
    }
    commonPrint.log('another instance owns the data directory, exiting');
    exit(0);
  }

  Future<TonalPalette?> _getSystemPrimaryPalette() async {
    final raw = await DynamicColorPlugin.channel.invokeMethod<List<dynamic>>(
      DynamicColorPlugin.methodName,
    );
    if (raw == null || raw.length < TonalPalette.commonSize) {
      return null;
    }
    return TonalPalette.fromList(
      raw.sublist(0, TonalPalette.commonSize).cast<int>(),
    );
  }

  Future<ProviderContainer> _initData(
    int version,
    Future<DynamicColorSeeds> dynamicColor,
    Future<PackageInfo> packageInfo,
  ) async {
    await _claimDataDirectory();
    unawaited(() async {
      try {
        globalState.packageInfo = await packageInfo;
      } catch (_) {}
    }());
    var config = await migration.run();
    final bootFacts = await packageInfo
        .then<(int, int?)>(
          (info) => (
            int.tryParse(info.buildNumber) ?? 0,
            info.updateTime?.millisecondsSinceEpoch,
          ),
          onError: (_) => (0, null),
        )
        .timeout(const Duration(seconds: 2), onTimeout: () => (0, null));
    _bootDecision = await bootGuard.evaluate(
      profileId: config.currentProfileId,
      appVersion: bootFacts.$1,
      lastUpdateAt: bootFacts.$2,
    );
    if (_bootDecision.recovery == BootRecovery.clearProfile) {
      config = config.copyWith(currentProfileId: null);
      await preferences.saveConfig(config);
    }
    final patchClashConfig = config.patchClashConfig.ensureControllerSecret();
    if (patchClashConfig != config.patchClashConfig) {
      config = config.copyWith(patchClashConfig: patchClashConfig);
      await preferences.saveConfig(config);
    }
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxRequestsLength),
      logs: FixedList(maxLogsLength),
      traffics: FixedList(trafficSampleLength),
      totalTraffic: const Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    final configOverrides = buildConfigOverrides(config);
    final container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    globalState.container = container;
    unawaited(() async {
      try {
        final seeds = await dynamicColor;
        container
            .read(dynamicColorProvider.notifier)
            .seed(
              lightSeed: seeds.lightSeed,
              darkSeed: seeds.darkSeed,
              accentColor: seeds.accentColor,
            );
      } catch (_) {}
    }());
    final profiles = await database.profilesDao.query().get();
    container.read(profilesProvider.notifier).reorder(profiles);
    await AppLocalizations.load(
      getLocaleForString(config.appSettingProps.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    await window?.init(version, config.windowProps);
    if (system.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    return container;
  }

  Future<void> attach() async {
    if (globalState.isAttach == true) {
      return;
    }
    await _initApp();
    globalState.isAttach = true;
  }

  ProviderContainer get _container => globalState.container;

  Future<void> _initApp() async {
    await FlClashHttpOverrides.settleTrustCoreRoots();
    unawaited(_container.read(systemActionProvider.notifier).updateTray());
    unawaited(
      _container.read(profilesActionProvider.notifier).autoUpdateProfiles(),
    );
    unawaited(
      autoLaunch?.updateStatus(_container.read(appSettingProvider).autoLaunch),
    );
    if (!_container.read(appSettingProvider).silentLaunch) {
      unawaited(window?.show());
    } else {
      unawaited(window?.hide());
    }
    await _handleFailedPreference();
    if (!await _handlerDisclaimer()) {
      return;
    }
    await _showCrashRecoveryTip();
    await _container.read(coreActionProvider.notifier).startCore();
    if (!_bootDecision.isDegraded) {
      if (await QfSessionController.localGuestQuotaHold()) {
        QfSessionController.startupHeldForQuota = true;
      } else {
        await _container.read(setupActionProvider.notifier).initStatus();
      }
    }
    _container.read(initProvider.notifier).value = true;
    unawaited(_container.read(resourcesActionProvider.notifier).autoUpdate());
    await bootGuard.markRunning();
    unawaited(_container.read(locationPermissionsProvider.notifier).refresh());
  }

  Future<void> _showCrashRecoveryTip() async {
    switch (_bootDecision.recovery) {
      case BootRecovery.none:
        return;
      case BootRecovery.skipAutoSetup:
        await dialogs.showMessage(
          title: currentAppLocalizations.launchInterrupted,
          cancelable: false,
          dismissible: false,
          message: TextSpan(text: currentAppLocalizations.launchInterruptedTip),
        );
      case BootRecovery.clearProfile:
        await dialogs.showMessage(
          title: currentAppLocalizations.crashDetected,
          cancelable: false,
          dismissible: false,
          message: TextSpan(
            text: currentAppLocalizations.crashDetectedTip(_failedProfileLabel),
          ),
        );
    }
  }

  String get _failedProfileLabel {
    final profileId = _bootDecision.failedProfileId;
    if (profileId == null) {
      return '';
    }
    final profile = _container.read(profilesProvider).getProfile(profileId);
    return profile?.label.takeFirstValid(['$profileId']) ?? '$profileId';
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) return;
    final res = await dialogs.showMessage(
      title: currentAppLocalizations.tip,
      message: TextSpan(text: currentAppLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    // Saving here would rewrite the preferences file the user just chose to delete.
    await _container.read(systemActionProvider.notifier).handleExit(false);
  }

  /// Android's exit only finishes the activity, so Dart keeps running after
  /// [SystemAction.handleExit] returns and must not go on to start the app.
  Future<bool> _handlerDisclaimer() async {
    final acceptedVersion = _container.read(
      appSettingProvider.select((state) => state.acceptedDisclaimerVersion),
    );
    if (acceptedVersion >= disclaimerVersion) {
      return true;
    }
    final isDisclaimerAccepted = await requestDisclaimerConsent();
    if (!isDisclaimerAccepted) {
      await _container.read(systemActionProvider.notifier).handleExit();
      return false;
    }
    _container
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(acceptedDisclaimerVersion: disclaimerVersion),
        );
    return true;
  }
}

final bootstrap = Bootstrap();
