import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import 'command_panels.dart';
import 'session_editor.dart';
import 'widgets/common.dart';

enum _Scope { all, favorites, recent, group, ungrouped, session }

enum _TypeFilter { all, ssh, vnc, favorite }

/// added 为默认的添加顺序（按创建时间），新服务器排在最后。
enum _SortKey { added, name, address, auth, recent }

const _mono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Menlo', 'Cascadia Mono'],
);

/// 「N 分钟前 / 昨天 / N 天前」形式的相对时间。
String formatAgo(int ms) {
  if (ms <= 0) return '未连接';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days == 0) return '${diff.inHours} 小时前';
  if (days == 1) return '昨天';
  if (days < 30) return '$days 天前';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// 桌面端首页：左侧导航（全部 / 收藏 / 最近连接 / 分组），右侧服务器列表。
class ServerHomeView extends StatefulWidget {
  const ServerHomeView({
    super.key,
    required this.onConnect,
    required this.onConnectMany,
    required this.onOpenSettings,
  });

  final void Function(SessionConfig s) onConnect;
  final void Function(List<SessionConfig> list) onConnectMany;
  final void Function(int tab) onOpenSettings;

  @override
  State<ServerHomeView> createState() => _ServerHomeViewState();
}

class _ServerHomeViewState extends State<ServerHomeView> {
  static const double _rowH = 54;
  static const double _headerH = 40;
  static const double _cardW = 272;
  static const double _cardH = 164;
  static const double _gap = 12;
  static const double _actionsW = 176;
  static const double _minSidebarW = 180;
  static const double _maxSidebarW = 420;
  static const double _checkW = 36;

  /// 拖动中的侧边栏宽度；松手后写入设置。
  final _dragW = ValueNotifier<double?>(null);

  /// 按下时的宽度与累计位移；按总位移计算宽度，同一帧内的多次事件不会丢失。
  double _dragStartW = 0;
  double _dragDx = 0;

  /// 多选勾选的服务器 id。
  final Set<String> _checked = {};

  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  _Scope _scope = _Scope.all;
  String? _groupId;
  String? _sessionId;
  _TypeFilter _type = _TypeFilter.all;
  AuthType? _auth;
  _SortKey _sort = _SortKey.added;
  bool _asc = true;
  bool _grid = false;
  final _scroll = ScrollController();
  String? _selectedId;

  /// 新建/复制后需要自动翻到其所在页的服务器。
  String? _revealId;

  String? _lastTapId;
  DateTime? _lastTapAt;

  AppStore get store => context.read<AppStore>();

  bool get _isMac => !kIsWeb && Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _restoreScope();
  }

  void _restoreScope() {
    final store = context.read<AppStore>();
    final raw = store.settings.homeScope;
    final i = raw.indexOf(':');
    final name = i < 0 ? raw : raw.substring(0, i);
    final id = i < 0 ? null : raw.substring(i + 1);
    final scope = _Scope.values.where((e) => e.name == name).firstOrNull;
    if (scope == null) return;
    if (scope == _Scope.group && store.groupById(id) == null) return;
    if (scope == _Scope.session && store.sessionById(id) == null) return;
    _scope = scope;
    _groupId = scope == _Scope.group ? id : null;
    _sessionId = scope == _Scope.session ? id : null;
    if (scope == _Scope.session) _selectedId = id;
    if (scope == _Scope.recent) {
      _sort = _SortKey.recent;
      _asc = false;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _dragW.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _update(VoidCallback fn) => setState(() {
    fn();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  void _setScope(_Scope scope, {String? groupId, String? sessionId}) =>
      _update(() {
        if (scope == _Scope.recent) {
          _sort = _SortKey.recent;
          _asc = false;
        } else if (_scope == _Scope.recent) {
          _sort = _SortKey.added;
          _asc = true;
        }
        _scope = scope;
        _groupId = groupId;
        _sessionId = sessionId;
        final id = groupId ?? sessionId;
        store.persistSettings(
          (x) => x.homeScope = id == null ? scope.name : '${scope.name}:$id',
        );
      });

  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  // ---------------- 数据筛选 ----------------

  Set<String> _descendants(String id, List<SessionGroup> groups) {
    final out = <String>{id};
    var frontier = [id];
    var guard = 0;
    while (frontier.isNotEmpty && guard++ < 50) {
      final next = <String>[];
      for (final g in groups) {
        if (g.parentId != null &&
            frontier.contains(g.parentId) &&
            out.add(g.id)) {
          next.add(g.id);
        }
      }
      frontier = next;
    }
    return out;
  }

  bool _isUngrouped(SessionConfig s) => store.groupById(s.groupId) == null;

  List<SessionConfig> _filtered(AppStore store) {
    var list = store.sessions;
    final groups = store.groups;
    switch (_scope) {
      case _Scope.all:
        break;
      case _Scope.favorites:
        list = list.where((s) => s.favorite).toList();
      case _Scope.recent:
        list = list.where((s) => s.lastConnectedAt > 0).toList();
      case _Scope.group:
        final ids = _descendants(_groupId!, groups);
        list = list.where((s) => ids.contains(s.groupId)).toList();
      case _Scope.ungrouped:
        list = list.where(_isUngrouped).toList();
      case _Scope.session:
        list = list.where((s) => s.id == _sessionId).toList();
    }
    switch (_type) {
      case _TypeFilter.all:
        break;
      case _TypeFilter.ssh:
        list = list.where((s) => s.type == SessionType.ssh).toList();
      case _TypeFilter.vnc:
        list = list.where((s) => s.type == SessionType.vnc).toList();
      case _TypeFilter.favorite:
        list = list.where((s) => s.favorite).toList();
    }
    if (_auth != null) {
      list = list
          .where((s) => s.type == SessionType.ssh && s.authType == _auth)
          .toList();
    }
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (s) =>
                s.displayName.toLowerCase().contains(q) ||
                s.host.toLowerCase().contains(q) ||
                s.username.toLowerCase().contains(q) ||
                s.description.toLowerCase().contains(q),
          )
          .toList();
    }
    int cmp(SessionConfig a, SessionConfig b) {
      switch (_sort) {
        case _SortKey.added:
          final c = a.createdAt.compareTo(b.createdAt);
          return c != 0 ? c : a.id.compareTo(b.id);
        case _SortKey.name:
          return a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          );
        case _SortKey.address:
          final c = a.host.compareTo(b.host);
          return c != 0 ? c : a.port.compareTo(b.port);
        case _SortKey.auth:
          return a.authType.index.compareTo(b.authType.index);
        case _SortKey.recent:
          return a.lastConnectedAt.compareTo(b.lastConnectedAt);
      }
    }

    list = [...list]..sort((a, b) => _asc ? cmp(a, b) : cmp(b, a));
    return list;
  }

  String _groupPath(SessionGroup g) {
    final names = <String>[g.name];
    var cur = store.groupById(g.parentId);
    var guard = 0;
    while (cur != null && guard++ < 20) {
      names.insert(0, cur.name);
      cur = store.groupById(cur.parentId);
    }
    return names.join(' / ');
  }

  String _scopeTitle() {
    switch (_scope) {
      case _Scope.all:
        return '所有服务器';
      case _Scope.favorites:
        return '收藏';
      case _Scope.recent:
        return '最近连接';
      case _Scope.group:
        final g = store.groupById(_groupId);
        return g == null ? '分组' : _groupPath(g);
      case _Scope.ungrouped:
        return '未分组';
      case _Scope.session:
        return store.sessionById(_sessionId ?? '')?.displayName ?? '服务器';
    }
  }

  // ---------------- 会话与分组操作 ----------------

  Future<void> _newSession(SessionType type) async {
    final s = SessionConfig(
      type: type,
      groupId: _scope == _Scope.group ? _groupId : null,
      favorite: _scope == _Scope.favorites,
    );
    if (type == SessionType.vnc) {
      s.port = 5900;
      s.username = '';
    }
    final r = await showSessionEditor(context, s, isNew: true);
    if (r != null) {
      store.upsertSession(r);
      _reveal(r.id);
    }
  }

  void _reveal(String id) {
    if (!mounted) return;
    setState(() {
      _selectedId = id;
      _revealId = id;
    });
  }

  Future<void> _edit(SessionConfig s) async {
    final r = await showSessionEditor(context, s.copy());
    if (r != null) store.upsertSession(r);
  }

  void _duplicate(SessionConfig s) {
    final c = s.copy()
      ..id = newId()
      ..name = '${s.displayName} - 副本'
      ..createdAt = nowMs()
      ..lastConnectedAt = 0;
    for (final f in c.forwards) {
      f.id = newId();
    }
    store.upsertSession(c);
    _reveal(c.id);
  }

  Future<void> _delete(SessionConfig s) async {
    if (await confirm(
      context,
      title: '删除服务器',
      message: '确定删除“${s.displayName}”吗？',
      danger: true,
    )) {
      store.deleteSession(s.id);
    }
  }

  Future<void> _moveTo(SessionConfig s) async {
    final target = await _pickGroup(
      description: '选择“${s.displayName}”要移动到的分组。',
      current: s.groupId ?? '',
    );
    if (target == null) return;
    s.groupId = target.isEmpty ? null : target;
    store.upsertSession(s);
  }

  /// 返回选中的分组 id，空字符串表示未分组，取消返回 null。
  Future<String?> _pickGroup({required String description, String? current}) {
    final groups = store.groups;
    Widget option(BuildContext ctx, String id, String label, IconData icon) {
      final isCurrent = current == id;
      return AppMenuItem(
        height: 38,
        icon: icon,
        label: label,
        selected: isCurrent,
        trailing: isCurrent
            ? Icon(
                Icons.check_rounded,
                size: 16,
                color: Theme.of(ctx).colorScheme.onSurface,
              )
            : null,
        onTap: () => Navigator.pop(ctx, id),
      );
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) => AppDialog(
        title: '移动到分组',
        description: description,
        width: 420,
        actions: [AppButton(label: '取消', onPressed: () => Navigator.pop(ctx))],
        child: Container(
          constraints: const BoxConstraints(maxHeight: 320),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(ctx).colorScheme.outlineVariant),
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              option(ctx, '', '未分组', Icons.inbox_outlined),
              for (final g in groups)
                option(ctx, g.id, _groupPath(g), Icons.folder_outlined),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _newGroup({String? parentId}) async {
    final name = await promptText(
      context,
      title: '新建分组',
      description: '分组用于整理服务器，可在左侧拖拽服务器到分组中。',
      label: '分组名称',
      hint: '例如：生产环境',
      okText: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    store.upsertGroup(SessionGroup(name: name.trim(), parentId: parentId));
    if (parentId != null) _toggleExpanded(parentId, open: true);
  }

  Future<void> _renameGroup(SessionGroup g) async {
    final name = await promptText(
      context,
      title: '重命名分组',
      initial: g.name,
      label: '分组名称',
      okText: '保存',
    );
    if (name == null || name.trim().isEmpty) return;
    g.name = name.trim();
    store.upsertGroup(g);
  }

  Future<void> _deleteGroup(SessionGroup g) async {
    if (await confirm(
      context,
      title: '删除分组',
      message: '删除分组“${g.name}”后，其中的服务器会移动到上级分组。',
      danger: true,
    )) {
      store.deleteGroup(g.id);
      if (_scope == _Scope.group && _groupId == g.id) _setScope(_Scope.all);
    }
  }

  String _infoText(SessionConfig s) {
    final lines = <String>['IP：${s.host}', '端口：${s.port}'];
    if (s.type == SessionType.ssh) {
      lines.add('用户名：${s.username}');
      lines.add(s.authType == AuthType.key ? '认证方式：密钥' : '密码：${s.password}');
    } else if (s.password.isNotEmpty) {
      lines.add('密码：${s.password}');
    }
    return lines.join('\n');
  }

  void _copyInfo(SessionConfig s) =>
      copyText(context, _infoText(s), tip: '已复制连接信息');

  Future<void> _sessionMenu(SessionConfig s, Offset pos) async {
    setState(() => _selectedId = s.id);
    final r = await showAppMenu<String>(context, pos, [
      const AppMenuEntry('connect', '连接', icon: Icons.play_arrow_rounded),
      AppMenuEntry(
        'check',
        _checked.contains(s.id) ? '取消勾选' : '勾选（多选）',
        icon: Icons.check_box_outlined,
      ),
      AppMenuEntry(
        'fav',
        s.favorite ? '取消收藏' : '收藏',
        icon: s.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
      ),
      const AppMenuEntry.divider(),
      const AppMenuEntry('edit', '编辑', icon: Icons.edit_outlined),
      const AppMenuEntry('dup', '复制服务器', icon: Icons.control_point_duplicate),
      const AppMenuEntry('move', '移动到分组', icon: Icons.drive_file_move_outline),
      const AppMenuEntry.divider(),
      const AppMenuEntry('copyInfo', '复制连接信息', icon: Icons.copy_rounded),
      const AppMenuEntry('copyHost', '复制地址', icon: Icons.link_rounded),
      const AppMenuEntry.divider(),
      const AppMenuEntry(
        'delete',
        '删除',
        icon: Icons.delete_outline_rounded,
        danger: true,
      ),
    ]);
    if (!mounted) return;
    switch (r) {
      case 'connect':
        widget.onConnect(s);
      case 'check':
        _toggleChecked(s.id);
      case 'fav':
        store.toggleFavorite(s.id);
      case 'edit':
        _edit(s);
      case 'dup':
        _duplicate(s);
      case 'move':
        _moveTo(s);
      case 'copyInfo':
        _copyInfo(s);
      case 'copyHost':
        copyText(context, '${s.host}:${s.port}');
      case 'delete':
        _delete(s);
    }
  }

  Future<void> _groupMenu(SessionGroup g, Offset pos) async {
    final r = await showAppMenu<String>(context, pos, const [
      AppMenuEntry('sub', '新建子分组', icon: Icons.create_new_folder_outlined),
      AppMenuEntry('rename', '重命名', icon: Icons.drive_file_rename_outline),
      AppMenuEntry.divider(),
      AppMenuEntry(
        'delete',
        '删除分组',
        icon: Icons.delete_outline_rounded,
        danger: true,
      ),
    ]);
    if (!mounted) return;
    switch (r) {
      case 'sub':
        _newGroup(parentId: g.id);
      case 'rename':
        _renameGroup(g);
      case 'delete':
        _deleteGroup(g);
    }
  }

  /// 自行判定双击，避免单击响应被双击识别延迟。
  bool _isDoubleTap(String key) {
    final now = DateTime.now();
    final hit =
        _lastTapId == key &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 350);
    _lastTapId = key;
    _lastTapAt = hit ? null : now;
    return hit;
  }

  /// 单击选中、双击连接；按住 Ctrl / ⌘ 单击切换勾选。
  void _tapSession(SessionConfig s) {
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed) {
      _toggleChecked(s.id);
      return;
    }
    if (_isDoubleTap(s.id)) {
      widget.onConnect(s);
      return;
    }
    setState(() => _selectedId = s.id);
  }

  void _toggleChecked(String id, [bool? value]) => setState(() {
    final want = value ?? !_checked.contains(id);
    want ? _checked.add(id) : _checked.remove(id);
  });

  void _openQuickCommands() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 680,
          height: 480,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Text('快捷命令', style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(width: 10),
                    Text(
                      '点击复制命令，连接后可在底部「快速命令」中发送',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).hintColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: QuickCommandPanel(
                  onSend: (c) => copyText(ctx, c.command, tip: '已复制命令'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 布局 ----------------

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if ((_scope == _Scope.group && store.groupById(_groupId) == null) ||
        (_scope == _Scope.session &&
            store.sessionById(_sessionId ?? '') == null)) {
      _scope = _Scope.all;
      _groupId = null;
      _sessionId = null;
    }
    if (_checked.isNotEmpty) {
      _checked.retainAll(store.sessions.map((s) => s.id));
    }
    return CallbackShortcuts(
      bindings: {
        if (_checked.isNotEmpty)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              setState(_checked.clear),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusSearch,
      },
      child: Focus(
        autofocus: true,
        child: _resizable(
          store,
          RepaintBoundary(child: _sidebar(store)),
          RepaintBoundary(child: _main(store)),
        ),
      ),
    );
  }

  /// 拖动时只更新宽度，两侧内容复用同一个 widget 实例，不会重新 build。
  Widget _resizable(AppStore store, Widget sidebar, Widget main) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxW = math.max(
          _minSidebarW,
          math.min(_maxSidebarW, c.maxWidth - 520),
        );
        return ValueListenableBuilder<double?>(
          valueListenable: _dragW,
          builder: (context, dragW, _) {
            final w = (dragW ?? store.settings.sidebarWidth)
                .clamp(_minSidebarW, maxW)
                .toDouble();
            return Row(
              children: [
                SizedBox(width: w, child: sidebar),
                DragDivider(
                  onStart: () {
                    _dragStartW = w;
                    _dragDx = 0;
                  },
                  onDrag: (d) {
                    _dragDx += d;
                    _dragW.value = (_dragStartW + _dragDx).clamp(
                      _minSidebarW,
                      maxW,
                    );
                  },
                  onEnd: () {
                    final v = _dragW.value;
                    if (v != null) {
                      store.updateSettings((x) => x.sidebarWidth = v);
                    }
                  },
                ),
                Expanded(child: main),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------- 左侧导航 ----------------

  static const _ungroupedKey = '__ungrouped__';

  Widget _sidebar(AppStore store) {
    final cs = Theme.of(context).colorScheme;
    final sessions = store.sessions;
    final rows = _treeRows(store);
    return Container(
      color: cs.surfaceContainerLow,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
              itemCount: rows.length + 5,
              itemBuilder: (context, i) => switch (i) {
                0 => _navItem(
                  icon: Icons.dns_outlined,
                  label: '所有服务器',
                  count: sessions.length,
                  selected: _scope == _Scope.all,
                  onTap: () => _setScope(_Scope.all),
                ),
                1 => _navItem(
                  icon: Icons.star_outline_rounded,
                  label: '收藏',
                  count: sessions.where((s) => s.favorite).length,
                  selected: _scope == _Scope.favorites,
                  onTap: () => _setScope(_Scope.favorites),
                ),
                2 => _navItem(
                  icon: Icons.history,
                  label: '最近连接',
                  count: sessions.where((s) => s.lastConnectedAt > 0).length,
                  selected: _scope == _Scope.recent,
                  onTap: () => _setScope(_Scope.recent),
                ),
                3 => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1, color: cs.outlineVariant),
                ),
                4 => Padding(
                  padding: const EdgeInsets.only(left: 10, bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '分组',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '新建分组',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: _newGroup,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                _ => rows[i - 5](),
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Divider(height: 1, color: cs.outlineVariant),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Column(
              children: [
                _navItem(
                  icon: Icons.terminal,
                  label: '快捷命令',
                  count: store.quickCommands.length,
                  onTap: _openQuickCommands,
                ),
                _navItem(
                  icon: Icons.cloud_outlined,
                  label: '备份与同步',
                  onTap: () => widget.onOpenSettings(2),
                ),
                _navItem(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: () => widget.onOpenSettings(0),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 16),
            child: Row(
              children: [
                Icon(
                  Icons.storage_outlined,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Text(
                  '数据保存在本机',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分组树：文件夹可展开，展开后显示子文件夹和其中服务器（仅名称）。
  List<Widget Function()> _treeRows(AppStore store) {
    final groups = store.groups;
    final groupMap = {for (final g in groups) g.id: g};
    final subGroups = <String?, List<SessionGroup>>{};
    for (final g in groups) {
      final parent = groupMap.containsKey(g.parentId) ? g.parentId : null;
      subGroups.putIfAbsent(parent, () => []).add(g);
    }
    for (final l in subGroups.values) {
      l.sort((a, b) => a.name.compareTo(b.name));
    }
    final direct = <String?, List<SessionConfig>>{};
    for (final s in store.sessions) {
      final gid = groupMap.containsKey(s.groupId) ? s.groupId : null;
      direct.putIfAbsent(gid, () => []).add(s);
    }
    for (final l in direct.values) {
      l.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final totals = <String, int>{};
    int total(String id, Set<String> path) {
      final cached = totals[id];
      if (cached != null) return cached;
      if (!path.add(id)) return 0;
      var n = direct[id]?.length ?? 0;
      for (final c in subGroups[id] ?? const <SessionGroup>[]) {
        n += total(c.id, path);
      }
      path.remove(id);
      return totals[id] = n;
    }

    final expanded = store.settings.expandedGroups.toSet();
    final rows = <Widget Function()>[];

    void addSessions(List<SessionConfig>? list, int depth) {
      for (final s in list ?? const <SessionConfig>[]) {
        rows.add(() => _treeSession(s, depth));
      }
    }

    void addGroup(SessionGroup g, int depth, Set<String> path) {
      if (depth > 8 || !path.add(g.id)) return;
      final subs = subGroups[g.id] ?? const <SessionGroup>[];
      final items = direct[g.id];
      final expandable = subs.isNotEmpty || (items?.isNotEmpty ?? false);
      final open = expandable && expanded.contains(g.id);
      final count = total(g.id, {});
      rows.add(() => _treeGroup(g, depth, count, expandable ? open : null));
      if (open) {
        for (final c in subs) {
          addGroup(c, depth + 1, path);
        }
        addSessions(items, depth + 1);
      }
      path.remove(g.id);
    }

    for (final g in subGroups[null] ?? const <SessionGroup>[]) {
      addGroup(g, 0, {});
    }

    final ungrouped = direct[null];
    final ungroupedOpen =
        (ungrouped?.isNotEmpty ?? false) && expanded.contains(_ungroupedKey);
    rows.add(
      () => _dropTarget(
        groupId: null,
        builder: (hover) => _navItem(
          tree: true,
          icon: Icons.folder_off_outlined,
          label: '未分组',
          count: ungrouped?.length ?? 0,
          selected: _scope == _Scope.ungrouped,
          highlighted: hover,
          chevron: (ungrouped?.isNotEmpty ?? false) ? ungroupedOpen : null,
          onChevron: () => _toggleExpanded(_ungroupedKey),
          onTap: () {
            if ((ungrouped?.isNotEmpty ?? false) &&
                _isDoubleTap('g:$_ungroupedKey')) {
              _toggleExpanded(_ungroupedKey);
            }
            _setScope(_Scope.ungrouped);
          },
        ),
      ),
    );
    if (ungroupedOpen) addSessions(ungrouped, 1);
    return rows;
  }

  Widget _treeGroup(SessionGroup g, int depth, int count, bool? open) {
    return _dropTarget(
      groupId: g.id,
      builder: (hover) => _navItem(
        tree: true,
        icon: open == true ? Icons.folder_open_rounded : Icons.folder_rounded,
        iconColor: _folderColor,
        label: g.name,
        count: count,
        selected: _scope == _Scope.group && _groupId == g.id,
        highlighted: hover,
        indent: depth * 16.0,
        chevron: open,
        onChevron: () => _toggleExpanded(g.id),
        onTap: () {
          if (open != null && _isDoubleTap('g:${g.id}')) {
            _toggleExpanded(g.id);
          }
          _setScope(_Scope.group, groupId: g.id);
        },
        onSecondaryTapUp: (d) => _groupMenu(g, d.globalPosition),
      ),
    );
  }

  Widget _treeSession(SessionConfig s, int depth) {
    return _draggable(
      s,
      _navItem(
        tree: true,
        dense: true,
        icon: s.type == SessionType.vnc
            ? Icons.desktop_windows_outlined
            : Icons.terminal_rounded,
        label: s.displayName,
        selected: _scope == _Scope.session && _sessionId == s.id,
        indent: depth * 16.0,
        onTap: () {
          if (_isDoubleTap('s:${s.id}')) {
            widget.onConnect(s);
            return;
          }
          _setScope(_Scope.session, sessionId: s.id);
          setState(() => _selectedId = s.id);
        },
        onSecondaryTapUp: (d) => _sessionMenu(s, d.globalPosition),
      ),
    );
  }

  static const _folderColor = Color(0xFFE8A93A);

  void _toggleExpanded(String id, {bool? open}) {
    store.updateSettings((x) {
      final set = x.expandedGroups.toSet();
      final want = open ?? !set.contains(id);
      want ? set.add(id) : set.remove(id);
      x.expandedGroups = set
          .where((e) => e == _ungroupedKey || store.groupById(e) != null)
          .toList();
    });
  }

  Widget _dropTarget({
    required String? groupId,
    required Widget Function(bool) builder,
  }) {
    return DragTarget<SessionConfig>(
      onAcceptWithDetails: (d) {
        d.data.groupId = groupId;
        store.upsertSession(d.data);
      },
      builder: (context, cand, _) => builder(cand.isNotEmpty),
    );
  }

  Widget _navItem({
    required IconData icon,
    required String label,
    int? count,
    bool selected = false,
    bool highlighted = false,
    double indent = 0,
    bool tree = false,
    bool dense = false,
    Color? iconColor,
    bool? chevron,
    VoidCallback? onChevron,
    VoidCallback? onTap,
    GestureTapUpCallback? onSecondaryTapUp,
  }) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.primary : cs.onSurface;
    final isTree = tree;
    final vPad = dense ? 6.0 : (tree ? 8.0 : 9.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: highlighted
            ? cs.primary.withValues(alpha: 0.22)
            : selected
            ? cs.primary.withValues(alpha: 0.13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onSecondaryTapUp: onSecondaryTapUp,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              (isTree ? 2 : 10) + indent,
              vPad,
              10,
              vPad,
            ),
            child: Row(
              children: [
                if (isTree)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: chevron == null
                        ? null
                        : InkResponse(
                            radius: 12,
                            onTap: onChevron,
                            child: AnimatedRotation(
                              turns: chevron ? 0.25 : 0,
                              duration: const Duration(milliseconds: 120),
                              child: Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                  ),
                Icon(
                  icon,
                  size: dense ? 15 : 18,
                  color:
                      iconColor ??
                      (selected ? cs.primary : cs.onSurfaceVariant),
                ),
                SizedBox(width: isTree ? 8 : 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: dense ? 13 : 13.5,
                      color: fg,
                      fontWeight: selected
                          ? FontWeight.w600
                          : (dense ? FontWeight.normal : FontWeight.w500),
                    ),
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 右侧主区域 ----------------

  Widget _main(AppStore store) {
    final cs = Theme.of(context).colorScheme;
    final list = _filtered(store);
    final hasVnc = store.sessions.any((s) => s.type == SessionType.vnc);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _scopeTitle(),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${list.length} 台服务器',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _newButton(),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _searchField()),
              const SizedBox(width: 10),
              _authFilterButton(),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 36,
            child: _checked.isNotEmpty ? _batchBar(store) : _filterBar(hasVnc),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: list.isEmpty
                ? _empty(store.sessions.isEmpty)
                : LayoutBuilder(builder: (context, c) => _scrollList(list, c)),
          ),
        ],
      ),
    );
  }

  Widget _filterBar(bool hasVnc) {
    return Row(
      children: [
        _chip(
          '全部',
          _type == _TypeFilter.all,
          () => _update(() => _type = _TypeFilter.all),
        ),
        _chip(
          'SSH',
          _type == _TypeFilter.ssh,
          () => _update(() => _type = _TypeFilter.ssh),
        ),
        if (hasVnc)
          _chip(
            'VNC',
            _type == _TypeFilter.vnc,
            () => _update(() => _type = _TypeFilter.vnc),
          ),
        _chip(
          '收藏',
          _type == _TypeFilter.favorite,
          () => _update(() => _type = _TypeFilter.favorite),
        ),
        const Spacer(),
        _viewToggle(),
      ],
    );
  }

  List<SessionConfig> _checkedSessions() =>
      store.sessions.where((s) => _checked.contains(s.id)).toList();

  Widget _batchBar(AppStore store) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_box_rounded, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            '已选择 ${_checked.length} 台',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const Spacer(),
          _batchAction(Icons.play_arrow_rounded, '批量连接', _batchConnect),
          _batchAction(Icons.content_copy_rounded, '复制连接信息', _batchCopy),
          _batchAction(Icons.drive_file_move_outline, '移动到分组', _batchMove),
          _batchAction(
            Icons.delete_outline_rounded,
            '删除',
            _batchDelete,
            danger: true,
          ),
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: cs.outlineVariant,
          ),
          _batchAction(
            Icons.close_rounded,
            '取消选择',
            () => setState(_checked.clear),
          ),
        ],
      ),
    );
  }

  Widget _batchAction(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final color = danger ? cs.error : cs.onSurface;
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: color,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }

  Future<void> _batchConnect() async {
    final list = _checkedSessions();
    if (list.isEmpty) return;
    if (list.length > 8 &&
        !await confirm(
          context,
          title: '批量连接',
          message: '将同时打开 ${list.length} 个连接标签，确定继续吗？',
          okText: '连接',
        )) {
      return;
    }
    if (!mounted) return;
    setState(_checked.clear);
    widget.onConnectMany(list);
  }

  void _batchCopy() {
    final list = _checkedSessions();
    if (list.isEmpty) return;
    final text = [
      for (final s in list) '【${s.displayName}】\n${_infoText(s)}',
    ].join('\n\n');
    copyText(context, text, tip: '已复制 ${list.length} 台服务器的连接信息');
  }

  Future<void> _batchMove() async {
    final list = _checkedSessions();
    if (list.isEmpty) return;
    final target = await _pickGroup(
      description: '选择这 ${list.length} 台服务器要移动到的分组。',
    );
    if (target == null) return;
    for (final s in list) {
      s.groupId = target.isEmpty ? null : target;
      store.upsertSession(s);
    }
    if (mounted) showToast(context, '已移动 ${list.length} 台服务器');
  }

  Future<void> _batchDelete() async {
    final list = _checkedSessions();
    if (list.isEmpty) return;
    final names = list.take(5).map((s) => '“${s.displayName}”').join('、');
    final more = list.length > 5 ? ' 等 ${list.length} 台服务器' : '';
    if (!await confirm(
      context,
      title: '批量删除',
      message: '确定删除 $names$more 吗？此操作无法撤销。',
      okText: '删除 ${list.length} 台',
      danger: true,
    )) {
      return;
    }
    store.deleteSessions(list.map((s) => s.id));
    if (!mounted) return;
    setState(_checked.clear);
    showToast(context, '已删除 ${list.length} 台服务器');
  }

  Widget _newButton() {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      builder: (context, controller, _) => FilledButton.icon(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('新建连接'),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.terminal, size: 18),
          onPressed: () => _newSession(SessionType.ssh),
          child: const Text('SSH 连接'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.desktop_windows_outlined, size: 18),
          onPressed: () => _newSession(SessionType.vnc),
          child: const Text('VNC 远程桌面'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined, size: 18),
          onPressed: () =>
              _newGroup(parentId: _scope == _Scope.group ? _groupId : null),
          child: const Text('分组'),
        ),
      ],
    );
  }

  Widget _searchField() {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        onChanged: (_) => _update(() {}),
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: '搜索名称、主机或备注',
          prefixIcon: const Icon(Icons.search, size: 20),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          suffixIcon: _search.text.isNotEmpty
              ? IconButton(
                  tooltip: '清除',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _update(_search.clear),
                )
              : Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Center(
                    widthFactor: 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      child: Text(
                        _isMac ? '⌘ K' : 'Ctrl K',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _authFilterButton() {
    final cs = Theme.of(context).colorScheme;
    final active = _auth != null;
    AppMenuEntry<int> item(int v, String label, bool checked) =>
        AppMenuEntry(v, label, icon: checked ? Icons.check_rounded : null);
    Future<void> open(BuildContext ctx) async {
      final box = ctx.findRenderObject() as RenderBox;
      final pos = box.localToGlobal(Offset(0, box.size.height + 6));
      final v = await showAppMenu<int>(ctx, pos, [
        item(0, '全部认证方式', _auth == null),
        item(1, '密码', _auth == AuthType.password),
        item(2, '密钥', _auth == AuthType.key),
      ]);
      if (v == null) return;
      _update(
        () => _auth = switch (v) {
          1 => AuthType.password,
          2 => AuthType.key,
          _ => null,
        },
      );
    }

    return Builder(
      builder: (ctx) => Tooltip(
        message: '按认证方式筛选',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => open(ctx),
          child: _authFilterBox(cs, active),
        ),
      ),
    );
  }

  Widget _authFilterBox(ColorScheme cs, bool active) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: active ? cs.primary.withValues(alpha: 0.13) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? cs.primary : cs.outlineVariant),
      ),
      child: Icon(
        Icons.filter_list,
        size: 20,
        color: active ? cs.primary : cs.onSurfaceVariant,
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.13)
            : cs.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? cs.primary : cs.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: selected ? cs.primary : cs.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewToggle() {
    final cs = Theme.of(context).colorScheme;
    Widget btn(IconData icon, bool selected, String tip, VoidCallback onTap) =>
        Tooltip(
          message: tip,
          child: Material(
            color: selected ? cs.surfaceContainerHighest : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              borderRadius: BorderRadius.circular(7),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(
            Icons.view_list_outlined,
            !_grid,
            '列表视图',
            () => _update(() => _grid = false),
          ),
          const SizedBox(width: 2),
          btn(
            Icons.grid_view_outlined,
            _grid,
            '卡片视图',
            () => _update(() => _grid = true),
          ),
        ],
      ),
    );
  }

  Widget _empty(bool noSessions) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            noSessions ? Icons.dns_outlined : Icons.search_off,
            size: 48,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            noSessions ? '还没有服务器' : '没有匹配的服务器',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          if (noSessions) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => _newSession(SessionType.ssh),
              icon: const Icon(Icons.add),
              label: const Text('新建 SSH 连接'),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------- 列表 / 卡片（单页滚动） ----------------

  Widget _scrollList(List<SessionConfig> list, BoxConstraints c) {
    final cols = _grid
        ? math.max(1, ((c.maxWidth + _gap) / (_cardW + _gap)).floor())
        : 1;
    if (_revealId != null) {
      final idx = list.indexWhere((s) => s.id == _revealId);
      _revealId = null;
      if (idx >= 0) _scrollToIndex(idx, cols, c.maxHeight);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _grid
          ? _cards(list, cols)
          : _table(list, maxHeight: c.maxHeight - 16),
    );
  }

  /// 把第 [idx] 项滚动到可见区域（新建 / 复制服务器后定位）。
  void _scrollToIndex(int idx, int cols, double viewH) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final double top, extent;
      if (_grid) {
        top = (idx ~/ cols) * (_cardH + _gap);
        extent = _cardH;
      } else {
        top = idx * _rowH;
        extent = _rowH;
      }
      final view = pos.viewportDimension;
      double? target;
      if (top < pos.pixels) {
        target = top;
      } else if (top + extent > pos.pixels + view) {
        target = top + extent - view;
      }
      if (target != null) {
        _scroll.animateTo(
          target.clamp(0, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _checkbox(
    bool? value,
    ValueChanged<bool?> onChanged, {
    bool tristate = false,
  }) {
    return SizedBox(
      width: _checkW,
      child: Center(
        child: Checkbox(
          value: value,
          tristate: tristate,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          side: BorderSide(
            width: 1.3,
            color: Theme.of(context).colorScheme.outline,
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// 表头复选框作用于当前筛选结果的全部服务器（跨页）。
  Widget _headerCheckbox(List<SessionConfig> all) {
    final n = all.where((s) => _checked.contains(s.id)).length;
    final bool? value = n == 0 ? false : (n == all.length ? true : null);
    return Tooltip(
      message: value == true ? '取消全选' : '全选 ${all.length} 台',
      child: _checkbox(value, tristate: true, (_) {
        setState(() {
          if (value == true) {
            _checked.removeAll(all.map((s) => s.id));
          } else {
            _checked.addAll(all.map((s) => s.id));
          }
        });
      }),
    );
  }

  Widget _table(List<SessionConfig> rows, {required double maxHeight}) {
    final cs = Theme.of(context).colorScheme;
    final bodyH = math.min(rows.length * _rowH, maxHeight - _headerH - 2);
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: _headerH,
              color: cs.surfaceContainerHigh,
              child: Row(
                children: [
                  const SizedBox(width: 3),
                  _headerCheckbox(rows),
                  const SizedBox(width: 85),
                  Expanded(flex: 4, child: _headerCell('名称', _SortKey.name)),
                  Expanded(flex: 4, child: _headerCell('地址', _SortKey.address)),
                  SizedBox(
                    width: 120,
                    child: _headerCell('最近连接', _SortKey.recent),
                  ),
                  SizedBox(
                    width: _actionsW,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '操作',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: math.max(0, bodyH),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: rows.length * _rowH > bodyH,
                child: ListView.builder(
                  controller: _scroll,
                  itemExtent: _rowH,
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _row(rows[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerCell(String label, _SortKey key) {
    final cs = Theme.of(context).colorScheme;
    final active = _sort == key;
    return InkWell(
      onTap: () => setState(() {
        final firstAsc = key != _SortKey.recent;
        if (_sort != key) {
          _sort = key;
          _asc = firstAsc;
        } else if (_asc == firstAsc) {
          _asc = !firstAsc;
        } else {
          _sort = _SortKey.added;
          _asc = true;
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              active
                  ? (_asc ? Icons.arrow_upward : Icons.arrow_downward)
                  : Icons.unfold_more,
              size: 13,
              color: active
                  ? cs.primary
                  : cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _favButton(SessionConfig s) {
    return IconButton(
      tooltip: s.favorite ? '取消收藏' : '收藏',
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      onPressed: () => store.toggleFavorite(s.id),
      icon: Icon(
        s.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
        color: s.favorite
            ? Colors.amber.shade600
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _typeIcon(SessionConfig s) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: cs.outline.withValues(alpha: 0.6)),
      ),
      child: Icon(
        s.type == SessionType.vnc
            ? Icons.desktop_windows_outlined
            : Icons.terminal,
        size: 16,
        color: cs.onSurface,
      ),
    );
  }

  Widget _authBadge(SessionConfig s) {
    final cs = Theme.of(context).colorScheme;
    final label = s.type == SessionType.vnc
        ? 'VNC'
        : s.authType == AuthType.key
        ? '密钥'
        : '密码';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _copyButton(SessionConfig s) {
    return IconButton(
      tooltip: '复制 IP、端口、用户名、密码',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      onPressed: () => _copyInfo(s),
      icon: Icon(
        Icons.content_copy_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _connectButton(SessionConfig s) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      onPressed: () => widget.onConnect(s),
      icon: const Icon(Icons.play_arrow_rounded, size: 18),
      label: const Text('连接'),
    );
  }

  Widget _moreButton(SessionConfig s) {
    return InkResponse(
      radius: 18,
      onTap: () {},
      onTapUp: (d) => _sessionMenu(s, d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.more_horiz,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _draggable(SessionConfig s, Widget child) {
    return Draggable<SessionConfig>(
      data: s,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(s.displayName),
        ),
      ),
      child: child,
    );
  }

  Widget _row(SessionConfig s) {
    final cs = Theme.of(context).colorScheme;
    final checked = _checked.contains(s.id);
    final selected = _selectedId == s.id || checked;
    final sub = s.type == SessionType.vnc
        ? 'VNC'
        : (s.username.isEmpty ? '—' : s.username);
    return _draggable(
      s,
      Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        child: InkWell(
          onTap: () => _tapSession(s),
          onSecondaryTapUp: (d) => _sessionMenu(s, d.globalPosition),
          child: Container(
            height: _rowH,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
                left: BorderSide(
                  color: selected ? cs.primary : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                _checkbox(checked, (v) => _toggleChecked(s.id, v ?? false)),
                SizedBox(width: 41, child: Center(child: _favButton(s))),
                SizedBox(width: 44, child: Center(child: _typeIcon(s))),
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        _subtitleWithNote(s, sub),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${s.host}:${s.port}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _mono.copyWith(
                              fontSize: 13,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        _copyHostButton(s),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      formatAgo(s.lastConnectedAt),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: s.lastConnectedAt > 0
                            ? cs.onSurface
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: _actionsW,
                  child: Row(
                    children: [
                      _copyButton(s),
                      const SizedBox(width: 4),
                      _connectButton(s),
                      const Spacer(),
                      _moreButton(s),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 地址后的小按钮：只复制主机（IP 或域名），不带端口。
  Widget _copyHostButton(SessionConfig s) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '复制 IP（不含端口）',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => copyText(context, s.host, tip: '已复制 ${s.host}'),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.content_copy_rounded,
            size: 13,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 列表行第二行：用户名，后面跟备注（悬停显示完整备注）。
  Widget _subtitleWithNote(SessionConfig s, String sub) {
    final cs = Theme.of(context).colorScheme;
    final note = s.description.trim().replaceAll(RegExp(r'\s*\n\s*'), '  ');
    final style = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: sub),
          if (note.isNotEmpty) ...[
            const TextSpan(text: '  ·  '),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Icon(
                  Icons.sticky_note_2_outlined,
                  size: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            TextSpan(text: note),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (note.isEmpty) return text;
    return Tooltip(
      message: s.description.trim(),
      waitDuration: const Duration(milliseconds: 400),
      child: text,
    );
  }

  Widget _cards(List<SessionConfig> items, int cols) {
    return Scrollbar(
      controller: _scroll,
      child: GridView.builder(
        controller: _scroll,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisExtent: _cardH,
          crossAxisSpacing: _gap,
          mainAxisSpacing: _gap,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => _card(items[i]),
      ),
    );
  }

  Widget _card(SessionConfig s) {
    final cs = Theme.of(context).colorScheme;
    final checked = _checked.contains(s.id);
    final selected = _selectedId == s.id || checked;
    final sub = s.type == SessionType.vnc
        ? '${s.host}:${s.port}'
        : '${s.username}@${s.host}:${s.port}';
    return _draggable(
      s,
      Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.10)
            : cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _tapSession(s),
          onSecondaryTapUp: (d) => _sessionMenu(s, d.globalPosition),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (_checked.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: SizedBox(
                          width: 22,
                          child: Checkbox(
                            value: checked,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) => _toggleChecked(s.id, v ?? false),
                          ),
                        ),
                      ),
                    _typeIcon(s),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    _favButton(s),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _mono.copyWith(
                            fontSize: 12.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      _copyHostButton(s),
                    ],
                  ),
                ),
                if (s.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Tooltip(
                    message: s.description.trim(),
                    waitDuration: const Duration(milliseconds: 400),
                    child: Row(
                      children: [
                        Icon(
                          Icons.sticky_note_2_outlined,
                          size: 13,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            s.description.trim().replaceAll(
                              RegExp(r'\s*\n\s*'),
                              '  ',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    _authBadge(s),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        formatAgo(s.lastConnectedAt),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    _copyButton(s),
                    const Spacer(),
                    _connectButton(s),
                    _moreButton(s),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
