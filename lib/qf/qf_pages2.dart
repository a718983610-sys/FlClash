import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_pages.dart';
import 'qf_providers.dart';
import 'qf_session.dart';
import 'qf_update.dart';
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
        qfToast(context, '当前已经是最新版本');
      case QfUpdateDecision.minor:
        final accepted = await showDialog<bool>(
          context: context,
          builder: (_) => QfMinorUpdateDialog(result: check),
        );
        if (accepted == true && context.mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
              content: QfUpdateDownloadPanel(result: check),
            ),
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

class QfSecurityPage extends StatefulWidget {
  final QfSessionController session;

  const QfSecurityPage({super.key, required this.session});

  @override
  State<QfSecurityPage> createState() => _QfSecurityPageState();
}

class _QfSecurityPageState extends State<QfSecurityPage> {
  Map<String, dynamic>? _me;
  List<dynamic> _devices = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await widget.session.authed('GET', '/security/me');
      final devices = await widget.session.securityDevices();
      if (mounted) {
        setState(() {
          _me = me;
          _devices = devices;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('注销账号'),
          content: const Text(
            '提交注销后进入 7 天冷静期，冷静期内登录可撤销注销；'
            '冷静期结束后账号正式注销，积分清零、已兑换未使用的兑换码作废。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认提交注销'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await widget.session.authed(
        'POST',
        '/security/delete-account',
        body: {'confirm': true},
      );
      if (mounted) qfToast(context, '注销申请已经提交，进入 7 天冷静期');
      await widget.session.refreshPoints();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
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
                Text(
                  '登录设备',
                  style: AppTextStyle.headline.of(context),
                ),
                for (final raw in _devices)
                  if (raw is Map)
                    ListTile(
                      title: Text(
                        '${raw['name'] ?? '未知设备'}'
                        '${raw['isCurrent'] == true ? '（本机）' : ''}',
                      ),
                      subtitle: Text(
                        '${raw['region'] ?? ''} · 最近活跃 '
                        '${DateTime.fromMillisecondsSinceEpoch(((raw['lastActiveAt'] as num? ?? 0) * 1000).toInt())}',
                      ),
                      trailing: raw['isCurrent'] == true
                          ? null
                          : TextButton(
                              onPressed: () => _logoutDevice(raw),
                              child: const Text('下线'),
                            ),
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
  bool _byCode = false;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
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
      await widget.session.authed(
        'POST',
        '/security/password/change',
        body: {
          if (_byCode) 'emailCode': _code.text else 'currentPassword': _current.text,
          'newPassword': _password.text,
        },
      );
      if (mounted) {
        Navigator.of(context).pop(true);
        qfToast(context, '密码已经修改');
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
      title: const Text('修改密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('当前密码')),
                ButtonSegment(value: true, label: Text('邮箱验证码')),
              ],
              selected: {_byCode},
              onSelectionChanged: (value) {
                setState(() => _byCode = value.first);
              },
            ),
            const SizedBox(height: 12),
            if (_byCode)
              QfField(
                controller: _code,
                label: '邮箱验证码',
                keyboardType: TextInputType.number,
                suffix: TextButton(
                  onPressed: () async {
                    try {
                      await widget.session.authed(
                        'POST',
                        '/security/password/code',
                        body: {},
                      );
                      if (mounted) qfToast(context, '验证码已经发到您的邮箱了');
                    } on QfApiException catch (e) {
                      if (mounted) qfToast(context, e.message);
                    }
                  },
                  child: const Text('发送验证码'),
                ),
              )
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('确认修改'),
        ),
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

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) qfToast(context, '验证码发送成功，请查收邮箱');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
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
      if (mounted) qfToast(context, e.message);
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
              suffix: TextButton(
                onPressed: () => _run(
                  () => widget.session.authed(
                    'POST',
                    '/security/email/request-old-code',
                    body: {},
                  ),
                ),
                child: const Text('发送验证码'),
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
              suffix: TextButton(
                onPressed: () => _run(
                  () => widget.session.authed(
                    'POST',
                    '/security/email/request-new-code',
                    body: {'newEmail': _newEmail.text},
                  ),
                ),
                child: const Text('发送验证码'),
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
  bool _busy = false;

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
    setState(() => _busy = true);
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
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
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
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('提交反馈'),
          ),
        ],
      ),
    );
  }
}

class QfBlockingPage extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
                    title,
                    textAlign: TextAlign.center,
                    style: AppTextStyle.pageTitle.of(context),
                  ),
                  const SizedBox(height: 16),
                  Text(body, textAlign: TextAlign.center),
                  if (update != null &&
                      update!.decision != QfUpdateDecision.none) ...[
                    const SizedBox(height: 24),
                    QfUpdateDownloadPanel(result: update!),
                  ],
                  if (onSwitchAccount != null) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: onSwitchAccount,
                      child: const Text('登录账号'),
                    ),
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
      );
      if (mounted) setState(() => _status = '下载完成，正在打开安装');
      await QfUpdateService.install(file);
      if (mounted) setState(() => _status = '已打开安装程序，请按提示完成安装');
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '下载失败，请检查网络后重试';
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
          Align(
            alignment: Alignment.centerLeft,
            child: Text(notes),
          ),
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
  bool _checking = false;
  bool _busy = false;

  bool get _exhausted => _remaining != null && _remaining! <= 0;

  @override
  void initState() {
    super.initState();
    _account.text = widget.initialAccount;
    if (_account.text.isNotEmpty) {
      _checkQuota();
    }
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _checkQuota() async {
    final account = _account.text.trim();
    if (account.isEmpty) return;
    setState(() => _checking = true);
    try {
      final data = await QfHttp.send(
        'GET',
        '${widget.serverBaseUrl}/appeals/quota'
            '?account=${Uri.encodeQueryComponent(account)}',
      );
      if (mounted) {
        setState(() {
          final remaining = data['remaining'];
          _remaining = remaining is num ? remaining.toInt() : null;
          _checking = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _submit() async {
    if (_account.text.trim().isEmpty ||
        _password.text.isEmpty ||
        _content.text.trim().isEmpty) {
      qfToast(context, '请完整填写账户、密码与申诉说明');
      return;
    }
    await _checkQuota();
    if (_exhausted) return;
    setState(() => _busy = true);
    try {
      final result = await QfHttp.send(
        'POST',
        '${widget.serverBaseUrl}/appeals',
        body: {
          'account': _account.text.trim(),
          'password': _password.text,
          'content': _content.text.trim(),
        },
      );
      if (mounted) {
        Navigator.of(context).pop();
        qfToast(context, (result['message'] ?? '申诉已经提交').toString());
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
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
            onSubmitted: (_) => _checkQuota(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '登录密码'),
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
          else if (_remaining != null)
            Text(
              '剩余申诉次数：$_remaining（${widget.permanent ? '永久封禁共 2 次' : '共 3 次'}）',
            )
          else
            const Text('填写账户后将自动查询剩余申诉次数'),
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
              FilledButton(
                onPressed: onLogin,
                child: const Text('登录账号'),
              ),
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
              FilledButton(
                onPressed: onLogin,
                child: const Text('登录账号'),
              ),
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
