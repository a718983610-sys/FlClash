part of '../action.dart';

enum _SetupTaskResult { completed, handoffToCoreRestart, failed }

typedef _SetupInputs = (
  SetupState,
  PatchClashConfig,
  NetworkProps,
  SetupParams,
);

typedef BuiltProfile = ({
  String yaml,
  String md5,
  ConfigCounts counts,
  SetupBase? base,
  bool hasProviders,
});

class _RunRequest {
  final bool running;
  final bool initialize;
  final DateTime? previousStartTime;

  const _RunRequest({
    required this.running,
    required this.initialize,
    required this.previousStartTime,
  });
}

/// The rollback target when a profile cannot build: the first profile
/// that has not already failed to build in this session.
Profile? qfRollbackCandidate(List<Profile> profiles, Set<int> failedIds) {
  for (final profile in profiles) {
    if (!failedIds.contains(profile.id)) {
      return profile;
    }
  }
  return null;
}

@Riverpod(keepAlive: true)
class SetupAction extends _$SetupAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  Timer? _runtimeTimer;
  final _setupScheduler = SerialTaskScheduler();
  final _listenerScheduler = SerialTaskScheduler();
  _RunRequest? _latestRunRequest;
  DateTime? _startTime;
  _SetupInputs? _appliedInputs;
  var _pendingForceApply = false;
  final _unbuildableProfileIds = <int>{};

  bool get _isRunning => _startTime != null && _startTime!.isBeforeNow;

  @override
  void build() {
    ref.onDispose(_stopRuntimeTicker);
    ref.listen(appVisibleProvider, (_, _) => _syncRuntimeTicker());
    ref.listen(
      appSettingProvider.select((state) => state.showTrayTitle),
      (_, _) => _syncRuntimeTicker(),
    );
  }

  bool get _isTrafficShown =>
      ref.read(appVisibleProvider) ||
      (system.isMacOS &&
          !ref.read(safeModeProvider) &&
          ref.read(appSettingProvider).showTrayTitle);

  SetupParams get _setupParams {
    final selectedMap = ref.read(selectedMapProvider);
    final appSetting = ref.read(appSettingProvider);
    return SetupParams(
      selectedMap: selectedMap,
      testUrl: appSetting.testUrl,
      skipCertVerify: !appSetting.checkCertificate,
    );
  }

  // The selection reaches the Core through changeProxy, not through an apply.
  SetupParams get _appliedParams =>
      _setupParams.copyWith(selectedMap: const {});

  Future<bool> fullSetup() async {
    if (!ref.read(initProvider)) return true;
    ref.read(proxiesActionProvider.notifier).cancelDelayTests();
    ref.read(delayDataSourceProvider.notifier).value = {};
    final setupResult = applyProfile(force: true);
    ref.read(logsProvider.notifier).value = FixedList(maxLogsLength);
    ref.read(requestsProvider.notifier).value = FixedList(maxRequestsLength);
    ref.read(dnsQueriesProvider.notifier).value = FixedList(
      maxDnsQueriesLength,
    );
    ref.read(dnsQueryCountProvider.notifier).value = 0;
    ref.read(requestCountProvider.notifier).value = 0;
    try {
      return await setupResult;
    } catch (e, s) {
      commonPrint.log('fullSetup ===> ${compactError(e)}, $s');
      return false;
    }
  }

  void _setLocalRunning(bool running) {
    _stopRuntimeTicker();
    if (!running) {
      _startTime = null;
      debouncer.cancel(FunctionTag.applyProfile);
      _pendingForceApply = false;
      _updateRunTime();
      return;
    }

    _startTime ??= DateTime.now();
    _updateRunTime();
    _syncRuntimeTicker();
  }

  void _syncRuntimeTicker() {
    if (_startTime == null || !_isTrafficShown) {
      _stopRuntimeTicker();
      return;
    }
    if (_runtimeTimer != null) {
      return;
    }
    _refreshRunningState();
    _runtimeTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshRunningState(),
    );
  }

  void _stopRuntimeTicker() {
    _runtimeTimer?.cancel();
    _runtimeTimer = null;
  }

  void _refreshRunningState() {
    _updateRunTime();
    unawaited(ref.read(commonActionProvider.notifier).updateTraffic());
  }

  void _updateRunTime() {
    final startTime = _startTime;
    ref.read(runTimeProvider.notifier).value = startTime == null
        ? null
        : DateTime.now().millisecondsSinceEpoch -
              startTime.millisecondsSinceEpoch;
  }

  Future<void> _updateStartTime() async {
    _startTime = await service?.getRunTime();
  }

  Future<void> initStatus() async {
    if (!globalState.needInitStatus) {
      return;
    }
    if (system.isAndroid) {
      await _updateStartTime();
    }
    final shouldRun = _isRunning || ref.read(appSettingProvider).autoRun;
    if (shouldRun) {
      await setRunning(true, initialize: true);
    } else {
      await globalState.safeRun(() => applyProfile(force: true));
    }
  }

  Future<bool> setRunning(bool running, {bool initialize = false}) {
    if (running && !initialize && !ref.read(initProvider)) {
      return Future.value(true);
    }

    final request = _RunRequest(
      running: running,
      initialize: running && initialize,
      previousStartTime: _startTime,
    );
    _latestRunRequest = request;
    _setLocalRunning(running);
    if (request.initialize) {
      globalState.needInitStatus = false;
    }
    return running ? _start(request) : _stop(request);
  }

  static const _configLoadFailedMessage = '订阅配置加载失败，请检查订阅是否可用后重试。';

  Future<bool> _start(_RunRequest request) async {
    // Config first, listeners second - always. Starting the listeners
    // before the profile is applied (or letting a failed apply catch up
    // in the background) lets the VPN capture every packet while the Core
    // runs an old or empty config with no usable outbound, which takes
    // the whole device offline while the UI shows a running state.
    if (request.initialize) {
      return _startFromInitialize(request);
    }
    // A start whose inputs the Core already runs needs no re-apply;
    // applyProfile itself does not dedupe forced calls.
    final bool applied;
    if (await _inputsApplied()) {
      applied = true;
    } else {
      try {
        applied = await applyProfile(force: true);
      } catch (_) {
        _rollbackRunning(request);
        rethrow;
      }
    }
    if (!_isCurrent(request)) {
      return true;
    }
    if (!applied) {
      _rollbackRunning(request);
      throw const MessageException(_configLoadFailedMessage);
    }
    try {
      await _startCoreRunning(request);
    } catch (_) {
      _rollbackRunning(request);
      rethrow;
    }
    if (_isCurrent(request) &&
        !ref.read(safeModeProvider) &&
        !(await _appliedConfigHealthy())) {
      await globalState.safeRun(() => setRunning(false));
      throw const MessageException(_configLoadFailedMessage);
    }
    return true;
  }

  /// The boot path: apply, then start, undoing the run through
  /// setRunning(false) when either step fails. initStatus is not
  /// error-wrapped, so failures surface here and in the return value.
  Future<bool> _startFromInitialize(_RunRequest request) async {
    var applied = false;
    try {
      applied = await applyProfile(force: true);
    } catch (_) {
      applied = false;
    }
    if (!applied) {
      if (_isCurrent(request)) {
        await globalState.safeRun(() => setRunning(false));
      }
      return false;
    }
    try {
      await _startCoreRunning(request);
    } catch (_) {
      if (_isCurrent(request)) {
        await globalState.safeRun(() => setRunning(false));
      }
      return false;
    }
    if (_isCurrent(request) &&
        !ref.read(safeModeProvider) &&
        !(await _appliedConfigHealthy())) {
      await globalState.safeRun(() => setRunning(false));
      dialogs.showNotifier(_configLoadFailedMessage, level: MessageLevel.error);
      return false;
    }
    return true;
  }

  /// Whether the config the Core most recently accepted can route at all.
  /// The Core's load report says what it actually kept after tolerant
  /// loading, so it outranks the host-side count of what the profile
  /// declared: a config the Core accepted with usable entries kept must
  /// not be vetoed by a counting mismatch (a profile with nodes but no
  /// declared groups is the known false positive). Provider-backed
  /// profiles legitimately declare no inline nodes, so declared
  /// proxy-providers satisfy the node side. Unknown counts (nothing
  /// applied yet this session) pass: there is nothing to judge.
  Future<bool> _appliedConfigHealthy() async {
    final counts = globalState.lastConfigCounts;
    if (counts == null) return true;
    // An empty subscription declares nothing to route with. The core
    // accepts it as a direct-only config, so it starts and the dashboard
    // banner explains the state; only a config that declared nodes and
    // kept none is refused, as the blackhole guard requires.
    final emptyProfile =
        counts.proxies <= 0 && !globalState.lastConfigHasProviders;
    try {
      final report = await _core.getLoadReport();
      if (report.proxies > 0 || report.groups > 0) return true;
      if (globalState.lastConfigHasProviders) return true;
      return emptyProfile;
    } catch (_) {
      if (emptyProfile) return true;
      if (counts.groups <= 0) return false;
      return counts.proxies > 0 || globalState.lastConfigHasProviders;
    }
  }

  Future<void> _startCoreRunning(_RunRequest request) async {
    if (!await _setCoreRunning(request) && _isCurrent(request)) {
      throw _unanswered(CoreMethod.startListener);
    }
  }

  Future<bool> _stop(_RunRequest request) async {
    final bool answered;
    try {
      answered = await _setCoreRunning(request);
    } catch (_) {
      _rollbackRunning(request);
      rethrow;
    }
    if (!_isCurrent(request)) {
      return true;
    }
    resetCoreTraffic();
    ref.read(trafficsProvider.notifier).clear();
    ref.read(totalTrafficProvider.notifier).value = const Traffic();
    // A silent Core is gone or hung; running again would proxy traffic to it.
    if (!answered) {
      throw _unanswered(CoreMethod.stopListener);
    }
    return true;
  }

  Future<bool> _setCoreRunning(_RunRequest request) {
    return _listenerScheduler.run(() async {
      if (!_isCurrent(request)) {
        return true;
      }
      if (request.running && ref.read(suspendProvider)) {
        return true;
      }
      if (ref.read(safeModeProvider)) {
        return true;
      }
      return _setListening(request.running);
    });
  }

  Future<bool> _setListening(bool running) async {
    final vpnOptions = await ref.read(vpnOptionsProvider.future);
    final answered = await setCoreRunning(running);
    ref.read(runningVpnOptionsProvider.notifier).value = running && answered
        ? vpnOptions
        : null;
    return answered;
  }

  CoreMethodException _unanswered(CoreMethod method) => CoreMethodException(
    code: 'no_response',
    message: 'Core did not answer ${method.name}',
  );

  /// An excluded SSID parks the listener without ending the run.
  void syncSuspend() {
    debouncer.call(FunctionTag.suspend, () {
      return _listenerScheduler.run(() async {
        if (!ref.read(isStartProvider) || ref.read(safeModeProvider)) {
          return;
        }
        await _setListening(!ref.read(suspendProvider));
      });
    });
  }

  Future<void> restartVpn() async {
    if (!ref.read(isStartProvider)) {
      return;
    }
    await setRunning(false);
    await setRunning(true);
  }

  void _rollbackRunning(_RunRequest request) {
    if (!_isCurrent(request)) {
      return;
    }
    _startTime = request.previousStartTime;
    _setLocalRunning(!request.running);
  }

  bool _isCurrent(_RunRequest request) => identical(_latestRunRequest, request);

  Future<void> updateConfigDebounce() async {
    debouncer.call(FunctionTag.updateConfig, updateConfig);
  }

  @protected
  Future<bool> setCoreRunning(bool running) {
    return running ? _core.startListener() : _core.stopListener();
  }

  @protected
  void resetCoreTraffic() {
    _core.resetTraffic();
  }

  @visibleForTesting
  Future<void> updateConfig() async {
    await globalState.safeRun(() async {
      final patchConfig = ref.read(patchClashConfigProvider);
      final shouldContinueSetup = await requestAdmin(patchConfig.tun.enable);
      if (!shouldContinueSetup) {
        await _restartCoreAfterAuthorization();
        return;
      }
      final networkSetting = ref.read(networkSettingProvider);
      final message = await _core.updateConfig(
        _effectivePatchConfig(patchConfig).toUpdateParams(
          authentication: networkSetting.authentication.credentials,
          skipCertVerify: !ref.read(appSettingProvider).checkCertificate,
        ),
      );
      if (message.isNotEmpty) throw MessageException(message);
    });
  }

  void applyProfileDebounce({bool silence = false, bool force = false}) {
    _pendingForceApply |= force;
    debouncer.call(FunctionTag.applyProfile, (silence) {
      final force = _pendingForceApply;
      _pendingForceApply = false;
      applyProfile(silence: silence, force: force);
    }, args: [silence]);
  }

  void changeMode(Mode mode) {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(GroupName.GLOBAL.name);
    }
  }

  /// For leaving an editor: a profile whose inputs match the config the Core
  /// already runs is not rebuilt, which on a large profile takes a while.
  void autoApplyProfile() {
    runAfterFrame(() async {
      if (!await _inputsApplied()) {
        await applyProfile();
      }
    });
  }

  Future<bool> _inputsApplied() async {
    final applied = _appliedInputs;
    if (applied == null) {
      return false;
    }
    final profileId = ref.read(currentProfileIdProvider);
    final SetupState setupState;
    try {
      setupState = await ref.read(setupStateProvider(profileId).future);
    } catch (_) {
      return false;
    }
    return applied ==
        (
          setupState,
          _effectivePatchConfig(ref.read(patchClashConfigProvider)),
          ref.read(networkSettingProvider),
          _appliedParams,
        );
  }

  // False means building the profile, the config write, or the Core setup
  // step failed. A profile that fails to build is NOT pushed to the Core:
  // the Core keeps serving the previous config, and callers that want to
  // start must refuse (see _start) rather than run with no proxies.
  // authorizeCore failures still throw.
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    final result = await _runSetup(
      force: force,
      silence: silence,
      preloadInvoke: preloadInvoke,
    );
    return result != _SetupTaskResult.failed;
  }

  Future<_SetupTaskResult> _runSetup({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    final result = await _setupScheduler.run(() {
      return _setupConfig(
        force: force,
        silence: silence,
        preloadInvoke: preloadInvoke,
        onUpdated: () async {
          await ref.read(proxiesActionProvider.notifier).updateGroups();
          await ref.read(providersProvider.notifier).syncProviders();
        },
      );
    });
    if (result != _SetupTaskResult.handoffToCoreRestart) {
      return result;
    }
    // Release the current serial task before restartCore reapplies the profile.
    final restarted = await _restartCoreAfterAuthorization();
    return restarted ? _SetupTaskResult.completed : _SetupTaskResult.failed;
  }

  Future<bool> _restartCoreAfterAuthorization() async {
    try {
      return await ref.read(coreActionProvider.notifier).restartCore();
    } catch (_) {
      ref.read(authorizedTunEnableProvider.notifier).value =
          TunAuthorizationState.none;
      rethrow;
    }
  }

  /// With a base, [BuiltProfile.yaml] is only the overlay the Core applies.
  Future<BuiltProfile> getProfile({
    required SetupState setupState,
    required PatchClashConfig patchConfig,
  }) async {
    final profileId = setupState.profileId;
    if (profileId == null) {
      return (
        yaml: '',
        md5: '',
        counts: configCountsOf(const {}),
        base: null,
        hasProviders: false,
      );
    }
    final defaultUA = globalState.packageInfo.ua;
    final networkSetting = ref.read(
      networkSettingProvider.select(
        (state) => (
          appendSystemDns: state.appendSystemDns,
          bypassPrivateRoute: state.bypassPrivateRoute,
          authentication: state.authentication,
        ),
      ),
    );
    final appendSystemDns = networkSetting.appendSystemDns;
    final isCustom = setupState.profileType == ProfileType.custom;
    final scriptContent =
        !isCustom && setupState.extendType == ExtendType.script
        ? await setupState.script?.content
        : null;
    final hasScript = scriptContent?.isNotEmpty == true;
    final autoSelectFastest = ref.read(appSettingProvider).autoSelectFastest;
    final profileBase = !isCustom && !hasScript && !autoSelectFastest
        ? await _core.getProfileBase(profileId)
        : null;
    Map<String, dynamic> rawConfig = isCustom
        ? {
            'proxies': appProxiesPayload(
              setupState.appProxies,
              dialers: setupState.proxyDialers,
              groups: setupState.proxyGroups,
            ),
          }
        : profileBase?.base.config ?? await _core.getConfig(profileId);
    final proxyGroups = isCustom ? setupState.proxyGroups : <ProxyGroup>[];
    final rules = isCustom ? setupState.rules : <Rule>[];
    final hasProviders = switch (rawConfig['proxy-providers']) {
      final Map providers => providers.isNotEmpty,
      _ => false,
    };
    if (hasScript) {
      rawConfig = await handleEvaluate(scriptContent!, rawConfig);
    }
    if (autoSelectFastest) {
      rawConfig = applyAutoSelectFastest(rawConfig);
    }
    final directory = await appPath.profilesPath;
    final injected = await _resolveInjectedProviders(
      setupState,
      proxyGroups: proxyGroups,
      rules: rules,
    );
    var synthesizedGroup = const <String, dynamic>{};
    var synthesizedGroupNeedsMatch = false;
    if (profileBase != null &&
        profileBase.base.proxies > 0 &&
        profileBase.base.proxyGroups == 0) {
      try {
        final outbounds = await _core.getProfileOutbounds(profileId);
        final declared = outbounds['proxies'];
        final names = <String>[
          if (declared is List)
            for (final proxy in declared)
              if (proxy is Map && proxy['name'] is String)
                proxy['name'] as String,
        ];
        if (names.isNotEmpty) {
          synthesizedGroup = bareProfileGroup(names);
          synthesizedGroupNeedsMatch =
              profileBase.base.rules == 0 && setupState.addedRules.isEmpty;
        }
      } catch (_) {
        // Best effort: keep applying bare if the read-back fails.
      }
    }
    final res = await makeRealProfileTask(
      MakeRealProfileState(
        rules: rules,
        proxyGroups: proxyGroups,
        injectedProxyProviders: injected.proxies,
        injectedRuleProviders: injected.rules,
        profilesPath: directory,
        profileId: profileId,
        rawConfig: rawConfig,
        realPatchConfig: patchConfig,
        overrides: setupState.overrides,
        bypassPrivateRoute: networkSetting.bypassPrivateRoute,
        keepEmptyDnsOverrides: setupState.profileType != ProfileType.custom,
        appendSystemDns: appendSystemDns,
        addedRules: setupState.addedRules,
        defaultUA: defaultUA,
        authentication: networkSetting.authentication.credentials,
        matchTarget:
            profileBase == null ||
                setupState.matchTarget?.trim().isNotEmpty == true
            ? setupState.matchTarget
            : lastMatchTarget(profileBase.base.matchRules),
        safeMode: ref.read(safeModeProvider),
        synthesizedGroup: synthesizedGroup,
        synthesizedGroupNeedsMatch: synthesizedGroupNeedsMatch,
      ),
    );
    if (profileBase == null) {
      return (
        yaml: res.yaml,
        md5: res.md5,
        counts: res.counts,
        base: null,
        hasProviders: hasProviders,
      );
    }
    final (:base, :path) = profileBase;
    return (
      yaml: res.yaml,
      md5: '${res.md5}${base.digest}'.toMd5(),
      counts: (
        groups: res.counts.groups + base.proxyGroups,
        proxies: res.counts.proxies + base.proxies,
        rules: res.counts.rules + base.rules,
      ),
      base: SetupBase(path: path, overlay: res.yaml),
      hasProviders: hasProviders,
    );
  }

  /// Only what the custom profile actually references is injected, so an
  /// app-level provider costs nothing in the profiles that never name it.
  Future<({Map<String, dynamic> proxies, Map<String, dynamic> rules})>
  _resolveInjectedProviders(
    SetupState setupState, {
    required List<ProxyGroup> proxyGroups,
    required List<Rule> rules,
  }) async {
    final usedProxyProviders = <String>{
      for (final proxyGroup in proxyGroups) ...?proxyGroup.use,
    };
    final usedRuleProviders = <String>{
      for (final rule in rules) ...rule.ruleSets,
      if (setupState.profileType == ProfileType.custom)
        ...setupState.overrides.ruleSets,
    };
    if (usedProxyProviders.isEmpty && usedRuleProviders.isEmpty) {
      return (
        proxies: const <String, dynamic>{},
        rules: const <String, dynamic>{},
      );
    }
    final options = setupState.overrides.proxyProviders;
    final proxies = <String, dynamic>{};
    for (final entry in setupState.profileProviders.entries) {
      if (!usedProxyProviders.contains(entry.key)) {
        continue;
      }
      proxies[entry.key] = {
        'type': 'file',
        'path': await appPath.getProfilePath(entry.value.toString()),
        ...?options[entry.key]?.definition,
      };
    }
    final clashProvidersAction = ref.read(
      clashProvidersActionProvider.notifier,
    );
    final ruleProviders = <String, dynamic>{};
    for (final provider in setupState.clashProviders) {
      if (!usedRuleProviders.contains(provider.label)) {
        continue;
      }
      final prepared = await clashProvidersAction.prepare(provider);
      ruleProviders[prepared.label] = prepared.definition(
        await prepared.corePath,
      );
    }
    return (proxies: proxies, rules: ruleProviders);
  }

  Future<String> getProfileWithId(int profileId) async {
    try {
      final setupState = await ref.read(setupStateProvider(profileId).future);
      final patchClashConfig = ref.read(patchClashConfigProvider);
      final res = await getProfile(
        setupState: setupState,
        patchConfig: patchClashConfig,
      );
      return switch (res.base) {
        final base? => await _core.buildProfile(base),
        null => res.yaml,
      };
    } catch (e) {
      dialogs.showNotifier(e.toString(), level: MessageLevel.error);
    }
    return '';
  }

  PatchClashConfig _effectivePatchConfig(PatchClashConfig patchConfig) {
    if (ref.read(safeModeProvider)) {
      return patchConfig.copyWith(
        tun: patchConfig.tun.copyWith(enable: false),
        externalController: ExternalControllerStatus.close,
      );
    }
    final authorized =
        ref.read(authorizedTunEnableProvider) ==
        TunAuthorizationState.authorized;
    return patchConfig.copyWith(
      tun: patchConfig.tun.copyWith(
        enable: patchConfig.tun.enable && authorized,
      ),
      externalController: patchConfig.secret.isEmpty
          ? ExternalControllerStatus.close
          : patchConfig.externalController,
    );
  }

  @protected
  Future<AuthorizeCode> authorizeCore() {
    return system.authorizeCore();
  }

  @visibleForTesting
  Future<bool> requestAdmin(bool enableTun) async {
    if (!enableTun || ref.read(safeModeProvider)) {
      return true;
    }
    final authorizationState = ref.read(authorizedTunEnableProvider);
    if (authorizationState != TunAuthorizationState.none) {
      return true;
    }

    final authorizationNotifier = ref.read(
      authorizedTunEnableProvider.notifier,
    );
    authorizationNotifier.value = TunAuthorizationState.unauthorized;

    final code = await authorizeCore();

    switch (code) {
      case AuthorizeCode.success:
        authorizationNotifier.value = TunAuthorizationState.authorized;
        return false;
      case AuthorizeCode.none:
        authorizationNotifier.value = TunAuthorizationState.authorized;
        return true;
      case AuthorizeCode.error:
        authorizationNotifier.value = TunAuthorizationState.none;
        ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(enable: false));
        dialogs.showNotifier(
          currentAppLocalizations.tunAuthorizationFailed,
          level: MessageLevel.error,
        );
        return true;
    }
  }

  /// An empty profile list is left alone: it is the first-run state, and it is
  /// what the profile stream holds before its first emission.
  @visibleForTesting
  Profile? recoverMissingProfile() {
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null) return null;
    final profiles = ref.read(profilesProvider);
    if (profiles.isEmpty) return null;
    final fallback = profiles.first;
    commonPrint.log(
      'profile $profileId is missing, falling back to ${fallback.id}',
      logLevel: LogLevel.warning,
    );
    ref.read(currentProfileIdProvider.notifier).value = fallback.id;
    return fallback;
  }

  /// A profile the core refuses to build must not stay current: it keeps
  /// showing its nodes while nothing can route through it. Fall back to
  /// the first profile that has not failed to build; when none is left,
  /// clear the current selection so the home screen says so plainly.
  Future<void> _rollbackUnbuildableProfile(Profile failed) async {
    _unbuildableProfileIds.add(failed.id);
    if (ref.read(currentProfileIdProvider) != failed.id) {
      return;
    }
    final candidate = qfRollbackCandidate(
      ref.read(profilesProvider),
      _unbuildableProfileIds,
    );
    if (candidate == null) {
      ref.read(currentProfileIdProvider.notifier).value = null;
      dialogs.showNotifier(
        '订阅「${failed.realLabel}」无法使用，已取消将其设为当前订阅，请检查订阅内容后重试。',
        level: MessageLevel.error,
      );
      return;
    }
    ref.read(currentProfileIdProvider.notifier).value = candidate.id;
    dialogs.showNotifier(
      '订阅「${failed.realLabel}」无法使用，已自动切换到「${candidate.realLabel}」。',
      level: MessageLevel.warning,
    );
    applyProfileDebounce(force: true);
  }

  Future<_SetupTaskResult> _setupConfig({
    bool force = false,
    bool silence = false,
    Future<void> Function()? preloadInvoke,
    FutureOr Function()? onUpdated,
  }) async {
    var profile = ref.read(currentProfileProvider) ?? recoverMissingProfile();
    // A refresh failure is surfaced by safeRun; setup keeps the old profile.
    final nextProfile = await globalState.safeRun(
      () => profile?.checkAndUpdateAndCopy(
        validate: (path, key) => _core.validateProfile(path, key),
      ),
    );
    if (nextProfile != null) {
      profile = nextProfile;
      ref.read(profilesProvider.notifier).put(nextProfile);
    }
    commonPrint.log('setup ===> ${profile?.realLabel}');
    final patchConfig = ref.read(patchClashConfigProvider);
    final shouldContinueSetup = await requestAdmin(patchConfig.tun.enable);
    if (!shouldContinueSetup) {
      return _SetupTaskResult.handoffToCoreRestart;
    }
    final realPatchConfig = _effectivePatchConfig(patchConfig);
    final networkSetting = ref.read(networkSettingProvider);
    SetupState? setupState;
    final realProfile = await globalState.safeRun(() async {
      final state = await ref.read(setupStateProvider(profile?.id).future);
      setupState = state;
      return getProfile(setupState: state, patchConfig: realPatchConfig);
    }, title: 'build profile');
    final profileFailed = realProfile == null;
    final setupParams = _setupParams.copyWith(base: realProfile?.base);
    final inputs = switch (setupState) {
      final state? when !profileFailed => (
        state,
        realPatchConfig,
        networkSetting,
        _appliedParams,
      ),
      _ => null,
    };
    final yamlString = realProfile?.yaml ?? '';
    final yamlMd5 = realProfile?.md5 ?? '';
    if (!profileFailed && yamlMd5 == globalState.lastConfigMd5 && !force) {
      _appliedInputs = inputs;
      return _SetupTaskResult.completed;
    }
    if (profileFailed) {
      // Never push a failed build: the empty config it used to send took
      // every route down while the profile's nodes stayed on screen.
      // The Core keeps its previous config; report the failure instead.
      commonPrint.log(
        'setup ===> profile build failed, keeping the previous config',
        logLevel: LogLevel.warning,
      );
      _appliedInputs = null;
      globalState.lastConfigMd5 = null;
      globalState.lastConfigCounts = null;
      globalState.lastConfigHasProviders = false;
      ref.read(qfDirectOnlyProfileProvider.notifier).update(false);
      return _SetupTaskResult.failed;
    }
    // Until this push succeeds no applied config is known: a config the
    // Core rejects now fails the whole apply (see core/config.go), it no
    // longer falls back to a built-in default with no proxies.
    _appliedInputs = null;
    globalState.lastConfigMd5 = null;
    globalState.lastConfigCounts = null;
    if (system.isAndroid) {
      await ref.read(vpnOptionsProvider.future);
      await preferences.saveShareState(ref.read(sharedStateProvider));
    }
    // Recaptured so _start's catch can roll back after safeRun swallows it.
    (Object, StackTrace)? handoffFailure;
    var setupFailed = false;
    Object? setupError;
    await globalState.loadingRun(
      () async {
        try {
          if (setupParams.base == null) {
            final configFilePath = await appPath.configFilePath;
            await File(configFilePath).writeAsStringAtomically(yamlString);
          }
          final profileId = profile?.id;
          if (profileId != null) {
            await appPath.ensureProviderDirs(profileId);
          }
          final message = await _core.setupConfig(
            params: setupParams,
            preloadInvoke: preloadInvoke,
          );
          if (message.isNotEmpty) {
            globalState.lastConfigCounts = configCountsOf(const {});
            globalState.lastConfigHasProviders = false;
            ref.read(qfDirectOnlyProfileProvider.notifier).update(false);
            await globalState.safeRun(() => onUpdated?.call());
            throw MessageException(message);
          }
        } catch (e, s) {
          setupFailed = true;
          setupError = e;
          if (preloadInvoke != null) {
            handoffFailure = (e, s);
          }
          rethrow;
        }
        globalState.lastConfigMd5 = yamlMd5;
        globalState.lastConfigCounts = realProfile.counts;
        globalState.lastConfigHasProviders = realProfile.hasProviders;
        ref
            .read(qfDirectOnlyProfileProvider.notifier)
            .update(
              realProfile.counts.proxies <= 0 && !realProfile.hasProviders,
            );
        _appliedInputs = inputs;
        await onUpdated?.call();
      },
      silence: true,
      tag: !silence ? LoadingTag.proxies : null,
    );
    if (handoffFailure != null) {
      Error.throwWithStackTrace(handoffFailure!.$1, handoffFailure!.$2);
    }
    if (setupFailed &&
        setupError is MessageException &&
        profile != null &&
        realProfile.base != null) {
      // The core rejected this profile's build: never leave it current.
      await _rollbackUnbuildableProfile(profile);
    }
    if (setupFailed || profileFailed) {
      return _SetupTaskResult.failed;
    }
    if (!silence) {
      await globalState.safeRun(() async {
        final report = await _core.getLoadReport();
        if (report.total > 0) {
          dialogs.showNotifier(
            '已自动跳过 ${report.total} 个无法使用的条目，其余节点与规则正常加载。',
            level: MessageLevel.warning,
          );
        }
      });
    }
    return _SetupTaskResult.completed;
  }
}
