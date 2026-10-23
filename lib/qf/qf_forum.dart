import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import 'qf_api.dart';
import 'qf_pages.dart';
import 'qf_session.dart';

/// 帖子/回复的作者名：服务端 postView/replyView 统一回 author:{userId, name}。
String qfForumAuthorName(Map<dynamic, dynamic> raw) {
  final author = raw['author'];
  if (author is Map) return (author['name'] ?? '').toString();
  return '';
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

class QfForumPage extends StatefulWidget {
  final QfSessionController session;

  const QfForumPage({super.key, required this.session});

  @override
  State<QfForumPage> createState() => _QfForumPageState();
}

class _QfForumPageState extends State<QfForumPage> {
  List<dynamic> _boards = const [];
  String _board = 'general';
  List<dynamic> _posts = const [];
  bool _loading = true;
  bool _loadingMore = false;
  Map<String, dynamic>? _profile;

  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  bool get _readOnly => !widget.session.isLoggedIn;

  Future<void> _loadBoards() async {
    try {
      final data = await widget.session.forumBoards();
      final boards = data['boards'];
      if (mounted) {
        setState(() => _boards = boards is List ? boards : const []);
      }
    } catch (_) {}
    if (!_readOnly) {
      try {
        final profile = await widget.session.forumProfile();
        if (mounted) setState(() => _profile = profile);
      } catch (_) {}
    }
    await _loadPosts(reset: true);
  }

  Future<void> _loadPosts({required bool reset}) async {
    if (reset) {
      setState(() => _loading = true);
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final data = await widget.session.forumPosts(
        board: _board,
        offset: reset ? 0 : _posts.length,
      );
      final rawPosts = data['posts'];
      final posts = rawPosts is List ? rawPosts : const <dynamic>[];
      if (mounted) {
        setState(() {
          if (reset) {
            _posts = posts;
          } else {
            _posts = [..._posts, ...posts];
          }
          _loading = false;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
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
    if (_board == 'announcements') {
      qfToast(context, '公告板块仅管理员可以发帖');
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

  @override
  Widget build(BuildContext context) {
    final muteBanner = _muteBanner();
    return Scaffold(
      appBar: AppBar(
        title: const Text('论坛'),
        actions: [
          if (!_readOnly)
            TextButton(
              onPressed: _editNickname,
              child: Text((_profile?['nickname'] ?? '设置昵称').toString()),
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final raw in _boards)
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
          Expanded(
            child: _loading
                ? const Center(child: CommonCircleLoading.page())
                : _posts.isEmpty
                ? const Center(child: Text('暂无帖子'))
                : ListView.separated(
                    itemCount: _posts.length + 1,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == _posts.length) {
                        return TextButton(
                          onPressed: _loadingMore
                              ? null
                              : () => _loadPosts(reset: false),
                          child: const Text('加载更多'),
                        );
                      }
                      final raw = _posts[index];
                      if (raw is! Map) return const SizedBox.shrink();
                      return ListTile(
                        title: Text((raw['title'] ?? '').toString()),
                        subtitle: Text(
                          '${qfForumAuthorName(raw)} · 回复 ${raw['replyCount'] ?? 0}',
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => QfForumPostPage(
                                session: widget.session,
                                postId: (raw['id'] as num).toInt(),
                              ),
                            ),
                          );
                        },
                      );
                    },
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
      Navigator.of(context).pop(message);
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
  bool _loading = true;

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
    try {
      final data = await widget.session.forumPostDetail(widget.postId);
      if (mounted) {
        setState(() {
          final post = data['post'];
          final replies = data['replies'];
          _post = post is Map ? Map<String, dynamic>.from(post) : null;
          _replies = replies is List ? replies : const [];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _readOnly => !widget.session.isLoggedIn;

  Future<void> _sendReply() async {
    if (_readOnly) {
      await qfForumGuideLogin(context, widget.session);
      return;
    }
    if (_reply.text.trim().isEmpty) return;
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
        qfToast(context, message);
      }
      await _load();
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
                      Text(
                        '${qfForumAuthorName(post)}'
                        '${qfForumStatusLabel(post).isEmpty ? '' : ' · ${qfForumStatusLabel(post)}'}',
                      ),
                      const SizedBox(height: 12),
                      Text((post['content'] ?? '').toString()),
                      const Divider(height: 32),
                      for (final raw in _replies)
                        if (raw is Map)
                          ListTile(
                            title: Text(qfForumAuthorName(raw)),
                            subtitle: Text(
                              '${raw['content'] ?? ''}'
                              '${qfForumStatusLabel(raw).isEmpty ? '' : '\n${qfForumStatusLabel(raw)}'}',
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
                                onPressed: _sendReply,
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
