import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qf_api.dart';
import 'qf_chat_media.dart';
import 'qf_config.dart';
import 'qf_qr.dart';
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

  Future<Map<String, dynamic>> socialFriendReject(
    int requestId, {
    bool neverAgain = false,
  }) async {
    return authed(
      'POST',
      '/friends/request/$requestId/reject',
      body: {if (neverAgain) 'neverAgain': true},
    );
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
    String? blobId,
  }) async {
    return authed(
      'POST',
      '/chat/send',
      body: qfChatSendBody(
        toUserId,
        msgId: msgId,
        ciphertext: ciphertext,
        nonce: nonce,
        blobId: blobId,
      ),
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

Map<int, int> qfUnreadByUser(List<dynamic> conversations) {
  final result = <int, int>{};
  for (final raw in conversations) {
    if (raw is! Map) continue;
    final user = raw['user'];
    final userId = user is Map
        ? (user['userId'] as num?)?.toInt()
        : (raw['userId'] as num?)?.toInt();
    final unread = (raw['unreadCount'] as num?)?.toInt() ?? 0;
    if (userId != null && unread > 0) result[userId] = unread;
  }
  return result;
}

Map<String, dynamic> qfChatSendBody(
  int toUserId, {
  required String msgId,
  required String ciphertext,
  required String nonce,
  String? blobId,
}) {
  return {
    'to': toUserId,
    'msgId': msgId,
    'ciphertext': ciphertext,
    'nonce': nonce,
    'blobId': ?blobId,
  };
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
final Map<String, Uint8List?> _qfAvatarStampedCache = {};
final Map<int, dynamic> _qfLatestAvatarStamp = {};

const int qfAvatarMaxBytes = 200 * 1024;

String qfAvatarCacheKey(int userId, dynamic avatarUpdatedAt) {
  return '$userId@${avatarUpdatedAt ?? ''}';
}

/// 进程内已知最新头像戳：展示侧以它为准，避免旧戳挡住新头像。
dynamic qfEffectiveAvatarStamp(int userId, dynamic avatarUpdatedAt) {
  final latest = _qfLatestAvatarStamp[userId];
  if (latest == null) return avatarUpdatedAt;
  if (avatarUpdatedAt == null) return latest;
  return _qfTsMillis(avatarUpdatedAt) > _qfTsMillis(latest)
      ? avatarUpdatedAt
      : latest;
}

void qfSetCachedAvatar(int userId, Uint8List bytes) {
  _qfAvatarCache[userId] = bytes;
}

Uint8List? qfCachedAvatar(int userId, dynamic avatarUpdatedAt) {
  final latest = _qfLatestAvatarStamp[userId];
  if (latest != null) {
    final stamped = _qfAvatarStampedCache[qfAvatarCacheKey(userId, latest)];
    if (stamped != null) return stamped;
  }
  if (avatarUpdatedAt != null) {
    return _qfAvatarStampedCache[qfAvatarCacheKey(userId, avatarUpdatedAt)];
  }
  return _qfAvatarCache[userId];
}

void qfStoreCachedAvatar(
  int userId,
  dynamic avatarUpdatedAt,
  Uint8List? bytes,
) {
  if (avatarUpdatedAt != null) {
    _qfAvatarStampedCache[qfAvatarCacheKey(userId, avatarUpdatedAt)] = bytes;
    final latest = _qfLatestAvatarStamp[userId];
    if (latest == null ||
        _qfTsMillis(avatarUpdatedAt) > _qfTsMillis(latest)) {
      _qfLatestAvatarStamp[userId] = avatarUpdatedAt;
    }
  } else {
    _qfAvatarCache[userId] = bytes;
  }
}

/// 上传落地：以回执新戳写入并淘汰旧戳条目，各展示面下次构建即见新头像。
void qfApplyUploadedAvatar(int userId, dynamic newStamp, Uint8List bytes) {
  final stamp = newStamp ?? 'u${DateTime.now().millisecondsSinceEpoch}';
  _qfAvatarCache[userId] = bytes;
  _qfLatestAvatarStamp[userId] = stamp;
  _qfAvatarStampedCache.removeWhere((key, _) => key.startsWith('$userId@'));
  _qfAvatarStampedCache[qfAvatarCacheKey(userId, stamp)] = bytes;
}

Future<({Uint8List bytes, bool compressed})> qfCompressAvatarBytes(
  Uint8List bytes, {
  int maxBytes = qfAvatarMaxBytes,
  bool force = false,
}) async {
  if (!force && bytes.length <= maxBytes) {
    return (bytes: bytes, compressed: false);
  }
  for (final size in [512, 384, 256, 192, 128]) {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: size,
        targetHeight: size,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) break;
      final out = data.buffer.asUint8List();
      if (out.length <= maxBytes) return (bytes: out, compressed: true);
    } catch (_) {
      break;
    }
  }
  return (bytes: bytes, compressed: false);
}

const Set<String> qfAvatarMimeWhitelist = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
};

/// mime 归一化：只认服务端白名单，其次按扩展名推断，推不出返回空串。
String qfAvatarMimeFor(String fileName, String? declared) {
  var mime = (declared ?? '').trim().toLowerCase();
  if (mime == 'image/jpg') mime = 'image/jpeg';
  if (qfAvatarMimeWhitelist.contains(mime)) return mime;
  final name = fileName.toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.gif')) return 'image/gif';
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
  return '';
}

Future<Uint8List?> qfPickAndUploadAvatar(QfSessionController session) async {
  final picker = ImagePicker();
  final file = await picker.pickImage(
    source: ImageSource.gallery,
    maxWidth: 512,
    maxHeight: 512,
    imageQuality: 85,
  );
  if (file == null) return null;
  final rawBytes = await file.readAsBytes();
  var mime = qfAvatarMimeFor(file.name, file.mimeType);
  final result = await qfCompressAvatarBytes(rawBytes, force: mime.isEmpty);
  final bytes = result.bytes;
  if (bytes.length > qfAvatarMaxBytes) {
    throw const QfApiException(
      0,
      'AVATAR_TOO_LARGE',
      '头像图片过大，已尝试压缩仍超过 200KB，请选择较小的图片',
    );
  }
  if (result.compressed) mime = 'image/png';
  if (mime.isEmpty) mime = 'image/jpeg';
  final response = await session.socialUpdateProfile({
    'avatar': {'mime': mime, 'dataBase64': base64Encode(bytes)},
  });
  final userId = session.userId;
  if (userId != null) {
    dynamic stamp = response['avatarUpdatedAt'];
    final profile = response['profile'];
    if (stamp == null && profile is Map) stamp = profile['avatarUpdatedAt'];
    qfApplyUploadedAvatar(userId, stamp, bytes);
  }
  return bytes;
}

class QfMyAvatarButton extends StatefulWidget {
  final QfSessionController session;
  final String name;
  final double radius;

  const QfMyAvatarButton({
    super.key,
    required this.session,
    required this.name,
    this.radius = 28,
  });

  @override
  State<QfMyAvatarButton> createState() => _QfMyAvatarButtonState();
}

class _QfMyAvatarButtonState extends State<QfMyAvatarButton> {
  bool _busy = false;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await qfPickAndUploadAvatar(widget.session);
      if (bytes != null && mounted) {
        setState(() {});
        qfToast(context, '头像已经更新');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } catch (_) {
      if (mounted) qfToast(context, QfCopy.avatarUpdateFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.session.userId;
    final cached = userId == null ? null : _qfAvatarCache[userId];
    return GestureDetector(
      onTap: _pick,
      child: cached != null && cached.isNotEmpty
          ? CircleAvatar(
              radius: widget.radius,
              backgroundImage: MemoryImage(cached),
            )
          : QfAvatarImage(
              session: widget.session,
              userId: userId,
              name: widget.name,
              radius: widget.radius,
            ),
    );
  }
}

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
  final dynamic avatarUpdatedAt;

  const QfAvatarImage({
    super.key,
    required this.session,
    required this.userId,
    required this.name,
    this.hasAvatar,
    this.radius = 20,
    this.avatarUpdatedAt,
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
    if (oldWidget.userId != widget.userId ||
        oldWidget.avatarUpdatedAt != widget.avatarUpdatedAt) {
      _bytes = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final userId = widget.userId;
    if (userId == null || widget.hasAvatar == false) return;
    final stamp = qfEffectiveAvatarStamp(userId, widget.avatarUpdatedAt);
    if (stamp != null &&
        _qfAvatarStampedCache.containsKey(qfAvatarCacheKey(userId, stamp))) {
      _bytes = _qfAvatarStampedCache[qfAvatarCacheKey(userId, stamp)];
      return;
    }
    if (stamp == null && _qfAvatarCache.containsKey(userId)) {
      _bytes = _qfAvatarCache[userId];
      return;
    }
    final bytes = await widget.session.socialAvatarBytes(userId);
    qfStoreCachedAvatar(userId, stamp, bytes);
    if (mounted && bytes != null) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.userId;
    final bytes =
        (userId == null
            ? null
            : qfCachedAvatar(userId, widget.avatarUpdatedAt)) ??
        _bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundImage: MemoryImage(bytes),
      );
    }
    return _qfLetterAvatar(widget.name, widget.radius);
  }
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
    try {
      final bytes = await qfPickAndUploadAvatar(widget.session);
      if (bytes == null) return;
      if (mounted) {
        setState(() {
          _avatarBytes = bytes;
        });
        qfToast(context, '头像已经更新');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, '头像保存失败：${e.message}');
    } catch (_) {
      if (mounted) qfToast(context, QfCopy.avatarUpdateFailed);
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
                      GestureDetector(
                        onTap: _pickAvatar,
                        child: _avatarBytes != null
                            ? CircleAvatar(
                                radius: 40,
                                backgroundImage: MemoryImage(_avatarBytes!),
                              )
                            : _qfLetterAvatar(_nickname.text, 40),
                      ),
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
                const SizedBox(height: 24),
                ListTile(
                  leading: const GlyphIcon(AppGlyphs.add),
                  title: const Text(QfCopy.attachmentsTitle),
                  subtitle: const Text('查看与删除您发送过的聊天附件'),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            QfAttachmentsPage(session: widget.session),
                      ),
                    );
                  },
                ),
              ],
            ),
    );
  }
}

class QfAttachmentsPage extends StatefulWidget {
  final QfSessionController session;

  const QfAttachmentsPage({super.key, required this.session});

  @override
  State<QfAttachmentsPage> createState() => _QfAttachmentsPageState();
}

class _QfAttachmentsPageState extends State<QfAttachmentsPage> {
  List<dynamic> _blobs = const [];
  int _total = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    try {
      final data = await widget.session.chatBlobs(
        offset: more ? _blobs.length : 0,
      );
      final blobs = data['blobs'];
      if (mounted) {
        setState(() {
          final list = blobs is List ? blobs : const <dynamic>[];
          _blobs = more ? [..._blobs, ...list] : list;
          _total = (data['total'] as num?)?.toInt() ?? _blobs.length;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete(Map<dynamic, dynamic> blob) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除附件'),
          content: const Text(QfCopy.attachmentsDeleteHint),
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
    try {
      await widget.session.chatDeleteBlob((blob['blobId'] ?? '').toString());
      if (mounted) qfToast(context, '附件已删除，7 天后将彻底清除。');
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(QfCopy.attachmentsTitle)),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : _blobs.isEmpty
          ? const Center(child: Text(QfCopy.attachmentsEmpty))
          : ListView.separated(
              itemCount: _blobs.length + (_blobs.length < _total ? 1 : 0),
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == _blobs.length) {
                  return TextButton(
                    onPressed: () => _load(more: true),
                    child: const Text('加载更多'),
                  );
                }
                final raw = _blobs[index];
                if (raw is! Map) return const SizedBox.shrink();
                final size = (raw['sizeBytes'] as num?)?.toInt() ?? 0;
                final created = qfFormatEpochSeconds(raw['createdAt']);
                final recipient = raw['recipientUserId'];
                final deleteAfter = raw['deleteAfter'];
                return ListTile(
                  title: Text(_qfFormatBytes(size)),
                  subtitle: Text(
                    '${created.isEmpty ? '' : '$created · '}'
                    '接收人：${recipient ?? '—'} · '
                    '${raw['downloaded'] == true ? '对方已下载' : '对方未下载'}'
                    '${deleteAfter != null ? '\n已删除，7 天待删期内将彻底清除' : ''}',
                  ),
                  trailing: deleteAfter != null
                      ? null
                      : TextButton(
                          onPressed: () => _delete(raw),
                          child: const Text('删除'),
                        ),
                );
              },
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
  Map<int, int> _unread = const {};
  Timer? _pollTimer;
  bool _loading = true;
  bool _supportDeskVisible = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(QfSignalManager.ensureInstalledQuietly(widget.session));
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
      var unread = _unread;
      try {
        unread = qfUnreadByUser(await widget.session.socialChatConversations());
      } catch (_) {}
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
          _unread = unread;
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
                avatarUpdatedAt: profile['avatarUpdatedAt'],
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

  Future<void> _rejectRequest(Map<dynamic, dynamic> raw) async {
    final requestId = (raw['id'] as num?)?.toInt();
    if (requestId == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('拒绝好友申请'),
          content: const Text(
            '拒绝后，对方一段时间内不能再次向您发送申请；选择「拒绝且不再接收」后，对方将无法再向您发送申请。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('never'),
              child: const Text('拒绝且不再接收'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('reject'),
              child: const Text('拒绝'),
            ),
          ],
        );
      },
    );
    if (choice == null) return;
    await _act(
      () => widget.session.socialFriendReject(
        requestId,
        neverAgain: choice == 'never',
      ),
      choice == 'never' ? '已拒绝，并不再接收对方的申请' : '已拒绝该申请',
    );
  }

  Widget _userTile(
    Map<dynamic, dynamic> raw, {
    Widget? trailing,
    VoidCallback? onTap,
    String? subtitle,
    int unread = 0,
  }) {
    final nickname = (raw['nickname'] ?? '').toString();
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          QfAvatarImage(
            session: widget.session,
            userId: (raw['userId'] as num?)?.toInt(),
            name: nickname,
            hasAvatar: raw['hasAvatar'] == true,
            avatarUpdatedAt: raw['avatarUpdatedAt'],
          ),
          if (unread > 0)
            Positioned(
              right: -6,
              top: -6,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: Theme.of(context).colorScheme.error,
                  shape: AppShape.full,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: Theme.of(context).colorScheme.onError),
                  ),
                ),
              ),
            ),
        ],
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
                              onPressed: () => _rejectRequest(raw),
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
                      unread: _unread[(raw['userId'] as num?)?.toInt()] ?? 0,
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
    String? value;
    if (qfCameraScanSupported()) {
      try {
        final capture = await MobileScannerPlatform.instance.analyzeImage(
          file.path,
          formats: const [BarcodeFormat.qrCode],
        );
        value = capture?.barcodes
            .map((barcode) => barcode.rawValue)
            .whereType<String>()
            .firstOrNull;
      } catch (_) {
        value = null;
      }
    }
    // Platforms without a scanner implementation (Windows) decode the
    // picked image in pure Dart instead.
    value ??= qfDecodeQrImageBytes(await file.readAsBytes());
    if (value == null) {
      if (mounted) qfToast(context, QfCopy.qrNoCodeFound);
      return;
    }
    _handle(value);
  }

  @override
  Widget build(BuildContext context) {
    final cameraSupported = qfCameraScanSupported();
    return Scaffold(
      appBar: AppBar(title: const Text('扫一扫')),
      body: Column(
        children: [
          Expanded(
            child: cameraSupported
                ? MobileScanner(
                    controller: _controller,
                    onDetect: (capture) {
                      final value = capture.barcodes
                          .map((barcode) => barcode.rawValue)
                          .whereType<String>()
                          .firstOrNull;
                      _handle(value);
                    },
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        QfCopy.qrCameraUnsupported,
                        textAlign: TextAlign.center,
                      ),
                    ),
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
                  avatarUpdatedAt: friend['avatarUpdatedAt'],
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

String _qfMimeForFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.txt')) return 'text/plain';
  if (lower.endsWith('.zip')) return 'application/zip';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  return 'application/octet-stream';
}

String _qfFormatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

class _QfChatPageState extends State<QfChatPage> {
  final _input = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final QfReactionMap _reactions = {};
  final Map<String, Uint8List> _attachmentBytes = {};
  Timer? _timer;
  bool _loading = true;
  bool _historySyncing = false;
  bool _sendingAttachment = false;
  String? _vaultNotice;
  List<dynamic> _recoveryRequests = const [];
  bool _recoveryBusy = false;

  int get _peerId => (widget.friend['userId'] as num).toInt();

  String get _peerName => (widget.friend['nickname'] ?? '').toString();

  String get _myKey => '${widget.session.userId ?? 0}';

  String _reactorKey(bool mine) => mine ? _myKey : '$_peerId';

  @override
  void initState() {
    super.initState();
    unawaited(QfSignalManager.ensureInstalledQuietly(widget.session));
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
      final reactions = <String, Map<String, String>>{};
      int? lastIncomingId;
      for (final raw in history) {
        if (raw is! Map) continue;
        final mine = raw['mine'] == true || raw['from'] == myId;
        var text = '无法解密的消息';
        var decryptFailed = false;
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
          } catch (_) {
            decryptFailed = true;
          }
        }
        final ts = _qfTsMillis(raw['createdAt']);
        final msgIdRaw = (raw['msgId'] ?? '').toString();
        final localId = msgIdRaw.isNotEmpty
            ? 'm-$msgIdRaw'
            : raw['id'] != null
            ? 'r-${raw['id']}'
            : 'c-$_peerId-$ts-${text.hashCode}';
        final payload = QfChatPayload.parse(text);
        if (payload.kind == QfChatPayloadKind.reaction) {
          QfReactions.apply(
            reactions,
            targetLocalId: payload.reactionTargetLocalId ?? '',
            reactorKey: _reactorKey(mine),
            emoji: payload.reactionEmoji,
          );
        } else {
          decoded.add({
            'mine': mine,
            'text': payload.displayText,
            'payload': payload,
            'createdAt': raw['createdAt'],
            'ts': ts,
            'localId': localId,
            'decryptFailed': decryptFailed,
            if (mine) 'readAt': raw['readAt'],
          });
        }
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
        final payload = QfChatPayload.parse(record.text);
        if (payload.kind == QfChatPayloadKind.reaction) {
          QfReactions.apply(
            reactions,
            targetLocalId: payload.reactionTargetLocalId ?? '',
            reactorKey: _reactorKey(record.mine),
            emoji: payload.reactionEmoji,
          );
          continue;
        }
        decoded.add({
          'mine': record.mine,
          'text': payload.displayText,
          'payload': payload,
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
          _reactions
            ..clear()
            ..addAll(reactions);
          _loading = false;
        });
      }
      unawaited(_pushHistoryQuietly());
    } catch (_) {
      try {
        final restored = await QfChatHistoryVault.localRecordsFor(_peerId);
        if (mounted && restored.isNotEmpty && _messages.isEmpty) {
          setState(() {
            for (final record in restored) {
              final payload = QfChatPayload.parse(record.text);
              if (payload.kind == QfChatPayloadKind.reaction) {
                QfReactions.apply(
                  _reactions,
                  targetLocalId: payload.reactionTargetLocalId ?? '',
                  reactorKey: _reactorKey(record.mine),
                  emoji: payload.reactionEmoji,
                );
                continue;
              }
              _messages.add({
                'mine': record.mine,
                'text': payload.displayText,
                'payload': payload,
                'createdAt': record.ts,
                'ts': record.ts,
                'localId': record.localId,
              });
            }
          });
        }
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _deliver(String wireText, {String? blobId}) async {
    try {
      await QfSignalManager.ensureInstalled(widget.session);
      final sealed = await QfSignalManager.encryptFor(
        widget.session,
        _peerId,
        wireText,
      );
      final msgId =
          'qf-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(4294967296)}';
      final result = await widget.session.socialChatSend(
        _peerId,
        msgId: msgId,
        ciphertext: sealed.ciphertext,
        nonce: sealed.nonce,
        blobId: blobId,
      );
      await _cacheSent((result['msgId'] ?? msgId).toString(), wireText);
      final serverId = result['id'];
      if (serverId != null) await _cacheSent('$serverId', wireText);
      await QfChatHistoryVault.archiveMessage(
        QfHistoryRecord(
          localId: 'm-${(result['msgId'] ?? msgId).toString()}',
          peerId: _peerId,
          mine: true,
          text: wireText,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      unawaited(_pushHistoryQuietly());
      await _load();
      return true;
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
    return false;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (await _deliver(text)) _input.clear();
  }

  Future<void> _sendSticker(String id) async {
    await _deliver(QfChatPayload.sticker(id).encode());
  }

  Future<void> _sendReaction(String targetLocalId, String tapped) async {
    final previous = _reactions[targetLocalId]?[_myKey];
    final next = QfReactions.nextEmoji(current: previous, tapped: tapped);
    setState(() {
      QfReactions.apply(
        _reactions,
        targetLocalId: targetLocalId,
        reactorKey: _myKey,
        emoji: next,
      );
    });
    final ok = await _deliver(
      QfChatPayload.reaction(targetLocalId, next).encode(),
    );
    if (!ok && mounted) {
      setState(() {
        QfReactions.apply(
          _reactions,
          targetLocalId: targetLocalId,
          reactorKey: _myKey,
          emoji: previous ?? '',
        );
      });
      qfToast(context, '回应发送失败，请稍后重试。');
    }
  }

  Future<void> _pickAndSendAttachment() async {
    if (_sendingAttachment) return;
    final reachable = await QfSignalManager.peerReachable(
      widget.session,
      _peerId,
    );
    if (!reachable) {
      if (mounted) qfToast(context, '对方尚未启用聊天加密，暂时无法发送附件。');
      return;
    }
    final picked = await FilePicker.pickFile();
    if (picked == null) return;
    final Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (_) {
      if (mounted) qfToast(context, '附件读取失败，请重新选择。');
      return;
    }
    if (bytes.length > qfAttachmentMaxBytes) {
      if (mounted) qfToast(context, qfAttachmentTooLargeMessage);
      return;
    }
    setState(() => _sendingAttachment = true);
    try {
      final sealedBlob = QfBlobCrypto.seal(bytes);
      final blobId = await widget.session.chatUploadBlob(
        recipientId: _peerId,
        cipher: sealedBlob.cipher,
        cipherSha256: sealedBlob.cipherSha256,
      );
      final ref = QfAttachmentRef(
        blobId: blobId,
        fileKey: sealedBlob.fileKey,
        nonce: sealedBlob.nonce,
        cipherSha256: sealedBlob.cipherSha256,
        name: picked.name,
        mime: _qfMimeForFileName(picked.name),
        size: bytes.length,
      );
      await _deliver(QfChatPayload.attachment(ref).encode(), blobId: blobId);
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, qfAttachmentErrorMessage(e));
    } catch (_) {
      if (mounted) qfToast(context, '附件发送失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _sendingAttachment = false);
    }
  }

  Future<void> _openAttachment(QfAttachmentRef ref) async {
    try {
      var plain = _attachmentBytes[ref.blobId];
      if (plain == null) {
        final cipher = await widget.session.chatDownloadBlob(ref.blobId);
        if (cipher == null) {
          if (mounted) qfToast(context, '附件下载失败，请稍后重试。');
          return;
        }
        plain = QfBlobCrypto.open(ref, cipher);
        _attachmentBytes[ref.blobId] = plain;
      }
      if (!mounted) return;
      if (ref.isImage) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Text(ref.name),
              content: Image.memory(plain!),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/qf_attachments');
      await folder.create(recursive: true);
      final safeName = ref.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      await File('${folder.path}/$safeName').writeAsBytes(plain);
      if (mounted) qfToast(context, '已保存：${ref.name}');
    } on QfChatMediaException catch (e) {
      if (mounted) qfToast(context, e.message);
    } catch (_) {
      if (mounted) qfToast(context, '附件下载失败，请稍后重试。');
    }
  }

  Future<void> _deleteForEveryone(Map<String, dynamic> message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('删除消息'),
          content: const Text('删除后将同时删除您在本机的记录；如消息包含附件，附件将一并删除。'),
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
    final payload = message['payload'] as QfChatPayload?;
    final ref = payload?.attachment;
    if (ref != null) {
      try {
        await widget.session.chatDeleteBlob(ref.blobId);
      } catch (_) {}
      _attachmentBytes.remove(ref.blobId);
    }
    final localId = (message['localId'] ?? '').toString();
    await QfChatHistoryVault.removeLocalRecord(localId);
    if (mounted) {
      setState(() {
        _messages.removeWhere((item) => item['localId'] == localId);
      });
      qfToast(context, '消息已经删除。');
    }
  }

  void _insertEmoji(String emoji) {
    final value = _input.value;
    final start = value.selection.start < 0
        ? value.text.length
        : value.selection.start;
    final end = value.selection.end < 0
        ? value.text.length
        : value.selection.end;
    final next = value.text.replaceRange(start, end, emoji);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  Future<void> _showEmojiPanel({String? reactionTarget}) async {
    var group = qfUnicodeEmojiGroups.keys.first;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (stateContext, setSheetState) {
            return DefaultTabController(
              length: reactionTarget == null ? 2 : 1,
              child: SizedBox(
                height: 380,
                child: Column(
                  children: [
                    TabBar(
                      tabs: [
                        const Tab(text: '表情'),
                        if (reactionTarget == null) const Tab(text: '表情包'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          Column(
                            children: [
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final name
                                        in qfUnicodeEmojiGroups.keys)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(name),
                                          selected: group == name,
                                          onSelected: (_) {
                                            setSheetState(() => group = name);
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: GridView.builder(
                                  padding: const EdgeInsets.all(8),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 8,
                                      ),
                                  itemCount:
                                      qfUnicodeEmojiGroups[group]!.length,
                                  itemBuilder: (itemContext, index) {
                                    final emoji =
                                        qfUnicodeEmojiGroups[group]![index];
                                    return InkWell(
                                      customBorder: AppShape.md,
                                      onTap: () {
                                        Navigator.of(sheetContext).pop();
                                        if (reactionTarget != null) {
                                          unawaited(
                                            _sendReaction(
                                              reactionTarget,
                                              emoji,
                                            ),
                                          );
                                        } else {
                                          _insertEmoji(emoji);
                                        }
                                      },
                                      child: Center(
                                        child: Text(
                                          emoji,
                                          style: AppTextStyle.custom(
                                            itemContext,
                                            size: 24,
                                            leading: 30,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                          if (reactionTarget == null)
                            GridView.builder(
                              padding: const EdgeInsets.all(8),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 6,
                                  ),
                              itemCount: qfTwemojiStickerIds.length,
                              itemBuilder: (itemContext, index) {
                                final id = qfTwemojiStickerIds[index];
                                return InkWell(
                                  customBorder: AppShape.md,
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    unawaited(_sendSticker(id));
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(6),
                                    child: Image.asset(qfStickerAsset(id)),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showMessageMenu(Map<String, dynamic> message) async {
    final localId = (message['localId'] ?? '').toString();
    final mine = message['mine'] == true;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final emoji in qfQuickReactions)
                      InkWell(
                        customBorder: AppShape.full,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_sendReaction(localId, emoji));
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            emoji,
                            style: AppTextStyle.custom(
                              sheetContext,
                              size: 26,
                              leading: 32,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const GlyphIcon(AppGlyphs.addCircle),
                title: const Text('更多表情回应'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_showEmojiPanel(reactionTarget: localId));
                },
              ),
              if (mine)
                ListTile(
                  leading: const GlyphIcon(AppGlyphs.delete),
                  title: const Text('删除（对所有人）'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_deleteForEveryone(message));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _messageContent(Map<String, dynamic> message) {
    final payload =
        message['payload'] as QfChatPayload? ??
        QfChatPayload.text((message['text'] ?? '').toString());
    switch (payload.kind) {
      case QfChatPayloadKind.sticker:
        return Image.asset(
          qfStickerAsset(payload.stickerId ?? ''),
          width: 96,
          height: 96,
          errorBuilder: (errorContext, error, stack) => const Text('表情'),
        );
      case QfChatPayloadKind.attachment:
        final ref = payload.attachment!;
        return GestureDetector(
          onTap: () => unawaited(_openAttachment(ref)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlyphIcon(ref.isImage ? AppGlyphs.photos : AppGlyphs.add),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ref.name),
                    Text(
                      ref.isImage
                          ? '图片附件（${_qfFormatBytes(ref.size)}），点击查看'
                          : '文件附件（${_qfFormatBytes(ref.size)}），点击保存',
                      style: AppTextStyle.caption1.of(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      case QfChatPayloadKind.text:
      case QfChatPayloadKind.reaction:
        return Text(payload.displayText);
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
              avatarUpdatedAt: widget.friend['avatarUpdatedAt'],
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
                      final localId = (message['localId'] ?? '').toString();
                      final summary = QfReactions.summary(
                        _reactions,
                        localId,
                        _myKey,
                      );
                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: GestureDetector(
                          onLongPress: () =>
                              unawaited(_showMessageMenu(message)),
                          child: Column(
                            crossAxisAlignment: mine
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (message['decryptFailed'] == true)
                                InkWell(
                                  customBorder: AppShape.md,
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => QfProfilePage(
                                          session: widget.session,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: ShapeDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.errorContainer,
                                      shape: AppShape.md,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(QfCopy.chatDecryptFailed),
                                        const SizedBox(width: 8),
                                        Text(
                                          QfCopy.chatRecoverKey,
                                          style: AppTextStyle.body
                                              .of(context, emphasized: true)
                                              .copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              else
                                Container(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: mine
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.primaryContainer
                                        : Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHighest,
                                  ),
                                  child: _messageContent(message),
                                ),
                              if (mine && message.containsKey('readAt'))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    message['readAt'] == null ? '未读' : '已读',
                                    style: AppTextStyle.caption1.of(context),
                                  ),
                                ),
                              if (summary.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Wrap(
                                    spacing: 4,
                                    children: [
                                      for (final item in summary)
                                        DecoratedBox(
                                          decoration: ShapeDecoration(
                                            color: item.mine
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primaryContainer
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                            shape: AppShape.full,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            child: Text(
                                              item.count > 1
                                                  ? '${item.emoji} ${item.count}'
                                                  : item.emoji,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_sendingAttachment)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('附件发送中，请稍候。'),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '表情',
                    onPressed: () => unawaited(_showEmojiPanel()),
                    icon: Text(
                      '😊',
                      style: AppTextStyle.custom(
                        context,
                        size: 22,
                        leading: 28,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '添加附件',
                    onPressed: _sendingAttachment
                        ? null
                        : () => unawaited(_pickAndSendAttachment()),
                    icon: const GlyphIcon(AppGlyphs.add),
                  ),
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
