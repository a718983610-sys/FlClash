
import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_pages.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_signal.dart';
import 'package:fl_clash/qf/qf_social.dart';
import 'package:fl_clash/qf/qf_support.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBatchSession extends QfSessionController {
  _FakeBatchSession() {
    mode = QfMode.user;
    userId = 100;
    username = 'tester123';
    serverBaseUrl = 'http://127.0.0.1:1';
  }

  List<dynamic> chatHistory = [];
  List<dynamic> blobsData = [
    {
      'id': 'b1',
      'blobId': 'blob-1',
      'sizeBytes': 2048,
      'recipientUserId': 42,
      'createdAt': 1700000000,
      'downloaded': true,
    },
  ];
  List<String> deletedBlobPaths = [];
  List<String> untrustPaths = [];
  List<dynamic> supportMessages = [
    {'author_role': 'bot', 'body': '您好，这里是智能客服。', 'createdAt': 1000},
    {'author_role': 'user', 'body': '节点连不上', 'createdAt': 1500},
    {'author_role': 'agent', 'body': '您好，正在为您处理。', 'createdAt': 2000},
  ];
  List<dynamic> ledgerData = [
    {
      'type': 'forum_daily',
      'delta': 1,
      'balanceAfter': 10,
      'createdAt': 1700000000,
      'note': '论坛每日签到',
    },
    {
      'type': 'forum_milestone',
      'delta': 5,
      'balanceAfter': 15,
      'createdAt': 1700000100,
      'note': '',
    },
  ];

  @override
  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    if (path.startsWith('/chat/messages')) {
      return {'messages': chatHistory};
    }
    if (method == 'GET' && path.startsWith('/chat/blobs')) {
      return {'blobs': blobsData, 'total': blobsData.length};
    }
    if (method == 'DELETE' && path.startsWith('/chat/blobs/')) {
      deletedBlobPaths.add(path);
      return {'ok': true};
    }
    if (path == '/security/me') {
      return {'email': 'a@b.c', 'loginProtection': true, 'hasPassword': true};
    }
    if (path == '/security/settings') return {};
    if (path.startsWith('/passkeys')) return {'passkeys': const []};
    if (method == 'POST' && path.contains('/untrust')) {
      untrustPaths.add(path);
      return {'ok': true};
    }
    throw QfApiException(404, 'NOT_FOUND', '未实现的测试路径：$path');
  }

  @override
  Future<List<dynamic>> securityDevices() async {
    return [
      {
        'id': 5,
        'name': '本机',
        'trusted': true,
        'verifiedAt': 1700000000,
        'isCurrent': true,
      },
      {'id': 6, 'name': '旧手机', 'trusted': false},
    ];
  }

  @override
  Future<Map<String, dynamic>> supportSession() async {
    return {'sessionId': 's-1', 'messages': supportMessages};
  }

  @override
  Future<void> refreshPoints() async {}

  @override
  Future<List<dynamic>> pointsLedger() async => ledgerData;

  @override
  Future<Map<String, dynamic>> pointsRules() async {
    return {'params': <String, dynamic>{}, 'redeemRegionBlocked': false};
  }

  @override
  Future<Map<String, dynamic>> redeemProducts() async {
    return {
      'balance': 5000,
      'products': [
        {
          'id': 1,
          'name': '人工发码商品',
          'pricePoints': 100,
          'stockStatus': 'manual',
          'stock': null,
          'payoutMethods': ['code'],
        },
        {
          'id': 2,
          'name': '售罄商品',
          'pricePoints': 100,
          'stockStatus': 'sold_out',
          'stock': 0,
          'payoutMethods': ['code'],
        },
        {
          'id': 3,
          'name': '余量商品',
          'pricePoints': 100,
          'stockStatus': 'low',
          'stock': 3,
          'payoutMethods': ['code'],
        },
      ],
    };
  }

  @override
  Future<List<dynamic>> myOrders() async {
    return [
      {
        'id': 9,
        'productName': 'USDT 商品',
        'costPoints': 200,
        'status': 'pending_review',
        'payoutMethod': 'usdt',
        'payoutAddress': 'T-OLD',
        'createdAt': 1700000000,
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> forumMeHome() async {
    return {'posts': const [], 'comments': const []};
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(home: child);
}

const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

final Map<String, String> _secureStore = {};

/// A working in-memory secure store: production builds always have a
/// real keystore behind this channel, and QfSignalStore (C-42) now
/// refuses to mint a chat identity when the store cannot be read at
/// all - an unmocked channel (which never answers) would otherwise
/// block identity creation in widget tests.
void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        final key = (args['key'] ?? '').toString();
        switch (call.method) {
          case 'read':
            return _secureStore[key];
          case 'write':
            _secureStore[key] = (args['value'] ?? '').toString();
            return null;
          case 'delete':
            _secureStore.remove(key);
            return null;
          case 'deleteAll':
            _secureStore.clear();
            return null;
          case 'readAll':
            return Map<String, String>.from(_secureStore);
          case 'containsKey':
            return _secureStore.containsKey(key);
          default:
            return null;
        }
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _secureStore.clear();
    _mockSecureStorage();
  });

  group('L-09 google complete body', () {
    test('body carries no nickname field', () {
      final body = qfGoogleCompleteBody(
        completionToken: 'tok',
        username: ' tester123 ',
        password: 'secret123',
        device: const {'deviceId': 'd1', 'platform': 'android'},
      );
      expect(body.containsKey('nickname'), isFalse);
      expect(body['username'], 'tester123');
      expect(body['completionToken'], 'tok');
      expect(body['deviceId'], 'd1');
    });
  });

  group('L-07 appeal status parsing', () {
    test('parses nested appeal and top level fields', () {
      final parsed = qfParseAppealStatus({
        'appeal': {
          'status': 'rejected',
          'reviewNote': '资料不完整',
          'reviewedAt': 1700000000,
        },
        'remaining': 2,
      });
      expect(parsed.hasAppeal, isTrue);
      expect(parsed.status, 'rejected');
      expect(parsed.label, QfCopy.appealStatusRejected);
      expect(parsed.reviewNote, '资料不完整');
      expect(parsed.reviewedAt, 1700000000);
      expect(parsed.remaining, 2);
    });

    test('empty response means no appeal', () {
      final parsed = qfParseAppealStatus({});
      expect(parsed.hasAppeal, isFalse);
      expect(qfAppealStatusLabel('pending'), QfCopy.appealStatusPending);
      expect(qfAppealStatusLabel('approved'), QfCopy.appealStatusApproved);
    });

    testWidgets('appeal page renders status query section', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(const QfAppealPage(serverBaseUrl: 'http://127.0.0.1:1')),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text(QfCopy.appealStatusTitle).first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(QfCopy.appealStatusTitle), findsWidgets);
      expect(find.text('使用通行密钥查询'), findsOneWidget);
    });
  });

  group('G1 device trust', () {
    test('trust text covers trusted with time and untrusted', () {
      expect(
        qfDeviceTrustText({'trusted': true, 'verifiedAt': 1700000000}),
        startsWith(QfCopy.deviceTrusted),
      );
      expect(qfDeviceTrustText({'trusted': true}), QfCopy.deviceTrusted);
      expect(qfDeviceTrustText({'trusted': false}), QfCopy.deviceUntrusted);
      expect(qfDeviceTrustText({}), QfCopy.deviceUntrusted);
    });

    testWidgets('security page shows trust state and untrust action', (
      tester,
    ) async {
      final session = _FakeBatchSession();
      await tester.pumpWidget(_wrap(QfSecurityPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.textContaining(QfCopy.deviceTrusted), findsWidgets);
      expect(find.textContaining(QfCopy.deviceUntrusted), findsOneWidget);
      expect(find.text(QfCopy.deviceUntrust), findsOneWidget);
      await tester.tap(find.text(QfCopy.deviceUntrust).first);
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.deviceUntrustConfirm), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, QfCopy.deviceUntrust));
      await tester.pumpAndSettle();
      expect(session.untrustPaths, ['/security/devices/5/untrust']);
    });
  });

  group('G8 deletion subtitle and points ledger', () {
    test('deletion subtitle renders effective time', () {
      expect(qfDeletionSubtitle(null), '冷静期结束前登录即可撤销注销');
      expect(qfDeletionSubtitle(1893456000), startsWith('注销将于 '));
      expect(qfDeletionSubtitle(1893456000), contains('生效前登录即可撤销注销'));
    });

    test('points labels cover forum types and daily remaining', () {
      expect(qfPointsTypeLabel('forum_daily'), '论坛每日积分');
      expect(qfPointsTypeLabel('forum_daily_reversal'), '论坛积分回冲');
      expect(qfPointsTypeLabel('forum_milestone'), '论坛千赞奖励');
      expect(qfPointsDailyRemaining(dailyCap: 8, mintedToday: 3), 5);
      expect(qfPointsDailyRemaining(dailyCap: 8, mintedToday: 9), 0);
    });

    testWidgets('points page shows remaining quota and entry notes', (
      tester,
    ) async {
      final session = _FakeBatchSession();
      session.pointsMe = {'balance': 15, 'dailyCap': 8, 'mintedToday': 3};
      await tester.pumpWidget(_wrap(QfPointsPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text('今日还可累计 5 分'), findsOneWidget);
      expect(find.text('论坛每日积分'), findsOneWidget);
      expect(find.textContaining('论坛每日签到'), findsOneWidget);
      expect(find.text('论坛千赞奖励'), findsOneWidget);
    });
  });

  group('G6/G7 redeem stock and order actions', () {
    test('stock labels follow the four server states', () {
      expect(qfStockLabel({'stockStatus': 'in_stock'}), '有货');
      expect(qfStockLabel({'stockStatus': 'low', 'stock': 3}), '仅剩 3 件');
      expect(qfStockLabel({'stockStatus': 'sold_out'}), '已售罄');
      expect(qfStockLabel({'stockStatus': 'manual', 'stock': null}), '');
      expect(qfStockSoldOut({'stockStatus': 'sold_out'}), isTrue);
      expect(qfStockSoldOut({'stockStatus': 'manual'}), isFalse);
    });

    test('order action gates follow status and payout method', () {
      expect(qfOrderCancellable({'status': 'pending_review'}), isTrue);
      expect(qfOrderCancellable({'status': 'pending_payout'}), isTrue);
      expect(qfOrderCancellable({'status': 'completed'}), isFalse);
      expect(
        qfOrderCanChangePayoutAddress({
          'status': 'pending_review',
          'payoutMethod': 'usdt',
        }),
        isTrue,
      );
      expect(
        qfOrderCanChangePayoutAddress({
          'status': 'pending_review',
          'payoutMethod': 'code',
        }),
        isFalse,
      );
      expect(
        qfOrderCanChangePayoutAddress({
          'status': 'pending_payout',
          'payoutMethod': 'usdt',
        }),
        isFalse,
      );
    });

    testWidgets('redeem page renders stock states and order actions', (
      tester,
    ) async {
      final session = _FakeBatchSession();
      await tester.pumpWidget(_wrap(QfRedeemPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.textContaining('仅剩 3 件'), findsOneWidget);
      expect(find.textContaining('已售罄'), findsOneWidget);
      final soldOutTile = find.ancestor(
        of: find.text('售罄商品'),
        matching: find.byType(ListTile),
      );
      final soldOutButton = tester.widget<FilledButton>(
        find.descendant(of: soldOutTile, matching: find.byType(FilledButton)),
      );
      expect(soldOutButton.onPressed, isNull);
      expect(find.text(QfCopy.orderCancel), findsOneWidget);
      expect(find.text(QfCopy.orderChangeAddress), findsOneWidget);
    });
  });

  group('G4 key backup rewrap', () {
    test('rewrap opens with the new password only', () {
      final plain = Uint8List.fromList([1, 2, 3, 4, 5]);
      final backup = QfSignalManager.encryptBackupPlain(plain, 'old-password');
      final rewrapped = QfSignalManager.rewrapBackupMap(
        backup,
        oldPassword: 'old-password',
        newPassword: 'new-password',
      );
      expect(rewrapped, isNotNull);
      expect(
        QfSignalManager.decryptBackupPlain(rewrapped!, 'new-password'),
        plain,
      );
      expect(
        () => QfSignalManager.decryptBackupPlain(rewrapped, 'old-password'),
        throwsA(anything),
      );
      expect(
        QfSignalManager.rewrapBackupMap(
          backup,
          oldPassword: 'wrong-password',
          newPassword: 'new-password',
        ),
        isNull,
      );
    });
  });

  group('chat helpers (G5/G16)', () {
    test('unread map reads nested user ids and skips zero', () {
      expect(
        qfUnreadByUser([
          {
            'user': {'userId': 42},
            'unreadCount': 3,
          },
          {
            'user': {'userId': 7},
            'unreadCount': 0,
          },
          {'userId': 9, 'unreadCount': 1},
        ]),
        {42: 3, 9: 1},
      );
    });

    test('avatar cache key changes with the updated stamp', () {
      expect(qfAvatarCacheKey(7, 100), isNot(qfAvatarCacheKey(7, 200)));
      qfStoreCachedAvatar(7, 100, Uint8List.fromList([1]));
      expect(qfCachedAvatar(7, 100), isNotNull);
      // 展示以进程内已知最新版本为准：持更新戳的调用先回已知最新图占位，
      // 由 _resolve 按 effective stamp 拉取新图（「上传后没变化」修复口径）。
      expect(qfCachedAvatar(7, 200), isNotNull);
      expect(qfEffectiveAvatarStamp(7, 200), 200);
    });

    test('small avatar bytes pass through uncompressed', () async {
      final small = Uint8List.fromList(List<int>.filled(1024, 7));
      final result = await qfCompressAvatarBytes(small);
      expect(result.compressed, isFalse);
      expect(result.bytes, small);
    });

    testWidgets('chat page marks own read state and decrypt failure', (
      tester,
    ) async {
      QfSignalStore.resetCache();
      final session = _FakeBatchSession();
      session.chatHistory = [
        {
          'id': 5,
          'from': 42,
          'ciphertext': 'not-a-real-ciphertext',
          'createdAt': 1000,
        },
        {
          'id': 6,
          'from': 100,
          'msgId': 'm-read',
          'readAt': 2000,
          'createdAt': 1500,
        },
        {'id': 7, 'from': 100, 'msgId': 'm-unread', 'createdAt': 1600},
      ];
      await tester.pumpWidget(
        _wrap(
          QfChatPage(
            session: session,
            friend: const {'userId': 42, 'nickname': '测试好友'},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(QfCopy.chatDecryptFailed), findsOneWidget);
      expect(find.text('已读'), findsOneWidget);
      expect(find.text('未读'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('attachments page', () {
    testWidgets('lists blobs and deletes with the seven day notice', (
      tester,
    ) async {
      final session = _FakeBatchSession();
      await tester.pumpWidget(_wrap(QfAttachmentsPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(find.textContaining('对方已下载'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.attachmentsDeleteHint), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(session.deletedBlobPaths, ['/chat/blobs/blob-1']);
    });
  });

  group('G12 support tile', () {
    test('latest agent message and unread count helpers', () {
      final messages = qfSupportParseMessages({
        'messages': _FakeBatchSession().supportMessages,
      });
      expect(qfSupportLatestAgentMessage(messages)?.body, '您好，正在为您处理。');
      expect(qfSupportUnreadCount(messages, 0), 2);
      expect(qfSupportUnreadCount(messages, 2000000), 0);
    });

    test('handoff notice respects supportConfigured', () {
      expect(
        qfSupportHandoffNoticeText({'supportConfigured': false}),
        qfSupportNotConfiguredNotice,
      );
      expect(
        qfSupportHandoffNoticeText({'supportConfigured': true}),
        QfCopy.supportHandoffNotice,
      );
    });

    testWidgets('tile shows latest reply summary and unread badge', (
      tester,
    ) async {
      final session = _FakeBatchSession();
      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: QfSupportContactTile(
              session: session,
              entry: const {'displayName': '智能客服'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('您好，正在为您处理。'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });

  group('G8 mine page deletion card', () {
    testWidgets('mine page renders deletion effective time subtitle', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = _FakeBatchSession();
      session.accountDeleting = true;
      session.deletionEffectiveAt = 1893456000;
      session.pointsMe = {'balance': 0};
      await tester.pumpWidget(_wrap(QfMinePage(session: session)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(find.textContaining('注销将于 '), 200);
      expect(find.textContaining('注销将于 '), findsOneWidget);
      expect(find.textContaining('生效前登录即可撤销注销'), findsOneWidget);
    });
  });
}
