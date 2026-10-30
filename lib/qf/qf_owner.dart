import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import 'qf_api.dart';
import 'qf_pages.dart';
import 'qf_session.dart';
import 'qf_social.dart';

// 站长管理台（App 端）：入口显隐以服务端 GET /owner/me 为准，接口另有角色
// 校验，前端隐藏不构成权限边界。可见字段与服务端白名单一致（隐私裁定正本），
// 本页只呈现接口下发的字段。敏感操作只过一道确认（讲清对象与后果）：站长
// 会话本身即身份凭据，不再要求输入登录密码或通行密钥复核（站长 2026-10-26
// 亲令；服务端 /owner/* 与网页版站长台同口径，服务端闸门只验确认标记）。

String _fmtSec(dynamic sec) {
  final n = sec is num ? sec.toInt() : 0;
  if (n <= 0) return '—';
  return '${DateTime.fromMillisecondsSinceEpoch(n * 1000)}';
}

String _maskNote() => '邮箱已打码展示';

class QfOwnerEntryTile extends StatefulWidget {
  final QfSessionController session;

  const QfOwnerEntryTile({super.key, required this.session});

  @override
  State<QfOwnerEntryTile> createState() => _QfOwnerEntryTileState();
}

class _QfOwnerEntryTileState extends State<QfOwnerEntryTile> {
  bool _isOwner = false;
  String _probedFor = '';

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final email = widget.session.email ?? '';
    if (email.isEmpty || _probedFor == email) return;
    _probedFor = email;
    try {
      final data = await widget.session.authed('GET', '/owner/me');
      if (mounted) setState(() => _isOwner = data['isOwner'] == true);
    } catch (_) {
      if (mounted) setState(() => _isOwner = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _probe();
    if (!_isOwner) return const SizedBox.shrink();
    return ListTile(
      leading: const GlyphIcon(AppGlyphs.verified),
      title: const Text('站长管理台'),
      subtitle: const Text('用户管理、审核队列与管理审计'),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => QfOwnerUsersPage(session: widget.session),
          ),
        );
      },
    );
  }
}

Future<bool> _ownerConfirm(
  BuildContext context,
  String title,
  String body,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Text('$body\n\n该操作将记录在管理审计中。请核对无误后再继续。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确认无误，继续'),
        ),
      ],
    ),
  );
  return ok == true;
}

// 敏感操作统一入口：确认 → 直接执行业务体（只带 confirm 确认标记）。
Future<void> _ownerSensitive(
  BuildContext context,
  QfSessionController session, {
  required String title,
  required String body,
  required Future<String> Function(Map<String, dynamic> payload) run,
}) async {
  if (!await _ownerConfirm(context, title, body)) return;
  if (!context.mounted) return;
  try {
    final done = await run(const {'confirm': true});
    if (context.mounted) qfToast(context, done);
  } on QfApiException catch (e) {
    if (context.mounted) qfToast(context, qfAccountErrorMessage(e));
  }
}

class QfOwnerUsersPage extends StatefulWidget {
  final QfSessionController session;

  const QfOwnerUsersPage({super.key, required this.session});

  @override
  State<QfOwnerUsersPage> createState() => _QfOwnerUsersPageState();
}

class _QfOwnerUsersPageState extends State<QfOwnerUsersPage> {
  final _query = TextEditingController();
  String _by = 'username';
  List<dynamic> _users = [];
  int _total = 0;
  int _page = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = _query.text.trim();
      final path = StringBuffer('/owner/users?limit=20&offset=${_page * 20}');
      if (q.isNotEmpty) {
        path.write('&q=${Uri.encodeQueryComponent(q)}&by=$_by');
      }
      final data = await widget.session.authed('GET', path.toString());
      if (mounted) {
        setState(() {
          _users = (data['users'] as List?) ?? [];
          _total = (data['total'] as num?)?.toInt() ?? 0;
          _loading = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = qfAccountErrorMessage(e);
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('站长管理台'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => QfOwnerReviewsPage(session: widget.session),
                ),
              );
            },
            child: const Text('审核队列'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => QfOwnerAuditPage(session: widget.session),
                ),
              );
            },
            child: const Text('管理审计'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                DropdownButton<String>(
                  value: _by,
                  items: const [
                    DropdownMenuItem(value: 'username', child: Text('账户 ID')),
                    DropdownMenuItem(value: 'email', child: Text('邮箱')),
                  ],
                  onChanged: (v) => setState(() => _by = v ?? 'username'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(labelText: '搜索（支持开头匹配）'),
                    onSubmitted: (_) {
                      _page = 0;
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    _page = 0;
                    _load();
                  },
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '共 $_total 个用户。${_maskNote()}；完整邮箱仅可在用户详情中单条查看，查看会留审计记录。',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : _error != null
                ? Center(child: Text(_error!))
                : _users.isEmpty
                ? const Center(child: Text('没有符合条件的用户。'))
                : ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (context, i) {
                      final u = Map<String, dynamic>.from(_users[i] as Map);
                      final restricted = (u['restricted'] as Map?) ?? const {};
                      final flags = <String>[
                        if (restricted['hasActiveBan'] == true)
                          restricted['banLevel'] == 'permanent'
                              ? '封禁中（永久）'
                              : '封禁中',
                        if (restricted['passwordFrozen'] == true) '密码冻结',
                      ];
                      return ListTile(
                        leading: QfAvatarImage(
                          session: widget.session,
                          userId: qfRowId(u) ?? 0,
                          name: (u['nickname'] ?? u['username'] ?? '')
                              .toString(),
                          hasAvatar: u['hasAvatar'] == true,
                          avatarUpdatedAt: u['avatarVersion'],
                        ),
                        title: Text(
                          '${u['nickname'] ?? u['username']}'
                          '${flags.isEmpty ? '' : '（${flags.join('、')}）'}',
                        ),
                        subtitle: Text(
                          '账户 ID：${u['username']} ｜ ${u['emailMasked']} ｜ 注册于 ${_fmtSec(u['createdAt'])}',
                        ),
                        trailing: const GlyphIcon(AppGlyphs.chevronForward),
                        onTap: () async {
                          final userId = qfRowId(u);
                          if (userId == null) {
                            qfToast(context, '数据异常，请刷新后重试。');
                            return;
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => QfOwnerUserPage(
                                session: widget.session,
                                userId: userId,
                              ),
                            ),
                          );
                          _load();
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: _page > 0
                      ? () {
                          _page--;
                          _load();
                        }
                      : null,
                  child: const Text('上一页'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _users.length >= 20
                      ? () {
                          _page++;
                          _load();
                        }
                      : null,
                  child: const Text('下一页'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class QfOwnerUserPage extends StatefulWidget {
  final QfSessionController session;
  final int userId;

  const QfOwnerUserPage({
    super.key,
    required this.session,
    required this.userId,
  });

  @override
  State<QfOwnerUserPage> createState() => _QfOwnerUserPageState();
}

class _QfOwnerUserPageState extends State<QfOwnerUserPage> {
  Map<String, dynamic>? _basic;
  String? _error;

  QfSessionController get session => widget.session;
  int get uid => widget.userId;

  @override
  void initState() {
    super.initState();
    _loadBasic();
  }

  Future<void> _loadBasic() async {
    try {
      final data = await session.authed('GET', '/owner/users/$uid/basic');
      if (mounted) setState(() => _basic = data);
    } on QfApiException catch (e) {
      if (mounted) setState(() => _error = qfAccountErrorMessage(e));
    }
  }

  Future<Map<String, dynamic>> _tab(String name) =>
      session.authed('GET', '/owner/users/$uid/$name');

  Widget _kv(String label, String value) =>
      ListTile(dense: true, title: Text(label), subtitle: Text(value));

  Future<void> _viewEmail() async {
    await _ownerSensitive(
      context,
      session,
      title: '查看完整邮箱',
      body: '您将查看该用户的完整邮箱地址。此操作将记录在管理审计中（记录不含邮箱本身）。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/view-email',
          body: payload,
        );
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('完整邮箱'),
              content: Text('${data['email']}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        }
        return '已查看';
      },
    );
  }

  Future<void> _setPassword() async {
    final controller = TextEditingController();
    final newPw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('替用户设置新密码'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '新密码（8 至 72 位）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newPw == null || newPw.length < 8 || newPw.length > 72) {
      if (newPw != null && mounted) qfToast(context, '新密码长度须为 8 至 72 位。');
      return;
    }
    if (!mounted) return;
    await _ownerSensitive(
      context,
      session,
      title: '确认替用户设置新密码',
      body: '执行后：该用户在所有设备上的登录状态将被退出；如其密码处于冻结状态将一并解除；系统会发邮件通知该用户。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/set-password',
          body: {...payload, 'newPassword': newPw},
        );
        await _loadBasic();
        return '${data['message'] ?? '密码已重置。'}';
      },
    );
  }

  Future<void> _editNickname() async {
    final controller = TextEditingController();
    final nick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '新昵称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nick == null || nick.isEmpty || !mounted) return;
    await _ownerSensitive(
      context,
      session,
      title: '确认修改昵称',
      body: '新昵称将即时生效并公开显示，须通过内容审核口径。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/profile',
          body: {...payload, 'nickname': nick},
        );
        await _loadBasic();
        return '${data['message'] ?? '资料已更新。'}';
      },
    );
  }

  Future<void> _changeEmail() async {
    final controller = TextEditingController();
    final mail = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更换绑定邮箱'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '新邮箱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (mail == null || mail.isEmpty || !mounted) return;
    await _ownerSensitive(
      context,
      session,
      title: '确认更换绑定邮箱',
      body: '执行后：该用户在所有设备上的登录状态将被退出；新邮箱与原邮箱都会收到通知邮件。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/change-email',
          body: {...payload, 'newEmail': mail},
        );
        await _loadBasic();
        return '${data['message'] ?? '绑定邮箱已更换。'}';
      },
    );
  }

  Future<void> _ban() async {
    var level = 'timed';
    final days = TextEditingController(text: '7');
    final reason = TextEditingController(text: '违反用户协议');
    var alsoDevices = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('封禁用户'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                value: level,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'warn', child: Text('警告（仅记录）')),
                  DropdownMenuItem(value: 'timed', child: Text('限时封禁')),
                  DropdownMenuItem(value: 'permanent', child: Text('永久封禁')),
                ],
                onChanged: (v) => setLocal(() => level = v ?? 'timed'),
              ),
              TextField(
                controller: days,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '限时封禁天数'),
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: '封禁原因（向用户展示）'),
              ),
              CheckboxListTile(
                value: alsoDevices,
                onChanged: (v) => setLocal(() => alsoDevices = v ?? false),
                title: const Text('同时封禁该用户名下设备'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) {
      days.dispose();
      reason.dispose();
      return;
    }
    await _ownerSensitive(
      context,
      session,
      title: '确认封禁该用户',
      body: '封禁后该用户将无法登录（警告除外），其现有登录状态会被退出。封禁原因将按既定口径向该用户展示。',
      run: (payload) async {
        final body = <String, dynamic>{
          ...payload,
          'level': level,
          'reasonText': reason.text.trim().isEmpty
              ? '违反用户协议'
              : reason.text.trim(),
          'alsoBanDevices': alsoDevices,
        };
        if (level == 'timed') {
          body['durationDays'] = int.tryParse(days.text) ?? 7;
        }
        await session.authed('POST', '/owner/users/$uid/ban', body: body);
        await _loadBasic();
        return '已执行封禁。';
      },
    );
    days.dispose();
    reason.dispose();
  }

  Future<void> _unban() async {
    await _ownerSensitive(
      context,
      session,
      title: '解除封禁',
      body: '将解除该用户当前全部生效中的封禁（含永久封禁）。站长人工处置优先于自动处置，解除后自动系统不会就同一事由立即再次处置。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/unban',
          body: {...payload, 'includeDevices': true},
        );
        await _loadBasic();
        return '已解除封禁 ${data['lifted']} 条。';
      },
    );
  }

  Future<void> _unfreeze() async {
    await _ownerSensitive(
      context,
      session,
      title: '解除密码冻结',
      body: '将立即解除该用户的密码冻结并清零密码连错计数，该用户可重新登录。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/unfreeze',
          body: payload,
        );
        await _loadBasic();
        return '${data['message'] ?? '已解除冻结。'}';
      },
    );
  }

  Future<void> _disconnect() async {
    await _ownerSensitive(
      context,
      session,
      title: '静默断开连接',
      body: '将断开该用户当前的全部在线连接（仅断开本次连接，不封禁账号，其可重新连接）。对方不会收到任何提示。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/disconnect',
          body: {...payload, 'reasonCode': 'SECURITY_RISK'},
        );
        return '断开指令已发送，将在对方下一次心跳时生效（已排队 ${data['queuedDevices'] ?? 0} 台设备）。';
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = _basic;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('用户详情'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '积分与兑换'),
              Tab(text: '设备与连接'),
              Tab(text: '论坛'),
              Tab(text: '风控与处置'),
              Tab(text: '管理审计'),
            ],
          ),
        ),
        body: _error != null
            ? Center(child: Text(_error!))
            : b == null
            ? const Center(child: CommonCircleLoading.page())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${b['nickname'] ?? b['username']}',
                          style: AppTextStyle.headline.of(context),
                        ),
                        Text(
                          '账户 ID：${b['username']} ｜ ${b['emailMasked']} ｜ 状态：${b['status']}'
                          '${b['passwordFrozen'] == true ? ' ｜ 密码已冻结' : ''}',
                        ),
                        Text(
                          '注册于 ${_fmtSec(b['createdAt'])} ｜ 谷歌登录：${b['googleBound'] == true ? '已绑定' : '未绑定'}',
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            OutlinedButton(
                              onPressed: _viewEmail,
                              child: const Text('查看完整邮箱'),
                            ),
                            OutlinedButton(
                              onPressed: _setPassword,
                              child: const Text('替设新密码'),
                            ),
                            OutlinedButton(
                              onPressed: _editNickname,
                              child: const Text('修改昵称'),
                            ),
                            OutlinedButton(
                              onPressed: _changeEmail,
                              child: const Text('更换邮箱'),
                            ),
                            OutlinedButton(
                              onPressed: _ban,
                              child: const Text('封禁'),
                            ),
                            OutlinedButton(
                              onPressed: _unban,
                              child: const Text('解除封禁'),
                            ),
                            OutlinedButton(
                              onPressed: _unfreeze,
                              child: const Text('解除冻结'),
                            ),
                            OutlinedButton(
                              onPressed: _disconnect,
                              child: const Text('静默断开'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _OwnerAsyncTab(
                          load: () => _tab('points'),
                          build: (data) => _pointsView(data),
                        ),
                        _OwnerAsyncTab(
                          load: () async => {
                            'devices': await _tab('devices'),
                            'connection': await _tab('connection'),
                          },
                          build: (data) => _devicesView(data),
                        ),
                        _OwnerAsyncTab(
                          load: () => _tab('forum'),
                          build: (data) => _forumView(data),
                        ),
                        _OwnerAsyncTab(
                          load: () => _tab('risk'),
                          build: (data) => _riskView(data),
                        ),
                        _OwnerAsyncTab(
                          load: () => session.authed(
                            'GET',
                            '/owner/users/$uid/audit?limit=50',
                          ),
                          build: (data) => _auditView(data),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _pointsView(Map<String, dynamic> data) {
    final points = (data['points'] as Map?) ?? const {};
    final orders = (data['orders'] as List?) ?? [];
    return ListView(
      children: [
        _kv('可用积分', '${points['balance'] ?? 0}'),
        _kv('冻结积分', '${points['frozen'] ?? 0}'),
        _kv(
          '累计获得 / 消耗',
          '${points['totalEarned'] ?? 0} / ${points['totalSpent'] ?? 0}',
        ),
        _kv(
          '附件用量',
          '${(((data['attachmentUsageBytes'] as num?) ?? 0) / 1048576).toStringAsFixed(2)} MB',
        ),
        const ListTile(title: Text('兑换订单')),
        if (orders.isEmpty) const ListTile(subtitle: Text('暂无兑换订单。')),
        for (final raw in orders)
          Builder(
            builder: (context) {
              final o = Map<String, dynamic>.from(raw as Map);
              final masked =
                  (o['payoutAddressMasked'] ?? o['payoutEmailMasked'] ?? '—')
                      .toString();
              return ListTile(
                title: Text('#${o['id']} ${o['productName'] ?? ''}'),
                subtitle: Text(
                  '${o['pricePoints']} 分 ｜ ${o['status']} ｜ 发放信息：$masked',
                ),
                trailing: o['payoutAddressMasked'] != null
                    ? TextButton(
                        onPressed: () {
                          final orderId = qfIdValue(o['id']);
                          if (orderId == null) {
                            qfToast(context, '订单数据异常，暂时无法查看。');
                            return;
                          }
                          _viewPayout(orderId);
                        },
                        child: const Text('查看完整'),
                      )
                    : null,
              );
            },
          ),
        ListTile(
          title: const Text('查看积分流水'),
          trailing: const GlyphIcon(AppGlyphs.chevronForward),
          onTap: () async {
            final data2 = await session.authed(
              'GET',
              '/owner/users/$uid/ledger?limit=50',
            );
            if (!mounted) return;
            final rows = (data2['ledger'] as List?) ?? [];
            await showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('积分流水'),
                content: SizedBox(
                  width: double.maxFinite,
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (rows.isEmpty) const Text('暂无积分流水。'),
                      for (final raw in rows)
                        Builder(
                          builder: (context) {
                            final x = Map<String, dynamic>.from(raw as Map);
                            return ListTile(
                              dense: true,
                              title: Text(
                                '${x['type']} ${(x['amount'] as num) > 0 ? '+' : ''}${x['amount']}（余额 ${x['balanceAfter']}）',
                              ),
                              subtitle: Text(
                                '${_fmtSec(x['createdAt'])} ${x['note'] ?? ''}',
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _viewPayout(int orderId) async {
    await _ownerSensitive(
      context,
      session,
      title: '查看完整发放信息',
      body: '您将查看该订单的完整发放信息（收款地址或接收邮箱）。此操作将记录在管理审计中（记录不含具体内容）。',
      run: (payload) async {
        final data = await session.authed(
          'POST',
          '/owner/users/$uid/view-payout',
          body: {...payload, 'orderId': orderId},
        );
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('完整发放信息'),
              content: Text(
                '发放方式：${data['payoutMethod'] ?? ''}\n收款地址：${data['payoutAddress'] ?? '—'}\n接收邮箱：${data['payoutEmail'] ?? '—'}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        }
        return '已查看';
      },
    );
  }

  Widget _devicesView(Map<String, dynamic> data) {
    final devicesData = (data['devices'] as Map?) ?? const {};
    final conn = (data['connection'] as Map?) ?? const {};
    final devices = (devicesData['devices'] as List?) ?? [];
    final connDevices = (conn['devices'] as List?) ?? [];
    final traffic = connDevices.fold<int>(
      0,
      (s, x) =>
          s + ((((x as Map?) ?? const {})['trafficBytes'] as num?)?.toInt() ?? 0),
    );
    final passkey = (devicesData['passkeyStatus'] as Map?) ?? const {};
    return ListView(
      children: [
        _kv(
          '连接状态',
          conn['online'] == true
              ? '在线（连接 ${connDevices.length} 个，流量汇总 $traffic 字节）'
              : '不在线',
        ),
        _kv(
          '通行密钥',
          passkey['hasPasskey'] == true ? '已创建 ${passkey['count']} 个' : '未创建',
        ),
        const ListTile(subtitle: Text('出于隐私保护，管理台不展示连接来源地址与访问目标。')),
        if (devices.isEmpty) const ListTile(subtitle: Text('暂无设备记录。')),
        for (final raw in devices)
          Builder(
            builder: (context) {
              final d = Map<String, dynamic>.from(raw as Map);
              return ListTile(
                title: Text('${d['name'] ?? '（未知设备）'}'),
                subtitle: Text(
                  '${d['platform'] ?? ''} ｜ 地区 ${d['region'] ?? '—'} ｜ 最近活跃 ${_fmtSec(d['lastActiveAt'])} ｜ ${d['trusted'] == true ? '已信任' : '未信任'}',
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _forumView(Map<String, dynamic> data) {
    final stats = (data['stats'] as Map?) ?? const {};
    final camps = (data['camps'] as Map?) ?? const {};
    final created = (camps['created'] as List?) ?? [];
    final reports = (data['reports'] as Map?) ?? const {};
    return ListView(
      children: [
        _kv('已发布帖子', '${stats['publishedPosts'] ?? 0}'),
        _kv('已发布回复', '${stats['publishedReplies'] ?? 0}'),
        _kv('累计获赞', '${stats['likesReceived'] ?? 0}'),
        _kv(
          '创建的营地',
          created.isEmpty
              ? '无'
              : created
                    .map((c) => '${(c as Map)['name']}（${c['status']}）')
                    .join('、'),
        ),
        _kv('加入营地数', '${camps['joinedCount'] ?? 0}'),
        _kv(
          '被举报',
          '${reports['reportedTimes'] ?? 0} 次（成立 ${reports['upheldTimes'] ?? 0} 次）',
        ),
      ],
    );
  }

  Widget _riskView(Map<String, dynamic> data) {
    final bans = (data['bans'] as List?) ?? [];
    return ListView(
      children: [
        if (bans.isEmpty) const ListTile(subtitle: Text('暂无封禁记录。')),
        for (final raw in bans)
          Builder(
            builder: (context) {
              final x = Map<String, dynamic>.from(raw as Map);
              return ListTile(
                title: Text(
                  '${x['targetKind'] == 'user' ? '账号' : '设备'} ｜ ${x['level']} ｜ ${x['status']}',
                ),
                subtitle: Text(
                  '来源 ${x['source'] ?? ''} ｜ ${_fmtSec(x['createdAt'])} ｜ 原因码 ${x['reasonCode'] ?? ''}',
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _auditView(Map<String, dynamic> data) {
    final rows = (data['audit'] as List?) ?? [];
    return ListView(
      children: [
        if (rows.isEmpty) const ListTile(subtitle: Text('暂无针对该用户的管理记录。')),
        for (final raw in rows)
          Builder(
            builder: (context) {
              final x = Map<String, dynamic>.from(raw as Map);
              return ListTile(
                title: Text('${x['action']}'),
                subtitle: Text(
                  '${_fmtSec(x['createdAt'])} ｜ ${x['operator']} ｜ ${x['detail'] ?? ''}',
                ),
              );
            },
          ),
      ],
    );
  }
}

class _OwnerAsyncTab extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() load;
  final Widget Function(Map<String, dynamic>) build;

  const _OwnerAsyncTab({required this.load, required this.build});

  @override
  State<_OwnerAsyncTab> createState() => _OwnerAsyncTabState();
}

class _OwnerAsyncTabState extends State<_OwnerAsyncTab>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final data = await widget.load();
      if (mounted) setState(() => _data = data);
    } on QfApiException catch (e) {
      if (mounted) setState(() => _error = qfAccountErrorMessage(e));
    } catch (_) {
      if (mounted) setState(() => _error = '加载失败，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null) return Center(child: Text(_error!));
    if (_data == null) return const Center(child: CommonCircleLoading.page());
    return widget.build(_data!);
  }
}

class QfOwnerReviewsPage extends StatefulWidget {
  final QfSessionController session;

  const QfOwnerReviewsPage({super.key, required this.session});

  @override
  State<QfOwnerReviewsPage> createState() => _QfOwnerReviewsPageState();
}

class _QfOwnerReviewsPageState extends State<QfOwnerReviewsPage> {
  String _kind = 'forum';
  List<Widget> _rows = [];
  bool _loading = true;

  QfSessionController get session => widget.session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _decide(
    String path,
    Map<String, dynamic> extra,
    String title,
  ) async {
    await _ownerSensitive(
      context,
      session,
      title: title,
      body: '请确认对该条目执行此处理。处理结果将记录在管理审计中。',
      run: (payload) async {
        await session.authed('POST', path, body: {...payload, ...extra});
        await _load();
        return '已处理。';
      },
    );
  }

  Widget _row(String title, String sub, List<Widget> actions) => Card(
    child: ListTile(
      title: Text(title),
      subtitle: Text(sub),
      trailing: Wrap(spacing: 4, children: actions),
    ),
  );

  Widget _btn(String label, VoidCallback onTap) =>
      TextButton(onPressed: onTap, child: Text(label));

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = <Widget>[];
      if (_kind == 'forum') {
        final data = await session.authed(
          'GET',
          '/owner/reviews/forum-pending',
        );
        void addGroup(List<dynamic>? items, String label, String type) {
          for (final raw in items ?? []) {
            final p = Map<String, dynamic>.from(raw as Map);
            rows.add(
              _row(
                '[$label] ${p['title'] ?? p['name'] ?? ''}',
                '${p['contentPreview'] ?? p['introPreview'] ?? ''}',
                [
                  _btn(
                    '通过',
                    () => _decide(
                      '/owner/reviews/forum/$type/${p['id']}/review',
                      {'decision': 'approve'},
                      '通过该条目',
                    ),
                  ),
                  _btn(
                    '驳回',
                    () => _decide(
                      '/owner/reviews/forum/$type/${p['id']}/review',
                      {'decision': 'reject'},
                      '驳回该条目',
                    ),
                  ),
                  if (type == 'post' || type == 'reply')
                    _btn(
                      '删除',
                      () => _decide(
                        '/owner/forum/$type/${p['id']}/delete',
                        {},
                        '删除该条目',
                      ),
                    ),
                ],
              ),
            );
          }
        }

        addGroup(data['posts'] as List?, '待审帖子', 'post');
        addGroup(data['replies'] as List?, '待审回复', 'reply');
        addGroup(data['camps'] as List?, '待审营地', 'camp');
        addGroup(data['campRenames'] as List?, '营地改名', 'campRename');
        for (final raw in (data['campFlags'] as List?) ?? []) {
          final c = Map<String, dynamic>.from(raw as Map);
          rows.add(
            _row('[营地复核] ${c['name']}', '该营地曾被自动关闭，复核后可复开', [
              _btn(
                '复开营地',
                () => _decide(
                  '/owner/reviews/camps/${c['id']}/reopen',
                  {},
                  '复开该营地',
                ),
              ),
            ]),
          );
        }
      } else if (_kind == 'appeals') {
        final data = await session.authed(
          'GET',
          '/owner/reviews/appeals?status=pending',
        );
        for (final raw in (data['appeals'] as List?) ?? []) {
          final a = Map<String, dynamic>.from(raw as Map);
          rows.add(
            _row(
              '封号申诉 #${a['id']}（用户 ${a['userId']}）',
              '${a['content'] ?? ''}',
              [
                _btn(
                  '批准（解封）',
                  () => _decide('/owner/reviews/appeals/${a['id']}/review', {
                    'decision': 'approve',
                  }, '批准该申诉'),
                ),
                _btn(
                  '驳回',
                  () => _decide('/owner/reviews/appeals/${a['id']}/review', {
                    'decision': 'reject',
                  }, '驳回该申诉'),
                ),
              ],
            ),
          );
        }
      } else if (_kind == 'recovery') {
        final data = await session.authed(
          'GET',
          '/owner/reviews/recovery?status=pending',
        );
        for (final raw in (data['appeals'] as List?) ?? []) {
          final a = Map<String, dynamic>.from(raw as Map);
          rows.add(
            _row(
              '找回申诉 #${a['id']}（账号 ${a['account'] ?? ''}）',
              '旧密码命中 ${a['oldPasswordHits'] ?? 0} 个 ｜ 机型 ${a['deviceModel'] ?? '—'} ｜ 地点 ${a['locationText'] ?? '—'} ｜ 好友验证 ${a['friendVerified'] == true ? '已通过' : '未完成'}',
              [
                _btn(
                  '批准',
                  () => _decide('/owner/reviews/recovery/${a['id']}/decide', {
                    'decision': 'approve',
                  }, '批准该找回申诉'),
                ),
                _btn(
                  '驳回',
                  () => _decide('/owner/reviews/recovery/${a['id']}/decide', {
                    'decision': 'reject',
                  }, '驳回该找回申诉'),
                ),
              ],
            ),
          );
        }
      } else if (_kind == 'rewards') {
        final data = await session.authed(
          'GET',
          '/owner/reviews/rewards?state=pending',
        );
        for (final raw in (data['applications'] as List?) ?? []) {
          final a = Map<String, dynamic>.from(raw as Map);
          rows.add(
            _row(
              '千赞奖励 #${a['id']}（帖子 ${a['postId']}）',
              '申请时点赞数 ${a['likeCountAtApply'] ?? 0}',
              [
                _btn('点赞构成', () async {
                  try {
                    final d = await session.authed(
                      'GET',
                      '/owner/reviews/like-composition/${a['postId']}',
                    );
                    if (!mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('点赞构成（脱敏聚合）'),
                        content: Text(
                          '总赞 ${d['total']} ｜ 独立设备 ${d['distinctDevices']} ｜ 独立来源 ${d['distinctIpHashes']}\n'
                          '单设备最高占比 ${(((d['topDeviceShare'] as num?) ?? 0) * 100).round()}% ｜ 单来源最高占比 ${(((d['topIpShare'] as num?) ?? 0) * 100).round()}%',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  } on QfApiException catch (e) {
                    if (mounted) qfToast(context, qfAccountErrorMessage(e));
                  }
                }),
                _btn(
                  '批准',
                  () => _decide('/owner/reviews/rewards/${a['id']}/review', {
                    'decision': 'approve',
                  }, '批准该奖励申请'),
                ),
                _btn(
                  '驳回',
                  () => _decide('/owner/reviews/rewards/${a['id']}/review', {
                    'decision': 'reject',
                  }, '驳回该奖励申请'),
                ),
              ],
            ),
          );
        }
      } else if (_kind == 'orders') {
        final data = await session.authed('GET', '/owner/reviews/orders');
        for (final raw in (data['orders'] as List?) ?? []) {
          final o = Map<String, dynamic>.from(raw as Map);
          if (o['status'] != 'pending_review' &&
              o['status'] != 'pending_payout') {
            continue;
          }
          rows.add(
            _row(
              '兑换订单 #${o['id']}（用户 ${o['userId']}）',
              '${o['pricePoints']} 分 ｜ 状态 ${o['status']}',
              [
                _btn(
                  '审核通过',
                  () => _decide('/owner/reviews/orders/${o['id']}/review', {
                    'decision': 'approve',
                  }, '审核通过该订单'),
                ),
                _btn(
                  '驳回',
                  () => _decide('/owner/reviews/orders/${o['id']}/review', {
                    'decision': 'reject',
                  }, '驳回该订单'),
                ),
              ],
            ),
          );
        }
      }
      if (mounted) {
        setState(() {
          _rows = rows;
          _loading = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        qfToast(context, qfAccountErrorMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const kinds = [
      ('forum', '论坛待审'),
      ('appeals', '封号申诉'),
      ('recovery', '找回申诉'),
      ('rewards', '千赞奖励'),
      ('orders', '兑换订单'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('审核队列')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                for (final k in kinds)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(k.$2),
                      selected: _kind == k.$1,
                      onSelected: (_) {
                        setState(() => _kind = k.$1);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : _rows.isEmpty
                ? const Center(child: Text('暂无待处理条目。'))
                : ListView(padding: const EdgeInsets.all(12), children: _rows),
          ),
        ],
      ),
    );
  }
}

class QfOwnerAuditPage extends StatefulWidget {
  final QfSessionController session;

  const QfOwnerAuditPage({super.key, required this.session});

  @override
  State<QfOwnerAuditPage> createState() => _QfOwnerAuditPageState();
}

class _QfOwnerAuditPageState extends State<QfOwnerAuditPage> {
  List<dynamic> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.authed('GET', '/owner/audit?limit=50');
      if (mounted) {
        setState(() {
          _rows = (data['audit'] as List?) ?? [];
          _loading = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        qfToast(context, qfAccountErrorMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('管理审计（我的操作）')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : _rows.isEmpty
          ? const Center(child: Text('暂无管理操作记录。'))
          : ListView.builder(
              itemCount: _rows.length,
              itemBuilder: (context, i) {
                final x = Map<String, dynamic>.from(_rows[i] as Map);
                return ListTile(
                  title: Text('${x['action']}'),
                  subtitle: Text(
                    '${_fmtSec(x['createdAt'])} ｜ ${x['targetType'] ?? ''} ${x['targetId'] ?? ''} ｜ ${x['detail'] ?? ''}',
                  ),
                );
              },
            ),
    );
  }
}
