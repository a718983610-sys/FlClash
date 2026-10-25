import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_chat_media.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_social.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeChatSession extends QfSessionController {
  _FakeChatSession() {
    mode = QfMode.user;
    userId = 100;
    serverBaseUrl = 'http://127.0.0.1:1';
  }
}

QfAttachmentRef _sampleRef() {
  return const QfAttachmentRef(
    blobId: 'blob-123',
    fileKey: 'a2V5',
    nonce: 'bm9uY2U',
    cipherSha256: 'abc123',
    name: '报告.pdf',
    mime: 'application/pdf',
    size: 2048,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('payload codec', () {
    test('plain text passes through unchanged', () {
      final payload = QfChatPayload.parse('你好，普通消息');
      expect(payload.kind, QfChatPayloadKind.text);
      expect(payload.encode(), '你好，普通消息');
      expect(payload.displayText, '你好，普通消息');
    });

    test('attachment payload roundtrip keeps every contract field', () {
      final encoded = QfChatPayload.attachment(_sampleRef()).encode();
      final decoded = QfChatPayload.parse(encoded);
      expect(decoded.kind, QfChatPayloadKind.attachment);
      final ref = decoded.attachment!;
      expect(ref.blobId, 'blob-123');
      expect(ref.fileKey, 'a2V5');
      expect(ref.nonce, 'bm9uY2U');
      expect(ref.cipherSha256, 'abc123');
      expect(ref.name, '报告.pdf');
      expect(ref.mime, 'application/pdf');
      expect(ref.size, 2048);
      final wire = jsonDecode(encoded.substring(4)) as Map;
      expect(wire['type'], 'attachment');
    });

    test('sticker payload roundtrip', () {
      final encoded = QfChatPayload.sticker('1f600').encode();
      final decoded = QfChatPayload.parse(encoded);
      expect(decoded.kind, QfChatPayloadKind.sticker);
      expect(decoded.stickerId, '1f600');
      expect(decoded.displayText, '表情');
    });

    test('reaction payload roundtrip including revoke', () {
      final add = QfChatPayload.parse(
        QfChatPayload.reaction('m-1', '👍').encode(),
      );
      expect(add.kind, QfChatPayloadKind.reaction);
      expect(add.reactionTargetLocalId, 'm-1');
      expect(add.reactionEmoji, '👍');
      final revoke = QfChatPayload.parse(
        QfChatPayload.reaction('m-1', '').encode(),
      );
      expect(revoke.reactionEmoji, '');
    });

    test('malformed structured payloads fall back to plain text', () {
      expect(QfChatPayload.parse('qf1:{oops').kind, QfChatPayloadKind.text);
      expect(
        QfChatPayload.parse('qf1:{"type":"unknown"}').kind,
        QfChatPayloadKind.text,
      );
      expect(
        QfChatPayload.parse('qf1:{"type":"attachment","blobId":""}').kind,
        QfChatPayloadKind.text,
      );
    });
  });

  group('blob crypto', () {
    test('seal and open roundtrip with sha256 verification', () {
      final plain = Uint8List.fromList(utf8.encode('机密附件内容 hello'));
      final sealed = QfBlobCrypto.seal(plain);
      expect(QfBlobCrypto.sha256Hex(sealed.cipher), sealed.cipherSha256);
      final ref = QfAttachmentRef(
        blobId: 'b1',
        fileKey: sealed.fileKey,
        nonce: sealed.nonce,
        cipherSha256: sealed.cipherSha256,
        name: 'a.txt',
        mime: 'text/plain',
        size: plain.length,
      );
      expect(QfBlobCrypto.open(ref, sealed.cipher), plain);
    });

    test('tampered cipher is rejected by checksum', () {
      final sealed = QfBlobCrypto.seal(Uint8List.fromList([1, 2, 3]));
      final tampered = Uint8List.fromList(sealed.cipher)..[0] ^= 0xff;
      final ref = QfAttachmentRef(
        blobId: 'b1',
        fileKey: sealed.fileKey,
        nonce: sealed.nonce,
        cipherSha256: sealed.cipherSha256,
        name: 'a.bin',
        mime: 'application/octet-stream',
        size: 3,
      );
      expect(
        () => QfBlobCrypto.open(ref, tampered),
        throwsA(isA<QfChatMediaException>()),
      );
    });
  });

  group('reactions reducer', () {
    test('add, replace, revoke and summary counts', () {
      final map = <String, Map<String, String>>{};
      QfReactions.apply(map, targetLocalId: 'm1', reactorKey: '1', emoji: '👍');
      QfReactions.apply(map, targetLocalId: 'm1', reactorKey: '2', emoji: '👍');
      QfReactions.apply(map, targetLocalId: 'm1', reactorKey: '1', emoji: '❤️');
      var summary = QfReactions.summary(map, 'm1', '1');
      expect(summary.length, 2);
      expect(summary.firstWhere((item) => item.emoji == '👍').count, 1);
      expect(summary.firstWhere((item) => item.emoji == '❤️').mine, isTrue);
      QfReactions.apply(map, targetLocalId: 'm1', reactorKey: '1', emoji: '');
      summary = QfReactions.summary(map, 'm1', '1');
      expect(summary.length, 1);
      expect(summary.single.emoji, '👍');
      QfReactions.apply(map, targetLocalId: 'm1', reactorKey: '2', emoji: '');
      expect(map.containsKey('m1'), isFalse);
    });

    test('tapping the same emoji revokes, a different one replaces', () {
      expect(QfReactions.nextEmoji(current: '👍', tapped: '👍'), '');
      expect(QfReactions.nextEmoji(current: '👍', tapped: '❤️'), '❤️');
      expect(QfReactions.nextEmoji(current: null, tapped: '👍'), '👍');
    });

    test('quick reactions hold 6 to 8 entries', () {
      expect(qfQuickReactions.length, inInclusiveRange(6, 8));
    });
  });

  group('attachment error copy', () {
    test('quota and size codes map to the official wording', () {
      expect(
        qfAttachmentErrorMessage(
          const QfApiException(403, 'BLOB_QUOTA_EXCEEDED', 'x'),
        ),
        qfAttachmentQuotaMessage,
      );
      expect(
        qfAttachmentErrorMessage(
          const QfApiException(413, 'BLOB_TOO_LARGE', 'x'),
        ),
        qfAttachmentTooLargeMessage,
      );
      expect(
        qfAttachmentErrorMessage(const QfApiException(413, '', 'x')),
        qfAttachmentTooLargeMessage,
      );
    });

    test('storage not configured maps to the unavailable wording', () {
      expect(
        qfAttachmentErrorMessage(
          const QfApiException(503, 'BLOB_STORAGE_NOT_CONFIGURED', 'x'),
        ),
        qfAttachmentUnavailableMessage,
      );
      expect(
        qfAttachmentErrorMessage(const QfApiException(503, '', 'x')),
        qfAttachmentUnavailableMessage,
      );
    });

    test('server wording wins, otherwise the fallback applies', () {
      expect(
        qfAttachmentErrorMessage(
          const QfApiException(400, 'OTHER', '服务端给出的说明'),
        ),
        '服务端给出的说明',
      );
      expect(
        qfAttachmentErrorMessage(
          const QfApiException(0, 'NETWORK', '请求失败，请稍后重试'),
        ),
        '附件发送失败，请稍后重试。',
      );
    });
  });

  group('emoji and sticker data', () {
    test('unicode groups are populated', () {
      expect(qfUnicodeEmojiGroups.length, greaterThanOrEqualTo(5));
      for (final entry in qfUnicodeEmojiGroups.entries) {
        expect(entry.value.length, greaterThanOrEqualTo(20), reason: entry.key);
        expect(entry.value.toSet().length, entry.value.length);
      }
    });

    test('twemoji subset respects the size budget and files exist', () {
      expect(qfTwemojiStickerIds.length, lessThanOrEqualTo(150));
      expect(qfTwemojiStickerIds.toSet().length, qfTwemojiStickerIds.length);
      var total = 0;
      for (final id in qfTwemojiStickerIds) {
        final file = File(qfStickerAsset(id));
        expect(file.existsSync(), isTrue, reason: id);
        final length = file.lengthSync();
        expect(length, lessThanOrEqualTo(50 * 1024), reason: id);
        total += length;
      }
      expect(total, lessThanOrEqualTo(5 * 1024 * 1024));
      expect(File('assets/emoji/NOTICE').existsSync(), isTrue);
    });
  });

  group('vault archive roundtrip', () {
    test('attachment reference survives archive and restore', () async {
      SharedPreferences.setMockInitialValues({});
      final wire = QfChatPayload.attachment(_sampleRef()).encode();
      final record = QfHistoryRecord(
        localId: 'm-att-1',
        peerId: 42,
        mine: false,
        text: wire,
        ts: 1000,
      );
      expect(await QfChatHistoryVault.archiveMessage(record), isTrue);
      final restored = await QfChatHistoryVault.localRecordsFor(42);
      expect(restored.length, 1);
      final parsed = QfChatPayload.parse(restored.single.text);
      expect(parsed.kind, QfChatPayloadKind.attachment);
      expect(parsed.attachment!.blobId, 'blob-123');
      expect(parsed.attachment!.fileKey, 'a2V5');
      await QfChatHistoryVault.removeLocalRecord('m-att-1');
      expect(await QfChatHistoryVault.localRecordsFor(42), isEmpty);
    });

    test('reaction events survive archive and restore', () async {
      SharedPreferences.setMockInitialValues({});
      final wire = QfChatPayload.reaction('m-9', '🔥').encode();
      await QfChatHistoryVault.archiveMessage(
        QfHistoryRecord(
          localId: 'm-rx-1',
          peerId: 7,
          mine: true,
          text: wire,
          ts: 2000,
        ),
      );
      final restored = await QfChatHistoryVault.localRecordsFor(7);
      final parsed = QfChatPayload.parse(restored.single.text);
      expect(parsed.kind, QfChatPayloadKind.reaction);
      expect(parsed.reactionTargetLocalId, 'm-9');
      expect(parsed.reactionEmoji, '🔥');
    });
  });

  group('avatar entry wiring', () {
    testWidgets('letter avatar renders when there is no avatar', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final session = QfSessionController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QfAvatarImage(
              session: session,
              userId: 42,
              name: '测试用户',
              hasAvatar: false,
            ),
          ),
        ),
      );
      expect(find.text('测'), findsOneWidget);
    });

    testWidgets('my avatar button renders and is tappable', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = QfSessionController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QfMyAvatarButton(session: session, name: '我'),
          ),
        ),
      );
      expect(find.byType(QfMyAvatarButton), findsOneWidget);
      expect(find.byType(GestureDetector), findsWidgets);
    });
  });

  group('blob reference on send', () {
    test('send body carries blobId only for attachment messages', () {
      final withBlob = qfChatSendBody(
        42,
        msgId: 'm1',
        ciphertext: 'c',
        nonce: 'n',
        blobId: 'blob-9',
      );
      expect(withBlob['blobId'], 'blob-9');
      expect(withBlob['to'], 42);
      final plain = qfChatSendBody(
        42,
        msgId: 'm2',
        ciphertext: 'c',
        nonce: 'n',
      );
      expect(plain.containsKey('blobId'), isFalse);
    });

    test(
      'peer preflight fails closed when the bundle is unreachable',
      () async {
        SharedPreferences.setMockInitialValues({});
        QfSignalStore.resetCache();
        final session = _FakeChatSession();
        expect(await QfSignalManager.peerReachable(session, 42), isFalse);
      },
    );
  });

  group('chat page emoji panel', () {
    testWidgets('panel opens with unicode and sticker tabs', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = _FakeChatSession();
      await tester.pumpWidget(
        MaterialApp(
          home: QfChatPage(
            session: session,
            friend: const {'userId': 42, 'nickname': '测试好友'},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final emojiButton = find.byTooltip('表情');
      expect(emojiButton, findsOneWidget);
      await tester.tap(emojiButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('表情包'), findsOneWidget);
      await tester.tap(find.text('表情包'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Image), findsWidgets);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('failed reaction send rolls back the optimistic reaction', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      QfSignalStore.resetCache();
      await QfChatHistoryVault.archiveMessage(
        const QfHistoryRecord(
          localId: 'm-seed-1',
          peerId: 42,
          mine: false,
          text: '你好',
          ts: 1000,
        ),
      );
      final session = _FakeChatSession();
      await tester.pumpWidget(
        MaterialApp(
          home: QfChatPage(
            session: session,
            friend: const {'userId': 42, 'nickname': '测试好友'},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('你好'), findsOneWidget);
      await tester.longPress(find.text('你好'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('👍'));
      // Wait on states, not a fixed budget: the verdict lands at a different fake time per pump schedule, and this notice queues one 4-second qfToast slot behind the delivery failure notice.
      var rolledBack = false;
      var failureNoticeShown = false;
      var noticeShown = false;
      for (var step = 0; step < 80 && !noticeShown; step++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.text('👍').evaluate().isEmpty) rolledBack = true;
        if (find.text('发送失败：网络或接口错误，请检查网络后重试。').evaluate().isNotEmpty ||
            find.text('对方尚未启用聊天加密，暂时无法发送消息。').evaluate().isNotEmpty) {
          failureNoticeShown = true;
        }
        if (find.text('回应发送失败，请稍后重试。').evaluate().isNotEmpty) {
          noticeShown = true;
        }
      }
      expect(rolledBack, isTrue);
      expect(failureNoticeShown, isTrue);
      expect(noticeShown, isTrue);
      expect(find.text('👍'), findsNothing);
      expect(find.text('回应发送失败，请稍后重试。'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
