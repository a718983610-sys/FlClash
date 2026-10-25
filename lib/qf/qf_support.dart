import 'dart:async';

import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_forum.dart';
import 'qf_pages.dart';
import 'qf_session.dart';

const String qfSupportBotKind = 'support_bot';
const String qfSupportBotUserId = 'support';

Map<String, dynamic> qfSupportBotEntry() {
  return {
    'kind': qfSupportBotKind,
    'userId': qfSupportBotUserId,
    'displayName': QfCopy.supportBotName,
    'nickname': QfCopy.supportBotName,
    'pinned': true,
    'undeletable': true,
  };
}

bool qfSupportIsBotEntry(Map<dynamic, dynamic> raw) {
  if (raw['kind'] == qfSupportBotKind) return true;
  return raw['userId']?.toString() == qfSupportBotUserId &&
      raw['undeletable'] == true;
}

bool qfSupportEntryDeletable(Map<dynamic, dynamic> raw) {
  return !qfSupportIsBotEntry(raw) && raw['undeletable'] != true;
}

List<dynamic> qfSupportWithBotEntry(
  List<dynamic> friends, {
  required bool loggedIn,
}) {
  if (!loggedIn) return friends;
  final rest = [
    for (final raw in friends)
      if (!(raw is Map && qfSupportIsBotEntry(raw))) raw,
  ];
  Map<dynamic, dynamic>? serverEntry;
  for (final raw in friends) {
    if (raw is Map && qfSupportIsBotEntry(raw)) {
      serverEntry = raw;
      break;
    }
  }
  return [serverEntry ?? qfSupportBotEntry(), ...rest];
}

String qfSupportDisplayNameForRole(String role) {
  return switch (role) {
    'agent' => QfCopy.supportAgentName,
    'user' => '用户',
    _ => QfCopy.supportBotName,
  };
}

class QfSupportOption {
  final String kbId;
  final String label;

  const QfSupportOption({required this.kbId, required this.label});

  static QfSupportOption? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final kbId = (raw['kbId'] ?? raw['id'] ?? '').toString();
    final label = (raw['label'] ?? raw['title'] ?? '').toString();
    if (kbId.isEmpty && label.isEmpty) return null;
    return QfSupportOption(kbId: kbId, label: label);
  }
}

List<QfSupportOption> _qfSupportOptions(dynamic raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (QfSupportOption.fromRaw(item) != null) QfSupportOption.fromRaw(item)!,
  ];
}

class QfSupportReply {
  final String action;
  final String text;
  final String? kbId;
  final String? sessionId;
  final List<QfSupportOption> alternates;
  final List<QfSupportOption> options;

  const QfSupportReply({
    required this.action,
    required this.text,
    this.kbId,
    this.sessionId,
    this.alternates = const [],
    this.options = const [],
  });

  factory QfSupportReply.fromJson(Map<String, dynamic> data) {
    return QfSupportReply(
      action: (data['action'] ?? 'answer').toString(),
      text: (data['text'] ?? data['message'] ?? '').toString(),
      kbId: data['kbId']?.toString(),
      sessionId: data['sessionId']?.toString(),
      alternates: _qfSupportOptions(data['alternates']),
      options: _qfSupportOptions(data['options']),
    );
  }

  bool get isHandoffOffer => action == 'handoff_offer';
  bool get isClarify => action == 'clarify';

  List<QfSupportOption> get choices =>
      options.isNotEmpty ? options : alternates;
}

class QfSupportMessage {
  final String role;
  final String body;
  final String? kbId;
  final int ts;

  const QfSupportMessage({
    required this.role,
    required this.body,
    this.kbId,
    this.ts = 0,
  });

  String get displayName => qfSupportDisplayNameForRole(role);
  bool get isBot => role == 'bot';
  bool get isAgent => role == 'agent';
  bool get isUser => role == 'user';

  static QfSupportMessage? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final role = (raw['author_role'] ?? raw['authorRole'] ?? raw['role'] ?? '')
        .toString();
    final body = (raw['body'] ?? raw['text'] ?? '').toString();
    if (body.isEmpty && role.isEmpty) return null;
    return QfSupportMessage(
      role: role.isEmpty ? 'bot' : role,
      body: body,
      kbId: raw['kb_id']?.toString() ?? raw['kbId']?.toString(),
      ts: _qfSupportTs(raw['created_at'] ?? raw['createdAt']),
    );
  }
}

int _qfSupportTs(dynamic raw) {
  if (raw is num) {
    final value = raw.toInt();
    return value < 1000000000000 ? value * 1000 : value;
  }
  if (raw is String && raw.isNotEmpty) {
    final numeric = int.tryParse(raw);
    if (numeric != null) {
      return numeric < 1000000000000 ? numeric * 1000 : numeric;
    }
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0;
  }
  return 0;
}

List<QfSupportMessage> qfSupportParseMessages(Map<String, dynamic> data) {
  final raw = data['messages'];
  if (raw is! List) return const [];
  final messages = [
    for (final item in raw)
      if (QfSupportMessage.fromRaw(item) != null)
        QfSupportMessage.fromRaw(item)!,
  ];
  messages.sort((a, b) => a.ts.compareTo(b.ts));
  return messages;
}

String? qfSupportParseSessionId(Map<String, dynamic> data) {
  final direct = data['sessionId'] ?? data['id'];
  if (direct != null && direct.toString().isNotEmpty) {
    return direct.toString();
  }
  final session = data['session'];
  if (session is Map) {
    final nested = session['id'] ?? session['sessionId'];
    if (nested != null && nested.toString().isNotEmpty) {
      return nested.toString();
    }
  }
  return null;
}

String qfSupportHandoffNotice(Map<String, dynamic> data) {
  final notice = (data['notice'] ?? '').toString();
  return notice.isNotEmpty ? notice : QfCopy.supportHandoffNotice;
}

const String qfSupportNotConfiguredNotice = '人工客服暂时无法转接，请稍后再试，或通过意见反馈联系我们。';

String qfSupportHandoffNoticeText(Map<String, dynamic> data) {
  if (data['supportConfigured'] == false) return qfSupportNotConfiguredNotice;
  return qfSupportHandoffNotice(data);
}

QfSupportMessage? qfSupportLatestAgentMessage(List<QfSupportMessage> messages) {
  for (final message in messages.reversed) {
    if (!message.isUser && message.body.isNotEmpty) return message;
  }
  return null;
}

int qfSupportUnreadCount(List<QfSupportMessage> messages, int seenTs) {
  return messages.where((m) => !m.isUser && m.ts > seenTs).length;
}

class QfSupportTicket {
  final String sessionId;
  final String userLabel;
  final bool userIsOwner;
  final String lastBody;
  final int unread;
  final String status;

  const QfSupportTicket({
    required this.sessionId,
    required this.userLabel,
    required this.userIsOwner,
    required this.lastBody,
    required this.unread,
    required this.status,
  });

  bool get isClosed => status == 'closed';

  static QfSupportTicket? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final sessionId = (raw['sessionId'] ?? raw['id'] ?? '').toString();
    if (sessionId.isEmpty) return null;
    var userLabel = (raw['userLabel'] ?? raw['username'] ?? '').toString();
    if (userLabel.isEmpty) {
      final user = raw['user'];
      if (user is Map) {
        userLabel = (user['nickname'] ?? user['username'] ?? '').toString();
      }
    }
    if (userLabel.isEmpty && raw['userId'] != null) {
      userLabel = '用户 ${raw['userId']}';
    }
    if (userLabel.isEmpty) userLabel = '用户';
    final user = raw['user'];
    return QfSupportTicket(
      sessionId: sessionId,
      userLabel: userLabel,
      userIsOwner:
          qfUserIsOwner(user is Map ? user : null) ||
          qfUserIsOwner(raw) ||
          qfIsOwnerUserId(raw['userId']),
      lastBody: (raw['lastMessage'] ?? raw['lastBody'] ?? raw['summary'] ?? '')
          .toString(),
      unread:
          (raw['unread'] as num?)?.toInt() ??
          (raw['unreadCount'] as num?)?.toInt() ??
          0,
      status: (raw['status'] ?? 'open').toString(),
    );
  }
}

List<QfSupportTicket> qfSupportParseTickets(Map<String, dynamic> data) {
  final raw = data['tickets'] ?? data['sessions'] ?? data['inbox'];
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (QfSupportTicket.fromRaw(item) != null) QfSupportTicket.fromRaw(item)!,
  ];
}

Future<bool> qfSupportDeskVisible(QfSessionController session) async {
  if (!session.isLoggedIn) return false;
  try {
    await session.supportInbox();
    return true;
  } catch (_) {
    return false;
  }
}

class QfSupportContactTile extends StatefulWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> entry;

  const QfSupportContactTile({
    super.key,
    required this.session,
    required this.entry,
  });

  @override
  State<QfSupportContactTile> createState() => _QfSupportContactTileState();
}

class _QfSupportContactTileState extends State<QfSupportContactTile> {
  // The seen marker is per account (C-51): a shared key would leak one
  // account's read state into another's unread count.
  String get _seenKey =>
      'qf_support_seen_latest_ts_${widget.session.userId ?? 0}';
  bool get _guest => !widget.session.isLoggedIn;
  String? _latestSummary;
  int _unread = 0;
  int _latestTs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = _guest
          ? await widget.session.guestSupportSession()
          : await widget.session.supportSession();
      final messages = qfSupportParseMessages(data);
      final latest = qfSupportLatestAgentMessage(messages);
      final prefs = await SharedPreferences.getInstance();
      final seenTs = prefs.getInt(_seenKey) ?? 0;
      if (mounted) {
        setState(() {
          _latestSummary = latest?.body;
          _latestTs = latest?.ts ?? 0;
          _unread = qfSupportUnreadCount(messages, seenTs);
        });
      }
    } catch (_) {}
  }

  Future<void> _open() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_latestTs > 0) await prefs.setInt(_seenKey, _latestTs);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _unread = 0);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QfSupportPage(session: widget.session),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const ValueKey('qf-support-contact'),
      leading: const CircleAvatar(
        child: GlyphIcon(AppGlyphs.sparkle, size: 20),
      ),
      title: Row(
        children: [
          Text(
            (widget.entry['displayName'] ?? QfCopy.supportBotName).toString(),
          ),
          const SizedBox(width: 8),
          Text(
            '系统',
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
      subtitle: Text(
        _latestSummary == null || _latestSummary!.isEmpty
            ? '智能客服 · 自动回复，点击进入客服会话'
            : _latestSummary!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_unread > 0)
            DecoratedBox(
              decoration: ShapeDecoration(
                color: Theme.of(context).colorScheme.error,
                shape: AppShape.full,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                child: Text(
                  _unread > 99 ? '99+' : '$_unread',
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: Theme.of(context).colorScheme.onError),
                ),
              ),
            ),
          const SizedBox(width: 4),
          const GlyphIcon(AppGlyphs.pin, size: 16),
        ],
      ),
      onTap: _open,
    );
  }
}

class QfSupportDeskTile extends StatelessWidget {
  final QfSessionController session;

  const QfSupportDeskTile({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const ValueKey('qf-support-desk-entry'),
      leading: const CircleAvatar(
        child: GlyphIcon(AppGlyphs.account, size: 20),
      ),
      title: const Text(QfCopy.supportDeskTitle),
      subtitle: const Text('人工客服工单列表与回复'),
      trailing: const GlyphIcon(AppGlyphs.chevronForward, size: 16),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => QfSupportInboxPage(session: session),
          ),
        );
      },
    );
  }
}

Widget _qfSupportBubble(
  BuildContext context, {
  required String name,
  required String body,
  required bool mine,
  bool autoTag = false,
}) {
  final colors = Theme.of(context).colorScheme;
  return Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: ShapeDecoration(
        color: mine ? colors.primaryContainer : colors.surfaceContainerHighest,
        shape: AppShape.md,
      ),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: AppTextStyle.caption1.of(context)),
              if (autoTag) ...[
                const SizedBox(width: 6),
                Text(
                  QfCopy.supportAutoReplyTag,
                  style: AppTextStyle.caption2
                      .of(context)
                      .copyWith(color: colors.primary),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(body),
        ],
      ),
    ),
  );
}

class QfSupportPage extends StatefulWidget {
  final QfSessionController session;

  const QfSupportPage({super.key, required this.session});

  @override
  State<QfSupportPage> createState() => _QfSupportPageState();
}

class _QfSupportPageState extends State<QfSupportPage> {
  final _input = TextEditingController();
  final _verifyAccount = TextEditingController();
  final _verifyPassword = TextEditingController();
  final _bottomAnchor = GlobalKey();
  final List<QfSupportMessage> _messages = [];
  Timer? _timer;
  bool _loading = true;
  bool _sending = false;
  bool _handingOff = false;
  bool _handedOff = false;
  bool _verifyOpen = false;
  bool _verifying = false;
  String? _linkedLabel;
  String? _sessionId;
  QfSupportReply? _lastReply;
  String? _handoffNotice;

  /// Reachable without an account: guests and signed-out visitors ask
  /// anonymously through the guest channel and may optionally link the
  /// consultation to their account by verification (never a login).
  bool get _guest => !widget.session.isLoggedIn;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    _verifyAccount.dispose();
    _verifyPassword.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _bottomAnchor.currentContext;
      if (anchor != null) {
        Scrollable.ensureVisible(anchor);
      }
    });
  }

  Future<void> _load() async {
    try {
      final data = _guest
          ? await widget.session.guestSupportSession()
          : await widget.session.supportSession();
      final parsed = qfSupportParseMessages(data);
      final sessionId = qfSupportParseSessionId(data);
      if (mounted) {
        setState(() {
          if (parsed.isNotEmpty || _messages.isEmpty) {
            // Merge, not replace (C-49): a poll landing right after a
            // send must not wipe the just-added local echo and reply
            // before the server snapshot includes them. Local-only
            // entries carry ts 0; once the server echoes the same
            // role+body, the local copy drops out.
            final serverKeys = {
              for (final message in parsed)
                '${message.role}|${message.body}',
            };
            final localOnly = _messages
                .where(
                  (message) =>
                      message.ts == 0 &&
                      !serverKeys.contains(
                        '${message.role}|${message.body}',
                      ),
                )
                .toList();
            _messages
              ..clear()
              ..addAll(parsed)
              ..addAll(localOnly);
          }
          if (sessionId != null) _sessionId = sessionId;
          _loading = false;
        });
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _ask({
    String? text,
    bool notThis = false,
    String? kbId,
    String? localEcho,
  }) async {
    if (_sending) return false;
    setState(() => _sending = true);
    try {
      final data = _guest
          ? await widget.session.guestSupportAsk(
              sessionId: _sessionId,
              text: text,
              notThis: notThis,
              kbId: kbId,
            )
          : await widget.session.supportAsk(
              sessionId: _sessionId,
              text: text,
              notThis: notThis,
              kbId: kbId,
            );
      final reply = QfSupportReply.fromJson(data);
      if (mounted) {
        setState(() {
          if (reply.sessionId != null) _sessionId = reply.sessionId;
          if (localEcho != null && localEcho.isNotEmpty) {
            _messages.add(QfSupportMessage(role: 'user', body: localEcho));
          }
          if (reply.text.isNotEmpty) {
            _messages.add(
              QfSupportMessage(role: 'bot', body: reply.text, kbId: reply.kbId),
            );
          }
          _lastReply = reply;
        });
        _scrollToBottom();
      }
      return true;
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    final account = _verifyAccount.text.trim();
    final password = _verifyPassword.text;
    if (account.isEmpty || password.isEmpty || _verifying) return;
    setState(() => _verifying = true);
    try {
      final data = await widget.session.guestSupportVerify(
        account: account,
        password: password,
      );
      if (mounted) {
        setState(() {
          _linkedLabel =
              (data['accountLabel'] ?? data['username'] ?? account).toString();
          _verifyPassword.clear();
        });
        qfToast(context, '已关联账户，本次咨询将带上您的账户信息。');
        await _load();
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Widget _verifyCard(BuildContext context) {
    if (!_guest) return const SizedBox.shrink();
    if (_linkedLabel != null) {
      return Container(
        key: const ValueKey('qf-support-linked'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text('已关联账户：$_linkedLabel（仅用于本次咨询核验，不会登录您的账户）'),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton(
            key: const ValueKey('qf-support-verify-toggle'),
            onPressed: () => setState(() => _verifyOpen = !_verifyOpen),
            child: Text(_verifyOpen ? '收起账户关联' : '咨询与账户有关？可先关联账户（可选）'),
          ),
          if (_verifyOpen) ...[
            const Text('输入账户 ID 或邮箱与密码进行核验。只核验身份、关联本次咨询，不会登录您的账户。'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('qf-support-verify-account'),
              controller: _verifyAccount,
              decoration: const InputDecoration(labelText: '账户 ID 或邮箱'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('qf-support-verify-password'),
              controller: _verifyPassword,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('qf-support-verify-submit'),
              onPressed: _verifying ? null : _verify,
              child: Text(_verifying ? '正在核验……' : '核验并关联'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // Clear the composer only once the send actually succeeded: the
    // old order (clear first, ask second) lost the user's words
    // whenever the request failed (C-48).
    final sent = await _ask(text: text, localEcho: text);
    if (sent && _input.text.trim() == text) _input.clear();
  }

  Future<void> _handoff() async {
    if (_handingOff || _handedOff) return;
    setState(() => _handingOff = true);
    try {
      final data = _guest
          ? await widget.session.guestSupportHandoff(_sessionId)
          : await widget.session.supportHandoff(_sessionId);
      final notice = qfSupportHandoffNoticeText(data);
      final sessionId = qfSupportParseSessionId(data);
      if (mounted) {
        setState(() {
          _handoffNotice = notice;
          _handedOff = true;
          if (sessionId != null) _sessionId = sessionId;
        });
        qfToast(context, notice);
      }
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _handingOff = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reply = _lastReply;
    return Scaffold(
      appBar: AppBar(title: const Text(QfCopy.supportBotName)),
      body: Column(
        children: [
          Container(
            key: const ValueKey('qf-support-banner'),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              QfCopy.supportBanner,
              style: AppTextStyle.caption1.of(context),
            ),
          ),
          if (_handoffNotice != null)
            Container(
              key: const ValueKey('qf-support-handoff-notice'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(_handoffNotice!),
            ),
          _verifyCard(context),
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : _messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('您好，这里是智能客服。请输入您遇到的问题，智能客服将为您解答。'),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _messages.length) {
                        return SizedBox(key: _bottomAnchor, height: 1);
                      }
                      final message = _messages[index];
                      return _qfSupportBubble(
                        context,
                        name: message.displayName,
                        body: message.body,
                        mine: message.isUser,
                        autoTag: message.isBot,
                      );
                    },
                  ),
          ),
          if (reply != null && reply.choices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in reply.choices)
                    OutlinedButton(
                      key: ValueKey('qf-support-option-${option.kbId}'),
                      onPressed: _sending
                          ? null
                          : () => _ask(
                              text: option.label,
                              kbId: option.kbId.isEmpty ? null : option.kbId,
                              localEcho: option.label,
                            ),
                      child: Text(option.label),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                TextButton(
                  key: const ValueKey('qf-support-handoff'),
                  onPressed: _handingOff || _handedOff ? null : _handoff,
                  child: Text(_handedOff ? '已转人工' : '转人工'),
                ),
                if (reply != null && !reply.isHandoffOffer)
                  TextButton(
                    key: const ValueKey('qf-support-not-this'),
                    onPressed: _sending ? null : () => _ask(notThis: true),
                    child: const Text(QfCopy.supportNotThis),
                  ),
              ],
            ),
          ),
          if (reply != null && reply.isHandoffOffer && !_handedOff)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton(
                key: const ValueKey('qf-support-handoff-confirm'),
                onPressed: _handingOff ? null : _handoff,
                child: const Text('转人工客服'),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('qf-support-input'),
                      controller: _input,
                      decoration: const InputDecoration(hintText: '请输入您的问题'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('qf-support-send'),
                    onPressed: _sending ? null : _send,
                    child: const Text('发送'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class QfSupportInboxPage extends StatefulWidget {
  final QfSessionController session;

  const QfSupportInboxPage({super.key, required this.session});

  @override
  State<QfSupportInboxPage> createState() => _QfSupportInboxPageState();
}

class _QfSupportInboxPageState extends State<QfSupportInboxPage> {
  List<QfSupportTicket> _tickets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.supportInbox();
      if (mounted) {
        setState(() {
          _tickets = qfSupportParseTickets(data);
          _loading = false;
          _error = null;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载失败，请稍后重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(QfCopy.supportDeskTitle)),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : _error != null
          ? Center(child: Text('客服会话加载失败：$_error'))
          : _tickets.isEmpty
          ? const Center(child: Text('暂无客服会话。'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final ticket in _tickets)
                  ListTile(
                    key: ValueKey('qf-support-ticket-${ticket.sessionId}'),
                    title: QfBadgedName(
                      name: ticket.userLabel,
                      isOwner: ticket.userIsOwner,
                    ),
                    subtitle: Text(
                      ticket.lastBody.isEmpty ? '暂无消息摘要' : ticket.lastBody,
                    ),
                    trailing: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(ticket.isClosed ? '已关闭' : '处理中'),
                        if (ticket.unread > 0) Text('未读 ${ticket.unread}'),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => QfSupportTicketPage(
                            session: widget.session,
                            ticket: ticket,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    );
  }
}

class QfSupportTicketPage extends StatefulWidget {
  final QfSessionController session;
  final QfSupportTicket ticket;

  const QfSupportTicketPage({
    super.key,
    required this.session,
    required this.ticket,
  });

  @override
  State<QfSupportTicketPage> createState() => _QfSupportTicketPageState();
}

class _QfSupportTicketPageState extends State<QfSupportTicketPage> {
  final _input = TextEditingController();
  List<QfSupportMessage> _messages = const [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _sending = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _closed = widget.ticket.isClosed;
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.supportInboxDetail(
        widget.ticket.sessionId,
      );
      if (mounted) {
        setState(() {
          _messages = qfSupportParseMessages(data);
          final status = (data['status'] ?? '').toString();
          if (status.isNotEmpty) _closed = status == 'closed';
          _loading = false;
          _loadFailed = false;
        });
      }
    } on QfApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        qfToast(context, e.message);
      }
    } catch (_) {
      // Any non-API throw must still land on a failure state, never on
      // an endless spinner (C-52).
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _reply() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.session.supportInboxReply(widget.ticket.sessionId, text);
      _input.clear();
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    try {
      await widget.session.supportInboxClose(widget.ticket.sessionId);
      if (mounted) {
        setState(() => _closed = true);
        qfToast(context, '该客服会话已关闭。');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: QfBadgedName(
          name: widget.ticket.userLabel,
          isOwner: widget.ticket.userIsOwner,
        ),
        actions: [
          if (!_closed)
            TextButton(
              key: const ValueKey('qf-support-ticket-close'),
              onPressed: _close,
              child: const Text('关闭工单'),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : _loadFailed
                ? QfLoadFailure(onRetry: _load)
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return _qfSupportBubble(
                        context,
                        name: message.isUser
                            ? widget.ticket.userLabel
                            : message.displayName,
                        body: message.body,
                        mine: message.isAgent,
                        autoTag: message.isBot,
                      );
                    },
                  ),
          ),
          if (_closed)
            const Padding(padding: EdgeInsets.all(12), child: Text('该客服会话已关闭。'))
          else
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('qf-support-reply-input'),
                        controller: _input,
                        decoration: const InputDecoration(
                          hintText: '以人工客服身份回复',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('qf-support-reply-send'),
                      onPressed: _sending ? null : _reply,
                      child: const Text('回复'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
