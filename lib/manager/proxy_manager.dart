import 'dart:async';

import 'package:fl_clash/common/proxy.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../qf/qf_providers.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (prev != next) {
        _apply(next);
      }
    }, fireImmediately: true);
  }

  void _apply(ProxyState next) {
    final queue = systemProxyQueue;
    if (queue == null) return;
    unawaited(
      queue.apply(next).then((ok) {
        if (!mounted) return;
        if (next.isStart && next.systemProxy) {
          ref.read(qfTakeoverStatusProvider.notifier).report(ok);
        } else if (ok) {
          ref.read(qfTakeoverStatusProvider.notifier).reset();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
