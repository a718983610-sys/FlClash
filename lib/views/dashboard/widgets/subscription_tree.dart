import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/profiles/add.dart';
import 'package:fl_clash/views/profiles/qf_detail_pages.dart';
import 'package:fl_clash/views/proxies/card.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import 'card.dart';

/// Expansion state of the subscription tree. A big group, once opened by
/// hand, stays open until it is closed by hand again; picking a node or
/// leaving and returning never folds it. Persisted so the choice also
/// survives a restart.
class QfSubscriptionTreeState {
  const QfSubscriptionTreeState({
    this.rootExpanded = true,
    this.expandedProfiles = const {},
    this.expandedGroups = const {},
  });

  final bool rootExpanded;
  final Set<int> expandedProfiles;
  final Set<String> expandedGroups;

  QfSubscriptionTreeState copyWith({
    bool? rootExpanded,
    Set<int>? expandedProfiles,
    Set<String>? expandedGroups,
  }) {
    return QfSubscriptionTreeState(
      rootExpanded: rootExpanded ?? this.rootExpanded,
      expandedProfiles: expandedProfiles ?? this.expandedProfiles,
      expandedGroups: expandedGroups ?? this.expandedGroups,
    );
  }
}

class QfSubscriptionTreeNotifier extends Notifier<QfSubscriptionTreeState> {
  static const _prefsKey = 'qf.subscriptionTree.expanded.v1';
  bool _restored = false;

  @override
  QfSubscriptionTreeState build() {
    unawaited(_restore());
    return const QfSubscriptionTreeState();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) {
        final currentId = ref.read(currentProfileIdProvider);
        state = QfSubscriptionTreeState(expandedProfiles: {?currentId});
      } else {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          state = QfSubscriptionTreeState(
            rootExpanded: decoded['root'] != false,
            expandedProfiles: {
              for (final item in decoded['profiles'] as List? ?? const [])
                if (item is num) item.toInt(),
            },
            expandedGroups: {
              for (final item in decoded['groups'] as List? ?? const [])
                item.toString(),
            },
          );
        }
      }
    } catch (_) {
      // A broken stored value must never block the dashboard.
    }
    _restored = true;
  }

  void toggleRoot() {
    state = state.copyWith(rootExpanded: !state.rootExpanded);
    unawaited(_save());
  }

  void toggleProfile(int profileId) {
    final next = {...state.expandedProfiles};
    if (!next.remove(profileId)) {
      next.add(profileId);
    }
    state = state.copyWith(expandedProfiles: next);
    unawaited(_save());
  }

  void toggleGroup(String key) {
    final next = {...state.expandedGroups};
    if (!next.remove(key)) {
      next.add(key);
    }
    state = state.copyWith(expandedGroups: next);
    unawaited(_save());
  }

  Future<void> _save() async {
    if (!_restored) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        json.encode({
          'root': state.rootExpanded,
          'profiles': state.expandedProfiles.toList(),
          'groups': state.expandedGroups.toList(),
        }),
      );
    } catch (_) {}
  }
}

final qfSubscriptionTreeProvider =
    NotifierProvider<QfSubscriptionTreeNotifier, QfSubscriptionTreeState>(
      QfSubscriptionTreeNotifier.new,
    );

class QfTreeFileGroup {
  const QfTreeFileGroup({
    required this.name,
    required this.type,
    required this.members,
  });

  final String name;
  final String type;
  final List<String> members;
}

/// Groups of a profile that is not loaded in the core, read from its stored
/// config file. Custom profiles keep their groups in the database instead,
/// so they answer with an empty list and the tree offers a switch action.
Future<List<QfTreeFileGroup>> _readProfileFileGroups(int profileId) async {
  try {
    final path = await appPath.getProfilePath(profileId.toString());
    final file = File(path);
    if (!await file.exists()) return const [];
    final document = loadYaml(await file.readAsString());
    if (document is! YamlMap) return const [];
    final rawGroups = document['proxy-groups'];
    if (rawGroups is! YamlList) return const [];
    return [
      for (final raw in rawGroups)
        if (raw is YamlMap && (raw['name'] ?? '').toString().isNotEmpty)
          QfTreeFileGroup(
            name: (raw['name'] ?? '').toString(),
            type: (raw['type'] ?? 'select').toString(),
            members: [
              for (final member in raw['proxies'] as YamlList? ?? const [])
                if (member.toString().isNotEmpty) member.toString(),
            ],
          ),
    ];
  } catch (_) {
    return const [];
  }
}

final _profileFileGroupsProvider =
    FutureProvider.family<List<QfTreeFileGroup>, int>(
      (ref, profileId) => _readProfileFileGroups(profileId),
    );

/// The main screen's node tree, directly under the connection card:
/// one 「我的订阅」root → each profile as its own row → its groups →
/// its nodes, with profile and node management kept in the same place.
class SubscriptionTreeCard extends ConsumerWidget {
  const SubscriptionTreeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final currentProfileId = ref.watch(currentProfileIdProvider);
    final rootExpanded = ref.watch(
      qfSubscriptionTreeProvider.select((state) => state.rootExpanded),
    );
    return DashboardCard(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RootHeader(
            expanded: rootExpanded,
            onTap: () =>
                ref.read(qfSubscriptionTreeProvider.notifier).toggleRoot(),
          ),
          // No "you have not imported a subscription yet" reminder:
          // the owner removed it outright (2026-10-25) — with no
          // profiles the card simply offers the add actions below.
          if (rootExpanded)
            for (final profile in profiles)
              _ProfileSection(
                profile: profile,
                isCurrent: profile.id == currentProfileId,
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => showAddProfilePage(context),
                  child: const Text('添加订阅'),
                ),
                TextButton(
                  onPressed: () => _showAddNodeDialog(context, ref),
                  child: const Text('添加节点'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showAddNodeDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final link = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('添加节点'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: '粘贴节点链接（如 ss://、vmess://、vless:// 等）',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('添加'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (link == null || link.isEmpty) return;
  await ref.read(profilesActionProvider.notifier).addProfileFromLink(link);
}

class _RootHeader extends StatelessWidget {
  const _RootHeader({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(
          children: [
            Transform.rotate(
              angle: expanded ? 0 : -math.pi / 2,
              child: const GlyphIcon(AppGlyphs.chevronDown, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '我的订阅',
                style: AppTextStyle.body.of(context, emphasized: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileSection extends ConsumerWidget {
  const _ProfileSection({required this.profile, required this.isCurrent});

  final Profile profile;
  final bool isCurrent;

  Future<void> _handleDelete(BuildContext context, WidgetRef ref) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    final appLocalizations = context.appLocalizations;
    final users = await profilesAction.providerUsers(profile);
    if (!context.mounted) return;
    final res = await dialogs.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: users.isEmpty
            ? appLocalizations.deleteTip(appLocalizations.profile)
            : appLocalizations.providerInUse(
                profile.realLabel,
                users.map((item) => item.realLabel).join(', '),
              ),
      ),
      destructive: true,
      confirmText: appLocalizations.delete,
    );
    if (res != true) return;
    await profilesAction.deleteProfile(profile.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(
      qfSubscriptionTreeProvider.select(
        (state) => state.expandedProfiles.contains(profile.id),
      ),
    );
    final colorScheme = context.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => ref
              .read(qfSubscriptionTreeProvider.notifier)
              .toggleProfile(profile.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 8, 12, 8),
            child: Row(
              children: [
                Transform.rotate(
                  angle: expanded ? 0 : -math.pi / 2,
                  child: const GlyphIcon(AppGlyphs.chevronDown, size: 16),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    profile.realLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.body.of(context, emphasized: true),
                  ),
                ),
                if (isCurrent)
                  Text(
                    '当前使用',
                    style: AppTextStyle.caption1
                        .of(context, emphasized: true)
                        .copyWith(color: colorScheme.primary),
                  ),
                DashboardIconButton(
                  glyph: AppGlyphs.delete,
                  tooltip: context.appLocalizations.delete,
                  onPressed: () => _handleDelete(context, ref),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          if (isCurrent)
            _CurrentGroups(profile: profile)
          else
            _FileGroups(profile: profile),
      ],
    );
  }
}

/// The current subscription's groups. Live core data wins when the core
/// has the profile loaded; while it has not (app opened but not
/// connected, core still loading), the same file-based groups the
/// other subscriptions show keep the current one visible and
/// pre-selectable instead of an empty placeholder.
class _CurrentGroups extends ConsumerWidget {
  const _CurrentGroups({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(currentGroupsStateProvider).value;
    if (groups.isNotEmpty) {
      return const _RuntimeGroups();
    }
    return _FileGroups(profile: profile, isCurrent: true);
  }
}

class _RuntimeGroups extends ConsumerWidget {
  const _RuntimeGroups();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(currentGroupsStateProvider).value;
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(72, 4, 20, 12),
        child: Text(
          '暂无分组，请先导入并启用一份订阅。',
          style: AppTextStyle.subheadline.of(context),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups) _RuntimeGroupSection(group: group),
      ],
    );
  }
}

class _RuntimeGroupSection extends ConsumerWidget {
  const _RuntimeGroupSection({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = 'runtime|${group.name}';
    final expanded = ref.watch(
      qfSubscriptionTreeProvider.select(
        (state) => state.expandedGroups.contains(key),
      ),
    );
    final selected = ref.watch(selectedProxyNameProvider(group.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupHeader(
          name: group.name,
          caption: selected ?? '',
          expanded: expanded,
          onTap: () =>
              ref.read(qfSubscriptionTreeProvider.notifier).toggleGroup(key),
        ),
        if (expanded)
          for (final proxy in group.all)
            _NodeRow(
              name: proxy.name,
              caption: proxy.type,
              selected: proxy.name == selected,
              onTap: () => selectGroupProxy(
                ref,
                groupName: group.name,
                groupType: group.type,
                proxyName: proxy.name,
              ),
              onInfo: GroupTypeExtension.valueList.contains(proxy.type)
                  ? null
                  : () {
                      final profile = ref.read(currentProfileProvider);
                      if (profile == null) return;
                      BaseNavigator.push(
                        context,
                        QfProxyDetailPage(
                          profileId: profile.id,
                          proxyName: proxy.name,
                          isCustom: profile.type == ProfileType.custom,
                        ),
                      );
                    },
            ),
      ],
    );
  }
}

class _FileGroups extends ConsumerWidget {
  const _FileGroups({required this.profile, this.isCurrent = false});

  final Profile profile;
  final bool isCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profile.type == ProfileType.custom) {
      return isCurrent
          ? const _NoGroupsHint()
          : _SwitchHint(profile: profile, custom: true);
    }
    final groups = ref.watch(_profileFileGroupsProvider(profile.id));
    return groups.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CommonCircleLoading()),
      ),
      error: (_, _) =>
          isCurrent ? const _NoGroupsHint() : _SwitchHint(profile: profile),
      data: (groups) => groups.isEmpty
          ? (isCurrent ? const _NoGroupsHint() : _SwitchHint(profile: profile))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in groups)
                  _FileGroupSection(profile: profile, group: group),
              ],
            ),
    );
  }
}

class _NoGroupsHint extends StatelessWidget {
  const _NoGroupsHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 4, 20, 12),
      child: Text(
        '暂无分组，请先导入并启用一份订阅。',
        style: AppTextStyle.subheadline.of(context),
      ),
    );
  }
}

class _SwitchHint extends ConsumerWidget {
  const _SwitchHint({required this.profile, this.custom = false});

  final Profile profile;
  final bool custom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 2, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              custom
                  ? '自定义订阅的分组与节点在订阅页编辑，切换到该订阅后可在此选节点。'
                  : '切换到该订阅后，这里会列出它的分组与节点。',
              style: AppTextStyle.subheadline.of(context),
            ),
          ),
          TextButton(
            onPressed: () {
              ref.read(currentProfileIdProvider.notifier).value = profile.id;
            },
            child: const Text('切换到此订阅'),
          ),
        ],
      ),
    );
  }
}

class _FileGroupSection extends ConsumerStatefulWidget {
  const _FileGroupSection({required this.profile, required this.group});

  final Profile profile;
  final QfTreeFileGroup group;

  @override
  ConsumerState<_FileGroupSection> createState() => _FileGroupSectionState();
}

class _FileGroupSectionState extends ConsumerState<_FileGroupSection> {
  bool _switching = false;

  Future<void> _selectNode(String proxyName) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      ref.read(currentProfileIdProvider.notifier).value = widget.profile.id;
      // The core needs a moment to load the switched profile before the
      // group exists; wait for it, then apply the pick.
      final stopwatch = Stopwatch()..start();
      var loaded = false;
      while (stopwatch.elapsed < const Duration(seconds: 6)) {
        if (ref.read(groupsProvider).getGroup(widget.group.name) != null) {
          loaded = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (loaded) {
        await ref
            .read(proxiesActionProvider.notifier)
            .changeProxy(groupName: widget.group.name, proxyName: proxyName);
      } else if (ref.read(currentProfileIdProvider) == widget.profile.id) {
        // The core has not loaded this profile (not connected yet):
        // keep the pick as the saved selection instead of failing; it
        // reaches the core on the next apply.
        ref
            .read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(widget.group.name, proxyName);
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = 'file|${widget.profile.id}|${widget.group.name}';
    final expanded = ref.watch(
      qfSubscriptionTreeProvider.select(
        (state) => state.expandedGroups.contains(key),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupHeader(
          name: widget.group.name,
          caption: widget.group.type,
          expanded: expanded,
          onTap: () =>
              ref.read(qfSubscriptionTreeProvider.notifier).toggleGroup(key),
        ),
        if (expanded)
          for (final member in widget.group.members)
            _NodeRow(
              name: member,
              selected: widget.profile.selectedMap[widget.group.name] == member,
              onTap: _switching ? null : () => _selectNode(member),
              onInfo: const {'DIRECT', 'REJECT', 'REJECT-DROP'}.contains(member)
                  ? null
                  : () {
                      BaseNavigator.push(
                        context,
                        QfProxyDetailPage(
                          profileId: widget.profile.id,
                          proxyName: member,
                          isCustom: widget.profile.type == ProfileType.custom,
                        ),
                      );
                    },
            ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.name,
    required this.caption,
    required this.expanded,
    required this.onTap,
  });

  final String name;
  final String caption;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(64, 8, 20, 8),
        child: Row(
          children: [
            Transform.rotate(
              angle: expanded ? 0 : -math.pi / 2,
              child: const GlyphIcon(AppGlyphs.chevronDown, size: 16),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.body.of(context),
              ),
            ),
            if (caption.isNotEmpty)
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.name,
    this.caption,
    required this.selected,
    required this.onTap,
    this.onInfo,
  });

  final String name;
  final String? caption;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(88, 9, onInfo == null ? 20 : 8, 9),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: selected
                  ? GlyphIcon(
                      AppGlyphs.check,
                      size: 16,
                      color: colorScheme.primary,
                    )
                  : null,
            ),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.subheadline
                    .of(context, emphasized: selected)
                    .copyWith(color: selected ? colorScheme.primary : null),
              ),
            ),
            if (caption != null)
              Text(
                caption!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: colorScheme.onSurfaceVariant),
              ),
            if (onInfo != null) QfInfoButton(onPressed: onInfo!),
          ],
        ),
      ),
    );
  }
}
