import 'dart:async';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../qf/qf_config.dart';
import '../../qf/qf_egress.dart';
import '../../qf/qf_providers.dart';
import 'edit.dart';
import 'layout.dart';
import 'style.dart';
import 'widget_registry.dart';
import 'widgets/core_status_button.dart';
import 'widgets/widgets.dart';

// Narrower columns leave the service grid's cells too tight for a status, so
// the grid takes the memory card's column instead.
const _memoryColumnMin = 290.0;

const _maxColumnWidth = 440.0;

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key, this.platform});

  /// The host's platform when null.
  final SupportPlatform? platform;

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  var _editing = false;
  final _cardKeys = <DashboardWidget, GlobalKey>{};

  void _setEditing(bool editing) {
    setState(() => _editing = editing);
  }

  GlobalKey _cardKeyOf(DashboardWidget widget) =>
      _cardKeys.putIfAbsent(widget, GlobalKey.new);

  @override
  Widget build(BuildContext context) {
    final platform = widget.platform ?? SupportPlatform.currentPlatform;
    final viewSize = ref.watch(viewSizeProvider);
    final sideWidth = ref.watch(sideWidthProvider);
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final size = Size(viewSize.width - sideWidth, viewSize.height) / scale;
    final editable = !DashboardDensity.of(size).isDesktop;
    if (!editable) {
      _editing = false;
    }
    final editing = _editing;
    final gap = cardSpacingOf(context, ref.watch(viewModeProvider));
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      backgroundColor: DashboardColors.of(context).page,
      title: editing
          ? appLocalizations.editDashboard
          : appLocalizations.dashboard,
      backAction: editing ? () => _setEditing(false) : null,
      actions: [if (!editing && coreLib == null) const CoreStatusButton()],
      confirmationAction: editing
          ? IconButtonData(
              glyph: AppGlyphs.check,
              tooltip: appLocalizations.done,
              onPressed: () => _setEditing(false),
            )
          : null,
      iconActions: [
        if (editable && !editing)
          IconButtonData(
            glyph: AppGlyphs.edit,
            tooltip: appLocalizations.editDashboard,
            onPressed: () => _setEditing(true),
          ),
      ],
      // The providers learn a resize a frame late, too late for the cards.
      body: Column(
        children: [
          const _QfEgressMonitor(),
          const _QfGuestRemainingBanner(),
          const _QfDirectOnlyBanner(),
          const _QfEgressBanner(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final room = constraints.biggest / scale;
                final layout = DashboardDensity.of(room);
                return DashboardDensityScope(
                  density: layout,
                  scale: scale,
                  child: layout.isDesktop
                      ? _DesktopDashboard(
                          platform: platform,
                          columns: dashboardColumnsOf(room.width),
                          gap: gap,
                        )
                      : _MobileDashboard(
                          platform: platform,
                          gap: gap,
                          editing: editing,
                          cardKeyOf: _cardKeyOf,
                          onDone: () => _setEditing(false),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _QfDirectOnlyBanner extends ConsumerWidget {
  const _QfDirectOnlyBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(qfDirectOnlyProfileProvider)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          color: Color(0xFFB3261E),
          shape: AppShape.sm,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            '当前订阅没有任何可用节点，已按仅直连模式运行，网络流量不会经过代理。请更新或更换订阅。',
            textAlign: TextAlign.center,
            style: AppTextStyle.subheadline
                .of(context, emphasized: true)
                .copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _QfGuestRemainingBanner extends ConsumerWidget {
  const _QfGuestRemainingBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.read(qfSessionProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final usage = session.guestUsage;
        if (!session.isGuest || usage == null) {
          return const SizedBox.shrink();
        }
        final seconds = usage.remainingSeconds;
        final hours = seconds ~/ 3600;
        final minutes = (seconds % 3600) ~/ 60;
        final duration = hours > 0
            ? '$hours 小时 $minutes 分钟'
            : minutes > 0
            ? '$minutes 分钟'
            : '不足 1 分钟';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '今日剩余免费时长：$duration',
            textAlign: TextAlign.center,
            style: AppTextStyle.subheadline.of(context),
          ),
        );
      },
    );
  }
}

/// Four columns fill the window, the tables taking what the rows above them
/// leave. A window too short for the tables, and every two column one, gets
/// the summary cards instead, so no list scrolls inside a page that scrolls.
class _DesktopDashboard extends StatelessWidget {
  const _DesktopDashboard({
    required this.platform,
    required this.columns,
    required this.gap,
  });

  final SupportPlatform platform;
  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final compact = density.isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final base = EdgeInsetsDirectional.fromSTEB(
      16,
      MediaQuery.paddingOf(context).top,
      24,
      24 + MediaQuery.paddingOf(context).bottom,
    );
    final topHeight = (compact ? 176 : 208) * scale;
    final controlHeight = (compact ? 56 : 64) * scale;
    final middleHeight = (compact ? 152 : 176) * scale;
    final tablesHeight = connectionsTableMinHeight(density, scale);
    final summaryHeight = (compact ? 112 : 120) * scale;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room =
            constraints.maxWidth - base.horizontal - gap * (columns - 1);
        final column = math.min(room / columns, _maxColumnWidth * scale);
        final inset = (room - column * columns) / 2;
        final padding = base.copyWith(
          start: base.start + inset,
          end: base.end + inset,
        );
        double span(int columns) => column * columns + gap * (columns - 1);
        Widget row(List<(int, Widget)> cards) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: [
            for (final (columns, card) in cards)
              SizedBox(
                width: span(columns),
                child: RepaintBoundary(child: card),
              ),
          ],
        );
        Widget sized(double height, Widget child) =>
            SizedBox(height: height, child: child);
        final switches =
            DashboardWidget.networkTakeover.platforms.contains(platform)
            ? const [
                (1, NetworkTakeoverTile(TakeoverSwitch.systemProxy)),
                (1, NetworkTakeoverTile(TakeoverSwitch.tun)),
              ]
            : const [(2, VpnTile())];
        final half = columns ~/ 2;
        final summaries = row([
          (half, const ConnectionStatsCard()),
          (half, const ProxyGroupsSummaryCard()),
        ]);
        if (columns == 2) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: padding,
            child: Column(
              spacing: gap,
              children: [
                sized(
                  topHeight,
                  const RepaintBoundary(child: CurrentOutboundCard()),
                ),
                const RepaintBoundary(child: SubscriptionTreeCard()),
                sized(
                  topHeight,
                  row(const [
                    (1, SpeedCard(direction: TrafficDirection.upload)),
                    (1, SpeedCard(direction: TrafficDirection.download)),
                  ]),
                ),
                sized(
                  controlHeight,
                  const RepaintBoundary(child: OutboundModeBar()),
                ),
                sized(controlHeight, row(switches)),
                sized(
                  middleHeight,
                  row(const [(1, IntranetIpCard()), (1, ProfilesCard())]),
                ),
                sized(
                  middleHeight,
                  row(const [(1, ServiceStatusCard()), (1, MemoryInfo())]),
                ),
                sized(summaryHeight, summaries),
              ],
            ),
          );
        }
        final rows = [
          sized(
            topHeight,
            row(const [
              (2, CurrentOutboundCard()),
              (1, SpeedCard(direction: TrafficDirection.upload)),
              (1, SpeedCard(direction: TrafficDirection.download)),
            ]),
          ),
          sized(
            controlHeight,
            row([(2, const OutboundModeBar()), ...switches]),
          ),
          sized(
            middleHeight,
            row([
              (1, const IntranetIpCard()),
              (1, const ProfilesCard()),
              if (column >= _memoryColumnMin * scale) ...[
                (1, const ServiceStatusCard()),
                (1, const MemoryInfo()),
              ] else
                (2, const ServiceStatusCard()),
            ]),
          ),
        ];
        final rowsHeight =
            padding.vertical +
            topHeight +
            controlHeight +
            middleHeight +
            gap * 3;
        final tablesFit = constraints.maxHeight >= rowsHeight + tablesHeight;
        final fills = constraints.maxHeight >= rowsHeight + summaryHeight;
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: fills ? constraints.maxHeight : null,
            child: Padding(
              padding: padding,
              child: Column(
                spacing: gap,
                children: [
                  ...rows,
                  if (tablesFit)
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: gap,
                        children: const [
                          Expanded(
                            flex: 3,
                            child: RepaintBoundary(
                              child: ConnectionsTableCard(),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: RepaintBoundary(child: ProxyGroupsCard()),
                          ),
                        ],
                      ),
                    )
                  else if (fills)
                    Expanded(child: summaries)
                  else
                    sized(summaryHeight, summaries),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MobileDashboard extends ConsumerWidget {
  const _MobileDashboard({
    required this.platform,
    required this.gap,
    required this.editing,
    required this.cardKeyOf,
    required this.onDone,
  });

  final SupportPlatform platform;
  final double gap;
  final bool editing;
  final GlobalKey Function(DashboardWidget widget) cardKeyOf;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(
      dashboardStateProvider.select((state) => state.dashboardWidgets),
    );
    final top = MediaQuery.paddingOf(context).top + 4;
    final bottom = 16 + BottomInsetScope.of(context);
    return CustomScrollView(
      // A viewport per card lays them all out and holds the scroll end still.
      scrollCacheExtent: editing
          ? ScrollCacheExtent.viewport(DashboardWidget.values.length.toDouble())
          : null,
      slivers: [
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final side = dashboardMobileSideOf(constraints.crossAxisExtent);
            final widgets = [
              for (final widget in saved)
                if (widget.platforms.contains(platform)) widget,
            ];
            if (editing) {
              return DashboardEditor(
                platform: platform,
                widgets: widgets,
                cardKeyOf: cardKeyOf,
                padding: EdgeInsets.fromLTRB(side, top, side, bottom),
                gap: gap,
                onDone: onDone,
              );
            }
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(side, top, side, bottom),
              // A lazy list estimates the cards it has not laid out from the
              // ones it has; cards this uneven move the scroll end as it goes.
              sliver: SliverToBoxAdapter(
                child: Column(
                  spacing: gap,
                  children: [
                    for (final widget in widgets)
                      RepaintBoundary(
                        key: cardKeyOf(widget),
                        child: widget.card,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Runs the post-connect egress check shortly after the core starts and
/// again whenever the takeover state changes while running.
class _QfEgressMonitor extends ConsumerStatefulWidget {
  const _QfEgressMonitor();

  @override
  ConsumerState<_QfEgressMonitor> createState() => _QfEgressMonitorState();
}

class _QfEgressMonitorState extends ConsumerState<_QfEgressMonitor> {
  Timer? _pending;

  @override
  void initState() {
    super.initState();
    ref.listenManual(isStartProvider, (prev, next) {
      if (next) {
        _schedule();
      } else {
        _pending?.cancel();
        ref.read(qfEgressStateProvider.notifier).set(QfEgressState.idle);
      }
    });
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (prev != next && next.isStart) _schedule();
    });
  }

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final proxyState = ref.read(proxyStateProvider);
      unawaited(
        qfRunEgressCheck(
          ref,
          takeoverExpected: proxyState.isStart && proxyState.systemProxy,
        ),
      );
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _QfEgressBanner extends ConsumerWidget {
  const _QfEgressBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isStart = ref.watch(isStartProvider);
    final egress = ref.watch(qfEgressStateProvider);
    if (!isStart || egress.status == QfEgressStatus.idle) {
      return const SizedBox.shrink();
    }
    if (egress.status == QfEgressStatus.checking ||
        egress.status == QfEgressStatus.ok) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          egress.status == QfEgressStatus.checking
              ? QfCopy.egressChecking
              : QfCopy.egressOk,
          textAlign: TextAlign.center,
          style: AppTextStyle.subheadline.of(context),
        ),
      );
    }
    final takeoverFailed = egress.status == QfEgressStatus.takeoverFailed;
    final message = switch (egress.status) {
      QfEgressStatus.handshakeFailed => QfCopy.egressHandshakeFailed,
      QfEgressStatus.takeoverFailed => QfCopy.egressTakeoverFailed,
      _ => QfCopy.egressNodeUnreachable,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          color: Color(0xFFB3261E),
          shape: AppShape.sm,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(color: Colors.white),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_onAction(ref, takeoverFailed)),
                child: Text(
                  takeoverFailed
                      ? QfCopy.egressRetryProxy
                      : QfCopy.egressRetryCheck,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onAction(WidgetRef ref, bool takeoverFailed) async {
    final proxyState = ref.read(proxyStateProvider);
    if (takeoverFailed) {
      final queue = systemProxyQueue;
      if (queue != null) {
        final ok = await queue.apply(proxyState);
        ref.read(qfTakeoverStatusProvider.notifier).report(ok);
      }
    }
    await qfRunEgressCheck(
      ref,
      takeoverExpected: proxyState.isStart && proxyState.systemProxy,
    );
  }
}
