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

TerminalStyle terminalStyleFor(AppStore store) =>
    _terminalStyle(store.settings.terminalFontFamily, store.settings.terminalFontSize);

// TerminalStyle 未实现 ==，每次传入新实例都会让 xterm 重新测量字符并清空字形缓存，
// 因此相同字体设置必须复用同一个实例。
(String, double)? _styleKey;
TerminalStyle? _styleCache;

TerminalStyle _terminalStyle(String fontFamily, double fontSize) {
  final key = (fontFamily, fontSize);
  if (_styleKey == key) return _styleCache!;
  final family = fontFamily.trim();
  final defaultFamily = Platform.isWindows
      ? 'Consolas'
      : Platform.isIOS || Platform.isMacOS
          ? 'Menlo'
          : 'monospace';
  _styleKey = key;
  return _styleCache = TerminalStyle(
    fontSize: fontSize,
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
  FocusNode get _focus => tab.terminalFocus;
  Timer? _copyTimer;
  String _lastCopied = '';

  SshTab get tab => widget.tab;

  final _viewKey = GlobalKey<TerminalViewState>();
  final _scroll = ScrollController();

  // 拖选超出上下边缘时自动滚动。xterm 以拖动起点的屏幕坐标计算选区，滚动后起点会漂移，
  // 因此一旦发生自动滚动，改用按下时记录的缓冲区锚点作为起点自行维护选区。
  CellAnchor? _dragBase;
  Offset? _dragGlobal;
  bool _dragScrolled = false;
  bool _applyingSelection = false;
  Timer? _autoScroll;
  late final _ime = _TerminalIme(
    onCommit: (text) => tab.terminal.textInput(text),
    caret: _caret,
  );
  static final _desktop = !(Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    tab.terminalController.addListener(_onSelection);
    _focus.addListener(_onFocus);
    if (_focus.hasFocus) _onFocus();
  }

  @override
  void didUpdateWidget(covariant TerminalPane old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      old.tab.terminalController.removeListener(_onSelection);
      widget.tab.terminalController.addListener(_onSelection);
      old.tab.terminalFocus.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    tab.terminalController.removeListener(_onSelection);
    _focus.removeListener(_onFocus);
    _ime.close();
    _copyTimer?.cancel();
    _endDrag();
    _scroll.dispose();
    super.dispose();
  }

  /// 终端渲染区域内的本地坐标与尺寸；未完成布局时为 null。
  (Offset, Size)? _local(Offset global) {
    final box = _viewKey.currentState?.renderTerminal;
    if (box == null || !box.attached || !box.hasSize) return null;
    return (box.globalToLocal(global), box.size);
  }

  void _startDrag(Offset global) {
    _endDrag();
    final anchor = _anchorAt(global);
    if (anchor == null) return;
    _dragBase = anchor;
    _dragGlobal = global;
  }

  void _endDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _dragBase?.dispose();
    _dragBase = null;
    _dragGlobal = null;
    _dragScrolled = false;
  }

  CellAnchor? _anchorAt(Offset global) {
    final l = _local(global);
    if (l == null) return null;
    final (local, s) = l;
    final cell = _viewKey.currentState!.renderTerminal.getCellOffset(Offset(
      local.dx.clamp(0, s.width - 1),
      local.dy.clamp(0, s.height - 1),
    ));
    final buf = tab.terminal.buffer;
    return buf.createAnchor(
      cell.x.clamp(0, tab.terminal.viewWidth),
      cell.y.clamp(0, buf.lines.length - 1),
    );
  }

  void _onDragMove(PointerMoveEvent e) {
    if (_dragBase == null || e.buttons & kPrimaryButton == 0) return;
    _dragGlobal = e.position;
    final l = _local(e.position);
    if (l == null) return;
    final dy = l.$1.dy;
    if (dy < 0 || dy > l.$2.height) {
      _autoScroll ??=
          Timer.periodic(const Duration(milliseconds: 16), (_) => _autoScrollTick());
    } else {
      _autoScroll?.cancel();
      _autoScroll = null;
    }
    if (_dragScrolled) _extendSelection();
  }

  void _autoScrollTick() {
    final global = _dragGlobal;
    final l = global == null ? null : _local(global);
    if (l == null || !_scroll.hasClients) return;
    final dy = l.$1.dy;
    final h = l.$2.height;
    final over = dy < 0 ? dy : (dy > h ? dy - h : 0.0);
    if (over == 0) return;
    final p = _scroll.position;
    final step = over.sign * (over.abs() * 0.5).clamp(4.0, 60.0);
    final target = (p.pixels + step).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target == p.pixels) return;
    _scroll.jumpTo(target);
    _dragScrolled = true;
    _extendSelection();
  }

  void _extendSelection() {
    final base = _dragBase;
    final global = _dragGlobal;
    if (base == null || !base.attached || global == null) return;
    final extent = _anchorAt(global);
    if (extent == null) return;
    _applyingSelection = true;
    try {
      tab.terminalController.setSelection(
        tab.terminal.buffer.createAnchorFromOffset(base.offset),
        extent,
      );
    } finally {
      _applyingSelection = false;
    }
  }

  void _onFocus() {
    if (!_desktop) return;
    if (!_focus.hasFocus) {
      _ime.close();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focus.hasFocus) _ime.open(View.of(context).viewId);
    });
  }

  /// 终端光标在屏幕上的位置，用于定位输入法候选框。
  (Size, Matrix4, Rect)? _caret() {
    final view = _viewKey.currentState;
    if (view == null || !view.mounted) return null;
    final box = view.renderTerminal;
    if (!box.attached || !box.hasSize) return null;
    return (box.size, box.getTransformTo(null), view.cursorRect);
  }

  String? get _selectedText {
    final sel = tab.terminalController.selection;
    if (sel == null) return null;
    final t = tab.terminal.buffer.getText(sel);
    return t.isEmpty ? null : t;
  }

  void _onSelection() {
    if (_dragScrolled && !_applyingSelection) _extendSelection();
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
    if (_desktop) {
      // 输入法组字期间（及上屏瞬间的回车）按键归输入法，不能再作为硬件按键发往终端。
      if (_ime.busy) return KeyEventResult.handled;
      if (e is KeyDownEvent) _ime.updateCaret();
    }
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
    final (themeName, fontFamily, fontSize, cursorStyle) = context.select(
      (AppStore s) => (
        s.settings.terminalTheme,
        s.settings.terminalFontFamily,
        s.settings.terminalFontSize,
        s.settings.cursorStyle,
      ),
    );
    final theme = terminalThemeByName(themeName);
    final mobile = Platform.isAndroid || Platform.isIOS;
    final view = Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent &&
            HardwareKeyboard.instance.isControlPressed) {
          _zoom(e.scrollDelta.dy < 0 ? 1 : -1);
        }
      },
      // xterm 在存在选区时首次点击只清除选区而不获取焦点，这里保证任何点击都聚焦终端。
      onPointerMove: _onDragMove,
      onPointerUp: (_) => _endDrag(),
      onPointerCancel: (_) => _endDrag(),
      onPointerDown: (e) {
        if (e.buttons != kPrimaryButton) return;
        _startDrag(e.position);
        if (!_focus.hasFocus) {
          _focus.requestFocus();
        } else if (_desktop) {
          _ime.open(View.of(context).viewId);
        }
      },
      child: Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(color: theme.background),
        child: TerminalView(
          tab.terminal,
          key: _viewKey,
          scrollController: _scroll,
          controller: tab.terminalController,
          focusNode: _focus,
          autofocus: true,
          theme: theme,
          textStyle: _terminalStyle(fontFamily, fontSize),
          padding: const EdgeInsets.all(4),
          deleteDetection: mobile,
          cursorType: switch (cursorStyle) {
            'underline' => TerminalCursorType.underline,
            'bar' => TerminalCursorType.verticalBar,
            _ => TerminalCursorType.block,
          },
          keyboardAppearance: Theme.of(context).brightness,
          // 桌面端用硬件按键取字符；xterm 自带的输入法连接在 Windows 上收不到文字，
          // 中文输入法的组字与上屏由 _TerminalIme 单独接收。
          hardwareKeyboardOnly: _desktop,
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

/// 桌面端终端的输入法客户端：只接收输入法组字与上屏的文本，普通按键仍走硬件键盘。
class _TerminalIme with TextInputClient {
  _TerminalIme({required this.onCommit, required this.caret});

  final void Function(String text) onCommit;
  final (Size, Matrix4, Rect)? Function() caret;

  TextInputConnection? _conn;
  TextEditingValue _value = TextEditingValue.empty;
  DateTime _committedAt = DateTime(0);

  bool get composing => _value.composing.isValid && !_value.composing.isCollapsed;

  /// 正在组字，或刚上屏（确认上屏的回车可能晚于上屏文本到达）。
  bool get busy =>
      composing ||
      DateTime.now().difference(_committedAt) < const Duration(milliseconds: 120);

  /// [viewId] 必须提供：Windows 引擎会拒绝不带 viewId 的输入连接，导致收不到输入法文本。
  void open(int viewId) {
    if (_conn == null || !_conn!.attached) {
      _value = TextEditingValue.empty;
      _sent = 0;
      _conn = TextInput.attach(
        this,
        TextInputConfiguration(
          viewId: viewId,
          inputType: TextInputType.text,
          inputAction: TextInputAction.none,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
        ),
      )..setEditingState(_value);
    }
    _conn!.show();
    updateCaret();
  }

  void close() {
    if (_conn?.attached == true) _conn!.close();
    _conn = null;
    _value = TextEditingValue.empty;
    _sent = 0;
  }

  void updateCaret() {
    final c = _conn;
    if (c == null || !c.attached) return;
    final info = caret();
    if (info == null) return;
    final (size, transform, rect) = info;
    c
      ..setEditableSizeAndTransform(size, transform)
      ..setCaretRect(rect);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  /// 已发往终端的确认文本长度（组字区之前的部分）。
  int _sent = 0;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    final c = value.composing;
    final active = c.isValid && !c.isCollapsed;
    final confirmed = active ? value.text.substring(0, c.start) : value.text;
    if (confirmed.length > _sent) {
      _committedAt = DateTime.now();
      onCommit(confirmed.substring(_sent));
    }
    _sent = confirmed.length;
    if (active) {
      updateCaret();
    } else if (value.text.isNotEmpty) {
      _value = TextEditingValue.empty;
      _sent = 0;
      _conn?.setEditingState(_value);
    }
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _conn = null;
    _value = TextEditingValue.empty;
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
