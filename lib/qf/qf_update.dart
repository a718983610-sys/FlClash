import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'qf_api.dart';
import 'qf_config.dart';
import 'qf_version.dart';

class QfUpdateCheck {
  final QfUpdateDecision decision;
  final QfReleaseManifest? manifest;
  final String notes;
  final String downloadUrl;
  final String latestVersion;

  const QfUpdateCheck({
    required this.decision,
    required this.manifest,
    required this.notes,
    required this.downloadUrl,
    required this.latestVersion,
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
  static String get platformKey =>
      Platform.isAndroid ? 'android' : Platform.isWindows ? 'windows' : '';

  static String get _tagPrefix =>
      Platform.isAndroid ? 'android-v' : Platform.isWindows ? 'windows-v' : '';

  static Future<QfUpdateCheck> check(String currentVersion) async {
    final current = QfVersion.tryParse(currentVersion);
    if (current == null || platformKey.isEmpty) return QfUpdateCheck.none;
    var manifest = await QfManifestService.fetchRemote();
    manifest ??= await QfManifestService.loadCached();
    if (manifest == null) return QfUpdateCheck.none;
    final decision = decideQfUpdate(current: current, manifest: manifest);
    if (decision == QfUpdateDecision.none) {
      return QfUpdateCheck(
        decision: decision,
        manifest: manifest,
        notes: '',
        downloadUrl: '',
        latestVersion: manifest.latestVersion,
      );
    }
    final platformRelease = manifest.platformRelease(platformKey);
    var notes = platformRelease?.notes ?? '';
    var downloadUrl = platformRelease?.downloadUrl ?? '';
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
    );
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
  }) async {
    final dir = await getTemporaryDirectory();
    final fileName = Uri.parse(url).pathSegments.isEmpty
        ? 'qfclash-update'
        : Uri.parse(url).pathSegments.last;
    final file = File('${dir.path}/$fileName');
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
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
      return file;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> install(File file) async {
    try {
      if (Platform.isWindows) {
        if (file.path.toLowerCase().endsWith('.exe')) {
          await Process.start(file.path, [], mode: ProcessStartMode.detached);
          return true;
        }
        await Process.start('explorer', [file.parent.path], mode: ProcessStartMode.detached);
        return true;
      }
      if (Platform.isAndroid) {
        return await launchUrl(
          Uri.file(file.path),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}
