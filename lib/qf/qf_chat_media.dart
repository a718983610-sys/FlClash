import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'qf_api.dart';
import 'qf_session.dart';
import 'qf_vault.dart';

const int qfAttachmentMaxBytes = 25 * 1024 * 1024;
const String qfAttachmentQuotaMessage = '附件空间已满，请删除部分历史附件后重试。';
const String qfAttachmentTooLargeMessage = '单个文件大小不能超过 25MB。';

class QfChatMediaException implements Exception {
  final String message;

  const QfChatMediaException(this.message);

  @override
  String toString() => message;
}

const String qfAttachmentUnavailableMessage = '附件服务暂不可用，请稍后再试。';

String qfAttachmentErrorMessage(QfApiException e) {
  final code = e.code.toUpperCase();
  if (code == 'BLOB_STORAGE_NOT_CONFIGURED' || e.status == 503) {
    return qfAttachmentUnavailableMessage;
  }
  if (code.contains('QUOTA')) return qfAttachmentQuotaMessage;
  if (code.contains('TOO_LARGE') || code.contains('SIZE') || e.status == 413) {
    return qfAttachmentTooLargeMessage;
  }
  if (e.message.isNotEmpty && e.message != '请求失败，请稍后重试') return e.message;
  return '附件发送失败，请稍后重试。';
}

class QfAttachmentRef {
  final String blobId;
  final String fileKey;
  final String nonce;
  final String cipherSha256;
  final String name;
  final String mime;
  final int size;

  const QfAttachmentRef({
    required this.blobId,
    required this.fileKey,
    required this.nonce,
    required this.cipherSha256,
    required this.name,
    required this.mime,
    required this.size,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': 'attachment',
      'blobId': blobId,
      'fileKey': fileKey,
      'nonce': nonce,
      'cipherSha256': cipherSha256,
      'name': name,
      'mime': mime,
      'size': size,
    };
  }

  static QfAttachmentRef? fromJson(Map<String, dynamic> json) {
    final blobId = (json['blobId'] ?? '').toString();
    final fileKey = (json['fileKey'] ?? '').toString();
    final nonce = (json['nonce'] ?? '').toString();
    if (blobId.isEmpty || fileKey.isEmpty || nonce.isEmpty) return null;
    return QfAttachmentRef(
      blobId: blobId,
      fileKey: fileKey,
      nonce: nonce,
      cipherSha256: (json['cipherSha256'] ?? '').toString(),
      name: (json['name'] ?? '附件').toString(),
      mime: (json['mime'] ?? 'application/octet-stream').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isImage => mime.startsWith('image/');
}

enum QfChatPayloadKind { text, attachment, sticker, reaction }

class QfChatPayload {
  final QfChatPayloadKind kind;
  final String text;
  final QfAttachmentRef? attachment;
  final String? stickerId;
  final String? reactionTargetLocalId;
  final String reactionEmoji;

  const QfChatPayload._({
    required this.kind,
    this.text = '',
    this.attachment,
    this.stickerId,
    this.reactionTargetLocalId,
    this.reactionEmoji = '',
  });

  static const String _prefix = 'qf1:';

  factory QfChatPayload.text(String text) {
    return QfChatPayload._(kind: QfChatPayloadKind.text, text: text);
  }

  factory QfChatPayload.attachment(QfAttachmentRef ref) {
    return QfChatPayload._(kind: QfChatPayloadKind.attachment, attachment: ref);
  }

  factory QfChatPayload.sticker(String id) {
    return QfChatPayload._(kind: QfChatPayloadKind.sticker, stickerId: id);
  }

  factory QfChatPayload.reaction(String targetLocalId, String emoji) {
    return QfChatPayload._(
      kind: QfChatPayloadKind.reaction,
      reactionTargetLocalId: targetLocalId,
      reactionEmoji: emoji,
    );
  }

  String encode() {
    switch (kind) {
      case QfChatPayloadKind.text:
        return text;
      case QfChatPayloadKind.attachment:
        return '$_prefix${jsonEncode(attachment!.toJson())}';
      case QfChatPayloadKind.sticker:
        return '$_prefix${jsonEncode({'type': 'sticker', 'packId': 'twemoji', 'id': stickerId})}';
      case QfChatPayloadKind.reaction:
        return '$_prefix${jsonEncode({'type': 'reaction', 'targetLocalId': reactionTargetLocalId, 'emoji': reactionEmoji})}';
    }
  }

  String get displayText {
    switch (kind) {
      case QfChatPayloadKind.text:
        return text;
      case QfChatPayloadKind.attachment:
        return attachment?.name ?? '附件';
      case QfChatPayloadKind.sticker:
        return '表情';
      case QfChatPayloadKind.reaction:
        return '';
    }
  }

  static QfChatPayload parse(String raw) {
    if (!raw.startsWith(_prefix)) return QfChatPayload.text(raw);
    try {
      final decoded = jsonDecode(raw.substring(_prefix.length));
      if (decoded is! Map) return QfChatPayload.text(raw);
      final json = Map<String, dynamic>.from(decoded);
      switch ((json['type'] ?? '').toString()) {
        case 'attachment':
          final ref = QfAttachmentRef.fromJson(json);
          if (ref == null) return QfChatPayload.text(raw);
          return QfChatPayload.attachment(ref);
        case 'sticker':
          final id = (json['id'] ?? '').toString();
          if (id.isEmpty || json['packId'] != 'twemoji') {
            return QfChatPayload.text(raw);
          }
          return QfChatPayload.sticker(id);
        case 'reaction':
          final target = (json['targetLocalId'] ?? '').toString();
          if (target.isEmpty) return QfChatPayload.text(raw);
          return QfChatPayload.reaction(
            target,
            (json['emoji'] ?? '').toString(),
          );
        default:
          return QfChatPayload.text(raw);
      }
    } catch (_) {
      return QfChatPayload.text(raw);
    }
  }
}

class QfSealedBlob {
  final Uint8List cipher;
  final String fileKey;
  final String nonce;
  final String cipherSha256;

  const QfSealedBlob({
    required this.cipher,
    required this.fileKey,
    required this.nonce,
    required this.cipherSha256,
  });
}

abstract final class QfBlobCrypto {
  static String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

  static QfSealedBlob seal(Uint8List plain) {
    final random = Random.secure();
    Uint8List fresh(int length) => Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
    final key = fresh(32);
    final nonce = fresh(24);
    final cipher = qfXChaCha20Poly1305Encrypt(key, nonce, plain);
    return QfSealedBlob(
      cipher: cipher,
      fileKey: base64Encode(key),
      nonce: base64Encode(nonce),
      cipherSha256: sha256Hex(cipher),
    );
  }

  static Uint8List open(QfAttachmentRef ref, Uint8List cipher) {
    if (sha256Hex(cipher) != ref.cipherSha256) {
      throw const QfChatMediaException('附件校验失败，文件可能已损坏，请联系对方重新发送。');
    }
    try {
      return qfXChaCha20Poly1305Decrypt(
        Uint8List.fromList(base64Decode(ref.fileKey)),
        Uint8List.fromList(base64Decode(ref.nonce)),
        cipher,
      );
    } catch (_) {
      throw const QfChatMediaException('附件解密失败，文件可能已损坏，请联系对方重新发送。');
    }
  }
}

typedef QfReactionMap = Map<String, Map<String, String>>;

abstract final class QfReactions {
  static String nextEmoji({required String? current, required String tapped}) {
    return current == tapped ? '' : tapped;
  }

  static void apply(
    QfReactionMap map, {
    required String targetLocalId,
    required String reactorKey,
    required String emoji,
  }) {
    if (emoji.isEmpty) {
      final inner = map[targetLocalId];
      if (inner == null) return;
      inner.remove(reactorKey);
      if (inner.isEmpty) map.remove(targetLocalId);
      return;
    }
    map.putIfAbsent(targetLocalId, () => <String, String>{})[reactorKey] =
        emoji;
  }

  static List<({String emoji, int count, bool mine})> summary(
    QfReactionMap map,
    String targetLocalId,
    String myKey,
  ) {
    final inner = map[targetLocalId];
    if (inner == null || inner.isEmpty) return const [];
    final counts = <String, int>{};
    final mineSet = <String>{};
    inner.forEach((reactor, emoji) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
      if (reactor == myKey) mineSet.add(emoji);
    });
    return [
      for (final entry in counts.entries)
        (
          emoji: entry.key,
          count: entry.value,
          mine: mineSet.contains(entry.key),
        ),
    ];
  }
}

const List<String> qfQuickReactions = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '🙏',
  '🔥',
  '🎉',
];

const Map<String, List<String>> qfUnicodeEmojiGroups = {
  '笑脸': [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😃',
    '😄',
    '😅',
    '😆',
    '😉',
    '😊',
    '😋',
    '😎',
    '😍',
    '😘',
    '🥰',
    '😗',
    '😙',
    '😚',
    '🙂',
    '🤗',
    '🤩',
    '🤔',
    '🤨',
    '😐',
    '😑',
    '😶',
    '🙄',
    '😏',
    '😣',
    '😥',
    '😮',
    '🤐',
    '😯',
    '😪',
    '😫',
    '🥱',
    '😴',
    '😌',
    '😛',
    '😜',
    '😝',
    '🤤',
    '😒',
    '😓',
    '😔',
    '😕',
    '🙃',
    '🤑',
    '😲',
    '🙁',
    '😖',
    '😞',
    '😟',
    '😤',
    '😢',
    '😭',
    '😦',
    '😧',
    '😨',
    '😩',
    '🤯',
    '😬',
    '😰',
    '😱',
    '🥵',
    '🥶',
    '😳',
    '🤪',
    '😵',
    '🥴',
    '😠',
    '😡',
    '🤬',
    '😷',
    '🤒',
    '🤕',
    '🤢',
    '🤮',
    '🤧',
    '😇',
    '🥳',
    '🥺',
    '🤠',
    '🤡',
    '🤥',
    '🤫',
    '🤭',
    '🧐',
    '🤓',
    '😈',
    '👻',
    '💀',
    '👽',
    '🤖',
    '💩',
  ],
  '手势': [
    '👍',
    '👎',
    '👌',
    '🤏',
    '✌️',
    '🤞',
    '🤟',
    '🤘',
    '🤙',
    '👈',
    '👉',
    '👆',
    '👇',
    '☝️',
    '✋',
    '🤚',
    '🖐️',
    '🖖',
    '👋',
    '💪',
    '🙏',
    '👏',
    '🙌',
    '👐',
    '🤲',
    '🤝',
    '🤜',
    '🤛',
    '✊',
    '👊',
    '🫰',
    '👀',
    '👂',
    '👃',
    '🧠',
  ],
  '爱心符号': [
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🤍',
    '🤎',
    '💔',
    '💕',
    '💞',
    '💓',
    '💗',
    '💖',
    '💘',
    '💝',
    '💟',
    '🔥',
    '✨',
    '⭐',
    '🌟',
    '💫',
    '💥',
    '💢',
    '💦',
    '💨',
    '💤',
    '🎉',
    '🎊',
    '🎁',
    '🏆',
    '🥇',
    '👑',
    '💎',
    '✅',
    '❌',
    '❓',
    '❗',
    '💯',
    '🆗',
    '🆒',
    '🆕',
    '⚠️',
    '🚀',
    '🍀',
  ],
  '动物自然': [
    '🐶',
    '🐱',
    '🐭',
    '🐹',
    '🐰',
    '🦊',
    '🐻',
    '🐼',
    '🐨',
    '🐯',
    '🦁',
    '🐮',
    '🐷',
    '🐸',
    '🐵',
    '🙈',
    '🙉',
    '🙊',
    '🐔',
    '🐧',
    '🐦',
    '🦄',
    '🐴',
    '🐢',
    '🐙',
    '🦋',
    '🐛',
    '🐝',
    '🌸',
    '🌹',
    '🌻',
    '🌞',
    '🌝',
    '🌚',
    '🌈',
    '☀️',
    '🌧️',
    '⛄',
    '🔥',
    '🌊',
    '🍎',
    '🍐',
    '🍊',
    '🍋',
    '🍉',
    '🍇',
    '🍓',
    '🍒',
  ],
  '食物': [
    '🍔',
    '🍟',
    '🍕',
    '🌭',
    '🍿',
    '🍩',
    '🍪',
    '🎂',
    '🍰',
    '🧁',
    '🍫',
    '🍬',
    '🍭',
    '🍮',
    '🍯',
    '🍼',
    '🥛',
    '☕',
    '🍵',
    '🧃',
    '🥤',
    '🍺',
    '🍻',
    '🥂',
    '🍷',
    '🥃',
    '🍸',
    '🍜',
    '🍲',
    '🍛',
    '🍣',
    '🍱',
    '🥟',
    '🍤',
    '🍚',
    '🍙',
    '🥮',
    '🍢',
    '🍡',
    '🍧',
    '🍨',
    '🍦',
    '🥧',
    '🍗',
    '🍖',
    '🌮',
    '🌯',
    '🥗',
  ],
  '活动物品': [
    '⚽',
    '🏀',
    '🏈',
    '⚾',
    '🎾',
    '🏐',
    '🏉',
    '🎱',
    '🏓',
    '🏸',
    '🥅',
    '🏒',
    '🎮',
    '🎲',
    '🎯',
    '🎸',
    '🎺',
    '🎻',
    '🥁',
    '🎤',
    '🎧',
    '🎬',
    '🎨',
    '📚',
    '✏️',
    '📝',
    '💼',
    '📁',
    '📅',
    '📈',
    '💰',
    '💴',
    '💵',
    '💶',
    '💷',
    '💸',
    '🚗',
    '🚕',
    '🚌',
    '🚑',
    '🚒',
    '🚓',
    '🚲',
    '✈️',
    '🚀',
    '🏠',
    '🏢',
    '📱',
  ],
};

const String qfStickerPackId = 'twemoji';

const List<String> qfTwemojiStickerIds = [
  '1f600',
  '1f601',
  '1f602',
  '1f603',
  '1f604',
  '1f605',
  '1f606',
  '1f607',
  '1f609',
  '1f60a',
  '1f60b',
  '1f60d',
  '1f60e',
  '1f60f',
  '1f610',
  '1f611',
  '1f612',
  '1f613',
  '1f614',
  '1f616',
  '1f618',
  '1f61a',
  '1f61c',
  '1f61d',
  '1f61e',
  '1f620',
  '1f621',
  '1f622',
  '1f623',
  '1f624',
  '1f625',
  '1f628',
  '1f629',
  '1f62a',
  '1f62b',
  '1f62d',
  '1f62e',
  '1f631',
  '1f632',
  '1f633',
  '1f634',
  '1f635',
  '1f637',
  '1f641',
  '1f642',
  '1f643',
  '1f644',
  '1f913',
  '1f914',
  '1f917',
  '1f920',
  '1f922',
  '1f923',
  '1f924',
  '1f925',
  '1f927',
  '1f928',
  '1f929',
  '1f92a',
  '1f92b',
  '1f92c',
  '1f92d',
  '1f92e',
  '1f92f',
  '1f970',
  '1f971',
  '1f972',
  '1f973',
  '1f974',
  '1f975',
  '1f976',
  '1f978',
  '1f979',
  '1f97a',
  '1f9d0',
  '1f44d',
  '1f44e',
  '1f44f',
  '1f64f',
  '1f91d',
  '1f91e',
  '1f91f',
  '1f918',
  '1f44b',
  '1f44c',
  '270c',
  '1f596',
  '1f4aa',
  '1f926',
  '1f937',
  '2764',
  '1f49a',
  '1f49b',
  '1f49c',
  '1f494',
  '1f495',
  '1f496',
  '1f497',
  '1f498',
  '1f499',
  '1f49d',
  '1f525',
  '2728',
  '1f31f',
  '1f4a2',
  '1f4a4',
  '1f4a6',
  '1f4a9',
  '1f389',
  '1f38a',
  '1f381',
  '1f436',
  '1f431',
  '1f42d',
  '1f439',
  '1f430',
  '1f98a',
  '1f43b',
  '1f43c',
  '1f428',
  '1f42f',
  '1f981',
  '1f42e',
  '1f437',
  '1f355',
  '1f354',
  '1f35f',
  '1f36a',
  '1f382',
  '1f369',
  '2600',
  '1f319',
  '2b50',
];

String qfStickerAsset(String id) => 'assets/emoji/$id.png';

extension QfChatBlobApi on QfSessionController {
  Future<String> chatUploadBlob({
    required int recipientId,
    required Uint8List cipher,
    required String cipherSha256,
  }) async {
    final data = await qfPostBinary(
      '/chat/blobs',
      cipher,
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Blob-Recipient': '$recipientId',
        'X-Blob-Sha256': cipherSha256,
      },
    );
    final blobId = (data['blobId'] ?? '').toString();
    if (blobId.isEmpty) {
      throw const QfApiException(0, 'BLOB_ID_MISSING', '附件上传失败，请稍后重试。');
    }
    return blobId;
  }

  Future<Uint8List?> chatDownloadBlob(String blobId) async {
    return qfGetBinary('/chat/blobs/${Uri.encodeComponent(blobId)}');
  }

  Future<void> chatDeleteBlob(String blobId) async {
    await authed('DELETE', '/chat/blobs/${Uri.encodeComponent(blobId)}');
  }
}
