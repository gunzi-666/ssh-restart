import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/session_config.dart';

String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

String joinRemote(String dir, String name) {
  if (dir.endsWith('/')) return '$dir$name';
  return '$dir/$name';
}

String remoteParent(String path) {
  if (path == '/' || path.isEmpty) return '/';
  final t = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final i = t.lastIndexOf('/');
  if (i <= 0) return '/';
  return t.substring(0, i);
}

class RemoteEntry {
  final String name;
  final String path;
  final SftpFileAttrs attrs;
  final String longname;
  RemoteEntry(this.name, this.path, this.attrs, this.longname);

  bool get isDir => attrs.isDirectory;
  bool get isLink => attrs.isSymbolicLink;
  int get size => attrs.size ?? 0;
  DateTime? get modified => attrs.modifyTime == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000);
  int get mode => (attrs.mode?.value ?? 0) & 0x1ff;

  String get permissionString {
    final m = attrs.mode;
    if (m == null) return '';
    final t = isDir
        ? 'd'
        : isLink
            ? 'l'
            : '-';
    String b(bool v, String c) => v ? c : '-';
    return t +
        b(m.userRead, 'r') +
        b(m.userWrite, 'w') +
        b(m.userExecute, 'x') +
        b(m.groupRead, 'r') +
        b(m.groupWrite, 'w') +
        b(m.groupExecute, 'x') +
        b(m.otherRead, 'r') +
        b(m.otherWrite, 'w') +
        b(m.otherExecute, 'x');
  }

  /// 从 ls -l 风格的 longname 中取出属主和属组。
  String get owner {
    final f = longname.trim().split(RegExp(r'\s+'));
    if (f.length >= 4) return '${f[2]}/${f[3]}';
    return '${attrs.userID ?? ''}/${attrs.groupID ?? ''}';
  }
}

enum TransferKind { upload, download }

enum TransferState { queued, running, done, failed, cancelled }

class TransferTask {
  TransferTask({
    required this.kind,
    required this.localPath,
    required this.remotePath,
    required this.total,
  }) : id = newId();

  final String id;
  final TransferKind kind;
  final String localPath;
  final String remotePath;
  int total;
  int transferred = 0;
  TransferState state = TransferState.queued;
  String? error;
  double speed = 0;
  DateTime? startedAt;
  bool _cancel = false;
  SftpFileWriter? _writer;

  String get name => kind == TransferKind.upload
      ? p.basename(localPath)
      : remotePath.split('/').last;
  double get progress => total <= 0 ? 0 : (transferred / total).clamp(0, 1);
}

/// SFTP 文件浏览与传输队列。
class SftpService extends ChangeNotifier {
  SftpService(this.client, {this.charset = 'UTF-8'});

  final SSHClient client;
  final String charset;
  SftpClient? _sftp;
  Future<SftpClient>? _opening;

  String currentPath = '';
  String homePath = '/';
  List<RemoteEntry> entries = [];
  bool loading = false;
  String? error;
  bool showHidden = false;
  final List<String> backStack = [];

  final List<TransferTask> transfers = [];
  int maxConcurrent = 2;
  int _running = 0;

  Future<SftpClient> get sftp async {
    if (_sftp != null) return _sftp!;
    _opening ??= client.sftp().then((s) {
      _sftp = s;
      return s;
    });
    return _opening!;
  }

  Future<void> init() async {
    try {
      final s = await sftp;
      // 记录用户主目录供“主目录”按钮使用，但默认进入根目录 /。
      homePath = await s.absolute('.');
      await cd('/', pushHistory: false);
    } catch (e) {
      error = 'SFTP 初始化失败：$e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final t in transfers) {
      t._cancel = true;
    }
    _sftp?.close();
    super.dispose();
  }

  Future<void> cd(String path, {bool pushHistory = true}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final s = await sftp;
      final abs = path.startsWith('/') ? path : await s.absolute(path);
      final list = await s.listdir(abs);
      final items = <RemoteEntry>[];
      for (final n in list) {
        if (n.filename == '.' || n.filename == '..') continue;
        var attrs = n.attr;
        if (attrs.isSymbolicLink) {
          try {
            final target = await s.stat(joinRemote(abs, n.filename));
            if (target.isDirectory) attrs = target;
          } catch (_) {}
        }
        items.add(RemoteEntry(
            n.filename, joinRemote(abs, n.filename), attrs, n.longname));
      }
      items.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (pushHistory && currentPath.isNotEmpty && currentPath != abs) {
        backStack.add(currentPath);
      }
      currentPath = abs;
      entries = items;
    } catch (e) {
      error = '打开目录失败：$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  List<RemoteEntry> get visibleEntries => showHidden
      ? entries
      : entries.where((e) => !e.name.startsWith('.')).toList();

  Future<void> refresh() => cd(currentPath, pushHistory: false);
  Future<void> up() => cd(remoteParent(currentPath));
  Future<void> back() async {
    if (backStack.isEmpty) return;
    final last = backStack.removeLast();
    await cd(last, pushHistory: false);
  }

  void toggleHidden(bool v) {
    showHidden = v;
    notifyListeners();
  }

  Future<String> _exec(String cmd) async {
    final r = await client.runWithResult(cmd);
    final out = utf8.decode(r.output, allowMalformed: true).trim();
    if (r.exitCode != null && r.exitCode != 0) {
      throw StateError(out.isEmpty ? '命令执行失败（退出码 ${r.exitCode}）' : out);
    }
    return out;
  }

  Future<void> mkdir(String name) async {
    final s = await sftp;
    await s.mkdir(joinRemote(currentPath, name));
    await refresh();
  }

  Future<void> createFile(String name) async {
    final s = await sftp;
    final f = await s.open(joinRemote(currentPath, name),
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive);
    await f.close();
    await refresh();
  }

  Future<void> rename(RemoteEntry e, String newName) async {
    final s = await sftp;
    await s.rename(e.path, joinRemote(remoteParent(e.path), newName));
    await refresh();
  }

  Future<void> delete(List<RemoteEntry> items) async {
    final s = await sftp;
    for (final e in items) {
      if (e.isDir && !e.isLink) {
        try {
          await _exec('rm -rf -- ${shQuote(e.path)}');
        } catch (_) {
          await _deleteRecursive(s, e.path);
        }
      } else {
        await s.remove(e.path);
      }
    }
    await refresh();
  }

  Future<void> _deleteRecursive(SftpClient s, String path) async {
    for (final n in await s.listdir(path)) {
      if (n.filename == '.' || n.filename == '..') continue;
      final child = joinRemote(path, n.filename);
      if (n.attr.isDirectory) {
        await _deleteRecursive(s, child);
      } else {
        await s.remove(child);
      }
    }
    await s.rmdir(path);
  }

  Future<void> chmod(List<RemoteEntry> items, int mode,
      {bool recursive = false}) async {
    final s = await sftp;
    for (final e in items) {
      if (recursive && e.isDir) {
        await _exec('chmod -R ${mode.toRadixString(8)} -- ${shQuote(e.path)}');
      } else {
        await s.setStat(e.path, SftpFileAttrs(mode: SftpFileMode.value(mode)));
      }
    }
    await refresh();
  }

  Future<void> chown(List<RemoteEntry> items, String owner,
      {bool recursive = false}) async {
    for (final e in items) {
      await _exec(
          'chown ${recursive ? '-R ' : ''}${shQuote(owner)} -- ${shQuote(e.path)}');
    }
    await refresh();
  }

  Future<String> execInDir(String command) =>
      _exec('cd ${shQuote(currentPath)} && $command');

  Encoding get _codec => utf8;

  Future<String> readText(String path, {int maxBytes = 10 * 1024 * 1024}) async {
    final s = await sftp;
    final attrs = await s.stat(path);
    if ((attrs.size ?? 0) > maxBytes) {
      throw StateError('文件超过 ${maxBytes ~/ 1024 ~/ 1024}MB，请下载后编辑');
    }
    final f = await s.open(path);
    try {
      final bytes = await f.readBytes();
      return _codec.decode(bytes);
    } finally {
      await f.close();
    }
  }

  Future<void> writeText(String path, String text) async {
    final s = await sftp;
    final f = await s.open(path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate);
    try {
      await f.writeBytes(Uint8List.fromList(_codec.encode(text)));
    } finally {
      await f.close();
    }
  }

  // ---------------- 传输 ----------------

  /// 当前这一批上传（队列空闲后新加入的上传任务算作新的一批），供面板显示汇总进度。
  final Set<String> _batchIds = {};
  List<TransferTask> get uploadBatch =>
      transfers.where((t) => _batchIds.contains(t.id)).toList();

  /// 正在扫描本地文件夹（尚未全部加入队列）。
  int scanning = 0;

  /// 本批上传全部结束的时间，用于短暂显示“上传完成”。
  DateTime? batchFinishedAt;

  bool get uploadsActive =>
      scanning > 0 ||
      transfers.any(
        (t) =>
            t.kind == TransferKind.upload &&
            (t.state == TransferState.queued ||
                t.state == TransferState.running),
      );

  void _addToBatch(TransferTask t) {
    if (!uploadsActive) {
      _batchIds.clear();
      batchFinishedAt = null;
    }
    _batchIds.add(t.id);
  }

  Timer? _refreshTimer;

  /// 远程路径就是当前目录或其直接子项时刷新列表，并合并短时间内的多次刷新。
  void _refreshIfVisible(String remotePath) {
    if (remotePath != currentPath && remoteParent(remotePath) != currentPath) {
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 400), () {
      if (!loading) refresh();
    });
  }

  Future<void> uploadPaths(List<String> localPaths, String remoteDir) async {
    if (!uploadsActive) {
      _batchIds.clear();
      batchFinishedAt = null;
    }
    scanning++;
    notifyListeners();
    try {
      for (final lp in localPaths) {
        final type = FileSystemEntity.typeSync(lp);
        if (type == FileSystemEntityType.directory) {
          await _queueUploadDir(Directory(lp), remoteDir);
        } else if (type == FileSystemEntityType.file) {
          final t = TransferTask(
            kind: TransferKind.upload,
            localPath: lp,
            remotePath: joinRemote(remoteDir, p.basename(lp)),
            total: File(lp).lengthSync(),
          );
          _addToBatch(t);
          _enqueue(t);
        }
        _pump();
      }
    } finally {
      scanning--;
      _checkBatchFinished();
      notifyListeners();
    }
  }

  void cancelUploads() {
    for (final t in uploadBatch) {
      if (t.state == TransferState.queued || t.state == TransferState.running) {
        cancel(t);
      }
    }
  }

  void _checkBatchFinished() {
    if (_batchIds.isEmpty || uploadsActive || batchFinishedAt != null) return;
    batchFinishedAt = DateTime.now();
    _refreshIfVisible(currentPath);
  }

  Future<void> _queueUploadDir(Directory dir, String remoteDir) async {
    final s = await sftp;
    final base = joinRemote(remoteDir, p.basename(dir.path));
    try {
      await s.mkdir(base);
    } catch (_) {}
    _refreshIfVisible(base);
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is Directory) {
        await _queueUploadDir(ent, base);
      } else if (ent is File) {
        final t = TransferTask(
          kind: TransferKind.upload,
          localPath: ent.path,
          remotePath: joinRemote(base, p.basename(ent.path)),
          total: ent.lengthSync(),
        );
        _addToBatch(t);
        _enqueue(t);
        _pump();
      }
    }
  }

  Future<void> downloadEntries(List<RemoteEntry> items, String localDir) async {
    final s = await sftp;
    for (final e in items) {
      if (e.isDir) {
        await _queueDownloadDir(s, e.path, p.join(localDir, e.name));
      } else {
        _enqueue(TransferTask(
          kind: TransferKind.download,
          localPath: p.join(localDir, e.name),
          remotePath: e.path,
          total: e.size,
        ));
      }
    }
    _pump();
  }

  Future<void> _queueDownloadDir(
      SftpClient s, String remote, String local) async {
    Directory(local).createSync(recursive: true);
    for (final n in await s.listdir(remote)) {
      if (n.filename == '.' || n.filename == '..') continue;
      final child = joinRemote(remote, n.filename);
      if (n.attr.isDirectory) {
        await _queueDownloadDir(s, child, p.join(local, n.filename));
      } else {
        _enqueue(TransferTask(
          kind: TransferKind.download,
          localPath: p.join(local, n.filename),
          remotePath: child,
          total: n.attr.size ?? 0,
        ));
      }
    }
  }

  /// 下载单个文件并等待完成，用于“用本地程序打开”等场景。
  Future<void> downloadFile(String remote, String local) async {
    final t = TransferTask(
      kind: TransferKind.download,
      localPath: local,
      remotePath: remote,
      total: 0,
    );
    _enqueue(t);
    await _runTask(t);
  }

  Future<void> uploadFile(String local, String remote) async {
    final t = TransferTask(
      kind: TransferKind.upload,
      localPath: local,
      remotePath: remote,
      total: File(local).lengthSync(),
    );
    _enqueue(t);
    await _runTask(t);
  }

  void _enqueue(TransferTask t) {
    transfers.insert(0, t);
    notifyListeners();
  }

  void _pump() {
    while (_running < maxConcurrent) {
      final next = transfers.reversed
          .where((t) => t.state == TransferState.queued)
          .firstOrNull;
      if (next == null) break;
      _running++;
      _runTask(next).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }

  Future<void> _runTask(TransferTask t) async {
    if (t._cancel) {
      t.state = TransferState.cancelled;
      notifyListeners();
      return;
    }
    t.state = TransferState.running;
    t.startedAt = DateTime.now();
    notifyListeners();
    var lastNotify = DateTime.now();
    void onProgress(int n) {
      t.transferred = n;
      final secs =
          DateTime.now().difference(t.startedAt!).inMilliseconds / 1000.0;
      if (secs > 0) t.speed = n / secs;
      if (DateTime.now().difference(lastNotify).inMilliseconds > 200) {
        lastNotify = DateTime.now();
        notifyListeners();
      }
    }

    try {
      final s = await sftp;
      if (t.kind == TransferKind.upload) {
        final f = await s.open(t.remotePath,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate);
        try {
          final w = f.write(
            File(t.localPath).openRead().map(Uint8List.fromList),
            onProgress: onProgress,
          );
          t._writer = w;
          await w.done;
        } finally {
          await f.close();
        }
      } else {
        if (t.total == 0) {
          try {
            t.total = (await s.stat(t.remotePath)).size ?? 0;
          } catch (_) {}
        }
        File(t.localPath).parent.createSync(recursive: true);
        final f = await s.open(t.remotePath);
        final sink = File(t.localPath).openWrite();
        try {
          await for (final chunk in f.read(onProgress: onProgress)) {
            if (t._cancel) break;
            sink.add(chunk);
          }
        } finally {
          await sink.close();
          await f.close();
        }
      }
      if (t._cancel) {
        t.state = TransferState.cancelled;
      } else {
        t.transferred = t.total > 0 ? t.total : t.transferred;
        t.state = TransferState.done;
      }
    } catch (e) {
      t.state = TransferState.failed;
      t.error = e.toString();
    }
    if (t.kind == TransferKind.upload) {
      if (t.state == TransferState.done) _refreshIfVisible(t.remotePath);
      _checkBatchFinished();
    }
    notifyListeners();
  }

  void cancel(TransferTask t) {
    t._cancel = true;
    t._writer?.abort();
    if (t.state == TransferState.queued) t.state = TransferState.cancelled;
    _checkBatchFinished();
    notifyListeners();
  }

  void retry(TransferTask t) {
    if (t.state != TransferState.failed && t.state != TransferState.cancelled) {
      return;
    }
    t._cancel = false;
    t.transferred = 0;
    t.error = null;
    t.state = TransferState.queued;
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    transfers.removeWhere((t) =>
        t.state == TransferState.done ||
        t.state == TransferState.cancelled ||
        t.state == TransferState.failed);
    notifyListeners();
  }
}
