import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';
import 'package:ssh_restart/services/ssh/transfer_worker.dart';

void main() {
  test('后台传输线程连接失败时抛出错误，便于回退到主连接', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();

    final s = SessionConfig(host: '127.0.0.1', port: port, password: 'x');
    await expectLater(
      TransferWorker.start(s, AppStore()),
      throwsA(isA<StateError>()),
    );
  });

  test('服务器不说 SSH 协议时同样失败而不是卡住', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((c) {
      c.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      c.destroy();
    });
    final s = SessionConfig(host: '127.0.0.1', port: server.port, password: 'x');
    await expectLater(
      TransferWorker.start(s, AppStore()),
      throwsA(anything),
    );
    await server.close();
  });
}
