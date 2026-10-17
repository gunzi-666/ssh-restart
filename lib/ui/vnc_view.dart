import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_tab.dart';
import '../state/vnc_tab.dart';
import 'widgets/common.dart';

int? _keysymFor(KeyEvent e) {
  final k = e.logicalKey;
  final special = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.backspace: 0xff08,
    LogicalKeyboardKey.tab: 0xff09,
    LogicalKeyboardKey.enter: 0xff0d,
    LogicalKeyboardKey.numpadEnter: 0xff8d,
    LogicalKeyboardKey.escape: 0xff1b,
    LogicalKeyboardKey.delete: 0xffff,
    LogicalKeyboardKey.insert: 0xff63,
    LogicalKeyboardKey.home: 0xff50,
    LogicalKeyboardKey.end: 0xff57,
    LogicalKeyboardKey.pageUp: 0xff55,
    LogicalKeyboardKey.pageDown: 0xff56,
    LogicalKeyboardKey.arrowLeft: 0xff51,
    LogicalKeyboardKey.arrowUp: 0xff52,
    LogicalKeyboardKey.arrowRight: 0xff53,
    LogicalKeyboardKey.arrowDown: 0xff54,
    LogicalKeyboardKey.shiftLeft: 0xffe1,
    LogicalKeyboardKey.shiftRight: 0xffe2,
    LogicalKeyboardKey.controlLeft: 0xffe3,
    LogicalKeyboardKey.controlRight: 0xffe4,
    LogicalKeyboardKey.capsLock: 0xffe5,
    LogicalKeyboardKey.metaLeft: 0xffeb,
    LogicalKeyboardKey.metaRight: 0xffec,
    LogicalKeyboardKey.altLeft: 0xffe9,
    LogicalKeyboardKey.altRight: 0xffea,
    LogicalKeyboardKey.f1: 0xffbe,
    LogicalKeyboardKey.f2: 0xffbf,
    LogicalKeyboardKey.f3: 0xffc0,
    LogicalKeyboardKey.f4: 0xffc1,
    LogicalKeyboardKey.f5: 0xffc2,
    LogicalKeyboardKey.f6: 0xffc3,
    LogicalKeyboardKey.f7: 0xffc4,
    LogicalKeyboardKey.f8: 0xffc5,
    LogicalKeyboardKey.f9: 0xffc6,
    LogicalKeyboardKey.f10: 0xffc7,
    LogicalKeyboardKey.f11: 0xffc8,
    LogicalKeyboardKey.f12: 0xffc9,
  };
  final s = special[k];
  if (s != null) return s;
  final ch = e.character;
  if (ch != null && ch.isNotEmpty) {
    final r = ch.runes.first;
    if (r >= 0x20 && r <= 0xff) return r;
    if (r > 0xff) return 0x01000000 | r;
  }
  final label = k.keyLabel;
  if (label.length == 1) return label.toLowerCase().codeUnitAt(0);
  return null;
}

class VncTabView extends StatefulWidget {
  const VncTabView({super.key, required this.tab});
  final VncTab tab;

  @override
  State<VncTabView> createState() => _VncTabViewState();
}

class _VncTabViewState extends State<VncTabView> {
  final _focus = FocusNode();
  final Map<PhysicalKeyboardKey, int> _down = {};
  int _buttons = 0;
  bool _fit = true;

  VncTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.onRemoteClipboard = (t) => Clipboard.setData(ClipboardData(text: t));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final c = tab.rfb;
    if (c == null) return KeyEventResult.ignored;
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      final sym = _down[e.physicalKey] ?? _keysymFor(e);
      if (sym == null) return KeyEventResult.ignored;
      _down[e.physicalKey] = sym;
      c.sendKey(sym, true);
    } else if (e is KeyUpEvent) {
      final sym = _down.remove(e.physicalKey) ?? _keysymFor(e);
      if (sym != null) c.sendKey(sym, false);
    }
    return KeyEventResult.handled;
  }

  void _ctrlAltDel() {
    final c = tab.rfb;
    if (c == null) return;
    for (final k in [0xffe3, 0xffe9, 0xffff]) {
      c.sendKey(k, true);
    }
    for (final k in [0xffff, 0xffe9, 0xffe3]) {
      c.sendKey(k, false);
    }
  }

  Future<void> _sendClipboard() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text == null) return;
    tab.rfb?.sendClipboard(d!.text!);
    if (mounted) showToast(context, '已发送剪贴板到远程');
  }

  int _mask(int flutterButtons) {
    var m = 0;
    if (flutterButtons & kPrimaryButton != 0) m |= 1;
    if (flutterButtons & kMiddleMouseButton != 0) m |= 2;
    if (flutterButtons & kSecondaryButton != 0) m |= 4;
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        final img = tab.image;
        return Column(
          children: [
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(Icons.circle,
                      size: 10,
                      color: switch (tab.status) {
                        TabStatus.connected => Colors.green,
                        TabStatus.connecting => Colors.orange,
                        _ => Colors.red,
                      }),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      switch (tab.status) {
                        TabStatus.connected =>
                          '${tab.rfb?.desktopName ?? ''}  ${tab.rfb?.width ?? 0}×${tab.rfb?.height ?? 0}',
                        TabStatus.connecting => '正在连接…',
                        TabStatus.error => '连接失败：${tab.errorMessage ?? ''}',
                        TabStatus.disconnected => '已断开：${tab.errorMessage ?? ''}',
                      },
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(onPressed: _ctrlAltDel, child: const Text('Ctrl+Alt+Del')),
                  IconButton(
                    tooltip: '发送本机剪贴板',
                    icon: const Icon(Icons.content_paste_go, size: 18),
                    onPressed: _sendClipboard,
                  ),
                  IconButton(
                    tooltip: _fit ? '原始大小' : '适应窗口',
                    icon: Icon(_fit ? Icons.fit_screen : Icons.crop_free, size: 18),
                    onPressed: () => setState(() => _fit = !_fit),
                  ),
                  IconButton(
                    tooltip: '重新连接',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: tab.reconnect,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Container(
                color: Colors.black,
                child: img == null
                    ? Center(
                        child: tab.status == TabStatus.connecting
                            ? const CircularProgressIndicator()
                            : Text(tab.errorMessage ?? '',
                                style: const TextStyle(color: Colors.white70)),
                      )
                    : Focus(
                        focusNode: _focus,
                        autofocus: true,
                        onKeyEvent: _onKey,
                        child: LayoutBuilder(builder: (context, c) {
                          final iw = img.width.toDouble();
                          final ih = img.height.toDouble();
                          final scale = _fit
                              ? [c.maxWidth / iw, c.maxHeight / ih].reduce((a, b) => a < b ? a : b)
                              : 1.0;
                          final w = iw * scale;
                          final h = ih * scale;
                          Offset toFb(Offset local) => Offset(local.dx / scale, local.dy / scale);
                          final canvas = Listener(
                            onPointerDown: (e) {
                              _focus.requestFocus();
                              _buttons = _mask(e.buttons);
                              final p = toFb(e.localPosition);
                              tab.rfb?.sendPointer(p.dx.round(), p.dy.round(), _buttons);
                            },
                            onPointerMove: (e) {
                              _buttons = _mask(e.buttons);
                              final p = toFb(e.localPosition);
                              tab.rfb?.sendPointer(p.dx.round(), p.dy.round(), _buttons);
                            },
                            onPointerHover: (e) {
                              final p = toFb(e.localPosition);
                              tab.rfb?.sendPointer(p.dx.round(), p.dy.round(), 0);
                            },
                            onPointerUp: (e) {
                              _buttons = 0;
                              final p = toFb(e.localPosition);
                              tab.rfb?.sendPointer(p.dx.round(), p.dy.round(), 0);
                            },
                            onPointerSignal: (e) {
                              if (e is PointerScrollEvent) {
                                final p = toFb(e.localPosition);
                                final btn = e.scrollDelta.dy < 0 ? 8 : 16;
                                tab.rfb?.sendPointer(p.dx.round(), p.dy.round(), btn);
                                tab.rfb?.sendPointer(p.dx.round(), p.dy.round(), 0);
                              }
                            },
                            child: MouseRegion(
                              cursor: SystemMouseCursors.precise,
                              child: SizedBox(
                                width: w,
                                height: h,
                                child: RawImage(image: img, fit: BoxFit.fill),
                              ),
                            ),
                          );
                          if (_fit) return Center(child: canvas);
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SingleChildScrollView(child: canvas),
                          );
                        }),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}
