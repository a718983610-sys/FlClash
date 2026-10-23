import 'package:flutter/material.dart';

import 'qf_api.dart';
import 'qf_pages.dart';
import 'qf_session.dart';

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

  Future<void> _loadBoards() async {
    try {
      final data = await widget.session.forumBoards();
      final boards = data['boards'];
      final profile = await widget.session.forumProfile();
      if (mounted) {
        setState(() {
          _boards = boards is List ? boards : const [];
          _profile = profile;
        });
      }
    } catch (_) {}
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
    if (_board == 'announcements') {
      qfToast(context, '公告板块仅管理员可以发帖');
      return;
    }
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _QfComposePostPage(
          session: widget.session,
          board: _board,
        ),
      ),
    );
    if (posted == true) {
      await _loadPosts(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = _profile?['muted'] == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('论坛'),
        actions: [
          TextButton(
            onPressed: _editNickname,
            child: Text((_profile?['nickname'] ?? '设置昵称').toString()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _compose,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('发帖'),
      ),
      body: Column(
        children: [
          if (muted)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('您当前处于禁言状态，暂时无法发帖与回复。'),
            ),
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
                            () => _board = (raw['key'] ?? 'general')
                                .toString(),
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
                ? const Center(child: CircularProgressIndicator())
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
                          '${raw['authorName'] ?? ''} · 回复 ${raw['replyCount'] ?? 0}',
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
    setState(() => _busy = true);
    try {
      final result = await widget.session.forumCreatePost(
        board: widget.board,
        title: _title.text,
        content: _content.text,
      );
      if (mounted) {
        final message = (result['message'] ?? '发布成功').toString();
        Navigator.of(context).pop(true);
        qfToast(context, message);
      }
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

  Future<void> _sendReply() async {
    if (_reply.text.trim().isEmpty) return;
    try {
      final result = await widget.session.forumCreateReply(
        widget.postId,
        _reply.text,
      );
      _reply.clear();
      if (mounted) {
        qfToast(context, (result['message'] ?? '回复成功').toString());
      }
      await _load();
    } on QfApiException catch (e) {
      if (mounted) qfToast(context, e.message);
    }
  }

  Future<void> _report() async {
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
            icon: const Icon(Icons.flag_outlined),
            tooltip: '举报',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
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
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${post['authorName'] ?? ''}'
                        '${qfForumStatusLabel(post).isEmpty ? '' : ' · ${qfForumStatusLabel(post)}'}',
                      ),
                      const SizedBox(height: 12),
                      Text((post['content'] ?? '').toString()),
                      const Divider(height: 32),
                      for (final raw in _replies)
                        if (raw is Map)
                          ListTile(
                            title: Text((raw['authorName'] ?? '').toString()),
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
                    child: Row(
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
