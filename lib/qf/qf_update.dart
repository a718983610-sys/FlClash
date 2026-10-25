import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Cooperative cancellation for an in-flight update download. The panel
/// owns one per attempt session; cancelling force-closes the HTTP client,
/// which errors the response stream and unwinds the transfer at once.
class QfDownloadControl {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }

  void _bind(void Function() onCancel) {
    _onCancel = onCancel;
    if (_cancelled) onCancel();
  }

  void _unbind() {
    _onCancel = null;
  }
}

class QfUpdateService {
  static String? platformKeyOverride;
  static Future<QfReleaseManifest?> Function()? manifestFetcherForTest;

  // Download guardrails (1.1.1): every stage of the transfer is bounded so
  // a stalled connection surfaces as a retryable Chinese error instead of
  // hanging forever inside a dialog the user cannot leave. Fields (not
  // consts) so tests can shrink them.
  static Duration connectTimeout = const Duration(seconds: 15);
  static Duration responseTimeout = const Duration(seconds: 30);
  static Duration stallTimeout = const Duration(seconds: 30);
  static Duration overallTimeout = const Duration(minutes: 15);
  static Duration retryDelay = const Duration(seconds: 2);
  static int maxAutoRetries = 1;
  static Duration installTimeout = const Duration(seconds: 30);
  static Duration silentInstallTimeout = const Duration(minutes: 2);

  // Throughput watchdog: a connection that keeps trickling a few bytes
  // never trips the per-gap stall timeout, so a 60+MB package can sit
  // at a frozen-looking percentage for the full overall timeout (the
  // user-reported "update is stuck"). If fewer than [minProgressBytes]
  // arrive within [progressStallTimeout], the attempt is aborted as a
  // timeout and the auto-retry switches path (see alternateSourceFor).
  static Duration progressStallTimeout = const Duration(seconds: 45);
  static Duration progressCheckInterval = const Duration(seconds: 5);
  static int minProgressBytes = 32 * 1024;

  /// The path the automatic retry should force after [source] failed or
  /// stalled: the account stack's cross-path rule — a download that
  /// died on the proxied path gets a direct attempt and vice versa.
  static QfProxySource alternateSourceFor(QfProxySource source) {
    return switch (source) {
      QfProxySource.core => QfProxySource.direct,
      QfProxySource.direct => QfProxySource.core,
      QfProxySource.system => QfProxySource.direct,
      QfProxySource.environment => QfProxySource.direct,
    };
  }

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
    void Function(int received, int total)? onBytes,
    void Function()? onAutoRetry,
    QfDownloadControl? control,
    String? expectedSha256,
    int? expectedSizeBytes,
  }) async {
    final dir = await getTemporaryDirectory();
    final fileName = Uri.parse(url).pathSegments.isEmpty
        ? 'qfclash-update'
        : Uri.parse(url).pathSegments.last;
    final file = File('${dir.path}/$fileName');
    var attempt = 0;
    QfProxySource? retryForceSource;
    while (true) {
      if (control?.isCancelled == true) {
        throw const QfApiException(0, 'CANCELLED', '已取消下载');
      }
      try {
        await _downloadAttempt(
          url,
          file,
          onProgress: onProgress,
          onBytes: onBytes,
          control: control,
          forceSource: retryForceSource,
        );
        break;
      } catch (e) {
        if (control?.isCancelled == true) {
          await _deleteQuietly(file);
          throw const QfApiException(0, 'CANCELLED', '已取消下载');
        }
        final retryable =
            e is QfApiException &&
            (e.code == 'TIMEOUT' || e.status == 0 || e.status >= 500);
        if (!retryable || attempt >= maxAutoRetries) rethrow;
        attempt++;
        onAutoRetry?.call();
        // Cross-path retry (same rule as the account stack): force the
        // alternate route, so a path that is up but cannot actually
        // move bytes (dead node, throttled direct route) is not simply
        // retried identically.
        retryForceSource = alternateSourceFor(QfHttpClient.lastDecision.source);
        await Future<void>.delayed(retryDelay);
      }
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

  static Future<void> _downloadAttempt(
    String url,
    File file, {
    required void Function(double progress) onProgress,
    void Function(int received, int total)? onBytes,
    QfDownloadControl? control,
    QfProxySource? forceSource,
  }) async {
    final client = await QfHttpClient.create(
      uri: Uri.parse(url),
      forceSource: forceSource,
    );
    var overallTimedOut = false;
    final overallTimer = Timer(overallTimeout, () {
      overallTimedOut = true;
      client.close(force: true);
    });
    var progressStalled = false;
    var lastMarkBytes = 0;
    var lastMarkAt = DateTime.now();
    final progressTimer = Timer.periodic(progressCheckInterval, (_) {
      if (DateTime.now().difference(lastMarkAt) > progressStallTimeout) {
        progressStalled = true;
        client.close(force: true);
      }
    });
    control?._bind(() => client.close(force: true));
    try {
      client.connectionTimeout = connectTimeout;
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(
            responseTimeout,
            onTimeout: () =>
                throw const QfApiException(0, 'TIMEOUT', '连接下载服务器超时，请检查网络后重试'),
          );
      request.headers.set('User-Agent', 'QFClash');
      final response = await request.close().timeout(
        responseTimeout,
        onTimeout: () =>
            throw const QfApiException(0, 'TIMEOUT', '连接下载服务器超时，请检查网络后重试'),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw QfApiException(response.statusCode, 'DOWNLOAD', '下载失败，请稍后重试');
      }
      final total = response.contentLength;
      var received = 0;
      // The throughput watchdog judges the body phase only; a slow
      // connect/headers phase has its own timeouts above.
      lastMarkAt = DateTime.now();
      onBytes?.call(0, total);
      final sink = file.openWrite();
      try {
        await for (final chunk in response.timeout(stallTimeout)) {
          if (control?.isCancelled == true) {
            throw const QfApiException(0, 'CANCELLED', '已取消下载');
          }
          sink.add(chunk);
          received += chunk.length;
          if (received - lastMarkBytes >= minProgressBytes) {
            lastMarkBytes = received;
            lastMarkAt = DateTime.now();
          }
          onBytes?.call(received, total);
          if (total > 0) onProgress(received / total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      onProgress(1);
    } catch (e) {
      if (control?.isCancelled == true) {
        throw const QfApiException(0, 'CANCELLED', '已取消下载');
      }
      if (overallTimedOut) {
        throw const QfApiException(0, 'TIMEOUT', '下载超时，请检查网络后重试');
      }
      if (progressStalled) {
        throw const QfApiException(0, 'TIMEOUT', '下载长时间没有进展，已自动停止，请检查网络后重试');
      }
      if (e is QfApiException) rethrow;
      if (e is TimeoutException) {
        throw const QfApiException(0, 'TIMEOUT', '下载超时，请检查网络后重试');
      }
      throw const QfApiException(0, 'NETWORK', '下载失败，请检查网络后重试');
    } finally {
      overallTimer.cancel();
      progressTimer.cancel();
      control?._unbind();
      client.close(force: true);
    }
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

  // Async on purpose: a narrower invoker future makes Future.timeout reject onTimeout at runtime.
  static Future<Object?> _invokeAppChannel(
    String method,
    Object? arguments,
  ) async {
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
        // A native side that never answers must not hang the update page;
        // a timeout reads as a plain failure and the UI offers the
        // official-site fallback instead of spinning forever.
        final result = await _invokeAppChannel('installApk', {
          'path': file.path,
        }).timeout(installTimeout, onTimeout: () => null);
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

  static bool shouldAttemptSilent(QfUpdateCheck check, {bool? isAndroid}) {
    return check.manifestFresh &&
        check.decision == QfUpdateDecision.minor &&
        (check.manifest?.silentUpdate ?? false) &&
        (isAndroid ?? _isAndroid);
  }

  /// Claims the one automatic silent attempt for [version].
  static Future<bool> claimSilentAttempt(String version) async {
    if (version.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final key = 'qf_silent_attempted_$version';
    if (prefs.getBool(key) == true) return false;
    await prefs.setBool(key, true);
    return true;
  }

  /// Installs via the no-user-action session; non-success means fall back.
  static Future<QfSilentInstallOutcome> installSilently(File file) async {
    try {
      if (!_isAndroid) return QfSilentInstallOutcome.failed;
      if (!await file.exists()) return QfSilentInstallOutcome.failed;
      if (!file.path.toLowerCase().endsWith('.apk')) {
        return QfSilentInstallOutcome.failed;
      }
      final result = await _invokeAppChannel('installApkSilent', {
        'path': file.path,
      }).timeout(silentInstallTimeout, onTimeout: () => null);
      return switch (result) {
        'success' => QfSilentInstallOutcome.success,
        'pending_user_action' => QfSilentInstallOutcome.pendingUserAction,
        'needs_permission' => QfSilentInstallOutcome.needsPermission,
        _ => QfSilentInstallOutcome.failed,
      };
    } catch (_) {
      return QfSilentInstallOutcome.failed;
    }
  }

  static Future<QfSilentFirstOutcome> installSilentFirst(File file) async {
    if (_isAndroid) {
      final silent = await installSilently(file);
      if (silent == QfSilentInstallOutcome.success) {
        return QfSilentFirstOutcome.installed;
      }
    }
    final ordinary = await installOutcome(file);
    return switch (ordinary) {
      QfInstallOutcome.launched => QfSilentFirstOutcome.launched,
      QfInstallOutcome.needsPermission => QfSilentFirstOutcome.needsPermission,
      QfInstallOutcome.failed => QfSilentFirstOutcome.failed,
    };
  }

  /// Opens the system page for allowing installs from this app; false
  /// when there is nothing to open (already allowed or unsupported).
  static Future<bool> openInstallPermissionSettings() async {
    try {
      if (!_isAndroid) return false;
      // Same hang guard as installApk (C-13): a native side that never
      // answers must not wedge the caller.
      final result = await _invokeAppChannel(
        'openUnknownAppSettings',
        null,
      ).timeout(installTimeout, onTimeout: () => null);
      return result == true;
    } catch (_) {
      return false;
    }
  }
}

enum QfInstallOutcome { launched, needsPermission, failed }

enum QfSilentInstallOutcome {
  success,
  pendingUserAction,
  needsPermission,
  failed,
}

enum QfSilentFirstOutcome { installed, launched, needsPermission, failed }
