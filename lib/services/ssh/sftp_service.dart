import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/session_config.dart';
import 'transfer_worker.dart';

String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// SSH 加解密和界面在同一线程执行。传输时每连续占用约 4ms 就让出一次事件循环，
/// 保证网速很快时界面仍能绘制、窗口仍能拖动。
abstract final class _Pacer {
  static final _sw = Stopwatch()..start();

  static Future<void> yieldIfBusy() async {
    if (_sw.elapsedMilliseconds < 4) return;
    await Future<void>.delayed(Duration.zero);
    _sw.reset();
  }
}

/// 按 SFTP 写入包大小切分本地文件，每发出一块检查一次是否该让出线程。
Stream<Uint8List> _pacedRead(String path) async* {
  const chunk = 16 * 1024;
  await for (final data in File(path).openRead()) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = i + chunk < bytes.length ? i + chunk : bytes.length;
      yield Uint8List.sublistView(bytes, i, end);
      await _Pacer.yieldIfBusy();
    }
  }
}

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

  /// 符号链接目标，例如 `bin -> usr/bin` 中的 `usr/bin`。
  String? get linkTarget {
    if (!isLink) return null;
    final i = longname.indexOf(' -> ');
    if (i < 0) return null;
    final t = longname.substring(i + 4).trim();
    return t.isEmpty ? null : t;
  }
}

String normalizeRemote(String path) {
  if (path.isEmpty || path == '/') return '/';
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
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
  SftpService(this.client, {this.charset = 'UTF-8', this.workerFactory});

  final SSHClient client;
  final String charset;

  /// 建立后台传输连接；为 null 时所有传输都走主连接。
  final Future<TransferWorker> Function()? workerFactory;
  SftpClient? _sftp;
  Future<SftpClient>? _opening;

  String currentPath = '';
  String homePath = '/';
  List<RemoteEntry> entries = [];
  bool loading = false;
  String? error;
  bool showHidden = false;
  final List<String> backStack = [];

  /// 已列出的目录内容，按绝对路径缓存，供树状展开复用。
  final Map<String, List<RemoteEntry>> children = {};
  /// 树状视图中已展开的目录。
  final Set<String> expanded = {};
  final Set<String> _listing = {};
  /// 目录缓存、展开状态或隐藏文件开关变化时递增，供界面缓存树的展平结果。
  int treeVersion = 0;

  final List<TransferTask> transfers = [];
  final Queue<TransferTask> _pending = Queue();
  int maxConcurrent = 2;
  int _running = 0;
  Timer? _notifyTimer;
  bool _disposed = false;

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
      final home = s.absolute('.').then((h) => homePath = h);
      await cd('/', pushHistory: false);
      await home;
    } catch (e) {
      error = 'SFTP 初始化失败：$e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _workerIdleTimer?.cancel();
    _worker?.close();
    for (final t in transfers) {
      t._cancel = true;
    }
    _sftp?.close();
    super.dispose();
  }

  Future<List<RemoteEntry>> _fetch(String abs) async {
    final s = await sftp;
    final list = await s.listdir(abs);
    // 符号链接需要额外 stat 才知道是否指向目录，并发查询，避免逐个等待往返。
    final items = await Future.wait([
      for (final n in list)
        if (n.filename != '.' && n.filename != '..')
          () async {
            final path = joinRemote(abs, n.filename);
            var attrs = n.attr;
            if (attrs.isSymbolicLink) {
              try {
                final target = await s.stat(path);
                if (target.isDirectory) attrs = target;
              } catch (_) {}
            }
            return RemoteEntry(n.filename, path, attrs, n.longname);
          }(),
    ]);
    items.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  /// 列出 [path] 并写入缓存；[force] 为 true 时强制重新拉取。
  Future<void> listDir(String path, {bool force = false}) async {
    final abs = normalizeRemote(
        path.startsWith('/') ? path : await (await sftp).absolute(path));
    if (!force && children.containsKey(abs)) return;
    _listing.add(abs);
    notifyListeners();
    try {
      children[abs] = await _fetch(abs);
      treeVersion++;
      if (abs == currentPath) entries = children[abs]!;
      error = null;
    } catch (e) {
      error = '打开目录失败：$e';
    } finally {
      _listing.remove(abs);
      notifyListeners();
    }
  }

  bool isListing(String path) => _listing.contains(normalizeRemote(path));

  List<RemoteEntry> visibleChildren(String path) {
    final list = children[normalizeRemote(path)] ?? const <RemoteEntry>[];
    return showHidden
        ? list
        : list.where((e) => !e.name.startsWith('.')).toList();
  }

  Future<void> toggleExpand(String path) async {
    final abs = normalizeRemote(path);
    if (expanded.contains(abs)) {
      expanded.remove(abs);
      expanded.removeWhere((p) => p.startsWith('$abs/'));
      treeVersion++;
      notifyListeners();
      return;
    }
    await listDir(abs);
    if (children.containsKey(abs)) {
      expanded.add(abs);
      treeVersion++;
      notifyListeners();
    }
  }

  /// 展开到 [path] 的全部祖先目录，使树状视图能看到该路径；未缓存的目录并发拉取。
  Future<void> reveal(String path, {bool listSelf = true}) async {
    final abs = normalizeRemote(
        path.startsWith('/') ? path : await (await sftp).absolute(path));
    final chain = <String>[];
    for (var p = abs; ; p = remoteParent(p)) {
      chain.add(p);
      if (p == '/') break;
    }
    await Future.wait([
      for (final dir in chain)
        if (listSelf || dir != abs) listDir(dir),
    ]);
    expanded.addAll(chain.where((d) => d != abs));
    treeVersion++;
  }

  Future<void> cd(String path, {bool pushHistory = true}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final abs = normalizeRemote(
          path.startsWith('/') ? path : await (await sftp).absolute(path));
      if (pushHistory && currentPath.isNotEmpty && currentPath != abs) {
        backStack.add(currentPath);
      }
      await Future.wait([
        reveal(abs, listSelf: false),
        listDir(abs, force: true),
      ]);
      currentPath = abs;
      entries = children[abs] ?? [];
      expanded.add(abs);
      treeVersion++;
    } catch (e) {
      error = '打开目录失败：$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 仅把工作目录切到已在树中的路径，不折叠其它已展开节点，也不发起网络请求。
  void selectPath(String path, {bool pushHistory = true}) {
    final abs = normalizeRemote(path);
    if (abs == currentPath) return;
    if (pushHistory && currentPath.isNotEmpty) backStack.add(currentPath);
    currentPath = abs;
    entries = children[abs] ?? [];
    notifyListeners();
  }

  List<RemoteEntry> get visibleEntries => showHidden
      ? entries
      : entries.where((e) => !e.name.startsWith('.')).toList();

  /// 刷新当前目录和已展开的目录；未展开的缓存直接丢弃，下次展开时再拉取。
  Future<void> refresh() async {
    final visible = <String>{
      normalizeRemote(currentPath),
      ...expanded.map(normalizeRemote),
    };
    children.removeWhere((k, _) => !visible.contains(k));
    await refreshDirs(visible);
  }

  /// 只刷新指定目录（并发拉取），用于删除、重命名等只影响少数目录的操作。
  Future<void> refreshDirs(Iterable<String> dirs) async {
    final paths = dirs.map(normalizeRemote).toSet();
    loading = true;
    error = null;
    notifyListeners();
    try {
      final list = paths.toList();
      const batch = 8;
      for (var i = 0; i < list.length; i += batch) {
        await Future.wait([
          for (final p in list.skip(i).take(batch)) listDir(p, force: true),
        ]);
      }
      entries = children[normalizeRemote(currentPath)] ?? [];
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 被删除或改名的路径：清掉它及其子目录的缓存与展开状态，并刷新所在目录。
  Future<void> _afterRemoved(Iterable<String> paths) {
    final parents = <String>{};
    for (final raw in paths) {
      final p = normalizeRemote(raw);
      parents.add(remoteParent(p));
      bool under(String k) => k == p || k.startsWith('$p/');
      children.removeWhere((k, _) => under(k));
      expanded.removeWhere(under);
      if (under(normalizeRemote(currentPath))) currentPath = remoteParent(p);
    }
    treeVersion++;
    return refreshDirs(parents);
  }

  Future<void> up() => cd(remoteParent(currentPath));
  Future<void> back() async {
    if (backStack.isEmpty) return;
    final last = backStack.removeLast();
    await cd(last, pushHistory: false);
  }

  void toggleHidden(bool v) {
    showHidden = v;
    treeVersion++;
    notifyListeners();
  }

  RemoteEntry? entryByPath(String path) {
    final parent = remoteParent(normalizeRemote(path));
    final list = children[parent];
    if (list == null) return null;
    for (final e in list) {
      if (e.path == path) return e;
    }
    return null;
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
    await refreshDirs([currentPath]);
  }

  Future<void> createFile(String name) async {
    final s = await sftp;
    final f = await s.open(joinRemote(currentPath, name),
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive);
    await f.close();
    await refreshDirs([currentPath]);
  }

  Future<void> rename(RemoteEntry e, String newName) async {
    final s = await sftp;
    await s.rename(e.path, joinRemote(remoteParent(e.path), newName));
    await _afterRemoved([e.path]);
  }

  Future<void> delete(List<RemoteEntry> items) async {
    final s = await sftp;
    try {
      await Future.wait([
        for (final e in items)
          if (!e.isDir || e.isLink) s.remove(e.path),
      ]);
      for (final e in items) {
        if (e.isDir && !e.isLink) {
          try {
            await _exec('rm -rf -- ${shQuote(e.path)}');
          } catch (_) {
            await _deleteRecursive(s, e.path);
          }
        }
      }
    } finally {
      await _afterRemoved(items.map((e) => e.path));
    }
  }

  /// 修改属性后刷新条目所在目录，以及其下已展开的子目录（递归修改时会变化）。
  Future<void> _refreshAround(List<RemoteEntry> items) {
    final dirs = <String>{};
    for (final e in items) {
      final p = normalizeRemote(e.path);
      dirs.add(remoteParent(p));
      dirs.addAll(expanded.where((k) => k == p || k.startsWith('$p/')));
    }
    return refreshDirs(dirs);
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
    await _refreshAround(items);
  }

  Future<void> chown(List<RemoteEntry> items, String owner,
      {bool recursive = false}) async {
    for (final e in items) {
      await _exec(
          'chown ${recursive ? '-R ' : ''}${shQuote(owner)} -- ${shQuote(e.path)}');
    }
    await _refreshAround(items);
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

  /// 远程路径落在已缓存/当前目录时刷新对应节点，并合并短时间内的多次刷新。
  void _refreshIfVisible(String remotePath) {
    final abs = normalizeRemote(remotePath);
    final parent = remoteParent(abs);
    final targets = <String>{
      if (abs == currentPath || children.containsKey(abs) || expanded.contains(abs))
        abs,
      if (parent == currentPath ||
          children.containsKey(parent) ||
          expanded.contains(parent))
        parent,
    };
    if (targets.isEmpty) return;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 400), () async {
      for (final p in targets) {
        await listDir(p, force: true);
      }
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
    _pending.add(t);
    _notifySoon();
  }

  /// 上传整个文件夹时会连续排入大量任务，合并成一次界面刷新。
  void _notifySoon() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _pump() {
    while (_running < maxConcurrent && _pending.isNotEmpty) {
      final next = _pending.removeFirst();
      if (next.state != TransferState.queued) continue;
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
      final worker = await _workerFor(t);
      if (t._cancel) {
        // 等待后台连接期间已被取消。
      } else if (worker != null) {
        _workerIdleTimer?.cancel();
        await worker.run(
          t.id,
          upload: t.kind == TransferKind.upload,
          local: t.localPath,
          remote: t.remotePath,
          onProgress: (n, total) {
            if (total > 0) t.total = total;
            onProgress(n);
          },
        );
      } else if (t.kind == TransferKind.upload) {
        final s = await sftp;
        final f = await s.open(t.remotePath,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate);
        try {
          final w = f.write(_pacedRead(t.localPath), onProgress: onProgress);
          t._writer = w;
          await w.done;
        } finally {
          await f.close();
        }
      } else {
        final s = await sftp;
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
            await _Pacer.yieldIfBusy();
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
      if (t._cancel) {
        t.state = TransferState.cancelled;
      } else {
        t.state = TransferState.failed;
        t.error = e.toString();
      }
    }
    if (t.kind == TransferKind.upload) {
      if (t.state == TransferState.done) _refreshIfVisible(t.remotePath);
      _checkBatchFinished();
    }
    _scheduleWorkerIdle();
    notifyListeners();
  }

  // ---------------- 后台传输连接 ----------------

  /// 小于该大小的文件不值得为它单独建立后台连接（已有后台连接时仍会复用）。
  static const _workerMinSize = 1024 * 1024;

  TransferWorker? _worker;
  Future<TransferWorker?>? _workerStarting;
  bool _workerDisabled = false;
  Timer? _workerIdleTimer;

  /// 返回可用的后台传输连接；无法建立（如需要二次验证）时返回 null，改用主连接传输。
  Future<TransferWorker?> _workerFor(TransferTask t) async {
    final factory = workerFactory;
    if (factory == null || _workerDisabled || _disposed) return null;
    final w = _worker;
    if (w != null && w.alive) return w;
    _worker = null;
    final starting = _workerStarting;
    if (starting != null) return starting;
    if (t.total < _workerMinSize) return null;
    final future = factory().then<TransferWorker?>(
      (w) {
        if (_disposed) {
          w.close();
          return null;
        }
        return _worker = w;
      },
      onError: (Object e) {
        _workerDisabled = true;
        debugPrint('后台传输连接失败，改用主连接传输：$e');
        return null;
      },
    );
    _workerStarting = future;
    future.whenComplete(() => _workerStarting = null);
    return future;
  }

  /// 传输队列空闲一段时间后关闭后台连接。
  void _scheduleWorkerIdle() {
    if (_worker == null) return;
    if (transfers.any((t) =>
        t.state == TransferState.queued || t.state == TransferState.running)) {
      return;
    }
    _workerIdleTimer?.cancel();
    _workerIdleTimer = Timer(const Duration(minutes: 2), () {
      _worker?.close();
      _worker = null;
    });
  }

  void cancel(TransferTask t) {
    t._cancel = true;
    t._writer?.abort();
    _worker?.cancel(t.id);
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
    _pending.add(t);
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
