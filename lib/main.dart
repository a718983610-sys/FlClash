import 'dart:async';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'application.dart';
import 'boot_shell.dart';
import 'bootstrap.dart';
import 'qf/qf_data_migration.dart';
import 'common/app_data.dart';
import 'common/common.dart';
import 'common/preferences_store.dart';
import 'common/window.dart';

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlClashHttpOverrides.beginTrustCoreRoots();
      if (Platform.isWindows || Platform.isLinux) {
        SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
          appPath.sharedPreferencesPath,
        );
      }
      if (Platform.isLinux) {
        linkManager.seedInitialLink(args);
      }
      FlutterError.onError = (details) {
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      final gate = feature.bootSkeleton ? BootGate() : null;
      if (gate != null) {
        runApp(BootShell(gate: gate));
      }
      try {
        await qfMigrateLegacyDataDirIfNeeded();
        await RustLib.init();
        final version = await system.init();
        final container = await bootstrap.init(version);
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        final app = UncontrolledProviderScope(
          container: container,
          child: const Application(),
        );
        if (gate != null) {
          gate.show(app);
        } else {
          runApp(app);
        }
      } catch (e, s) {
        final errorApp = InitErrorApp(
          error: e,
          stack: s,
          onClearData: clearAppData,
          onExit: _exitAfterInitFailure,
        );
        if (gate != null) {
          gate.show(errorApp);
        } else {
          runApp(errorApp);
        }
        unawaited(window?.showInitFailure(onExit: _exitAfterInitFailure));
      }
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

Future<void> _exitAfterInitFailure() async {
  await system.exit();
  window?.forceExit();
}
