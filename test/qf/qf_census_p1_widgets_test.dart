import 'dart:async';

import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_forum.dart';
import 'package:fl_clash/qf/qf_pages2.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:fl_clash/qf/qf_support.dart';
import 'package:fl_clash/qf/qf_update.dart';
import 'package:fl_clash/qf/qf_version.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: child);
}


class _FakeForumSession extends QfSessionController {
  _FakeForumSession() {
    mode = QfMode.user;
    userId = 100;
    username = 'tester123';
  }

  int likeCalls = 0;
  int replyCalls = 0;
  int createCalls = 0;
  Completer<void>? likeGate;
  Completer<void>? replyGate;

  Map<String, dynamic> get _post => {
    'id': 1,
    'title': '测试帖子',
    'content': '帖子内容',
    'board': 'general',
    'author': {'userId': 7, 'name': '作者甲'},
    'replyCount': 1,
    'likeCount': 3,
    'shareCount': 2,
    'viewCount': 9,
    'likedByMe': false,
  };

  @override
  Future<Map<String, dynamic>> forumPostDetail(int id) async {
    return {'post': _post, 'replies': const []};
  }

  @override
  Future<List<dynamic>> forumRewardApplications() async => const [];

  @override
  Future<Map<String, dynamic>> forumLikePost(int postId, bool liked) async {
    likeCalls++;
    await likeGate?.future;
    return {'liked': liked, 'likeCount': liked ? 4 : 3};
  }

  @override
  Future<Map<String, dynamic>> forumCreateReply(
    int postId,
    String content,
  ) async {
    replyCalls++;
    await replyGate?.future;
    return {'status': 'published', 'message': '回复成功'};
  }

  @override
  Future<Map<String, dynamic>> forumCreateCamp({
    required String name,
    required String description,
  }) async {
    createCalls++;
    return {'status': 'active'};
  }
}

class _FakeSupportSession extends QfSessionController {
  _FakeSupportSession() {
    mode = QfMode.user;
    userId = 42;
    username = 'tester123';
  }

  bool askFails = true;
  int askCalls = 0;

  @override
  Future<Map<String, dynamic>> supportSession() async {
    return {'sessionId': 's-1', 'messages': const []};
  }

  @override
  Future<Map<String, dynamic>> supportAsk({
    String? sessionId,
    String? text,
    bool notThis = false,
    String? kbId,
  }) async {
    askCalls++;
    if (askFails) {
      throw const QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');
    }
    return {
      'action': 'answer',
      'kbId': 'kb-1',
      'text': '这是回复。',
      'sessionId': 's-1',
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('C-11 update panel without a package routes to the website', () {
    testWidgets('empty downloadUrl shows the website button only', (
      tester,
    ) async {
      const check = QfUpdateCheck(
        decision: QfUpdateDecision.force,
        manifest: null,
        notes: '更新说明',
        downloadUrl: '',
        latestVersion: '9.9.9',
      );
      await tester.pumpWidget(
        _wrap(
          const Scaffold(body: QfUpdateDownloadPanel(result: check)),
        ),
      );
      expect(find.text('前往官网下载'), findsOneWidget);
      expect(find.text('立即更新'), findsNothing);
    });

    testWidgets('a real downloadUrl keeps the in-app update button', (
      tester,
    ) async {
      const check = QfUpdateCheck(
        decision: QfUpdateDecision.force,
        manifest: null,
        notes: '更新说明',
        downloadUrl: 'http://127.0.0.1:1/QFClash.apk',
        latestVersion: '9.9.9',
      );
      await tester.pumpWidget(
        _wrap(
          const Scaffold(body: QfUpdateDownloadPanel(result: check)),
        ),
      );
      expect(find.text('立即更新'), findsOneWidget);
      expect(find.text('前往官网下载'), findsNothing);
    });
  });

  group('C-44 post detail guards', () {
    testWidgets('double-tapping like fires one request', (tester) async {
      final session = _FakeForumSession();
      session.likeGate = Completer<void>();
      await tester.pumpWidget(
        _wrap(QfForumPostPage(session: session, postId: 1)),
      );
      await tester.pumpAndSettle();
      final likeButton = find.textContaining('点赞');
      expect(likeButton, findsWidgets);
      await tester.tap(likeButton.first);
      await tester.tap(likeButton.first, warnIfMissed: false);
      await tester.pump();
      expect(session.likeCalls, 1);
      session.likeGate!.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('已赞').first);
      await tester.pumpAndSettle();
      expect(session.likeCalls, 2);
    });

    testWidgets('double-tapping reply fires one request', (tester) async {
      final session = _FakeForumSession();
      session.replyGate = Completer<void>();
      await tester.pumpWidget(
        _wrap(QfForumPostPage(session: session, postId: 1)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '一条回复');
      await tester.tap(find.text('回复'));
      await tester.tap(find.text('回复'), warnIfMissed: false);
      await tester.pump();
      expect(session.replyCalls, 1);
      session.replyGate!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('C-45 camp create leaves the form', () {
    testWidgets('successful create pops the form page', (tester) async {
      final session = _FakeForumSession();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => QfCampFormPage(session: session),
                    ),
                  );
                },
                child: const Text('打开表单'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开表单'));
      await tester.pumpAndSettle();
      expect(find.byType(QfCampFormPage), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), '新营地');
      await tester.enterText(find.byType(TextField).at(1), '营地说明');
      await tester.tap(find.text(QfCopy.campCreateSubmit));
      await tester.pumpAndSettle();
      expect(session.createCalls, 1);
      expect(find.byType(QfCampFormPage), findsNothing);
    });
  });

  group('C-48 support send keeps the words on failure', () {
    testWidgets('failed ask restores the composer text', (tester) async {
      final session = _FakeSupportSession();
      await tester.pumpWidget(_wrap(QfSupportPage(session: session)));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('qf-support-input')),
        '节点连不上怎么办',
      );
      await tester.tap(find.byKey(const ValueKey('qf-support-send')));
      await tester.pump();
      await tester.pump();
      expect(session.askCalls, 1);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('qf-support-input')),
      );
      expect(field.controller!.text, '节点连不上怎么办');
      // And a successful retry does clear it.
      session.askFails = false;
      await tester.tap(find.byKey(const ValueKey('qf-support-send')));
      await tester.pump();
      await tester.pump();
      final fieldAfter = tester.widget<TextField>(
        find.byKey(const ValueKey('qf-support-input')),
      );
      expect(fieldAfter.controller!.text, '');
    });
  });
}
