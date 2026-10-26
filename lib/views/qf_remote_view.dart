import 'dart:async';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_remote.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Tools page's QFRemote module (2.0.3): native sign-in and profile
// basics around an embedded web console. Friends, chat, forum and
// points stay in QFRemote itself and are not surfaced here.
class QfRemoteView extends StatefulWidget {
  const QfRemoteView({super.key});

  @override
  State<QfRemoteView> createState() => _QfRemoteViewState();
}

enum _QfrStage { checking, login, hub }

class _QfRemoteViewState extends State<QfRemoteView> {
  final _service = QfRemoteService.instance;
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  _QfrStage _stage = _QfrStage.checking;
  bool _busy = false;
  String? _notice;
  QfrProfile? _profile;
  QfrAccess? _access;
  bool _purchaseAutoOpened = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    if (!await _service.hasSession) {
      if (mounted) setState(() => _stage = _QfrStage.login);
      return;
    }
    await _loadHub(sessionExpiredNotice: QfCopy.remoteSessionExpired);
  }

  Future<void> _loadHub({String? sessionExpiredNotice}) async {
    final profile = await _service.fetchProfile();
    if (!mounted) return;
    if (profile == null) {
      await _service.clearSession();
      if (!mounted) return;
      setState(() {
        _stage = _QfrStage.login;
        _notice = sessionExpiredNotice;
        _profile = null;
        _access = null;
      });
      return;
    }
    final access = await _service.fetchAccess();
    if (!mounted) return;
    setState(() {
      _stage = _QfrStage.hub;
      _profile = profile;
      _access = access;
      _notice = access == null ? QfCopy.remoteNetworkFailed : null;
    });
    if (access != null && !access.allow && !access.isBanned) {
      _openPurchaseOnce();
    }
  }

  void _openPurchaseOnce() {
    if (_purchaseAutoOpened) return;
    _purchaseAutoOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openPurchase());
    });
  }

  Future<void> _login() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _notice = QfCopy.remoteLoginFailed);
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    final result = await _service.login(username, password);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result.outcome) {
      case QfrLoginOutcome.success:
        _passwordController.clear();
        await _loadHub();
      case QfrLoginOutcome.invalidCredentials:
        setState(() => _notice = QfCopy.remoteLoginFailed);
      case QfrLoginOutcome.frozen:
        setState(() => _notice = QfCopy.remoteFrozen);
      case QfrLoginOutcome.networkError:
        setState(() => _notice = QfCopy.remoteNetworkFailed);
    }
  }

  Future<void> _openConsole() async {
    final navigator = Navigator.of(context);
    final base = await _service.webBase();
    if (!mounted) return;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => QfrWebViewPage(
          title: QfCopy.remoteTitle,
          url: '$base/',
          cookies: _service.cookieJar(),
          base: base,
        ),
      ),
    );
    if (mounted) unawaited(_loadHub());
  }

  Future<void> _openPurchase() async {
    final navigator = Navigator.of(context);
    final base = await _service.webBase();
    if (!mounted) return;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => QfrWebViewPage(
          title: QfCopy.remoteOpenPurchase,
          url: '$base/purchase',
          cookies: _service.cookieJar(),
          base: base,
        ),
      ),
    );
    if (mounted) unawaited(_loadHub());
  }

  Future<void> _changePassword() async {
    final currentController = TextEditingController();
    final nextController = TextEditingController();
    final confirmController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(QfCopy.remoteChangePassword),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: QfCopy.remoteCurrentPassword,
                ),
              ),
              TextField(
                controller: nextController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: QfCopy.remoteNewPassword,
                ),
              ),
              TextField(
                controller: confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: QfCopy.remoteConfirmPassword,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认修改'),
            ),
          ],
        );
      },
    );
    final current = currentController.text;
    final next = nextController.text;
    final confirm = confirmController.text;
    currentController.dispose();
    nextController.dispose();
    confirmController.dispose();
    if (confirmed != true || !mounted) return;
    if (next.isEmpty || next != confirm) {
      setState(() => _notice = QfCopy.passwordMismatch);
      return;
    }
    setState(() => _busy = true);
    final ok = await _service.changePassword(current, next);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = ok
          ? QfCopy.remoteChangePasswordOk
          : QfCopy.remoteChangePasswordFailed;
    });
    if (ok) await _loadHub();
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    await _service.logout();
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stage = _QfrStage.login;
      _profile = null;
      _access = null;
      _notice = null;
      _purchaseAutoOpened = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: QfCopy.remoteTitle,
      body: switch (_stage) {
        _QfrStage.checking => const Center(child: CommonCircleLoading.page()),
        _QfrStage.login => _buildLogin(context),
        _QfrStage.hub => _buildHub(context),
      },
    );
  }

  Widget _buildLogin(BuildContext context) {
    // The app bar floats over the body on Android; without clearing it
    // the centered form slides under the bar and overlaps its title.
    final topClearance =
        SupportPlatform.currentPlatform == SupportPlatform.Android
        ? context.appBarInset
        : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: topClearance),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  QfCopy.remoteLoginTitle,
                  textAlign: TextAlign.center,
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                const SizedBox(height: 8),
                const Text(QfCopy.remoteLoginHint, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: QfCopy.remoteUsernameLabel,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  onSubmitted: (_) => unawaited(_login()),
                  decoration: const InputDecoration(
                    labelText: QfCopy.remotePasswordLabel,
                  ),
                ),
                if (_notice != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _notice!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : () => unawaited(_login()),
                  child: Text(_busy ? '正在登录……' : QfCopy.remoteLoginAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHub(BuildContext context) {
    final profile = _profile;
    final access = _access;
    if (profile == null) {
      return const Center(child: CommonCircleLoading.page());
    }
    final topClearance =
        SupportPlatform.currentPlatform == SupportPlatform.Android
        ? context.appBarInset
        : 0.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16 + topClearance, 16, 16),
      children: [
        if (_notice != null) ...[
          Text(
            _notice!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          QfCopy.remoteProfileTitle,
          style: AppTextStyle.headline.of(context),
        ),
        const SizedBox(height: 8),
        _infoRow('账号', profile.username),
        _infoRow(QfCopy.remotePlanLabel, profile.planName),
        _infoRow(QfCopy.remoteKeyLabel, profile.maskedKey),
        _infoRow(QfCopy.remoteStatusLabel, profile.displayStatus),
        if (profile.statusNote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(profile.statusNote),
          ),
        const SizedBox(height: 24),
        if (access != null && access.allow)
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_openConsole()),
            child: const Text(QfCopy.remoteOpenConsole),
          )
        else if (access != null && access.isBanned)
          const Text(QfCopy.remoteBanned)
        else if (access != null) ...[
          const Text(QfCopy.remoteNeedKey),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_openPurchase()),
            child: const Text(QfCopy.remoteOpenPurchase),
          ),
        ] else
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_loadHub()),
            child: const Text('重新读取状态'),
          ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : () => unawaited(_changePassword()),
          child: const Text(QfCopy.remoteChangePassword),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : () => unawaited(_logout()),
          child: const Text(QfCopy.remoteLogout),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 88, child: Text(label)),
          Expanded(child: Text(value.isEmpty ? '—' : value)),
        ],
      ),
    );
  }
}

class QfrWebViewPage extends StatefulWidget {
  const QfrWebViewPage({
    super.key,
    required this.title,
    required this.url,
    required this.cookies,
    required this.base,
  });

  final String title;
  final String url;
  final Future<Map<String, String>> cookies;
  final String base;

  @override
  State<QfrWebViewPage> createState() => _QfrWebViewPageState();
}

class _QfrWebViewPageState extends State<QfrWebViewPage> {
  InAppWebViewController? _controller;
  var _progress = 0;
  String? _error;
  var _ready = false;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _armWatchdog();
    unawaited(_seedCookies());
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  // A stalled load (dead tunnel, dropped packets) fires no error
  // callback at all; without a deadline the page would sit on a silent
  // blank area forever. 25s without finishing swaps in the retry panel.
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 25), () {
      if (mounted && _error == null && (!_ready || _progress < 100)) {
        setState(() => _error = '加载超时，网络可能不稳定，请检查网络后重试。');
      }
    });
  }

  void _loadFinished() {
    _watchdog?.cancel();
    if (mounted && _progress < 100) setState(() => _progress = 100);
  }

  void _retry() {
    setState(() {
      _error = null;
      _progress = 0;
    });
    _armWatchdog();
    if (!_ready) {
      unawaited(_seedCookies());
      return;
    }
    unawaited(
      _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(widget.url))),
    );
  }

  Future<void> _seedCookies() async {
    try {
      final jar = await widget.cookies;
      final manager = CookieManager.instance();
      final url = WebUri(widget.base);
      for (final entry in jar.entries) {
        await manager.setCookie(url: url, name: entry.key, value: entry.value);
      }
    } catch (_) {}
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    // Keep the web content below the floating app bar: the page gets
    // its own bounded area and its own loading / error surface, so the
    // native header and the web page can never paint over each other.
    final topClearance =
        SupportPlatform.currentPlatform == SupportPlatform.Android
        ? context.appBarInset
        : 0.0;
    final surface = Theme.of(context).colorScheme.surface;
    return CommonScaffold(
      title: widget.title,
      body: Padding(
        padding: EdgeInsets.only(top: topClearance),
        child: Stack(
          children: [
            if (_ready)
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  supportZoom: false,
                  mediaPlaybackRequiresUserGesture: false,
                ),
                onWebViewCreated: (controller) => _controller = controller,
                onProgressChanged: (_, progress) {
                  if (!mounted) return;
                  setState(() => _progress = progress);
                  if (progress >= 100) _loadFinished();
                },
                onLoadStop: (_, _) => _loadFinished(),
                onReceivedError: (_, request, error) {
                  if ((request.isForMainFrame ?? true) && mounted) {
                    setState(() => _error = QfCopy.remoteNetworkFailed);
                  }
                },
                onReceivedHttpError: (_, request, response) {
                  if ((request.isForMainFrame ?? true) &&
                      mounted &&
                      (response.statusCode ?? 0) >= 400) {
                    setState(() => _error = '页面加载失败，请稍后重试。');
                  }
                },
              ),
            if (_error == null && (!_ready || _progress < 100))
              Positioned.fill(
                child: ColoredBox(
                  color: surface,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CommonCircleLoading.page(),
                        const SizedBox(height: 16),
                        const Text('正在加载…'),
                        if (_ready && _progress > 0)
                          Text(
                            '$_progress%',
                            style: AppTextStyle.caption1.of(context),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Positioned.fill(
                child: ColoredBox(
                  color: surface,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _retry,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
