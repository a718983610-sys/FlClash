class QfVersion implements Comparable<QfVersion> {
  final int major;
  final int minor;
  final int patch;

  const QfVersion(this.major, this.minor, this.patch);

  static QfVersion? tryParse(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final core = cleaned.split('+').first.split('-').first;
    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final values = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null) return null;
      values.add(value);
    }
    while (values.length < 3) {
      values.add(0);
    }
    return QfVersion(values[0], values[1], values[2]);
  }

  @override
  int compareTo(QfVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(QfVersion other) => compareTo(other) < 0;
  bool operator >(QfVersion other) => compareTo(other) > 0;
  bool operator <=(QfVersion other) => compareTo(other) <= 0;
  bool operator >=(QfVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is QfVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

enum QfUpdateDecision { none, minor, force, retired, maintenance }

class QfReleaseManifest {
  final String latestVersion;
  final String retiredBelowVersion;
  final String minUsableVersion;
  final bool maintenance;
  final String serverBaseUrl;
  final String googleClientId;
  final Map<String, QfPlatformRelease> platforms;

  const QfReleaseManifest({
    required this.latestVersion,
    required this.retiredBelowVersion,
    this.minUsableVersion = '0.0.0',
    required this.maintenance,
    required this.serverBaseUrl,
    required this.googleClientId,
    required this.platforms,
  });

  factory QfReleaseManifest.fromJson(Map<String, dynamic> json) {
    final rawPlatforms = json['platforms'];
    final platforms = <String, QfPlatformRelease>{};
    if (rawPlatforms is Map) {
      rawPlatforms.forEach((key, value) {
        if (value is Map) {
          platforms[key.toString()] = QfPlatformRelease.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return QfReleaseManifest(
      latestVersion: (json['latestVersion'] ?? '').toString(),
      retiredBelowVersion: (json['retiredBelowVersion'] ?? '0.0.0').toString(),
      minUsableVersion: (json['minUsableVersion'] ?? '0.0.0').toString(),
      maintenance: json['maintenance'] == true,
      serverBaseUrl: (json['serverBaseUrl'] ?? '').toString(),
      googleClientId: (json['googleClientId'] ?? '').toString(),
      platforms: platforms,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latestVersion': latestVersion,
      'retiredBelowVersion': retiredBelowVersion,
      'minUsableVersion': minUsableVersion,
      'maintenance': maintenance,
      'serverBaseUrl': serverBaseUrl,
      'googleClientId': googleClientId,
      'platforms': platforms.map((key, value) => MapEntry(key, value.toJson())),
    };
  }

  QfPlatformRelease? platformRelease(String platform) => platforms[platform];

  String googleClientIdFor(String platform) {
    final platformId = platforms[platform]?.googleClientId ?? '';
    return platformId.isNotEmpty ? platformId : googleClientId;
  }
}

class QfPlatformRelease {
  final String downloadUrl;
  final String notes;
  final String googleClientId;
  final String sha256;
  final int? sizeBytes;

  const QfPlatformRelease({
    required this.downloadUrl,
    required this.notes,
    this.googleClientId = '',
    this.sha256 = '',
    this.sizeBytes,
  });

  factory QfPlatformRelease.fromJson(Map<String, dynamic> json) {
    return QfPlatformRelease(
      downloadUrl: (json['downloadUrl'] ?? '').toString(),
      notes: (json['notes'] ?? '').toString(),
      googleClientId: (json['googleClientId'] ?? '').toString(),
      sha256: (json['sha256'] ?? '').toString().trim().toLowerCase(),
      sizeBytes: _parseSizeBytes(json['sizeBytes']),
    );
  }

  static int? _parseSizeBytes(Object? raw) {
    final value = switch (raw) {
      final num number => number.toInt(),
      final String text => int.tryParse(text.trim()),
      _ => null,
    };
    return value != null && value > 0 ? value : null;
  }

  Map<String, dynamic> toJson() {
    return {
      'downloadUrl': downloadUrl,
      'notes': notes,
      'googleClientId': googleClientId,
      'sha256': sha256,
      'sizeBytes': sizeBytes,
    };
  }
}

QfUpdateDecision decideQfUpdate({
  required QfVersion current,
  required QfReleaseManifest manifest,
}) {
  if (manifest.maintenance) return QfUpdateDecision.maintenance;
  final latest = QfVersion.tryParse(manifest.latestVersion);
  if (latest == null) return QfUpdateDecision.none;
  final retiredBelow = QfVersion.tryParse(manifest.retiredBelowVersion);
  if (retiredBelow != null && current < retiredBelow) {
    return QfUpdateDecision.retired;
  }
  final minUsable = QfVersion.tryParse(manifest.minUsableVersion);
  if (minUsable != null && current < minUsable && current < latest) {
    return QfUpdateDecision.force;
  }
  if (current.major < latest.major) return QfUpdateDecision.force;
  if (current < latest) return QfUpdateDecision.minor;
  return QfUpdateDecision.none;
}
