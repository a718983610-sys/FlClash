import 'dart:async';
import 'dart:typed_data';

import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_pages.dart';
import 'qf_session.dart';
import 'qf_social.dart';

/// 帖子/回复的作者名：服务端 postView/replyView 统一回 author:{userId, name}。
String qfForumAuthorName(Map<dynamic, dynamic> raw) {
  final author = raw['author'];
  if (author is Map) return (author['name'] ?? '').toString();
  return '';
}

int qfForumAuthorId(Map<dynamic, dynamic> raw) {
  final author = raw['author'];
  if (author is Map) return (author['userId'] as num?)?.toInt() ?? 0;
  return 0;
}

bool? qfForumAuthorHasAvatar(Map<dynamic, dynamic> raw) {
  final author = raw['author'];
  if (author is Map && author['hasAvatar'] is bool) {
    return author['hasAvatar'] as bool;
  }
  return null;
}

bool qfForumAuthorIsOwner(Map<dynamic, dynamic> raw) {
  final author = raw['author'];
  if (author is Map) {
    return qfUserIsOwner(author) || qfIsOwnerUserId(author['userId']);
  }
  return false;
}

int qfForumCount(Map<dynamic, dynamic> raw, String key) {
  return (raw[key] as num?)?.toInt() ?? 0;
}

String qfForumCountsText(Map<dynamic, dynamic> raw) {
  return '赞 ${qfForumCount(raw, 'likeCount')} · '
      '分享 ${qfForumCount(raw, 'shareCount')} · '
      '浏览 ${qfForumCount(raw, 'viewCount')} · '
      '回复 ${qfForumCount(raw, 'replyCount')}';
}

bool qfForumRewardVisible({
  required Map<dynamic, dynamic> post,
  required int? currentUserId,
}) {
  if (currentUserId == null || currentUserId <= 0) return false;
  if (qfForumAuthorId(post) != currentUserId) return false;
  if (qfForumCount(post, 'likeCount') < 1000) return false;
  final reward = post['reward'];
  return reward is Map && reward['eligible'] == true;
}

String qfForumRewardState(Map<dynamic, dynamic> post) {
  final reward = post['reward'];
  if (reward is Map) return (reward['state'] ?? 'none').toString();
  return 'none';
}

String qfForumRewardStateLabel(String state) {
  return switch (state) {
    'pending' => QfCopy.forumRewardPending,
    'approved' => QfCopy.forumRewardApproved,
    'rejected' => QfCopy.forumRewardRejected,
    _ => '',
  };
}

Map<dynamic, dynamic>? qfForumRewardApplicationFor(
  List<dynamic> applications,
  int postId,
) {
  for (final raw in applications) {
    if (raw is Map && (raw['postId'] as num?)?.toInt() == postId) return raw;
  }
  return null;
}

String qfForumRewardStatusText({
  required String state,
  String rejectReason = '',
}) {
  final label = qfForumRewardStateLabel(state);
  if (label.isEmpty) return '';
  if (state == 'rejected' && rejectReason.isNotEmpty) {
    return '奖励申请状态：$label（$rejectReason）';
  }
  return '奖励申请状态：$label';
}

String qfForumPointsNotice(Map<dynamic, dynamic> result) {
  final points = result['forumPoints'];
  if (points is! Map) return '';
  if (points['granted'] == true) return '本次发布已获得论坛积分。';
  if ((points['reason'] ?? '').toString() == 'already_granted_today') {
    return '今日论坛积分已获得。';
  }
  return '';
}

String qfForumPostLink(String serverBaseUrl, int postId) {
  return '$serverBaseUrl/forum/posts/$postId';
}

List<dynamic> qfForumVisibleBoards(
  List<dynamic> boards, {
  required bool canAnnounce,
}) {
  if (canAnnounce) return boards;
  return [
    for (final raw in boards)
      if (!(raw is Map && (raw['key'] ?? '').toString() == 'announcements'))
        raw,
  ];
}

Map<dynamic, dynamic>? qfCampCreator(Map<dynamic, dynamic> camp) {
  final creator = camp['creator'];
  return creator is Map ? creator : null;
}

int qfCampCreatorId(Map<dynamic, dynamic> camp) {
  final creator = qfCampCreator(camp);
  if (creator == null) return 0;
  return ((creator['userId'] ?? creator['id']) as num?)?.toInt() ?? 0;
}

String qfCampCreatorName(Map<dynamic, dynamic> camp) {
  final creator = qfCampCreator(camp);
  if (creator == null) return '';
  return (creator['displayName'] ??
          creator['name'] ??
          creator['nickname'] ??
          '')
      .toString();
}

bool? qfCampCreatorHasAvatar(Map<dynamic, dynamic> camp) {
  final creator = qfCampCreator(camp);
  if (creator == null) return null;
  if (creator['hasAvatar'] is bool) return creator['hasAvatar'] as bool;
  final avatarUrl = (creator['avatarUrl'] ?? '').toString();
  if (avatarUrl.isNotEmpty) return true;
  return null;
}

bool qfCampIsMine(Map<dynamic, dynamic> camp, int? currentUserId) {
  if (currentUserId == null || currentUserId <= 0) return false;
  return qfCampCreatorId(camp) == currentUserId;
}

String qfCampStatus(Map<dynamic, dynamic> camp) {
  return (camp['status'] ?? 'active').toString();
}

String qfCampStatusLabel(String status) {
  return switch (status) {
    'pending' => QfCopy.campStatusPending,
    'active' => QfCopy.campStatusActive,
    'rejected' => QfCopy.campStatusRejected,
    'closed' => QfCopy.campStatusClosed,
    _ => '',
  };
}

String qfCampCategory(Map<dynamic, dynamic> raw) {
  for (final key in [
    'category',
    'rejectCategory',
    'reasonCategory',
    'closeReasonCategory',
  ]) {
    final value = (raw[key] ?? '').toString();
    if (value.isNotEmpty) return value;
  }
  return '';
}

String qfCampCloseReason(Map<dynamic, dynamic> camp) {
  return (camp['closeReasonCategory'] ?? '').toString();
}

bool qfCampCanDelete(Map<dynamic, dynamic> camp) {
  final status = qfCampStatus(camp);
  return status == 'rejected' || status == 'pending';
}

bool qfCampCanResubmit(Map<dynamic, dynamic> camp) {
  return qfCampStatus(camp) == 'rejected';
}

bool qfCampPendingReview(Map<dynamic, dynamic> camp) {
  if (camp['pendingReview'] == true) return true;
  if (camp['hasPendingReview'] == true) return true;
  if (camp['pendingEdit'] is Map) return true;
  if (camp['pendingChanges'] is Map) return true;
  return (camp['editStatus'] ?? '').toString() == 'pending';
}

class QfCampOutcome {
  final String state;
  final String text;

  const QfCampOutcome(this.state, this.text);
}

QfCampOutcome qfCampCreateOutcome(Map<dynamic, dynamic> result) {
  final status = (result['status'] ?? 'active').toString();
  final message = (result['message'] ?? '').toString();
  if (status == 'pending') {
    return QfCampOutcome(
      'pending',
      message.isNotEmpty ? message : QfCopy.campCreatePending,
    );
  }
  if (status == 'rejected') {
    final category = qfCampCategory(result);
    final text = message.isNotEmpty
        ? message
        : category.isNotEmpty
        ? '${QfCopy.campCreateRejected}：$category'
        : QfCopy.campCreateRejected;
    return QfCampOutcome('rejected', text);
  }
  return QfCampOutcome(
    'active',
    message.isNotEmpty ? message : QfCopy.campCreateActive,
  );
}

QfCampOutcome qfCampCreateErrorOutcome(QfApiException error) {
  final data = error.data;
  if ((data['status'] ?? '').toString() == 'rejected') {
    return qfCampCreateOutcome({...data, 'message': error.message});
  }
  return QfCampOutcome('rejected', error.message);
}

String _qfFormatSec(int sec) {
  final time = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// 访客只读下发帖/回复/举报的登录引导。
Future<void> qfForumGuideLogin(
  BuildContext context,
  QfSessionController session,
) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('登录后即可参与论坛'),
        content: const Text('游客模式下仅可浏览帖子，登录后即可发帖、回复与举报。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续浏览'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去登录'),
          ),
        ],
      );
    },
  );
  if (go == true && session.isGuest) {
    await session.exitGuestToEntry();
  }
}

void qfOpenForumAuthor(
  BuildContext context,
  QfSessionController session,
  Map<dynamic, dynamic> raw,
) {
  final userId = qfForumAuthorId(raw);
  if (userId <= 0) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => QfForumUserPage(session: session, userId: userId),
    ),
  );
}

class QfForumAuthorHeader extends StatelessWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> raw;
  final bool tappable;

  const QfForumAuthorHeader({
    super.key,
    required this.session,
    required this.raw,
    this.tappable = true,
  });

  @override
  Widget build(BuildContext context) {
    final name = qfForumAuthorName(raw);
    return InkWell(
      customBorder: AppShape.md,
      onTap: tappable ? () => qfOpenForumAuthor(context, session, raw) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          QfAvatarImage(
            session: session,
            userId: qfForumAuthorId(raw),
            name: name,
            hasAvatar: qfForumAuthorHasAvatar(raw),
            radius: 14,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: QfBadgedName(name: name, isOwner: qfForumAuthorIsOwner(raw)),
          ),
        ],
      ),
    );
  }
}

class QfForumCountsLine extends StatelessWidget {
  final Map<dynamic, dynamic> raw;

  const QfForumCountsLine({super.key, required this.raw});

  @override
  Widget build(BuildContext context) {
    return Text(qfForumCountsText(raw));
  }
}

/// 帖子列表卡：整卡点击进详情；点赞、评论在卡内直接完成；作者与板块
/// 标签各自处理点击，不触发进详情。与网页版 ui3 的卡片口径一致。
class QfForumPostCard extends StatefulWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> raw;
  final String? boardLabel;
  final VoidCallback? onBoardTap;
  final VoidCallback? onChanged;

  const QfForumPostCard({
    super.key,
    required this.session,
    required this.raw,
    this.boardLabel,
    this.onBoardTap,
    this.onChanged,
  });

  @override
  State<QfForumPostCard> createState() => _QfForumPostCardState();
}

class _QfForumPostCardState extends State<QfForumPostCard> {
  final _reply = TextEditingController();
  bool _replyOpen = false;
  bool _liking = false;
  bool _sending = false;

  int get _postId => (widget.raw['id'] as num?)?.toInt() ?? 0;

  bool get _readOnly => !widget.session.isLoggedIn;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _openDetail() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            QfForumPostPage(session: widget.session, postId: _postId),
      ),
    );
    widget.onChanged?.call();
  }

  Future<void> _toggleLike() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    if (_liking) return;
    final raw = widget.raw;
    final liked = raw['likedByMe'] != true;
    setState(() => _liking = true);
    try {
      final data = await widget.session.forumLikePost(_postId, liked);
      if (mounted) {
        setState(() {
          raw['likedByMe'] = data['liked'] ?? liked;
          raw['likeCount'] =
              (data['likeCount'] as num?)?.toInt() ??
              qfForumCount(raw, 'likeCount');
        });
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  Future<void> _sendReply() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    final content = _reply.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final result = await widget.session.forumCreateReply(_postId, content);
      final status = (result['status'] ?? 'published').toString();
      final message = (result['message'] ?? '回复成功').toString();
      if (status == 'rejected') {
        // 驳回保留输入，改完可直接重发（与详情页口径一致）。
        if (mounted) qfToast(context, message);
        return;
      }
      _reply.clear();
      if (mounted) {
        setState(() => _replyOpen = false);
        if (status == 'published') {
          widget.raw['replyCount'] = qfForumCount(widget.raw, 'replyCount') + 1;
        }
        final notice = qfForumPointsNotice(result);
        qfToast(context, notice.isEmpty ? message : '$message $notice');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.raw;
    final title = (raw['title'] ?? '').toString();
    final content = (raw['content'] ?? '').toString();
    final statusLabel = qfForumStatusLabel(raw);
    final liked = raw['likedByMe'] == true;
    return InkWell(
      customBorder: AppShape.md,
      onTap: _openDetail,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: QfForumAuthorHeader(
                      session: widget.session,
                      raw: raw,
                    ),
                  ),
                ),
                if (widget.boardLabel != null)
                  TextButton(
                    onPressed: widget.onBoardTap,
                    child: Text(widget.boardLabel!),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(title, style: AppTextStyle.body.of(context, emphasized: true)),
            if (content.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.subheadline.of(context),
              ),
            ],
            if (statusLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(statusLabel),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: _liking ? null : _toggleLike,
                  child: Text(
                    liked
                        ? '已赞 ${qfForumCount(raw, 'likeCount')}'
                        : '点赞 ${qfForumCount(raw, 'likeCount')}',
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    if (_readOnly) {
                      await qfForumGuideLogin(context, widget.session);
                      return;
                    }
                    setState(() => _replyOpen = !_replyOpen);
                  },
                  child: Text('评论 ${qfForumCount(raw, 'replyCount')}'),
                ),
                const Spacer(),
                Text(
                  '分享 ${qfForumCount(raw, 'shareCount')} · '
                  '浏览 ${qfForumCount(raw, 'viewCount')}',
                  style: AppTextStyle.caption1.of(context),
                ),
              ],
            ),
            if (_replyOpen) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _reply,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: '写下您的评论'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending ? null : _sendReply,
                    child: const Text('发送'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 加载失败呈现：与空态严格分开，带重试入口（F-03）。
class QfLoadFailure extends StatelessWidget {
  final VoidCallback onRetry;
  final String? message;
  final bool compact;

  const QfLoadFailure({
    super.key,
    required this.onRetry,
    this.message,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(message ?? QfCopy.forumLoadFailed);
    final retry = OutlinedButton(onPressed: onRetry, child: const Text('重试'));
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: text),
            const SizedBox(width: 12),
            retry,
          ],
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [text, const SizedBox(height: 8), retry],
        ),
      ),
    );
  }
}

class QfForumRewardSection extends StatefulWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> post;
  final Map<dynamic, dynamic>? application;

  const QfForumRewardSection({
    super.key,
    required this.session,
    required this.post,
    this.application,
  });

  @override
  State<QfForumRewardSection> createState() => _QfForumRewardSectionState();
}

class _QfForumRewardSectionState extends State<QfForumRewardSection> {
  late String _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _state = qfForumRewardState(widget.post);
  }

  Future<void> _apply() async {
    final rawId = widget.post['id'];
    final postId = rawId is num ? rawId.toInt() : int.tryParse('$rawId');
    if (postId == null) {
      qfToast(context, '数据异常，请刷新后重试。');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.session.forumApplyReward(postId);
      if (mounted) {
        setState(() => _state = 'pending');
        qfToast(context, '奖励申请已经提交，请等待审核');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } catch (_) {
      if (mounted) qfToast(context, '申请失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final application = widget.application;
    final appState = (application?['state'] ?? '').toString();
    final effectiveState = _state != 'none'
        ? _state
        : appState.isNotEmpty
        ? appState
        : _state;
    final rejectReason = (application?['rejectReason'] ?? '').toString();
    if (!qfForumRewardVisible(
      post: widget.post,
      currentUserId: widget.session.userId,
    )) {
      final userId = widget.session.userId;
      final mine =
          userId != null &&
          userId > 0 &&
          qfForumAuthorId(widget.post) == userId;
      final statusText = qfForumRewardStatusText(
        state: effectiveState,
        rejectReason: rejectReason,
      );
      if (mine && statusText.isNotEmpty) {
        return Align(alignment: Alignment.centerLeft, child: Text(statusText));
      }
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(QfCopy.forumRewardExplain),
        const SizedBox(height: 8),
        if (effectiveState == 'none')
          FilledButton(
            onPressed: _busy ? null : _apply,
            child: const Text('申请奖励'),
          )
        else
          Text(
            qfForumRewardStatusText(
              state: effectiveState,
              rejectReason: rejectReason,
            ),
          ),
      ],
    );
  }
}

final _qfCampAvatarCache = <String, Uint8List>{};

/// 营地头像：有头像图时显示图片，否则显示营地名首字占位。
/// 头像地址是服务端给的版本化 URL（换图即换地址），按地址缓存图片字节。
class QfCampAvatar extends StatefulWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> camp;
  final double radius;

  const QfCampAvatar({
    super.key,
    required this.session,
    required this.camp,
    this.radius = 20,
  });

  @override
  State<QfCampAvatar> createState() => _QfCampAvatarState();
}

class _QfCampAvatarState extends State<QfCampAvatar> {
  Uint8List? _bytes;

  String get _avatarUrl => (widget.camp['avatarUrl'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(QfCampAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.camp['avatarUrl'] ?? '').toString() != _avatarUrl) {
      _bytes = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if (widget.camp['hasAvatar'] != true || _avatarUrl.isEmpty) return;
    final cached = _qfCampAvatarCache[_avatarUrl];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    final campId = (widget.camp['id'] as num?)?.toInt();
    if (campId == null) return;
    final bytes = await widget.session.forumCampAvatarBytes(campId);
    if (bytes != null && bytes.isNotEmpty) {
      _qfCampAvatarCache[_avatarUrl] = bytes;
      if (mounted) setState(() => _bytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ?? _qfCampAvatarCache[_avatarUrl];
    if (bytes != null && bytes.isNotEmpty) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundImage: MemoryImage(bytes),
      );
    }
    final name = (widget.camp['name'] ?? '').toString();
    return CircleAvatar(
      radius: widget.radius,
      child: Text(name.isEmpty ? '营' : name.characters.first),
    );
  }
}

class QfForumPage extends StatefulWidget {
  final QfSessionController session;

  const QfForumPage({super.key, required this.session});

  @override
  State<QfForumPage> createState() => _QfForumPageState();
}

class _QfForumPageState extends State<QfForumPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<dynamic> _boards = const [];
  String _board = 'general';
  List<dynamic> _posts = const [];
  bool _loading = true;
  bool _loadingMore = false;
  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _meHome;
  List<dynamic> _rewardApplications = const [];
  Map<String, dynamic>? _analytics;
  List<dynamic> _camps = const [];
  bool _campsExpanded = false;
  bool _meLoading = false;
  bool _analyticsLoading = false;
  bool _boardsFailed = false;
  bool _campsFailed = false;
  bool _postsFailed = false;
  bool _meFailed = false;
  bool _rewardsFailed = false;
  bool _analyticsFailed = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTabChanged);
    _loadBoards();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging || !mounted) return;
    setState(() {});
    if (_tabs.index == 1 || _tabs.index == 2) unawaited(_loadMeHome());
    if (_tabs.index == 3) unawaited(_loadAnalytics());
  }

  bool get _readOnly => !widget.session.isLoggedIn;

  Future<void> _fetchBoards() async {
    try {
      final data = await widget.session.forumBoards();
      final boards = data['boards'];
      if (mounted) {
        setState(() {
          _boards = boards is List ? boards : const [];
          _boardsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _boardsFailed = true);
    }
  }

  Future<void> _fetchCamps() async {
    try {
      final data = await widget.session.forumCamps();
      final camps = data['camps'];
      if (mounted) {
        setState(() {
          _camps = camps is List ? camps : const [];
          _campsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _campsFailed = true);
    }
  }

  Future<void> _loadBoards() async {
    if (!_readOnly) await widget.session.refreshCanAnnounce();
    await _fetchBoards();
    await _fetchCamps();
    if (!_readOnly) {
      try {
        final profile = await widget.session.forumProfile();
        if (mounted) setState(() => _profile = profile);
      } catch (_) {}
    }
    await _loadPosts(reset: true);
  }

  int _postsGen = 0;

  Future<void> _loadPosts({required bool reset}) async {
    // Generation + board guard (C-43): a response for a board the user
    // has already left must never land on the new board's list.
    final gen = ++_postsGen;
    final board = _board;
    final offset = reset ? 0 : _posts.length;
    if (reset) {
      setState(() => _loading = true);
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final data = await widget.session.forumPosts(
        board: board,
        offset: offset,
      );
      final rawPosts = data['posts'];
      final posts = rawPosts is List ? rawPosts : const <dynamic>[];
      if (mounted && gen == _postsGen && board == _board) {
        setState(() {
          if (reset) {
            _posts = posts;
          } else {
            _posts = [..._posts, ...posts];
          }
          _postsFailed = false;
          _loading = false;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted && gen == _postsGen && board == _board) {
        setState(() {
          _postsFailed = true;
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadMeHome() async {
    if (_readOnly || _meLoading) return;
    setState(() => _meLoading = true);
    try {
      final data = await widget.session.forumMeHome();
      if (mounted) {
        setState(() {
          _meHome = data;
          _meFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _meFailed = true);
    }
    try {
      final applications = await widget.session.forumRewardApplications();
      if (mounted) {
        setState(() {
          _rewardApplications = applications;
          _rewardsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _rewardsFailed = true);
    } finally {
      if (mounted) setState(() => _meLoading = false);
    }
  }

  Future<void> _loadAnalytics() async {
    if (_readOnly || _analyticsLoading) return;
    setState(() => _analyticsLoading = true);
    try {
      final data = await widget.session.forumAnalytics();
      if (mounted) {
        setState(() {
          _analytics = data;
          _analyticsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _analyticsFailed = true);
    } finally {
      if (mounted) setState(() => _analyticsLoading = false);
    }
  }

  Future<void> _editNickname() async {
    final controller = TextEditingController(
      text: (_profile?['nickname'] ?? '').toString(),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('论坛昵称'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '昵称'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (saved == true) {
      try {
        await widget.session.forumUpdateNickname(controller.text.trim());
        final profile = await widget.session.forumProfile();
        if (mounted) {
          setState(() => _profile = profile);
          qfToast(context, '昵称已经保存');
        }
      } on QfApiException catch (e) {
        if (mounted) qfToast(context, e.message);
      }
    }
    controller.dispose();
  }

  Future<void> _compose() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    if (_board == 'announcements' && !widget.session.canAnnounce) {
      qfToast(context, QfCopy.forumAnnouncementForbidden);
      return;
    }
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) =>
            _QfComposePostPage(session: widget.session, board: _board),
      ),
    );
    if (message != null && mounted) {
      qfToast(context, message);
      await _loadPosts(reset: true);
    }
  }

  Widget? _muteBanner() {
    final profile = _profile;
    if (profile == null || _readOnly) return null;
    final permanent = profile['mutePermanent'] == true;
    final until = (profile['muteUntil'] as num?)?.toInt();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!permanent && (until == null || until <= nowSec)) return null;
    final text = permanent
        ? '您已被永久禁言，无法在论坛发帖与回复。'
              '如有疑问，请通过意见反馈申诉，或发邮件到 a718983610@gmail.com'
        : '您的论坛发言已被限制，解除时间：${_qfFormatSec(until!)}。'
              '如有疑问，请通过意见反馈申诉，或发邮件到 a718983610@gmail.com';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Text(text),
    );
  }

  Widget _identityHeader() {
    if (_readOnly) {
      return const Padding(
        key: ValueKey('qf-forum-identity'),
        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          children: [
            CircleAvatar(radius: 28, child: Text('?')),
            SizedBox(height: 8),
            Text('未登录'),
          ],
        ),
      );
    }
    final nickname = (_profile?['nickname'] ?? widget.session.username ?? '')
        .toString();
    final displayName = nickname.isEmpty ? '已登录用户' : nickname;
    final accountId = (widget.session.username ?? '').toString();
    return Padding(
      key: const ValueKey('qf-forum-identity'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        children: [
          QfAvatarImage(
            session: widget.session,
            userId: widget.session.userId,
            name: displayName,
            radius: 28,
          ),
          const SizedBox(height: 8),
          Text(displayName),
          if (accountId.isNotEmpty)
            Text(accountId, style: AppTextStyle.caption1.of(context)),
        ],
      ),
    );
  }

  Widget _postTile(Map<dynamic, dynamic> raw) {
    final boardKey = (raw['board'] ?? '').toString();
    String? boardLabel;
    for (final board in _boards) {
      if (board is Map && (board['key'] ?? '').toString() == boardKey) {
        boardLabel = (board['name'] ?? '').toString();
        break;
      }
    }
    return QfForumPostCard(
      session: widget.session,
      raw: raw,
      boardLabel: boardLabel,
      onBoardTap: boardLabel == null
          ? null
          : () {
              if (_board != boardKey) {
                setState(() => _board = boardKey);
                _loadPosts(reset: true);
              }
              if (_tabs.index != 0) _tabs.animateTo(0);
            },
      onChanged: () => _loadPosts(reset: true),
    );
  }

  /// 官方社区的固定呈现顺序（与服务端种子营地的 sort_order 一致）。
  static const List<String> _officialCampKeys = [
    'usage-tips',
    'account-security',
    'points-rewards',
    'support',
    'lounge',
  ];

  bool _isOfficialCamp(Map<dynamic, dynamic> camp) {
    final creator = camp['creator'];
    return creator is Map && creator['userId'] == null;
  }

  List<Map<dynamic, dynamic>> _officialCamps() {
    final list = _camps
        .whereType<Map<dynamic, dynamic>>()
        .where(_isOfficialCamp)
        .toList();
    int rank(Map<dynamic, dynamic> camp) {
      final index = _officialCampKeys.indexOf((camp['key'] ?? '').toString());
      return index < 0 ? _officialCampKeys.length : index;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    return list;
  }

  /// 个人营地沿用服务端返回的人气排序（加入人数→帖子数），此处只过滤不重排。
  List<Map<dynamic, dynamic>> _personalCamps() {
    return _camps
        .whereType<Map<dynamic, dynamic>>()
        .where((camp) => !_isOfficialCamp(camp))
        .toList();
  }

  /// 营地行：头像、名字、加入人数、帖子数四样，点开进营地页。
  Widget _campRow(Map<dynamic, dynamic> camp) {
    final members = (camp['memberCount'] as num?)?.toInt() ?? 0;
    final posts = (camp['postCount'] as num?)?.toInt() ?? 0;
    return ListTile(
      leading: QfCampAvatar(session: widget.session, camp: camp),
      title: Text((camp['name'] ?? '').toString()),
      subtitle: Text('$members 人加入 · $posts 篇帖子'),
      trailing: const GlyphIcon(AppGlyphs.chevronForward),
      onTap: () => _openCamp(camp),
    );
  }

  void _openCampList() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QfForumCampListPage(session: widget.session),
      ),
    );
  }

  void _showCampGuide() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('营地使用方法'),
        content: const Text(
          '营地是按话题划分的社区空间。官方社区由官方维护，个人营地由用户创建。\n\n'
          '· 点开任意营地即可浏览其中的帖子；加入营地后可以在营地内发帖。\n'
          '· 在「全部」里可以按热度查看全部营地。\n'
          '· 登录后可以创建自己的营地，营地名称、简介和头像经审核通过后正式上线；'
          '创建者可以在自己的营地页里修改名称、简介和头像。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _homeTab() {
    final recommended = _camps
        .where((c) => c is Map && c['recommended'] == true)
        .toList();
    final shownCamps = recommended.isNotEmpty ? recommended : _camps;
    final officialCamps = _officialCamps();
    final personalCamps = _personalCamps();
    return ListView(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final raw in qfForumVisibleBoards(
                _boards,
                canAnnounce: widget.session.canAnnounce,
              ))
                if (raw is Map)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text((raw['name'] ?? '').toString()),
                      selected: _board == raw['key'],
                      onSelected: (_) {
                        setState(
                          () => _board = (raw['key'] ?? 'general').toString(),
                        );
                        _loadPosts(reset: true);
                      },
                    ),
                  ),
            ],
          ),
        ),
        if (_boardsFailed && _boards.isEmpty)
          QfLoadFailure(compact: true, onRetry: _fetchBoards),
        if (_campsFailed && _camps.isEmpty)
          QfLoadFailure(compact: true, onRetry: _fetchCamps),
        if (officialCamps.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(alignment: Alignment.centerLeft, child: Text('官方社区')),
          ),
          for (final raw in officialCamps) _campRow(raw),
        ],
        if (personalCamps.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _campsExpanded = !_campsExpanded),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Row(
                      children: [
                        const Text('个人营地'),
                        GlyphIcon(
                          _campsExpanded
                              ? AppGlyphs.chevronUp
                              : AppGlyphs.chevronDown,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton(onPressed: _showCampGuide, child: const Text('使用方法')),
              TextButton(onPressed: _openCampList, child: const Text('全部')),
            ],
          ),
          if (_campsExpanded)
            for (final raw in personalCamps) _campRow(raw),
        ],
        if (shownCamps.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(alignment: Alignment.centerLeft, child: Text('营地热帖')),
          ),
          for (final raw in shownCamps)
            if (raw is Map)
              for (final hot in _campHotPosts(raw))
                if (hot is Map) _postTile(hot),
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CommonCircleLoading.page()),
          )
        else if (_postsFailed && _posts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: QfLoadFailure(onRetry: () => _loadPosts(reset: true)),
          )
        else if (_posts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('暂无帖子')),
          )
        else ...[
          for (final raw in _posts)
            if (raw is Map) _postTile(raw),
          if (_postsFailed)
            QfLoadFailure(
              compact: true,
              onRetry: () => _loadPosts(reset: false),
            )
          else
            TextButton(
              onPressed: _loadingMore ? null : () => _loadPosts(reset: false),
              child: const Text('加载更多'),
            ),
        ],
      ],
    );
  }

  List<dynamic> _campHotPosts(Map<dynamic, dynamic> camp) {
    final hot = camp['hotPosts'];
    return hot is List ? hot : const [];
  }

  void _openCamp(Map<dynamic, dynamic> camp) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QfForumCampPage(
          session: widget.session,
          campId: (camp['id'] as num).toInt(),
        ),
      ),
    );
  }

  Widget _loginNeeded(String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => qfForumGuideLogin(context, widget.session),
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  Widget _myPostsTab() {
    if (_readOnly) return _loginNeeded('登录后即可查看我的帖子');
    if (_meLoading && _meHome == null) {
      return const Center(child: CommonCircleLoading.page());
    }
    if (_meFailed && _meHome == null) {
      return QfLoadFailure(onRetry: _loadMeHome);
    }
    final posts = _meHome?['posts'];
    final list = posts is List ? posts : const <dynamic>[];
    if (list.isEmpty && !_rewardsFailed) {
      return const Center(child: Text('暂无帖子'));
    }
    final listView = ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final raw = list[index];
        if (raw is! Map) return const SizedBox.shrink();
        return Column(
          children: [
            _postTile(raw),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: QfForumRewardSection(
                session: widget.session,
                post: raw,
                application: qfForumRewardApplicationFor(
                  _rewardApplications,
                  (raw['id'] as num).toInt(),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (!_rewardsFailed) return listView;
    return Column(
      children: [
        QfLoadFailure(
          compact: true,
          message: QfCopy.forumRewardStatusFailed,
          onRetry: _loadMeHome,
        ),
        Expanded(child: listView),
      ],
    );
  }

  Widget _myCommentsTab() {
    if (_readOnly) return _loginNeeded('登录后即可查看我的评价');
    if (_meLoading && _meHome == null) {
      return const Center(child: CommonCircleLoading.page());
    }
    if (_meFailed && _meHome == null) {
      return QfLoadFailure(onRetry: _loadMeHome);
    }
    final comments = _meHome?['comments'] ?? _meHome?['replies'];
    final list = comments is List ? comments : const <dynamic>[];
    if (list.isEmpty) return const Center(child: Text('暂无评价'));
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final raw = list[index];
        if (raw is! Map) return const SizedBox.shrink();
        return ListTile(
          title: Text((raw['content'] ?? '').toString()),
          subtitle: Text(
            '${raw['postTitle'] ?? ''}'
            '${qfForumStatusLabel(raw).isEmpty ? '' : '\n${qfForumStatusLabel(raw)}'}'
            '${(raw['modNote'] ?? '').toString().isEmpty ? '' : '\n审核备注：${raw['modNote']}'}',
          ),
          onTap: () {
            final postId = (raw['postId'] as num?)?.toInt();
            if (postId == null) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    QfForumPostPage(session: widget.session, postId: postId),
              ),
            );
          },
        );
      },
    );
  }

  Widget _analyticsTab() {
    if (_readOnly) return _loginNeeded('登录后即可查看数据分析');
    if (_analyticsLoading && _analytics == null) {
      return const Center(child: CommonCircleLoading.page());
    }
    if (_analyticsFailed && _analytics == null) {
      return QfLoadFailure(onRetry: _loadAnalytics);
    }
    final data = _analytics ?? const <String, dynamic>{};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('主题偏好', style: AppTextStyle.headline.of(context)),
        _analyticsNames(data['topTopics']),
        const SizedBox(height: 16),
        Text('常看帖子', style: AppTextStyle.headline.of(context)),
        _analyticsPosts(data['frequentPosts']),
        const SizedBox(height: 16),
        Text('我的统计', style: AppTextStyle.headline.of(context)),
        _analyticsStats(data['myStats']),
        const SizedBox(height: 16),
        Text('推荐帖子', style: AppTextStyle.headline.of(context)),
        _analyticsPosts(data['recommendedPosts']),
        const SizedBox(height: 16),
        Text('推荐营地', style: AppTextStyle.headline.of(context)),
        _analyticsCamps(data['recommendedCamps']),
      ],
    );
  }

  Widget _analyticsNames(dynamic raw) {
    final list = raw is List ? raw : const <dynamic>[];
    if (list.isEmpty) return const Text('暂无数据');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in list)
          Text(
            item is Map
                ? (item['name'] ?? item['topic'] ?? '').toString()
                : item.toString(),
          ),
      ],
    );
  }

  Widget _analyticsPosts(dynamic raw) {
    final list = raw is List ? raw : const <dynamic>[];
    if (list.isEmpty) return const Text('暂无数据');
    return Column(
      children: [
        for (final item in list)
          if (item is Map) _postTile(item),
      ],
    );
  }

  Widget _analyticsStats(dynamic raw) {
    if (raw is! Map) return const Text('暂无数据');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in raw.entries) Text('${entry.key}：${entry.value}'),
      ],
    );
  }

  Widget _analyticsCamps(dynamic raw) {
    final list = raw is List ? raw : const <dynamic>[];
    if (list.isEmpty) return const Text('暂无数据');
    return Column(
      children: [
        for (final item in list)
          if (item is Map)
            ListTile(
              title: Text((item['name'] ?? '').toString()),
              subtitle: Text((item['description'] ?? '').toString()),
              onTap: () => _openCamp(item),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final muteBanner = _muteBanner();
    return Scaffold(
      appBar: AppBar(
        title: const Text('论坛'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => QfForumCampListPage(session: widget.session),
                ),
              );
            },
            child: const Text('营地'),
          ),
          if (!_readOnly)
            TextButton(
              onPressed: _editNickname,
              child: QfBadgedName(
                name: (_profile?['nickname'] ?? '设置昵称').toString(),
                isOwner: qfUserIsOwner(_profile),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _compose,
        icon: const GlyphIcon(AppGlyphs.edit, fill: 1),
        label: Text(_readOnly ? '登录后发帖' : '发帖'),
      ),
      body: Column(
        children: [
          ?muteBanner,
          _identityHeader(),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: const [
              Tab(text: '首页'),
              Tab(text: '我的帖子'),
              Tab(text: '我的评价'),
              Tab(text: '数据分析'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _homeTab(),
                _myPostsTab(),
                _myCommentsTab(),
                _analyticsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QfComposePostPage extends StatefulWidget {
  final QfSessionController session;
  final String board;

  const _QfComposePostPage({required this.session, required this.board});

  @override
  State<_QfComposePostPage> createState() => _QfComposePostPageState();
}

class _QfComposePostPageState extends State<_QfComposePostPage> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  bool _busy = false;
  String? _notice;
  List<dynamic> _camps = const [];
  int? _campId;
  bool _campsFailed = false;

  @override
  void initState() {
    super.initState();
    _loadCamps();
  }

  Future<void> _loadCamps() async {
    try {
      final data = await widget.session.forumCamps();
      final camps = data['camps'];
      if (mounted) {
        setState(() {
          _camps = camps is List ? camps : const [];
          _campsFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _campsFailed = true);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty || _content.text.trim().isEmpty) {
      qfToast(context, '标题与内容不能为空');
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final result = await widget.session.forumCreatePost(
        board: widget.board,
        title: _title.text,
        content: _content.text,
        campId: _campId,
      );
      if (!mounted) return;
      final status = (result['status'] ?? 'published').toString();
      final message = (result['message'] ?? '发布成功').toString();
      if (status == 'rejected') {
        // 驳回不关页：保留原稿，页面内展示审核大类，用户改完可直接重发。
        setState(() => _notice = message);
        qfToast(context, message);
        return;
      }
      final notice = qfForumPointsNotice(result);
      Navigator.of(context).pop(notice.isEmpty ? message : '$message $notice');
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('发布帖子')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_notice != null) ...[
            Text(
              _notice!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<int?>(
            initialValue: _campId,
            decoration: const InputDecoration(labelText: '归属营地（选填）'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('不选择营地')),
              for (final raw in _camps)
                if (raw is Map)
                  DropdownMenuItem<int?>(
                    value: (raw['id'] as num).toInt(),
                    child: Text((raw['name'] ?? '').toString()),
                  ),
            ],
            onChanged: (value) => setState(() => _campId = value),
          ),
          if (_campsFailed) QfLoadFailure(compact: true, onRetry: _loadCamps),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '内容',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('发布'),
          ),
        ],
      ),
    );
  }
}

String qfForumStatusLabel(Map<dynamic, dynamic> post) {
  final status = (post['status'] ?? 'published').toString();
  return switch (status) {
    'pending' => '审核中',
    'rejected' => '未通过（${post['category'] ?? '内容问题'}）',
    _ => '',
  };
}

class QfForumPostPage extends StatefulWidget {
  final QfSessionController session;
  final int postId;

  const QfForumPostPage({
    super.key,
    required this.session,
    required this.postId,
  });

  @override
  State<QfForumPostPage> createState() => _QfForumPostPageState();
}

class _QfForumPostPageState extends State<QfForumPostPage> {
  final _reply = TextEditingController();
  Map<String, dynamic>? _post;
  List<dynamic> _replies = const [];
  List<dynamic> _rewardApplications = const [];
  bool _loading = true;
  bool _failed = false;
  bool _rewardsFailed = false;
  bool _likingPost = false;
  bool _sendingReply = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final data = await widget.session.forumPostDetail(widget.postId);
      var applications = _rewardApplications;
      var rewardsFailed = false;
      if (!widget.session.isGuest && widget.session.isLoggedIn) {
        try {
          applications = await widget.session.forumRewardApplications();
        } catch (_) {
          rewardsFailed = true;
        }
      }
      if (mounted) {
        setState(() {
          _rewardApplications = applications;
          _rewardsFailed = rewardsFailed;
          final post = data['post'];
          final replies = data['replies'];
          _post = post is Map ? Map<String, dynamic>.from(post) : null;
          _replies = replies is List ? replies : const [];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  bool get _readOnly => !widget.session.isLoggedIn;

  Future<void> _sendReply() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    if (_reply.text.trim().isEmpty || _sendingReply) return;
    setState(() => _sendingReply = true);
    try {
      final result = await widget.session.forumCreateReply(
        widget.postId,
        _reply.text,
      );
      final status = (result['status'] ?? 'published').toString();
      final message = (result['message'] ?? '回复成功').toString();
      if (status == 'rejected') {
        // 驳回保留输入并展示审核大类，改完可直接重发。
        if (mounted) qfToast(context, message);
        return;
      }
      _reply.clear();
      if (mounted) {
        final notice = qfForumPointsNotice(result);
        qfToast(context, notice.isEmpty ? message : '$message $notice');
      }
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _sendingReply = false);
    }
  }

  Future<void> _toggleLike() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    final post = _post;
    if (post == null || _likingPost) return;
    final liked = post['likedByMe'] != true;
    setState(() => _likingPost = true);
    try {
      final data = await widget.session.forumLikePost(widget.postId, liked);
      if (mounted) {
        setState(() {
          post['likedByMe'] = data['liked'] ?? liked;
          post['likeCount'] =
              (data['likeCount'] as num?)?.toInt() ??
              qfForumCount(post, 'likeCount');
        });
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _likingPost = false);
    }
  }

  Future<void> _share() async {
    final post = _post;
    if (post == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: qfForumPostLink(widget.session.serverBaseUrl, widget.postId),
      ),
    );
    if (!mounted) return;
    qfToast(context, '帖子链接已经复制');
    try {
      final data = await widget.session.forumSharePost(widget.postId);
      if (mounted) {
        setState(() {
          post['shareCount'] =
              (data['shareCount'] as num?)?.toInt() ??
              qfForumCount(post, 'shareCount');
        });
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _report() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    try {
      await widget.session.forumReport(widget.postId);
      if (mounted) {
        qfToast(context, '举报已经提交');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    return Scaffold(
      appBar: AppBar(
        title: const Text('帖子详情'),
        actions: [
          IconButton(
            onPressed: _report,
            icon: const GlyphIcon(AppGlyphs.gavel),
            tooltip: '举报',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : post == null && _failed
          ? QfLoadFailure(onRetry: _load)
          : post == null
          ? const Center(child: Text('帖子不存在或不可见'))
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        (post['title'] ?? '').toString(),
                        style: AppTextStyle.title3.of(context),
                      ),
                      const SizedBox(height: 8),
                      QfForumAuthorHeader(session: widget.session, raw: post),
                      if (qfForumStatusLabel(post).isNotEmpty)
                        Text(qfForumStatusLabel(post)),
                      if ((post['modNote'] ?? '').toString().isNotEmpty)
                        Text('审核备注：${post['modNote']}'),
                      const SizedBox(height: 12),
                      Text((post['content'] ?? '').toString()),
                      const SizedBox(height: 12),
                      QfForumCountsLine(raw: post),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (post['likedByMe'] == true)
                            FilledButton(
                              onPressed: _likingPost ? null : _toggleLike,
                              child: Text(
                                '已赞 ${qfForumCount(post, 'likeCount')}',
                              ),
                            )
                          else
                            OutlinedButton(
                              onPressed: _likingPost ? null : _toggleLike,
                              child: Text(
                                '点赞 ${qfForumCount(post, 'likeCount')}',
                              ),
                            ),
                          OutlinedButton(
                            onPressed: _share,
                            child: Text(
                              '分享 ${qfForumCount(post, 'shareCount')}',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_rewardsFailed)
                        QfLoadFailure(
                          compact: true,
                          message: QfCopy.forumRewardStatusFailed,
                          onRetry: _load,
                        ),
                      QfForumRewardSection(
                        session: widget.session,
                        post: post,
                        application: qfForumRewardApplicationFor(
                          _rewardApplications,
                          widget.postId,
                        ),
                      ),
                      const Divider(height: 32),
                      for (final raw in _replies)
                        if (raw is Map)
                          ListTile(
                            title: QfForumAuthorHeader(
                              session: widget.session,
                              raw: raw,
                            ),
                            subtitle: Text(
                              '${raw['content'] ?? ''}'
                              '${qfForumStatusLabel(raw).isEmpty ? '' : '\n${qfForumStatusLabel(raw)}'}'
                              '${(raw['modNote'] ?? '').toString().isEmpty ? '' : '\n审核备注：${raw['modNote']}'}',
                            ),
                          ),
                    ],
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _readOnly
                        ? OutlinedButton(
                            onPressed: () =>
                                qfForumGuideLogin(context, widget.session),
                            child: const Text('登录后回复'),
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _reply,
                                  decoration: const InputDecoration(
                                    hintText: '写下您的回复',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _sendingReply ? null : _sendReply,
                                child: const Text('回复'),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

class QfForumUserPage extends StatefulWidget {
  final QfSessionController session;
  final int userId;

  const QfForumUserPage({
    super.key,
    required this.session,
    required this.userId,
  });

  @override
  State<QfForumUserPage> createState() => _QfForumUserPageState();
}

class _QfForumUserPageState extends State<QfForumUserPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.forumUserProfile(widget.userId);
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final user = data?['user'];
    final name = user is Map
        ? (user['name'] ?? user['nickname'] ?? '').toString()
        : '';
    final posts = data?['posts'];
    final comments = data?['comments'] ?? data?['replies'];
    final postList = posts is List ? posts : const <dynamic>[];
    final commentList = comments is List ? comments : const <dynamic>[];
    return Scaffold(
      appBar: AppBar(title: const Text('个人主页')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : data == null && _failed
          ? QfLoadFailure(onRetry: _load)
          : data == null
          ? const Center(child: Text('该用户暂不可见'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Column(
                    children: [
                      QfAvatarImage(
                        session: widget.session,
                        userId: widget.userId,
                        name: name,
                        radius: 28,
                      ),
                      const SizedBox(height: 8),
                      Text(name),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text('帖子', style: AppTextStyle.headline.of(context)),
                if (postList.isEmpty) const Text('暂无帖子'),
                for (final raw in postList)
                  if (raw is Map) ...[
                    QfForumPostCard(
                      session: widget.session,
                      raw: raw,
                      onChanged: _load,
                    ),
                    QfForumRewardSection(session: widget.session, post: raw),
                  ],
                const SizedBox(height: 16),
                Text('评价', style: AppTextStyle.headline.of(context)),
                if (commentList.isEmpty) const Text('暂无评价'),
                for (final raw in commentList)
                  if (raw is Map)
                    ListTile(
                      title: Text((raw['content'] ?? '').toString()),
                      subtitle: Text((raw['postTitle'] ?? '').toString()),
                    ),
              ],
            ),
    );
  }
}

class QfCampCreatorRow extends StatelessWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic> camp;

  const QfCampCreatorRow({
    super.key,
    required this.session,
    required this.camp,
  });

  @override
  Widget build(BuildContext context) {
    if (qfCampCreator(camp) == null) return const SizedBox.shrink();
    final name = qfCampCreatorName(camp);
    return Row(
      children: [
        QfAvatarImage(
          session: session,
          userId: qfCampCreatorId(camp),
          name: name,
          hasAvatar: qfCampCreatorHasAvatar(camp),
          radius: 14,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: QfBadgedName(
            name: name,
            isOwner:
                qfUserIsOwner(qfCampCreator(camp)) ||
                qfIsOwnerUserId(qfCampCreator(camp)?['userId']),
          ),
        ),
        const SizedBox(width: 8),
        Text(QfCopy.campCreatorLabel, style: AppTextStyle.caption1.of(context)),
      ],
    );
  }
}

class QfCampStatusBadge extends StatelessWidget {
  final Map<dynamic, dynamic> camp;

  const QfCampStatusBadge({super.key, required this.camp});

  @override
  Widget build(BuildContext context) {
    final label = qfCampStatusLabel(qfCampStatus(camp));
    if (label.isEmpty) return const SizedBox.shrink();
    return Text(label, style: AppTextStyle.caption1.of(context));
  }
}

class QfCampFormPage extends StatefulWidget {
  final QfSessionController session;
  final Map<dynamic, dynamic>? camp;
  final bool resubmit;

  const QfCampFormPage({
    super.key,
    required this.session,
    this.camp,
    this.resubmit = false,
  });

  bool get isEdit => camp != null && !resubmit;

  @override
  State<QfCampFormPage> createState() => _QfCampFormPageState();
}

class _QfCampFormPageState extends State<QfCampFormPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  bool _busy = false;
  QfCampOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    final camp = widget.camp;
    if (camp != null) {
      _name.text = (camp['name'] ?? '').toString();
      _description.text = (camp['description'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final description = _description.text.trim();
    if (name.isEmpty || description.isEmpty) {
      qfToast(context, QfCopy.campFormRequired);
      return;
    }
    setState(() {
      _busy = true;
      _outcome = null;
    });
    try {
      if (widget.resubmit) {
        final result = await widget.session.forumEditCamp(
          (widget.camp!['id'] as num).toInt(),
          name: name,
          description: description,
        );
        if (!mounted) return;
        final outcome = qfCampCreateOutcome(result);
        setState(() => _outcome = outcome);
        if (outcome.state != 'rejected') {
          qfToast(context, outcome.text);
          Navigator.of(context).pop(true);
        }
        return;
      }
      if (widget.isEdit) {
        await widget.session.forumEditCamp(
          (widget.camp!['id'] as num).toInt(),
          name: name,
          description: description,
        );
        if (!mounted) return;
        qfToast(context, QfCopy.campEditSubmitted);
        Navigator.of(context).pop(true);
        return;
      }
      final result = await widget.session.forumCreateCamp(
        name: name,
        description: description,
      );
      if (!mounted) return;
      final outcome = qfCampCreateOutcome(result);
      setState(() => _outcome = outcome);
      if (outcome.state != 'rejected') {
        // Match the resubmit/edit branches: leave the form on success
        // so the caller refreshes the camp list, and so the form
        // cannot be submitted again to create duplicates (C-45).
        qfToast(context, outcome.text);
        Navigator.of(context).pop(true);
      }
    } on QfApiException catch (e) {
      if (!mounted) return;
      if (widget.isEdit) {
        qfToast(context, e.message);
      } else {
        setState(() => _outcome = qfCampCreateErrorOutcome(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.resubmit
              ? QfCopy.campResubmit
              : widget.isEdit
              ? QfCopy.campEdit
              : QfCopy.campCreate,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: QfCopy.campNameLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: QfCopy.campDescriptionLabel,
              alignLabelWithHint: true,
            ),
          ),
          if (!widget.isEdit) ...[
            const SizedBox(height: 12),
            Text(
              QfCopy.campCreateRules,
              style: AppTextStyle.caption1.of(context),
            ),
          ],
          if (outcome != null) ...[
            const SizedBox(height: 16),
            Text(
              outcome.text,
              key: const ValueKey('qf-camp-outcome'),
              style: outcome.state == 'rejected'
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(
              widget.resubmit
                  ? QfCopy.campResubmitSubmit
                  : widget.isEdit
                  ? QfCopy.campEditSubmit
                  : QfCopy.campCreateSubmit,
            ),
          ),
        ],
      ),
    );
  }
}

class QfMyCampsPage extends StatefulWidget {
  final QfSessionController session;

  const QfMyCampsPage({super.key, required this.session});

  @override
  State<QfMyCampsPage> createState() => _QfMyCampsPageState();
}

class _QfMyCampsPageState extends State<QfMyCampsPage> {
  List<dynamic> _camps = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.forumMyCamps();
      final camps = data['camps'];
      if (mounted) {
        setState(() {
          _camps = camps is List ? camps : const [];
          _loading = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _create() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QfCampFormPage(session: widget.session),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _resubmit(Map<dynamic, dynamic> camp) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QfCampFormPage(
          session: widget.session,
          camp: Map<dynamic, dynamic>.from(camp),
          resubmit: true,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _delete(Map<dynamic, dynamic> camp) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(QfCopy.campDeleteConfirmTitle),
          content: const Text(QfCopy.campDeleteConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(QfCopy.campDelete),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await widget.session.forumDeleteCamp((camp['id'] as num).toInt());
      if (mounted) qfToast(context, QfCopy.campDeleted);
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(QfCopy.campMyCamps),
        actions: [
          TextButton(onPressed: _create, child: const Text(QfCopy.campCreate)),
        ],
      ),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : _camps.isEmpty && _failed
          ? QfLoadFailure(onRetry: _load)
          : _camps.isEmpty
          ? const Center(child: Text(QfCopy.campEmptyMine))
          : ListView.separated(
              itemCount: _camps.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final raw = _camps[index];
                if (raw is! Map) return const SizedBox.shrink();
                final status = qfCampStatus(raw);
                final reason = qfCampCloseReason(raw);
                final memberCount = (raw['memberCount'] as num?)?.toInt();
                return ListTile(
                  title: Text((raw['name'] ?? '').toString()),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((raw['description'] ?? '').toString()),
                      if (memberCount != null)
                        Text('$memberCount${QfCopy.campMemberCountSuffix}'),
                      if (status == 'closed' && reason.isNotEmpty)
                        Text('${QfCopy.campCloseReasonPrefix}$reason'),
                      if (qfCampCanResubmit(raw) || qfCampCanDelete(raw))
                        Wrap(
                          spacing: 8,
                          children: [
                            if (qfCampCanResubmit(raw))
                              TextButton(
                                onPressed: () => _resubmit(raw),
                                child: const Text(QfCopy.campResubmit),
                              ),
                            if (qfCampCanDelete(raw))
                              TextButton(
                                onPressed: () => _delete(raw),
                                child: const Text(QfCopy.campDelete),
                              ),
                          ],
                        ),
                    ],
                  ),
                  trailing: QfCampStatusBadge(camp: raw),
                  onTap: status == 'closed'
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => QfForumCampPage(
                                session: widget.session,
                                campId: (raw['id'] as num).toInt(),
                              ),
                            ),
                          );
                        },
                );
              },
            ),
    );
  }
}

class QfForumCampListPage extends StatefulWidget {
  final QfSessionController session;

  const QfForumCampListPage({super.key, required this.session});

  @override
  State<QfForumCampListPage> createState() => _QfForumCampListPageState();
}

class _QfForumCampListPageState extends State<QfForumCampListPage> {
  List<dynamic> _camps = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.forumCamps();
      final camps = data['camps'];
      if (mounted) {
        setState(() {
          _camps = camps is List ? camps : const [];
          _loading = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  final Set<int> _joiningCampIds = {};

  Future<void> _toggleJoin(Map<dynamic, dynamic> camp) async {
    if (!widget.session.isLoggedIn) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    final rawId = camp['id'];
    final campId = rawId is num ? rawId.toInt() : int.tryParse('$rawId');
    if (campId == null || !_joiningCampIds.add(campId)) return;
    final wasJoined = camp['joined'] == true;
    final joined = !wasJoined;
    try {
      final data = await widget.session.forumJoinCamp(campId, joined);
      if (mounted) {
        setState(() {
          final nowJoined = data['joined'] ?? joined;
          camp['joined'] = nowJoined;
          final serverCount = data['memberCount'];
          if (serverCount is num) {
            camp['memberCount'] = serverCount.toInt();
          } else if (nowJoined != wasJoined) {
            final current = (camp['memberCount'] as num?)?.toInt() ?? 0;
            camp['memberCount'] = nowJoined == true
                ? current + 1
                : (current > 0 ? current - 1 : 0);
          }
        });
        qfToast(context, joined ? '已经加入营地' : '已经退出营地');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      _joiningCampIds.remove(campId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _createCamp() async {
    if (!widget.session.isLoggedIn) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QfCampFormPage(session: widget.session),
      ),
    );
    if (mounted) await _load();
  }

  void _openMyCamps() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QfMyCampsPage(session: widget.session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('营地'),
        actions: [
          TextButton(
            onPressed: _createCamp,
            child: const Text(QfCopy.campCreate),
          ),
          if (widget.session.isLoggedIn)
            TextButton(
              onPressed: _openMyCamps,
              child: const Text(QfCopy.campMyCamps),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : _camps.isEmpty && _failed
          ? QfLoadFailure(onRetry: _load)
          : _camps.isEmpty
          ? const Center(child: Text('暂无营地'))
          : ListView.separated(
              itemCount: _camps.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final raw = _camps[index];
                if (raw is! Map) return const SizedBox.shrink();
                final joined = raw['joined'] == true;
                final members = (raw['memberCount'] as num?)?.toInt() ?? 0;
                final posts = (raw['postCount'] as num?)?.toInt() ?? 0;
                final description = (raw['description'] ?? '').toString();
                return ListTile(
                  leading: QfCampAvatar(session: widget.session, camp: raw),
                  title: Text((raw['name'] ?? '').toString()),
                  subtitle: Text(
                    '${description.isEmpty ? '' : '$description\n'}'
                    '$members 人加入 · $posts 篇帖子',
                  ),
                  trailing: joined
                      ? OutlinedButton(
                          onPressed: _joiningCampIds.contains(
                            (raw['id'] as num?)?.toInt(),
                          )
                              ? null
                              : () => _toggleJoin(raw),
                          child: const Text('已加入'),
                        )
                      : FilledButton(
                          onPressed: _joiningCampIds.contains(
                            (raw['id'] as num?)?.toInt(),
                          )
                              ? null
                              : () => _toggleJoin(raw),
                          child: const Text('加入营地'),
                        ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => QfForumCampPage(
                          session: widget.session,
                          campId: (raw['id'] as num).toInt(),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class QfForumCampPage extends StatefulWidget {
  final QfSessionController session;
  final int campId;

  const QfForumCampPage({
    super.key,
    required this.session,
    required this.campId,
  });

  @override
  State<QfForumCampPage> createState() => _QfForumCampPageState();
}

class _QfForumCampPageState extends State<QfForumCampPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.session.forumCampDetail(widget.campId);
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  bool _joinBusy = false;

  Future<void> _toggleJoin() async {
    if (_joinBusy) return;
    if (!widget.session.isLoggedIn) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    final camp = _camp;
    if (camp == null) return;
    final wasJoined = camp['joined'] == true;
    final joined = !wasJoined;
    setState(() => _joinBusy = true);
    try {
      final data = await widget.session.forumJoinCamp(widget.campId, joined);
      if (mounted) {
        setState(() {
          final nowJoined = data['joined'] ?? joined;
          camp['joined'] = nowJoined;
          final serverCount = data['memberCount'];
          if (serverCount is num) {
            camp['memberCount'] = serverCount.toInt();
          } else if (nowJoined != wasJoined) {
            final current = (camp['memberCount'] as num?)?.toInt() ?? 0;
            camp['memberCount'] = nowJoined == true
                ? current + 1
                : (current > 0 ? current - 1 : 0);
          }
        });
        qfToast(context, joined ? '已经加入营地' : '已经退出营地');
      }
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    } finally {
      if (mounted) setState(() => _joinBusy = false);
    }
  }

  Map<dynamic, dynamic>? get _camp {
    final camp = _data?['camp'];
    return camp is Map ? camp : _data;
  }

  Future<void> _editCamp() async {
    final camp = _camp;
    if (camp == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QfCampFormPage(
          session: widget.session,
          camp: Map<dynamic, dynamic>.from(camp),
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Widget _section(String title, dynamic raw) {
    final list = raw is List ? raw : const <dynamic>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTextStyle.headline.of(context)),
        if (list.isEmpty) const Text('暂无帖子'),
        for (final item in list)
          if (item is Map)
            QfForumPostCard(
              session: widget.session,
              raw: item,
              onChanged: _load,
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final camp = _camp;
    return Scaffold(
      appBar: AppBar(title: const Text('营地详情')),
      body: _loading
          ? const Center(child: CommonCircleLoading.page())
          : camp == null && _failed
          ? QfLoadFailure(onRetry: _load)
          : camp == null
          ? const Center(child: Text('营地暂不可见'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  (camp['name'] ?? '').toString(),
                  style: AppTextStyle.title3.of(context),
                ),
                const SizedBox(height: 8),
                Text((camp['description'] ?? '').toString()),
                if (qfCampCreator(camp) != null) ...[
                  const SizedBox(height: 8),
                  QfCampCreatorRow(session: widget.session, camp: camp),
                ],
                if (qfCampIsMine(camp, widget.session.userId)) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _editCamp,
                    child: const Text(QfCopy.campEdit),
                  ),
                  if (qfCampPendingReview(camp)) ...[
                    const SizedBox(height: 8),
                    const Text(QfCopy.campEditPendingNote),
                  ],
                ],
                const SizedBox(height: 12),
                if (camp['joined'] == true)
                  OutlinedButton(
                    onPressed: _joinBusy ? null : _toggleJoin,
                    child: const Text('已加入'),
                  )
                else
                  FilledButton(
                    onPressed: _joinBusy ? null : _toggleJoin,
                    child: const Text('加入营地'),
                  ),
                const SizedBox(height: 16),
                _section('营地热帖', _data?['hotPosts']),
                const SizedBox(height: 16),
                _section('最新帖子', _data?['latestPosts'] ?? _data?['posts']),
              ],
            ),
    );
  }
}
