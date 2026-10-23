import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import 'qf_api.dart';
import 'qf_passkey.dart';
import 'qf_recovery.dart';
import 'qf_privacy.dart';
import 'qf_config.dart';
import 'qf_pages.dart';
import 'qf_providers.dart';
import 'qf_session.dart';
import 'qf_signal.dart';
import 'qf_update.dart';
import 'qf_vault.dart';
import 'qf_version.dart';

List<String> qfUpdateBlockText(QfUpdateDecision decision) {
  return switch (decision) {
    QfUpdateDecision.maintenance => [
      QfCopy.maintenanceTitle,
      QfCopy.maintenanceBody,
    ],
    QfUpdateDecision.retired => [QfCopy.retiredTitle, QfCopy.retiredBody],
    QfUpdateDecision.force => [QfCopy.forceUpdateTitle, QfCopy.forceUpdateBody],
    _ => ['', ''],
  };
}

class QfUpdateFlow {
  static Future<void> runManualCheck(BuildContext context) async {
    final check = await QfUpdateService.check(QfRuntime.appVersion);
    if (!context.mounted) return;
    switch (check.decision) {
      case QfUpdateDecision.none:
        qfToast(
          context,
          check.manifestFresh ? '当前已经是最新版本' : QfCopy.networkAccountUnreachable,
        );
      case QfUpdateDecision.minor:
        final accepted = await showDialog<bool>(
          context: context,
          builder: (_) => QfMinorUpdateDialog(result: check),
        );
        if (accepted == true && context.mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) =>
                AlertDialog(content: QfUpdateDownloadPanel(result: check)),
          );
        }
      case QfUpdateDecision.force:
      case QfUpdateDecision.retired:
      case QfUpdateDecision.maintenance:
        final text = qfUpdateBlockText(check.decision);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => QfBlockingPage(
              title: text[0],
              body: text[1],
              update: check.decision == QfUpdateDecision.maintenance
                  ? null
                  : check,
            ),
          ),
        );
    }
  }
}

String qfDeviceTrustText(Map<dynamic, dynamic> device) {
  if (device['trusted'] != true) return QfCopy.deviceUntrusted;
  final verifiedAt = qfFormatEpochSeconds(device['verifiedAt']);
  return verifiedAt.isEmpty
      ? QfCopy.deviceTrusted
      : '${QfCopy.deviceTrusted} · 最近验证 $verifiedAt';
}

class QfSecurityPage extends StatefulWidget {
  final QfSessionController session;

  const QfSecurityPage({super.key, required this.session});

  @override
  State<QfSecurityPage> createState() => _QfSecurityPageState();
}

class _QfSecurityPageState extends State<QfSecurityPage> {
  Map<String, dynamic>? _me;
  List<dynamic> _devices = const [];
  List<dynamic> _passkeys = const [];
  bool _loading = true;
  bool? _loginProtection;
  bool _settingsBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await widget.session.authed('GET', '/security/me');
      final devices = await widget.session.securityDevices();
      var passkeys = _passkeys;
      try {
        passkeys = await widget.session.passkeyList();
      } catch (_) {}
      var loginProtection = me['loginProtection'] == true;
      try {
        final settings = await widget.session.authed(
          'GET',
          '/security/settings',
        );
        if (settings['loginProtection'] is bool) {
          loginProtection = settings['loginProtection'] == true;
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _me = me;
          _devices = devices;
          _passkeys = passkeys;
          _loginProtection = loginProtection;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleLoginProtection(bool value) async {
    final previous = _loginProtection;
    setState(() {
      _loginProtection = value;
      _settingsBusy = true;
    });
    try {
      await widget.session.authed(
        'PUT',
        '/security/settings',
        body: {'loginProtection': value},
      );
      if (mounted) qfToast(context, '设置已保存');
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _loginProtection = previous);
        qfToast(context, qfAccountErrorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _changePassword() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QfChangePasswordDialog(session: widget.session),
    );
  }

  Future<void> _changeEmail() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QfChangeEmailDialog(session: widget.session),
    );
    await _load();
  }

  Future<void> _untrustDevice(Map<dynamic, dynamic> device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(QfCopy.deviceUntrust),
          content: const Text(QfCopy.deviceUntrustConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(QfCopy.deviceUntrust),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await widget.session.securityUntrustDevice((device['id'] as num).toInt());
      if (mounted) qfToast(context, QfCopy.deviceUntrustedDone);
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    }
  }

  Future<void> _logoutDevice(Map<dynamic, dynamic> device) async {
    try {
      await widget.session.authed(
        'POST',
        '/security/devices/${(device['id'] as num).toInt()}/logout',
        body: {},
      );
      if (mounted) qfToast(context, '该设备已经退出登录');
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    }
  }

  Future<Map<String, String>?> _verifyIdentity(
    String title,
    String purpose,
  ) async {
    return showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _QfIdentityVerifyDialog(
        session: widget.session,
        title: title,
        purpose: purpose,
      ),
    );
  }

  Future<void> _createPasskey() async {
    final proof = await _verifyIdentity('创建通行密钥', 'passkey_manage');
    if (proof == null || !mounted) return;
    try {
      final Map<String, dynamic> options;
      final reauthToken = proof['reauthToken'];
      if (reauthToken != null) {
        final data = await widget.session.authed(
          'POST',
          '/passkeys/register/options',
          body: {'reauthToken': reauthToken},
        );
        final rawOptions = data['options'];
        options = rawOptions is Map
            ? Map<String, dynamic>.from(rawOptions)
            : Map<String, dynamic>.from(data);
      } else {
        options = await widget.session.passkeyRegisterOptions(
          proof['password']!,
        );
      }
      final response = await QfPasskeyCeremony.register(options);
      if (!mounted) return;
      final nameController = TextEditingController(text: '通行密钥');
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('通行密钥名称'),
            content: TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            actions: [
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(nameController.text),
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
      nameController.dispose();
      await widget.session.passkeyRegisterVerify(
        response,
        name: (name == null || name.trim().isEmpty) ? null : name.trim(),
      );
      if (mounted) qfToast(context, '通行密钥已创建');
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    } catch (e) {
      if (mounted) qfToast(context, qfPasskeyFailureText(e));
    }
  }

  Future<void> _deletePasskey(Map<dynamic, dynamic> item) async {
    final proof = await _verifyIdentity('删除通行密钥', 'passkey_manage');
    if (proof == null || !mounted) return;
    try {
      final id = (item['id'] as num).toInt();
      final reauthToken = proof['reauthToken'];
      if (reauthToken != null) {
        await widget.session.authed(
          'DELETE',
          '/passkeys/$id',
          body: {'reauthToken': reauthToken},
        );
      } else {
        await widget.session.passkeyDelete(id, proof['password']!);
      }
      if (mounted) qfToast(context, '通行密钥已删除');
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    }
  }

  String _platformLabel(dynamic value) {
    final platform = (value ?? '').toString();
    if (platform.isEmpty) return '';
    final label = switch (platform) {
      'android' => 'Android',
      'windows' => 'Windows',
      'website' => '网页',
      _ => platform,
    };
    return '$label · ';
  }

  String _passkeyCreatedLabel(dynamic value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (value * 1000).toInt(),
      ).toString();
    }
    return value?.toString() ?? '';
  }

  Future<void> _deleteAccount() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _QfDeleteAccountDialog(session: widget.session),
    );
    if (done != true || !mounted) return;
    widget.session.accountDeleting = true;
    try {
      final me = await widget.session.authed('GET', '/security/me');
      widget.session.accountDeleting = me['status'] == 'deleting';
      widget.session.deletionEffectiveAt = (me['deletionEffectiveAt'] as num?)
          ?.toInt();
    } catch (_) {}
    await widget.session.refreshPoints();
    if (mounted) {
      qfToast(context, '注销申请已经提交，进入 7 天冷静期');
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('安全中心')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  title: const Text('当前账号'),
                  subtitle: Text(_me?['email']?.toString() ?? ''),
                ),
                if (_loginProtection != null)
                  SwitchListTile(
                    title: const Text('环境异常双重验证'),
                    subtitle: const Text(
                      '开启后，在新设备登录或登录国家与以往明显不同时，除密码外还需输入发送至绑定邮箱的验证码；'
                      '已验证通过的设备不会被反复拦截。关闭后，如系统检测到异常登录，仍可能要求完成强制复核。',
                    ),
                    value: _loginProtection!,
                    onChanged: _settingsBusy ? null : _toggleLoginProtection,
                  ),
                ListTile(
                  leading: const GlyphIcon(AppGlyphs.lock),
                  title: const Text('修改密码'),
                  onTap: _changePassword,
                ),
                ListTile(
                  leading: const GlyphIcon(AppGlyphs.send),
                  title: const Text('换绑邮箱'),
                  onTap: _changeEmail,
                ),
                const Divider(),
                Text('登录设备', style: AppTextStyle.headline.of(context)),
                for (final raw in _devices)
                  if (raw is Map)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          title: Text(
                            '${raw['name'] ?? '未知设备'}'
                            '${raw['isCurrent'] == true ? '（本机）' : ''}',
                          ),
                          subtitle: Text(
                            '${_platformLabel(raw['platform'])}'
                            '${raw['region'] ?? ''} · 最近活跃 '
                            '${DateTime.fromMillisecondsSinceEpoch(((raw['lastActiveAt'] as num? ?? 0) * 1000).toInt())}'
                            '\n${qfDeviceTrustText(raw)}',
                          ),
                        ),
                        if (raw['isCurrent'] != true || raw['trusted'] == true)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Wrap(
                              children: [
                                if (raw['isCurrent'] != true)
                                  TextButton(
                                    onPressed: () => _logoutDevice(raw),
                                    child: const Text('下线'),
                                  ),
                                if (raw['trusted'] == true)
                                  TextButton(
                                    onPressed: () => _untrustDevice(raw),
                                    child: const Text(QfCopy.deviceUntrust),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                const Divider(),
                Text('通行密钥', style: AppTextStyle.headline.of(context)),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('通行密钥可通过系统生物识别或设备 PIN 快速登录。'),
                ),
                for (final raw in _passkeys)
                  if (raw is Map)
                    ListTile(
                      leading: const GlyphIcon(AppGlyphs.verified),
                      title: Text((raw['name'] ?? '通行密钥').toString()),
                      subtitle: Text(
                        '创建时间：${_passkeyCreatedLabel(raw['createdAt'])}',
                      ),
                      trailing: TextButton(
                        onPressed: () => _deletePasskey(raw),
                        child: const Text('删除'),
                      ),
                    ),
                ListTile(
                  leading: const GlyphIcon(AppGlyphs.add),
                  title: const Text('创建通行密钥'),
                  onTap: _createPasskey,
                ),
                const Divider(),
                ListTile(
                  leading: const GlyphIcon(AppGlyphs.delete),
                  title: const Text(
                    '注销账号',
                    style: TextStyle(color: Colors.red),
                  ),
                  subtitle: const Text('提交后进入 7 天冷静期，期间可撤销'),
                  onTap: _deleteAccount,
                ),
              ],
            ),
    );
  }
}

class _QfIdentityVerifyDialog extends StatefulWidget {
  final QfSessionController session;
  final String title;
  final String purpose;

  const _QfIdentityVerifyDialog({
    required this.session,
    required this.title,
    required this.purpose,
  });

  @override
  State<_QfIdentityVerifyDialog> createState() =>
      _QfIdentityVerifyDialogState();
}

class _QfIdentityVerifyDialogState extends State<_QfIdentityVerifyDialog> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _usePasskey() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await qfPasskeyReauthToken(widget.session, widget.purpose);
      if (mounted) Navigator.of(context).pop({'reauthToken': token});
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.code == 'PASSKEY_NOT_ENROLLED'
              ? '您尚未创建通行密钥，请使用账户密码验证。'
              : qfAccountErrorMessage(e);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = qfPasskeyFailureText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('请先完成身份验证：输入当前密码，或使用通行密钥验证。'),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(labelText: '当前账户密码', errorText: _error),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _usePasskey,
            child: const Text('使用通行密钥验证'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  if (_password.text.isEmpty) {
                    setState(() => _error = '请输入当前账户密码');
                    return;
                  }
                  Navigator.of(context).pop({'password': _password.text});
                },
          child: const Text('确认'),
        ),
      ],
    );
  }
}

class _QfDeleteAccountDialog extends StatefulWidget {
  final QfSessionController session;

  const _QfDeleteAccountDialog({required this.session});

  @override
  State<_QfDeleteAccountDialog> createState() => _QfDeleteAccountDialogState();
}

class _QfDeleteAccountDialogState extends State<_QfDeleteAccountDialog> {
  final _password = TextEditingController();
  String? _reauthToken;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _usePasskey() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await qfPasskeyReauthToken(
        widget.session,
        'delete_account',
      );
      if (mounted) {
        setState(() {
          _reauthToken = token;
          _busy = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.code == 'PASSKEY_NOT_ENROLLED'
              ? '您尚未创建通行密钥，请使用账户密码验证。'
              : qfAccountErrorMessage(e);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = qfPasskeyFailureText(e);
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_reauthToken == null && _password.text.isEmpty) {
      setState(() => _error = '请先完成身份复核：输入账户密码，或使用通行密钥验证。');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.session.authed(
        'POST',
        '/security/delete-account',
        body: {
          'confirm': true,
          if (_reauthToken != null)
            'reauthToken': _reauthToken
          else
            'password': _password.text,
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          if (e.code == 'REAUTH_INVALID') _reauthToken = null;
          _error = qfAccountErrorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('注销账号'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '提交注销后进入 7 天冷静期，冷静期内登录可撤销注销；'
              '冷静期结束后账号正式注销，积分清零、已兑换未使用的兑换码作废。',
            ),
            const SizedBox(height: 12),
            const Text('冷静期结束并完成数据清除后，本账号绑定的邮箱可用于重新注册；账户ID将被保留，不再释放。'),
            const SizedBox(height: 12),
            const Text('提交前请完成身份复核：输入账户密码，或使用通行密钥验证。'),
            const SizedBox(height: 12),
            if (_reauthToken == null) ...[
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '当前账户密码',
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _usePasskey,
                child: const Text('使用通行密钥验证'),
              ),
            ] else ...[
              const Text('已通过通行密钥验证。'),
              if (_error != null) ...[const SizedBox(height: 8), Text(_error!)],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('确认提交注销'),
        ),
      ],
    );
  }
}

class _QfChangePasswordDialog extends StatefulWidget {
  final QfSessionController session;

  const _QfChangePasswordDialog({required this.session});

  @override
  State<_QfChangePasswordDialog> createState() =>
      _QfChangePasswordDialogState();
}

class _QfChangePasswordDialogState extends State<_QfChangePasswordDialog> {
  final _current = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _confirmError;
  String? _reauthToken;
  int _method = 0;
  bool _busy = false;
  bool _vaultFailed = false;

  @override
  void dispose() {
    _current.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _usePasskey() async {
    setState(() => _busy = true);
    try {
      final token = await qfPasskeyReauthToken(
        widget.session,
        'change_password',
      );
      if (mounted) {
        setState(() {
          _reauthToken = token;
          _busy = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(
          context,
          e.code == 'PASSKEY_NOT_ENROLLED'
              ? '您尚未创建通行密钥，请改用当前密码或邮箱验证码验证'
              : e.message,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        qfToast(context, qfPasskeyFailureText(e));
      }
    }
  }

  Future<void> _submit() async {
    setState(() {
      _confirmError = _password.text != _confirm.text
          ? QfCopy.passwordMismatch
          : null;
    });
    if (_confirmError != null) return;
    if (_method == 1 && _reauthToken == null) {
      qfToast(context, '请先使用通行密钥完成验证');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.session.authed(
        'POST',
        '/security/password/change',
        body: {
          if (_method == 2)
            'emailCode': _code.text
          else if (_method == 1)
            'reauthToken': _reauthToken
          else
            'currentPassword': _current.text,
          'newPassword': _password.text,
        },
      );
      if (!mounted) return;
      if (_method == 0) {
        var rewrapped = false;
        try {
          final vaultOk = await QfVaultService.rewrapAll(
            session: widget.session,
            oldPassword: _current.text,
            newPassword: _password.text,
          );
          final historyOk = await QfChatHistoryVault.rewrapHistoryKey(
            session: widget.session,
            oldPassword: _current.text,
            newPassword: _password.text,
          );
          final keyBackupOk = await QfSignalManager.rewrapKeyBackup(
            session: widget.session,
            oldPassword: _current.text,
            newPassword: _password.text,
          );
          rewrapped = vaultOk && historyOk && keyBackupOk;
        } catch (_) {
          rewrapped = false;
        }
        if (!rewrapped) {
          setState(() {
            _busy = false;
            _vaultFailed = true;
          });
          return;
        }
      }
      Navigator.of(context).pop(true);
      qfToast(context, '密码已经修改');
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          if (e.code == 'REAUTH_INVALID') _reauthToken = null;
        });
        qfToast(context, qfAccountErrorMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('当前密码')),
                ButtonSegment(value: 1, label: Text('通行密钥')),
                ButtonSegment(value: 2, label: Text('邮箱验证码')),
              ],
              selected: {_method},
              onSelectionChanged: (value) {
                setState(() => _method = value.first);
              },
            ),
            const SizedBox(height: 12),
            if (_method != 0)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '通过此方式改密后，云端保险库（订阅备份、聊天记录、聊天密钥备份）无法自动迁移，请改用当前密码验证，或改密后重新备份。',
                ),
              ),
            if (_method == 2)
              QfField(
                controller: _code,
                label: '邮箱验证码',
                keyboardType: TextInputType.number,
                suffix: QfCodeSendButton(
                  onSend: () async {
                    await widget.session.authed(
                      'POST',
                      '/security/password/code',
                      body: {},
                    );
                    if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
                    return null;
                  },
                ),
              )
            else if (_method == 1)
              if (_reauthToken == null)
                OutlinedButton(
                  onPressed: _busy ? null : _usePasskey,
                  child: const Text('使用通行密钥验证'),
                )
              else
                const Text('已通过通行密钥验证。')
            else
              QfField(controller: _current, label: '当前密码', obscure: true),
            const SizedBox(height: 12),
            QfField(controller: _password, label: '新密码', obscure: true),
            const SizedBox(height: 12),
            QfField(
              controller: _confirm,
              label: '确认新密码',
              obscure: true,
              error: _confirmError,
            ),
            if (_vaultFailed) ...[
              const SizedBox(height: 12),
              const Text(
                '密码已修改，但云端保险库未能同步迁移（可能包括聊天密钥备份），请重新备份订阅、聊天记录与聊天密钥。',
                style: TextStyle(color: Colors.red),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_vaultFailed)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('我知道了'),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('确认修改'),
          ),
        ],
      ],
    );
  }
}

class _QfChangeEmailDialog extends StatefulWidget {
  final QfSessionController session;

  const _QfChangeEmailDialog({required this.session});

  @override
  State<_QfChangeEmailDialog> createState() => _QfChangeEmailDialogState();
}

class _QfChangeEmailDialogState extends State<_QfChangeEmailDialog> {
  final _newEmail = TextEditingController();
  final _oldCode = TextEditingController();
  final _newCode = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _newEmail.dispose();
    _oldCode.dispose();
    _newCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.session.authed(
        'POST',
        '/security/email/confirm',
        body: {
          'newEmail': _newEmail.text,
          'oldCode': _oldCode.text,
          'newCode': _newCode.text,
        },
      );
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, '邮箱已经换绑，请使用新邮箱登录');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('换绑邮箱'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('原邮箱与新邮箱都需要通过验证码确认后才会完成换绑。'),
            const SizedBox(height: 12),
            QfField(
              controller: _oldCode,
              label: '原邮箱验证码',
              keyboardType: TextInputType.number,
              suffix: QfCodeSendButton(
                onSend: () async {
                  await widget.session.authed(
                    'POST',
                    '/security/email/request-old-code',
                    body: {},
                  );
                  if (mounted) qfToast(context, '验证码发送成功，请查收邮箱');
                  return null;
                },
              ),
            ),
            const SizedBox(height: 12),
            QfField(
              controller: _newEmail,
              label: '新邮箱',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            QfField(
              controller: _newCode,
              label: '新邮箱验证码',
              keyboardType: TextInputType.number,
              suffix: QfCodeSendButton(
                onSend: () async {
                  await widget.session.authed(
                    'POST',
                    '/security/email/request-new-code',
                    body: {'newEmail': _newEmail.text},
                  );
                  if (mounted) qfToast(context, '验证码发送成功，请查收邮箱');
                  return null;
                },
              ),
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
          child: const Text('确认换绑'),
        ),
      ],
    );
  }
}

class QfFeedbackPage extends StatefulWidget {
  final QfSessionController session;

  const QfFeedbackPage({super.key, required this.session});

  @override
  State<QfFeedbackPage> createState() => _QfFeedbackPageState();
}

class _QfFeedbackPageState extends State<QfFeedbackPage> {
  final _content = TextEditingController();
  final _contact = TextEditingController();

  @override
  void dispose() {
    _content.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_content.text.trim().isEmpty) {
      qfToast(context, '反馈内容不能为空');
      return;
    }
    try {
      await widget.session.submitFeedback(
        content: _content.text,
        contact: _contact.text,
        appVersion: QfRuntime.appVersion,
      );
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, QfCopy.feedbackSuccess);
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('意见反馈')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(QfCopy.feedbackHint),
          const SizedBox(height: 16),
          TextField(
            controller: _content,
            maxLines: 8,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '反馈内容',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contact,
            decoration: const InputDecoration(labelText: '联系方式（选填）'),
          ),
          const SizedBox(height: 16),
          QfActionButton(label: '提交反馈', busyLabel: '正在提交……', onAction: _submit),
        ],
      ),
    );
  }
}

class QfBlockingPage extends StatefulWidget {
  final String title;
  final String body;
  final QfUpdateCheck? update;
  final VoidCallback? onSwitchAccount;

  const QfBlockingPage({
    super.key,
    required this.title,
    required this.body,
    this.update,
    this.onSwitchAccount,
  });

  @override
  State<QfBlockingPage> createState() => _QfBlockingPageState();
}

class _QfBlockingPageState extends State<QfBlockingPage> {
  bool _later = false;

  bool get _isGuestQuota => widget.onSwitchAccount != null;

  @override
  Widget build(BuildContext context) {
    if (_isGuestQuota) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _later
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                widget.title,
                                textAlign: TextAlign.center,
                                style: AppTextStyle.pageTitle.of(context),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                '您已选择暂不登录。今日访客额度恢复或登录后，可继续使用全部功能。',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              FilledButton(
                                onPressed: widget.onSwitchAccount,
                                child: const Text('登录账号'),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: () =>
                                    QfUpdateFlow.runManualCheck(context),
                                child: const Text('检查更新'),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () => setState(() => _later = false),
                                child: const Text('返回登录提示'),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                widget.title,
                                textAlign: TextAlign.center,
                                style: AppTextStyle.pageTitle.of(context),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                '当日免费 2 小时额度已用完，登录畅享不限额，还有积分好礼相送',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              FilledButton(
                                onPressed: widget.onSwitchAccount,
                                child: const Text('登录账号'),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: () => setState(() => _later = true),
                                child: const Text('暂不登录'),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () =>
                                    QfUpdateFlow.runManualCheck(context),
                                child: const Text('检查更新'),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: AppTextStyle.pageTitle.of(context),
                  ),
                  const SizedBox(height: 16),
                  Text(widget.body, textAlign: TextAlign.center),
                  if (widget.update != null &&
                      widget.update!.decision != QfUpdateDecision.none) ...[
                    const SizedBox(height: 24),
                    QfUpdateDownloadPanel(result: widget.update!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class QfUpdateDownloadPanel extends StatefulWidget {
  final QfUpdateCheck result;

  const QfUpdateDownloadPanel({super.key, required this.result});

  @override
  State<QfUpdateDownloadPanel> createState() => _QfUpdateDownloadPanelState();
}

class _QfUpdateDownloadPanelState extends State<QfUpdateDownloadPanel> {
  double? _progress;
  String? _status;
  bool _downloading = false;

  Future<void> _start() async {
    final url = widget.result.downloadUrl;
    if (url.isEmpty) {
      setState(() => _status = '下载地址暂不可用，请稍后再试');
      return;
    }
    setState(() {
      _downloading = true;
      _status = '正在下载';
    });
    try {
      final file = await QfUpdateService.download(
        url,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        expectedSha256: widget.result.sha256,
        expectedSizeBytes: widget.result.sizeBytes,
      );
      if (mounted) setState(() => _status = '下载完成，正在打开安装');
      final launched = await QfUpdateService.install(file);
      if (mounted) {
        setState(() {
          if (launched) {
            _status = '已打开安装程序，请按提示完成安装';
          } else {
            _status = '自动安装未能启动，请前往官网下载最新版安装包。';
            _downloading = false;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = e is QfApiException ? e.message : '下载失败，请检查网络后重试';
          _downloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.result.notes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notes.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '更新内容',
              style: AppTextStyle.body.of(context, emphasized: true),
            ),
          ),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: Text(notes)),
          const SizedBox(height: 16),
        ],
        if (_downloading || _progress != null)
          LinearProgressIndicator(value: _progress),
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _downloading ? null : _start,
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}

class QfMinorUpdateDialog extends StatelessWidget {
  final QfUpdateCheck result;

  const QfMinorUpdateDialog({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final notes = result.notes;
    return AlertDialog(
      title: Text('发现新版本 v${result.latestVersion}'),
      content: SingleChildScrollView(
        child: Text(notes.isNotEmpty ? notes : '新版本已经发布，建议更新后使用。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('暂不更新'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}

Future<void> qfShowBanDialog(
  BuildContext context, {
  required QfSessionController session,
  required Map<String, dynamic> data,
  String account = '',
}) async {
  final reason = (data['reason'] ?? '').toString();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('账户已被封禁'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(QfSessionController.formatBanNotice(data)),
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
                    permanent: data['permanent'] == true,
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
}

class QfPrivacyPage extends StatelessWidget {
  const QfPrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('隐私说明')),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: SelectableText(qfPrivacyText),
      ),
    );
  }
}

String qfAppealStatusLabel(String status) {
  return switch (status) {
    'pending' => QfCopy.appealStatusPending,
    'approved' => QfCopy.appealStatusApproved,
    'rejected' => QfCopy.appealStatusRejected,
    _ => status,
  };
}

class QfAppealStatus {
  final bool hasAppeal;
  final String status;
  final String reviewNote;
  final int? reviewedAt;
  final int? remaining;

  const QfAppealStatus({
    required this.hasAppeal,
    required this.status,
    required this.reviewNote,
    required this.reviewedAt,
    required this.remaining,
  });

  String get label => qfAppealStatusLabel(status);
}

QfAppealStatus qfParseAppealStatus(Map<String, dynamic> data) {
  final appeal = data['appeal'];
  final appealMap = appeal is Map ? appeal : null;
  final status = (data['status'] ?? appealMap?['status'] ?? '').toString();
  return QfAppealStatus(
    hasAppeal: appealMap != null || status.isNotEmpty,
    status: status,
    reviewNote: (data['reviewNote'] ?? appealMap?['reviewNote'] ?? '')
        .toString(),
    reviewedAt:
        (data['reviewedAt'] as num?)?.toInt() ??
        (appealMap?['reviewedAt'] as num?)?.toInt(),
    remaining: (data['remaining'] as num?)?.toInt(),
  );
}

class QfAppealPage extends StatefulWidget {
  final String serverBaseUrl;
  final String initialAccount;
  final bool permanent;

  const QfAppealPage({
    super.key,
    required this.serverBaseUrl,
    this.initialAccount = '',
    this.permanent = false,
  });

  @override
  State<QfAppealPage> createState() => _QfAppealPageState();
}

class _QfAppealPageState extends State<QfAppealPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _content = TextEditingController();
  int? _remaining;
  int? _limit;
  String? _quotaError;
  bool _checking = false;
  bool _busy = false;
  QfAppealStatus? _appealStatus;
  String? _statusError;
  bool _statusBusy = false;
  bool _statusQueried = false;

  bool get _exhausted => _remaining != null && _remaining! <= 0;

  @override
  void initState() {
    super.initState();
    _account.text = widget.initialAccount;
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<bool> _checkQuota() async {
    final identifier = _account.text.trim();
    if (identifier.isEmpty || _password.text.isEmpty) {
      setState(() => _quotaError = '请先填写账户 ID 或邮箱与登录密码，再查询剩余申诉次数');
      return false;
    }
    setState(() {
      _checking = true;
      _quotaError = null;
    });
    try {
      final data = await QfHttp.send(
        'POST',
        '${widget.serverBaseUrl}/appeals/quota',
        body: {'identifier': identifier, 'password': _password.text},
      );
      if (mounted) {
        setState(() {
          final remaining = data['remaining'];
          final limit = data['limit'];
          _remaining = remaining is num ? remaining.toInt() : null;
          _limit = limit is num ? limit.toInt() : null;
          _checking = false;
        });
      }
      return true;
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _remaining = null;
          _quotaError = qfAccountErrorMessage(e);
        });
      }
      return false;
    }
  }

  Future<void> _queryStatus({bool byPasskey = false}) async {
    final identifier = _account.text.trim();
    if (identifier.isEmpty || (!byPasskey && _password.text.isEmpty)) {
      setState(
        () => _statusError = '请先填写账户 ID 或邮箱${byPasskey ? '' : '与登录密码'}，再查询申诉结果',
      );
      return;
    }
    setState(() {
      _statusBusy = true;
      _statusError = null;
    });
    try {
      Map<String, dynamic> body;
      if (byPasskey) {
        final optionsData = await QfHttp.send(
          'POST',
          '${widget.serverBaseUrl}/appeals/passkey/options',
          body: {'identifier': identifier},
        );
        final rawOptions = optionsData['options'];
        final options = rawOptions is Map
            ? Map<String, dynamic>.from(rawOptions)
            : optionsData;
        final assertion = await QfPasskeyCeremony.authenticate(options);
        body = {'identifier': identifier, 'passkeyAssertion': assertion};
      } else {
        body = {'identifier': identifier, 'password': _password.text};
      }
      final data = await QfHttp.send(
        'POST',
        '${widget.serverBaseUrl}/appeals/status',
        body: body,
      );
      if (mounted) {
        setState(() {
          _appealStatus = qfParseAppealStatus(data);
          _statusQueried = true;
          _statusBusy = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _statusBusy = false;
          _statusError = qfAccountErrorMessage(e);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusBusy = false;
          _statusError = qfPasskeyFailureText(e);
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_account.text.trim().isEmpty ||
        _password.text.isEmpty ||
        _content.text.trim().isEmpty) {
      qfToast(context, '请完整填写账户、密码与申诉说明');
      return;
    }
    final quotaOk = await _checkQuota();
    if (!quotaOk || _exhausted) return;
    setState(() => _busy = true);
    try {
      final result = await QfHttp.send(
        'POST',
        '${widget.serverBaseUrl}/appeals',
        body: {
          'identifier': _account.text.trim(),
          'password': _password.text,
          'content': _content.text.trim(),
        },
      );
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, (result['message'] ?? '申诉已经提交').toString());
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAccountErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('封禁申诉')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('请填写被封禁的账户与登录密码进行身份核验，并说明申诉理由。密码仅用于核验，不会被保存。'),
          const SizedBox(height: 16),
          TextField(
            controller: _account,
            decoration: const InputDecoration(labelText: '账户 ID 或邮箱'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '登录密码'),
            onSubmitted: (_) => _checkQuota(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _checking ? null : _checkQuota,
              child: const Text('查询剩余申诉次数'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            maxLines: 6,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: '申诉说明',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          if (_checking)
            const Text('正在查询剩余申诉次数……')
          else if (_quotaError != null)
            Text(_quotaError!, style: const TextStyle(color: Colors.red))
          else if (_remaining != null)
            Text(
              '剩余申诉次数：$_remaining（共 ${_limit ?? (widget.permanent ? 2 : 3)} 次）',
            )
          else
            const Text('填写账户与密码后，可查询剩余申诉次数'),
          if (_exhausted)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '申诉次数已用完，无法再次申诉。',
                style: TextStyle(color: Colors.red),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _exhausted ? null : _submit,
            child: const Text('提交申诉'),
          ),
          const SizedBox(height: 12),
          const Text('也可通过邮箱 a718983610@gmail.com 进行申诉。'),
          const Divider(height: 32),
          Text(
            QfCopy.appealStatusTitle,
            style: AppTextStyle.headline.of(context),
          ),
          const SizedBox(height: 8),
          const Text('使用被封禁账户的账户 ID 或邮箱，配合登录密码或通行密钥核验后，即可查看最近一次申诉的审核结果。'),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: _statusBusy ? null : () => _queryStatus(),
                child: const Text(QfCopy.appealStatusTitle),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _statusBusy
                    ? null
                    : () => _queryStatus(byPasskey: true),
                child: const Text(QfCopy.appealPasskeyVerify),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_statusBusy)
            const Text('正在查询申诉结果……')
          else if (_statusError != null)
            Text(_statusError!, style: const TextStyle(color: Colors.red))
          else if (_statusQueried && _appealStatus != null)
            if (!_appealStatus!.hasAppeal)
              const Text(QfCopy.appealStatusEmpty)
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('申诉状态：${_appealStatus!.label}'),
                  if (_appealStatus!.reviewNote.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('审核说明：${_appealStatus!.reviewNote}'),
                    ),
                  if (_appealStatus!.reviewedAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '审核时间：${qfFormatEpochSeconds(_appealStatus!.reviewedAt)}',
                      ),
                    ),
                  if (_appealStatus!.remaining != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('剩余申诉次数：${_appealStatus!.remaining}'),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}

class QfLoginGuidePage extends StatelessWidget {
  final String title;
  final VoidCallback onLogin;

  const QfLoginGuidePage({
    super.key,
    required this.title,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('该功能需要登录后使用。'),
              const SizedBox(height: 8),
              const Text(QfCopy.loginBenefit, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onLogin, child: const Text('登录账号')),
            ],
          ),
        ),
      ),
    );
  }
}

class QfRestrictedPage extends StatelessWidget {
  final VoidCallback onLogin;
  final VoidCallback onAbout;
  final VoidCallback onCheckUpdate;

  const QfRestrictedPage({
    super.key,
    required this.onLogin,
    required this.onAbout,
    required this.onCheckUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(QfCopy.guestRestricted, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(QfCopy.loginBenefit, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onLogin, child: const Text('登录账号')),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(onPressed: onAbout, child: const Text('关于')),
                  TextButton(
                    onPressed: onCheckUpdate,
                    child: const Text('检查更新'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
