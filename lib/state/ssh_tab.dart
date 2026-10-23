import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/widgets.dart' show FocusNode;
import 'package:xterm/xterm.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import '../services/ssh/port_forwarder.dart';
import '../services/ssh/server_monitor.dart';
import '../services/ssh/sftp_service.dart';
import '../services/ssh/ssh_connector.dart';
import 'app_tab.dart';
import 'connect_progress.dart';
import 'editor_file.dart';

/// 一个 SSH 标签页：终端、状态监控、SFTP 与端口转发共用同一条 SSH 连接。
class SshTab extends AppTab {
  SshTab(super.config, this.store) {
    // xterm 的 reflow 在宽度变化时会替换整个缓冲区且不校正光标，遇到中文/彩色
    // 输出时会错乱（最大化再还原后内容丢失、露出旧输出），故关闭。
    terminal = Terminal(
      maxLines: store.settings.scrollback,
      reflowEnabled: false,
    );
    terminal.onOutput = _onTerminalInput;
    terminal.onResize = (w, h, pw, ph) {
      _cols = w;
      _rows = h;
      _shell?.resizeTerminal(w, h, pw, ph);
    };
    terminal.onTitleChange = (t) {
      if (remoteTitle == t) return;
      remoteTitle = t;
      notifyListeners();
    };
  }

  final AppStore store;
  late final Terminal terminal;
  final TerminalController terminalController = TerminalController();

  /// 终端的键盘焦点。由快捷命令、历史命令等外部操作在发送后调用 [focusTerminal]，
  /// 使交互式脚本（如 y/n 确认）可以直接在终端里继续输入。
  final FocusNode terminalFocus = FocusNode(debugLabel: 'terminal');

  void focusTerminal() {
    // 移动端终端可能不在当前页，聚焦会意外弹出软键盘。
    if (Platform.isAndroid || Platform.isIOS) return;
    terminalFocus.requestFocus();
  }

  SSHConnectResult? _conn;
  SSHSession? _shell;
  StreamSubscription? _outSub;
  StreamSubscription? _errSub;
  ServerMonitor? monitor;
  SftpService? sftp;
  PortForwardManager? forwards;
  String remoteTitle = '';
  int _cols = 80;
  int _rows = 24;
  final String _marker = newId().replaceAll('-', '');
  final StringBuffer _typedLine = StringBuffer();
  bool _typedLineDirty = false;
  int _connectSeq = 0;

  /// 会话内打开的文件编辑器（副标签）。subTab=0 为主工作区（终端），
  /// 1..n 对应 editors[subTab-1]。
  final List<EditorFile> editors = [];
  int subTab = 0;

  SSHClient? get client => _conn?.client;

  /// 打开（或聚焦已打开的）文件作为会话内的编辑副标签。
  void openEditor(String path) {
    final s = sftp;
    if (s == null) return;
    final idx = editors.indexWhere((f) => f.path == path);
    if (idx >= 0) {
      subTab = idx + 1;
      notifyListeners();
      return;
    }
    final f = EditorFile(sftp: s, path: path);
    editors.add(f);
    subTab = editors.length;
    notifyListeners();
    f.load();
  }

  void closeEditor(EditorFile f) {
    final idx = editors.indexOf(f);
    if (idx < 0) return;
    editors.removeAt(idx);
    // 关闭后尽量停留在相邻的副标签上。
    if (subTab > editors.length) subTab = editors.length;
    if (subTab == idx + 1 && subTab > 0) {
      subTab = subTab.clamp(0, editors.length);
    }
    notifyListeners();
    f.dispose();
  }

  void activateSubTab(int i) {
    subTab = i.clamp(0, editors.length);
    notifyListeners();
  }

  bool get isGbk => config.charset.toUpperCase() == 'GBK';

  /// 当前（或最近一次）连接的分步进度；[showProgress] 控制进度面板是否显示。
  ConnectProgress? progress;
  bool showProgress = false;
  Timer? _progressTimer;

  void hideProgress() {
    _progressTimer?.cancel();
    if (!showProgress) return;
    showProgress = false;
    notifyListeners();
  }

  /// 首页连接进度弹窗是否正在显示本标签的进度。
  bool progressViewer = false;

  void _startProgress() {
    final p = progress = ConnectProgress()..hasViewer = () => progressViewer;
    p.begin('初始化配置');
    final jump = store.sessionById(config.jumpSessionId);
    p.log('目标服务器：${config.displayName}（${config.host}:${config.port}）');
    if (jump != null) p.log('使用跳板机：${jump.displayName}');
    if (config.proxy.type != ProxyType.none && config.proxy.host.isNotEmpty) {
      p.log('使用代理：${config.proxy.type.name.toUpperCase()} '
          '${config.proxy.host}:${config.proxy.port}');
    }
    if (config.legacyAlgorithms) p.log('已启用兼容旧版服务器的算法');
    _progressTimer?.cancel();
    showProgress = false;
    // 连接很快时不闪出面板。
    _progressTimer = Timer(const Duration(milliseconds: 400), () {
      if (status == TabStatus.connecting && progress == p) {
        showProgress = true;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  @override
  Future<void> connect() async {
    final seq = ++_connectSeq;
    await _teardown();
    setStatus(TabStatus.connecting);
    terminal.write('\r\n\x1b[36m正在连接 ${config.host}:${config.port} …\x1b[0m\r\n');
    _startProgress();
    final p = progress!;
    try {
      final conn = await SSHConnector.connect(config, store, progress: p);
      if (seq != _connectSeq || isDisposed) {
        conn.closeAll();
        return;
      }
      _conn = conn;
      p.begin('打开终端');
      final shell = await conn.client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: _cols,
          height: _rows,
        ),
        environment: {'LC_SSHR_ID': _marker},
      );
      _shell = shell;
      final Stream<String> out = isGbk
          ? gbk.decoder.bind(shell.stdout)
          : const Utf8Decoder(allowMalformed: true).bind(shell.stdout);
      final Stream<String> err = isGbk
          ? gbk.decoder.bind(shell.stderr)
          : const Utf8Decoder(allowMalformed: true).bind(shell.stderr);
      _outSub = out.listen(terminal.write);
      _errSub = err.listen(terminal.write);
      shell.done.then((_) => _onDisconnected(seq, null));
      conn.client.done.then((_) => _onDisconnected(seq, null),
          onError: (e) => _onDisconnected(seq, e));

      store.touchSession(config.id);
      p.log('终端已打开');
      p.finish();
      _progressTimer?.cancel();
      showProgress = false;
      setStatus(TabStatus.connected);

      monitor = ServerMonitor(conn.client)
        ..start(Duration(seconds: store.settings.monitorIntervalSeconds.clamp(1, 60)));
      sftp = SftpService(conn.client, charset: config.charset)
        ..showHidden = store.settings.sftpShowHidden;
      sftp!.init();
      forwards = PortForwardManager(conn.client);
      await forwards!.startAll(config.forwards);
      notifyListeners();

      // 可选：为常见命令启用彩色输出（很多服务器 root 的 shell 默认未开启）。
      // 同时为 bash 设置彩色提示符（绿色 用户@主机、蓝色 路径），
      // 让真实连接的观感与设置里的预览一致。
      // 行首空格可避免写入带 ignorespace 的历史；clear 收起这条噪声。
      if (store.settings.terminalColorHelper) {
        Future.delayed(const Duration(milliseconds: 500), () {
          sendText(
            " export CLICOLOR=1;"
            " alias ls='ls --color=auto'; alias ll='ls -alF --color=auto';"
            " alias la='ls -A --color=auto'; alias grep='grep --color=auto';"
            " alias egrep='egrep --color=auto'; alias fgrep='fgrep --color=auto';"
            " if [ -n \"\$BASH_VERSION\" ]; then"
            " PS1='\\[\\e[1;32m\\]\\u@\\h\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]\\\$ ';"
            " fi; clear\r",
            recordHistory: false,
          );
        });
      }

      if (config.initCommand.trim().isNotEmpty) {
        Future.delayed(const Duration(milliseconds: 600), () {
          sendText('${config.initCommand.trim()}\r');
        });
      }
    } catch (e) {
      if (seq != _connectSeq) return;
      final msg = SSHConnector.describeError(e);
      p.fail(msg);
      _progressTimer?.cancel();
      showProgress = true;
      terminal.write('\r\n\x1b[31m连接失败：$msg\x1b[0m\r\n');
      terminal.write('\x1b[33m按回车键重新连接\x1b[0m\r\n');
      setStatus(TabStatus.error, msg);
    }
  }

  void _onDisconnected(int seq, Object? e) {
    if (seq != _connectSeq || status == TabStatus.disconnected || isDisposed) {
      return;
    }
    monitor?.stop();
    terminal.write('\r\n\x1b[33m连接已断开${e != null ? '：$e' : ''}，按回车键重新连接\x1b[0m\r\n');
    setStatus(TabStatus.disconnected, e?.toString());
  }

  Future<void> _teardown() async {
    await _outSub?.cancel();
    await _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    _shell?.close();
    _shell = null;
    monitor?.dispose();
    monitor = null;
    await forwards?.stopAll();
    forwards?.dispose();
    forwards = null;
    sftp?.dispose();
    sftp = null;
    _conn?.closeAll();
    _conn = null;
  }

  Uint8List _encode(String s) =>
      Uint8List.fromList(isGbk ? gbk.encode(s) : utf8.encode(s));

  /// 移动端辅助按键栏上的 Ctrl / Alt 粘滞状态，作用于下一次输入。
  bool stickyCtrl = false;
  bool stickyAlt = false;

  void toggleCtrl() {
    stickyCtrl = !stickyCtrl;
    notifyListeners();
  }

  void toggleAlt() {
    stickyAlt = !stickyAlt;
    notifyListeners();
  }

  (bool, bool) consumeSticky() {
    final r = (stickyCtrl, stickyAlt);
    if (stickyCtrl || stickyAlt) {
      stickyCtrl = false;
      stickyAlt = false;
      notifyListeners();
    }
    return r;
  }

  String _applySticky(String data) {
    if (!stickyCtrl && !stickyAlt) return data;
    var out = data;
    if (stickyCtrl && data.length == 1) {
      final c = data.toLowerCase().codeUnitAt(0);
      if (c >= 97 && c <= 122) {
        out = String.fromCharCode(c - 96);
      } else if (c >= 64 && c <= 95) {
        out = String.fromCharCode(c - 64);
      }
    }
    if (stickyAlt) out = '\x1b$out';
    stickyCtrl = false;
    stickyAlt = false;
    notifyListeners();
    return out;
  }

  void _onTerminalInput(String raw) {
    if (status != TabStatus.connected) {
      if (raw == '\r' &&
          (status == TabStatus.disconnected || status == TabStatus.error)) {
        connect();
      }
      return;
    }
    final data = _applySticky(raw);
    _recordTyped(data);
    _shell?.write(_encode(data));
  }

  /// 尽力从键盘输入中还原出用户敲下的命令行，写入历史命令。
  void _recordTyped(String data) {
    if (terminal.isUsingAltBuffer) return;
    for (final r in data.runes) {
      if (r == 13) {
        final line = _typedLine.toString();
        if (!_typedLineDirty && line.trim().isNotEmpty) store.addHistory(line);
        _typedLine.clear();
        _typedLineDirty = false;
      } else if (r == 127 || r == 8) {
        final s = _typedLine.toString();
        _typedLine.clear();
        if (s.isNotEmpty) {
          _typedLine.write(String.fromCharCodes(s.runes.take(s.runes.length - 1)));
        }
      } else if (r == 3 || r == 21) {
        _typedLine.clear();
        _typedLineDirty = false;
      } else if (r < 32 || r == 27) {
        _typedLineDirty = true;
      } else {
        _typedLine.writeCharCode(r);
      }
    }
  }

  /// 从命令输入框或快捷命令发送文本到终端。
  void sendText(String text, {bool recordHistory = false}) {
    if (status != TabStatus.connected) return;
    if (recordHistory) {
      for (final line in text.split(RegExp(r'[\r\n]+'))) {
        store.addHistory(line);
      }
    }
    _shell?.write(_encode(text));
  }

  void paste(String text) {
    if (status != TabStatus.connected) return;
    terminal.paste(text);
  }

  /// 通过登录时注入的 LC_SSHR_ID 环境变量找到本终端对应的 shell 进程，读取它的当前目录。
  Future<String?> resolveTerminalCwd() async {
    final c = client;
    if (c == null || c.isClosed) return null;
    final script = 'best=""; for f in \$(grep -l "LC_SSHR_ID=$_marker" /proc/[0-9]*/environ 2>/dev/null); do '
        'p=\${f#/proc/}; p=\${p%/environ}; c=\$(cat /proc/\$p/comm 2>/dev/null); '
        'case "\$c" in bash|zsh|sh|fish|dash|ash|ksh|tcsh|csh|mksh) '
        'if [ -z "\$best" ] || [ "\$p" -gt "\$best" ]; then best=\$p; fi;; esac; done; '
        '[ -n "\$best" ] && readlink /proc/\$best/cwd';
    try {
      final out = utf8.decode(await c.run(script, stderr: false)).trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  void restartMonitor() {
    monitor?.start(
        Duration(seconds: store.settings.monitorIntervalSeconds.clamp(1, 60)));
  }

  @override
  Future<void> close() async {
    _progressTimer?.cancel();
    _connectSeq++;
    await _teardown();
    for (final f in editors) {
      f.dispose();
    }
    editors.clear();
    terminalFocus.dispose();
    status = TabStatus.disconnected;
    dispose();
  }
}
