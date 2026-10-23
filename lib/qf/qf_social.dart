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
import 'qf_recovery.dart';
import 'qf_signal.dart';
import 'qf_pages.dart';
import 'qf_session.dart';
import 'qf_support.dart';

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

  Future<Map<String, dynamic>> socialProfileByUsername(String username) async {
    final data = await authed(
      'GET',
      '/profile/by-username/${Uri.encodeComponent(username)}',
    );
    final profile = data['profile'];
    if (profile is Map) return Map<String, dynamic>.from(profile);
    return data;
  }

  Future<Map<String, dynamic>> socialFriends() async {
    return authed('GET', '/friends');
  }

  Future<Map<String, dynamic>> socialFriendRequests() async {
    return authed('GET', '/friends/requests');
  }

  Future<List<dynamic>> socialFriendSearch(String query) async {
    final data = await authed(
      'POST',
      '/friends/search',
      body: {'query': query},
    );
    final users = data['users'];
    return users is List ? users : const [];
  }

  Future<Map<String, dynamic>> socialFriendRequest(int userId) async {
    return authed('POST', '/friends/request', body: {'userId': userId});
  }

  Future<Map<String, dynamic>> socialFriendAccept(int requestId) async {
    return authed('POST', '/friends/request/$requestId/accept');
  }

  Future<Map<String, dynamic>> socialFriendReject(int requestId) async {
    return authed('POST', '/friends/request/$requestId/reject');
  }

  Future<Map<String, dynamic>> socialFriendDelete(int userId) async {
    return authed('DELETE', '/friends/$userId');
  }

  Future<List<dynamic>> socialChatHistory(
    int withUserId, {
    int after = 0,
  }) async {
    final data = await authed(
      'GET',
      '/chat/messages?with=$withUserId&after=$after&limit=200',
    );
    final messages = data['messages'];
    return messages is List ? messages : const [];
  }

  Future<Map<String, dynamic>> socialChatSend(
    int toUserId, {
    required String msgId,
    required String ciphertext,
    required String nonce,
  }) async {
    return authed(
      'POST',
      '/chat/send',
      body: {
        'to': toUserId,
        'msgId': msgId,
        'ciphertext': ciphertext,
        'nonce': nonce,
      },
    );
  }

  Future<List<dynamic>> socialChatConversations() async {
    final data = await authed('GET', '/chat/conversations');
    final conversations = data['conversations'];
    return conversations is List ? conversations : const [];
  }

  Future<void> socialChatRead(int withUserId, {int? upToId}) async {
    await authed(
      'POST',
      '/chat/read',
      body: {'with': withUserId, 'upToId': ?upToId},
    );
  }

  Future<List<dynamic>> recoveryFriendRequests() async {
    final data = await authed('GET', '/appeals/recovery/friend-requests');
    final requests = data['requests'];
    return requests is List ? requests : const [];
  }

  Future<Map<String, dynamic>> recoveryFriendVerify(
    String applicantAccount,
    String code,
  ) async {
    return authed(
      'POST',
      '/appeals/recovery/friend-verify',
      body: {'applicantAccount': applicantAccount, 'code': code},
    );
  }

  Future<Map<String, dynamic>> socialGetMyPrekeyBundle() async {
    return authed('GET', '/chat/prekey-bundle');
  }

  Future<Map<String, dynamic>> socialGetPrekeyBundle(int userId) async {
    return authed('GET', '/chat/prekey-bundle/$userId');
  }

  Future<Map<String, dynamic>> socialPutPrekeyBundle(
    Map<String, dynamic> body,
  ) async {
    return authed('PUT', '/chat/prekey-bundle', body: body);
  }

  Future<Map<String, dynamic>> socialPutKeyBackup(String backup) async {
    return authed('PUT', '/chat/key-backup', body: {'backup': backup});
  }

  Future<Map<String, dynamic>> socialGetKeyBackup() async {
    return authed('GET', '/chat/key-backup');
  }

  Future<Uint8List?> socialAvatarBytes(int userId) async {
    return qfGetBinary('/profile/$userId/avatar');
  }
}

int _qfTsMillis(dynamic raw) {
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

final Map<int, Uint8List?> _qfAvatarCache = {};

Widget _qfLetterAvatar(String name, double radius) {
  final label = name.isEmpty ? '?' : name.characters.first;
  return CircleAvatar(radius: radius, child: Text(label));
}

/// 按服务端公开资料的 hasAvatar 标记，从二进制端点拉头像并缓存；
/// 没有头像或拉取失败时显示昵称首字。
class QfAvatarImage extends StatefulWidget {
  final QfSessionController session;
  final int? userId;
  final String name;
  final bool? hasAvatar;
  final double radius;

  const QfAvatarImage({
    super.key,
    required this.session,
    required this.userId,
    required this.name,
    this.hasAvatar,
    this.radius = 20,
  });

  @override
  State<QfAvatarImage> createState() => _QfAvatarImageState();
}

class _QfAvatarImageState extends State<QfAvatarImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(QfAvatarImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _bytes = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final userId = widget.userId;
    if (userId == null || widget.hasAvatar == false) return;
    if (_qfAvatarCache.containsKey(userId)) {
      _bytes = _qfAvatarCache[userId];
      return;
    }
    final bytes = await widget.session.socialAvatarBytes(userId);
    _qfAvatarCache[userId] = bytes;
    if (mounted && bytes != null) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundImage: MemoryImage(bytes),
      );
    }
    return _qfLetterAvatar(widget.name, widget.radius);
  }
}

String _qfAvatarMime(XFile file) {
  final declared = file.mimeType;
  if (declared != null && declared.isNotEmpty) return declared;
  final name = file.name.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

class QfProfilePage extends StatefulWidget {
  final QfSessionController session;

  const QfProfilePage({super.key, required this.session});

  @override
  State<QfProfilePage> createState() => _QfProfilePageState();
}

class _QfProfilePageState extends State<QfProfilePage> {
  final _nickname = TextEditingController();
  Uint8List? _avatarBytes;
  String _loadedNickname = '';
  bool _loading = true;
  bool _hasKey = false;
  bool _hasBackup = false;
  bool _historyUnlocked = false;
  bool _historyBusy = false;
  int _historyLocalCount = 0;
  int _historyCloudEntries = 0;
  int _historyCloudBytes = 0;

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

  Future<void> _refreshHistoryStatus() async {
    final status = await QfChatHistoryVault.status();
    if (mounted) {
      setState(() {
        _historyUnlocked = QfChatHistoryVault.historyUnlocked;
        _historyLocalCount = status.localCount;
        _historyCloudEntries = status.totalEntries;
        _historyCloudBytes = status.totalBytes;
      });
    }
  }

  Future<void> _unlockHistory() async {
    final password = await _askPassword(
      '解锁聊天记录保险库',
      note: '备份由您的账户密码加密，通行密钥无法解密，请输入账户密码。',
    );
    if (password == null || password.isEmpty) return;
    setState(() => _historyBusy = true);
    try {
      await QfChatHistoryVault.unlock(
        session: widget.session,
        password: password,
      );
      final restored = await QfChatHistoryVault.pullIncremental(widget.session);
      var capacityHit = false;
      try {
        await QfChatHistoryVault.pushPending(widget.session);
      } on QfApiException catch (e) {
        if (e.code == 'HISTORY_CAPACITY_EXCEEDED') capacityHit = true;
      }
      await _refreshHistoryStatus();
      if (mounted) {
        if (capacityHit) {
          qfToast(context, '云端聊天记录归档已达容量上限，请清理较早的会话后重试。');
        } else if (restored > 0) {
          qfToast(context, '聊天记录已经恢复：新增 $restored 条历史消息。');
        } else {
          qfToast(context, '聊天记录保险库已解锁，暂无可恢复的聊天记录。');
        }
      }
    } on QfChatHistoryException catch (e) {
      if (mounted) qfToast(context, '恢复失败：${e.message}');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _historyBusy = false);
    }
  }

  Future<void> _clearHistoryCloud() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('清除云端聊天记录'),
          content: const Text('清除后云端归档与保险库密钥将一并删除，无法恢复；本机记录不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await QfChatHistoryVault.clearCloud(widget.session);
      await _refreshHistoryStatus();
      if (mounted) qfToast(context, '云端聊天记录归档已清空。');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _load() async {
    unawaited(_refreshHistoryStatus());
    try {
      final profile = await widget.session.socialGetProfile();
      final nickname = (profile['nickname'] ?? '').toString();
      final hasAvatar = profile['hasAvatar'] == true;
      final userId =
          (profile['userId'] as num?)?.toInt() ?? widget.session.userId;
      Uint8List? bytes;
      if (hasAvatar && userId != null) {
        bytes = await widget.session.socialAvatarBytes(userId);
        if (bytes != null) _qfAvatarCache[userId] = bytes;
      }
      if (mounted) {
        setState(() {
          _nickname.text = nickname;
          _loadedNickname = nickname;
          _avatarBytes = bytes;
          _hasBackup = profile['hasKeyBackup'] == true;
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
            _loadedNickname = _nickname.text;
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
    if (bytes.length > 200 * 1024) {
      if (mounted) qfToast(context, '头像图片过大，请选择小于 200KB 的图片');
      return;
    }
    try {
      await widget.session.socialUpdateProfile({
        'avatar': {
          'mime': _qfAvatarMime(file),
          'dataBase64': base64Encode(bytes),
        },
      });
      final userId = widget.session.userId;
      if (userId != null) _qfAvatarCache[userId] = bytes;
      if (mounted) {
        setState(() {
          _avatarBytes = bytes;
        });
        qfToast(context, '头像已经更新');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, '头像保存失败：${e.message}');
    }
  }

  Future<void> _save() async {
    final nickname = _nickname.text.trim();
    if (nickname == _loadedNickname) {
      if (mounted) qfToast(context, '没有需要保存的修改');
      return;
    }
    try {
      await widget.session.socialUpdateProfile({'nickname': nickname});
      _loadedNickname = nickname;
      try {
        await QfSignalManager.ensureInstalled(widget.session);
      } catch (_) {}
      if (mounted) qfToast(context, '昵称已经保存');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, '昵称保存失败：${e.message}');
    }
  }

  Future<String?> _askPassword(String title, {String? note}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note != null) ...[Text(note), const SizedBox(height: 12)],
              TextField(
                controller: controller,
                obscureText: true,
                decoration: const InputDecoration(labelText: '账号密码'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askBackupPassword() async {
    final first = TextEditingController();
    final second = TextEditingController();
    var error = '';
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (stateContext, setDialogState) {
            return AlertDialog(
              title: const Text('备份聊天密钥'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('备份口令必须与账户密码一致，输错将无法恢复。'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: first,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '账号密码'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: second,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '再次输入账号密码'),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(stateContext).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    if (first.text.isEmpty) {
                      setDialogState(() => error = '请输入账号密码');
                      return;
                    }
                    if (first.text != second.text) {
                      setDialogState(() => error = '两次输入的密码不一致，请重新输入');
                      return;
                    }
                    Navigator.of(dialogContext).pop(first.text);
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
    first.dispose();
    second.dispose();
    return result;
  }

  Future<void> _backupKey() async {
    final password = await _askBackupPassword();
    if (password == null || password.isEmpty) return;
    try {
      await QfSignalManager.ensureInstalled(widget.session);
      final backup = await QfSignalManager.buildBackup(password);
      final transport = base64Encode(utf8.encode(jsonEncode(backup)));
      await widget.session.socialPutKeyBackup(transport);
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
    final password = await _askPassword(
      '恢复聊天密钥',
      note: '备份由您的账户密码加密，通行密钥无法解密，请输入账户密码。',
    );
    if (password == null || password.isEmpty) return;
    try {
      final data = await widget.session.socialGetKeyBackup();
      final backupRaw = data['backup'];
      if (backupRaw is! String || backupRaw.isEmpty) {
        if (mounted) qfToast(context, '服务器上暂无密钥备份');
        return;
      }
      Map<String, dynamic> backup;
      try {
        final decoded = jsonDecode(utf8.decode(base64Decode(backupRaw)));
        if (decoded is! Map) throw const FormatException('bad-backup');
        backup = Map<String, dynamic>.from(decoded);
      } catch (_) {
        if (mounted) qfToast(context, '恢复失败：备份数据已损坏');
        return;
      }
      final ok = await QfSignalManager.restoreBackup(backup, password);
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
                      if (_avatarBytes != null)
                        CircleAvatar(
                          radius: 40,
                          backgroundImage: MemoryImage(_avatarBytes!),
                        )
                      else
                        _qfLetterAvatar(_nickname.text, 40),
                      TextButton(
                        onPressed: _pickAvatar,
                        child: const Text('更换头像'),
                      ),
                      const Text('头像将单独保存，大小不超过 200KB'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nickname,
                  decoration: const InputDecoration(labelText: '昵称'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _save, child: const Text('保存昵称')),
                const SizedBox(height: 24),
                Text('聊天密钥（端到端加密）', style: AppTextStyle.headline.of(context)),
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
                const SizedBox(height: 24),
                Text('聊天记录保险库', style: AppTextStyle.headline.of(context)),
                const SizedBox(height: 8),
                Text(
                  _historyUnlocked
                      ? '已解锁。云端归档 $_historyCloudEntries 条（上限 20,000 条 / 64 MB），本机归档 $_historyLocalCount 条。'
                      : '尚未解锁。输入账户密码解锁后，将自动恢复历史消息，并同步本机新消息。',
                ),
                if (_historyUnlocked &&
                    _historyCloudEntries == 0 &&
                    _historyLocalCount == 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('暂无可恢复的聊天记录。'),
                  ),
                if (QfChatHistoryVault.isNearCapacity(
                  _historyCloudEntries,
                  _historyCloudBytes,
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '云端聊天记录归档已接近容量上限，请清理较早的会话后重试。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _historyBusy ? null : _unlockHistory,
                      child: const Text('解锁并同步'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _historyBusy ? null : _clearHistoryCloud,
                      child: const Text('清除云端聊天记录'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '恢复内容包括历史消息与身份密钥；实时会话将在新设备上重新建立加密连接，不会迁移原会话的加密状态。'
                  '云端仅保存加密后的聊天记录，忘记账户密码后将无法恢复。',
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
  List<dynamic> _incoming = const [];
  List<dynamic> _outgoing = const [];
  List<dynamic> _results = const [];
  bool _loading = true;
  bool _supportDeskVisible = false;
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
      List<dynamic> incoming = const [];
      List<dynamic> outgoing = const [];
      try {
        final requests = await widget.session.socialFriendRequests();
        final inRaw = requests['incoming'];
        final outRaw = requests['outgoing'];
        incoming = inRaw is List ? inRaw : const [];
        outgoing = outRaw is List ? outRaw : const [];
      } catch (_) {}
      final deskVisible = await qfSupportDeskVisible(widget.session);
      if (mounted) {
        setState(() {
          final friends = data['friends'];
          _friends = qfSupportWithBotEntry(
            friends is List ? friends : const [],
            loggedIn: widget.session.isLoggedIn,
          );
          _supportDeskVisible = deskVisible;
          _incoming = incoming;
          _outgoing = outgoing;
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
    final nickname = (profile['nickname'] ?? '').toString();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QfAvatarImage(
                session: widget.session,
                userId: userId,
                name: nickname,
                hasAvatar: profile['hasAvatar'] == true,
                radius: 36,
              ),
              const SizedBox(height: 12),
              Text(nickname, style: AppTextStyle.headline.of(context)),
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

  Future<void> _confirmDelete(Map<dynamic, dynamic> raw) async {
    final userId = (raw['userId'] as num?)?.toInt();
    if (userId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除好友'),
          content: const Text('删除后聊天记录将保留，对方不会收到通知；云端归档删除仅移除您自己的副本，对方的记录不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await _act(() => widget.session.socialFriendDelete(userId), '好友已经删除');
  }

  Widget _userTile(
    Map<dynamic, dynamic> raw, {
    Widget? trailing,
    VoidCallback? onTap,
    String? subtitle,
  }) {
    final nickname = (raw['nickname'] ?? '').toString();
    return ListTile(
      leading: QfAvatarImage(
        session: widget.session,
        userId: (raw['userId'] as num?)?.toInt(),
        name: nickname,
        hasAvatar: raw['hasAvatar'] == true,
      ),
      title: Text(nickname),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    );
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
                    _userTile(
                      raw,
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
                if (_incoming.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('待处理申请', style: AppTextStyle.headline.of(context)),
                  for (final raw in _incoming)
                    if (raw is Map && raw['user'] is Map)
                      _userTile(
                        Map<dynamic, dynamic>.from(raw['user'] as Map),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => _act(
                                () => widget.session.socialFriendAccept(
                                  (raw['id'] as num).toInt(),
                                ),
                                '已添加为好友',
                              ),
                              child: const Text('同意'),
                            ),
                            TextButton(
                              onPressed: () => _act(
                                () => widget.session.socialFriendReject(
                                  (raw['id'] as num).toInt(),
                                ),
                                '已拒绝该申请',
                              ),
                              child: const Text('拒绝'),
                            ),
                          ],
                        ),
                      ),
                ],
                if (_outgoing.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('已发出的申请', style: AppTextStyle.headline.of(context)),
                  for (final raw in _outgoing)
                    if (raw is Map && raw['user'] is Map)
                      _userTile(
                        Map<dynamic, dynamic>.from(raw['user'] as Map),
                        trailing: const Text('等待对方处理'),
                      ),
                ],
                if (_supportDeskVisible) ...[
                  const SizedBox(height: 16),
                  QfSupportDeskTile(session: widget.session),
                ],
                for (final raw in _friends)
                  if (raw is Map && qfSupportIsBotEntry(raw))
                    QfSupportContactTile(session: widget.session, entry: raw),
                const SizedBox(height: 16),
                Text('我的好友', style: AppTextStyle.headline.of(context)),
                if (_friends
                    .where((raw) => !(raw is Map && qfSupportIsBotEntry(raw)))
                    .isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无好友，可通过上方搜索添加'),
                  ),
                for (final raw in _friends)
                  if (raw is Map && !qfSupportIsBotEntry(raw))
                    _userTile(
                      raw,
                      subtitle: raw['username'] != null
                          ? '账户 ID：${raw['username']} · 点击进入聊天'
                          : '点击进入聊天',
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
                            onPressed: () => _confirmDelete(raw),
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
                QfAvatarImage(
                  session: session,
                  userId: _peerId,
                  name: nickname,
                  hasAvatar: friend['hasAvatar'] == true,
                  radius: 40,
                ),
                const SizedBox(height: 12),
                Text(nickname, style: AppTextStyle.headline.of(context)),
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
  bool _historySyncing = false;
  String? _vaultNotice;
  List<dynamic> _recoveryRequests = const [];
  bool _recoveryBusy = false;

  int get _peerId => (widget.friend['userId'] as num).toInt();

  String get _peerName => (widget.friend['nickname'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_syncHistoryOnOpen());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  Future<void> _syncHistoryOnOpen() async {
    if (!QfChatHistoryVault.historyUnlocked || !widget.session.isLoggedIn) {
      return;
    }
    try {
      final restored = await QfChatHistoryVault.pullIncremental(widget.session);
      if (restored > 0) await _load();
      await _pushHistoryQuietly();
    } catch (_) {}
  }

  Future<void> _pushHistoryQuietly() async {
    if (_historySyncing || !QfChatHistoryVault.historyUnlocked) return;
    _historySyncing = true;
    try {
      await QfChatHistoryVault.pushPending(widget.session);
    } on QfApiException catch (e) {
      if (e.code == 'HISTORY_CAPACITY_EXCEEDED' && mounted) {
        setState(() => _vaultNotice = '云端聊天记录归档已达容量上限，请清理较早的会话后重试。');
      }
    } catch (_) {
    } finally {
      _historySyncing = false;
    }
    try {
      final status = await QfChatHistoryVault.status();
      if (mounted &&
          QfChatHistoryVault.isNearCapacity(
            status.totalEntries,
            status.totalBytes,
          )) {
        setState(() => _vaultNotice = '云端聊天记录归档已接近容量上限，请清理较早的会话后重试。');
      }
    } catch (_) {}
  }

  Future<void> _confirmDeleteConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除会话'),
          content: const Text(
            '删除后将同步删除您在本机与云端归档中的此会话记录，您的其他设备联网后将同步删除；对方的记录不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final result = await QfChatHistoryVault.deleteConversation(
      widget.session,
      _peerId,
    );
    if (!mounted) return;
    setState(() => _messages.clear());
    switch (result) {
      case QfHistoryDeleteResult.synced:
        qfToast(context, '会话已经删除，云端归档已同步删除。');
      case QfHistoryDeleteResult.localOnly:
        qfToast(context, '会话已在本机删除。解锁聊天记录保险库后将同步删除云端归档。');
      case QfHistoryDeleteResult.pendingRetry:
        qfToast(context, '会话已在本机删除，但云端归档同步失败，请稍后重试。');
    }
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

  Future<void> _cacheSent(String key, String text) async {
    final cache = await _sentCache();
    cache[key] = text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qf_chat_sent_$_peerId', jsonEncode(cache));
  }

  Future<void> _loadRecoveryRequests() async {
    try {
      final requests = await widget.session.recoveryFriendRequests();
      if (mounted) {
        setState(() {
          _recoveryRequests = requests
              .where(
                (raw) =>
                    raw is Map &&
                    (raw['applicantUserId'] as num?)?.toInt() == _peerId,
              )
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _verifyRecoveryRequest(Map<dynamic, dynamic> request) async {
    final account = (request['applicantAccount'] ?? '').toString();
    final code = (request['code'] ?? '').toString();
    if (account.isEmpty || code.isEmpty) return;
    setState(() => _recoveryBusy = true);
    try {
      final data = await widget.session.recoveryFriendVerify(account, code);
      if (mounted) {
        qfToast(context, (data['message'] ?? '验证已完成，感谢您的协助。').toString());
      }
      await _loadRecoveryRequests();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
      await _loadRecoveryRequests();
    } finally {
      if (mounted) setState(() => _recoveryBusy = false);
    }
  }

  Future<void> _load() async {
    unawaited(_loadRecoveryRequests());
    try {
      final history = await widget.session.socialChatHistory(_peerId);
      final myId = widget.session.userId;
      final sentCache = await _sentCache();
      final decoded = <Map<String, dynamic>>[];
      int? lastIncomingId;
      for (final raw in history) {
        if (raw is! Map) continue;
        final mine = raw['mine'] == true || raw['from'] == myId;
        var text = '无法解密的消息';
        if (mine) {
          text =
              sentCache['${raw['msgId']}'] ??
              sentCache['${raw['id']}'] ??
              '已加密发送的消息';
        } else {
          final rawId = (raw['id'] as num?)?.toInt();
          if (rawId != null) lastIncomingId = rawId;
          try {
            text = await QfSignalManager.decryptFrom(
              widget.session,
              _peerId,
              (raw['ciphertext'] ?? '').toString(),
            );
          } catch (_) {}
        }
        final ts = _qfTsMillis(raw['createdAt']);
        final msgIdRaw = (raw['msgId'] ?? '').toString();
        final localId = msgIdRaw.isNotEmpty
            ? 'm-$msgIdRaw'
            : raw['id'] != null
            ? 'r-${raw['id']}'
            : 'c-$_peerId-$ts-${text.hashCode}';
        decoded.add({
          'mine': mine,
          'text': text,
          'createdAt': raw['createdAt'],
          'ts': ts,
          'localId': localId,
        });
        await QfChatHistoryVault.archiveMessage(
          QfHistoryRecord(
            localId: localId,
            peerId: _peerId,
            mine: mine,
            text: text,
            ts: ts,
          ),
        );
      }
      if (lastIncomingId != null) {
        try {
          await widget.session.socialChatRead(_peerId, upToId: lastIncomingId);
        } catch (_) {}
      }
      final restored = await QfChatHistoryVault.localRecordsFor(_peerId);
      final known = decoded.map((item) => item['localId']).toSet();
      for (final record in restored) {
        if (known.contains(record.localId)) continue;
        decoded.add({
          'mine': record.mine,
          'text': record.text,
          'createdAt': record.ts,
          'ts': record.ts,
          'localId': record.localId,
        });
      }
      decoded.sort(
        (a, b) => ((a['ts'] as int?) ?? 0).compareTo((b['ts'] as int?) ?? 0),
      );
      if (mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(decoded);
          _loading = false;
        });
      }
      unawaited(_pushHistoryQuietly());
    } catch (_) {
      try {
        final restored = await QfChatHistoryVault.localRecordsFor(_peerId);
        if (mounted && restored.isNotEmpty && _messages.isEmpty) {
          setState(() {
            _messages.addAll([
              for (final record in restored)
                {
                  'mine': record.mine,
                  'text': record.text,
                  'createdAt': record.ts,
                  'ts': record.ts,
                  'localId': record.localId,
                },
            ]);
          });
        }
      } catch (_) {}
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
      final msgId =
          'qf-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(4294967296)}';
      final result = await widget.session.socialChatSend(
        _peerId,
        msgId: msgId,
        ciphertext: sealed.ciphertext,
        nonce: sealed.nonce,
      );
      await _cacheSent((result['msgId'] ?? msgId).toString(), text);
      final serverId = result['id'];
      if (serverId != null) await _cacheSent('$serverId', text);
      await QfChatHistoryVault.archiveMessage(
        QfHistoryRecord(
          localId: 'm-${(result['msgId'] ?? msgId).toString()}',
          peerId: _peerId,
          mine: true,
          text: text,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      unawaited(_pushHistoryQuietly());
      _input.clear();
      await _load();
    } on StateError {
      if (mounted) qfToast(context, '对方尚未启用聊天加密，暂时无法发送消息。');
    } on QfApiException catch (e) {
      if (mounted) {
        if (e.code == 'PREKEY_BUNDLE_NOT_FOUND') {
          qfToast(context, '对方尚未启用聊天加密，暂时无法发送消息。');
        } else {
          qfToast(context, '发送失败：网络或接口错误，请检查网络后重试。');
        }
      }
    } catch (_) {
      if (mounted) qfToast(context, '发送失败：网络或接口错误，请检查网络后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            QfAvatarImage(
              session: widget.session,
              userId: _peerId,
              name: _peerName,
              hasAvatar: widget.friend['hasAvatar'] == true,
              radius: 16,
            ),
            const SizedBox(width: 8),
            Text(_peerName),
          ],
        ),
        actions: [
          IconButton(
            icon: const GlyphIcon(AppGlyphs.delete),
            tooltip: '删除会话',
            onPressed: _confirmDeleteConversation,
          ),
        ],
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
          if (_vaultNotice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _vaultNotice!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final raw in _recoveryRequests)
            if (raw is Map)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            QfAvatarImage(
                              session: widget.session,
                              userId: _peerId,
                              name: _peerName,
                              hasAvatar: widget.friend['hasAvatar'] == true,
                              radius: 14,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${raw['applicantAccount'] ?? _peerName}',
                              style: AppTextStyle.body.of(
                                context,
                                emphasized: true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text((raw['cardText'] ?? '').toString()),
                        const SizedBox(height: 8),
                        Text(
                          '验证数字：${raw['code'] ?? ''}',
                          style: AppTextStyle.headline.of(context),
                        ),
                        if (qfFormatEpochSeconds(raw['expiresAt']).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '有效期至：${qfFormatEpochSeconds(raw['expiresAt'])}',
                              style: AppTextStyle.caption1.of(context),
                            ),
                          ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _recoveryBusy
                              ? null
                              : () => _verifyRecoveryRequest(raw),
                          child: const Text('提交验证'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('暂无聊天记录。'),
                          const SizedBox(height: 8),
                          Text(
                            '如已在其他设备备份，可在个人资料中解锁聊天记录保险库后恢复历史消息。',
                            style: AppTextStyle.caption1.of(context),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final mine = message['mine'] == true;
                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: mine
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
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
