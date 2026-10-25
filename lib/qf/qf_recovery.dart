import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import 'qf_api.dart';
import 'qf_pages.dart';
import 'qf_session.dart';
import 'qf_support.dart';

String qfFormatEpochSeconds(dynamic raw) {
  final seconds = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  if (seconds == null || seconds <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

String qfFormatEpochDate(dynamic raw) {
  final seconds = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  if (seconds == null || seconds <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

class QfRecoveryApi {
  static Future<Map<String, dynamic>> submit(
    String baseUrl,
    Map<String, dynamic> body,
  ) {
    return QfHttp.send('POST', '$baseUrl/appeals/recovery', body: body);
  }

  static Future<Map<String, dynamic>> viewDevices(
    String baseUrl, {
    required String account,
    required String email,
  }) {
    return QfHttp.send(
      'POST',
      '$baseUrl/appeals/recovery/devices',
      body: {'account': account, 'email': email},
    );
  }

  // 登出态没有登录凭证可用，走免登录双因子端点，与 viewDevices 同口径。
  static Future<Map<String, dynamic>> viewFriends(
    String baseUrl, {
    required String account,
    required String email,
  }) {
    return QfHttp.send(
      'POST',
      '$baseUrl/appeals/recovery/friends',
      body: {'account': account, 'email': email},
    );
  }

  static Future<Map<String, dynamic>> status(
    String baseUrl, {
    required String appealId,
    required String account,
  }) {
    final query =
        'appealId=${Uri.encodeQueryComponent(appealId)}'
        '&account=${Uri.encodeQueryComponent(account)}';
    return QfHttp.send('GET', '$baseUrl/appeals/recovery/status?$query');
  }

  static Future<Map<String, dynamic>> reset(
    String baseUrl, {
    required int appealId,
    required String resetGrant,
    required String newPassword,
  }) {
    return QfHttp.send(
      'POST',
      '$baseUrl/appeals/recovery/reset',
      body: {
        'appealId': appealId,
        'resetGrant': resetGrant,
        'newPassword': newPassword,
      },
    );
  }
}

enum QfFrozenAction { resetPassword, recoveryAppeal, support, dismissed }

Future<QfFrozenAction> qfShowFrozenDialog(
  BuildContext context, {
  required String message,
  int? frozenAt,
}) async {
  final action = await showDialog<QfFrozenAction>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('账户已被冻结'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (frozenAt != null && frozenAt > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('冻结时间：${qfFormatEpochSeconds(frozenAt)}'),
                ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '如您的绑定邮箱可以正常接收验证码，请通过忘记密码重置密码，'
                  '重置成功后冻结将自动解除；如绑定邮箱已无法使用，'
                  '请提交找回申诉，由人工审核后协助您恢复账户。',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('qf-frozen-support'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(QfFrozenAction.support),
            child: const Text('联系智能客服'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(QfFrozenAction.recoveryAppeal),
            child: const Text('提交找回申诉'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(QfFrozenAction.resetPassword),
            child: const Text('忘记密码重置'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(QfFrozenAction.dismissed),
            child: const Text('我知道了'),
          ),
        ],
      );
    },
  );
  return action ?? QfFrozenAction.dismissed;
}

Future<void> qfHandleFrozenAction(
  BuildContext context, {
  required QfSessionController session,
  required QfFrozenAction action,
  String account = '',
}) async {
  switch (action) {
    case QfFrozenAction.resetPassword:
      await showDialog<void>(
        context: context,
        builder: (_) => QfResetPasswordDialog(
          session: session,
          initialEmail: account.contains('@') ? account : '',
        ),
      );
    case QfFrozenAction.recoveryAppeal:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              QfRecoveryAppealPage(session: session, initialAccount: account),
        ),
      );
    case QfFrozenAction.support:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => QfSupportPage(session: session),
        ),
      );
    case QfFrozenAction.dismissed:
      return;
  }
}

Future<void> qfShowRegistrationFrozenDialog(
  BuildContext context, {
  required String message,
  required Map<String, dynamic> data,
}) async {
  final until = qfFormatEpochDate(data['registrationFrozenUntil']);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('注册功能已暂时冻结'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (until.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('解冻日期：$until'),
                ),
            ],
          ),
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
}

class QfRecoveryAppealPage extends StatefulWidget {
  final QfSessionController session;
  final String initialAccount;

  const QfRecoveryAppealPage({
    super.key,
    required this.session,
    this.initialAccount = '',
  });

  @override
  State<QfRecoveryAppealPage> createState() => _QfRecoveryAppealPageState();
}

class _QfRecoveryAppealPageState extends State<QfRecoveryAppealPage> {
  final _account = TextEditingController();
  final _deviceEmail = TextEditingController();
  final _note = TextEditingController();
  final _friendIdInput = TextEditingController();
  final List<TextEditingController> _oldPasswords = [TextEditingController()];
  final List<TextEditingController> _deviceModels = [TextEditingController()];
  final List<TextEditingController> _locations = [TextEditingController()];
  List<dynamic> _friends = const [];
  bool _friendsLoaded = false;
  List<dynamic> _candidateFriends = const [];
  bool _candidatesLoaded = false;
  bool _candidatesBusy = false;
  int? _selectedFriendId;
  List<dynamic> _devices = const [];
  bool _devicesQueried = false;
  bool _devicesBusy = false;
  bool _busy = false;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _account.text = widget.initialAccount;
    if (widget.session.isLoggedIn) _loadFriends();
  }

  @override
  void dispose() {
    _account.dispose();
    _deviceEmail.dispose();
    _note.dispose();
    _friendIdInput.dispose();
    for (final c in _oldPasswords) {
      c.dispose();
    }
    for (final c in _deviceModels) {
      c.dispose();
    }
    for (final c in _locations) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFriends() async {
    try {
      final data = await widget.session.authed('GET', '/friends');
      final friends = data['friends'];
      if (mounted) {
        setState(() {
          _friends = friends is List ? friends : const [];
          _friendsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _friendsLoaded = true);
    }
  }

  Future<void> _loadCandidateFriends() async {
    if (_account.text.trim().isEmpty || _deviceEmail.text.trim().isEmpty) {
      qfToast(context, '请先填写账户 ID 或邮箱，以及该账户的绑定邮箱。');
      return;
    }
    setState(() => _candidatesBusy = true);
    try {
      final data = await QfRecoveryApi.viewFriends(
        widget.session.serverBaseUrl,
        account: _account.text.trim(),
        email: _deviceEmail.text.trim(),
      );
      final friends = data['friends'];
      if (mounted) {
        setState(() {
          _candidateFriends = friends is List ? friends : const [];
          _candidatesLoaded = true;
          final selected = _selectedFriendId;
          if (selected != null &&
              !_candidateFriends.any(
                (raw) =>
                    raw is Map && (raw['userId'] as num?)?.toInt() == selected,
              )) {
            _selectedFriendId = null;
          }
        });
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _candidatesBusy = false);
    }
  }

  List<String> _collect(List<TextEditingController> controllers) {
    return controllers
        .map((c) => c.text.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }

  Future<void> _queryDevices() async {
    if (_account.text.trim().isEmpty || _deviceEmail.text.trim().isEmpty) {
      qfToast(context, '请先填写账户 ID 或邮箱，以及该账户的绑定邮箱。');
      return;
    }
    setState(() => _devicesBusy = true);
    try {
      final data = await QfRecoveryApi.viewDevices(
        widget.session.serverBaseUrl,
        account: _account.text.trim(),
        email: _deviceEmail.text.trim(),
      );
      final devices = data['devices'];
      if (mounted) {
        setState(() {
          _devices = devices is List ? devices : const [];
          _devicesQueried = true;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _devicesBusy = false);
    }
  }

  int? _resolvedFriendId() {
    final hasRadioList =
        (_friendsLoaded && _friends.isNotEmpty) ||
        (_candidatesLoaded && _candidateFriends.isNotEmpty);
    if (hasRadioList) return _selectedFriendId;
    final parsed = int.tryParse(_friendIdInput.text.trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }

  Future<void> _submit() async {
    if (_account.text.trim().isEmpty) {
      qfToast(context, '请填写账户ID或邮箱。');
      return;
    }
    setState(() => _busy = true);
    try {
      final friendId = _resolvedFriendId();
      final data = await QfRecoveryApi.submit(widget.session.serverBaseUrl, {
        'account': _account.text.trim(),
        'oldPasswords': _collect(_oldPasswords),
        'deviceModels': _collect(_deviceModels),
        'loginLocations': _collect(_locations),
        'selectedFriendUserId': ?friendId,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      });
      if (mounted) setState(() => _result = data);
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openStatus({String appealId = ''}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QfRecoveryStatusPage(
          session: widget.session,
          initialAppealId: appealId,
          initialAccount: _account.text.trim(),
        ),
      ),
    );
  }

  Widget _dynamicRows({
    required String label,
    required List<TextEditingController> controllers,
    required int maxRows,
    bool obscure = false,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < controllers.length; i++) ...[
          Row(
            children: [
              Expanded(
                child: QfField(
                  controller: controllers[i],
                  label: i == 0 ? label : '$label ${i + 1}',
                  obscure: obscure,
                ),
              ),
              if (controllers.length > 1)
                IconButton(
                  tooltip: '删除此行',
                  onPressed: () {
                    setState(() {
                      controllers.removeAt(i).dispose();
                    });
                  },
                  icon: const GlyphIcon(AppGlyphs.remove),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(hint, style: AppTextStyle.caption1.of(context)),
          ),
        if (controllers.length < maxRows)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                setState(() => controllers.add(TextEditingController()));
              },
              child: Text('添加一行（最多 $maxRows 个）'),
            ),
          ),
      ],
    );
  }

  Widget _resultCard(Map<String, dynamic> result) {
    final appealId = '${result['appealId'] ?? ''}';
    final friend = result['friendVerification'];
    final friendMessage = friend is Map
        ? (friend['message'] ?? '').toString()
        : '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('申诉已提交', style: AppTextStyle.headline.of(context)),
            const SizedBox(height: 8),
            Text((result['message'] ?? '').toString()),
            const SizedBox(height: 8),
            Text('申诉编号：$appealId'),
            if (friendMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(friendMessage),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _openStatus(appealId: appealId),
              child: const Text('查询处理状态'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _friendRadioList(List<dynamic> friends) {
    return RadioGroup<int?>(
      groupValue: _selectedFriendId,
      onChanged: (v) => setState(() => _selectedFriendId = v),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const RadioListTile<int?>(value: null, title: Text('不选择好友验证')),
          for (final raw in friends)
            if (raw is Map)
              RadioListTile<int?>(
                value: (raw['userId'] as num?)?.toInt(),
                title: QfBadgedName(
                  name: (raw['nickname'] ?? '').toString(),
                  isOwner: qfUserIsOwner(raw),
                ),
                subtitle: raw['username'] != null
                    ? Text('账户 ID：${raw['username']}')
                    : null,
              ),
        ],
      ),
    );
  }

  Widget _friendSection() {
    if (_friendsLoaded && _friends.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('好友验证（选填）', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          const Text(
            '您可以选定一位好友协助验证身份。选定后，该好友将在其与您的聊天界面内收到验证请求，'
            '并提交验证数字完成验证。不选择好友验证时，本次申诉将直接提交审核。',
          ),
          _friendRadioList(_friends),
        ],
      );
    }
    if (_candidatesLoaded && _candidateFriends.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('好友验证（选填）', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          const Text(
            '已根据您填写的账户与绑定邮箱加载好友名单。您可以选定一位好友协助验证身份。'
            '选定后，该好友将在其与您的聊天界面内收到验证请求，并提交验证数字完成验证。'
            '不选择好友验证时，本次申诉将直接提交审核。',
          ),
          _friendRadioList(_candidateFriends),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('好友验证（选填）', style: AppTextStyle.headline.of(context)),
        const SizedBox(height: 8),
        const Text(
          '如您选定一位好友协助验证身份，可填写该账户的绑定邮箱并加载好友候选，'
          '从名单中选择；如您知晓该好友的用户 ID，也可直接填写。选定后，'
          '该好友将在其与您的聊天界面内收到验证请求，并提交验证数字完成验证。'
          '不选择好友验证时，本次申诉将直接提交审核。',
        ),
        const SizedBox(height: 12),
        // 与下方登录设备查询共用同一绑定邮箱输入，两处双因子核对口径一致。
        QfField(
          controller: _deviceEmail,
          label: '绑定邮箱',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _candidatesBusy ? null : _loadCandidateFriends,
          child: Text(_candidatesBusy ? '正在加载好友候选' : '加载好友候选'),
        ),
        if (_candidatesLoaded) ...[
          const SizedBox(height: 12),
          const Text(
            '未查询到可协助验证的好友。如您知晓好友的用户 ID，可在下方直接填写；'
            '不填写时将跳过好友验证，本次申诉将直接提交审核。',
          ),
        ],
        const SizedBox(height: 12),
        QfField(
          controller: _friendIdInput,
          label: '验证好友的用户 ID（选填）',
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('找回申诉')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '当您的绑定邮箱无法使用、无法通过邮箱验证码重置密码时，可提交找回申诉，'
            '由人工核对您提供的资料后协助恢复账户。请尽量准确填写以下信息。',
          ),
          const SizedBox(height: 16),
          if (result != null) ...[
            _resultCard(result),
            const SizedBox(height: 16),
          ],
          QfField(controller: _account, label: '账户 ID 或邮箱'),
          const SizedBox(height: 16),
          Text('曾设置过的密码', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          _dynamicRows(
            label: '旧密码',
            controllers: _oldPasswords,
            maxRows: 3,
            obscure: true,
            hint: '最多填写 3 个您认为曾经设置过的密码，仅用于核对账户归属。',
          ),
          const SizedBox(height: 8),
          Text('曾用机型', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          _dynamicRows(
            label: '曾用机型',
            controllers: _deviceModels,
            maxRows: 5,
            hint: '填写您曾经登录过该账户的设备机型，可参考下方登录设备记录。',
          ),
          const SizedBox(height: 8),
          Text('常用登录地点', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          _dynamicRows(
            label: '常用登录地点',
            controllers: _locations,
            maxRows: 5,
            hint: '填写您经常登录该账户的国家或地区。',
          ),
          const SizedBox(height: 8),
          _friendSection(),
          const SizedBox(height: 16),
          QfField(controller: _note, label: '补充说明（选填）'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('提交找回申诉'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _openStatus(),
            child: const Text('查询已有申诉状态'),
          ),
          const SizedBox(height: 24),
          Text('登录设备记录（只读参考）', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          const Text('填写账户与绑定邮箱并核对通过后，可查看该账户的登录设备记录，供您对照填写曾用机型与常用登录地点。'),
          const SizedBox(height: 12),
          QfField(
            controller: _deviceEmail,
            label: '绑定邮箱',
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _devicesBusy ? null : _queryDevices,
            child: const Text('查看登录设备'),
          ),
          if (_devicesQueried) ...[
            const SizedBox(height: 12),
            if (_devices.isEmpty)
              const Text('该账户暂无登录设备记录。')
            else
              for (final raw in _devices)
                if (raw is Map)
                  ListTile(
                    title: Text(
                      '${raw['name'] ?? '未知设备'}（${raw['platform'] ?? ''}）',
                    ),
                    subtitle: Text(
                      '地区：${raw['region'] ?? '—'} · '
                      '最近活跃：${qfFormatEpochSeconds(raw['lastActiveAt'])} · '
                      '首次出现：${qfFormatEpochSeconds(raw['firstSeenAt'])}',
                    ),
                  ),
          ],
        ],
      ),
    );
  }
}

class QfRecoveryStatusPage extends StatefulWidget {
  final QfSessionController session;
  final String initialAppealId;
  final String initialAccount;

  const QfRecoveryStatusPage({
    super.key,
    required this.session,
    this.initialAppealId = '',
    this.initialAccount = '',
  });

  @override
  State<QfRecoveryStatusPage> createState() => _QfRecoveryStatusPageState();
}

class _QfRecoveryStatusPageState extends State<QfRecoveryStatusPage> {
  final _appealId = TextEditingController();
  final _account = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  Map<String, dynamic>? _status;
  bool _busy = false;
  bool _resetBusy = false;
  String? _resetDone;

  @override
  void initState() {
    super.initState();
    _appealId.text = widget.initialAppealId;
    _account.text = widget.initialAccount;
    if (_appealId.text.isNotEmpty && _account.text.isNotEmpty) _query();
  }

  @override
  void dispose() {
    _appealId.dispose();
    _account.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  String _statusLabel(String status) {
    return switch (status) {
      'pending' => '审核中',
      'approved' => '已通过',
      'rejected' => '未通过',
      'superseded' => '已被新的申诉替代',
      _ => status,
    };
  }

  Future<void> _query() async {
    if (_appealId.text.trim().isEmpty || _account.text.trim().isEmpty) {
      qfToast(context, '请填写申诉编号与账户ID或邮箱。');
      return;
    }
    setState(() => _busy = true);
    try {
      final data = await QfRecoveryApi.status(
        widget.session.serverBaseUrl,
        appealId: _appealId.text.trim(),
        account: _account.text.trim(),
      );
      if (mounted) {
        setState(() {
          _status = data;
          _resetDone = null;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final status = _status;
    if (status == null) return;
    if (_newPassword.text.length < 8) {
      qfToast(context, '密码至少需要 8 位');
      return;
    }
    if (_newPassword.text != _confirmPassword.text) {
      qfToast(context, '两次输入的密码不一致，请重新输入。');
      return;
    }
    setState(() => _resetBusy = true);
    try {
      final data = await QfRecoveryApi.reset(
        widget.session.serverBaseUrl,
        appealId: (status['appealId'] as num).toInt(),
        resetGrant: (status['resetGrant'] ?? '').toString(),
        newPassword: _newPassword.text,
      );
      if (mounted) {
        setState(() => _resetDone = (data['message'] ?? '').toString());
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _resetBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final grant = status == null ? '' : (status['resetGrant'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: const Text('找回申诉状态')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          QfField(
            controller: _appealId,
            label: '申诉编号',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          QfField(controller: _account, label: '账户 ID 或邮箱'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _query,
            child: const Text('查询状态'),
          ),
          if (status != null) ...[
            const SizedBox(height: 24),
            Text(
              '处理状态：${_statusLabel((status['status'] ?? '').toString())}',
              style: AppTextStyle.headline.of(context),
            ),
            const SizedBox(height: 8),
            Text('好友验证：${status['friendVerified'] == true ? '已完成' : '未完成'}'),
            if ((status['rejectReason'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('审核意见：${status['rejectReason']}'),
            ],
            if (status['status'] == 'approved' && _resetDone == null) ...[
              const SizedBox(height: 16),
              if (grant.isNotEmpty) ...[
                const Text('您的申诉已通过审核。请在凭证有效期内设置新密码，设置成功后账户冻结将自动解除。'),
                const SizedBox(height: 12),
                QfField(controller: _newPassword, label: '新密码', obscure: true),
                const SizedBox(height: 12),
                QfField(
                  controller: _confirmPassword,
                  label: '确认新密码',
                  obscure: true,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _resetBusy ? null : _reset,
                  child: const Text('设置新密码并解除冻结'),
                ),
              ] else if (status['resetUsed'] == true)
                const Text('该申诉的重置凭证已经使用。如需再次找回，请重新提交申诉。')
              else
                const Text('重置凭证已生成，请使用首次查询时获取的凭证完成重置；凭证过期后可再次查询获取。'),
            ],
            if (_resetDone != null) ...[
              const SizedBox(height: 16),
              Text(_resetDone!),
            ],
          ],
        ],
      ),
    );
  }
}
