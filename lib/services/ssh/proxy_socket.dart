import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../models/session_config.dart';

class ProxyException implements Exception {
  final String message;
  ProxyException(this.message);
  @override
  String toString() => '代理错误：$message';
}

/// 先经由 HTTP CONNECT 或 SOCKS5 代理建立隧道，握手完成后作为普通 [SSHSocket] 使用。
class ProxiedSocket implements SSHSocket {
  ProxiedSocket._(this._socket) {
    _sub = _socket.listen(
      (d) {
        if (_ready) {
          _ctrl.add(d);
        } else {
          _buf.addAll(d);
          _wake();
        }
      },
      onError: (Object e, StackTrace st) {
        if (_ready) {
          _ctrl.addError(e, st);
        } else {
          _error = e;
          _wake();
        }
      },
      onDone: () {
        _closed = true;
        if (_ready) {
          _ctrl.close();
        } else {
          _wake();
        }
      },
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _ctrl = StreamController<Uint8List>();
  final List<int> _buf = [];
  Completer<void>? _waiter;
  bool _ready = false;
  bool _closed = false;
  Object? _error;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  Future<void> _waitData() async {
    if (_error != null) throw ProxyException('$_error');
    if (_closed) throw ProxyException('代理服务器关闭了连接');
    _waiter = Completer<void>();
    await _waiter!.future.timeout(const Duration(seconds: 20));
    if (_error != null) throw ProxyException('$_error');
  }

  Future<List<int>> _read(int n) async {
    while (_buf.length < n) {
      await _waitData();
    }
    final r = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return r;
  }

  void _finish() {
    _ready = true;
    if (_buf.isNotEmpty) {
      _ctrl.add(Uint8List.fromList(_buf));
      _buf.clear();
    }
  }

  static Future<SSHSocket> connect(
      ProxyConfig proxy, String host, int port) async {
    final raw = await Socket.connect(proxy.host, proxy.port,
        timeout: const Duration(seconds: 15));
    raw.setOption(SocketOption.tcpNoDelay, true);
    final s = ProxiedSocket._(raw);
    try {
      if (proxy.type == ProxyType.http) {
        await s._httpConnect(proxy, host, port);
      } else {
        await s._socks5Connect(proxy, host, port);
      }
      s._finish();
      return s;
    } catch (_) {
      s.destroy();
      rethrow;
    }
  }

  Future<void> _httpConnect(ProxyConfig proxy, String host, int port) async {
    final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
    final sb = StringBuffer()
      ..write('CONNECT $target HTTP/1.1\r\n')
      ..write('Host: $target\r\n')
      ..write('Proxy-Connection: Keep-Alive\r\n');
    if (proxy.username.isNotEmpty) {
      final token =
          base64Encode(utf8.encode('${proxy.username}:${proxy.password}'));
      sb.write('Proxy-Authorization: Basic $token\r\n');
    }
    sb.write('\r\n');
    _socket.add(utf8.encode(sb.toString()));
    await _socket.flush();

    while (true) {
      final idx = _indexOf(_buf, const [13, 10, 13, 10]);
      if (idx >= 0) {
        final header = latin1.decode(_buf.sublist(0, idx));
        _buf.removeRange(0, idx + 4);
        final status = header.split('\r\n').first;
        final parts = status.split(' ');
        if (parts.length < 2 || parts[1] != '200') {
          throw ProxyException('HTTP 代理拒绝连接：$status');
        }
        return;
      }
      if (_buf.length > 16384) throw ProxyException('HTTP 代理响应过长');
      await _waitData();
    }
  }

  Future<void> _socks5Connect(ProxyConfig proxy, String host, int port) async {
    final useAuth = proxy.username.isNotEmpty;
    _socket.add(useAuth ? [5, 2, 0, 2] : [5, 1, 0]);
    await _socket.flush();
    final hello = await _read(2);
    if (hello[0] != 5) throw ProxyException('不是 SOCKS5 代理');
    if (hello[1] == 2) {
      final u = utf8.encode(proxy.username);
      final p = utf8.encode(proxy.password);
      _socket.add([1, u.length, ...u, p.length, ...p]);
      await _socket.flush();
      final auth = await _read(2);
      if (auth[1] != 0) throw ProxyException('SOCKS5 用户名或密码错误');
    } else if (hello[1] != 0) {
      throw ProxyException('SOCKS5 代理不支持所需的认证方式');
    }

    final req = <int>[5, 1, 0];
    final ip = InternetAddress.tryParse(host);
    if (ip != null && ip.type == InternetAddressType.IPv4) {
      req
        ..add(1)
        ..addAll(ip.rawAddress);
    } else if (ip != null && ip.type == InternetAddressType.IPv6) {
      req
        ..add(4)
        ..addAll(ip.rawAddress);
    } else {
      final h = utf8.encode(host);
      req
        ..add(3)
        ..add(h.length)
        ..addAll(h);
    }
    req.addAll([(port >> 8) & 0xff, port & 0xff]);
    _socket.add(req);
    await _socket.flush();

    final head = await _read(4);
    if (head[1] != 0) {
      throw ProxyException('SOCKS5 连接目标失败，错误码 ${head[1]}');
    }
    switch (head[3]) {
      case 1:
        await _read(4 + 2);
        break;
      case 4:
        await _read(16 + 2);
        break;
      case 3:
        final len = (await _read(1))[0];
        await _read(len + 2);
        break;
    }
  }

  static int _indexOf(List<int> data, List<int> pattern) {
    for (var i = 0; i <= data.length - pattern.length; i++) {
      var ok = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  @override
  Stream<Uint8List> get stream => _ctrl.stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  void destroy() {
    _sub.cancel();
    _socket.destroy();
    if (!_ctrl.isClosed) _ctrl.close();
  }

  @override
  Future<void> flush() => _socket.flush();
}
