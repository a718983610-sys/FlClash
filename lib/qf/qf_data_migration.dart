import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The 0.9.1 Windows build shipped with a different product name, so its
/// per-user data directory ("clash") differs from the current one
/// ("QFClash") and nothing carried the data over. On first launch, when the
/// current directory holds no app data yet and a legacy directory with data
/// exists, copy the whole legacy directory over before anything reads it.

const String qfLegacyMarkerName = '.qf_legacy_migrated';

const Set<String> qfAppDataMarkers = {
  'config.yaml',
  'database.sqlite',
  'shared_preferences.json',
  'profiles',
};

bool qfNamesContainAppData(Iterable<String> names) {
  final lowered = names.map((name) => name.toLowerCase()).toSet();
  return qfAppDataMarkers.any(lowered.contains);
}

bool qfShouldMigrate({
  required bool markerExists,
  required bool newHasData,
  required bool oldHasData,
}) {
  return !markerExists && !newHasData && oldHasData;
}

Future<bool> _dirHasAppData(Directory dir) async {
  try {
    if (!await dir.exists()) return false;
    final names = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      names.add(p.basename(entity.path));
    }
    return qfNamesContainAppData(names);
  } catch (_) {
    return false;
  }
}

Future<List<Directory>> _legacyCandidates(Directory current) async {
  final found = <Directory>[];
  final seen = <String>{};
  void consider(Directory dir) {
    final key = dir.path.toLowerCase();
    if (key == current.path.toLowerCase() || !seen.add(key)) return;
    found.add(dir);
  }

  final parent = current.parent;
  try {
    if (await parent.exists()) {
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is Directory &&
            p.basename(entity.path).toLowerCase() == 'clash') {
          consider(entity);
        }
      }
    }
    final grandParent = parent.parent;
    if (await grandParent.exists()) {
      await for (final entity in grandParent.list(followLinks: false)) {
        if (entity is Directory) {
          final nested = Directory(p.join(entity.path, 'clash'));
          if (await nested.exists()) consider(nested);
        }
      }
    }
  } catch (_) {}
  return found;
}

Future<void> _copyDirectory(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(followLinks: false)) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

/// Core routine with an injectable current directory (tests use temp dirs).
/// Never throws: a failed migration must not block startup.
Future<bool> qfMigrateLegacyDataDir(Directory current) async {
  try {
    final marker = File(p.join(current.path, qfLegacyMarkerName));
    final markerExists = await marker.exists();
    final newHasData = await _dirHasAppData(current);
    Directory? legacy;
    var legacyHasData = false;
    for (final candidate in await _legacyCandidates(current)) {
      if (await _dirHasAppData(candidate)) {
        legacy = candidate;
        legacyHasData = true;
        break;
      }
    }
    if (!qfShouldMigrate(
      markerExists: markerExists,
      newHasData: newHasData,
      oldHasData: legacyHasData,
    )) {
      return false;
    }
    await _copyDirectory(legacy!, current);
    await marker.writeAsString('migrated from ${legacy.path}');
    return true;
  } catch (_) {
    return false;
  }
}

/// Windows-only entry point used by main() before any data access. Login
/// state kept in platform secure storage (DPAPI) is not directory data and
/// is outside this migration's scope by design.
Future<void> qfMigrateLegacyDataDirIfNeeded() async {
  if (!Platform.isWindows) return;
  try {
    final current = await getApplicationSupportDirectory();
    await qfMigrateLegacyDataDir(current);
  } catch (_) {}
}
