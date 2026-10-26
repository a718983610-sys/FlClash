import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/common/task.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

// Guards the upgrade-retention contract behind the 2.0.3 fix: data written
// in the on-disk shape every shipped build used (drift schema 20, profile
// files under profiles/, a version-1 config map) must survive a new build
// opening the same store — rows, selection, order and files all intact —
// while an explicit delete still removes exactly what it targets.

class _FixtureStore implements MigrationStore {
  _FixtureStore({required this.configMap, required this.upgradeVersion});

  final Map<String, Object?>? configMap;
  final int upgradeVersion;
  Config? savedConfig;
  var restoreCalls = 0;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<Map<String, Object?>?> getConfigMap() async => configMap;

  @override
  Future<int> getVersion() async => 1;

  @override
  Future<Map<String, Object?>?> getClashConfigMap() async => null;

  @override
  Future<void> restore(MigrationData data) async {
    restoreCalls++;
  }

  @override
  Future<bool> saveConfig(Config config) async {
    savedConfig = config;
    return true;
  }

  @override
  Future<void> clearClashConfig() async {}

  @override
  Future<void> setVersion(int version) async {}

  @override
  Future<int> getUpgradeVersion() async => upgradeVersion;

  @override
  Future<void> setUpgradeVersion(int version) async {}
}

const _awsYaml = '''
mixed-port: 7890
proxies:
  - {name: "node-tokyo-ss", type: ss, server: 203.0.113.11, port: 8000, cipher: aes-256-gcm, password: "fixture"}
  - {name: "node-taipei-ss", type: ss, server: 198.51.100.12, port: 8000, cipher: aes-256-gcm, password: "fixture"}
proxy-groups:
  - name: AWS组
    type: select
    proxies: [DIRECT, node-tokyo-ss, node-taipei-ss]
rules:
  - MATCH,AWS组
''';

const _legacyYaml = '''
proxies:
  - {name: "legacy-a", type: ss, server: 203.0.113.21, port: 8000, cipher: aes-256-gcm, password: "fixture"}
  - {name: "legacy-b", type: ss, server: 203.0.113.22, port: 8000, cipher: aes-256-gcm, password: "fixture"}
''';

const _fileYaml = '''
proxies:
  - {name: "local-node", type: ss, server: 203.0.113.31, port: 8000, cipher: aes-256-gcm, password: "fixture"}
rules:
  - MATCH,DIRECT
''';

Map<String, dynamic> _node(String name, String server) => {
  'name': name,
  'type': 'ss',
  'server': server,
  'port': 8000,
  'cipher': 'aes-256-gcm',
  'password': 'fixture',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File dbFile;
  late Directory profilesDir;

  const awsId = 101;
  const legacyId = 102;
  const fileId = 103;
  const customId = 104;

  List<Profile> fixtureProfiles() => [
    Profile(
      id: awsId,
      type: ProfileType.url,
      label: 'AWS订阅',
      url: 'https://subs.example.test/aws.yaml',
      autoUpdateDuration: const Duration(hours: 24),
      currentGroupName: 'AWS组',
      selectedMap: const {'AWS组': 'node-tokyo-ss'},
    ),
    Profile(
      id: legacyId,
      type: ProfileType.url,
      label: '192.0.2.21',
      url: 'http://192.0.2.21:18080/sub/fixture',
      autoUpdateDuration: const Duration(hours: 24),
    ),
    Profile(
      id: fileId,
      type: ProfileType.file,
      label: '本地文件',
      autoUpdateDuration: const Duration(hours: 24),
    ),
    Profile(
      id: customId,
      type: ProfileType.custom,
      label: '自建档案',
      autoUpdateDuration: const Duration(hours: 24),
    ),
  ];

  Future<int> userVersion(Database db) async {
    final row = await db.customSelect('PRAGMA user_version').getSingle();
    return row.data['user_version'] as int;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qf_upgrade_fixture');
    dbFile = File(p.join(dir.path, 'database.sqlite'));
    profilesDir = await Directory(p.join(dir.path, 'profiles')).create();
    await File(p.join(profilesDir.path, '$awsId.yaml')).writeAsString(_awsYaml);
    await File(
      p.join(profilesDir.path, '$legacyId.yaml'),
    ).writeAsString(_legacyYaml);
    await File(
      p.join(profilesDir.path, '$fileId.yaml'),
    ).writeAsString(_fileYaml);

    final old = Database(NativeDatabase(dbFile));
    await old.customSelect('SELECT 1').get();
    await old.profilesDao.setAll(fixtureProfiles());
    await old
        .into(old.proxyGroups)
        .insert(
          ProxyGroupsCompanion.insert(
            id: const Value(201),
            profileId: customId,
            name: '手动组',
            type: 'select',
            proxies: const Value(['DIRECT']),
          ),
        );
    await old
        .into(old.rules)
        .insert(
          RulesCompanion.insert(
            id: const Value(301),
            profileId: const Value(customId),
            ruleAction: RuleAction.MATCH,
            ruleTarget: const Value('手动组'),
          ),
        );
    await old.close();
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test(
    'profiles, selection, custom rows and files survive a reopen + migration',
    () async {
      final reopened = Database(NativeDatabase(dbFile));
      addTearDown(reopened.close);
      await reopened.customSelect('SELECT 1').get();

      expect(await userVersion(reopened), 20);

      final profiles = await reopened.profilesDao.query().get();
      expect(profiles.map((e) => e.id), [awsId, legacyId, fileId, customId]);
      final aws = profiles.firstWhere((e) => e.id == awsId);
      expect(aws.label, 'AWS订阅');
      expect(aws.url, 'https://subs.example.test/aws.yaml');
      expect(aws.currentGroupName, 'AWS组');
      expect(aws.selectedMap, {'AWS组': 'node-tokyo-ss'});
      expect(aws.order, 0);
      final legacy = profiles.firstWhere((e) => e.id == legacyId);
      expect(legacy.label, '192.0.2.21');
      expect(legacy.order, 1);
      expect(profiles.firstWhere((e) => e.id == fileId).label, '本地文件');
      expect(profiles.firstWhere((e) => e.id == customId).label, '自建档案');

      final groups = await reopened.proxyGroupsDao.query(customId).get();
      expect(groups.single.name, '手动组');
      final rules = await reopened.rulesDao.queryProfileRules(customId).get();
      expect(rules.single.ruleAction, RuleAction.MATCH);
      expect(rules.single.ruleTarget, '手动组');

      final persisted =
          jsonDecode(
                jsonEncode(
                  Config.realFromJson(
                    null,
                  ).copyWith(currentProfileId: awsId).toJson(),
                ),
              )
              as Map<String, Object?>;
      final store = _FixtureStore(configMap: persisted, upgradeVersion: 1);
      final config = await Migration(store: store).run();
      expect(config.currentProfileId, awsId);
      expect(store.restoreCalls, 0);
      // Nothing needs persisting when no upgrade transform fires; any
      // config the migration does save must keep the selection.
      final saved = store.savedConfig;
      if (saved != null) {
        expect(saved.currentProfileId, awsId);
      }

      final after = await reopened.profilesDao.query().get();
      expect(after.map((e) => e.id), [awsId, legacyId, fileId, customId]);

      expect(
        await File(p.join(profilesDir.path, '$awsId.yaml')).readAsString(),
        _awsYaml,
      );
      expect(
        await File(p.join(profilesDir.path, '$legacyId.yaml')).readAsString(),
        _legacyYaml,
      );
      expect(
        await File(p.join(profilesDir.path, '$fileId.yaml')).readAsString(),
        _fileYaml,
      );
    },
  );

  test('an explicit delete removes only the targeted profile', () async {
    final reopened = Database(NativeDatabase(dbFile));
    addTearDown(reopened.close);
    await reopened.customSelect('SELECT 1').get();

    await (reopened.delete(
      reopened.profiles,
    )..where((t) => t.id.equals(fileId))).go();

    final profiles = await reopened.profilesDao.query().get();
    expect(profiles.map((e) => e.id), [awsId, legacyId, customId]);
  });

  test('a fresh install opens an empty schema-20 store', () async {
    final freshFile = File(p.join(dir.path, 'fresh.sqlite'));
    final fresh = Database(NativeDatabase(freshFile));
    addTearDown(fresh.close);
    await fresh.customSelect('SELECT 1').get();

    expect(await userVersion(fresh), 20);
    expect(await fresh.profilesDao.query().get(), isEmpty);
  });

  test(
    'old-era raw configs rebuild with their rules respected or split-filled',
    () async {
      MakeRealProfileState stateFor(int id, Map<String, dynamic> raw) {
        return MakeRealProfileState(
          profilesPath: profilesDir.path,
          profileId: id,
          rawConfig: raw,
          realPatchConfig: const PatchClashConfig(),
          appendSystemDns: false,
          proxyGroups: const [],
          rules: const [],
          addedRules: const [],
          defaultUA: 'FlClash-Test',
        );
      }

      final awsResult = await makeRealProfileTask(
        stateFor(awsId, {
          'proxies': [
            _node('node-tokyo-ss', '203.0.113.11'),
            _node('node-taipei-ss', '198.51.100.12'),
          ],
          'proxy-groups': [
            {
              'name': 'AWS组',
              'type': 'select',
              'proxies': ['DIRECT', 'node-tokyo-ss', 'node-taipei-ss'],
            },
          ],
          'rules': ['MATCH,AWS组'],
        }),
      );
      final awsOut = loadYaml(awsResult.yaml) as YamlMap;
      expect(awsOut['rules'], ['MATCH,AWS组']);
      expect((awsOut['proxy-groups'] as YamlList).single['name'], 'AWS组');
      expect(awsResult.counts, (groups: 1, proxies: 2, rules: 1));

      final legacyResult = await makeRealProfileTask(
        stateFor(legacyId, {
          'proxies': [
            _node('legacy-a', '203.0.113.21'),
            _node('legacy-b', '203.0.113.22'),
          ],
        }),
      );
      final legacyOut = loadYaml(legacyResult.yaml) as YamlMap;
      expect(legacyOut['rules'], [
        'GEOIP,LAN,DIRECT,no-resolve',
        'GEOSITE,CN,DIRECT',
        'GEOIP,CN,DIRECT,no-resolve',
        'MATCH,节点选择',
      ]);
      final group = (legacyOut['proxy-groups'] as YamlList).single as YamlMap;
      expect(group['name'], '节点选择');
      expect(group['proxies'], ['legacy-a', 'legacy-b', 'DIRECT']);
      expect(legacyResult.counts, (groups: 1, proxies: 2, rules: 4));
    },
  );
}
