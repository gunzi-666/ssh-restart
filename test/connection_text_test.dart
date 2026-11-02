import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/services/connection_text.dart';

void main() {
  test('本软件复制的单台连接信息', () {
    final r = parseConnectionText('IP：1.2.3.4\n端口：2222\n用户名：root\n密码：p@ss word');
    expect(r, hasLength(1));
    expect(r.first.host, '1.2.3.4');
    expect(r.first.port, 2222);
    expect(r.first.username, 'root');
    expect(r.first.password, 'p@ss word');
  });

  test('本软件批量复制的多台连接信息', () {
    final r = parseConnectionText(
      '【香港】\nIP：1.1.1.1\n端口：22\n用户名：root\n密码：a\n\n'
      '【日本】\nIP：2.2.2.2\n端口：2200\n用户名：admin\n认证方式：密钥',
    );
    expect(r, hasLength(2));
    expect(r[0].name, '香港');
    expect(r[0].password, 'a');
    expect(r[1].name, '日本');
    expect(r[1].port, 2200);
    expect(r[1].keyAuth, isTrue);
  });

  test('同一行多个字段与英文冒号', () {
    final r = parseConnectionText('IP: 5.6.7.8 Port: 30022 User: ubuntu Password: Abc 123');
    expect(r.single.host, '5.6.7.8');
    expect(r.single.port, 30022);
    expect(r.single.username, 'ubuntu');
    expect(r.single.password, 'Abc 123');
  });

  test('ssh 命令与 user@host:port', () {
    final a = parseConnectionText('ssh -p 2022 root@example.com').single;
    expect(a.host, 'example.com');
    expect(a.port, 2022);
    expect(a.username, 'root');

    final b = parseConnectionText('admin@10.0.0.8:2200\n密码：xyz').single;
    expect(b.host, '10.0.0.8');
    expect(b.port, 2200);
    expect(b.username, 'admin');
    expect(b.password, 'xyz');
  });

  test('主机字段带端口；空行分隔但只有一段带主机时视为一台', () {
    final r = parseConnectionText('服务器地址：9.9.9.9:2201\n\n账号：root\n密码：q');
    expect(r.single.host, '9.9.9.9');
    expect(r.single.port, 2201);
    expect(r.single.username, 'root');
    expect(r.single.password, 'q');
  });

  test('识别不到主机时返回空', () {
    expect(parseConnectionText('用户名：root\n密码：x'), isEmpty);
  });
}
