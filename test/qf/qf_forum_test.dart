import 'package:fl_clash/qf/qf_forum.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Map<String, dynamic> _post({
  int id = 1,
  int authorId = 7,
  String authorName = '作者甲',
  int likeCount = 3,
  int shareCount = 2,
  int viewCount = 9,
  bool likedByMe = false,
  Map<String, dynamic>? reward,
}) {
  return {
    'id': id,
    'title': '测试帖子$id',
    'content': '帖子内容$id',
    'board': 'general',
    'author': {'userId': authorId, 'name': authorName},
    'replyCount': 1,
    'likeCount': likeCount,
    'shareCount': shareCount,
    'viewCount': viewCount,
    'likedByMe': likedByMe,
    'reward': ?reward,
  };
}

class _FakeForumSession extends QfSessionController {
  _FakeForumSession({required bool loggedIn, int? currentUserId}) {
    mode = loggedIn ? QfMode.user : QfMode.guest;
    userId = currentUserId;
    username = currentUserId == null ? null : 'tester123';
  }

  List<Map<String, dynamic>> posts = [_post()];
  Map<String, dynamic> detailPost = _post();
  bool? lastLike;

  @override
  Future<Map<String, dynamic>> forumBoards() async {
    return {
      'boards': [
        {'key': 'general', 'name': '综合讨论'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> forumProfile() async {
    return {'nickname': '测试昵称', 'mutePermanent': false, 'muteUntil': null};
  }

  @override
  Future<Map<String, dynamic>> forumPosts({
    String? board,
    int offset = 0,
    int limit = 20,
  }) async {
    return {'posts': offset == 0 ? posts : const []};
  }

  @override
  Future<Map<String, dynamic>> forumCamps() async {
    return {
      'camps': [
        {
          'id': 5,
          'name': '测试营地',
          'description': '营地说明',
          'joined': false,
          'recommended': true,
          'hotPosts': [_post(id: 9)],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> forumMeHome() async {
    return {'posts': posts, 'comments': const []};
  }

  @override
  Future<Map<String, dynamic>> forumAnalytics() async {
    return {
      'topTopics': [
        {'name': '网络'},
      ],
      'frequentPosts': const [],
      'myStats': {'posts': 1},
      'recommendedPosts': const [],
      'recommendedCamps': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> forumPostDetail(int id) async {
    return {'post': detailPost, 'replies': const []};
  }

  @override
  Future<Map<String, dynamic>> forumLikePost(int postId, bool liked) async {
    lastLike = liked;
    return {'likeCount': liked ? 4 : 3, 'liked': liked};
  }

  @override
  Future<Map<String, dynamic>> forumSharePost(int postId) async {
    return {'shareCount': 3};
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(home: child);
}

void main() {
  testWidgets('forum renders four tabs and guest identity header', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: false);
    await tester.pumpWidget(_wrap(QfForumPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的帖子'), findsOneWidget);
    expect(find.text('我的评价'), findsOneWidget);
    expect(find.text('数据分析'), findsOneWidget);
    expect(find.byKey(const ValueKey('qf-forum-identity')), findsOneWidget);
    expect(find.text('未登录'), findsOneWidget);
  });

  testWidgets('forum renders logged-in identity with nickname and account id', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    await tester.pumpWidget(_wrap(QfForumPage(session: session)));
    await tester.pumpAndSettle();
    final identity = find.byKey(const ValueKey('qf-forum-identity'));
    expect(
      find.descendant(of: identity, matching: find.text('测试昵称')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: identity, matching: find.text('tester123')),
      findsOneWidget,
    );
  });

  testWidgets('post list shows like share and view counts', (tester) async {
    final session = _FakeForumSession(loggedIn: false);
    await tester.pumpWidget(_wrap(QfForumPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.textContaining('赞 3'), findsWidgets);
    expect(find.textContaining('分享 2'), findsWidgets);
    expect(find.textContaining('浏览 9'), findsWidgets);
  });

  testWidgets('like button toggles state on post detail', (tester) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 8);
    await tester.pumpWidget(
      _wrap(QfForumPostPage(session: session, postId: 1)),
    );
    await tester.pumpAndSettle();
    expect(find.text('点赞 3'), findsOneWidget);
    await tester.tap(find.text('点赞 3'));
    await tester.pumpAndSettle();
    expect(session.lastLike, isTrue);
    expect(find.text('已赞 4'), findsOneWidget);
  });

  testWidgets('reward entry shows for own post at 1000 likes and eligible', (
    tester,
  ) async {
    final own = _FakeForumSession(loggedIn: true, currentUserId: 7);
    own.detailPost = _post(
      likeCount: 1000,
      reward: {'eligible': true, 'state': 'none'},
    );
    await tester.pumpWidget(_wrap(QfForumPostPage(session: own, postId: 1)));
    await tester.pumpAndSettle();
    expect(find.text('申请奖励'), findsOneWidget);
    expect(find.textContaining('获赞达到 1000'), findsOneWidget);
  });

  testWidgets('reward entry hidden for another author at 1000 likes', (
    tester,
  ) async {
    final other = _FakeForumSession(loggedIn: true, currentUserId: 8);
    other.detailPost = _post(
      likeCount: 1000,
      reward: {'eligible': true, 'state': 'none'},
    );
    await tester.pumpWidget(_wrap(QfForumPostPage(session: other, postId: 1)));
    await tester.pumpAndSettle();
    expect(find.text('申请奖励'), findsNothing);
  });

  testWidgets('reward entry hidden below 1000 likes', (tester) async {
    final below = _FakeForumSession(loggedIn: true, currentUserId: 7);
    below.detailPost = _post(
      likeCount: 999,
      reward: {'eligible': true, 'state': 'none'},
    );
    await tester.pumpWidget(_wrap(QfForumPostPage(session: below, postId: 1)));
    await tester.pumpAndSettle();
    expect(find.text('申请奖励'), findsNothing);
  });

  test(
    'reward visibility helper requires author, threshold and eligibility',
    () {
      final post = _post(
        likeCount: 1000,
        reward: {'eligible': true, 'state': 'none'},
      );
      expect(qfForumRewardVisible(post: post, currentUserId: 7), isTrue);
      expect(qfForumRewardVisible(post: post, currentUserId: 8), isFalse);
      expect(qfForumRewardVisible(post: post, currentUserId: null), isFalse);
      expect(
        qfForumRewardVisible(
          post: _post(likeCount: 1000, reward: {'eligible': false}),
          currentUserId: 7,
        ),
        isFalse,
      );
    },
  );
}
