import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_social.dart';
import 'package:fl_clash/qf/qf_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FakeSupportSession extends QfSessionController {
  _FakeSupportSession({required bool loggedIn, this.inboxReachable = false}) {
    mode = loggedIn ? QfMode.user : QfMode.guest;
    userId = loggedIn ? 42 : null;
    username = loggedIn ? 'tester123' : null;
  }

  final bool inboxReachable;
  List<dynamic> friendsData = [
    {
      'userId': 7,
      'nickname': '好友甲',
      'username': 'friend001',
      'hasAvatar': false,
    },
  ];
  List<dynamic> sessionMessages = [
    {'author_role': 'bot', 'body': '您好，这里是智能客服。', 'createdAt': 1000},
  ];
  Map<String, dynamic> nextAsk = {
    'action': 'answer',
    'kbId': 'kb-1',
    'text': '请在订阅页面点击更新按钮。',
    'sessionId': 's-1',
  };
  List<Map<String, dynamic>> askCalls = [];
  String handoffNoticeText = '已为您转接人工客服。人工客服的回复将显示在本会话中。';
  bool handoffCalled = false;
  List<dynamic> ticketsData = [
    {
      'sessionId': 's-9',
      'userLabel': '用户乙',
      'lastMessage': '还是连不上',
      'unreadCount': 2,
      'status': 'open',
    },
  ];
  Map<String, dynamic> ticketDetail = {
    'status': 'open',
    'messages': [
      {'author_role': 'user', 'body': '节点连不上', 'createdAt': 1000},
      {'author_role': 'bot', 'body': '请先尝试更新订阅。', 'createdAt': 2000},
      {'author_role': 'agent', 'body': '您好，正在为您处理。', 'createdAt': 3000},
    ],
  };
  List<String> replies = [];
  bool closedCalled = false;

  @override
  Future<Map<String, dynamic>> authed(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    if (path == '/friends') return {'friends': friendsData};
    if (path == '/friends/requests') {
      return {'incoming': const [], 'outgoing': const []};
    }
    if (path == '/support/inbox') {
      if (!inboxReachable) {
        throw const QfApiException(403, 'FORBIDDEN', '无权访问');
      }
      return {'tickets': ticketsData};
    }
    throw QfApiException(404, 'NOT_FOUND', '未实现的测试路径：$path');
  }

  @override
  Future<Map<String, dynamic>> supportSession() async {
    return {'sessionId': 's-1', 'messages': sessionMessages};
  }

  @override
  Future<Map<String, dynamic>> supportAsk({
    String? sessionId,
    String? text,
    bool notThis = false,
    String? kbId,
  }) async {
    askCalls.add({
      'sessionId': sessionId,
      'text': text,
      'notThis': notThis,
      'kbId': kbId,
    });
    return nextAsk;
  }

  @override
  Future<Map<String, dynamic>> supportHandoff(String? sessionId) async {
    handoffCalled = true;
    return {'ok': true, 'notice': handoffNoticeText, 'sessionId': 's-1'};
  }

  List<Map<String, dynamic>> guestAskCalls = [];
  bool guestHandoffCalled = false;
  Map<String, dynamic>? guestVerifyCall;

  Map<String, dynamic> guestVerified = {'linked': false, 'username': null};

  @override
  Future<Map<String, dynamic>> guestSupportSession() async {
    return {
      'sessionId': 'g-1',
      'status': 'active',
      'guestToken': null,
      'verified': guestVerified,
    };
  }

  @override
  Future<Map<String, dynamic>> guestSupportSnapshot() async {
    return {
      'sessionId': 'g-1',
      'status': 'active',
      'verified': guestVerified,
      'messages': sessionMessages,
    };
  }

  @override
  Future<Map<String, dynamic>> guestSupportFetch({String? sessionId}) async {
    return {
      'sessionId': 'g-1',
      'verified': guestVerified,
      'messages': sessionMessages,
    };
  }

  @override
  Future<Map<String, dynamic>> guestSupportAsk({
    String? sessionId,
    String? text,
    bool notThis = false,
    String? kbId,
  }) async {
    guestAskCalls.add({
      'sessionId': sessionId,
      'text': text,
      'notThis': notThis,
      'kbId': kbId,
    });
    return nextAsk;
  }

  @override
  Future<Map<String, dynamic>> guestSupportHandoff(String? sessionId) async {
    guestHandoffCalled = true;
    return {
      'handoff': true,
      'gated': false,
      'notice': handoffNoticeText,
      'sessionId': 'g-1',
      'supportConfigured': true,
    };
  }

  @override
  Future<Map<String, dynamic>> guestSupportVerify({
    required String account,
    required String password,
  }) async {
    guestVerifyCall = {'account': account, 'password': password};
    guestVerified = {'linked': true, 'username': 'tester123'};
    return {
      'verified': true,
      'alreadyLinked': false,
      'username': 'tester123',
      'message': '核验通过，已关联您的账户。',
    };
  }

  @override
  Future<Map<String, dynamic>> supportInbox() async {
    if (!inboxReachable) {
      throw const QfApiException(403, 'FORBIDDEN', '无权访问');
    }
    return {'tickets': ticketsData};
  }

  @override
  Future<Map<String, dynamic>> supportInboxDetail(String sessionId) async {
    return ticketDetail;
  }

  @override
  Future<void> supportInboxReply(String sessionId, String text) async {
    replies.add(text);
  }

  @override
  Future<void> supportInboxClose(String sessionId) async {
    closedCalled = true;
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(home: child);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(_wrap(const SizedBox()));
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  test('bot entry synthesis keeps server entry first and single', () {
    final normal = {'userId': 7, 'nickname': '好友甲'};
    final serverBot = qfSupportBotEntry();
    final merged = qfSupportWithBotEntry([normal, serverBot], loggedIn: true);
    expect(merged.length, 2);
    expect(qfSupportIsBotEntry(merged.first as Map), isTrue);
    final synthesized = qfSupportWithBotEntry([normal], loggedIn: true);
    expect(synthesized.length, 2);
    expect((synthesized.first as Map)['displayName'], '智能客服');
    expect((synthesized.first as Map)['pinned'], isTrue);
    expect((synthesized.first as Map)['undeletable'], isTrue);
    final guest = qfSupportWithBotEntry([normal], loggedIn: false);
    expect(guest.length, 1);
  });

  test('bot entry is undeletable and roles map to fixed display names', () {
    expect(qfSupportEntryDeletable(qfSupportBotEntry()), isFalse);
    expect(qfSupportEntryDeletable({'userId': 7}), isTrue);
    expect(qfSupportDisplayNameForRole('bot'), '智能客服');
    expect(qfSupportDisplayNameForRole('agent'), '人工客服');
    expect(qfSupportDisplayNameForRole('user'), '用户');
  });

  test('ask reply parsing covers answer alternates clarify handoff', () {
    final answer = QfSupportReply.fromJson({
      'action': 'answer',
      'kbId': 'kb-1',
      'text': '答案正文',
      'sessionId': 's-1',
      'alternates': [
        {'kbId': 'kb-2', 'label': '备选条目'},
      ],
    });
    expect(answer.action, 'answer');
    expect(answer.choices.single.kbId, 'kb-2');
    final clarify = QfSupportReply.fromJson({
      'action': 'clarify',
      'text': '请问您指的是哪一项？',
      'options': [
        {'kbId': 'kb-3', 'label': '选项条目'},
      ],
    });
    expect(clarify.isClarify, isTrue);
    expect(clarify.choices.single.label, '选项条目');
    final handoff = QfSupportReply.fromJson({
      'action': 'handoff_offer',
      'text': '可为您转接人工客服。',
    });
    expect(handoff.isHandoffOffer, isTrue);
  });

  test('handoff notice falls back to the fixed copy', () {
    expect(qfSupportHandoffNotice({'notice': '服务端定稿通知'}), '服务端定稿通知');
    expect(qfSupportHandoffNotice({}), QfCopy.supportHandoffNotice);
    expect(QfCopy.supportHandoffNotice, contains('人工客服的回复将显示在本会话中'));
  });

  test('message and ticket parsing keeps server order by time', () {
    final messages = qfSupportParseMessages({
      'messages': [
        {'author_role': 'agent', 'body': '人工回复', 'createdAt': 3000},
        {'author_role': 'user', 'body': '用户问题', 'createdAt': 1000},
        {'author_role': 'bot', 'body': '机器人回复', 'created_at': 2000},
      ],
    });
    expect(messages.map((item) => item.role), ['user', 'bot', 'agent']);
    expect(messages[1].displayName, '智能客服');
    expect(messages[2].displayName, '人工客服');
    final tickets = qfSupportParseTickets({
      'tickets': [
        {
          'id': 's-9',
          'userId': 8,
          'lastBody': '摘要',
          'unread': 1,
          'status': 'open',
        },
      ],
    });
    expect(tickets.single.sessionId, 's-9');
    expect(tickets.single.userLabel, '用户 8');
    expect(tickets.single.unread, 1);
  });

  testWidgets('friends page pins support bot without delete entry', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: true);
    await tester.pumpWidget(_wrap(QfFriendsPage(session: session)));
    await tester.pumpAndSettle();
    final contact = find.byKey(const ValueKey('qf-support-contact'));
    expect(contact, findsOneWidget);
    expect(find.text('智能客服'), findsWidgets);
    expect(find.text('系统'), findsOneWidget);
    expect(
      find.descendant(of: contact, matching: find.byType(IconButton)),
      findsNothing,
    );
    expect(
      find.descendant(of: contact, matching: find.text('删除好友')),
      findsNothing,
    );
    final botY = tester.getTopLeft(contact).dy;
    final friendY = tester.getTopLeft(find.text('好友甲')).dy;
    expect(botY, lessThan(friendY));
    expect(find.byTooltip('删除好友'), findsOneWidget);
    expect(find.byKey(const ValueKey('qf-support-desk-entry')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('guest support page asks anonymously, verifies, hands off', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: false);
    session.mode = QfMode.entry;
    await tester.pumpWidget(_wrap(QfSupportPage(session: session)));
    await tester.pump();
    await tester.pump();
    // Anonymous first: the verify card is an optional extra, collapsed.
    expect(
      find.byKey(const ValueKey('qf-support-verify-toggle')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('qf-support-input')),
      '连不上网怎么办',
    );
    await tester.tap(find.byKey(const ValueKey('qf-support-send')));
    await tester.pump();
    await tester.pump();
    expect(session.guestAskCalls.single['text'], '连不上网怎么办');
    expect(session.askCalls, isEmpty);
    // Optional account linking: verify only, never a login.
    await tester.tap(find.byKey(const ValueKey('qf-support-verify-toggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('只核验身份'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('qf-support-verify-account')),
      'tester123',
    );
    await tester.enterText(
      find.byKey(const ValueKey('qf-support-verify-password')),
      'pw123456',
    );
    await tester.tap(find.byKey(const ValueKey('qf-support-verify-submit')));
    await tester.pump();
    await tester.pump();
    expect(session.guestVerifyCall, {
      'account': 'tester123',
      'password': 'pw123456',
    });
    expect(find.byKey(const ValueKey('qf-support-linked')), findsOneWidget);
    expect(session.mode, QfMode.entry);
    // Guest handoff goes through the guest channel too.
    await tester.tap(find.byKey(const ValueKey('qf-support-handoff')));
    await tester.pump();
    await tester.pump();
    expect(session.guestHandoffCalled, isTrue);
    expect(session.handoffCalled, isFalse);
    await _unmount(tester);
  });

  testWidgets('support page renders banner bot tag and resident handoff', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: true);
    await tester.pumpWidget(_wrap(QfSupportPage(session: session)));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('qf-support-banner')), findsOneWidget);
    expect(find.text(QfCopy.supportBanner), findsOneWidget);
    expect(find.text('您好，这里是智能客服。'), findsOneWidget);
    expect(find.text('智能客服'), findsWidgets);
    expect(find.text(QfCopy.supportAutoReplyTag), findsOneWidget);
    expect(find.byKey(const ValueKey('qf-support-handoff')), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('ask answer alternates clarify not-this and handoff flow', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: true);
    session.nextAsk = {
      'action': 'answer',
      'kbId': 'kb-1',
      'text': '请在订阅页面点击更新按钮。',
      'sessionId': 's-1',
      'alternates': [
        {'kbId': 'kb-2', 'label': '节点测速说明'},
      ],
    };
    await tester.pumpWidget(_wrap(QfSupportPage(session: session)));
    await tester.pump();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('qf-support-input')),
      '订阅怎么更新',
    );
    await tester.tap(find.byKey(const ValueKey('qf-support-send')));
    await tester.pump();
    await tester.pump();
    expect(session.askCalls.single['text'], '订阅怎么更新');
    expect(find.text('请在订阅页面点击更新按钮。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('qf-support-option-kb-2')),
      findsOneWidget,
    );
    session.nextAsk = {
      'action': 'clarify',
      'text': '请问您指的是订阅更新还是节点测速？',
      'sessionId': 's-1',
      'options': [
        {'kbId': 'kb-3', 'label': '订阅更新说明'},
      ],
    };
    await tester.tap(find.byKey(const ValueKey('qf-support-option-kb-2')));
    await tester.pump();
    await tester.pump();
    expect(session.askCalls.last['kbId'], 'kb-2');
    expect(find.text('请问您指的是订阅更新还是节点测速？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('qf-support-option-kb-3')),
      findsOneWidget,
    );
    session.nextAsk = {
      'action': 'answer',
      'kbId': 'kb-4',
      'text': '这是顺位候选答案。',
      'sessionId': 's-1',
    };
    await tester.tap(find.byKey(const ValueKey('qf-support-not-this')));
    await tester.pump();
    await tester.pump();
    expect(session.askCalls.last['notThis'], isTrue);
    expect(find.text('这是顺位候选答案。'), findsOneWidget);
    session.nextAsk = {
      'action': 'handoff_offer',
      'text': '如仍未解决，可为您转接人工客服。',
      'sessionId': 's-1',
    };
    await tester.enterText(
      find.byKey(const ValueKey('qf-support-input')),
      '我要找人工',
    );
    await tester.tap(find.byKey(const ValueKey('qf-support-send')));
    await tester.pump();
    await tester.pump();
    expect(find.text('如仍未解决，可为您转接人工客服。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('qf-support-handoff-confirm')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('qf-support-handoff-confirm')));
    await tester.pump();
    await tester.pump();
    expect(session.handoffCalled, isTrue);
    expect(
      find.byKey(const ValueKey('qf-support-handoff-notice')),
      findsOneWidget,
    );
    expect(find.text(session.handoffNoticeText), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('handoff notice falls back when server omits notice', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: true);
    session.handoffNoticeText = '';
    await tester.pumpWidget(_wrap(QfSupportPage(session: session)));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('qf-support-handoff')));
    await tester.pump();
    await tester.pump();
    expect(session.handoffCalled, isTrue);
    expect(find.text(QfCopy.supportHandoffNotice), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('support desk entry hidden when inbox is not reachable', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: true);
    expect(await qfSupportDeskVisible(session), isFalse);
    await tester.pumpWidget(_wrap(QfFriendsPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('qf-support-desk-entry')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('support desk lists tickets replies and closes as agent', (
    tester,
  ) async {
    final session = _FakeSupportSession(loggedIn: true, inboxReachable: true);
    expect(await qfSupportDeskVisible(session), isTrue);
    await tester.pumpWidget(_wrap(QfFriendsPage(session: session)));
    await tester.pumpAndSettle();
    final desk = find.byKey(const ValueKey('qf-support-desk-entry'));
    expect(desk, findsOneWidget);
    await tester.tap(desk);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('用户乙'), findsOneWidget);
    expect(find.text('还是连不上'), findsOneWidget);
    expect(find.text('未读 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('qf-support-ticket-s-9')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('节点连不上'), findsOneWidget);
    expect(find.text('您好，正在为您处理。'), findsOneWidget);
    expect(find.text('人工客服'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('qf-support-reply-input')),
      '请重启应用后再试一次。',
    );
    await tester.tap(find.byKey(const ValueKey('qf-support-reply-send')));
    await tester.pump();
    await tester.pump();
    expect(session.replies, ['请重启应用后再试一次。']);
    await tester.tap(find.byKey(const ValueKey('qf-support-ticket-close')));
    await tester.pump();
    await tester.pump();
    expect(session.closedCalled, isTrue);
    expect(find.text('该客服会话已关闭。'), findsWidgets);
    await _unmount(tester);
  });
}
