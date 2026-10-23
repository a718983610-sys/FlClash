import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart' show ProxyState;
import 'package:path/path.dart' as p;
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop && !safeModeBuild ? Proxy() : null;

final systemProxyQueue = proxy == null ? null : SystemProxyQueue(proxy!);

/// Snapshot of the user's own WinINET proxy settings, captured before the
/// core overwrites them so stop/exit can hand the machine back untouched.
/// The native plugin's stop only flips the enable flag and never restores
/// the original server/bypass values, so the restore lives here.
class WinInetProxyBackup {
  final bool enable;
  final String server;
  final String bypass;

  const WinInetProxyBackup({
    required this.enable,
    required this.server,
    required this.bypass,
  });

  Map<String, dynamic> toJson() => {
    'enable': enable,
    'server': server,
    'bypass': bypass,
  };

  factory WinInetProxyBackup.fromJson(Map<String, dynamic> json) {
    return WinInetProxyBackup(
      enable: json['enable'] == true,
      server: (json['server'] ?? '').toString(),
      bypass: (json['bypass'] ?? '').toString(),
    );
  }

  static String? parseRegValue(String output, String name) {
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith(name)) continue;
      final rest = trimmed.substring(name.length).trim();
      final split = rest.indexOf(RegExp(r'\s{2,}|\t'));
      if (split < 0) continue;
      return rest.substring(split).trim();
    }
    return null;
  }

  static WinInetProxyBackup fromRegOutput(String output) {
    final enableRaw = parseRegValue(output, 'ProxyEnable');
    final enable = enableRaw != null && enableRaw != '0x0';
    return WinInetProxyBackup(
      enable: enable,
      server: parseRegValue(output, 'ProxyServer') ?? '',
      bypass: parseRegValue(output, 'ProxyOverride') ?? '',
    );
  }

  bool get pointsAtCore =>
      server.startsWith('127.0.0.1:') || server.startsWith('http://127.0.0.1:');

  /// reg.exe argument lists that put the snapshot back, in order.
  List<List<String>> restoreCommands(String keyPath) {
    List<String> add(String name, String type, String data) => [
      'add',
      keyPath,
      '/v',
      name,
      '/t',
      type,
      '/d',
      data,
      '/f',
    ];
    return [
      add('ProxyServer', 'REG_SZ', server),
      add('ProxyOverride', 'REG_SZ', bypass),
      add('ProxyEnable', 'REG_DWORD', enable ? '1' : '0'),
    ];
  }
}

class _WinInetBackupStore {
  static const _keyPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  File? _file;

  Future<File> _backupFile() async {
    return _file ??= File(
      p.join(await appPath.homeDirPath, 'qf_proxy_backup.json'),
    );
  }

  Future<WinInetProxyBackup?> read() async {
    try {
      final file = await _backupFile();
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        return WinInetProxyBackup.fromJson(Map<String, dynamic>.from(data));
      }
    } catch (_) {}
    return null;
  }

  Future<void> write(WinInetProxyBackup backup) async {
    try {
      final file = await _backupFile();
      await file.writeAsString(jsonEncode(backup.toJson()));
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final file = await _backupFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<WinInetProxyBackup?> captureCurrent() async {
    try {
      final result = await Process.run('reg', ['query', _keyPath]);
      if (result.exitCode != 0) return null;
      return WinInetProxyBackup.fromRegOutput(result.stdout.toString());
    } catch (_) {
      return null;
    }
  }

  Future<void> restore(WinInetProxyBackup backup) async {
    for (final args in backup.restoreCommands(_keyPath)) {
      try {
        await Process.run('reg', args);
      } catch (_) {}
    }
  }
}

/// Exit's stop goes through the same queue as every other change, so a start
/// still waiting behind a slow call cannot turn the proxy back on after it.
class SystemProxyQueue {
  final Proxy _proxy;
  final _WinInetBackupStore _backupStore = _WinInetBackupStore();
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _restoredStaleBackup = false;

  SystemProxyQueue(this._proxy);

  Future<void> apply(ProxyState state) {
    return _enqueue(() async {
      if (_closed) {
        return;
      }
      if (!_restoredStaleBackup) {
        _restoredStaleBackup = true;
        await _restoreStaleBackupIfAny();
      }
      final applied = state.isStart && state.systemProxy
          ? await _startWithBackup(state)
          : await _stopWithRestore();
      if (!applied) {
        commonPrint.log(
          'update system proxy failed',
          logLevel: LogLevel.warning,
        );
      }
    });
  }

  Future<void> close() {
    _closed = true;
    return _enqueue(() async {
      await _stopWithRestore();
    });
  }

  Future<bool> _startWithBackup(ProxyState state) async {
    if (Platform.isWindows) {
      final existing = await _backupStore.read();
      if (existing == null) {
        final current = await _backupStore.captureCurrent();
        // Never back up our own proxy as if it were the user's setting.
        if (current != null && !current.pointsAtCore) {
          await _backupStore.write(current);
        }
      }
    }
    return _proxy.startProxy(state.port, state.bassDomain);
  }

  Future<bool> _stopWithRestore() async {
    if (Platform.isWindows) {
      final backup = await _backupStore.read();
      if (backup != null) {
        final stopped = await _proxy.stopProxy();
        await _backupStore.restore(backup);
        await _backupStore.clear();
        return stopped;
      }
    }
    return _proxy.stopProxy();
  }

  Future<void> _restoreStaleBackupIfAny() async {
    if (!Platform.isWindows) return;
    final backup = await _backupStore.read();
    if (backup == null) return;
    final current = await _backupStore.captureCurrent();
    if (current != null && current.pointsAtCore) {
      await _backupStore.restore(backup);
    }
    await _backupStore.clear();
  }

  Future<void> _enqueue(Future<void> Function() task) {
    return _tail = _tail.then((_) => task()).catchError((Object error) {
      commonPrint.log(
        'update system proxy failed: $error',
        logLevel: LogLevel.warning,
      );
    });
  }
}

String proxyEnvCommand(int port, {required bool isWindows}) {
  final url = 'http://127.0.0.1:$port';
  return isWindows ? 'set \$env:all_proxy=$url' : 'export all_proxy=$url';
}
