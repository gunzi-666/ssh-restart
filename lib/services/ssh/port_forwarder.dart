import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../models/session_config.dart';

class ActiveForward {
  ActiveForward(this.config);
  final PortForward config;
  bool running = false;
  String status = '未启动';
  int connections = 0;
  ServerSocket? _server;
  SSHRemoteForward? _remote;
  SSHDynamicForward? _dynamic;
  final Set<Socket> _sockets = {};
}

/// 管理一个 SSH 连接上的本地转发(-L)、远程转发(-R)和动态 SOCKS5 转发(-D)。
class PortForwardManager extends ChangeNotifier {
  PortForwardManager(this.client);

  final SSHClient client;
  final List<ActiveForward> items = [];

  Future<void> startAll(List<PortForward> forwards) async {
    for (final f in forwards.where((f) => f.enabled)) {
      await start(f);
    }
  }

  ActiveForward _entry(PortForward f) {
    final existing = items.where((e) => e.config.id == f.id).firstOrNull;
    if (existing != null) return existing;
    final e = ActiveForward(f);
    items.add(e);
    return e;
  }

  Future<void> start(PortForward f) async {
    final e = _entry(f);
    if (e.running) return;
    try {
      switch (f.type) {
        case ForwardType.local:
          final server = await ServerSocket.bind(f.bindHost, f.bindPort);
          e._server = server;
          server.listen((sock) async {
            e._sockets.add(sock);
            e.connections++;
            notifyListeners();
            try {
              final ch = await client.forwardLocal(f.destHost, f.destPort);
              _pipe(sock, ch, () {
                e._sockets.remove(sock);
                e.connections--;
                notifyListeners();
              });
            } catch (err) {
              sock.destroy();
              e._sockets.remove(sock);
              e.connections--;
              e.status = '连接目标失败：$err';
              notifyListeners();
            }
          });
          e.status = '监听 ${f.bindHost}:${server.port}';
          break;
        case ForwardType.remote:
          final rf = await client.forwardRemote(
              host: f.bindHost.isEmpty ? null : f.bindHost, port: f.bindPort);
          if (rf == null) throw StateError('服务器拒绝了远程转发请求');
          e._remote = rf;
          rf.connections.listen((ch) async {
            try {
              final sock = await Socket.connect(f.destHost, f.destPort,
                  timeout: const Duration(seconds: 10));
              e._sockets.add(sock);
              e.connections++;
              notifyListeners();
              _pipe(sock, ch, () {
                e._sockets.remove(sock);
                e.connections--;
                notifyListeners();
              });
            } catch (err) {
              ch.destroy();
              e.status = '连接本地目标失败：$err';
              notifyListeners();
            }
          });
          e.status = '远程监听 ${f.bindHost}:${rf.port}';
          break;
        case ForwardType.dynamic:
          final d = await client.forwardDynamic(
              bindHost: f.bindHost, bindPort: f.bindPort);
          e._dynamic = d;
          e.status = 'SOCKS5 ${f.bindHost}:${f.bindPort}';
          break;
      }
      e.running = true;
    } catch (err) {
      e.running = false;
      e.status = '启动失败：$err';
    }
    notifyListeners();
  }

  void _pipe(Socket sock, SSHForwardChannel ch, VoidCallback onClosed) {
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      sock.destroy();
      ch.destroy();
      onClosed();
    }

    ch.stream.listen(
      (d) {
        try {
          sock.add(d);
        } catch (_) {
          close();
        }
      },
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
    sock.listen(
      (d) {
        try {
          ch.sink.add(d);
        } catch (_) {
          close();
        }
      },
      onDone: close,
      onError: (_) => close(),
      cancelOnError: true,
    );
  }

  Future<void> stop(String id) async {
    final e = items.where((x) => x.config.id == id).firstOrNull;
    if (e == null) return;
    await e._server?.close();
    e._remote?.close();
    await e._dynamic?.close();
    for (final s in e._sockets.toList()) {
      s.destroy();
    }
    e._sockets.clear();
    e._server = null;
    e._remote = null;
    e._dynamic = null;
    e.running = false;
    e.connections = 0;
    e.status = '已停止';
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await stop(id);
    items.removeWhere((e) => e.config.id == id);
    notifyListeners();
  }

  Future<void> stopAll() async {
    for (final e in items.toList()) {
      await stop(e.config.id);
    }
  }
}
