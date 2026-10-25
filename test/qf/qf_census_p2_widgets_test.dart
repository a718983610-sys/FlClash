import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_social.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

class _CensusSession extends QfSessionController {
  _CensusSession() {
    mode = QfMode.user;
    userId = 100;
    serverBaseUrl = 'http://127.0.0.1:1';
  }

  bool failDelete = false;
  bool failBlobs = false;
  bool failProfile = false;
  Map<String, dynamic> profilePayload = const {};
  List<dynamic> historyMessages = const [];
  final List<String> calls = [];
  int deleteCalls = 0;

  @override
  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    calls.add('$method $path');
    if (method == 'GET' && path.startsWith('/chat/messages')) {
      return {'messages': historyMessages};
    }
    if (method == 'DELETE' && path.startsWith('/chat/messages/')) {
      deleteCalls++;
      if (failDelete) {
        throw const QfApiException(403, 'CHAT_DELETE_FORBIDDEN', '只能删除自己发送的消息。');
      }
      return {'deleted': true};
    }
    if (method == 'POST' && path == '/chat/read') return {};
    if (method == 'GET' && path == '/profile') {
      if (failProfile) {
        throw const QfApiException(0, 'NETWORK', '请求失败，请稍后重试');
      }
      return {'profile': profilePayload};
    }
    if (method == 'GET' && path == '/forum/profile') {
      if (failProfile) {
        throw const QfApiException(0, 'NETWORK', '请求失败，请稍后重试');
      }
      return {'nickname': '论坛昵称'};
    }
    if (method == 'GET' && path.startsWith('/chat/blobs')) {
      if (failBlobs) {
        throw const QfApiException(0, 'NETWORK', '请求失败，请稍后重试');
      }
      if (path.contains('offset=2')) {
        return {
          'total': 3,
          'blobs': [
            {'blobId': 'b2', 'sizeBytes': 2048, 'recipientUserId': 7},
            {'blobId': 'b3', 'sizeBytes': 3072, 'recipientUserId': 8},
          ],
        };
      }
      return {
        'total': 3,
        'blobs': [
          {'blobId': 'b1', 'sizeBytes': 1024, 'recipientUserId': 7},
          {'blobId': 'b2', 'sizeBytes': 2048, 'recipientUserId': 7},
        ],
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    QfSignalStore.resetCache();
    // Without a handler the secure-storage read never settles in the
    // test environment and its 5s timeout timer outlives the test.
    final store = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
          final args = call.arguments is Map
              ? Map<dynamic, dynamic>.from(call.arguments as Map)
              : const {};
          final key = args['key']?.toString() ?? '';
          return switch (call.method) {
            'read' => store[key],
            'write' => store[key] = args['value'].toString(),
            'delete' => store.remove(key),
            'containsKey' => store.containsKey(key),
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  group('C-38 delete for everyone', () {
    _CensusSession ownMessageSession() {
      return _CensusSession()
        ..historyMessages = [
          {
            'id': 555,
            'msgId': 'srv-del-1',
            'from': 100,
            'mine': true,
            'ciphertext': 'x',
            'createdAt': 1700000000,
          },
        ];
    }

    Future<void> openChat(WidgetTester tester, _CensusSession session) async {
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
    }

    testWidgets('server delete succeeds, then local copy and tombstone', (
      tester,
    ) async {
      final session = ownMessageSession();
      await openChat(tester, session);
      expect(find.text('已加密发送的消息'), findsOneWidget);
      await tester.longPress(find.text('已加密发送的消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('删除（对所有人）'), findsOneWidget);
      expect(find.text('删除本机记录'), findsOneWidget);
      await tester.tap(find.text('删除（对所有人）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('从服务器上删除'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.deleteCalls, 1);
      expect(find.text('已加密发送的消息'), findsNothing);
      expect(find.text('消息已经删除。'), findsOneWidget);
      final deleted = await QfChatHistoryVault.deletedLocalIds();
      expect(deleted.contains('m-srv-del-1'), isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('server refusal keeps the local copy and shows its wording', (
      tester,
    ) async {
      final session = ownMessageSession()..failDelete = true;
      await openChat(tester, session);
      await tester.longPress(find.text('已加密发送的消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('删除（对所有人）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.deleteCalls, 1);
      expect(find.text('已加密发送的消息'), findsOneWidget);
      expect(find.text('只能删除自己发送的消息。'), findsOneWidget);
      final deleted = await QfChatHistoryVault.deletedLocalIds();
      expect(deleted.contains('m-srv-del-1'), isFalse);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('C-40 read receipt bound', () {
    testWidgets('an undecryptable incoming message is not marked read', (
      tester,
    ) async {
      final session = _CensusSession()
        ..historyMessages = [
          {
            'id': 556,
            'msgId': 'inc-1',
            'from': 42,
            'mine': false,
            'ciphertext': 'x',
            'createdAt': 1700000000,
          },
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: QfChatPage(
            session: session,
            friend: const {'userId': 42, 'nickname': '测试好友'},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      expect(
        session.calls.where((call) => call.startsWith('POST /chat/read')),
        isEmpty,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('C-35 profile page', () {
    testWidgets('double failure shows a failure state with retry', (
      tester,
    ) async {
      final session = _CensusSession()..failProfile = true;
      await tester.pumpWidget(
        MaterialApp(home: QfProfilePage(session: session)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('个人资料加载失败，请检查网络后重试。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('key presence comes from the device, not the backup flag', (
      tester,
    ) async {
      final session = _CensusSession()
        ..profilePayload = {'nickname': '小明', 'hasKeyBackup': true};
      await tester.pumpWidget(
        MaterialApp(home: QfProfilePage(session: session)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('本机尚未生成聊天密钥'), findsOneWidget);
      expect(find.textContaining('本机已生成聊天密钥'), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('C-36 attachments page', () {
    testWidgets('load more dedupes overlapping pages by blobId', (
      tester,
    ) async {
      final session = _CensusSession();
      await tester.pumpWidget(
        MaterialApp(home: QfAttachmentsPage(session: session)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ListTile), findsNWidgets(2));
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ListTile), findsNWidgets(3));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('initial failure shows a failure state with retry', (
      tester,
    ) async {
      final session = _CensusSession()..failBlobs = true;
      await tester.pumpWidget(
        MaterialApp(home: QfAttachmentsPage(session: session)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('附件加载失败，请检查网络后重试。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
