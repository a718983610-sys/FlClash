import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:material_ui/material_ui.dart';

/// Receives the real app once the startup chain lands; until [show] is
/// called the shell paints the boot skeleton, so the first frame no longer
/// waits for the whole chain.
class BootGate {
  final ValueNotifier<Widget?> app = ValueNotifier<Widget?>(null);

  void show(Widget widget) => app.value = widget;
}

class BootShell extends StatelessWidget {
  const BootShell({super.key, required this.gate});

  final BootGate gate;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Widget?>(
      valueListenable: gate.app,
      builder: (_, app, _) => app ?? const BootSkeletonApp(),
    );
  }
}

/// A throwaway [MaterialApp] in the dashboard's shape, built from the app's
/// own skeleton bars. It is replaced wholesale when the chain lands, so it
/// carries no state worth keeping.
class BootSkeletonApp extends StatelessWidget {
  const BootSkeletonApp({super.key});

  @override
  Widget build(BuildContext context) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(defaultPrimaryColor),
      brightness: brightness,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: appName,
      theme: ThemeData(colorScheme: scheme),
      // The skeleton's pills stay still: a pulsing placeholder costs more
      // compositing than the frame it stands in for, and boot is not where
      // the animation budget belongs.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: const BootSkeletonPage(),
    );
  }
}

class BootSkeletonPage extends StatelessWidget {
  const BootSkeletonPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      SkeletonPill(width: 40, height: 40),
                      SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonText(width: 96),
                          SizedBox(height: 6),
                          SkeletonText(width: 56),
                        ],
                      ),
                    ],
                  ),
                  SizedBox(height: 40),
                  Center(child: SkeletonPill(width: 148, height: 148)),
                  SizedBox(height: 16),
                  Center(child: SkeletonText(width: 72)),
                  SizedBox(height: 32),
                  Row(
                    children: [
                      Expanded(child: _SkeletonCard()),
                      SizedBox(width: 12),
                      Expanded(child: _SkeletonCard()),
                    ],
                  ),
                  SizedBox(height: 12),
                  _SkeletonCard(),
                  Spacer(),
                  _SkeletonDock(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: context.colorScheme.surfaceContainer,
        shape: AppShape.lg,
      ),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonText(width: 64),
            SizedBox(height: 10),
            SkeletonText(width: 40),
          ],
        ),
      ),
    );
  }
}

class _SkeletonDock extends StatelessWidget {
  const _SkeletonDock();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: context.colorScheme.surfaceContainer,
        shape: AppShape.full,
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SkeletonPill(width: 28, height: 28),
            SkeletonPill(width: 28, height: 28),
            SkeletonPill(width: 28, height: 28),
            SkeletonPill(width: 28, height: 28),
          ],
        ),
      ),
    );
  }
}
