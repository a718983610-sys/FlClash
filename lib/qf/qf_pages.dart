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
import 'qf_pages2.dart';
import 'qf_passkey.dart';
import 'qf_providers.dart';
import 'qf_recovery.dart';
import 'qf_session.dart';
import 'qf_social.dart';

void qfToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

class QfEntryPage extends StatefulWidget {
  final QfSessionController session;
  final VoidCallback onAbout;
  final VoidCallback onCheckUpdate;
  final VoidCallback onAgreement;

  const QfEntryPage({
    super.key,
    required this.session,
    required this.onAbout,
    required this.onCheckUpdate,
    required this.onAgreement,
  });

  @override
  State<QfEntryPage> createState() => _QfEntryPageState();
}

class _QfEntryPageState extends State<QfEntryPage> {
  bool _register = false;
  bool _busy = false;

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
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.enterGuest();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                  OutlinedButton(
                    onPressed: _busy ? null : _enterGuest,
                    child: const Text('免登录使用（访客模式）'),
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

class _QfLoginFormState extends State<QfLoginForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _stepUpCode = TextEditingController();
  String? _emailError;
  String? _passwordError;
  String? _codeError;
  String? _stepUpError;
  bool _dual = false;
  bool _busy = false;
  bool _remember = true;

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
    });
    if (_stepUpError != null) return;
    setState(() => _busy = true);
    try {
      await widget.session.verifyStepUp(_stepUpCode.text.trim());
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
        } else {
          qfToast(context, e.message);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resendStepUp() async {
    try {
      await widget.session.resendStepUp();
      if (mounted) qfToast(context, '验证码已经重新发送至您的绑定邮箱');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _sendCode() async {
    try {
      await widget.session.loginRequestCode(_email.text);
      if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _emailError = _email.text.trim().isEmpty ? '请输入邮箱或 ID' : null;
      _passwordError = _password.text.isEmpty ? '请输入密码' : null;
      _codeError = null;
    });
    if (_emailError != null || _passwordError != null) return;
    setState(() => _busy = true);
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
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
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
        } else if (e.code == 'BAD_CREDENTIALS') {
          setState(() => _passwordError = e.message);
        } else {
          qfToast(context, e.message);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _passkeyLogin() async {
    setState(() => _busy = true);
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
          qfToast(context, e.message);
        }
      }
    } catch (_) {
      if (mounted) qfToast(context, '通行密钥验证未完成，请重试或改用密码登录');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _googleLogin() async {
    setState(() => _busy = true);
    try {
      final idToken = await QfGoogleAuth.fetchIdToken();
      await widget.session.googleLogin(idToken, remember: _remember);
      if (!mounted) return;
      if (widget.session.googleCompletionPending) {
        final message = await showDialog<String>(
          context: context,
          builder: (_) => QfGoogleCompletionDialog(session: widget.session),
        );
        if (message != null && message.isNotEmpty && mounted) {
          qfToast(context, message);
        }
      } else if (widget.session.stepUpPending) {
        setState(() {});
      }
    } on QfGoogleAuthException catch (e) {
      if (mounted) qfToast(context, e.message);
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
          qfToast(context, e.message);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final googleReady = QfGoogleAuth.isConfigured;
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
            suffix: TextButton(
              onPressed: _sendCode,
              child: const Text('发送验证码'),
            ),
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
              TextButton(
                onPressed: _busy ? null : _resendStepUp,
                child: const Text('重新发送验证码'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _verifyStepUp,
                child: const Text('验证并登录'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '邮箱无法接收验证码？请发送邮件至 a718983610@gmail.com 申请人工核验，并附上您的账户ID或绑定邮箱。',
          ),
        ],
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
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('登录'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _passkeyLogin,
          child: const Text('使用通行密钥登录'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: googleReady && !_busy ? _googleLogin : null,
          child: const Text('使用谷歌账号登录'),
        ),
        Row(
          children: [
            TextButton(
              onPressed: _openRecoveryAppeal,
              child: const Text('邮箱不可用？提交找回申诉'),
            ),
            const Spacer(),
            TextButton(onPressed: _forgotPassword, child: const Text('忘记密码')),
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
  bool _busy = false;

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
      _confirmError = _password.text != _confirm.text
          ? QfCopy.passwordMismatch
          : null;
    });
    if (_confirmError != null) return;
    setState(() => _busy = true);
    try {
      await widget.session.resetConfirm(
        emailInput: _email.text,
        code: _code.text,
        newPassword: _password.text,
      );
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, '密码已经重置，请使用新密码登录');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
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
              suffix: TextButton(
                onPressed: () async {
                  try {
                    await widget.session.resetRequestCode(_email.text);
                    if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
                  } on QfApiException catch (e) {
                    if (mounted) qfToast(context, e.message);
                  }
                },
                child: const Text('发送验证码'),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('重置密码'),
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
  bool _busy = false;
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

  Future<void> _sendCode() async {
    setState(() {
      _emailError = _email.text.trim().contains('@') ? null : '邮箱格式不正确';
    });
    if (_emailError != null) return;
    try {
      await widget.session.registerRequestCode(_email.text);
      if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
    } on QfApiException catch (e) {
      if (mounted) setState(() => _emailError = e.message);
    }
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
    });
    if (_idError != null ||
        _emailError != null ||
        _codeError != null ||
        _passwordError != null ||
        _confirmError != null) {
      return;
    }
    setState(() => _busy = true);
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
      if (mounted && e.code == 'REGISTRATION_FROZEN') {
        widget.session.captureRegistrationFrozen(e);
        await qfShowRegistrationFrozenDialog(
          context,
          message: e.message,
          data: e.data,
        );
      } else if (mounted) {
        setState(() {
          if (e.code.contains('USERNAME') ||
              e.message.contains('已被注册') ||
              e.message.contains('账户 ID') ||
              e.message.contains('账户ID')) {
            _idError = e.message;
          } else if (e.message.contains('验证码')) {
            _codeError = e.message;
            _ticket = null;
          } else if (e.message.contains('密码')) {
            _passwordError = e.message;
          } else if (e.message.contains('邮箱')) {
            _emailError = e.message;
          } else {
            _codeError = e.message;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
          suffix: TextButton(
            onPressed: _busy ? null : _sendCode,
            child: const Text('发送验证码'),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('注册并登录'),
        ),
      ],
    );
  }
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
  bool _busy = false;

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
      return;
    }
    setState(() => _busy = true);
    final pw = _password.text;
    try {
      await widget.session.completeGoogleSetup(
        username: _id.text.trim(),
        password: pw,
      );
      if (mounted) Navigator.of(context).pop();
    } on QfApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      switch (e.code) {
        case 'USERNAME_TAKEN':
        case 'USERNAME_INVALID':
        case 'USERNAME_IMMUTABLE':
          setState(() => _idError = e.message);
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
        case 'GOOGLE_COMPLETION_INVALID':
        case 'GOOGLE_ALREADY_COMPLETED':
        case 'ACCOUNT_BANNED':
        case 'DEVICE_BANNED':
          Navigator.of(context).pop(e.message);
        case 'BAD_REQUEST':
          if (e.message.contains('密码')) {
            setState(() => _passwordError = e.message);
          } else {
            qfToast(context, e.message);
          }
        default:
          qfToast(context, e.message);
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('完成设置'),
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
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _idError = qfUsernameError(_id.text));
    if (_idError != null) return;
    setState(() => _busy = true);
    try {
      await widget.session.completeUsername(_id.text.trim());
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, '账户ID已设置。');
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _idError = e.message;
        });
      }
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('确认设置'),
        ),
      ],
    );
  }
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
                    subtitle: const Text('冷静期结束前登录即可撤销注销'),
                    trailing: TextButton(
                      onPressed: () async {
                        try {
                          await session.authed(
                            'POST',
                            '/security/delete-account/cancel',
                            body: {},
                          );
                          await session.refreshPoints();
                          if (context.mounted) {
                            qfToast(context, '注销已经撤销，账号恢复正常');
                          }
                        } on QfApiException catch (e) {
                          if (context.mounted) qfToast(context, e.message);
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await widget.session.pointsLedger();
      final rules = await widget.session.pointsRules();
      if (mounted) {
        setState(() {
          _entries = entries;
          _rules = rules;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    await widget.session.refreshPoints();
  }

  String _typeLabel(String type) {
    return switch (type) {
      'earn_settle' => '计时结算',
      'redeem' => '兑换扣分',
      'redeem_freeze' => '兑换冻结',
      'redeem_refund' => '兑换退回',
      'redeem_confiscate' => '审核没收',
      'redeem_confirm' => '审核确认',
      'admin_clear' => '处置清分',
      'admin_adjust' => '手工调整',
      _ => type,
    };
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
                          '当前余额：${points?['balance'] ?? 0} 分',
                          style: AppTextStyle.headline.of(context),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '累计获得 ${points?['totalEarned'] ?? 0} 分 · '
                          '累计消费 ${points?['totalSpent'] ?? 0} 分 · '
                          '今日已获得 ${points?['mintedToday'] ?? 0} 分',
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: points == null
                              ? 0
                              : ((points['pendingMinutes'] as num? ?? 0) /
                                        (points['minutesPerPoint'] as num? ??
                                            180))
                                    .clamp(0, 1)
                                    .toDouble(),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '本轮进度：已累计 ${points?['pendingMinutes'] ?? 0} 分钟，'
                          '距离下 1 分还差 ${points?['minutesToNextPoint'] ?? 0} 分钟',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('积分明细', style: AppTextStyle.headline.of(context)),
                if (_entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无积分记录'),
                  ),
                for (final raw in _entries)
                  if (raw is Map)
                    ListTile(
                      title: Text(_typeLabel((raw['type'] ?? '').toString())),
                      subtitle: Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          ((raw['created_at'] as num? ?? 0) * 1000).toInt(),
                        ).toString(),
                      ),
                      trailing: Text(
                        '${(raw['amount'] as num? ?? 0) > 0 ? '+' : ''}${raw['amount']}',
                      ),
                    ),
                const SizedBox(height: 16),
                Text('积分规则', style: AppTextStyle.headline.of(context)),
                const SizedBox(height: 8),
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

class QfRedeemPage extends StatefulWidget {
  final QfSessionController session;

  const QfRedeemPage({super.key, required this.session});

  @override
  State<QfRedeemPage> createState() => _QfRedeemPageState();
}

class _QfRedeemPageState extends State<QfRedeemPage> {
  List<dynamic> _products = const [];
  List<dynamic> _orders = const [];
  int _balance = 0;
  bool _loading = true;
  bool _regionBlocked = false;
  String _redeemBlockedMessage = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rules = await widget.session.pointsRules();
      final data = await widget.session.redeemProducts();
      final orders = await widget.session.myOrders();
      if (mounted) {
        setState(() {
          final products = data['products'];
          _products = products is List ? products : const [];
          _balance = (data['balance'] as num?)?.toInt() ?? 0;
          _orders = orders;
          _regionBlocked = rules['redeemRegionBlocked'] == true;
          _redeemBlockedMessage = (rules['redeemBlockedMessage'] ?? '')
              .toString();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _stockLabel(Map<dynamic, dynamic> product) {
    final status = (product['stockStatus'] ?? '').toString();
    final stock = (product['stock'] as num?)?.toInt() ?? 0;
    return switch (status) {
      'out_of_stock' => '已售罄',
      'low_stock' => '仅剩 $stock 件',
      _ => '有货',
    };
  }

  Future<void> _redeem(Map<dynamic, dynamic> product) async {
    final outcome = await showDialog<String>(
      context: context,
      builder: (_) => _QfRedeemDialog(
        session: widget.session,
        product: product,
        balance: _balance,
      ),
    );
    if (!mounted) return;
    if (outcome == 'region') {
      qfToast(context, '该功能在您的国家地区不可用');
    } else if (outcome == 'done') {
      qfToast(context, '兑换申请已提交');
      await _load();
      await widget.session.refreshPoints();
    }
  }

  Future<void> _showReveal(Map<dynamic, dynamic> order) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QfRevealCodeDialog(
        session: widget.session,
        orderId: (order['id'] as num).toInt(),
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
                Text('当前积分：$_balance 分'),
                if (_regionBlocked)
                  Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      _redeemBlockedMessage.isNotEmpty
                          ? _redeemBlockedMessage
                          : '该功能在您的国家地区不可用',
                      style: AppTextStyle.body.of(context, emphasized: true),
                    ),
                  ),
                const SizedBox(height: 12),
                for (final raw in _products)
                  if (raw is Map)
                    Card(
                      child: ListTile(
                        title: Text((raw['name'] ?? '').toString()),
                        subtitle: Text(
                          '${raw['description'] ?? ''}\n'
                          '${raw['pricePoints']} 积分 · ${_stockLabel(raw)}'
                          '${raw['requiresReview'] == true ? ' · 需人工审核' : ''}',
                        ),
                        isThreeLine: true,
                        trailing: FilledButton(
                          onPressed:
                              _regionBlocked ||
                                  _stockLabel(raw) == '已售罄' ||
                                  _balance <
                                      ((raw['pricePoints'] as num?)?.toInt() ??
                                          0)
                              ? null
                              : () => _redeem(raw),
                          child: Text(
                            _balance <
                                    ((raw['pricePoints'] as num?)?.toInt() ?? 0)
                                ? '还差 ${((raw['pricePoints'] as num?)?.toInt() ?? 0) - _balance} 分'
                                : '兑换',
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
                Text('我的兑换', style: AppTextStyle.headline.of(context)),
                if (_orders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无兑换记录'),
                  ),
                for (final raw in _orders)
                  if (raw is Map)
                    ListTile(
                      title: Text((raw['productName'] ?? '').toString()),
                      subtitle: Text(
                        '${_orderStatusLabel(raw)}'
                        '${raw['payoutAddress'] != null ? '\n收款地址：${raw['payoutAddress']}' : ''}'
                        '${raw['payoutEmail'] != null ? '\n通知邮箱：${raw['payoutEmail']}' : ''}'
                        '${raw['paidAt'] != null ? '\n打款时间：${DateTime.fromMillisecondsSinceEpoch(((raw['paidAt'] as num) * 1000).toInt())}' : ''}'
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
              ],
            ),
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
  bool _busy = false;

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
    setState(() => _busy = true);
    try {
      await widget.session.redeemCreate(
        (widget.product['id'] as num).toInt(),
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
      if (e.code == 'REGION_UNAVAILABLE') {
        Navigator.of(context).pop('region');
      } else {
        setState(() => _busy = false);
        qfToast(context, e.message);
      }
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: const Text('确认兑换'),
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
  Timer? _cooldownTimer;
  Timer? _maskTimer;
  int _cooldown = 0;
  String? _revealedCode;
  String? _reauthToken;
  bool _busy = false;

  Future<void> _passkeyVerify() async {
    setState(() => _busy = true);
    try {
      final token = await qfPasskeyReauthToken(widget.session, 'reveal_code');
      if (mounted) {
        setState(() {
          _reauthToken = token;
          _busy = false;
        });
        qfToast(context, '通行密钥验证已通过，请继续输入邮箱验证码完成查看');
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(
          context,
          e.code == 'PASSKEY_NOT_ENROLLED' ? '您尚未创建通行密钥，请使用账户密码验证' : e.message,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, '通行密钥验证未完成，请重试或改用账户密码验证');
      }
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _maskTimer?.cancel();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _requestCode() async {
    try {
      await widget.session.redeemCodeRequest(widget.orderId);
      if (!mounted) return;
      qfToast(context, '一次性验证码已发送至账号绑定邮箱，10 分钟内有效');
      setState(() => _cooldown = 60);
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _cooldown -= 1;
          if (_cooldown <= 0) timer.cancel();
        });
      });
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
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
    setState(() => _busy = true);
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
      setState(() {
        _revealedCode = code;
        _busy = false;
      });
      _maskTimer = Timer(const Duration(seconds: 60), () {
        if (mounted) Navigator.of(context).pop();
      });
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          if (e.code == 'REAUTH_INVALID') _reauthToken = null;
        });
        qfToast(context, e.message);
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
                OutlinedButton(
                  onPressed: _busy ? null : _passkeyVerify,
                  child: const Text('使用通行密钥验证'),
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
                  TextButton(
                    onPressed: _cooldown > 0 ? null : _requestCode,
                    child: Text(_cooldown > 0 ? '重新发送（$_cooldown 秒）' : '获取验证码'),
                  ),
                ],
              ),
            ] else ...[
              const Text('您的兑换码（离开本窗口后将重新遮罩）：'),
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
          FilledButton(
            onPressed: _busy ? null : _reveal,
            child: const Text('验证并查看'),
          ),
      ],
    );
  }
}
