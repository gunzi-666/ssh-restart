import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/finalshell_import.dart';

/// 由 Java 版 FinalShell 密码加密算法生成的测试向量（密文, 明文）。
const _vectors = [
  ['r63OtS/aNT99LnNWU0Z/oA==', 'root123'],
  ['owCp+C5cNtgfYVRbwFg+0w==', 'root123'],
  ['QTnfQCV95tV23rbj5DU02fhza7VhVewh', 'P@ssw0rd!#2024'],
  ['Gv81ofwoyTeQr7p9ximrJyQdSTCFgP6E', 'P@ssw0rd!#2024'],
  ['SDxpxHuur2dnh1mzytO9ww==', 'a'],
  ['1vJSFn6FjdwN1k6L9Nmu9A==', 'a'],
  ['7BTxFdl+v3bIhS6+WjthFzOTMXZaN1VF', '12345678'],
  ['U68uKZul7r6HaXXKQgGukzFu4BnnsXO/', '12345678'],
  ['/s+8Un8FUndLSKMGlGHKpqbbTmiBZLxJBwjvOvpfRlw=', '中文密码测试'],
  ['Cplhlc83eN2jwS7NDOBsTJ6OrM4/wy3Jd8eFNobb9gg=', '中文密码测试'],
  [
    'r63OtS/aNT+tZeWt7suuDFX+seuKUc5i/mU32XuKIWyiQiwYbxY+sQ3M7+uMD9EzFCEmRLfdYrQ=',
    'very-long-password-with-more-than-sixteen-chars'
  ],
];

Uint8List _json(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

void main() {
  test('解密 FinalShell 密码', () {
    for (final v in _vectors) {
      expect(FinalShellImporter.decodePassword(v[0]), v[1]);
    }
    expect(FinalShellImporter.decodePassword('not-base64!!'), isNull);
  });

  test('解析连接、分组和私钥', () {
    final r = FinalShellImporter.fromFiles({
      'f1_folder_config.json': _json(
          {'id': 'f1', 'name': '生产环境', 'parent_id': 'root'}),
      'f2_folder_config.json':
          _json({'id': 'f2', 'name': '数据库', 'parent_id': 'f1'}),
      'a_connect_config.json': _json({
        'id': 'a',
        'name': 'web-01',
        'host': '10.0.0.1',
        'port': 2222,
        'user_name': 'root',
        'password': _vectors[0][0],
        'authentication_type': 1,
        'conection_type': 100,
        'parent_id': 'f2',
        'terminal_encoding': 'GBK',
      }),
      'b_connect_config.json': _json({
        'id': 'b',
        'name': 'key-host',
        'host': 'example.com',
        'port': '22',
        'user_name': 'ubuntu',
        'authentication_type': 2,
        'secret_key_id': 'k1',
        'conection_type': 100,
        'parent_id': 'root',
      }),
      'c_connect_config.json': _json({
        'id': 'c',
        'name': 'win',
        'host': '10.0.0.9',
        'port': 3389,
        'conection_type': 101,
      }),
      'config.json': _json({
        'secret_key_list': [
          {
            'id': 'k1',
            'name': 'mykey',
            'key_data': '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
          }
        ]
      }),
    });

    expect(r.sessions.length, 2);
    expect(r.skippedOther, 1);
    expect(r.passwordOk, 1);
    expect(r.keyMatched, 1);

    final a = r.sessions.firstWhere((s) => s.host == '10.0.0.1');
    expect(a.port, 2222);
    expect(a.password, 'root123');
    expect(a.charset, 'GBK');
    final db = r.groups.firstWhere((g) => g.id == a.groupId);
    expect(db.name, '数据库');
    expect(r.groups.firstWhere((g) => g.id == db.parentId).name, '生产环境');

    final b = r.sessions.firstWhere((s) => s.host == 'example.com');
    expect(b.authType, AuthType.key);
    expect(b.privateKey, contains('BEGIN OPENSSH'));
    expect(b.groupId, isNull);
  });

  test('跳过 backup / deleted 目录中的历史副本，同一连接只保留一份', () {
    List<int> conn(String id, String host) => utf8.encode(jsonEncode({
          'id': id,
          'name': host,
          'host': host,
          'port': 22,
          'user_name': 'root',
          'conection_type': 100,
        }));
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('finalshell/conn/a_connect_config.json', conn('a', '1.1.1.1')))
      ..addFile(ArchiveFile.bytes('finalshell/conn/b_connect_config.json', conn('b', '2.2.2.2')))
      ..addFile(ArchiveFile.bytes(
          'finalshell/backup/connect_config_a/1714755758985.json', conn('a', '1.1.1.1')))
      ..addFile(ArchiveFile.bytes(
          'finalshell/deleted/20240424193149071/c_connect_config.json', conn('c', '3.3.3.3')))
      ..addFile(ArchiveFile.bytes('finalshell/conn/copy/a_connect_config.json', conn('a', '1.1.1.1')));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    final r = FinalShellImporter.fromFiles({'finalshell.zip': zip});
    expect(r.sessions.map((s) => s.host), ['1.1.1.1', '2.2.2.2']);
  });

  test('解析快捷命令：按顺序、跳过已删除和空命令、保留回车设置', () {
    final text = jsonEncode({
      'font_size': 14,
      'quick_commands': [
        {
          'name': '运维',
          'order': 2,
          'delete_time': 0,
          'commands': [
            {'name': '看磁盘', 'command': 'df -h', 'append_cr': true, 'order': 1},
            {'name': '空', 'command': '  ', 'append_cr': true, 'order': 2},
          ],
        },
        {
          'name': '常用',
          'order': 1,
          'commands': [
            {'name': '多行', 'command': 'cd /tmp\nls', 'append_cr': false, 'order': 2},
            {'name': '已删', 'command': 'rm x', 'delete_time': 1700000000, 'order': 3},
            {'name': '进程', 'command': 'top', 'order': 1},
          ],
        },
        {
          'name': '旧分组',
          'delete_time': 1700000000,
          'commands': [
            {'name': 'a', 'command': 'uptime'},
          ],
        },
      ],
    });
    final list = FinalShellCommandImporter.parse(text)!;
    expect(list.map((q) => '${q.group}/${q.name}'),
        ['常用/进程', '常用/多行', '运维/看磁盘']);
    expect(list[1].command, 'cd /tmp\nls');
    expect(list[1].appendEnter, isFalse);
    expect(list[0].appendEnter, isTrue);

    expect(FinalShellCommandImporter.parse('{"host": "x"}'), isNull);
    expect(FinalShellCommandImporter.parse('不是 json'), isNull);
    expect(
        FinalShellCommandImporter.fromFiles(
            {'config.json': Uint8List.fromList(utf8.encode(text))})!.length,
        3);
  });
}
