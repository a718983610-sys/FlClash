import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_google.dart';
import 'qf_owner.dart';
import 'qf_pages2.dart';
import 'qf_passkey.dart';
import 'qf_providers.dart';
import 'qf_recovery.dart';
import 'qf_session.dart';
import 'qf_social.dart';
import 'qf_update.dart';
import 'qf_version.dart';

OverlayEntry? _qfToastEntry;
OverlayState? _qfToastOverlay;
bool _qfToastShowing = false;
final List<String> _qfToastQueue = <String>[];

// The toast goes into the root overlay, above every page, dialog and the
// bottom navigation bar: a Scaffold-hosted SnackBar can render underneath
// the bar in this app's nested Scaffolds, hiding its text. The bottom
// offset clears the bar and the gesture area; messages queue like SnackBars.
void qfToast(BuildContext context, String message) {
  if (_qfToastShowing &&
      (_qfToastOverlay == null || !_qfToastOverlay!.mounted)) {
    _qfToastEntry = null;
    _qfToastOverlay = null;
    _qfToastShowing = false;
    _qfToastQueue.clear();
  }
  _qfToastQueue.add(message);
  if (_qfToastShowing) return;
  _qfToastShowing = true;
  _qfToastOverlay = Overlay.of(context, rootOverlay: true);
  _showNextToast(MediaQuery.paddingOf(context).bottom);
}

void _showNextToast(double bottomInset) {
  final overlay = _qfToastOverlay;
  if (overlay == null || !overlay.mounted || _qfToastQueue.isEmpty) {
    _qfToastShowing = false;
    _qfToastOverlay = null;
    return;
  }
  final message = _qfToastQueue.removeAt(0);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _QfToastView(
      message: message,
      bottomInset: bottomInset,
      onDismissed: () {
        if (_qfToastEntry == entry) {
          _qfToastEntry = null;
          entry.remove();
        }
        _showNextToast(bottomInset);
      },
    ),
  );
  _qfToastEntry = entry;
  overlay.insert(entry);
}

class _QfToastView extends StatefulWidget {
  final String message;
  final double bottomInset;
  final VoidCallback onDismissed;

  const _QfToastView({
    required this.message,
    required this.bottomInset,
    required this.onDismissed,
  });

  @override
  State<_QfToastView> createState() => _QfToastViewState();
}

class _QfToastViewState extends State<_QfToastView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), widget.onDismissed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 24,
      right: 24,
      bottom: widget.bottomInset + 88,
      child: IgnorePointer(
        child: Center(
          child: Material(
            shape: AppShape.lg,
            color: scheme.inverseSurface,
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                widget.message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onInverseSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<String> qfPasskeyReauthToken(
  QfSessionController session,
  String purpose,
) async {
  final data = await session.authed(
    'POST',
    '/passkeys/reauth/options',
    body: {'purpose': purpose},
  );
  final rawOptions = data['options'];
  final options = rawOptions is Map
      ? Map<String, dynamic>.from(rawOptions)
      : Map<String, dynamic>.from(data);
  final response = await QfPasskeyCeremony.authenticate(options);
  final verified = await session.authed(
    'POST',
    '/passkeys/reauth/verify',
    body: {'purpose': purpose, 'response': response},
  );
  final token = (verified['reauthToken'] ?? '').toString();
  if (token.isEmpty) {
    throw const QfApiException(401, 'REAUTH_INVALID', '通行密钥验证未完成，请重试');
  }
  return token;
}

class QfField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? error;
  final bool obscure;
  final TextInputType? keyboardType;
  final Widget? suffix;

  const QfField({
    super.key,
    required this.controller,
    required this.label,
    this.error,
    this.obscure = false,
    this.keyboardType,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        errorText: error,
        suffixIcon: suffix,
      ),
    );
  }
}

class _QfSendAborted implements Exception {
  const _QfSendAborted();
}

enum QfFailureKind {
  network,
  rejected,
  credential,
  cancelled,
  unsupported,
  validation,
  unknown,
}

class QfFailure {
  final QfFailureKind kind;
  final String message;

  const QfFailure(this.kind, this.message);
}

/// 登录链失败分类：网络不可达走定稿口径，业务拒绝回服务端原文，
/// 凭据/取消/不支持单列，未知异常给可操作兜底文案（不外泄原始报错）。
QfFailure qfClassifyAuthError(Object error, {bool guest = false}) {
  if (error is _QfSendAborted) {
    return const QfFailure(QfFailureKind.validation, '');
  }
  if (error is QfPasskeyException) {
    final message = error.message;
    if (message.contains('已取消')) {
      return QfFailure(QfFailureKind.cancelled, message);
    }
    if (message.contains('不支持')) {
      return QfFailure(QfFailureKind.unsupported, message);
    }
    return QfFailure(QfFailureKind.rejected, message);
  }
  if (error is MissingPluginException || error is PlatformException) {
    final message = qfPasskeyFailureText(error);
    if (message.contains('已取消')) {
      return QfFailure(QfFailureKind.cancelled, message);
    }
    if (message.contains('不支持')) {
      return QfFailure(QfFailureKind.unsupported, message);
    }
    return QfFailure(QfFailureKind.rejected, message);
  }
  if (error is QfGoogleAuthException) {
    final message = error.message;
    if (message.contains('已取消')) {
      return QfFailure(QfFailureKind.cancelled, message);
    }
    if (message.contains('尚未完成配置') || message.contains('暂不支持')) {
      return QfFailure(QfFailureKind.unsupported, message);
    }
    return QfFailure(QfFailureKind.rejected, message);
  }
  if (error is QfApiException) {
    if (error.isNetworkFailure) {
      return QfFailure(
        QfFailureKind.network,
        guest ? qfGuestErrorMessage(error) : qfAccountErrorMessage(error),
      );
    }
    if (error.code == 'NOT_CONFIGURED') {
      return QfFailure(QfFailureKind.unsupported, error.message);
    }
    if (error.status == 401 ||
        error.status == 403 ||
        error.code == 'BAD_CREDENTIALS' ||
        error.code == 'INVALID_CREDENTIALS') {
      return QfFailure(QfFailureKind.credential, error.message);
    }
    return QfFailure(
      QfFailureKind.rejected,
      guest ? qfGuestErrorMessage(error) : error.message,
    );
  }
  return const QfFailure(QfFailureKind.unknown, QfCopy.actionFailedRetry);
}

/// 登录链通用动作按钮：忙态只锁自身、点击即呈现进度，
/// 失败经分类器内联呈现（对话框场景可关内联改走 onFailure 自行呈现）。
class QfActionButton extends StatefulWidget {
  final String label;
  final String busyLabel;
  final Future<void> Function() onAction;
  final QfFailure Function(Object error)? classify;
  final void Function(QfFailure failure)? onFailure;
  final bool filled;
  final bool showInlineError;
  final bool enabled;

  const QfActionButton({
    super.key,
    required this.label,
    required this.onAction,
    this.busyLabel = '处理中……',
    this.classify,
    this.onFailure,
    this.filled = true,
    this.showInlineError = true,
    this.enabled = true,
  });

  @override
  State<QfActionButton> createState() => _QfActionButtonState();
}

class _QfActionButtonState extends State<QfActionButton> {
  bool _busy = false;
  QfFailure? _failure;

  Future<void> _tap() async {
    if (_busy || !widget.enabled) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await widget.onAction();
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      final failure = widget.classify?.call(e) ?? qfClassifyAuthError(e);
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = failure;
        });
      }
      if (failure.kind != QfFailureKind.validation) {
        widget.onFailure?.call(failure);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _busy
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CommonCircleLoading(size: 16),
              const SizedBox(width: 8),
              Text(widget.busyLabel),
            ],
          )
        : Text(widget.label);
    final onPressed = _busy || !widget.enabled ? null : _tap;
    final button = widget.filled
        ? FilledButton(onPressed: onPressed, child: child)
        : OutlinedButton(onPressed: onPressed, child: child);
    final failure = _failure;
    if (!widget.showInlineError || failure == null || failure.message.isEmpty) {
      return button;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        button,
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            failure.message,
            textAlign: TextAlign.center,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    );
  }
}

class QfCodeSendButton extends StatefulWidget {
  final Future<int?> Function() onSend;
  final void Function(Object error)? onError;
  final String label;
  final String resendLabel;
  final bool enabled;

  const QfCodeSendButton({
    super.key,
    required this.onSend,
    this.onError,
    this.label = '发送验证码',
    this.resendLabel = '重新发送',
    this.enabled = true,
  });

  @override
  State<QfCodeSendButton> createState() => _QfCodeSendButtonState();
}

class _QfCodeSendButtonState extends State<QfCodeSendButton> {
  Timer? _timer;
  int _secondsLeft = 0;
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tap() async {
    if (_sending || _secondsLeft > 0 || !widget.enabled) return;
    setState(() => _sending = true);
    try {
      final serverSeconds = await widget.onSend();
      if (!mounted) return;
      final seconds = (serverSeconds ?? 60) > 0 ? (serverSeconds ?? 60) : 60;
      setState(() {
        _sending = false;
        _sent = true;
        _secondsLeft = seconds;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _secondsLeft -= 1;
          if (_secondsLeft <= 0) {
            _secondsLeft = 0;
            timer.cancel();
          }
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      final onError = widget.onError;
      if (onError != null) {
        onError(e);
      } else {
        final message = qfClassifyAuthError(e).message;
        if (message.isNotEmpty) qfToast(context, message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final counting = _secondsLeft > 0;
    return TextButton(
      onPressed: _sending || counting || !widget.enabled ? null : _tap,
      child: Text(
        counting
            ? '已发送（$_secondsLeft 秒）'
            : _sending
            ? '发送中……'
            : _sent
            ? widget.resendLabel
            : widget.label,
      ),
    );
  }
}

class QfEntryPage extends StatefulWidget {
  final QfSessionController session;
  final VoidCallback onAbout;
  final VoidCallback onCheckUpdate;
  final VoidCallback onAgreement;
  final VoidCallback onSupport;

  const QfEntryPage({
    super.key,
    required this.session,
    required this.onAbout,
    required this.onCheckUpdate,
    required this.onAgreement,
    required this.onSupport,
  });

  @override
  State<QfEntryPage> createState() => _QfEntryPageState();
}

class _QfEntryPageState extends State<QfEntryPage> {
  bool _register = false;

  Future<void> _enterGuest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(QfCopy.guestIntroTitle),
          content: const Text(
            '${QfCopy.guestNotice}\n\n${QfCopy.loginBenefit}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认进入访客模式'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) throw const _QfSendAborted();
    await widget.session.enterGuest();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'QFClash',
                    textAlign: TextAlign.center,
                    style: AppTextStyle.title1.of(context),
                  ),
                  const SizedBox(height: 8),
                  const Text(QfCopy.loginBenefit, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('登录')),
                      ButtonSegment(value: true, label: Text('注册')),
                    ],
                    selected: {_register},
                    onSelectionChanged: (value) {
                      setState(() => _register = value.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  if (_register)
                    QfRegisterForm(session: widget.session)
                  else
                    QfLoginForm(session: widget.session),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 8),
                  QfActionButton(
                    label: '免登录使用（访客模式）',
                    busyLabel: '正在进入访客模式……',
                    filled: false,
                    classify: (e) => qfClassifyAuthError(e, guest: true),
                    onAction: _enterGuest,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    QfCopy.guestNotice,
                    textAlign: TextAlign.center,
                    style: AppTextStyle.caption1.of(context),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(
                        onPressed: widget.onAbout,
                        child: const Text('关于'),
                      ),
                      TextButton(
                        onPressed: widget.onCheckUpdate,
                        child: const Text('检查更新'),
                      ),
                      TextButton(
                        key: const ValueKey('qf-entry-support'),
                        onPressed: widget.onSupport,
                        child: const Text('智能客服'),
                      ),
                      TextButton(
                        onPressed: widget.onAgreement,
                        child: const Text('用户使用协议'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const QfPrivacyPage(),
                            ),
                          );
                        },
                        child: const Text('隐私说明'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class QfLoginForm extends StatefulWidget {
  final QfSessionController session;

  const QfLoginForm({super.key, required this.session});

  @override
  State<QfLoginForm> createState() => _QfLoginFormState();
}

enum QfGoogleConfigState { ready, networkFailed, unconfigured }

void qfApplyGoogleRuntime(QfReleaseManifest manifest) {
  final platformId = manifest.googleClientIdFor(QfUpdateService.platformKey);
  if (platformId.isNotEmpty) QfRuntime.googleClientId = platformId;
  if (manifest.googleClientId.isNotEmpty) {
    QfRuntime.googleWebClientId = manifest.googleClientId;
  }
  QfEndpoints.applyManifest(manifest);
}

/// Cached manifest first, remote second: Google sign-in must not depend
/// on reaching GitHub from a cold start on a network where that fetch
/// routinely fails.
Future<QfGoogleConfigState> qfRefreshGoogleRuntime() async {
  if (QfGoogleAuth.isConfigured) return QfGoogleConfigState.ready;
  final cached = await QfManifestService.loadCached();
  if (cached != null) {
    qfApplyGoogleRuntime(cached);
    if (QfGoogleAuth.isConfigured) return QfGoogleConfigState.ready;
  }
  final manifest = await QfManifestService.fetchRemote();
  if (manifest == null) {
    return QfGoogleAuth.isConfigured
        ? QfGoogleConfigState.ready
        : QfGoogleConfigState.networkFailed;
  }
  qfApplyGoogleRuntime(manifest);
  return QfGoogleAuth.isConfigured
      ? QfGoogleConfigState.ready
      : QfGoogleConfigState.unconfigured;
}

class _QfLoginFormState extends State<QfLoginForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _stepUpCode = TextEditingController();
  String? _emailError;
  String? _passwordError;
  String? _codeError;
  String? _stepUpError;
  String? _stepUpFailureText;
  bool _dual = false;
  bool _remember = true;
  bool _savePassword = false;

  @override
  void initState() {
    super.initState();
    _savePassword = widget.session.saveLoginCredentials;
    if (_savePassword) {
      unawaited(
        widget.session.loadSavedLogin().then((saved) {
          if (!mounted || saved == null) return;
          if (_email.text.isEmpty) _email.text = saved.id;
          if (_password.text.isEmpty) _password.text = saved.password;
        }),
      );
    }
    if (!QfGoogleAuth.isConfigured) {
      unawaited(
        qfRefreshGoogleRuntime().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _stepUpCode.dispose();
    super.dispose();
  }

  Future<void> _verifyStepUp() async {
    setState(() {
      _stepUpError = _stepUpCode.text.trim().isEmpty ? '请输入验证码' : null;
      _stepUpFailureText = null;
    });
    if (_stepUpError != null) throw const _QfSendAborted();
    try {
      await widget.session.verifyStepUp(_stepUpCode.text.trim());
    } on QfApiException catch (e) {
      if (e.code == 'ACCOUNT_FROZEN' && mounted) {
        final action = await qfShowFrozenDialog(
          context,
          message: e.message,
          frozenAt: (e.data['passwordFrozenAt'] as num?)?.toInt(),
        );
        if (mounted) {
          await qfHandleFrozenAction(
            context,
            session: widget.session,
            action: action,
            account: _email.text.trim(),
          );
        }
        return;
      }
      rethrow;
    }
  }

  Future<int?> _resendStepUp() async {
    await widget.session.resendStepUp();
    if (mounted) qfToast(context, '验证码已经重新发送至您的绑定邮箱');
    return null;
  }

  Future<int?> _sendLoginCode() async {
    await widget.session.loginRequestCode(_email.text);
    if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
    return null;
  }

  Future<void> _submit() async {
    setState(() {
      _emailError = _email.text.trim().isEmpty ? '请输入邮箱或 ID' : null;
      _passwordError = _password.text.isEmpty ? '请输入密码' : null;
      _codeError = null;
    });
    if (_emailError != null || _passwordError != null) {
      throw const _QfSendAborted();
    }
    try {
      final outcome = await widget.session.login(
        emailInput: _email.text,
        password: _password.text,
        emailCode: _dual ? _code.text : null,
        remember: _remember,
      );
      if (outcome.dualVerifyRequired && mounted) {
        setState(() => _dual = true);
        qfToast(context, outcome.message);
      } else if (widget.session.stepUpPending && mounted) {
        setState(() {});
      }
      if (_savePassword && widget.session.mode == QfMode.user) {
        await widget.session.storeSavedLogin(
          _email.text.trim(),
          _password.text,
        );
      }
    } on QfApiException catch (e) {
      if (mounted) {
        if (e.code == 'ACCOUNT_FROZEN') {
          final action = await qfShowFrozenDialog(
            context,
            message: e.message,
            frozenAt: (e.data['passwordFrozenAt'] as num?)?.toInt(),
          );
          if (mounted) {
            await qfHandleFrozenAction(
              context,
              session: widget.session,
              action: action,
              account: _email.text.trim(),
            );
          }
        } else if (e.code == 'ACCOUNT_BANNED') {
          final reason = (e.data['reason'] ?? '').toString();
          final cred = _password.text;
          await showDialog<void>(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                title: const Text('账户已被封禁'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(QfSessionController.formatBanNotice(e.data)),
                    if (reason.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('封禁原因：$reason'),
                      ),
                    QfBanAppealEntry(
                      session: widget.session,
                      identifier: _email.text.trim(),
                      credential: cred,
                      onAppeal: () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => QfAppealPage(
                              serverBaseUrl: widget.session.serverBaseUrl,
                              initialAccount: _email.text.trim(),
                              permanent: e.data['permanent'] == true,
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
        } else if (e.code == 'BAD_CREDENTIALS') {
          setState(() => _passwordError = qfAccountErrorMessage(e));
        } else {
          rethrow;
        }
      }
    }
  }

  Future<void> _passkeyLogin() async {
    try {
      final options = await widget.session.passkeyLoginOptions(
        _email.text.trim().isEmpty ? null : _email.text.trim(),
      );
      final response = await QfPasskeyCeremony.authenticate(options);
      await widget.session.passkeyLoginVerify(response, remember: _remember);
    } on QfApiException catch (e) {
      if (mounted) {
        if (e.code == 'ACCOUNT_FROZEN') {
          final action = await qfShowFrozenDialog(
            context,
            message: e.message,
            frozenAt: (e.data['passwordFrozenAt'] as num?)?.toInt(),
          );
          if (mounted) {
            await qfHandleFrozenAction(
              context,
              session: widget.session,
              action: action,
              account: _email.text.trim(),
            );
          }
        } else if (e.code == 'ACCOUNT_BANNED') {
          await qfShowBanDialog(
            context,
            session: widget.session,
            data: e.data,
            account: _email.text.trim(),
          );
        } else {
          rethrow;
        }
      }
    }
  }

  Future<void> _googleLogin() async {
    if (!QfGoogleAuth.isConfigured) {
      final configState = await qfRefreshGoogleRuntime();
      if (configState != QfGoogleConfigState.ready) {
        throw QfApiException(
          0,
          'NOT_CONFIGURED',
          configState == QfGoogleConfigState.networkFailed
              ? QfCopy.googleConfigNetworkHint
              : QfCopy.googleNotConfiguredHint,
        );
      }
      if (mounted) setState(() {});
    }
    try {
      final idToken = await QfGoogleAuth.fetchIdToken();
      await widget.session.googleLogin(idToken, remember: _remember);
      if (!mounted) return;
      if (widget.session.googleCompletionPending) {
        final outcome = await showDialog<QfCompletionOutcome>(
          context: context,
          builder: (_) => QfGoogleCompletionDialog(session: widget.session),
        );
        if (outcome != null && mounted) {
          if (outcome.banData != null) {
            await qfShowBanDialog(
              context,
              session: widget.session,
              data: outcome.banData!,
              account: widget.session.googleCompletionEmail ?? '',
              credential: outcome.banCredential,
            );
          } else if (outcome.message.isNotEmpty) {
            qfToast(context, outcome.message);
          }
        }
      } else if (widget.session.stepUpPending) {
        setState(() {});
      }
    } on QfApiException catch (e) {
      if (mounted) {
        if (e.code == 'ACCOUNT_FROZEN') {
          final action = await qfShowFrozenDialog(
            context,
            message: e.message,
            frozenAt: (e.data['passwordFrozenAt'] as num?)?.toInt(),
          );
          if (mounted) {
            await qfHandleFrozenAction(
              context,
              session: widget.session,
              action: action,
              account: _email.text.trim(),
            );
          }
        } else if (e.code == 'ACCOUNT_BANNED') {
          await qfShowBanDialog(
            context,
            session: widget.session,
            data: e.data,
            account: _email.text.trim(),
          );
        } else {
          rethrow;
        }
      }
    }
  }

  Future<void> _forgotPassword() async {
    await showDialog<void>(
      context: context,
      builder: (_) => QfResetPasswordDialog(
        session: widget.session,
        initialEmail: _email.text.trim().contains('@')
            ? _email.text.trim()
            : '',
      ),
    );
  }

  Future<void> _openRecoveryAppeal() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QfRecoveryAppealPage(
          session: widget.session,
          initialAccount: _email.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QfField(
          controller: _email,
          label: '邮箱或 ID',
          error: _emailError,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        QfField(
          controller: _password,
          label: '密码',
          error: _passwordError,
          obscure: true,
        ),
        if (_dual) ...[
          const SizedBox(height: 12),
          QfField(
            controller: _code,
            label: '邮箱验证码',
            error: _codeError,
            keyboardType: TextInputType.number,
            suffix: QfCodeSendButton(onSend: _sendLoginCode),
          ),
          const SizedBox(height: 8),
          const Text(
            '邮箱无法接收验证码？请发送邮件至 a718983610@gmail.com 申请人工核验，并附上您的账户ID或绑定邮箱。',
          ),
        ],
        if (widget.session.stepUpPending) ...[
          const SizedBox(height: 12),
          const Text('检测到本次登录环境异常。为保障账户安全，验证码已发送至您的绑定邮箱，请输入验证码完成验证。'),
          const SizedBox(height: 12),
          QfField(
            controller: _stepUpCode,
            label: '邮箱验证码',
            error: _stepUpError,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              QfCodeSendButton(
                onSend: _resendStepUp,
                label: '重新发送验证码',
                resendLabel: '重新发送验证码',
              ),
              const Spacer(),
              QfActionButton(
                label: '验证并登录',
                busyLabel: '正在验证……',
                showInlineError: false,
                onFailure: (failure) {
                  if (mounted) {
                    setState(() => _stepUpFailureText = failure.message);
                  }
                },
                onAction: _verifyStepUp,
              ),
            ],
          ),
          if (_stepUpFailureText != null) ...[
            const SizedBox(height: 8),
            Text(
              _stepUpFailureText!,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            '邮箱无法接收验证码？请发送邮件至 a718983610@gmail.com 申请人工核验，并附上您的账户ID或绑定邮箱。',
          ),
        ],
        CheckboxListTile(
          value: _savePassword,
          onChanged: (value) {
            final on = value ?? false;
            setState(() => _savePassword = on);
            if (!on) {
              unawaited(widget.session.clearSavedLogin());
            } else if (_email.text.trim().isNotEmpty &&
                _password.text.isNotEmpty) {
              unawaited(
                widget.session.storeSavedLogin(
                  _email.text.trim(),
                  _password.text,
                ),
              );
            }
          },
          title: const Text('记住账号密码'),
          subtitle: const Text('勾选后下次打开自动填好账号和密码，只保存在本机安全存储里；取消勾选立即清除。'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        CheckboxListTile(
          value: _remember,
          onChanged: (value) => setState(() => _remember = value ?? true),
          title: const Text('记住此设备'),
          subtitle: const Text('勾选后重开软件免输密码；不勾选则每次启动都需重新登录。'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        const SizedBox(height: 8),
        QfActionButton(label: '登录', busyLabel: '正在登录……', onAction: _submit),
        const SizedBox(height: 8),
        QfActionButton(
          label: '使用通行密钥登录',
          busyLabel: '正在验证通行密钥……',
          filled: false,
          onAction: _passkeyLogin,
        ),
        const SizedBox(height: 8),
        QfActionButton(
          label: '使用谷歌账号登录',
          busyLabel: '正在连接谷歌……',
          filled: false,
          onAction: _googleLogin,
        ),
        Row(
          children: [
            Flexible(
              child: TextButton(
                onPressed: _openRecoveryAppeal,
                child: const Text('邮箱不可用？提交找回申诉'),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: TextButton(
                onPressed: _forgotPassword,
                child: const Text('忘记密码'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class QfResetPasswordDialog extends StatefulWidget {
  final QfSessionController session;
  final String initialEmail;

  const QfResetPasswordDialog({
    super.key,
    required this.session,
    this.initialEmail = '',
  });

  @override
  State<QfResetPasswordDialog> createState() => _QfResetPasswordDialogState();
}

class _QfResetPasswordDialogState extends State<QfResetPasswordDialog> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _confirmError;
  String? _failureText;

  @override
  void initState() {
    super.initState();
    _email.text = widget.initialEmail;
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _failureText = !_email.text.trim().contains('@')
          ? '邮箱格式不正确'
          : _code.text.trim().isEmpty
          ? '请输入邮箱验证码'
          : _password.text.length < 8
          ? '新密码至少需要 8 位'
          : null;
      _confirmError = _password.text != _confirm.text
          ? QfCopy.passwordMismatch
          : null;
    });
    if (_failureText != null || _confirmError != null) {
      throw const _QfSendAborted();
    }
    await widget.session.resetConfirm(
      emailInput: _email.text,
      code: _code.text,
      newPassword: _password.text,
    );
    if (mounted) {
      Navigator.of(context).pop();
      qfToast(context, '密码已经重置，请使用新密码登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('找回密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QfField(
              controller: _email,
              label: '邮箱',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            QfField(
              controller: _code,
              label: '邮箱验证码',
              keyboardType: TextInputType.number,
              suffix: QfCodeSendButton(
                onSend: () async {
                  await widget.session.resetRequestCode(_email.text);
                  if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
                  return null;
                },
              ),
            ),
            const SizedBox(height: 12),
            QfField(controller: _password, label: '新密码', obscure: true),
            const SizedBox(height: 12),
            QfField(
              controller: _confirm,
              label: '确认新密码',
              obscure: true,
              error: _confirmError,
            ),
            if (_failureText != null) ...[
              const SizedBox(height: 12),
              Text(
                _failureText!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        QfActionButton(
          label: '重置密码',
          busyLabel: '正在重置……',
          showInlineError: false,
          onFailure: (failure) {
            if (mounted) setState(() => _failureText = failure.message);
          },
          onAction: _submit,
        ),
      ],
    );
  }
}

class QfRegisterForm extends StatefulWidget {
  final QfSessionController session;

  const QfRegisterForm({super.key, required this.session});

  @override
  State<QfRegisterForm> createState() => _QfRegisterFormState();
}

class _QfRegisterFormState extends State<QfRegisterForm> {
  final _id = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _idError;
  String? _emailError;
  String? _codeError;
  String? _passwordError;
  String? _confirmError;
  String? _formError;
  String? _ticket;
  String _ticketKey = '';

  @override
  void dispose() {
    _id.dispose();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<int?> _sendRegisterCode() async {
    setState(() {
      _emailError = _email.text.trim().contains('@') ? null : '邮箱格式不正确';
    });
    if (_emailError != null) throw const _QfSendAborted();
    await widget.session.registerRequestCode(_email.text);
    if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
    return null;
  }

  Future<void> _submit() async {
    setState(() {
      _idError = qfUsernameError(_id.text);
      _emailError = _email.text.trim().contains('@') ? null : '邮箱格式不正确';
      _passwordError = _password.text.length < 8 ? '密码至少需要 8 位' : null;
      _confirmError = _password.text != _confirm.text
          ? QfCopy.passwordMismatch
          : null;
      _codeError = _code.text.trim().isEmpty ? '请输入邮箱验证码' : null;
      _formError = null;
    });
    if (_idError != null ||
        _emailError != null ||
        _codeError != null ||
        _passwordError != null ||
        _confirmError != null) {
      throw const _QfSendAborted();
    }
    try {
      final key = '${_email.text.trim()}|${_code.text.trim()}';
      if (_ticket == null || _ticketKey != key) {
        _ticket = await widget.session.registerVerify(_email.text, _code.text);
        _ticketKey = key;
      }
      await widget.session.registerComplete(
        ticket: _ticket!,
        password: _password.text,
        usernameInput: _id.text,
      );
    } on QfApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'REGISTRATION_FROZEN') {
        widget.session.captureRegistrationFrozen(e);
        await qfShowRegistrationFrozenDialog(
          context,
          message: e.message,
          data: e.data,
        );
        return;
      }
      setState(() {
        if (e.code.contains('USERNAME') ||
            e.message.contains('已被注册') ||
            e.message.contains('账户 ID') ||
            e.message.contains('账户ID')) {
          _idError = qfAccountErrorMessage(e);
        } else if (e.message.contains('验证已经过期')) {
          // The ticket itself is dead (expired or already consumed):
          // drop it and send the user back to requesting a fresh code
          // instead of retrying the same dead ticket forever (C-17).
          _ticket = null;
          _ticketKey = '';
          _codeError = qfAccountErrorMessage(e);
        } else if (e.message.contains('验证码')) {
          _codeError = qfAccountErrorMessage(e);
          _ticket = null;
        } else if (e.message.contains('密码')) {
          _passwordError = qfAccountErrorMessage(e);
        } else if (e.message.contains('邮箱')) {
          _emailError = qfAccountErrorMessage(e);
        } else {
          // Unknown errors belong to the form, not the code field;
          // the ticket stays cached because the server only consumes
          // it once every gate has passed (C-17).
          _formError = qfAccountErrorMessage(e);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QfField(controller: _id, label: '账户 ID', error: _idError),
        Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            QfCopy.usernameRuleHint,
            style: AppTextStyle.caption1.of(context),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('账户ID一经设置不可更改，请谨慎填写。'),
        ),
        const SizedBox(height: 12),
        QfField(
          controller: _email,
          label: '邮箱',
          error: _emailError,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        QfField(
          controller: _password,
          label: '密码',
          error: _passwordError,
          obscure: true,
        ),
        const SizedBox(height: 12),
        QfField(
          controller: _confirm,
          label: '重复密码',
          error: _confirmError,
          obscure: true,
        ),
        const SizedBox(height: 12),
        QfField(
          controller: _code,
          label: '邮箱验证码',
          error: _codeError,
          keyboardType: TextInputType.number,
          suffix: QfCodeSendButton(
            onSend: _sendRegisterCode,
            onError: (error) {
              if (error is _QfSendAborted) return;
              if (mounted) {
                setState(() => _emailError = qfAccountErrorMessage(error));
              }
            },
          ),
        ),
        if (_formError != null) ...[
          const SizedBox(height: 12),
          Text(
            _formError!,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        QfActionButton(label: '注册并登录', busyLabel: '正在注册……', onAction: _submit),
      ],
    );
  }
}

class QfCompletionOutcome {
  const QfCompletionOutcome({
    required this.message,
    this.banData,
    this.banCredential,
  });

  final String message;
  final Map<String, dynamic>? banData;
  final String? banCredential;
}

class QfGoogleCompletionDialog extends StatefulWidget {
  final QfSessionController session;

  const QfGoogleCompletionDialog({super.key, required this.session});

  @override
  State<QfGoogleCompletionDialog> createState() =>
      _QfGoogleCompletionDialogState();
}

class _QfGoogleCompletionDialogState extends State<QfGoogleCompletionDialog> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _idError;
  String? _passwordError;
  String? _confirmError;
  String? _failureText;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _idError = qfUsernameError(_id.text);
      _passwordError = _password.text.length < 8 ? '密码至少要 8 位' : null;
      _confirmError = _password.text != _confirm.text
          ? QfCopy.passwordMismatch
          : null;
    });
    if (_idError != null || _passwordError != null || _confirmError != null) {
      throw const _QfSendAborted();
    }
    final pw = _password.text;
    try {
      await widget.session.completeGoogleSetup(
        username: _id.text.trim(),
        password: pw,
      );
      if (mounted) Navigator.of(context).pop();
    } on QfApiException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case 'USERNAME_TAKEN':
        case 'USERNAME_INVALID':
        case 'USERNAME_IMMUTABLE':
          setState(() => _idError = qfAccountErrorMessage(e));
        case 'ACCOUNT_FROZEN':
          {
            final action = await qfShowFrozenDialog(
              context,
              message: e.message,
              frozenAt: (e.data['passwordFrozenAt'] as num?)?.toInt(),
            );
            if (mounted) {
              await qfHandleFrozenAction(
                context,
                session: widget.session,
                action: action,
                account: widget.session.googleCompletionEmail ?? '',
              );
            }
          }
        case 'REGISTRATION_FROZEN':
          {
            widget.session.captureRegistrationFrozen(e);
            await qfShowRegistrationFrozenDialog(
              context,
              message: e.message,
              data: e.data,
            );
          }
        case 'ACCOUNT_BANNED':
          Navigator.of(context).pop(
            QfCompletionOutcome(
              message: e.message,
              banData: e.data,
              banCredential: pw,
            ),
          );
        case 'GOOGLE_COMPLETION_INVALID':
        case 'GOOGLE_ALREADY_COMPLETED':
        case 'DEVICE_BANNED':
          Navigator.of(context).pop(QfCompletionOutcome(message: e.message));
        case 'BAD_REQUEST':
          if (e.message.contains('密码')) {
            setState(() => _passwordError = qfAccountErrorMessage(e));
          } else {
            rethrow;
          }
        default:
          rethrow;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.session.googleCompletionEmail;
    return AlertDialog(
      title: const Text('设置账户ID和密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('请设置账户ID与登录密码以完成注册。设置完成后，可使用账户ID或邮箱加密码登录。'),
            if (email != null && email.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('账号邮箱：$email'),
            ],
            const SizedBox(height: 12),
            QfField(controller: _id, label: '账户 ID', error: _idError),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                QfCopy.usernameRuleHint,
                style: AppTextStyle.caption1.of(context),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('账户ID一经设置不可更改，请谨慎填写。'),
            ),
            const SizedBox(height: 12),
            QfField(
              controller: _password,
              label: '密码',
              error: _passwordError,
              obscure: true,
            ),
            const SizedBox(height: 12),
            QfField(
              controller: _confirm,
              label: '重复密码',
              error: _confirmError,
              obscure: true,
            ),
            if (_failureText != null) ...[
              const SizedBox(height: 12),
              Text(
                _failureText!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        QfActionButton(
          label: '完成设置',
          busyLabel: '正在设置……',
          showInlineError: false,
          onFailure: (failure) {
            if (mounted) setState(() => _failureText = failure.message);
          },
          onAction: _submit,
        ),
      ],
    );
  }
}

class QfCompleteUsernameDialog extends StatefulWidget {
  final QfSessionController session;

  const QfCompleteUsernameDialog({super.key, required this.session});

  @override
  State<QfCompleteUsernameDialog> createState() =>
      _QfCompleteUsernameDialogState();
}

class _QfCompleteUsernameDialogState extends State<QfCompleteUsernameDialog> {
  final _id = TextEditingController();
  String? _idError;
  String? _failureText;

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _idError = qfUsernameError(_id.text));
    if (_idError != null) throw const _QfSendAborted();
    try {
      await widget.session.completeUsername(_id.text.trim());
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, '账户ID已设置。');
      }
    } on QfApiException catch (e) {
      if (mounted) setState(() => _idError = qfAccountErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置账户ID'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            QfField(controller: _id, label: '账户 ID', error: _idError),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                QfCopy.usernameRuleHint,
                style: AppTextStyle.caption1.of(context),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('账户ID一经设置不可更改，请谨慎填写。'),
            ),
            if (_failureText != null) ...[
              const SizedBox(height: 12),
              Text(
                _failureText!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        QfActionButton(
          label: '确认设置',
          busyLabel: '正在设置……',
          showInlineError: false,
          onFailure: (failure) {
            if (mounted) setState(() => _failureText = failure.message);
          },
          onAction: _submit,
        ),
      ],
    );
  }
}

String qfDeletionSubtitle(int? deletionEffectiveAt) {
  final when = qfFormatEpochSeconds(deletionEffectiveAt);
  if (when.isEmpty) return '冷静期结束前登录即可撤销注销';
  return '注销将于 $when 生效，生效前登录即可撤销注销';
}

class QfMinePage extends StatelessWidget {
  final QfSessionController session;

  const QfMinePage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final points = session.pointsMe;
        return Scaffold(
          appBar: AppBar(title: const Text('我的')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          QfMyAvatarButton(
                            session: session,
                            name: session.email ?? '',
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              session.email ?? '',
                              style: AppTextStyle.headline.of(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text('点击头像可更换头像'),
                      const SizedBox(height: 4),
                      const Text(QfCopy.loginBenefit),
                      const SizedBox(height: 12),
                      Text(
                        '积分余额：${points?['balance'] ?? 0} 分'
                        '（累计获得 ${points?['totalEarned'] ?? 0} 分，'
                        '累计消费 ${points?['totalSpent'] ?? 0} 分）',
                      ),
                      if (points != null)
                        Text(
                          '本轮已累计 ${points['pendingMinutes'] ?? 0} 分钟，'
                          '距离下 1 分还差 ${points['minutesToNextPoint'] ?? 0} 分钟',
                        ),
                      if (session.heartbeatNotice != null)
                        Text(session.heartbeatNotice!),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (session.accountIncomplete)
                Card(
                  child: ListTile(
                    title: const Text('您的账号尚未设置账户ID'),
                    subtitle: const Text('设置账户ID后，好友可通过账户ID或二维码找到您。'),
                    trailing: TextButton(
                      onPressed: () async {
                        await showDialog<void>(
                          context: context,
                          builder: (_) =>
                              QfCompleteUsernameDialog(session: session),
                        );
                      },
                      child: const Text('立即设置'),
                    ),
                  ),
                ),
              QfMyQrCard(session: session),
              if (session.accountDeleting)
                Card(
                  child: ListTile(
                    title: const Text('账号正在注销冷静期内'),
                    subtitle: Text(
                      qfDeletionSubtitle(session.deletionEffectiveAt),
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        try {
                          await session.authed(
                            'POST',
                            '/security/delete-account/cancel',
                            body: {},
                          );
                          await session.refreshAccountState();
                          await session.refreshPoints();
                          if (context.mounted) {
                            qfToast(context, '注销已经撤销，账号恢复正常');
                          }
                        } on QfApiException catch (e) {
                          if (context.mounted)
                            qfToast(context, qfAccountErrorMessage(e));
                        }
                      },
                      child: const Text('撤销注销'),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.star),
                title: const Text('我的积分'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QfPointsPage(session: session),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.sparkle),
                title: const Text('积分兑换'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QfRedeemPage(session: session),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.account),
                title: const Text('个人资料'),
                subtitle: const Text('昵称与头像，好友聊天与论坛共用'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QfProfilePage(session: session),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.lock),
                title: const Text('安全中心'),
                subtitle: const Text('修改密码、换绑邮箱、登录设备、注销账号'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QfSecurityPage(session: session),
                    ),
                  );
                },
              ),
              QfOwnerEntryTile(session: session),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.sync),
                title: const Text('软件更新'),
                subtitle: Text('当前版本 v${QfRuntime.appVersion}'),
                onTap: () {
                  QfUpdateFlow.runManualCheck(context);
                },
              ),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.compose),
                title: const Text('意见反馈'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => QfFeedbackPage(session: session),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () async {
                  await session.logout();
                },
                child: const Text('退出登录'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class QfMyQrCard extends StatefulWidget {
  final QfSessionController session;

  const QfMyQrCard({super.key, required this.session});

  @override
  State<QfMyQrCard> createState() => _QfMyQrCardState();
}

class _QfMyQrCardState extends State<QfMyQrCard> {
  final _qrKey = GlobalKey();
  String? _username;

  @override
  void initState() {
    super.initState();
    _username = widget.session.username;
    if (_username == null || _username!.isEmpty) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final profile = await widget.session.socialGetProfile();
      final name = profile['username'];
      if (mounted && name is String && name.isNotEmpty) {
        setState(() => _username = name);
      }
    } catch (_) {}
  }

  Future<void> _saveQr() async {
    final boundary =
        _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final dir =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/qfclash-qrcode.png');
    await file.writeAsBytes(data.buffer.asUint8List());
    if (mounted) qfToast(context, '二维码已经保存到 ${file.path}');
  }

  @override
  Widget build(BuildContext context) {
    final username = _username;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('我的二维码', style: AppTextStyle.headline.of(context)),
            const SizedBox(height: 4),
            const Text('好友扫码即可查看您的资料并添加好友'),
            const SizedBox(height: 12),
            if (username != null && username.isNotEmpty)
              RepaintBoundary(
                key: _qrKey,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(
                    data: username,
                    version: QrVersions.auto,
                    size: 180,
                  ),
                ),
              )
            else
              const Text('账户 ID 加载中'),
            const SizedBox(height: 8),
            Text('账户 ID：${username ?? ''}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(onPressed: _saveQr, child: const Text('保存二维码')),
                OutlinedButton(
                  onPressed: username == null
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: username));
                          qfToast(context, '账户 ID 已经复制');
                        },
                  child: const Text('复制账户 ID'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String qfPointsTypeLabel(String type) {
  return switch (type) {
    'earn_settle' => '计时结算',
    'redeem' => '兑换扣分',
    'redeem_freeze' => '兑换冻结',
    'redeem_refund' => '兑换退回',
    'redeem_confiscate' => '审核没收',
    'redeem_confirm' => '审核确认',
    'admin_clear' => '处置清分',
    'admin_adjust' => '手工调整',
    'forum_daily' => '论坛每日积分',
    'forum_daily_reversal' => '论坛积分回冲',
    'forum_milestone' => '论坛千赞奖励',
    _ => type,
  };
}

int qfPointsDailyRemaining({required int dailyCap, required int mintedToday}) {
  final remaining = dailyCap - mintedToday;
  return remaining > 0 ? remaining : 0;
}

class QfPointsPage extends StatefulWidget {
  final QfSessionController session;

  const QfPointsPage({super.key, required this.session});

  @override
  State<QfPointsPage> createState() => _QfPointsPageState();
}

class _QfPointsPageState extends State<QfPointsPage> {
  List<dynamic> _entries = const [];
  Map<String, dynamic>? _rules;
  bool _loading = true;
  bool _entriesFailed = false;
  bool _rulesFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await widget.session.pointsLedger();
      if (mounted) {
        setState(() {
          _entries = entries;
          _entriesFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _entriesFailed = true);
    }
    try {
      final rules = await widget.session.pointsRules();
      if (mounted) {
        setState(() {
          _rules = rules;
          _rulesFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _rulesFailed = true);
    }
    if (mounted) setState(() => _loading = false);
    await widget.session.refreshPoints();
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.session.pointsMe;
    final params = _rules?['params'];
    return Scaffold(
      appBar: AppBar(title: const Text('我的积分')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '当前余额：${points == null ? '—' : points['balance'] ?? 0} 分',
                          style: AppTextStyle.headline.of(context),
                        ),
                        const SizedBox(height: 8),
                        if (points == null)
                          const Text('余额信息暂时无法加载，请稍后重试。')
                        else ...[
                          Text(
                            '累计获得 ${points['totalEarned'] ?? 0} 分 · '
                            '累计消费 ${points['totalSpent'] ?? 0} 分 · '
                            '今日已获得 ${points['mintedToday'] ?? 0} 分',
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '今日还可累计 ${qfPointsDailyRemaining(dailyCap: (points['dailyCap'] as num?)?.toInt() ?? (params?['dailyCapPoints'] as num?)?.toInt() ?? 8, mintedToday: (points['mintedToday'] as num?)?.toInt() ?? 0)} 分',
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: ((points['pendingMinutes'] as num? ?? 0) /
                                    (points['minutesPerPoint'] as num? ?? 180))
                                .clamp(0, 1)
                                .toDouble(),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '本轮进度：已累计 ${points['pendingMinutes'] ?? 0} 分钟，'
                            '距离下 1 分还差 ${points['minutesToNextPoint'] ?? 0} 分钟',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('积分明细', style: AppTextStyle.headline.of(context)),
                if (_entriesFailed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: TextButton(
                      onPressed: _load,
                      child: const Text('积分明细加载失败，点击重试'),
                    ),
                  )
                else if (_entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无积分记录'),
                  ),
                for (final raw in _entries)
                  if (raw is Map)
                    ListTile(
                      title: Text(
                        qfPointsTypeLabel((raw['type'] ?? '').toString()),
                      ),
                      subtitle: Text(
                        '${DateTime.fromMillisecondsSinceEpoch(((raw['created_at'] as num? ?? 0) * 1000).toInt())}'
                        '${(raw['note'] ?? '').toString().isNotEmpty ? '\n${raw['note']}' : ''}',
                      ),
                      trailing: Text(
                        '${(raw['amount'] as num? ?? 0) > 0 ? '+' : ''}${raw['amount']}',
                      ),
                    ),
                const SizedBox(height: 16),
                Text('积分规则', style: AppTextStyle.headline.of(context)),
                const SizedBox(height: 8),
                if (_rulesFailed)
                  TextButton(
                    onPressed: _load,
                    child: const Text('积分规则加载失败，点击重试'),
                  )
                else if (_rules == null)
                  const Text('积分规则暂时无法加载。')
                else
                  Text(
                    '连接有效使用才计时：每累计 ${params?['minutesPerPoint'] ?? 180} 分钟得 1 分，'
                    '未满部分不清零；每日最多 ${params?['dailyCapPoints'] ?? 8} 分（账号与设备双限）。'
                    '计时以服务器为准；模拟器、改机、多开环境与长时间零流量不计分。'
                    '作弊将面临清分、封号与封设备处置。如有疑问或需要申诉，'
                    '请发送邮件至 ${_rules?['appealEmail'] ?? QfConfig.contactEmail}。',
                  ),
              ],
            ),
    );
  }
}

/// 站长判断：三种下发口径全认——本人/站长台视图的 isOwner、公开视图的
/// ownerBadge（'green'）、原始行形状的 is_owner，任一命中即站长。
bool qfUserIsOwner(Map? user) {
  if (user == null) return false;
  return user['isOwner'] == true ||
      user['ownerBadge'] == 'green' ||
      user['is_owner'] == 1 ||
      user['is_owner'] == true;
}

/// 绿色站长标识：挂在站长昵称旁，全站统一这一个组件。
class QfOwnerBadge extends StatelessWidget {
  const QfOwnerBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const ShapeDecoration(
        color: Color(0xFF1DA851),
        shape: AppShape.sm,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          '站长',
          style: AppTextStyle.caption2
              .of(context, emphasized: true)
              .copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

/// 昵称与（站长时的）绿标同一行，各处显示用户昵称统一用它。
class QfBadgedName extends StatelessWidget {
  final String name;
  final bool isOwner;
  final TextStyle? style;

  const QfBadgedName({
    super.key,
    required this.name,
    required this.isOwner,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(name, style: style, overflow: TextOverflow.ellipsis),
        ),
        if (isOwner) ...[const SizedBox(width: 6), const QfOwnerBadge()],
      ],
    );
  }
}

String qfStockLabel(Map<dynamic, dynamic> product) {
  final status = (product['stockStatus'] ?? '').toString();
  final stock = (product['stock'] as num?)?.toInt();
  return switch (status) {
    'sold_out' => '已售罄',
    'low' => stock != null ? '仅剩 $stock 件' : '余量不多',
    'manual' => '',
    'in_stock' => '有货',
    'out_of_stock' => '已售罄',
    'low_stock' => '仅剩 ${stock ?? 0} 件',
    _ => '有货',
  };
}

bool qfStockSoldOut(Map<dynamic, dynamic> product) {
  final status = (product['stockStatus'] ?? '').toString();
  return status == 'sold_out' || status == 'out_of_stock';
}

bool qfOrderCancellable(Map<dynamic, dynamic> order) {
  final status = (order['status'] ?? '').toString();
  return status == 'pending_review' || status == 'pending_payout';
}

bool qfOrderCanChangePayoutAddress(Map<dynamic, dynamic> order) {
  return (order['status'] ?? '').toString() == 'pending_review' &&
      (order['payoutMethod'] ?? '').toString() == 'usdt';
}

class QfRedeemPage extends StatefulWidget {
  final QfSessionController session;

  const QfRedeemPage({super.key, required this.session});

  @override
  State<QfRedeemPage> createState() => _QfRedeemPageState();
}

/// Safe id extraction for order/product rows: a missing or non-numeric
/// id must surface as a visible data error, never a silent dead
/// button via a throwing cast (C-22).
int? qfRowId(Map<dynamic, dynamic> row) {
  final raw = row['id'];
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw');
}

class _QfRedeemPageState extends State<QfRedeemPage> {
  List<dynamic> _products = const [];
  List<dynamic> _orders = const [];
  int? _balance;
  bool _loading = true;
  bool _productsFailed = false;
  bool _ordersFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.redeemProducts();
      if (mounted) {
        setState(() {
          final products = data['products'];
          _products = products is List ? products : const [];
          _balance = (data['balance'] as num?)?.toInt();
          _productsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _productsFailed = true);
    }
    try {
      final orders = await widget.session.myOrders();
      if (mounted) {
        setState(() {
          _orders = orders;
          _ordersFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _ordersFailed = true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _redeem(Map<dynamic, dynamic> product) async {
    final outcome = await showDialog<String>(
      context: context,
      builder: (_) => _QfRedeemDialog(
        session: widget.session,
        product: product,
        balance: _balance ?? 0,
      ),
    );
    if (!mounted) return;
    if (outcome == 'done') {
      qfToast(context, '兑换申请已提交');
      await _load();
      await widget.session.refreshPoints();
    }
  }

  Future<void> _cancelOrder(Map<dynamic, dynamic> order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(QfCopy.orderCancel),
          content: const Text(QfCopy.orderCancelConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('再想想'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(QfCopy.orderCancel),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final orderId = qfRowId(order);
    if (orderId == null) {
      if (mounted) qfToast(context, '数据异常，请刷新后重试。');
      return;
    }
    try {
      await widget.session.redeemCancelOrder(orderId);
      if (mounted) qfToast(context, QfCopy.orderCancelledDone);
      await _load();
      await widget.session.refreshPoints();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    }
  }

  Future<void> _changeOrderAddress(Map<dynamic, dynamic> order) async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => _QfChangeAddressDialog(
        initial: (order['payoutAddress'] ?? '').toString(),
      ),
    );
    if (address == null) return;
    if (address.isEmpty) {
      if (mounted) qfToast(context, '收款地址不能为空，修改已取消。');
      return;
    }
    final orderId = qfRowId(order);
    if (orderId == null) {
      if (mounted) qfToast(context, '数据异常，请刷新后重试。');
      return;
    }
    try {
      await widget.session.redeemChangePayoutAddress(orderId, address);
      if (mounted) qfToast(context, QfCopy.orderChangeAddressDone);
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    }
  }

  Future<void> _showReveal(Map<dynamic, dynamic> order) async {
    final orderId = qfRowId(order);
    if (orderId == null) {
      if (mounted) qfToast(context, '数据异常，请刷新后重试。');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _QfRevealCodeDialog(
        session: widget.session,
        orderId: orderId,
      ),
    );
    await _load();
  }

  String _orderStatusLabel(Map<dynamic, dynamic> order) {
    return switch ((order['status'] ?? '').toString()) {
      'issued' => '已发放',
      'pending_review' => '待审核',
      'pending_payout' => '待打款',
      'paid' => '已打款',
      'rejected' => '已驳回',
      'rejected_fraud' => '已驳回（查实作弊，积分已没收）',
      'refunded' => '已退分',
      'superseded' => '已被补发订单替代',
      'cancelled' => '已取消',
      'expired' => '已过期',
      _ => (order['status'] ?? '').toString(),
    };
  }

  bool _canRevealCode(Map<dynamic, dynamic> order) {
    if (order['codeAvailable'] != true) return false;
    final method = (order['payoutMethod'] ?? order['fulfillment'] ?? '')
        .toString();
    return method != 'usdt';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('积分兑换')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('当前积分：${_balance ?? '—'} 分'),
                const SizedBox(height: 12),
                if (_productsFailed)
                  TextButton(
                    onPressed: _load,
                    child: const Text('商品加载失败，点击重试'),
                  ),
                for (final raw in _products)
                  if (raw is Map)
                    Card(
                      child: ListTile(
                        title: Text((raw['name'] ?? '').toString()),
                        subtitle: Text(
                          '${raw['description'] ?? ''}\n'
                          '${raw['pricePoints']} 积分'
                          '${qfStockLabel(raw).isEmpty ? '' : ' · ${qfStockLabel(raw)}'}'
                          '${raw['requiresReview'] == true ? ' · 需人工审核' : ''}',
                        ),
                        isThreeLine: true,
                        trailing: FilledButton(
                          onPressed:
                              qfStockSoldOut(raw) ||
                                  (_balance ?? 0) <
                                      ((raw['pricePoints'] as num?)?.toInt() ??
                                          0)
                              ? null
                              : () => _redeem(raw),
                          child: Text(
                            (_balance ?? 0) <
                                    ((raw['pricePoints'] as num?)?.toInt() ?? 0)
                                ? '还差 ${((raw['pricePoints'] as num?)?.toInt() ?? 0) - (_balance ?? 0)} 分'
                                : '兑换',
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
                Text('我的兑换', style: AppTextStyle.headline.of(context)),
                if (_ordersFailed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: TextButton(
                      onPressed: _load,
                      child: const Text('兑换记录加载失败，点击重试'),
                    ),
                  )
                else if (_orders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无兑换记录'),
                  ),
                for (final raw in _orders)
                  if (raw is Map)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          title: Text((raw['productName'] ?? '').toString()),
                          subtitle: Text(
                            '${_orderStatusLabel(raw)}'
                            '${raw['payoutAddress'] != null ? '\n收款地址：${raw['payoutAddress']}' : ''}'
                            '${raw['payoutEmail'] != null ? '\n通知邮箱：${raw['payoutEmail']}' : ''}'
                            '${raw['paidAt'] != null ? '\n打款时间：${DateTime.fromMillisecondsSinceEpoch((((raw['paidAt'] as num?) ?? 0) * 1000).toInt())}' : ''}'
                            '${raw['paidTx'] != null && raw['paidTx'].toString().isNotEmpty ? '\n打款交易号：${raw['paidTx']}' : ''}'
                            '${raw['reviewReason'] != null ? '\n驳回原因：${raw['reviewReason']}' : ''}',
                          ),
                          trailing: _canRevealCode(raw)
                              ? TextButton(
                                  onPressed: () => _showReveal(raw),
                                  child: const Text('查看兑换码'),
                                )
                              : null,
                        ),
                        if (qfOrderCanChangePayoutAddress(raw) ||
                            qfOrderCancellable(raw))
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Wrap(
                              children: [
                                if (qfOrderCanChangePayoutAddress(raw))
                                  TextButton(
                                    onPressed: () => _changeOrderAddress(raw),
                                    child: const Text(
                                      QfCopy.orderChangeAddress,
                                    ),
                                  ),
                                if (qfOrderCancellable(raw))
                                  TextButton(
                                    onPressed: () => _cancelOrder(raw),
                                    child: const Text(QfCopy.orderCancel),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
              ],
            ),
    );
  }
}

/// Address editor that owns its controller for its whole lifetime:
/// disposing a controller the caller created while the dialog is
/// still leaving the tree is a use-after-dispose hazard (C-Q3), and
/// an emptied field must be distinguishable from a cancel (C-23).
class _QfChangeAddressDialog extends StatefulWidget {
  final String initial;

  const _QfChangeAddressDialog({required this.initial});

  @override
  State<_QfChangeAddressDialog> createState() => _QfChangeAddressDialogState();
}

class _QfChangeAddressDialogState extends State<_QfChangeAddressDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(QfCopy.orderChangeAddress),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(labelText: 'USDT（TRC20）收款地址'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _QfRedeemDialog extends StatefulWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> product;
  final int balance;

  const _QfRedeemDialog({
    required this.session,
    required this.product,
    required this.balance,
  });

  @override
  State<_QfRedeemDialog> createState() => _QfRedeemDialogState();
}

class _QfRedeemDialogState extends State<_QfRedeemDialog> {
  final _address = TextEditingController();
  final _email = TextEditingController();
  String _method = 'usdt';
  String? _fieldError;

  String get _fulfillment =>
      (widget.product['fulfillment'] ?? '').toString().toLowerCase();

  bool get _needsChoice => _fulfillment == 'choice';

  bool get _needsPayout => _needsChoice || _fulfillment == 'usdt';

  @override
  void initState() {
    super.initState();
    _email.text = widget.session.email ?? '';
  }

  @override
  void dispose() {
    _address.dispose();
    _email.dispose();
    super.dispose();
  }

  bool _validate() {
    if (!_needsPayout) return true;
    if (_method == 'usdt') {
      final ok = RegExp(
        r'^T[1-9A-HJ-NP-Za-km-z]{33}$',
      ).hasMatch(_address.text.trim());
      setState(
        () => _fieldError = ok ? null : '请输入正确的 USDT（TRC20）收款地址（以 T 开头，共 34 位）',
      );
      return ok;
    }
    final ok = RegExp(
      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
    ).hasMatch(_email.text.trim());
    setState(() => _fieldError = ok ? null : '请输入正确的邮箱地址');
    return ok;
  }

  Future<void> _confirm() async {
    if (!_validate()) return;
    final productId = qfRowId(widget.product);
    if (productId == null) {
      if (mounted) qfToast(context, '数据异常，请刷新后重试。');
      return;
    }
    try {
      await widget.session.redeemCreate(
        productId,
        payoutMethod: _needsPayout ? _method : null,
        payoutAddress: _needsPayout && _method == 'usdt'
            ? _address.text.trim()
            : null,
        payoutEmail: _needsPayout && _method == 'giftcard'
            ? _email.text.trim()
            : null,
      );
      if (mounted) Navigator.of(context).pop('done');
    } on QfApiException catch (e) {
      if (!mounted) return;
      qfToast(context, qfAccountErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = (widget.product['pricePoints'] as num?)?.toInt() ?? 0;
    return AlertDialog(
      title: const Text('确认兑换'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将花费 $price 积分兑换「${widget.product['name']}」，兑换后余额为 ${widget.balance - price} 分。'
              '${widget.product['requiresReview'] == true ? '该商品需人工审核，审核通过后发放。' : ''}',
            ),
            if (_needsChoice) ...[
              const SizedBox(height: 16),
              const Text('请选择发放方式'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment<String>(value: 'usdt', label: Text('USDT')),
                  ButtonSegment<String>(
                    value: 'giftcard',
                    label: Text('美区礼品卡'),
                  ),
                ],
                selected: {_method},
                onSelectionChanged: (value) {
                  setState(() {
                    _method = value.first;
                    _fieldError = null;
                  });
                },
              ),
            ],
            if (_needsPayout && _method == 'usdt') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _address,
                decoration: InputDecoration(
                  labelText: 'USDT（TRC20）收款地址',
                  hintText: '以 T 开头，共 34 位',
                  errorText: _fieldError,
                ),
              ),
              const SizedBox(height: 4),
              const Text('请仔细核对，打款后无法撤销。'),
            ],
            if (_needsPayout && _method == 'giftcard') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: '接收发放通知的邮箱',
                  errorText: _fieldError,
                ),
              ),
              const SizedBox(height: 4),
              const Text('该邮箱仅用于接收发放通知与发放信息，兑换码请到「我的兑换」中查看。'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        QfActionButton(
          label: '确认兑换',
          busyLabel: '正在兑换……',
          showInlineError: false,
          onFailure: (failure) {
            if (mounted) qfToast(context, failure.message);
          },
          onAction: _confirm,
        ),
      ],
    );
  }
}

class _QfRevealCodeDialog extends StatefulWidget {
  final QfSessionController session;
  final int orderId;

  const _QfRevealCodeDialog({required this.session, required this.orderId});

  @override
  State<_QfRevealCodeDialog> createState() => _QfRevealCodeDialogState();
}

class _QfRevealCodeDialogState extends State<_QfRevealCodeDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  Timer? _maskTimer;
  String? _revealedCode;
  String? _reauthToken;

  Future<void> _passkeyVerify() async {
    try {
      final token = await qfPasskeyReauthToken(widget.session, 'reveal_code');
      if (mounted) {
        setState(() => _reauthToken = token);
        qfToast(context, '通行密钥验证已通过，请继续输入邮箱验证码完成查看');
      }
    } on QfApiException catch (e) {
      if (mounted) {
        qfToast(
          context,
          e.code == 'PASSKEY_NOT_ENROLLED'
              ? '您尚未创建通行密钥，请使用账户密码验证'
              : qfAccountErrorMessage(e),
        );
      }
    } catch (e) {
      if (mounted) qfToast(context, qfPasskeyFailureText(e));
    }
  }

  @override
  void dispose() {
    _maskTimer?.cancel();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<int?> _requestCode() async {
    await widget.session.redeemCodeRequest(widget.orderId);
    if (mounted) {
      qfToast(context, '一次性验证码已发送至账号绑定邮箱，10 分钟内有效');
    }
    return null;
  }

  Future<void> _reveal() async {
    if (_code.text.trim().isEmpty) {
      qfToast(context, '请输入邮箱验证码');
      return;
    }
    if (_reauthToken == null && _password.text.isEmpty) {
      qfToast(context, '请输入账户密码，或先使用通行密钥验证');
      return;
    }
    try {
      final String code;
      if (_reauthToken != null) {
        final data = await widget.session.authed(
          'POST',
          '/redeem/orders/${widget.orderId}/code/reveal',
          body: {'reauthToken': _reauthToken, 'emailCode': _code.text.trim()},
        );
        code = (data['code'] ?? '').toString();
      } else {
        code = await widget.session.redeemCodeReveal(
          widget.orderId,
          _password.text,
          _code.text,
        );
      }
      if (!mounted) return;
      if (code.isEmpty) {
        qfToast(context, '兑换码获取失败，请稍后重试。');
        return;
      }
      setState(() => _revealedCode = code);
      _maskTimer = Timer(const Duration(seconds: 60), () {
        if (mounted) Navigator.of(context).pop();
      });
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          if (e.code == 'REAUTH_INVALID') _reauthToken = null;
        });
        qfToast(context, qfAccountErrorMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('查看兑换码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_revealedCode == null) ...[
              const Text(
                '查看兑换码需完成双重核验：先验证当前账户密码（或使用通行密钥验证），再输入发送至账号绑定邮箱的一次性验证码。通行密钥仅替代密码验证，邮箱验证码仍须输入。',
              ),
              const SizedBox(height: 12),
              if (_reauthToken == null) ...[
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前账户密码'),
                ),
                const SizedBox(height: 8),
                QfActionButton(
                  label: '使用通行密钥验证',
                  busyLabel: '正在验证通行密钥……',
                  filled: false,
                  showInlineError: false,
                  onAction: _passkeyVerify,
                ),
              ] else
                const Text('已通过通行密钥验证，请继续输入邮箱验证码完成查看。'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '邮箱验证码'),
                    ),
                  ),
                  QfCodeSendButton(
                    onSend: _requestCode,

                    label: '获取验证码',

                    resendLabel: '重新发送',
                  ),
                ],
              ),
            ] else ...[
              const Text('您的兑换码（本窗口将在 60 秒后自动关闭）：'),
              const SizedBox(height: 8),
              SelectableText(
                _revealedCode!,
                style: AppTextStyle.custom(context, size: 16, leading: 21),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_revealedCode != null)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _revealedCode!));
              qfToast(context, '兑换码已复制');
            },
            child: const Text('复制兑换码'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (_revealedCode == null)
          QfActionButton(
            label: '验证并查看',
            busyLabel: '正在验证……',
            showInlineError: false,
            onFailure: (failure) {
              if (mounted) qfToast(context, failure.message);
            },
            onAction: _reveal,
          ),
      ],
    );
  }
}
