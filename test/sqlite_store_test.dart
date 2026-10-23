import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';
import 'package:ssh_restart/services/sqlite_store.dart';

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
  });

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ssh_restart_test'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> legacyJson() => {
    'sessions': [
      SessionConfig(name: 'a', host: '10.0.0.1', password: 'pw1').toJson(),
      SessionConfig(name: 'b', host: '10.0.0.2', groupId: 'g1').toJson(),
    ],
    'groups': [SessionGroup(name: '生产').toJson()..['id'] = 'g1'],
    'quickCommands': [],
    'history': ['ls -la'],
    'knownHosts': {'10.0.0.1:22': 'abc'},
    'settings': {'uiStyle': 'fluent', 'terminalFontSize': 16},
  };

  test('首次启动把 data.json 迁移进数据库，校验通过后删除 data.json', () async {
    File(
      p.join(dir.path, 'data.json'),
    ).writeAsStringSync(jsonEncode(legacyJson()));

    final store = AppStore();
    await store.loadFrom(dir);
    expect(File(p.join(dir.path, 'data.json')).existsSync(), isFalse);
    expect(File(p.join(dir.path, AppStore.dbName)).existsSync(), isTrue);
    expect(store.sessions.length, 2);
    await store.saveNow();

    final again = AppStore();
    await again.loadFrom(dir);
    expect(again.sessions.map((s) => s.host).toSet(), {'10.0.0.1', '10.0.0.2'});
    expect(again.sessions.firstWhere((s) => s.name == 'a').password, 'pw1');
    expect(again.groups.single.name, '生产');
    expect(again.history, ['ls -la']);
    expect(again.knownHosts['10.0.0.1:22'], 'abc');
    expect(again.settings.uiStyle, 'fluent');
    expect(again.settings.terminalFontSize, 16);
  });

  test('损坏的 data.json 不会被删除', () async {
    final legacy = File(p.join(dir.path, 'data.json'))
      ..writeAsStringSync('{broken');
    final store = AppStore();
    await store.loadFrom(dir);
    expect(legacy.existsSync(), isTrue);
  });

  test('只写入变化的行，删除的行会被移除', () {
    final db = SqliteStore.memory();
    expect(db.sync(SqliteStore.sessions, {'1': 'a', '2': 'b'}), 2);
    expect(db.sync(SqliteStore.sessions, {'1': 'a', '2': 'b'}), 0);
    expect(db.sync(SqliteStore.sessions, {'1': 'a2'}), 2);
    expect(db.read(SqliteStore.sessions), {'1': 'a2'});
    db.close();
  });

  test('启动密码：设置、校验、关闭', () async {
    final store = AppStore();
    await store.loadFrom(dir);
    expect(store.hasStartupPassword, isFalse);
    await store.setStartupPassword('secret');
    expect(store.hasStartupPassword, isTrue);
    expect(await store.verifyStartupPassword('secret'), isTrue);
    expect(await store.verifyStartupPassword('wrong'), isFalse);
    store.clearStartupPassword();
    expect(store.hasStartupPassword, isFalse);
  });

  test('清除所有数据会删除目录内的数据文件', () async {
    final store = AppStore();
    await store.loadFrom(dir);
    store.upsertSession(SessionConfig(name: 'x', host: '1.1.1.1'));
    await store.saveNow();
    File(p.join(dir.path, 'data.json.bak')).writeAsStringSync('old');

    await store.clearAllData();
    expect(store.sessions, isEmpty);
    expect(File(p.join(dir.path, 'data.json.bak')).existsSync(), isFalse);

    final again = AppStore();
    await again.loadFrom(dir);
    expect(again.sessions, isEmpty);
  });
}
