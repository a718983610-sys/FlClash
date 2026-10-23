import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'qf_api.dart';
import 'qf_version.dart';

@pragma('vm:entry-point')
void qfUpdateCheckDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await QfUpdateNotify.checkInBackground();
    } catch (_) {}
    return true;
  });
}

class QfUpdateNotify {
  static const String _notifiedKey = 'qf_notified_version';
  static const String _permAskedKey = 'qf_notify_perm_asked';
  static const int _notificationId = 1001;

  static FlutterLocalNotificationsPlugin? _plugin;
  static void Function()? _onTap;

  static Future<FlutterLocalNotificationsPlugin> _ensurePlugin() async {
    if (_plugin != null) return _plugin!;
    final plugin = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    final windowsSettings = WindowsInitializationSettings(
      appName: 'QFClash',
      appUserModelId: 'QFClash.App',
      guid: '7f3a9c41-5d2e-4c8b-9a17-2e6d4b8f05a3',
    );
    await plugin.initialize(
      settings: InitializationSettings(
        android: androidSettings,
        windows: windowsSettings,
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == 'update') {
          _onTap?.call();
        }
      },
    );
    _plugin = plugin;
    return plugin;
  }

  static void registerTapHandler(void Function() handler) {
    _onTap = handler;
  }

  static Future<bool> launchedFromNotification() async {
    try {
      final plugin = await _ensurePlugin();
      final details = await plugin.getNotificationAppLaunchDetails();
      return details?.didNotificationLaunchApp == true &&
          details?.notificationResponse?.payload == 'update';
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestPermissionOnce() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_permAskedKey) == true) return;
    await prefs.setBool(_permAskedKey, true);
    try {
      final plugin = await _ensurePlugin();
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> registerBackgroundChecks() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().initialize(qfUpdateCheckDispatcher);
      await Workmanager().registerPeriodicTask(
        'qf-update-check',
        'qfUpdateCheck',
        frequency: const Duration(hours: 6),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {}
  }

  static Future<void> markNotified(String version) async {
    if (version.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_notifiedKey, version);
  }

  static Future<void> checkAndNotify({
    required QfReleaseManifest manifest,
    required String currentVersion,
    required bool interactive,
  }) async {
    if (manifest.maintenance) return;
    final current = QfVersion.tryParse(currentVersion);
    if (current == null) return;
    final decision = decideQfUpdate(manifest: manifest, current: current);
    if (decision != QfUpdateDecision.minor &&
        decision != QfUpdateDecision.force) {
      return;
    }
    final version = manifest.latestVersion;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_notifiedKey) == version) return;
    await prefs.setString(_notifiedKey, version);
    if (interactive) return;
    try {
      final plugin = await _ensurePlugin();
      await plugin.show(
        id: _notificationId,
        title: 'QFClash 更新',
        body: '新版本 $version 已发布，打开 QFClash 即可更新。',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'qf_updates',
            '版本更新',
            channelDescription: '发现新版本时提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          windows: WindowsNotificationDetails(),
        ),
        payload: 'update',
      );
    } catch (_) {}
  }

  static Future<void> checkInBackground() async {
    final manifest = await QfManifestService.fetchRemote();
    if (manifest == null) return;
    String version = '';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    if (version.isEmpty) return;
    await checkAndNotify(
      manifest: manifest,
      currentVersion: version,
      interactive: false,
    );
  }

  static Future<void> runBackgroundCheckNow() async {
    final manifest = await QfManifestService.fetchRemote();
    if (manifest == null) return;
    await checkAndNotify(
      manifest: manifest,
      currentVersion: await _currentVersion(),
      interactive: false,
    );
  }

  static Future<String> _currentVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }
}
