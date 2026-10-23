import 'dart:async';

import 'package:flutter/foundation.dart';

/// 等待用户确认的主机指纹；[known] 为之前记录的指纹（首次连接为 null）。
class HostKeyRequest {
  HostKeyRequest(this.host, this.type, this.fingerprint, this.known);
  final String host;
  final String type;
  final String fingerprint;
  final String? known;
  final Completer<bool> _done = Completer<bool>();

  bool get changed => known != null;
}

enum ConnectStepState { running, done, failed }

class ConnectStep {
  ConnectStep(this.label) : state = ConnectStepState.running;
  final String label;
  ConnectStepState state;
}

class ConnectLog {
  ConnectLog(this.time, this.text, {this.error = false});
  final DateTime time;
  final String text;
  final bool error;
}

/// 一次连接的分步进度与日志，用于连接进度面板，失败时可看出卡在哪一步。
class ConnectProgress extends ChangeNotifier {
  final List<ConnectStep> steps = [];
  final List<ConnectLog> logs = [];
  String? error;
  bool finished = false;

  /// 正在等待用户操作（信任主机指纹、输入验证码），此时进度面板让位给对话框。
  bool waitingUser = false;

  /// 进度弹窗是否正在显示；显示时主机指纹确认直接在弹窗内完成。
  bool Function() hasViewer = () => false;

  HostKeyRequest? hostKeyRequest;

  Future<bool> askHostKey(
      String host, String type, String fingerprint, String? known) async {
    final r = HostKeyRequest(host, type, fingerprint, known);
    hostKeyRequest = r;
    log(r.changed ? '主机指纹与之前记录的不一致，等待确认' : '首次连接该主机，等待确认指纹');
    try {
      return await r._done.future;
    } finally {
      if (hostKeyRequest == r) hostKeyRequest = null;
      notifyListeners();
    }
  }

  void answerHostKey(bool trust) {
    final r = hostKeyRequest;
    if (r == null || r._done.isCompleted) return;
    r._done.complete(trust);
  }

  Future<T> waitForUser<T>(Future<T> Function() fn) async {
    waitingUser = true;
    notifyListeners();
    try {
      return await fn();
    } finally {
      waitingUser = false;
      notifyListeners();
    }
  }

  static const _maxLogs = 500;

  ConnectStep? get current =>
      steps.isNotEmpty && steps.last.state == ConnectStepState.running
      ? steps.last
      : null;

  /// 开始新步骤，上一个进行中的步骤视为完成。
  void begin(String label) {
    current?.state = ConnectStepState.done;
    steps.add(ConnectStep(label));
    notifyListeners();
  }

  void log(String text, {bool error = false}) {
    logs.add(ConnectLog(DateTime.now(), text, error: error));
    if (logs.length > _maxLogs) logs.removeRange(0, logs.length - _maxLogs);
    notifyListeners();
  }

  void fail(String message) {
    current?.state = ConnectStepState.failed;
    error = message;
    logs.add(ConnectLog(DateTime.now(), message, error: true));
    finished = true;
    notifyListeners();
  }

  void finish() {
    current?.state = ConnectStepState.done;
    finished = true;
    notifyListeners();
  }

  /// 复制给他人排查用的纯文本（不含密码等敏感信息）。
  String toText() {
    String two(int v) => v.toString().padLeft(2, '0');
    String ts(DateTime t) =>
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    final b = StringBuffer();
    for (final s in steps) {
      final mark = switch (s.state) {
        ConnectStepState.done => '[✓]',
        ConnectStepState.failed => '[✗]',
        ConnectStepState.running => '[…]',
      };
      b.writeln('$mark ${s.label}');
    }
    b.writeln();
    for (final l in logs) {
      b.writeln('${ts(l.time)}  ${l.text}');
    }
    return b.toString();
  }
}
