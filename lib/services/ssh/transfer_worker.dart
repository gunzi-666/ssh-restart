import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../models/session_config.dart';
import '../app_store.dart';
import 'ssh_connector.dart';

/// 在后台 isolate 中用一条独立的 SSH 连接执行文件传输。
///
/// dartssh2 的加解密是纯 Dart 实现，放在界面线程会与绘制争抢时间，
/// 大文件传输时窗口明显掉帧；放到后台 isolate 后界面线程只处理进度消息。
class TransferWorker {
  TransferWorker._(this._isolate, this._port, this._commands);

  final Isolate _isolate;
  final ReceivePort _port;
  final SendPort _commands;
  final Map<String, _Job> _jobs = {};
  bool _alive = true;

  bool get alive => _alive;

  /// 启动后台 isolate 并完成连接；连接失败时抛出异常。
  static Future<TransferWorker> start(SessionConfig session, AppStore store) async {
    final chain = <String, Map<String, dynamic>>{};
    var cur = session;
    for (var i = 0; i < 8; i++) {
      final j = store.sessionById(cur.jumpSessionId);
      if (j == null || chain.containsKey(j.id) || j.id == session.id) break;
      chain[j.id] = j.toJson();
      cur = j;
    }
    final port = ReceivePort();
    final exit = ReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        [port.sendPort, session.toJson(), chain, Map.of(store.knownHosts)],
        debugName: 'sftp-transfer',
        onExit: exit.sendPort,
        errorsAreFatal: false,
      );
    } catch (_) {
      port.close();
      exit.close();
      rethrow;
    }

    final ready = Completer<TransferWorker>();
    TransferWorker? worker;
    void fail(Object e) {
      if (!ready.isCompleted) ready.completeError(e);
      worker?._shutdown(e);
    }

    exit.listen((_) {
      exit.close();
      fail(StateError('后台传输线程已退出'));
    });
    port.listen((m) {
      if (m is SendPort) {
        worker = TransferWorker._(isolate, port, m);
        return;
      }
      final msg = m as Map;
      switch (msg['t']) {
        case 'ready':
          ready.complete(worker!);
        case 'fail':
          fail(StateError(msg['e'] as String));
          isolate.kill();
        case 'closed':
          worker?._shutdown(StateError('后台传输连接已断开'));
        default:
          worker?._onMessage(msg);
      }
    });
    return ready.future.timeout(const Duration(seconds: 45), onTimeout: () {
      isolate.kill(priority: Isolate.immediate);
      port.close();
      throw TimeoutException('后台传输连接超时');
    });
  }

  /// 执行一次传输；取消时正常返回，失败时抛出异常。
  Future<void> run(
    String id, {
    required bool upload,
    required String local,
    required String remote,
    required void Function(int transferred, int total) onProgress,
  }) {
    if (!_alive) return Future.error(StateError('后台传输连接已断开'));
    final job = _Job(onProgress);
    _jobs[id] = job;
    _commands.send({
      't': upload ? 'up' : 'down',
      'id': id,
      'local': local,
      'remote': remote,
    });
    return job.done.future;
  }

  void cancel(String id) {
    if (_alive && _jobs.containsKey(id)) _commands.send({'t': 'cancel', 'id': id});
  }

  void close() {
    if (!_alive) return;
    _commands.send({'t': 'close'});
    _shutdown(StateError('后台传输连接已关闭'));
    Timer(const Duration(seconds: 3), () => _isolate.kill());
  }

  void _onMessage(Map msg) {
    final job = _jobs[msg['id']];
    if (job == null) return;
    switch (msg['t']) {
      case 'p':
        job.onProgress(msg['n'] as int, msg['total'] as int);
      case 'end':
        _jobs.remove(msg['id']);
        final err = msg['e'] as String?;
        if (err == null) {
          job.done.complete();
        } else {
          job.done.completeError(StateError(err));
        }
    }
  }

  void _shutdown(Object error) {
    if (!_alive) return;
    _alive = false;
    for (final j in _jobs.values) {
      if (!j.done.isCompleted) j.done.completeError(error);
    }
    _jobs.clear();
    _port.close();
  }
}

class _Job {
  _Job(this.onProgress);
  final void Function(int transferred, int total) onProgress;
  final done = Completer<void>();
}

Future<void> _workerMain(List<Object?> args) async {
  final out = args[0] as SendPort;
  final commands = ReceivePort();
  out.send(commands.sendPort);

  final SSHConnectResult conn;
  final SftpClient sftp;
  try {
    final session = SessionConfig.fromJson(Map<String, dynamic>.from(args[1] as Map));
    final sessions = {
      for (final e in (args[2] as Map).entries)
        e.key as String:
            SessionConfig.fromJson(Map<String, dynamic>.from(e.value as Map)),
    };
    final known = Map<String, String>.from(args[3] as Map);
    conn = await SSHConnector.connectDetached(session, sessions, known);
    sftp = await conn.client.sftp();
  } catch (e) {
    out.send({'t': 'fail', 'e': SSHConnector.describeError(e)});
    commands.close();
    return;
  }
  out.send({'t': 'ready'});
  conn.client.done.whenComplete(() {
    out.send({'t': 'closed'});
    commands.close();
  });

  final cancels = <String, void Function()>{};
  await for (final m in commands) {
    final msg = m as Map;
    final id = msg['id'] as String?;
    switch (msg['t']) {
      case 'up':
      case 'down':
        unawaited(_transfer(
          sftp,
          out,
          cancels,
          id!,
          upload: msg['t'] == 'up',
          local: msg['local'] as String,
          remote: msg['remote'] as String,
        ));
      case 'cancel':
        cancels[id]?.call();
      case 'close':
        for (final c in cancels.values) {
          c();
        }
        conn.closeAll();
        commands.close();
    }
  }
  Isolate.exit();
}

Future<void> _transfer(
  SftpClient sftp,
  SendPort out,
  Map<String, void Function()> cancels,
  String id, {
  required bool upload,
  required String local,
  required String remote,
}) async {
  var cancelled = false;
  SftpFileWriter? writer;
  cancels[id] = () {
    cancelled = true;
    writer?.abort();
  };
  var total = 0;
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  void progress(int n) {
    final now = DateTime.now();
    if (now.difference(last).inMilliseconds < 100) return;
    last = now;
    out.send({'t': 'p', 'id': id, 'n': n, 'total': total});
  }

  String? error;
  try {
    if (upload) {
      total = File(local).lengthSync();
      final f = await sftp.open(remote,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate);
      try {
        writer = f.write(
          File(local).openRead().map(Uint8List.fromList),
          onProgress: progress,
        );
        if (cancelled) await writer.abort();
        await writer.done;
      } finally {
        await f.close();
      }
    } else {
      try {
        total = (await sftp.stat(remote)).size ?? 0;
      } catch (_) {}
      File(local).parent.createSync(recursive: true);
      final f = await sftp.open(remote);
      final sink = File(local).openWrite();
      try {
        await for (final chunk in f.read(onProgress: progress)) {
          if (cancelled) break;
          sink.add(chunk);
        }
      } finally {
        await sink.close();
        await f.close();
      }
    }
  } catch (e) {
    if (!cancelled) error = e.toString();
  } finally {
    cancels.remove(id);
  }
  out.send({'t': 'end', 'id': id, 'e': error});
}
