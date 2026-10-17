import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/block/desede_engine.dart';
import 'package:pointycastle/api.dart' show KeyParameter;

class RfbException implements Exception {
  final String message;
  RfbException(this.message);
  @override
  String toString() => message;
}

class _Reader {
  _Reader(Stream<Uint8List> stream) {
    _sub = stream.listen(
      (d) {
        _chunks.add(d);
        _available += d.length;
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<Uint8List> _chunks = [];
  int _offset = 0;
  int _available = 0;
  Completer<void>? _waiter;
  bool _closed = false;
  Object? _error;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  Future<void> _need(int n) async {
    while (_available < n) {
      if (_error != null) throw RfbException('连接错误：$_error');
      if (_closed) throw RfbException('连接已关闭');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  Future<Uint8List> read(int n) async {
    await _need(n);
    final out = Uint8List(n);
    var pos = 0;
    while (pos < n) {
      final c = _chunks.first;
      final take = (c.length - _offset).clamp(0, n - pos);
      out.setRange(pos, pos + take, c, _offset);
      pos += take;
      _offset += take;
      if (_offset >= c.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    _available -= n;
    return out;
  }

  /// 直接把数据读入 [target] 的指定位置，避免为大块像素数据额外分配内存。
  Future<void> readInto(Uint8List target, int start, int n) async {
    await _need(n);
    var pos = start;
    var remaining = n;
    while (remaining > 0) {
      final c = _chunks.first;
      final take = (c.length - _offset).clamp(0, remaining);
      target.setRange(pos, pos + take, c, _offset);
      pos += take;
      remaining -= take;
      _offset += take;
      if (_offset >= c.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    _available -= n;
  }

  Future<int> u8() async => (await read(1))[0];
  Future<int> u16() async {
    final b = await read(2);
    return (b[0] << 8) | b[1];
  }

  Future<int> u32() async {
    final b = await read(4);
    return ByteData.sublistView(b).getUint32(0);
  }

  Future<int> s32() async {
    final b = await read(4);
    return ByteData.sublistView(b).getInt32(0);
  }

  void cancel() => _sub.cancel();
}

/// 最小可用的 RFB(VNC) 客户端：支持 3.3/3.7/3.8 协议、无认证与 VNC 密码认证、Raw 与 CopyRect 编码。
class RfbClient {
  RfbClient({
    required Stream<Uint8List> input,
    required this.write,
    required this.password,
  }) : _r = _Reader(input);

  final _Reader _r;
  final void Function(List<int> data) write;
  final String password;

  int width = 0;
  int height = 0;
  String desktopName = '';
  Uint8List framebuffer = Uint8List(0);

  void Function()? onFrame;
  void Function()? onResize;
  void Function(String text)? onClipboard;
  void Function()? onBell;

  bool _closed = false;

  Future<void> handshake() async {
    final ver = ascii.decode(await _r.read(12));
    final m = RegExp(r'RFB (\d{3})\.(\d{3})').firstMatch(ver);
    if (m == null) throw RfbException('不是 VNC 服务器');
    final minor = int.parse(m.group(2)!);
    final useMinor = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3);
    write(ascii.encode('RFB 003.00$useMinor\n'));

    int secType;
    if (useMinor == 3) {
      secType = await _r.u32();
      if (secType == 0) throw RfbException(await _reason());
    } else {
      final n = await _r.u8();
      if (n == 0) throw RfbException(await _reason());
      final types = await _r.read(n);
      if (password.isNotEmpty && types.contains(2)) {
        secType = 2;
      } else if (types.contains(1)) {
        secType = 1;
      } else if (types.contains(2)) {
        secType = 2;
      } else {
        throw RfbException('服务器要求的认证方式不受支持：${types.join(',')}');
      }
      write([secType]);
    }

    if (secType == 2) {
      final challenge = await _r.read(16);
      write(_vncAuth(challenge, password));
    } else if (secType != 1) {
      throw RfbException('服务器要求的认证方式不受支持：$secType');
    }

    if (secType == 2 || useMinor == 8) {
      final result = await _r.u32();
      if (result != 0) {
        final reason = useMinor == 8 ? await _reason() : '';
        throw RfbException('VNC 认证失败${reason.isEmpty ? '' : '：$reason'}');
      }
    }

    write([1]);

    width = await _r.u16();
    height = await _r.u16();
    await _r.read(16);
    final nameLen = await _r.u32();
    desktopName = utf8.decode(await _r.read(nameLen), allowMalformed: true);
    framebuffer = Uint8List(width * height * 4);

    // 32 位真彩色，内存中按 R G B X 排列，正好对应 RGBA8888。
    write([
      0, 0, 0, 0,
      32, 24, 0, 1,
      0, 255, 0, 255, 0, 255,
      0, 8, 16,
      0, 0, 0,
    ]);
    final encodings = [1, 0, -223];
    final enc = ByteData(4 + encodings.length * 4)
      ..setUint8(0, 2)
      ..setUint16(2, encodings.length);
    for (var i = 0; i < encodings.length; i++) {
      enc.setInt32(4 + i * 4, encodings[i]);
    }
    write(enc.buffer.asUint8List());
    requestUpdate(incremental: false);
  }

  Future<String> _reason() async {
    final len = await _r.u32();
    return utf8.decode(await _r.read(len), allowMalformed: true);
  }

  static Uint8List _vncAuth(Uint8List challenge, String password) {
    final key = Uint8List(8);
    final pw = latin1.encode(password.length > 8 ? password.substring(0, 8) : password);
    for (var i = 0; i < pw.length; i++) {
      var b = pw[i];
      var r = 0;
      for (var j = 0; j < 8; j++) {
        r = (r << 1) | (b & 1);
        b >>= 1;
      }
      key[i] = r;
    }
    final des = DESedeEngine()
      ..init(true, KeyParameter(Uint8List.fromList([...key, ...key, ...key])));
    final out = Uint8List(16);
    des.processBlock(challenge, 0, out, 0);
    des.processBlock(challenge, 8, out, 8);
    return out;
  }

  void requestUpdate({bool incremental = true}) {
    if (_closed) return;
    final b = ByteData(10)
      ..setUint8(0, 3)
      ..setUint8(1, incremental ? 1 : 0)
      ..setUint16(2, 0)
      ..setUint16(4, 0)
      ..setUint16(6, width)
      ..setUint16(8, height);
    write(b.buffer.asUint8List());
  }

  Future<void> run() async {
    try {
      while (!_closed) {
        final type = await _r.u8();
        switch (type) {
          case 0:
            await _framebufferUpdate();
            onFrame?.call();
            requestUpdate();
            break;
          case 1:
            await _r.read(1);
            await _r.u16();
            final n = await _r.u16();
            await _r.read(n * 6);
            break;
          case 2:
            onBell?.call();
            break;
          case 3:
            await _r.read(3);
            final len = await _r.u32();
            final text = latin1.decode(await _r.read(len));
            onClipboard?.call(text);
            break;
          default:
            throw RfbException('收到未知的服务器消息类型：$type');
        }
      }
    } finally {
      _closed = true;
    }
  }

  Future<void> _framebufferUpdate() async {
    await _r.read(1);
    final rects = await _r.u16();
    for (var i = 0; i < rects; i++) {
      final x = await _r.u16();
      final y = await _r.u16();
      final w = await _r.u16();
      final h = await _r.u16();
      final enc = await _r.s32();
      switch (enc) {
        case 0:
          await _raw(x, y, w, h);
          break;
        case 1:
          final sx = await _r.u16();
          final sy = await _r.u16();
          _copyRect(sx, sy, x, y, w, h);
          break;
        case -223:
          width = w;
          height = h;
          framebuffer = Uint8List(width * height * 4);
          onResize?.call();
          break;
        default:
          throw RfbException('服务器使用了不支持的编码：$enc');
      }
    }
  }

  Future<void> _raw(int x, int y, int w, int h) async {
    if (w == 0 || h == 0) return;
    final rowBytes = w * 4;
    if (x == 0 && w == width) {
      final start = y * width * 4;
      await _r.readInto(framebuffer, start, rowBytes * h);
      for (var i = start + 3; i < start + rowBytes * h; i += 4) {
        framebuffer[i] = 255;
      }
      return;
    }
    for (var row = 0; row < h; row++) {
      final start = ((y + row) * width + x) * 4;
      await _r.readInto(framebuffer, start, rowBytes);
      for (var i = start + 3; i < start + rowBytes; i += 4) {
        framebuffer[i] = 255;
      }
    }
  }

  void _copyRect(int sx, int sy, int dx, int dy, int w, int h) {
    final rowBytes = w * 4;
    final copy = Uint8List(rowBytes * h);
    for (var row = 0; row < h; row++) {
      final s = ((sy + row) * width + sx) * 4;
      copy.setRange(row * rowBytes, (row + 1) * rowBytes, framebuffer, s);
    }
    for (var row = 0; row < h; row++) {
      final d = ((dy + row) * width + dx) * 4;
      framebuffer.setRange(d, d + rowBytes, copy, row * rowBytes);
    }
  }

  void sendPointer(int x, int y, int buttonMask) {
    if (_closed) return;
    final b = ByteData(6)
      ..setUint8(0, 5)
      ..setUint8(1, buttonMask)
      ..setUint16(2, x.clamp(0, width - 1))
      ..setUint16(4, y.clamp(0, height - 1));
    write(b.buffer.asUint8List());
  }

  void sendKey(int keysym, bool down) {
    if (_closed) return;
    final b = ByteData(8)
      ..setUint8(0, 4)
      ..setUint8(1, down ? 1 : 0)
      ..setUint32(4, keysym);
    write(b.buffer.asUint8List());
  }

  void sendClipboard(String text) {
    if (_closed) return;
    final data = latin1.encode(
        String.fromCharCodes(text.runes.map((r) => r > 255 ? 63 : r)));
    final b = ByteData(8)
      ..setUint8(0, 6)
      ..setUint32(4, data.length);
    write([...b.buffer.asUint8List(), ...data]);
  }

  void close() {
    _closed = true;
    _r.cancel();
  }
}
