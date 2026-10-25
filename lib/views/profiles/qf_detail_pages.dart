import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:fl_clash/views/profiles/custom/custom.dart';
import 'package:fl_clash/views/profiles/edit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Small trailing "i" affordance that opens a detail page. Uses the
/// standard info glyph at a restrained size, vertically centered, with a
/// compact but adequate tap target that does not stretch the row height.
class QfInfoButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String tooltip;

  const QfInfoButton({
    super.key,
    required this.onPressed,
    this.tooltip = '详情',
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 19,
      padding: const EdgeInsets.all(6),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: GlyphIcon(
        AppGlyphs.info,
        size: 19,
        color: context.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

String _formatDateTime(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

void _copied(BuildContext context, String what) {
  context.showNotifier('$what已复制。', level: MessageLevel.success);
}

Future<void> _showShareText(BuildContext context, String title, String text) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SelectableText(text),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
              _copied(dialogContext, title);
            }
          },
          child: const Text('复制'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// Read-only detail page for one subscription (profile). Opened from the
/// info button on the profile row; the row tap itself keeps selecting.
class QfProfileDetailPage extends ConsumerStatefulWidget {
  final int profileId;

  const QfProfileDetailPage({super.key, required this.profileId});

  @override
  ConsumerState<QfProfileDetailPage> createState() =>
      _QfProfileDetailPageState();
}

class _QfProfileDetailPageState extends ConsumerState<QfProfileDetailPage> {
  bool _updating = false;

  Profile? get _profile {
    final profiles = ref.watch(profilesProvider);
    for (final profile in profiles) {
      if (profile.id == widget.profileId) return profile;
    }
    return null;
  }

  Future<void> _updateNow(Profile profile) async {
    if (_updating || profile.type != ProfileType.url) return;
    setState(() => _updating = true);
    try {
      await ref
          .read(profilesActionProvider.notifier)
          .updateProfile(profile, showLoading: true);
      if (mounted) context.showNotifier('订阅已更新。', level: MessageLevel.success);
    } catch (e) {
      if (mounted) {
        context.showNotifier('更新失败：${compactError(e)}', level: MessageLevel.error);
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _exportFile(Profile profile) async {
    final res = await globalState.safeRun<bool>(() async {
      final file = await profile.file;
      final value = await picker.saveFile(
        profile.exportFileName,
        file.readAsBytesSync(),
      );
      return value != null;
    }, title: '提示');
    if (res == true && mounted) {
      context.showNotifier('导出成功。', level: MessageLevel.success);
    }
  }

  Future<void> _delete(Profile profile) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    final users = await profilesAction.providerUsers(profile);
    if (!mounted) return;
    final res = await dialogs.showMessage(
      title: '提示',
      message: TextSpan(
        text: users.isEmpty
            ? '确定要删除这个订阅吗？删除后无法恢复。'
            : '该订阅正被 ${users.map((item) => item.realLabel).join('、')} 使用，确定要删除吗？',
      ),
      destructive: true,
      confirmText: '删除',
    );
    if (res != true) return;
    await profilesAction.deleteProfile(profile.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _editInterval(Profile profile) async {
    final controller = TextEditingController(
      text: profile.autoUpdateDuration.inMinutes.toString(),
    );
    final minutes = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('自动更新间隔'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '间隔（分钟）',
            hintText: '例如 1440 表示每天一次',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(int.tryParse(controller.text.trim())),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (minutes == null || minutes <= 0) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(autoUpdateDuration: Duration(minutes: minutes)));
  }

  Widget _field(BuildContext context, String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: AppTextStyle.footnote.of(context).toLighter,
            ),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext context, {
    required Glyph glyph,
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    return ListTile(
      leading: GlyphIcon(
        glyph,
        size: 20,
        color: danger ? context.colorScheme.error : null,
      ),
      title: Text(
        label,
        style: danger
            ? TextStyle(color: context.colorScheme.error)
            : null,
      ),
      trailing: danger
          ? null
          : GlyphIcon(AppGlyphs.chevronForward, size: 18),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    if (profile == null) {
      return const Scaffold(body: Center(child: Text('该订阅已不存在。')));
    }
    final isCurrent =
        ref.watch(currentProfileIdProvider) == profile.id;
    final isUrl = profile.type == ProfileType.url;
    final isCustom = profile.type == ProfileType.custom;
    final info = isUrl ? profile.subscriptionInfo : null;
    final typeLabel = switch (profile.type) {
      ProfileType.url => '远程订阅',
      ProfileType.file => '本地文件',
      ProfileType.custom => '自定义订阅',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('订阅详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  profile.realLabel,
                  style: AppTextStyle.title1.of(context, emphasized: true),
                ),
              ),
              if (isCurrent)
                const Chip(label: Text('当前使用'), visualDensity: VisualDensity.compact),
            ],
          ),
          const SizedBox(height: 12),
          _field(
            context,
            '名称',
            Row(
              children: [
                Expanded(child: Text(profile.realLabel)),
                IconButton(
                  tooltip: '修改名称',
                  iconSize: 18,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  icon: GlyphIcon(AppGlyphs.edit, size: 18),
                  onPressed: () => renameProfile(context, ref, profile),
                ),
              ],
            ),
          ),
          _field(context, '类型', Text(typeLabel)),
          _field(
            context,
            '上次更新',
            Text(
              profile.lastUpdateDate == null
                  ? '尚未更新'
                  : _formatDateTime(profile.lastUpdateDate!),
            ),
          ),
          if (isUrl)
            _field(
              context,
              '订阅地址',
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: SelectableText(profile.url)),
                  IconButton(
                    tooltip: '复制订阅地址',
                    iconSize: 18,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    icon: GlyphIcon(AppGlyphs.copy, size: 18),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: profile.url),
                      );
                      if (context.mounted) _copied(context, '订阅地址');
                    },
                  ),
                ],
              ),
            ),
          if (info != null && info.usage != null)
            _field(
              context,
              '流量',
              Text(
                '已用 ${(info.upload + info.download).traffic.show} / '
                '共 ${info.total.traffic.show}'
                '${info.expire > 0 && info.expireDate != null ? '，到期 ${_formatDateTime(info.expireDate!)}' : ''}',
              ),
            ),
          if (isUrl) ...[
            const Divider(height: 24),
            SwitchListTile(
              title: const Text('自动更新'),
              subtitle: Text('每 ${profile.autoUpdateDuration.inMinutes} 分钟检查一次'),
              value: profile.autoUpdate,
              onChanged: (value) {
                ref
                    .read(profilesProvider.notifier)
                    .put(profile.copyWith(autoUpdate: value));
              },
            ),
            ListTile(
              title: const Text('自动更新间隔'),
              subtitle: Text('${profile.autoUpdateDuration.inMinutes} 分钟'),
              trailing: GlyphIcon(AppGlyphs.chevronForward, size: 18),
              onTap: () => _editInterval(profile),
            ),
          ],
          const Divider(height: 24),
          if (!isCurrent)
            _action(
              context,
              glyph: AppGlyphs.checkCircle,
              label: '使用此订阅',
              onTap: () {
                ref.read(currentProfileIdProvider.notifier).value = profile.id;
                context.showNotifier('已切换到此订阅。', level: MessageLevel.success);
              },
            ),
          if (isUrl)
            _action(
              context,
              glyph: AppGlyphs.sync,
              label: _updating ? '正在更新…' : '立即更新',
              onTap: _updating ? null : () => _updateNow(profile),
            ),
          if (isUrl)
            _action(
              context,
              glyph: AppGlyphs.copy,
              label: '复制订阅链接',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: profile.url));
                if (context.mounted) _copied(context, '订阅链接');
              },
            ),
          if (isUrl)
            _action(
              context,
              glyph: AppGlyphs.link,
              label: '分享链接',
              onTap: () => _showShareText(context, '订阅链接', profile.url),
            ),
          if (!isCustom)
            _action(
              context,
              glyph: AppGlyphs.export,
              label: '导出配置文件',
              onTap: () => _exportFile(profile),
            ),
          _action(
            context,
            glyph: AppGlyphs.edit,
            label: isCustom ? '编辑节点与分组' : '编辑订阅',
            onTap: () {
              if (isCustom) {
                BaseNavigator.push(
                  context,
                  CustomProfileView(profileId: profile.id),
                );
              } else {
                showExtend(
                  context,
                  builder: (_) => EditProfileView(profile: profile),
                );
              }
            },
          ),
          _action(
            context,
            glyph: AppGlyphs.delete,
            label: '删除订阅',
            danger: true,
            onTap: () => _delete(profile),
          ),
        ],
      ),
    );
  }
}

/// One display row of a proxy definition, produced by
/// [qfProxyDetailFields] in a stable, human-first order.
typedef QfProxyField = ({String label, String value, bool secret});

const _qfKnownFieldOrder = <String>[
  'name',
  'type',
  'server',
  'port',
  'cipher',
  'password',
  'uuid',
  'alterId',
  'network',
  'tls',
  'servername',
  'sni',
  'skip-cert-verify',
  'udp',
  'flow',
  'fingerprint',
  'alpn',
  'obfs',
  'ports',
  'plugin',
  'up',
  'down',
];

String _qfFieldLabel(String key) => switch (key) {
  'name' => '名称',
  'type' => '类型',
  'server' => '服务器',
  'port' => '端口',
  'cipher' => '加密算法',
  'password' => '密码',
  'uuid' => 'UUID',
  'alterId' => 'alterId',
  'network' => '传输协议',
  'tls' => 'TLS',
  'servername' => '服务器名称（SNI）',
  'sni' => 'SNI',
  'skip-cert-verify' => '跳过证书验证',
  'udp' => 'UDP',
  'flow' => '流控',
  'fingerprint' => '客户端指纹',
  'alpn' => 'ALPN',
  'obfs' => '混淆',
  'ports' => '端口跳跃',
  'plugin' => '插件',
  'up' => '上行带宽',
  'down' => '下行带宽',
  _ => key,
};

String _qfFieldValue(String key, Object? value) {
  if (value is bool) {
    return switch (key) {
      'skip-cert-verify' => value ? '是' : '否',
      'tls' || 'udp' => value ? '开启' : '关闭',
      _ => value ? '是' : '否',
    };
  }
  if (value is List) {
    final scalars = value.where((item) => item is! Map && item is! List);
    if (scalars.length == value.length) {
      return value.map((item) => '$item').join(', ');
    }
    return jsonEncode(value);
  }
  if (value is Map) return jsonEncode(value);
  return '$value';
}

/// Flattens a proxy definition into display rows: known fields first in
/// product order (password masked unless [revealSecrets]), nested option
/// maps as compact JSON, and any remaining keys in their original order.
List<QfProxyField> qfProxyDetailFields(
  Map<String, dynamic> definition, {
  required bool revealSecrets,
}) {
  final rows = <QfProxyField>[];
  final used = <String>{};
  void add(String key) {
    if (!definition.containsKey(key)) return;
    used.add(key);
    final value = definition[key];
    if (value == null) return;
    final secret = key == 'password';
    rows.add((
      label: _qfFieldLabel(key),
      value: secret && !revealSecrets && '$value'.isNotEmpty
          ? '••••••'
          : _qfFieldValue(key, value),
      secret: secret,
    ));
  }

  for (final key in _qfKnownFieldOrder) {
    add(key);
  }
  for (final key in definition.keys) {
    if (!used.contains(key)) add(key);
  }
  return rows;
}

Future<Map<String, dynamic>?> qfLoadProxyDefinition({
  required Profile profile,
  required String proxyName,
  required Future<List<CustomProxy>> Function() loadCustomProxies,
}) async {
  if (profile.type == ProfileType.custom) {
    final proxies = await loadCustomProxies();
    for (final proxy in proxies) {
      if (proxy.definition['name']?.toString() == proxyName) {
        return Map<String, dynamic>.from(proxy.definition);
      }
    }
    return null;
  }
  final file = await profile.file;
  if (!await file.exists()) return null;
  final plain = loadPlainYaml(await file.readAsString());
  if (plain is! Map) return null;
  final list = plain['proxies'];
  if (list is! List) return null;
  for (final item in list) {
    if (item is Map && item['name']?.toString() == proxyName) {
      return {
        for (final entry in item.entries)
          entry.key.toString(): entry.value,
      };
    }
  }
  return null;
}

/// Read-only parameter page for a single node, mirroring the reference
/// client's node detail: address, port, cipher, credentials (masked with
/// a reveal toggle) and the protocol-specific options.
class QfProxyDetailPage extends ConsumerStatefulWidget {
  final int profileId;
  final String proxyName;
  final bool isCustom;

  const QfProxyDetailPage({
    super.key,
    required this.profileId,
    required this.proxyName,
    required this.isCustom,
  });

  @override
  ConsumerState<QfProxyDetailPage> createState() => _QfProxyDetailPageState();
}

class _QfProxyDetailPageState extends ConsumerState<QfProxyDetailPage> {
  Map<String, dynamic>? _definition;
  bool _loading = true;
  bool _reveal = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles = ref.read(profilesProvider);
      Profile? profile;
      for (final item in profiles) {
        if (item.id == widget.profileId) profile = item;
      }
      if (profile == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final definition = await qfLoadProxyDefinition(
        profile: profile,
        proxyName: widget.proxyName,
        loadCustomProxies: () async {
          final state = await ref.read(
            setupStateProvider(widget.profileId).future,
          );
          return state.appProxies;
        },
      );
      if (mounted) {
        setState(() {
          _definition = definition;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _shareLink() async {
    final definition = _definition;
    if (definition == null) return;
    try {
      final links = await ref
          .read(coreHandlerProvider)
          .encodeShareLinks([definition]);
      if (!mounted) return;
      if (links.isEmpty) {
        context.showNotifier('这个节点暂时无法生成分享链接。', level: MessageLevel.warning);
        return;
      }
      await _showShareText(context, '节点分享链接', links.first);
    } catch (_) {
      if (mounted) {
        context.showNotifier('分享链接生成失败。', level: MessageLevel.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final definition = _definition;
    return Scaffold(
      appBar: AppBar(title: const Text('节点详情')),
      body: _loading
          ? const Center(child: CommonCircleLoading())
          : definition == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '「${widget.proxyName}」的参数不在订阅文件里'
                  '（可能由节点提供商动态下发），暂时无法查看详细参数。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  widget.proxyName,
                  style: AppTextStyle.title1.of(context, emphasized: true),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.isCustom
                      ? '手动添加的节点，参数以这里为准，可在自定义订阅里修改。'
                      : '订阅节点为只读，参数来自订阅文件，刷新订阅后会被覆盖。',
                  style: AppTextStyle.footnote.of(context).toLighter,
                ),
                const SizedBox(height: 12),
                for (final field in qfProxyDetailFields(
                  definition,
                  revealSecrets: _reveal,
                ))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            field.label,
                            style: AppTextStyle.footnote
                                .of(context)
                                .toLighter,
                          ),
                        ),
                        Expanded(child: SelectableText(field.value)),
                        if (field.secret)
                          IconButton(
                            tooltip: _reveal ? '隐藏密码' : '显示密码',
                            iconSize: 18,
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            icon: GlyphIcon(
                              _reveal ? AppGlyphs.eyeOff : AppGlyphs.eye,
                              size: 18,
                            ),
                            onPressed: () =>
                                setState(() => _reveal = !_reveal),
                          ),
                      ],
                    ),
                  ),
                const Divider(height: 24),
                ListTile(
                  leading: GlyphIcon(AppGlyphs.copy, size: 20),
                  title: const Text('复制节点配置'),
                  trailing: GlyphIcon(AppGlyphs.chevronForward, size: 18),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: const JsonEncoder.withIndent(
                          '  ',
                        ).convert(definition),
                      ),
                    );
                    if (context.mounted) _copied(context, '节点配置');
                  },
                ),
                ListTile(
                  leading: GlyphIcon(AppGlyphs.link, size: 20),
                  title: const Text('分享链接'),
                  trailing: GlyphIcon(AppGlyphs.chevronForward, size: 18),
                  onTap: _shareLink,
                ),
                if (widget.isCustom)
                  ListTile(
                    leading: GlyphIcon(AppGlyphs.edit, size: 20),
                    title: const Text('编辑节点'),
                    trailing: GlyphIcon(AppGlyphs.chevronForward, size: 18),
                    onTap: () {
                      BaseNavigator.push(
                        context,
                        CustomProfileView(profileId: widget.profileId),
                      );
                    },
                  ),
              ],
            ),
    );
  }
}
