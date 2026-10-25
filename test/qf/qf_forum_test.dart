import 'package:fl_clash/qf/qf_api.dart';
import 'package:fl_clash/qf/qf_config.dart';
import 'package:fl_clash/qf/qf_forum.dart';
import 'package:fl_clash/qf/qf_session.dart';
import 'package:flutter/services.dart';
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
  List<Map<String, dynamic>> externalPosts = const [];

  @override
  Future<Map<String, dynamic>> forumExternal({int limit = 10}) async {
    return {'posts': externalPosts};
  }

  @override
  Future<Map<String, dynamic>> forumBoards() async {
    final error = boardsError;
    if (error != null) throw error;
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
    final error = postsError;
    if (error != null) throw error;
    return {'posts': offset == 0 ? posts : const []};
  }

  @override
  Future<Map<String, dynamic>> forumCamps() async {
    final campError = campsError;
    if (campError != null) throw campError;
    return {
      'camps': [
        {
          'id': 5,
          'name': '测试营地',
          'description': '营地说明',
          'joined': false,
          'recommended': true,
          'creator': {
            'userId': 7,
            'displayName': '营主甲',
            'avatarUrl': '',
            'hasAvatar': false,
          },
          'hotPosts': [_post(id: 9)],
        },
      ],
    };
  }

  Map<String, dynamic> campDetailData = {
    'camp': {
      'id': 5,
      'name': '测试营地',
      'description': '营地说明',
      'joined': false,
      'creator': {
        'userId': 7,
        'displayName': '营主甲',
        'avatarUrl': '',
        'hasAvatar': false,
      },
    },
    'hotPosts': <dynamic>[],
    'latestPosts': <dynamic>[],
  };
  Map<String, dynamic> createResult = {'status': 'active'};
  QfApiException? createError;
  Map<String, dynamic>? lastCreate;
  Map<String, dynamic> myCampsData = {'camps': <dynamic>[]};
  Map<String, dynamic>? lastEdit;
  List<int> deletedCamps = [];
  List<dynamic> rewardApplicationsData = [];
  Object? boardsError;
  Object? campsError;
  Object? postsError;
  Object? meHomeError;
  Object? rewardsError;
  Object? analyticsError;
  Object? myCampsError;
  Object? campDetailError;
  Object? postDetailError;

  @override
  Future<Map<String, dynamic>> forumCampDetail(int campId) async {
    final error = campDetailError;
    if (error != null) throw error;
    return campDetailData;
  }

  @override
  Future<Map<String, dynamic>> forumCreateCamp({
    required String name,
    required String description,
  }) async {
    lastCreate = {'name': name, 'description': description};
    final error = createError;
    if (error != null) throw error;
    return createResult;
  }

  @override
  Future<Map<String, dynamic>> forumMyCamps() async {
    final error = myCampsError;
    if (error != null) throw error;
    return myCampsData;
  }

  @override
  Future<Map<String, dynamic>> forumEditCamp(
    int campId, {
    String? name,
    String? description,
  }) async {
    lastEdit = {'id': campId, 'name': name, 'description': description};
    return {'ok': true, 'pendingReview': true};
  }

  @override
  Future<Map<String, dynamic>> forumDeleteCamp(int campId) async {
    deletedCamps.add(campId);
    return {'ok': true};
  }

  @override
  Future<List<dynamic>> forumRewardApplications() async {
    final error = rewardsError;
    if (error != null) throw error;
    return rewardApplicationsData;
  }

  @override
  Future<Map<String, dynamic>> forumMeHome() async {
    final error = meHomeError;
    if (error != null) throw error;
    return {'posts': posts, 'comments': const []};
  }

  @override
  Future<Map<String, dynamic>> forumAnalytics() async {
    final error = analyticsError;
    if (error != null) throw error;
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
    final error = postDetailError;
    if (error != null) throw error;
    return {'post': detailPost, 'replies': const []};
  }

  @override
  Future<Map<String, dynamic>> forumLikePost(int postId, bool liked) async {
    lastLike = liked;
    return {'likeCount': liked ? 4 : 3, 'liked': liked};
  }

  final List<({int postId, String text})> repliesSent = [];

  @override
  Future<Map<String, dynamic>> forumCreateReply(
    int postId,
    String content,
  ) async {
    repliesSent.add((postId: postId, text: content));
    return {'status': 'published', 'message': '回复成功'};
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

  testWidgets(
    'announcement post shows a working reply box to a normal logged-in user',
    (tester) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 8);
      session.detailPost = _post()..['board'] = 'announcements';
      await tester.pumpWidget(
        _wrap(QfForumPostPage(session: session, postId: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('回复'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '公告评论测试');
      await tester.tap(find.text('回复'));
      await tester.pumpAndSettle();
      expect(session.repliesSent, [(postId: 1, text: '公告评论测试')]);
    },
  );

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

  test('camp creator helpers parse user camps and ignore seed camps', () {
    final userCamp = {
      'id': 1,
      'creator': {
        'userId': 7,
        'displayName': '营主甲',
        'avatarUrl': 'https://example.invalid/a.png',
      },
    };
    expect(qfCampCreatorId(userCamp), 7);
    expect(qfCampCreatorName(userCamp), '营主甲');
    expect(qfCampCreatorHasAvatar(userCamp), isTrue);
    expect(qfCampIsMine(userCamp, 7), isTrue);
    expect(qfCampIsMine(userCamp, 8), isFalse);
    expect(qfCampIsMine(userCamp, null), isFalse);
    final seed = {'id': 2, 'name': '种子营地'};
    expect(qfCampCreator(seed), isNull);
    expect(qfCampCreatorId(seed), 0);
    expect(qfCampCreatorName(seed), '');
    expect(qfCampIsMine(seed, 7), isFalse);
  });

  test('camp status labels, close reason and pending review parsing', () {
    expect(qfCampStatusLabel('pending'), QfCopy.campStatusPending);
    expect(qfCampStatusLabel('active'), QfCopy.campStatusActive);
    expect(qfCampStatusLabel('rejected'), QfCopy.campStatusRejected);
    expect(qfCampStatusLabel('closed'), QfCopy.campStatusClosed);
    expect(qfCampStatusLabel('unknown'), '');
    expect(qfCampStatus({'name': 'x'}), 'active');
    expect(qfCampCloseReason({'closeReasonCategory': '违规内容聚集'}), '违规内容聚集');
    expect(qfCampPendingReview({'pendingReview': true}), isTrue);
    expect(qfCampPendingReview({'hasPendingReview': true}), isTrue);
    expect(
      qfCampPendingReview({
        'pendingEdit': {'name': '新名'},
      }),
      isTrue,
    );
    expect(qfCampPendingReview({'editStatus': 'pending'}), isTrue);
    expect(qfCampPendingReview({'id': 1}), isFalse);
  });

  test('camp create outcome maps active pending and rejected states', () {
    final active = qfCampCreateOutcome({'status': 'active'});
    expect(active.state, 'active');
    expect(active.text, QfCopy.campCreateActive);
    final pending = qfCampCreateOutcome({'status': 'pending'});
    expect(pending.state, 'pending');
    expect(pending.text, QfCopy.campCreatePending);
    final rejected = qfCampCreateOutcome({
      'status': 'rejected',
      'category': '敏感内容',
    });
    expect(rejected.state, 'rejected');
    expect(rejected.text, contains('敏感内容'));
    final serverMessage = qfCampCreateOutcome({
      'status': 'pending',
      'message': '服务端提示',
    });
    expect(serverMessage.text, '服务端提示');
    final errorOutcome = qfCampCreateErrorOutcome(
      const QfApiException(409, 'NAME_TAKEN', QfCopy.campNameTaken),
    );
    expect(errorOutcome.state, 'rejected');
    expect(errorOutcome.text, QfCopy.campNameTaken);
  });

  testWidgets('camp list shows create and my camps entries when logged in', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    await tester.pumpWidget(_wrap(QfForumCampListPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text(QfCopy.campCreate), findsOneWidget);
    expect(find.text(QfCopy.campMyCamps), findsOneWidget);
    expect(find.text('测试营地'), findsOneWidget);
  });

  testWidgets('camp list guest create entry guides to login', (tester) async {
    final session = _FakeForumSession(loggedIn: false);
    await tester.pumpWidget(_wrap(QfForumCampListPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text(QfCopy.campCreate), findsOneWidget);
    expect(find.text(QfCopy.campMyCamps), findsNothing);
    await tester.tap(find.text(QfCopy.campCreate));
    await tester.pumpAndSettle();
    expect(find.text('登录后即可参与论坛'), findsOneWidget);
    await tester.tap(find.text('继续浏览'));
    await tester.pumpAndSettle();
    expect(find.text('登录后即可参与论坛'), findsNothing);
  });

  Future<void> fillAndSubmitCamp(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), '新营地');
    await tester.enterText(find.byType(TextField).at(1), '营地简介');
    await tester.tap(find.text(QfCopy.campCreateSubmit));
    await tester.pumpAndSettle();
  }

  testWidgets('create camp form shows rules and active outcome', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.createResult = {'status': 'active'};
    await tester.pumpWidget(_wrap(QfCampFormPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text(QfCopy.campCreateRules), findsOneWidget);
    await fillAndSubmitCamp(tester);
    expect(session.lastCreate?['name'], '新营地');
    expect(session.lastCreate?['description'], '营地简介');
    expect(find.text(QfCopy.campCreateActive), findsOneWidget);
  });

  testWidgets('create camp form shows pending outcome', (tester) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.createResult = {'status': 'pending'};
    await tester.pumpWidget(_wrap(QfCampFormPage(session: session)));
    await tester.pumpAndSettle();
    await fillAndSubmitCamp(tester);
    expect(find.text(QfCopy.campCreatePending), findsOneWidget);
  });

  testWidgets('create camp form shows rejected category outcome', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.createResult = {'status': 'rejected', 'category': '敏感内容'};
    await tester.pumpWidget(_wrap(QfCampFormPage(session: session)));
    await tester.pumpAndSettle();
    await fillAndSubmitCamp(tester);
    expect(find.text('未通过审核：敏感内容'), findsOneWidget);
  });

  testWidgets('create camp surfaces server name-taken message verbatim', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.createError = const QfApiException(
      409,
      'NAME_TAKEN',
      QfCopy.campNameTaken,
    );
    await tester.pumpWidget(_wrap(QfCampFormPage(session: session)));
    await tester.pumpAndSettle();
    await fillAndSubmitCamp(tester);
    expect(find.text('该营地名称已被使用。'), findsOneWidget);
  });

  testWidgets('create camp surfaces server limit message verbatim', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.createError = const QfApiException(
      400,
      'CAMP_LIMIT',
      '您创建的营地数量已达上限。',
    );
    await tester.pumpWidget(_wrap(QfCampFormPage(session: session)));
    await tester.pumpAndSettle();
    await fillAndSubmitCamp(tester);
    expect(find.text('您创建的营地数量已达上限。'), findsOneWidget);
  });

  testWidgets('my camps renders every status badge and close reason', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.myCampsData = {
      'camps': [
        {
          'id': 1,
          'name': '待审营地',
          'description': '简介一',
          'status': 'pending',
          'memberCount': 0,
        },
        {
          'id': 2,
          'name': '上线营地',
          'description': '简介二',
          'status': 'active',
          'memberCount': 12,
        },
        {'id': 3, 'name': '被拒营地', 'description': '简介三', 'status': 'rejected'},
        {
          'id': 4,
          'name': '关闭营地',
          'description': '简介四',
          'status': 'closed',
          'closeReasonCategory': '违规内容聚集',
        },
      ],
    };
    await tester.pumpWidget(_wrap(QfMyCampsPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('待审营地'), findsOneWidget);
    expect(find.text(QfCopy.campStatusPending), findsOneWidget);
    expect(find.text(QfCopy.campStatusActive), findsOneWidget);
    expect(find.text(QfCopy.campStatusRejected), findsOneWidget);
    expect(find.text(QfCopy.campStatusClosed), findsOneWidget);
    expect(find.text('12 位成员'), findsOneWidget);
    expect(find.text('关闭原因：违规内容聚集'), findsOneWidget);
  });

  testWidgets('camp detail shows creator row for user camp', (tester) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 8);
    await tester.pumpWidget(
      _wrap(QfForumCampPage(session: session, campId: 5)),
    );
    await tester.pumpAndSettle();
    expect(find.text('营主甲'), findsOneWidget);
    expect(find.text(QfCopy.campCreatorLabel), findsOneWidget);
    expect(find.text(QfCopy.campEdit), findsNothing);
  });

  testWidgets('camp detail hides creator row for seed camp', (tester) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    session.campDetailData = {
      'camp': {'id': 9, 'name': '种子营地', 'description': '官方营地', 'joined': false},
      'hotPosts': <dynamic>[],
      'latestPosts': <dynamic>[],
    };
    await tester.pumpWidget(
      _wrap(QfForumCampPage(session: session, campId: 9)),
    );
    await tester.pumpAndSettle();
    expect(find.text('种子营地'), findsOneWidget);
    expect(find.text(QfCopy.campCreatorLabel), findsNothing);
    expect(find.text(QfCopy.campEdit), findsNothing);
  });

  testWidgets('camp owner edits camp and gets pending-review notice', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    await tester.pumpWidget(
      _wrap(QfForumCampPage(session: session, campId: 5)),
    );
    await tester.pumpAndSettle();
    expect(find.text(QfCopy.campEdit), findsOneWidget);
    await tester.tap(find.text(QfCopy.campEdit));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '测试营地'), findsOneWidget);
    await tester.tap(find.text(QfCopy.campEditSubmit));
    await tester.pumpAndSettle();
    expect(session.lastEdit?['id'], 5);
    expect(session.lastEdit?['name'], '测试营地');
    expect(find.text(QfCopy.campEditSubmitted), findsOneWidget);
    expect(find.byType(QfForumCampPage), findsOneWidget);
  });

  testWidgets('compose camp selector tolerates creator field in camp list', (
    tester,
  ) async {
    final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
    await tester.pumpWidget(_wrap(QfForumPage(session: session)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发帖'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int?>));
    await tester.pumpAndSettle();
    expect(find.text('测试营地'), findsWidgets);
  });

  group('camp delete and resubmit (L-03)', () {
    test('status helpers gate delete and resubmit by camp status', () {
      expect(qfCampCanDelete({'status': 'rejected'}), isTrue);
      expect(qfCampCanDelete({'status': 'pending'}), isTrue);
      expect(qfCampCanDelete({'status': 'active'}), isFalse);
      expect(qfCampCanResubmit({'status': 'rejected'}), isTrue);
      expect(qfCampCanResubmit({'status': 'pending'}), isFalse);
      expect(qfCampCanResubmit({'status': 'active'}), isFalse);
    });

    testWidgets('rejected camp offers resubmit and delete with confirm', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
      session.myCampsData = {
        'camps': [
          {
            'id': 8,
            'name': '被驳营地',
            'description': '旧说明',
            'status': 'rejected',
            'reviewNote': '名称不合规',
          },
        ],
      };
      await tester.pumpWidget(_wrap(QfMyCampsPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.campResubmit), findsOneWidget);
      expect(find.text(QfCopy.campDelete), findsOneWidget);
      await tester.tap(find.text(QfCopy.campDelete));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.campDeleteConfirmBody), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, QfCopy.campDelete));
      await tester.pumpAndSettle();
      expect(session.deletedCamps, [8]);
    });

    testWidgets('pending camp can be deleted but not resubmitted', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
      session.myCampsData = {
        'camps': [
          {'id': 9, 'name': '待审营地', 'description': '说明', 'status': 'pending'},
        ],
      };
      await tester.pumpWidget(_wrap(QfMyCampsPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.campDelete), findsOneWidget);
      expect(find.text(QfCopy.campResubmit), findsNothing);
    });

    testWidgets('resubmit opens edit form and submits through edit', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
      session.myCampsData = {
        'camps': [
          {'id': 8, 'name': '被驳营地', 'description': '旧说明', 'status': 'rejected'},
        ],
      };
      await tester.pumpWidget(_wrap(QfMyCampsPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(QfCopy.campResubmit));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.campResubmitSubmit), findsOneWidget);
      expect(find.widgetWithText(TextField, '被驳营地'), findsOneWidget);
      await tester.tap(find.text(QfCopy.campResubmitSubmit));
      await tester.pumpAndSettle();
      expect(session.lastEdit?['id'], 8);
      expect(session.lastEdit?['name'], '被驳营地');
      expect(find.byType(QfMyCampsPage), findsOneWidget);
    });
  });

  group('announcement board gate (G14) and reward state (G1 forum)', () {
    test('boards without announce permission hide announcements', () {
      const boards = [
        {'key': 'general', 'name': '综合讨论'},
        {'key': 'announcements', 'name': '公告'},
      ];
      expect(qfForumVisibleBoards(boards, canAnnounce: false), hasLength(1));
      expect(qfForumVisibleBoards(boards, canAnnounce: true), hasLength(2));
    });

    test('forum points notice covers granted and already granted', () {
      expect(
        qfForumPointsNotice({
          'forumPoints': {'granted': true, 'reason': 'ok'},
        }),
        '本次发布已获得论坛积分。',
      );
      expect(
        qfForumPointsNotice({
          'forumPoints': {'granted': false, 'reason': 'already_granted_today'},
        }),
        '今日论坛积分已获得。',
      );
      expect(qfForumPointsNotice({}), '');
      expect(
        qfForumPointsNotice({
          'forumPoints': {'granted': false, 'reason': 'other'},
        }),
        '',
      );
    });

    test('reward application lookup and status text', () {
      final applications = [
        {'postId': 3, 'state': 'pending', 'rejectReason': ''},
        {'postId': 4, 'state': 'rejected', 'rejectReason': '内容质量不足'},
        {'postId': 5, 'state': 'approved', 'rejectReason': ''},
      ];
      expect(
        qfForumRewardApplicationFor(applications, 4)?['state'],
        'rejected',
      );
      expect(qfForumRewardApplicationFor(applications, 99), isNull);
      expect(qfForumRewardStatusText(state: 'pending'), '奖励申请状态：审核中');
      expect(qfForumRewardStatusText(state: 'approved'), '奖励申请状态：已发放');
      expect(
        qfForumRewardStatusText(state: 'rejected', rejectReason: '内容质量不足'),
        '奖励申请状态：已驳回（内容质量不足）',
      );
      expect(qfForumRewardStatusText(state: 'unknown'), '');
    });

    testWidgets('post detail shows reward state for own below-threshold post', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7);
      session.detailPost = _post(id: 4, authorId: 7, likeCount: 12);
      session.rewardApplicationsData = [
        {'postId': 4, 'state': 'rejected', 'rejectReason': '内容质量不足'},
      ];
      await tester.pumpWidget(
        _wrap(QfForumPostPage(session: session, postId: 4)),
      );
      await tester.pumpAndSettle();
      expect(find.text('奖励申请状态：已驳回（内容质量不足）'), findsOneWidget);
    });
  });

  group('load failure states stay distinct from empty states (F-03)', () {
    const netError = QfApiException(0, 'NETWORK', '网络连接失败，请检查网络后重试');

    testWidgets('boards failure shows retry and recovers', (tester) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..boardsError = netError;
      await tester.pumpWidget(_wrap(QfForumPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('综合讨论'), findsNothing);
      session.boardsError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      // Board names also appear as tags on post cards, so the recovered
      // board name legitimately shows up more than once.
      expect(find.text('综合讨论'), findsWidgets);
      expect(find.text(QfCopy.forumLoadFailed), findsNothing);
    });

    testWidgets('posts failure is not the empty state', (tester) async {
      final session = _FakeForumSession(loggedIn: false)..postsError = netError;
      await tester.pumpWidget(_wrap(QfForumPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('暂无帖子'), findsNothing);
    });

    testWidgets('empty posts still show the empty state', (tester) async {
      final session = _FakeForumSession(loggedIn: false)..posts = [];
      await tester.pumpWidget(_wrap(QfForumPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text('暂无帖子'), findsOneWidget);
      expect(find.text(QfCopy.forumLoadFailed), findsNothing);
    });

    testWidgets('my posts tab separates me-home failure from empty', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..meHomeError = netError;
      await tester.pumpWidget(_wrap(QfForumPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的帖子'));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('暂无帖子'), findsNothing);
    });

    testWidgets('reward status failure banners on my posts tab', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..rewardsError = netError;
      await tester.pumpWidget(_wrap(QfForumPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的帖子'));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumRewardStatusFailed), findsOneWidget);
    });

    testWidgets('analytics failure shows retry instead of empty data', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..analyticsError = netError;
      await tester.pumpWidget(_wrap(QfForumPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('数据分析'));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('暂无数据'), findsNothing);
    });

    testWidgets('my camps failure shows retry and recovers to empty', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..myCampsError = netError;
      await tester.pumpWidget(_wrap(QfMyCampsPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text(QfCopy.campEmptyMine), findsNothing);
      session.myCampsError = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.campEmptyMine), findsOneWidget);
    });

    testWidgets('camp list failure is not the empty state', (tester) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..campsError = netError;
      await tester.pumpWidget(_wrap(QfForumCampListPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('暂无营地'), findsNothing);
    });

    testWidgets('post detail failure shows retry instead of missing post', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..postDetailError = netError;
      await tester.pumpWidget(
        _wrap(QfForumPostPage(session: session, postId: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('帖子不存在或不可见'), findsNothing);
    });

    testWidgets('camp detail failure shows retry instead of invisible', (
      tester,
    ) async {
      final session = _FakeForumSession(loggedIn: true, currentUserId: 7)
        ..campDetailError = netError;
      await tester.pumpWidget(
        _wrap(QfForumCampPage(session: session, campId: 5)),
      );
      await tester.pumpAndSettle();
      expect(find.text(QfCopy.forumLoadFailed), findsOneWidget);
      expect(find.text('营地暂不可见'), findsNothing);
    });

    testWidgets(
      'home shows the external picks section with web-identical elements '
      'and opens the source url',
      (tester) async {
        const launcherChannel = MethodChannel(
          'plugins.flutter.io/url_launcher',
        );
        String? launched;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcherChannel,
          (call) async {
            if (call.method == 'launch') {
              launched = (call.arguments as Map)['url']?.toString();
              return true;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger
              .setMockMethodCallHandler(launcherChannel, null),
        );
        final session = _FakeForumSession(loggedIn: false)
          ..externalPosts = [
            {
              'id': 3,
              'platform': 'sspai',
              'title': '精选文章标题',
              'summary': '精选摘要',
              'url': 'https://example.com/post/3',
              'author_name': '原作者甲',
              'published_at': 1760000000,
              'released_at': 1760000100,
            },
          ];
        await tester.pumpWidget(_wrap(QfForumPage(session: session)));
        await tester.pumpAndSettle();
        for (var i = 0; i < 4 && find.text('外站精选').evaluate().isEmpty; i++) {
          await tester.drag(
            find.byType(ListView).first,
            const Offset(0, -500),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('外站精选'), findsOneWidget);
        expect(find.text('精选 · 少数派'), findsOneWidget);
        expect(find.text('精选文章标题'), findsOneWidget);
        expect(find.text('精选摘要'), findsOneWidget);
        await tester.tap(find.text('精选文章标题'));
        await tester.pumpAndSettle();
        expect(launched, 'https://example.com/post/3');
      },
    );
  });
}
