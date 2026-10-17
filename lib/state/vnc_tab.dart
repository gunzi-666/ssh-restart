import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/app_store.dart';
import '../services/ssh/ssh_connector.dart';
import '../services/vnc/rfb_client.dart';
import 'app_tab.dart';

/// VNC 远程桌面标签页，可直连，也可经由已保存的 SSH 会话建立隧道。
class VncTab extends AppTab {
  VncTab(super.config, this.store);

  final AppStore store;
  RfbClient? rfb;
  ui.Image? image;
  Socket? _socket;
  SSHConnectResult? _tunnel;
  bool _dirty = false;
  bool _decoding = false;
  Timer? _frameTimer;
  int _seq = 0;
  void Function(String text)? onRemoteClipboard;

  @override
  Future<void> connect() async {
    final seq = ++_seq;
    await _teardown();
    setStatus(TabStatus.connecting);
    try {
      Stream<Uint8List> input;
      void Function(List<int>) write;
      final jump = store.sessionById(config.jumpSessionId);
      if (jump != null) {
        final t = await SSHConnector.connect(jump, store);
        _tunnel = t;
        final ch = await t.client.forwardLocal(config.host, config.port);
        input = ch.stream;
        write = (d) => ch.sink.add(d);
      } else {
        final s = await Socket.connect(config.host, config.port,
            timeout: const Duration(seconds: 15));
        s.setOption(SocketOption.tcpNoDelay, true);
        _socket = s;
        input = s;
        write = s.add;
      }
      final client = RfbClient(input: input, write: write, password: config.password);
      rfb = client;
      await client.handshake();
      if (seq != _seq) return;
      client.onFrame = () => _dirty = true;
      client.onResize = () => _dirty = true;
      client.onClipboard = (t) => onRemoteClipboard?.call(t);
      _frameTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => _render());
      store.touchSession(config.id);
      setStatus(TabStatus.connected);
      client.run().catchError((Object e) {
        if (seq == _seq) setStatus(TabStatus.disconnected, e.toString());
      }).whenComplete(() {
        if (seq == _seq && status == TabStatus.connected) {
          setStatus(TabStatus.disconnected, '连接已关闭');
        }
      });
    } catch (e) {
      if (seq != _seq) return;
      setStatus(TabStatus.error, SSHConnector.describeError(e));
    }
  }

  void _render() {
    final c = rfb;
    if (c == null || !_dirty || _decoding || c.width == 0) return;
    _dirty = false;
    _decoding = true;
    final pixels = Uint8List.fromList(c.framebuffer);
    ui.decodeImageFromPixels(pixels, c.width, c.height, ui.PixelFormat.rgba8888,
        (img) {
      _decoding = false;
      final old = image;
      image = img;
      old?.dispose();
      notifyListeners();
    });
  }

  Future<void> _teardown() async {
    _frameTimer?.cancel();
    _frameTimer = null;
    rfb?.close();
    rfb = null;
    _socket?.destroy();
    _socket = null;
    _tunnel?.closeAll();
    _tunnel = null;
  }

  @override
  Future<void> close() async {
    _seq++;
    await _teardown();
    image?.dispose();
    image = null;
    dispose();
  }
}
