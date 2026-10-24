import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'qf_api.dart';
import 'qf_http_client.dart';
import 'qf_config.dart';
import 'qf_version.dart';

class QfUpdateCheck {
  final QfUpdateDecision decision;
  final QfReleaseManifest? manifest;
  final String notes;
  final String downloadUrl;
  final String latestVersion;
  final String sha256;
  final int? sizeBytes;
  final bool manifestFresh;

  const QfUpdateCheck({
    required this.decision,
    required this.manifest,
    required this.notes,
    required this.downloadUrl,
    required this.latestVersion,
    this.sha256 = '',
    this.sizeBytes,
    this.manifestFresh = false,
  });

  static const QfUpdateCheck none = QfUpdateCheck(
    decision: QfUpdateDecision.none,
    manifest: null,
    notes: '',
    downloadUrl: '',
    latestVersion: '',
  );
}

class QfUpdateService {
  static String? platformKeyOverride;
  static Future<QfReleaseManifest?> Function()? manifestFetcherForTest;

  static String get platformKey =>
      platformKeyOverride ??
      (Platform.isAndroid
          ? 'android'
          : Platform.isWindows
          ? 'windows'
          : '');

  static String get _tagPrefix => Platform.isAndroid
      ? 'android-v'
      : Platform.isWindows
      ? 'windows-v'
      : '';

  static String? _lastCheckedVersion;
  static void Function(QfUpdateCheck)? onFreshCheck;

  static Future<QfUpdateCheck> check(String currentVersion) async {
    _lastCheckedVersion = currentVersion;
    final current = QfVersion.tryParse(currentVersion);
    if (current == null || platformKey.isEmpty) return QfUpdateCheck.none;
    final fetcher = manifestFetcherForTest ?? QfManifestService.fetchRemote;
    var manifest = await fetcher();
    final fresh = manifest != null;
    if (!fresh) {
      manifest = await QfManifestService.loadCached();
      _scheduleManifestRetry();
      if (manifest == null) return QfUpdateCheck.none;
      // Fail-open: a stale cached manifest may inform the UI about versions
      // but must never drive a blocking decision (maintenance/force/retired).
      return QfUpdateCheck(
        decision: QfUpdateDecision.none,
        manifest: manifest,
        notes: '',
        downloadUrl: '',
        latestVersion: manifest.latestVersion,
      );
    }
    final decision = decideQfUpdate(current: current, manifest: manifest);
    if (decision == QfUpdateDecision.none) {
      return QfUpdateCheck(
        decision: decision,
        manifest: manifest,
        notes: '',
        downloadUrl: '',
        latestVersion: manifest.latestVersion,
        manifestFresh: true,
      );
    }
    final platformRelease = manifest.platformRelease(platformKey);
    var notes = platformRelease?.notes ?? '';
    var downloadUrl = platformRelease?.downloadUrl ?? '';
    final expectedSha256 = platformRelease?.sha256 ?? '';
    final expectedSizeBytes = platformRelease?.sizeBytes;
    if (notes.isEmpty || downloadUrl.isEmpty) {
      final release = await _fetchPlatformRelease(manifest.latestVersion);
      if (release != null) {
        if (notes.isEmpty) notes = (release['body'] ?? '').toString().trim();
        if (downloadUrl.isEmpty) {
          downloadUrl = _pickAssetUrl(release);
        }
      }
    }
    if (notes.isEmpty) notes = '修复已知问题，优化使用体验。';
    return QfUpdateCheck(
      decision: decision,
      manifest: manifest,
      notes: notes,
      downloadUrl: downloadUrl,
      latestVersion: manifest.latestVersion,
      sha256: expectedSha256,
      sizeBytes: expectedSizeBytes,
      manifestFresh: true,
    );
  }

  static bool _manifestRetryScheduled = false;

  static void _scheduleManifestRetry() {
    if (_manifestRetryScheduled || manifestFetcherForTest != null) return;
    _manifestRetryScheduled = true;
    unawaited(
      Future<void>(() async {
        try {
          await Future<void>.delayed(const Duration(seconds: 5));
          if (!await retryManifestOnce()) {
            await Future<void>.delayed(const Duration(seconds: 20));
            await retryManifestOnce();
          }
        } catch (_) {
        } finally {
          _manifestRetryScheduled = false;
        }
      }),
    );
  }

  /// One background re-fetch; on success the verdict is recomputed at once
  /// and pushed to [onFreshCheck] instead of waiting for the next cycle.
  static Future<bool> retryManifestOnce() async {
    final fetcher = manifestFetcherForTest ?? QfManifestService.fetchRemote;
    final manifest = await fetcher();
    if (manifest == null) return false;
    final version = _lastCheckedVersion;
    final callback = onFreshCheck;
    if (version != null && callback != null) {
      callback(await check(version));
    }
    return true;
  }

  static Future<Map<String, dynamic>?> _fetchPlatformRelease(
    String version,
  ) async {
    try {
      final data = await QfHttp.send(
        'GET',
        'https://api.github.com/repos/${QfConfig.repository}/releases/tags/'
            '$_tagPrefix$version',
      );
      return data;
    } catch (_) {
      return null;
    }
  }

  static String _pickAssetUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return '';
    String fallback = '';
    for (final raw in assets) {
      if (raw is! Map) continue;
      final asset = Map<String, dynamic>.from(raw);
      final name = (asset['name'] ?? '').toString().toLowerCase();
      final url = (asset['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      if (Platform.isAndroid && name.endsWith('.apk')) return url;
      if (Platform.isWindows && name.endsWith('.exe')) return url;
      if (fallback.isEmpty) fallback = url;
    }
    return fallback;
  }

  static Future<File> download(
    String url, {
    required void Function(double progress) onProgress,
    String? expectedSha256,
    int? expectedSizeBytes,
  }) async {
    final dir = await getTemporaryDirectory();
    final fileName = Uri.parse(url).pathSegments.isEmpty
        ? 'qfclash-update'
        : Uri.parse(url).pathSegments.last;
    final file = File('${dir.path}/$fileName');
    final client = await QfHttpClient.create(uri: Uri.parse(url));
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'QFClash');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const QfApiException(0, 'DOWNLOAD', '下载失败，请稍后重试');
      }
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      onProgress(1);
    } finally {
      client.close(force: true);
    }
    var sha = (expectedSha256 ?? '').trim().toLowerCase();
    var size = expectedSizeBytes;
    if (sha.isEmpty || size == null) {
      final cached = await QfManifestService.loadCached();
      final release = cached?.platformRelease(platformKey);
      if (sha.isEmpty) sha = (release?.sha256 ?? '').trim().toLowerCase();
      size ??= release?.sizeBytes;
    }
    await _verifyDownloadedFile(file, sha256: sha, sizeBytes: size);
    return file;
  }

  static Future<void> _verifyDownloadedFile(
    File file, {
    required String sha256,
    required int? sizeBytes,
  }) async {
    if (sizeBytes != null) {
      final actualSize = await file.length();
      if (actualSize != sizeBytes) {
        await _deleteQuietly(file);
        throw const QfApiException(0, 'INTEGRITY', '更新包校验失败（大小不一致），已删除，请重新下载');
      }
    }
    if (sha256.isNotEmpty) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
        await _deleteQuietly(file);
        throw const QfApiException(0, 'INTEGRITY', '更新包校验失败（校验信息无效），已删除，请重新下载');
      }
      final digest = await crypto.sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != sha256) {
        await _deleteQuietly(file);
        throw const QfApiException(
          0,
          'INTEGRITY',
          '更新包校验失败（内容不完整或已被篡改），已删除，请重新下载',
        );
      }
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static const MethodChannel _appChannel = MethodChannel(
    'com.follow.clash/app',
  );

  static bool? isAndroidForTest;
  static bool? isWindowsForTest;
  static Future<Object?> Function(String method, Object? arguments)?
  appChannelInvokerForTest;

  static bool get _isAndroid => isAndroidForTest ?? Platform.isAndroid;
  static bool get _isWindows => isWindowsForTest ?? Platform.isWindows;

  static Future<Object?> _invokeAppChannel(
    String method,
    Object? arguments,
  ) {
    final invoker = appChannelInvokerForTest;
    if (invoker != null) return invoker(method, arguments);
    return _appChannel.invokeMethod<Object?>(method, arguments);
  }

  /// Returns true only when an installer was actually launched.
  static Future<bool> install(File file) async {
    return await installOutcome(file) == QfInstallOutcome.launched;
  }

  /// A missing install permission is reported separately from a plain
  /// failure, so the UI can guide the user through it and then retry.
  static Future<QfInstallOutcome> installOutcome(File file) async {
    try {
      if (!await file.exists()) return QfInstallOutcome.failed;
      if (_isWindows) {
        final lower = file.path.toLowerCase();
        if (!lower.endsWith('.exe') && !lower.endsWith('.msi')) {
          return QfInstallOutcome.failed;
        }
        await Process.start(file.path, [], mode: ProcessStartMode.detached);
        return QfInstallOutcome.launched;
      }
      if (_isAndroid) {
        if (!file.path.toLowerCase().endsWith('.apk')) {
          return QfInstallOutcome.failed;
        }
        final result = await _invokeAppChannel('installApk', {
          'path': file.path,
        });
        return switch (result) {
          'launched' => QfInstallOutcome.launched,
          'needs_permission' => QfInstallOutcome.needsPermission,
          // Older native builds answer with a plain bool.
          true => QfInstallOutcome.launched,
          _ => QfInstallOutcome.failed,
        };
      }
    } catch (_) {
      return QfInstallOutcome.failed;
    }
    return QfInstallOutcome.failed;
  }

  /// Opens the system page for allowing installs from this app; false
  /// when there is nothing to open (already allowed or unsupported).
  static Future<bool> openInstallPermissionSettings() async {
    try {
      if (!_isAndroid) return false;
      return await _invokeAppChannel('openUnknownAppSettings', null) == true;
    } catch (_) {
      return false;
    }
  }
}

enum QfInstallOutcome { launched, needsPermission, failed }
