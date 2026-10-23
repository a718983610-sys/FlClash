import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_api.dart';
import 'qf_signal.dart';
import 'qf_pages.dart';
import 'qf_session.dart';

extension QfSocialApi on QfSessionController {
  Future<Map<String, dynamic>> socialGetProfile() async {
    final data = await authed('GET', '/profile');
    final profile = data['profile'];
    if (profile is Map) return Map<String, dynamic>.from(profile);
    return data;
  }

  Future<Map<String, dynamic>> socialUpdateProfile(
    Map<String, dynamic> body,
  ) async {
    return authed('PUT', '/profile', body: body);
  }

  Future<Map<String, dynamic>> socialGetUserProfile(int userId) async {
    final data = await authed('GET', '/profile/$userId');
    final profile = data['profile'];
    if (profile is Map) return Map<String, dynamic>.from(profile);
    return data;
  }

  Future<Map<String, dynamic>> socialProfileByUsername(
    String username,
  ) async {
    final data = await authed(
      'GET',
      '/profile/by-username?username=${Uri.encodeQueryComponent(username)}',
    );
    final profile = data['profile'];
    if (profile is Map) return Map<String, dynamic>.from(profile);
    return data;
  }

  Future<Map<String, dynamic>> socialFriends() async {
    return authed('GET', '/friends');
  }

  Future<List<dynamic>> socialFriendSearch(String query) async {
    final data = await authed(
      'GET',
      '/friends/search?q=${Uri.encodeQueryComponent(query)}',
    );
    final results = data['results'];
    return results is List ? results : const [];
  }

  Future<Map<String, dynamic>> socialFriendRequest(int userId) async {
    return authed('POST', '/friends/request', body: {'userId': userId});
  }

  Future<Map<String, dynamic>> socialFriendAccept(int userId) async {
    return authed('POST', '/friends/accept', body: {'userId': userId});
  }

  Future<Map<String, dynamic>> socialFriendReject(int userId) async {
    return authed('POST', '/friends/reject', body: {'userId': userId});
  }

  Future<Map<String, dynamic>> socialFriendDelete(int userId) async {
    return authed('DELETE', '/friends/$userId');
  }

  Future<List<dynamic>> socialChatHistory(int userId) async {
    final data = await authed('GET', '/chat/$userId/messages?limit=100');
    final messages = data['messages'];
    return messages is List ? messages : const [];
  }

  Future<Map<String, dynamic>> socialChatSend(
    int userId,
    int type,
    String body,
  ) async {
    return authed(
      'POST',
      '/chat/$userId/messages',
      body: {'type': type, 'body': body},
    );
  }
}

Widget qfAvatar(String? avatarData, String name, {double radius = 20}) {
  if (avatarData != null && avatarData.isNotEmpty) {
    try {
      return CircleAvatar(
        radius: radius,
        backgroundImage: MemoryImage(base64Decode(avatarData)),
      );
    } catch (_) {}
  }
  final label = name.isEmpty ? '?' : name.characters.first;
  return CircleAvatar(radius: radius, child: Text(label));
}

class QfProfilePage extends StatefulWidget {
  final QfSessionController session;

  const QfProfilePage({super.key, required this.session});

  @override
  State<QfProfilePage> createState() => _QfProfilePageState();
}

class _QfProfilePageState extends State<QfProfilePage> {
  final _nickname = TextEditingController();
  String? _avatarData;
  bool _loading = true;
  bool _hasKey = false;
  bool _hasBackup = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.session.socialGetProfile();
      if (mounted) {
        setState(() {
          _nickname.text = (profile['nickname'] ?? '').toString();
          final avatar = profile['avatarData'];
          _avatarData = avatar is String && avatar.isNotEmpty
              ? avatar
              : null;
          _hasBackup = profile['keyBackup'] is Map;
          _hasKey = true;
          _loading = false;
        });
      }
    } catch (_) {
      try {
        final forumProfile = await widget.session.forumProfile();
        if (mounted) {
          setState(() {
            _nickname.text = (forumProfile['nickname'] ?? '').toString();
            _hasKey = true;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 512 * 1024) {
      if (mounted) qfToast(context, '头像图片过大，请选择小于 512KB 的图片');
      return;
    }
    setState(() => _avatarData = base64Encode(bytes));
    await _save(showToast: false);
    if (mounted) qfToast(context, '头像已经更新');
  }

  Future<void> _save({bool showToast = true}) async {
    try {
      await widget.session.socialUpdateProfile({
        'nickname': _nickname.text.trim(),
        'avatarData': _avatarData,
      });
      try {
        await QfSignalManager.ensureInstalled(widget.session);
      } catch (_) {}
      try {
        await widget.session.forumUpdateNickname(_nickname.text.trim());
      } catch (_) {}
      if (mounted && showToast) qfToast(context, '个人资料已经保存');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<String?> _askPassword(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(labelText: '账号密码'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<void> _backupKey() async {
    final password = await _askPassword('备份聊天密钥');
    if (password == null || password.isEmpty) return;
    try {
      await QfSignalManager.ensureInstalled(widget.session);
      final backup = await QfSignalManager.buildBackup(password);
      await widget.session.socialUpdateProfile({'keyBackup': backup});
      if (mounted) {
        setState(() {
          _hasKey = true;
          _hasBackup = true;
        });
        qfToast(context, '聊天密钥已经加密备份，换设备时可用账号密码恢复');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _restoreKey() async {
    final password = await _askPassword('恢复聊天密钥');
    if (password == null || password.isEmpty) return;
    try {
      final profile = await widget.session.socialGetProfile();
      final backup = profile['keyBackup'];
      if (backup is! Map) {
        if (mounted) qfToast(context, '服务器上暂无密钥备份');
        return;
      }
      final ok = await QfSignalManager.restoreBackup(
        Map<String, dynamic>.from(backup),
        password,
      );
      if (ok) {
        try {
          final store = await QfSignalStore.load();
          store.bundlePublished = false;
          await store.persist();
          await QfSignalManager.ensureInstalled(widget.session);
        } catch (_) {}
      }
      if (mounted) {
        if (ok) {
          setState(() => _hasKey = true);
          qfToast(context, '聊天密钥已经恢复，历史消息可以继续查看');
        } else {
          qfToast(context, '恢复失败：密码不正确或备份已损坏');
        }
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('个人资料')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Column(
                    children: [
                      qfAvatar(_avatarData, _nickname.text, radius: 40),
                      TextButton(
                        onPressed: _pickAvatar,
                        child: const Text('更换头像'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nickname,
                  decoration: const InputDecoration(labelText: '昵称'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _save, child: const Text('保存资料')),
                const SizedBox(height: 24),
                Text(
                  '聊天密钥（端到端加密）',
                  style: AppTextStyle.headline.of(context),
                ),
                const SizedBox(height: 8),
                Text(
                  _hasKey
                      ? '本机已生成聊天密钥${_hasBackup ? '，并已加密备份到服务器' : ''}。'
                      : '本机尚未生成聊天密钥，首次与好友聊天时会自动生成。',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _backupKey,
                      child: const Text('备份聊天密钥'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _restoreKey,
                      child: const Text('恢复聊天密钥'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '聊天采用 Signal 协议端到端加密（X3DH 密钥协商＋双棘轮逐消息密钥，具备前向保密）：'
                  '服务器只转发密文，无法查看消息内容。私钥只保存在本机；'
                  '加密备份由账号密码经 Argon2id 派生的密钥保护，服务器同样无法解密。',
                  style: AppTextStyle.caption1.of(context),
                ),
              ],
            ),
    );
  }
}

class QfFriendsPage extends StatefulWidget {
  final QfSessionController session;

  const QfFriendsPage({super.key, required this.session});

  @override
  State<QfFriendsPage> createState() => _QfFriendsPageState();
}

class _QfFriendsPageState extends State<QfFriendsPage> {
  final _search = TextEditingController();
  List<dynamic> _friends = const [];
  List<dynamic> _requests = const [];
  List<dynamic> _results = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.socialFriends();
      if (mounted) {
        setState(() {
          final friends = data['friends'];
          final requests = data['requests'];
          _friends = friends is List ? friends : const [];
          _requests = requests is List ? requests : const [];
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
    }
  }

  Future<void> _doSearch() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    try {
      final results = await widget.session.socialFriendSearch(query);
      if (mounted) setState(() => _results = results);
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _scan() async {
    final username = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QfScanPage()),
    );
    if (username == null || username.isEmpty || !mounted) return;
    try {
      final profile = await widget.session.socialProfileByUsername(username);
      if (!mounted) return;
      await _showUserCard(profile);
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _showUserCard(Map<String, dynamic> profile) async {
    final userId = (profile['userId'] as num?)?.toInt();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              qfAvatar(
                profile['avatarData']?.toString(),
                (profile['nickname'] ?? '').toString(),
                radius: 36,
              ),
              const SizedBox(height: 12),
              Text(
                (profile['nickname'] ?? '').toString(),
                style: AppTextStyle.headline.of(context),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
            if (userId != null)
              FilledButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _act(
                    () => widget.session.socialFriendRequest(userId),
                    '好友申请已经发送',
                  );
                },
                child: const Text('添加好友'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _act(
    Future<Map<String, dynamic>> Function() action,
    String done,
  ) async {
    try {
      await action();
      if (mounted) qfToast(context, done);
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('好友'),
        actions: [
          TextButton.icon(
            onPressed: _scan,
            icon: const GlyphIcon(AppGlyphs.qrCode),
            label: const Text('扫一扫'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text('好友服务暂时不可用：$_error'),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          labelText: '搜索用户（邮箱或账户 ID）',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _doSearch, child: const Text('搜索')),
                  ],
                ),
                for (final raw in _results)
                  if (raw is Map)
                    ListTile(
                      leading: qfAvatar(
                        raw['avatarData']?.toString(),
                        (raw['nickname'] ?? '').toString(),
                      ),
                      title: Text((raw['nickname'] ?? '').toString()),
                      trailing: TextButton(
                        onPressed: () => _act(
                          () => widget.session.socialFriendRequest(
                            (raw['userId'] as num).toInt(),
                          ),
                          '好友申请已经发送',
                        ),
                        child: const Text('添加'),
                      ),
                    ),
                if (_requests.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '待处理申请',
                    style: AppTextStyle.headline.of(context),
                  ),
                  for (final raw in _requests)
                    if (raw is Map)
                      ListTile(
                        leading: qfAvatar(
                          raw['avatarData']?.toString(),
                          (raw['nickname'] ?? '').toString(),
                        ),
                        title: Text((raw['nickname'] ?? '').toString()),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => _act(
                                () => widget.session.socialFriendAccept(
                                  (raw['userId'] as num).toInt(),
                                ),
                                '已添加为好友',
                              ),
                              child: const Text('同意'),
                            ),
                            TextButton(
                              onPressed: () => _act(
                                () => widget.session.socialFriendReject(
                                  (raw['userId'] as num).toInt(),
                                ),
                                '已拒绝该申请',
                              ),
                              child: const Text('拒绝'),
                            ),
                          ],
                        ),
                      ),
                ],
                const SizedBox(height: 16),
                Text(
                  '我的好友',
                  style: AppTextStyle.headline.of(context),
                ),
                if (_friends.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无好友，可通过上方搜索添加'),
                  ),
                for (final raw in _friends)
                  if (raw is Map)
                    ListTile(
                      leading: qfAvatar(
                        raw['avatarData']?.toString(),
                        (raw['nickname'] ?? '').toString(),
                      ),
                      title: Text((raw['nickname'] ?? '').toString()),
                      subtitle: Text(
                        raw['username'] != null
                            ? '账户 ID：${raw['username']} · 点击进入聊天'
                            : '点击进入聊天',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const GlyphIcon(AppGlyphs.verified),
                            tooltip: '好友资料与安全码',
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => QfFriendProfilePage(
                                    session: widget.session,
                                    friend: Map<String, dynamic>.from(raw),
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: const GlyphIcon(AppGlyphs.remove),
                            tooltip: '删除好友',
                            onPressed: () => _act(
                          () => widget.session.socialFriendDelete(
                            (raw['userId'] as num).toInt(),
                          ),
                          '好友已经删除',
                        ),
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => QfChatPage(
                              session: widget.session,
                              friend: Map<String, dynamic>.from(raw),
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

class QfScanPage extends StatefulWidget {
  const QfScanPage({super.key});

  @override
  State<QfScanPage> createState() => _QfScanPageState();
}

class _QfScanPageState extends State<QfScanPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handle(String? value) {
    if (_done || value == null || value.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(value.trim());
  }

  Future<void> _importImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final capture = await MobileScannerPlatform.instance.analyzeImage(
      file.path,
      formats: const [BarcodeFormat.qrCode],
    );
    final value = capture?.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (value == null) {
      if (mounted) qfToast(context, '图片中没有识别到有效的二维码');
      return;
    }
    _handle(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫一扫')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                final value = capture.barcodes
                    .map((barcode) => barcode.rawValue)
                    .whereType<String>()
                    .firstOrNull;
                _handle(value);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: _importImage,
              icon: const GlyphIcon(AppGlyphs.photos),
              label: const Text('导入二维码图片'),
            ),
          ),
        ],
      ),
    );
  }
}


class QfFriendProfilePage extends StatelessWidget {
  final QfSessionController session;
  final Map<String, dynamic> friend;

  const QfFriendProfilePage({
    super.key,
    required this.session,
    required this.friend,
  });

  int get _peerId => (friend['userId'] as num).toInt();

  Future<void> _verifyByScan(BuildContext context) async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QfScanPage()),
    );
    if (scanned == null || !context.mounted) return;
    final fingerprint = await QfSignalManager.safetyFingerprint(
      session,
      _peerId,
    );
    if (fingerprint == null || !context.mounted) {
      if (context.mounted) qfToast(context, '暂时无法生成安全码');
      return;
    }
    var ok = false;
    if (scanned.startsWith('qfclash-safety:')) {
      try {
        ok = fingerprint.scannableFingerprint.compareTo(
          base64Decode(scanned.substring('qfclash-safety:'.length)),
        );
      } catch (_) {}
    }
    if (context.mounted) {
      qfToast(context, ok ? '安全码核对一致，身份确认无误' : '安全码不一致，请谨慎确认对方身份');
    }
  }

  @override
  Widget build(BuildContext context) {
    final nickname = (friend['nickname'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: const Text('好友资料')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                qfAvatar(friend['avatarData']?.toString(), nickname, radius: 40),
                const SizedBox(height: 12),
                Text(
                  nickname,
                  style: AppTextStyle.headline.of(context),
                ),
                if (friend['username'] != null)
                  Text('账户 ID：${friend['username']}'),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('安全码', style: AppTextStyle.headline.of(context)),
          const SizedBox(height: 8),
          const Text(
            '安全码由双方的身份密钥生成，用于核对对方身份是否真实。'
            '与好友当面或通过其他可信渠道比对数字，或扫码核对；'
            '如果对方更换设备或重装，安全码会变化，请重新核对。',
          ),
          const SizedBox(height: 12),
          FutureBuilder(
            future: QfSignalManager.safetyFingerprint(session, _peerId),
            builder: (context, snapshot) {
              final fingerprint = snapshot.data;
              if (fingerprint == null) {
                return const Text('安全码暂时不可用（对方尚未启用聊天加密或暂无会话）');
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectableText(
                    fingerprint.displayableFingerprint.getDisplayText(),
                    style: AppTextStyle.custom(context, size: 16, leading: 21),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: QrImageView(
                      data:
                          'qfclash-safety:${base64Encode(fingerprint.scannableFingerprint.fingerprints)}',
                      version: QrVersions.auto,
                      size: 180,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _verifyByScan(context),
                    icon: const GlyphIcon(AppGlyphs.qrCode),
                    label: const Text('扫码核对'),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class QfChatPage extends StatefulWidget {
  final QfSessionController session;
  final Map<String, dynamic> friend;

  const QfChatPage({super.key, required this.session, required this.friend});

  @override
  State<QfChatPage> createState() => _QfChatPageState();
}

class _QfChatPageState extends State<QfChatPage> {
  final _input = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  Timer? _timer;
  bool _loading = true;

  int get _peerId => (widget.friend['userId'] as num).toInt();

  String get _peerName => (widget.friend['nickname'] ?? '').toString();

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
    super.dispose();
  }

  Future<Map<String, String>> _sentCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('qf_chat_sent_$_peerId');
    if (raw == null) return {};
    return Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> _cacheSent(String id, String text) async {
    final cache = await _sentCache();
    cache[id] = text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qf_chat_sent_$_peerId', jsonEncode(cache));
  }

  Future<void> _load() async {
    try {
      final history = await widget.session.socialChatHistory(_peerId);
      final myId = widget.session.userId;
      final sentCache = await _sentCache();
      final decoded = <Map<String, dynamic>>[];
      for (final raw in history) {
        if (raw is! Map) continue;
        final mine = raw['fromUserId'] == myId;
        var text = '无法解密的消息';
        if (mine) {
          text = sentCache['${raw['id']}'] ?? '已加密发送的消息';
        } else {
          try {
            final type =
                (raw['type'] as num?)?.toInt() ??
                (raw['signalType'] as num?)?.toInt() ??
                3;
            final body = (raw['body'] ?? raw['ciphertext'] ?? '').toString();
            text = await QfSignalManager.decryptFrom(
              widget.session,
              _peerId,
              type,
              body,
            );
          } catch (_) {}
        }
        decoded.add({
          'mine': mine,
          'text': text,
          'createdAt': raw['createdAt'],
        });
      }
      if (mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(decoded);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    try {
      await QfSignalManager.ensureInstalled(widget.session);
      final sealed = await QfSignalManager.encryptFor(
        widget.session,
        _peerId,
        text,
      );
      final result = await widget.session.socialChatSend(
        _peerId,
        sealed.type,
        sealed.body,
      );
      final id = result['id'] ?? result['messageId'];
      if (id != null) {
        await _cacheSent('$id', text);
      }
      _input.clear();
      await _load();
    } on StateError {
      if (mounted) qfToast(context, '对方尚未启用聊天加密，暂时无法发送');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            qfAvatar(
              widget.friend['avatarData']?.toString(),
              _peerName,
              radius: 16,
            ),
            const SizedBox(width: 8),
            Text(_peerName),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '消息已端到端加密，服务器只转发密文。'
              '${widget.friend['username'] != null ? '对方账户 ID：${widget.friend['username']}' : ''}',
              style: AppTextStyle.caption1.of(context),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final mine = message['mine'] == true;
                      return Align(
                        alignment:
                            mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: mine
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                          ),
                          child: Text((message['text'] ?? '').toString()),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(hintText: '输入消息'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _send, child: const Text('发送')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
