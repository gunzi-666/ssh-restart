@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ssh_restart/services/updater.dart';

String _sys(String exe) => p.join(
  Platform.environment['SystemRoot'] ?? r'C:\Windows',
  'System32',
  exe,
);

void main() {
  late Directory base;
  late Directory src;
  late Directory dst;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('更新 测试 ');
    src = Directory(p.join(base.path, '新 版本'))..createSync();
    dst = Directory(p.join(base.path, '安装 目录'))..createSync();
    File(_sys('whoami.exe')).copySync(p.join(src.path, 'ssh_restart.exe'));
    Directory(p.join(src.path, 'data')).createSync();
    File(p.join(src.path, 'data', '新文件.txt')).writeAsStringSync('v2');
    File(p.join(dst.path, '旧文件.txt')).writeAsStringSync('v1');
    // 用 ping.exe 冒充正在运行的旧版本：运行期间其可执行文件被系统锁定。
    File(_sys('PING.EXE')).copySync(p.join(dst.path, 'ssh_restart.exe'));
  });

  tearDown(() => base.delete(recursive: true).catchError((_) => base));

  test('等待旧程序退出后覆盖文件（中文与空格路径）', () async {
    final old = await Process.start(p.join(dst.path, 'ssh_restart.exe'), [
      '-n',
      '4',
      '127.0.0.1',
    ]);
    old.stdout.drain<void>();
    old.stderr.drain<void>();
    var exited = false;
    old.exitCode.then((_) => exited = true);

    final logs = <String>[];
    final ok = await Updater.applyUpdate(
      src: src.path,
      dst: dst.path,
      log: logs.add,
    );

    expect(ok, isTrue, reason: logs.join('\n'));
    expect(exited, isTrue, reason: '必须等旧程序退出后才能覆盖');
    expect(
      File(p.join(dst.path, 'ssh_restart.exe')).lengthSync(),
      File(_sys('whoami.exe')).lengthSync(),
    );
    expect(File(p.join(dst.path, 'data', '新文件.txt')).readAsStringSync(), 'v2');
    expect(File(p.join(dst.path, '旧文件.txt')).existsSync(), isTrue);
    expect(logs.last, contains('文件替换完成'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('旧程序一直不退出时超时放弃', () async {
    final old = await Process.start(p.join(dst.path, 'ssh_restart.exe'), [
      '-n',
      '30',
      '127.0.0.1',
    ]);
    old.stdout.drain<void>();
    old.stderr.drain<void>();
    addTearDown(old.kill);

    final logs = <String>[];
    final ok = await Updater.applyUpdate(
      src: src.path,
      dst: dst.path,
      log: logs.add,
      timeout: const Duration(seconds: 2),
    );
    expect(ok, isFalse);
    expect(logs.last, contains('等待超时'));
    expect(File(p.join(dst.path, 'data', '新文件.txt')).existsSync(), isFalse);
    old.kill();
    await old.exitCode;
  }, timeout: const Timeout(Duration(seconds: 60)));
}
