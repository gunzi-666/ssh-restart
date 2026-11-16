import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ssh_restart/services/app_store.dart';

void main() {
  late Directory home;
  late Directory oldDir;
  late Directory newDir;
  const bundle = 'com.sshrestart.sshRestart';

  setUp(() {
    home = Directory.systemTemp.createTempSync('sshr_home');
    oldDir = Directory(p.join(home.path, 'Library', 'Containers', bundle, 'Data',
        'Library', 'Application Support', bundle))
      ..createSync(recursive: true);
    newDir = Directory(p.join(home.path, 'Library', 'Application Support', bundle))
      ..createSync(recursive: true);
  });

  tearDown(() => home.deleteSync(recursive: true));

  test('新目录没有数据时从沙盒目录复制，原文件保留', () {
    File(p.join(oldDir.path, AppStore.dbName)).writeAsStringSync('db');
    File(p.join(oldDir.path, 'sub', 'x.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');

    AppStore.migrateFromSandbox(newDir, home.path);

    expect(File(p.join(newDir.path, AppStore.dbName)).readAsStringSync(), 'db');
    expect(File(p.join(newDir.path, 'sub', 'x.txt')).readAsStringSync(), 'x');
    expect(File(p.join(oldDir.path, AppStore.dbName)).existsSync(), isTrue);
  });

  test('新目录已有数据时不覆盖', () {
    File(p.join(oldDir.path, AppStore.dbName)).writeAsStringSync('old');
    File(p.join(newDir.path, AppStore.dbName)).writeAsStringSync('new');

    AppStore.migrateFromSandbox(newDir, home.path);

    expect(File(p.join(newDir.path, AppStore.dbName)).readAsStringSync(), 'new');
  });
}
