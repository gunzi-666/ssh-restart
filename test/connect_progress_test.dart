import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';
import 'package:ssh_restart/services/ssh/ssh_connector.dart';
import 'package:ssh_restart/state/connect_progress.dart';

Future<ConnectProgress> _tryConnect(int port) async {
  final p = ConnectProgress()..begin('初始化配置');
  final s = SessionConfig(name: 't', host: '127.0.0.1', password: 'x')
    ..port = port;
  try {
    final r = await SSHConnector.connect(s, AppStore(), progress: p);
    r.closeAll();
    p.finish();
  } catch (e) {
    p.fail(SSHConnector.describeError(e));
  }
  return p;
}

void main() {
  test('端口未开放时失败在「连接到服务器」', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final p = await _tryConnect(port);
    expect(p.steps.last.label, '连接到服务器');
    expect(p.steps.last.state, ConnectStepState.failed);
    expect(p.error, isNotNull);
  });

  test('握手中断时失败在「配置连接协议」', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((c) async {
      c.write('SSH-2.0-FakeServer\r\n');
      await c.flush();
      await Future.delayed(const Duration(milliseconds: 100));
      await c.close();
    });

    final p = await _tryConnect(server.port);
    await server.close();
    expect(p.steps.map((s) => s.label),
        containsAllInOrder(['初始化配置', '连接到服务器', '配置连接协议']));
    expect(p.steps.last.state, ConnectStepState.failed);
    expect(p.logs.map((l) => l.text), contains('服务器版本：SSH-2.0-FakeServer'));
  });
}
