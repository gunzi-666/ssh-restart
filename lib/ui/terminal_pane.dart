import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/app_store.dart';
import '../state/ssh_tab.dart';
import 'terminal_themes.dart';

TerminalStyle terminalStyleFor(AppStore store) {
  final family = store.settings.terminalFontFamily.trim();
  final defaultFamily = Platform.isWindows
      ? 'Consolas'
      : Platform.isIOS || Platform.isMacOS
          ? 'Menlo'
          : 'monospace';
  return TerminalStyle(
    fontSize: store.settings.terminalFontSize,
    fontFamily: family.isEmpty ? defaultFamily : family,
    fontFamilyFallback: const [
      'Consolas',
      'Menlo',
      'Cascadia Mono',
      'DejaVu Sans Mono',
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans Mono CJK SC',
      'Noto Sans CJK SC',
      'Noto Color Emoji',
      'monospace',
    ],
  );
}

/// 终端区域：右键菜单、选中即复制、右键粘贴、Ctrl+Shift+C/V、Ctrl+滚轮缩放字体。
class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key, required this.tab, this.showKeyBar = false});
  final SshTab tab;
  final bool showKeyBar;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final _focus = FocusNode();
  Timer? _copyTimer;
  String _lastCopied = '';

  SshTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.terminalController.addListener(_onSelection);
  }

  @override
  void didUpdateWidget(covariant TerminalPane old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      old.tab.terminalController.removeListener(_onSelection);
      widget.tab.terminalController.addListener(_onSelection);
    }
  }

  @override
  void dispose() {
    tab.terminalController.removeListener(_onSelection);
    _copyTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  String? get _selectedText {
    final sel = tab.terminalController.selection;
    if (sel == null) return null;
    final t = tab.terminal.buffer.getText(sel);
    return t.isEmpty ? null : t;
  }

  void _onSelection() {
    if (!context.read<AppStore>().settings.copyOnSelect) return;
    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(milliseconds: 350), () {
      final t = _selectedText;
      if (t != null && t != _lastCopied) {
        _lastCopied = t;
        Clipboard.setData(ClipboardData(text: t));
      }
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    tab.paste(text);
    _focus.requestFocus();
  }

  void _copy() {
    final t = _selectedText;
    if (t != null) Clipboard.setData(ClipboardData(text: t));
  }

  void _selectAll() {
    final buf = tab.terminal.buffer;
    tab.terminalController.setSelection(
      buf.createAnchor(0, 0),
      buf.createAnchor(tab.terminal.viewWidth, buf.lines.length - 1),
    );
  }

  void _zoom(double delta) {
    final store = context.read<AppStore>();
    store.updateSettings((s) =>
        s.terminalFontSize = (s.terminalFontSize + delta).clamp(8, 40));
  }

  Future<void> _contextMenu(Offset pos) async {
    final store = context.read<AppStore>();
    if (store.settings.rightClickPaste && _selectedText == null) {
      await _paste();
      return;
    }
    final hasSel = _selectedText != null;
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(value: 'copy', enabled: hasSel, child: const Text('复制')),
        const PopupMenuItem(value: 'paste', child: Text('粘贴')),
        const PopupMenuItem(value: 'all', child: Text('全选')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'clear', child: Text('清屏')),
        const PopupMenuItem(value: 'clearBuf', child: Text('清空缓冲区')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'zoomIn', child: Text('放大字体')),
        const PopupMenuItem(value: 'zoomOut', child: Text('缩小字体')),
      ],
    );
    switch (r) {
      case 'copy':
        _copy();
        tab.terminalController.clearSelection();
        break;
      case 'paste':
        await _paste();
        break;
      case 'all':
        _selectAll();
        break;
      case 'clear':
        tab.sendText('clear\r');
        break;
      case 'clearBuf':
        tab.terminal.buffer.clear();
        tab.terminal.buffer.setCursor(0, 0);
        tab.sendText('\x0c');
        break;
      case 'zoomIn':
        _zoom(1);
        break;
      case 'zoomOut':
        _zoom(-1);
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final hk = HardwareKeyboard.instance;
    if (hk.isControlPressed && hk.isShiftPressed) {
      if (e.logicalKey == LogicalKeyboardKey.keyC) {
        _copy();
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
    }
    if (hk.isShiftPressed && e.logicalKey == LogicalKeyboardKey.insert) {
      _paste();
      return KeyEventResult.handled;
    }
    if (hk.isControlPressed &&
        (e.logicalKey == LogicalKeyboardKey.equal ||
            e.logicalKey == LogicalKeyboardKey.numpadAdd)) {
      _zoom(1);
      return KeyEventResult.handled;
    }
    if (hk.isControlPressed &&
        (e.logicalKey == LogicalKeyboardKey.minus ||
            e.logicalKey == LogicalKeyboardKey.numpadSubtract)) {
      _zoom(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final theme = terminalThemeByName(store.settings.terminalTheme);
    final mobile = Platform.isAndroid || Platform.isIOS;
    final view = Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent &&
            HardwareKeyboard.instance.isControlPressed) {
          _zoom(e.scrollDelta.dy < 0 ? 1 : -1);
        }
      },
      child: Container(
        color: theme.background,
        child: TerminalView(
          tab.terminal,
          controller: tab.terminalController,
          focusNode: _focus,
          autofocus: true,
          theme: theme,
          textStyle: terminalStyleFor(store),
          padding: const EdgeInsets.all(4),
          deleteDetection: mobile,
          cursorType: switch (store.settings.cursorStyle) {
            'underline' => TerminalCursorType.underline,
            'bar' => TerminalCursorType.verticalBar,
            _ => TerminalCursorType.block,
          },
          keyboardAppearance: Theme.of(context).brightness,
          // 桌面端直接用硬件键盘事件取字符，避免 xterm 默认的 IME 文本连接
          // 因拿不到 keyboard token 而需要先点击才能输入的问题。
          hardwareKeyboardOnly: !mobile,
          onKeyEvent: _onKey,
          onSecondaryTapDown: (d, _) => _contextMenu(d.globalPosition),
        ),
      ),
    );
    if (!widget.showKeyBar) return view;
    return Column(
      children: [
        Expanded(child: view),
        MobileKeyBar(tab: tab, onPaste: _paste),
      ],
    );
  }
}

/// 移动端终端辅助按键栏。
class MobileKeyBar extends StatelessWidget {
  const MobileKeyBar({super.key, required this.tab, required this.onPaste});
  final SshTab tab;
  final VoidCallback onPaste;

  void _key(TerminalKey k) {
    final (ctrl, alt) = tab.consumeSticky();
    tab.terminal.keyInput(k, ctrl: ctrl, alt: alt);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        Widget btn(String label, VoidCallback onTap, {bool active = false}) =>
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Material(
                color: active ? cs.primary : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onTap,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 40),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    alignment: Alignment.center,
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            color: active ? cs.onPrimary : cs.onSurface)),
                  ),
                ),
              ),
            );
        void send(String s) => tab.terminal.textInput(s);
        return Container(
          color: cs.surface,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                btn('Esc', () => _key(TerminalKey.escape)),
                btn('Tab', () => _key(TerminalKey.tab)),
                btn('Ctrl', tab.toggleCtrl, active: tab.stickyCtrl),
                btn('Alt', tab.toggleAlt, active: tab.stickyAlt),
                btn('↑', () => _key(TerminalKey.arrowUp)),
                btn('↓', () => _key(TerminalKey.arrowDown)),
                btn('←', () => _key(TerminalKey.arrowLeft)),
                btn('→', () => _key(TerminalKey.arrowRight)),
                btn('Home', () => _key(TerminalKey.home)),
                btn('End', () => _key(TerminalKey.end)),
                btn('PgUp', () => _key(TerminalKey.pageUp)),
                btn('PgDn', () => _key(TerminalKey.pageDown)),
                btn('|', () => send('|')),
                btn('/', () => send('/')),
                btn('-', () => send('-')),
                btn('~', () => send('~')),
                btn('^C', () => send('\x03')),
                btn('^D', () => send('\x04')),
                btn('^Z', () => send('\x1a')),
                btn('粘贴', onPaste),
                for (var i = 1; i <= 12; i++)
                  btn('F$i', () => _key(TerminalKey.values.byName('f$i'))),
              ],
            ),
          ),
        );
      },
    );
  }
}
