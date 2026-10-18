import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_store.dart';
import '../services/ssh/sftp_service.dart';
import '../state/ssh_tab.dart';
import 'widgets/common.dart';

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// SFTP 文件管理面板。
class SftpPanel extends StatefulWidget {
  const SftpPanel({super.key, required this.tab});
  final SshTab tab;

  @override
  State<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends State<SftpPanel> {
  final _pathCtrl = TextEditingController();
  final Set<String> _selected = {};
  String? _anchor;
  Timer? _followTimer;
  String? _lastTermCwd;
  bool _follow = true;
  bool _selectMode = false;
  final Map<String, Timer> _watchers = {};
  int _sortCol = 0;
  bool _asc = true;

  SftpService? get sftp => widget.tab.sftp;

  @override
  void initState() {
    super.initState();
    _follow = context.read<AppStore>().settings.sftpFollowTerminal;
    _startFollow();
  }

  @override
  void dispose() {
    _followTimer?.cancel();
    for (final w in _watchers.values) {
      w.cancel();
    }
    super.dispose();
  }

  void _startFollow() {
    _followTimer?.cancel();
    if (!_follow) return;
    _followTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final s = sftp;
      if (s == null || s.loading) return;
      final cwd = await widget.tab.resolveTerminalCwd();
      if (cwd == null || cwd == _lastTermCwd) return;
      _lastTermCwd = cwd;
      if (cwd != s.currentPath) s.cd(cwd);
    });
  }

  Future<String> _downloadDir() async {
    final configured = context.read<AppStore>().settings.downloadDir;
    if (configured.isNotEmpty) return configured;
    final d = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(d.path, 'SSH-Restart'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  List<RemoteEntry> _sorted(SftpService s) {
    final list = [...s.visibleEntries];
    int cmp(RemoteEntry a, RemoteEntry b) => switch (_sortCol) {
          1 => a.size.compareTo(b.size),
          2 => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
          3 => a.permissionString.compareTo(b.permissionString),
          4 => a.owner.compareTo(b.owner),
          _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        };
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return _asc ? cmp(a, b) : cmp(b, a);
    });
    return list;
  }

  List<RemoteEntry> _selection(SftpService s) =>
      s.entries.where((e) => _selected.contains(e.path)).toList();

  void _open(SftpService s, RemoteEntry e) {
    if (e.isDir) {
      _selected.clear();
      s.cd(e.path);
    } else {
      _edit(s, e);
    }
  }

  void _edit(SftpService s, RemoteEntry e) {
    widget.tab.openEditor(e.path);
  }

  /// 下载到临时目录并用系统默认程序打开，文件保存后自动上传回服务器。
  Future<void> _openLocal(SftpService s, RemoteEntry e) async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'ssh-restart-edit', widget.tab.id));
      dir.createSync(recursive: true);
      final local = p.join(dir.path, e.name);
      await s.downloadFile(e.path, local);
      var mtime = File(local).lastModifiedSync();
      _watchers[local]?.cancel();
      _watchers[local] = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!File(local).existsSync()) return;
        final m = File(local).lastModifiedSync();
        if (m != mtime) {
          mtime = m;
          try {
            await s.uploadFile(local, e.path);
            if (mounted) showToast(context, '已自动上传：${e.name}');
          } catch (err) {
            if (mounted) showToast(context, '自动上传失败：$err');
          }
        }
      });
      await launchUrl(Uri.file(local));
      if (mounted) showToast(context, '已用本地程序打开，保存后会自动上传');
    } catch (err) {
      if (mounted) showToast(context, '打开失败：$err');
    }
  }

  Future<void> _download(SftpService s, List<RemoteEntry> items) async {
    if (items.isEmpty) return;
    String? dir;
    if (_isDesktop && context.read<AppStore>().settings.downloadDir.isEmpty) {
      dir = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
      if (dir == null) return;
    } else {
      dir = await _downloadDir();
    }
    await s.downloadEntries(items, dir);
    if (mounted) showToast(context, '已加入下载队列，保存到 $dir');
  }

  Future<void> _uploadFiles(SftpService s) async {
    final r = await FilePicker.pickFiles(allowMultiple: true, dialogTitle: '选择要上传的文件');
    if (r == null) return;
    final paths = r.files.map((f) => f.path).whereType<String>().toList();
    await s.uploadPaths(paths, s.currentPath);
  }

  Future<void> _uploadDir(SftpService s) async {
    final d = await FilePicker.getDirectoryPath(dialogTitle: '选择要上传的文件夹');
    if (d == null) return;
    await s.uploadPaths([d], s.currentPath);
  }

  Future<void> _run(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  Future<void> _newFolder(SftpService s) async {
    final n = await promptText(context, title: '新建文件夹', label: '名称');
    if (n == null || n.trim().isEmpty) return;
    await _run(() => s.mkdir(n.trim()));
  }

  Future<void> _newFile(SftpService s) async {
    final n = await promptText(context, title: '新建文件', label: '名称');
    if (n == null || n.trim().isEmpty) return;
    await _run(() => s.createFile(n.trim()));
  }

  Future<void> _rename(SftpService s, RemoteEntry e) async {
    final n = await promptText(context, title: '重命名', initial: e.name, label: '新名称');
    if (n == null || n.trim().isEmpty || n == e.name) return;
    await _run(() => s.rename(e, n.trim()));
  }

  Future<void> _delete(SftpService s, List<RemoteEntry> items) async {
    if (items.isEmpty) return;
    final ok = await confirm(context,
        title: '删除',
        message: items.length == 1
            ? '确定删除“${items.first.name}”吗？${items.first.isDir ? '\n文件夹中的所有内容都会被删除。' : ''}'
            : '确定删除选中的 ${items.length} 项吗？',
        danger: true,
        okText: '删除');
    if (!ok) return;
    _selected.clear();
    await _run(() => s.delete(items));
  }

  Future<void> _chmod(SftpService s, List<RemoteEntry> items) async {
    if (items.isEmpty) return;
    final r = await showChmodDialog(context, items.first.mode,
        hasDir: items.any((e) => e.isDir));
    if (r == null) return;
    await _run(() => s.chmod(items, r.$1, recursive: r.$2));
  }

  Future<void> _chown(SftpService s, List<RemoteEntry> items) async {
    if (items.isEmpty) return;
    final owner = await promptText(context,
        title: '修改属主', label: '用户[:组]', initial: items.first.owner.replaceAll('/', ':'));
    if (owner == null || owner.trim().isEmpty) return;
    await _run(() => s.chown(items, owner.trim(), recursive: items.any((e) => e.isDir)));
  }

  Future<void> _compress(SftpService s, List<RemoteEntry> items) async {
    if (items.isEmpty) return;
    final name = await promptText(context,
        title: '压缩为 tar.gz', label: '文件名',
        initial: '${items.length == 1 ? items.first.name : 'archive'}.tar.gz');
    if (name == null || name.trim().isEmpty) return;
    final args = items.map((e) => shQuote(e.name)).join(' ');
    await _run(() async {
      await s.execInDir('tar -czf ${shQuote(name.trim())} -- $args');
      await s.refresh();
    });
  }

  Future<void> _extract(SftpService s, RemoteEntry e) async {
    final n = e.name.toLowerCase();
    final q = shQuote(e.name);
    final String cmd;
    if (n.endsWith('.zip')) {
      cmd = 'unzip -o $q';
    } else if (n.endsWith('.tar.gz') || n.endsWith('.tgz')) {
      cmd = 'tar -xzf $q';
    } else if (n.endsWith('.tar.bz2')) {
      cmd = 'tar -xjf $q';
    } else if (n.endsWith('.tar.xz')) {
      cmd = 'tar -xJf $q';
    } else if (n.endsWith('.tar')) {
      cmd = 'tar -xf $q';
    } else if (n.endsWith('.gz')) {
      cmd = 'gunzip -k $q';
    } else {
      showToast(context, '不支持的压缩格式');
      return;
    }
    await _run(() async {
      await s.execInDir(cmd);
      await s.refresh();
    });
  }

  void _cdInTerminal(String dir) {
    widget.tab.sendText('cd ${shQuote(dir)}\r');
  }

  Future<void> _contextMenu(SftpService s, RemoteEntry? e, Offset pos) async {
    if (e != null && !_selected.contains(e.path)) {
      setState(() {
        _selected
          ..clear()
          ..add(e.path);
        _anchor = e.path;
      });
    }
    final items = _selection(s);
    final single = items.length == 1 ? items.first : null;
    final isArchive = single != null &&
        RegExp(r'\.(zip|tar|tgz|gz|bz2|xz)$', caseSensitive: false).hasMatch(single.name);
    PopupMenuItem<String> pmi(String value, String label, {Color? color}) =>
        PopupMenuItem(
          value: value,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(label, style: TextStyle(fontSize: 13, color: color)),
        );
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        if (single != null && single.isDir) pmi('open', '打开'),
        if (single != null && !single.isDir) ...[
          pmi('edit', '编辑'),
          if (_isDesktop) pmi('local', '用本地程序打开'),
        ],
        if (items.isNotEmpty) pmi('download', '下载'),
        pmi('upload', '上传文件'),
        if (_isDesktop) pmi('uploadDir', '上传文件夹'),
        const PopupMenuDivider(),
        if (single != null) pmi('rename', '重命名'),
        if (items.isNotEmpty) ...[
          pmi('chmod', '文件权限'),
          pmi('chown', '修改属主'),
          pmi('compress', '压缩为 tar.gz'),
        ],
        if (isArchive) pmi('extract', '解压到当前目录'),
        if (single != null) ...[
          pmi('copyName', '复制文件名'),
          pmi('copyPath', '复制文件路径'),
        ],
        if (single != null && single.isDir) pmi('cdTerm', '在终端中进入此目录'),
        const PopupMenuDivider(),
        pmi('newFolder', '新建文件夹'),
        pmi('newFile', '新建文件'),
        pmi('refresh', '刷新'),
        if (items.isNotEmpty) ...[
          const PopupMenuDivider(),
          pmi('delete', '删除', color: Colors.red),
        ],
      ],
    );
    if (!mounted || r == null) return;
    switch (r) {
      case 'open':
        _open(s, single!);
      case 'edit':
        _edit(s, single!);
      case 'local':
        _openLocal(s, single!);
      case 'download':
        _download(s, items);
      case 'upload':
        _uploadFiles(s);
      case 'uploadDir':
        _uploadDir(s);
      case 'rename':
        _rename(s, single!);
      case 'chmod':
        _chmod(s, items);
      case 'chown':
        _chown(s, items);
      case 'compress':
        _compress(s, items);
      case 'extract':
        _extract(s, single!);
      case 'copyName':
        copyText(context, single!.name);
      case 'copyPath':
        copyText(context, single!.path);
      case 'cdTerm':
        _cdInTerminal(single!.path);
      case 'newFolder':
        _newFolder(s);
      case 'newFile':
        _newFile(s);
      case 'refresh':
        s.refresh();
      case 'delete':
        _delete(s, items);
    }
  }

  void _onTap(SftpService s, List<RemoteEntry> list, RemoteEntry e) {
    final hk = HardwareKeyboard.instance;
    setState(() {
      if (_selectMode) {
        _selected.contains(e.path) ? _selected.remove(e.path) : _selected.add(e.path);
        if (_selected.isEmpty) _selectMode = false;
        return;
      }
      if (hk.isControlPressed || hk.isMetaPressed) {
        _selected.contains(e.path) ? _selected.remove(e.path) : _selected.add(e.path);
        _anchor = e.path;
      } else if (hk.isShiftPressed && _anchor != null) {
        final a = list.indexWhere((x) => x.path == _anchor);
        final b = list.indexOf(e);
        if (a >= 0 && b >= 0) {
          _selected.clear();
          for (var i = a < b ? a : b; i <= (a < b ? b : a); i++) {
            _selected.add(list[i].path);
          }
        }
      } else {
        _selected
          ..clear()
          ..add(e.path);
        _anchor = e.path;
      }
    });
    if (!_isDesktop && !_selectMode) _open(s, e);
  }

  @override
  Widget build(BuildContext context) {
    final s = sftp;
    if (s == null) {
      return const Center(child: Text('未连接'));
    }
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        if (_pathCtrl.text != s.currentPath) _pathCtrl.text = s.currentPath;
        final list = _sorted(s);
        return LayoutBuilder(builder: (context, box) {
          // 以面板自身宽度判断：够宽才用多列表格，否则用紧凑列表，避免溢出。
          final wide = box.maxWidth >= 560;
          return Column(
          children: [
            _toolbar(s, wide),
            if (s.loading) const LinearProgressIndicator(minHeight: 2),
            if (s.error != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.all(6),
                child: Text(s.error!, style: const TextStyle(fontSize: 12)),
              ),
            if (wide) _header(),
            Expanded(
              child: GestureDetector(
                onSecondaryTapUp: (d) => _contextMenu(s, null, d.globalPosition),
                child: ListView.builder(
                  itemCount: list.length + 1,
                  itemExtent: _isDesktop ? 28 : 52,
                  itemBuilder: (context, i) {
                    if (i == 0) return _parentRow(s, wide);
                    final e = list[i - 1];
                    // 交互模式只看是否桌面端：桌面端始终可双击进目录、
                    // 右键选中并弹出完整菜单；wide 只决定显示多少列。
                    return _isDesktop
                        ? _row(s, list, e, wide)
                        : _mobileRow(s, list, e);
                  },
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              alignment: Alignment.centerLeft,
              child: Text(
                '${list.length} 项${_selected.isEmpty ? '' : '，已选 ${_selected.length} 项'}',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
              ),
            ),
          ],
          );
        });
      },
    );
  }

  Widget _toolbar(SftpService s, bool wide) {
    final sel = _selection(s);
    Widget ib(IconData icon, String tip, VoidCallback? onTap, {bool active = false}) =>
        IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          isSelected: active,
          icon: Icon(icon),
          onPressed: onTap,
        );
    final pathField = SizedBox(
      height: 30,
      child: TextField(
        controller: _pathCtrl,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
        onSubmitted: (v) => s.cd(v.trim()),
      ),
    );
    final icons = <Widget>[
      ib(Icons.arrow_back, '后退', s.backStack.isEmpty ? null : s.back),
      ib(Icons.arrow_upward, '上级目录', s.up),
      ib(Icons.home_outlined, '主目录', () => s.cd(s.homePath)),
      ib(Icons.refresh, '刷新', s.refresh),
      ib(Icons.sync_alt, _follow ? '跟随终端目录：开' : '跟随终端目录：关', () {
        setState(() => _follow = !_follow);
        _lastTermCwd = null;
        _startFollow();
      }, active: _follow),
      ib(s.showHidden ? Icons.visibility : Icons.visibility_off,
          s.showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
          () => s.toggleHidden(!s.showHidden)),
      ib(Icons.upload_file, '上传文件', () => _uploadFiles(s)),
      if (_isDesktop) ib(Icons.drive_folder_upload, '上传文件夹', () => _uploadDir(s)),
      ib(Icons.download, '下载选中', sel.isEmpty ? null : () => _download(s, sel)),
      ib(Icons.create_new_folder_outlined, '新建文件夹', () => _newFolder(s)),
      if (sel.isNotEmpty)
        ib(Icons.delete_outline, '删除选中', () => _delete(s, sel)),
    ];
    // 宽面板：图标 + 路径框同一行；窄面板：图标行可横向滚动，路径框单独一行。
    if (wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            ...icons.take(4),
            Expanded(child: pathField),
            ...icons.skip(4),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: icons),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: pathField,
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final style = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    Widget h(String t, int i, {int flex = 1}) => Expanded(
          flex: flex,
          child: InkWell(
            onTap: () => setState(() {
              if (_sortCol == i) {
                _asc = !_asc;
              } else {
                _sortCol = i;
                _asc = true;
              }
            }),
            child: Row(
              children: [
                Text(t, style: style),
                if (_sortCol == i)
                  Icon(_asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 16),
              ],
            ),
          ),
        );
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(
        children: [
          h('文件名', 0, flex: 4),
          h('大小', 1),
          h('修改时间', 2, flex: 2),
          h('权限', 3),
          h('用户/组', 4),
        ],
      ),
    );
  }

  Widget _parentRow(SftpService s, bool wide) {
    return InkWell(
      onDoubleTap: _isDesktop ? s.up : null,
      onTap: _isDesktop ? null : s.up,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(Icons.folder, size: 18, color: Colors.amber.shade700),
            const SizedBox(width: 6),
            const Text('..', style: TextStyle(fontSize: 12.5)),
          ],
        ),
      ),
    );
  }

  Widget _icon(RemoteEntry e) {
    if (e.isDir) {
      return Icon(e.isLink ? Icons.folder_shared : Icons.folder,
          size: 18, color: Colors.amber.shade700);
    }
    if (e.isLink) return const Icon(Icons.link, size: 18);
    final ext = p.extension(e.name).toLowerCase();
    final icon = switch (ext) {
      '.zip' || '.gz' || '.tgz' || '.xz' || '.bz2' || '.tar' || '.rar' || '.7z' =>
        Icons.archive_outlined,
      '.png' || '.jpg' || '.jpeg' || '.gif' || '.webp' || '.svg' => Icons.image_outlined,
      '.sh' || '.py' || '.js' || '.ts' || '.go' || '.java' || '.c' || '.cpp' || '.php' =>
        Icons.code,
      '.conf' || '.ini' || '.yaml' || '.yml' || '.json' || '.toml' || '.xml' =>
        Icons.settings_applications_outlined,
      '.log' || '.txt' || '.md' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    return Icon(icon, size: 18);
  }

  Widget _row(SftpService s, List<RemoteEntry> list, RemoteEntry e, bool wide) {
    final sel = _selected.contains(e.path);
    const ts = TextStyle(fontSize: 12.5);
    return GestureDetector(
      onSecondaryTapUp: (d) => _contextMenu(s, e, d.globalPosition),
      child: Material(
        color: sel ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
        child: InkWell(
          onTap: () => _onTap(s, list, e),
          onDoubleTap: () => _open(s, e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      _icon(e),
                      const SizedBox(width: 6),
                      Expanded(child: Text(e.name, style: ts, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
                if (wide) ...[
                  Expanded(child: Text(e.isDir ? '' : formatBytes(e.size), style: ts)),
                  Expanded(flex: 2, child: Text(formatDateTime(e.modified), style: ts)),
                  Expanded(
                      child: Text(e.permissionString,
                          style: ts.copyWith(fontFamily: 'monospace', fontSize: 11.5))),
                  Expanded(child: Text(e.owner, style: ts, overflow: TextOverflow.ellipsis)),
                ] else if (!e.isDir)
                  Text(formatBytes(e.size),
                      style: ts.copyWith(
                          fontSize: 11, color: Theme.of(context).hintColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileRow(SftpService s, List<RemoteEntry> list, RemoteEntry e) {
    final sel = _selected.contains(e.path);
    return ListTile(
      dense: true,
      selected: sel,
      leading: _selectMode
          ? Checkbox(
              value: sel,
              onChanged: (_) => _onTap(s, list, e),
            )
          : _icon(e),
      title: Text(e.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${e.isDir ? '' : '${formatBytes(e.size)}  '}${formatDateTime(e.modified)}  ${e.permissionString}',
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () => _onTap(s, list, e),
      onLongPress: () {
        setState(() {
          _selectMode = true;
          _selected.add(e.path);
        });
      },
      trailing: IconButton(
        icon: const Icon(Icons.more_vert, size: 18),
        onPressed: () {
          final box = context.findRenderObject() as RenderBox?;
          final pos = box?.localToGlobal(Offset(box.size.width - 40, 80)) ?? Offset.zero;
          _contextMenu(s, e, pos);
        },
      ),
    );
  }
}

/// 返回 (权限值, 是否递归)。
Future<(int, bool)?> showChmodDialog(BuildContext context, int mode, {bool hasDir = false}) {
  var m = mode & 0x1ff;
  var recursive = false;
  final octal = TextEditingController(text: m.toRadixString(8).padLeft(3, '0'));
  return showDialog<(int, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Widget cb(String label, int bit) => Expanded(
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(label),
                value: m & bit != 0,
                onChanged: (v) => setState(() {
                  m = v == true ? m | bit : m & ~bit;
                  octal.text = m.toRadixString(8).padLeft(3, '0');
                }),
              ),
            );
        Widget row(String who, int shift) => Row(
              children: [
                SizedBox(width: 56, child: Text(who)),
                cb('读', 4 << shift),
                cb('写', 2 << shift),
                cb('执行', 1 << shift),
              ],
            );
        return AlertDialog(
          title: const Text('文件权限'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row('所有者', 6),
                row('用户组', 3),
                row('其他', 0),
                const SizedBox(height: 8),
                TextField(
                  controller: octal,
                  decoration: const InputDecoration(labelText: '权限值（八进制）'),
                  onChanged: (v) {
                    final parsed = int.tryParse(v, radix: 8);
                    if (parsed != null && parsed <= 0x1ff) setState(() => m = parsed);
                  },
                ),
                if (hasDir)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('应用到子目录和文件'),
                    value: recursive,
                    onChanged: (v) => setState(() => recursive = v ?? false),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, (m, recursive)), child: const Text('确定')),
          ],
        );
      },
    ),
  );
}
