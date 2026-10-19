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

enum _Scope { all, favorites, recent, group, ungrouped }

enum _TypeFilter { all, ssh, vnc, favorite }

enum _SortKey { name, address, auth, recent }

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
    required this.onOpenSettings,
  });

  final void Function(SessionConfig s) onConnect;
  final void Function(int tab) onOpenSettings;

  @override
  State<ServerHomeView> createState() => _ServerHomeViewState();
}

class _ServerHomeViewState extends State<ServerHomeView> {
  static const double _rowH = 54;
  static const double _headerH = 40;
  static const double _footerH = 56;
  static const double _cardW = 272;
  static const double _cardH = 164;
  static const double _gap = 12;
  static const double _actionsW = 176;

  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  _Scope _scope = _Scope.all;
  String? _groupId;
  _TypeFilter _type = _TypeFilter.all;
  AuthType? _auth;
  _SortKey _sort = _SortKey.name;
  bool _asc = true;
  bool _grid = false;
  int _page = 0;
  String? _selectedId;

  String? _lastTapId;
  DateTime? _lastTapAt;

  AppStore get store => context.read<AppStore>();

  bool get _isMac => !kIsWeb && Platform.isMacOS;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _update(VoidCallback fn) => setState(() {
        fn();
        _page = 0;
      });

  void _setScope(_Scope scope, {String? groupId}) => _update(() {
        _scope = scope;
        _groupId = groupId;
        if (scope == _Scope.recent) {
          _sort = _SortKey.recent;
          _asc = false;
        }
      });

  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection =
        TextSelection(baseOffset: 0, extentOffset: _search.text.length);
  }

  // ---------------- 数据筛选 ----------------

  Set<String> _descendants(String id, List<SessionGroup> groups) {
    final out = <String>{id};
    var frontier = [id];
    var guard = 0;
    while (frontier.isNotEmpty && guard++ < 50) {
      final next = <String>[];
      for (final g in groups) {
        if (g.parentId != null && frontier.contains(g.parentId) && out.add(g.id)) {
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
          .where((s) =>
              s.displayName.toLowerCase().contains(q) ||
              s.host.toLowerCase().contains(q) ||
              s.username.toLowerCase().contains(q) ||
              s.description.toLowerCase().contains(q))
          .toList();
    }
    int cmp(SessionConfig a, SessionConfig b) {
      switch (_sort) {
        case _SortKey.name:
          return a.displayName
              .toLowerCase()
              .compareTo(b.displayName.toLowerCase());
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
    if (r != null) store.upsertSession(r);
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
  }

  Future<void> _delete(SessionConfig s) async {
    if (await confirm(context,
        title: '删除服务器',
        message: '确定删除“${s.displayName}”吗？',
        danger: true)) {
      store.deleteSession(s.id);
    }
  }

  Future<void> _moveTo(SessionConfig s) async {
    final groups = store.groups;
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移动到分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('未分组'),
          ),
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g.id),
              child: Text(_groupPath(g)),
            ),
        ],
      ),
    );
    if (target == null) return;
    s.groupId = target.isEmpty ? null : target;
    store.upsertSession(s);
  }

  Future<void> _newGroup({String? parentId}) async {
    final name = await promptText(context, title: '新建分组', label: '分组名称');
    if (name == null || name.trim().isEmpty) return;
    store.upsertGroup(SessionGroup(name: name.trim(), parentId: parentId));
  }

  Future<void> _renameGroup(SessionGroup g) async {
    final name = await promptText(context,
        title: '重命名分组', initial: g.name, label: '分组名称');
    if (name == null || name.trim().isEmpty) return;
    g.name = name.trim();
    store.upsertGroup(g);
  }

  Future<void> _deleteGroup(SessionGroup g) async {
    if (await confirm(context,
        title: '删除分组',
        message: '删除分组“${g.name}”后，其中的服务器会移动到上级分组。',
        danger: true)) {
      store.deleteGroup(g.id);
      if (_scope == _Scope.group && _groupId == g.id) _setScope(_Scope.all);
    }
  }

  void _copyInfo(SessionConfig s) {
    final lines = <String>['IP：${s.host}', '端口：${s.port}'];
    if (s.type == SessionType.ssh) {
      lines.add('用户名：${s.username}');
      lines.add(s.authType == AuthType.key ? '认证方式：密钥' : '密码：${s.password}');
    } else if (s.password.isNotEmpty) {
      lines.add('密码：${s.password}');
    }
    copyText(context, lines.join('\n'), tip: '已复制连接信息');
  }

  Future<void> _sessionMenu(SessionConfig s, Offset pos) async {
    setState(() => _selectedId = s.id);
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'connect', child: Text('连接')),
        PopupMenuItem(
            value: 'fav', child: Text(s.favorite ? '取消收藏' : '收藏')),
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuItem(value: 'dup', child: Text('复制服务器')),
        const PopupMenuItem(value: 'move', child: Text('移动到分组')),
        const PopupMenuItem(value: 'copyInfo', child: Text('复制连接信息')),
        const PopupMenuItem(value: 'copyHost', child: Text('复制地址')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (!mounted) return;
    switch (r) {
      case 'connect':
        widget.onConnect(s);
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
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'sub', child: Text('新建子分组')),
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: Text('删除分组')),
      ],
    );
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

  /// 单击选中、双击连接；自行判定双击，避免单击选中被双击识别延迟。
  void _tapSession(SessionConfig s) {
    final now = DateTime.now();
    if (_lastTapId == s.id &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 350)) {
      _lastTapAt = null;
      widget.onConnect(s);
      return;
    }
    _lastTapId = s.id;
    _lastTapAt = now;
    setState(() => _selectedId = s.id);
  }

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
                    Text('快捷命令',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(width: 10),
                    Text('点击复制命令，连接后可在底部「快速命令」中发送',
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(ctx).hintColor)),
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
    if (_scope == _Scope.group && store.groupById(_groupId) == null) {
      _scope = _Scope.all;
      _groupId = null;
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusSearch,
      },
      child: Focus(
        autofocus: true,
        child: Row(
          children: [
            _sidebar(store),
            VerticalDivider(
                width: 1,
                color: Theme.of(context).colorScheme.outlineVariant),
            Expanded(child: _main(store)),
          ],
        ),
      ),
    );
  }

  // ---------------- 左侧导航 ----------------

  Widget _sidebar(AppStore store) {
    final cs = Theme.of(context).colorScheme;
    final sessions = store.sessions;
    final groups = store.groups;
    return Container(
      width: 232,
      color: cs.surfaceContainerLow,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
              children: [
                _navItem(
                  icon: Icons.dns_outlined,
                  label: '所有服务器',
                  count: sessions.length,
                  selected: _scope == _Scope.all,
                  onTap: () => _setScope(_Scope.all),
                ),
                _navItem(
                  icon: Icons.star_outline_rounded,
                  label: '收藏',
                  count: sessions.where((s) => s.favorite).length,
                  selected: _scope == _Scope.favorites,
                  onTap: () => _setScope(_Scope.favorites),
                ),
                _navItem(
                  icon: Icons.history,
                  label: '最近连接',
                  count: sessions.where((s) => s.lastConnectedAt > 0).length,
                  selected: _scope == _Scope.recent,
                  onTap: () => _setScope(_Scope.recent),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1, color: cs.outlineVariant),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 10, bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('分组',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: cs.onSurfaceVariant)),
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
                ..._groupItems(null, 0, groups, sessions),
                _dropTarget(
                  groupId: null,
                  builder: (hover) => _navItem(
                    icon: Icons.folder_off_outlined,
                    label: '未分组',
                    count: sessions.where(_isUngrouped).length,
                    selected: _scope == _Scope.ungrouped,
                    highlighted: hover,
                    onTap: () => _setScope(_Scope.ungrouped),
                  ),
                ),
              ],
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
                Icon(Icons.storage_outlined,
                    size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Text('数据保存在本机',
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _groupItems(String? parentId, int depth,
      List<SessionGroup> groups, List<SessionConfig> sessions) {
    final gs = groups
        .where((g) =>
            g.parentId == parentId ||
            (parentId == null && store.groupById(g.parentId) == null))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return [
      for (final g in gs) ...[
        _dropTarget(
          groupId: g.id,
          builder: (hover) {
            final ids = _descendants(g.id, groups);
            final selected = _scope == _Scope.group && _groupId == g.id;
            return _navItem(
              icon: selected ? Icons.folder_open_outlined : Icons.folder_outlined,
              label: g.name,
              count: sessions.where((s) => ids.contains(s.groupId)).length,
              selected: selected,
              highlighted: hover,
              indent: depth * 14.0,
              onTap: () => _setScope(_Scope.group, groupId: g.id),
              onSecondaryTapUp: (d) => _groupMenu(g, d.globalPosition),
            );
          },
        ),
        if (depth < 6) ..._groupItems(g.id, depth + 1, groups, sessions),
      ],
    ];
  }

  Widget _dropTarget(
      {required String? groupId, required Widget Function(bool) builder}) {
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
    VoidCallback? onTap,
    GestureTapUpCallback? onSecondaryTapUp,
  }) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.primary : cs.onSurface;
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
            padding: EdgeInsets.fromLTRB(10 + indent, 9, 10, 9),
            child: Row(
              children: [
                Icon(icon,
                    size: 18,
                    color: selected ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          color: fg,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500)),
                ),
                if (count != null)
                  Text('$count',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant)),
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
                    Text(_scopeTitle(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface)),
                    const SizedBox(height: 4),
                    Text('${list.length} 台服务器',
                        style: TextStyle(
                            fontSize: 12.5, color: cs.onSurfaceVariant)),
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
          Row(
            children: [
              _chip('全部', _type == _TypeFilter.all,
                  () => _update(() => _type = _TypeFilter.all)),
              _chip('SSH', _type == _TypeFilter.ssh,
                  () => _update(() => _type = _TypeFilter.ssh)),
              if (hasVnc)
                _chip('VNC', _type == _TypeFilter.vnc,
                    () => _update(() => _type = _TypeFilter.vnc)),
              _chip('收藏', _type == _TypeFilter.favorite,
                  () => _update(() => _type = _TypeFilter.favorite)),
              const Spacer(),
              _viewToggle(),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: list.isEmpty
                ? _empty(store.sessions.isEmpty)
                : LayoutBuilder(
                    builder: (context, c) => _paged(list, c),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _newButton() {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      builder: (context, controller, _) => FilledButton.icon(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
          onPressed: () => _newGroup(
              parentId: _scope == _Scope.group ? _groupId : null),
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
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      child: Text(_isMac ? '⌘ K' : 'Ctrl K',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
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
    PopupMenuItem<int> item(int v, String label, bool checked) => PopupMenuItem(
          value: v,
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: checked
                    ? Icon(Icons.check, size: 16, color: cs.primary)
                    : null,
              ),
              Text(label),
            ],
          ),
        );
    return PopupMenuButton<int>(
      tooltip: '按认证方式筛选',
      position: PopupMenuPosition.under,
      onSelected: (v) => _update(() => _auth = switch (v) {
            1 => AuthType.password,
            2 => AuthType.key,
            _ => null,
          }),
      itemBuilder: (_) => [
        item(0, '全部认证方式', _auth == null),
        item(1, '密码', _auth == AuthType.password),
        item(2, '密钥', _auth == AuthType.key),
      ],
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? cs.primary.withValues(alpha: 0.13) : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? cs.primary : cs.outlineVariant),
        ),
        child: Icon(Icons.filter_list,
            size: 20, color: active ? cs.primary : cs.onSurfaceVariant),
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
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: selected ? cs.primary : cs.onSurface,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal)),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Icon(icon,
                    size: 18,
                    color: selected ? cs.onSurface : cs.onSurfaceVariant),
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
          btn(Icons.view_list_outlined, !_grid, '列表视图',
              () => _update(() => _grid = false)),
          const SizedBox(width: 2),
          btn(Icons.grid_view_outlined, _grid, '卡片视图',
              () => _update(() => _grid = true)),
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
          Icon(noSessions ? Icons.dns_outlined : Icons.search_off,
              size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(noSessions ? '还没有服务器' : '没有匹配的服务器',
              style: TextStyle(color: cs.onSurfaceVariant)),
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

  // ---------------- 分页列表 / 卡片 ----------------

  Widget _paged(List<SessionConfig> list, BoxConstraints c) {
    final bodyH = c.maxHeight - _footerH;
    int pageSize;
    int cols = 1;
    if (_grid) {
      cols = math.max(1, ((c.maxWidth + _gap) / (_cardW + _gap)).floor());
      final rows = math.max(1, ((bodyH + _gap) / (_cardH + _gap)).floor());
      pageSize = cols * rows;
    } else {
      pageSize = math.max(3, ((bodyH - _headerH - 2) / _rowH).floor());
    }
    final pages = math.max(1, (list.length / pageSize).ceil());
    final page = _page.clamp(0, pages - 1);
    final start = page * pageSize;
    final end = math.min(start + pageSize, list.length);
    final slice = list.sublist(start, end);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: _grid
                ? _cards(slice, cols)
                : _table(slice, showAuth: c.maxWidth >= 820),
          ),
        ),
        SizedBox(
          height: _footerH,
          child: _pager(start, end, list.length, page, pages),
        ),
      ],
    );
  }

  Widget _table(List<SessionConfig> rows, {required bool showAuth}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
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
                const SizedBox(width: 88),
                Expanded(flex: 4, child: _headerCell('名称', _SortKey.name)),
                Expanded(
                    flex: 4, child: _headerCell('地址', _SortKey.address)),
                if (showAuth)
                  SizedBox(width: 100, child: _headerCell('认证', _SortKey.auth)),
                SizedBox(
                    width: 120, child: _headerCell('最近连接', _SortKey.recent)),
                SizedBox(
                  width: _actionsW,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('操作',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurfaceVariant)),
                  ),
                ),
              ],
            ),
          ),
          for (final s in rows) _row(s, showAuth: showAuth),
        ],
      ),
    );
  }

  Widget _headerCell(String label, _SortKey key) {
    final cs = Theme.of(context).colorScheme;
    final active = _sort == key;
    return InkWell(
      onTap: () => setState(() {
        if (_sort == key) {
          _asc = !_asc;
        } else {
          _sort = key;
          _asc = key != _SortKey.recent;
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        child: Row(
          children: [
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active ? cs.onSurface : cs.onSurfaceVariant)),
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
      child: Text(label,
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
    );
  }

  Widget _copyButton(SessionConfig s) {
    return IconButton(
      tooltip: '复制 IP、端口、用户名、密码',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      onPressed: () => _copyInfo(s),
      icon: Icon(Icons.content_copy_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
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
        child: Icon(Icons.more_horiz,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
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

  Widget _row(SessionConfig s, {required bool showAuth}) {
    final cs = Theme.of(context).colorScheme;
    final selected = _selectedId == s.id;
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
                    color: cs.outlineVariant.withValues(alpha: 0.6)),
                left: BorderSide(
                    color: selected ? cs.primary : Colors.transparent,
                    width: 3),
              ),
            ),
            child: Row(
              children: [
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
                        Text(s.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                        const SizedBox(height: 2),
                        Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('${s.host}:${s.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _mono.copyWith(
                            fontSize: 13, color: cs.onSurface)),
                  ),
                ),
                if (showAuth)
                  SizedBox(
                    width: 100,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: _authBadge(s)),
                    ),
                  ),
                SizedBox(
                  width: 120,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(formatAgo(s.lastConnectedAt),
                        style: TextStyle(
                            fontSize: 12.5,
                            color: s.lastConnectedAt > 0
                                ? cs.onSurface
                                : cs.onSurfaceVariant)),
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
                      const SizedBox(width: 4),
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

  Widget _cards(List<SessionConfig> items, int cols) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisExtent: _cardH,
        crossAxisSpacing: _gap,
        mainAxisSpacing: _gap,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _card(items[i]),
    );
  }

  Widget _card(SessionConfig s) {
    final cs = Theme.of(context).colorScheme;
    final selected = _selectedId == s.id;
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
              width: selected ? 1.5 : 1),
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
                    _typeIcon(s),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface)),
                    ),
                    _favButton(s),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _mono.copyWith(
                          fontSize: 12.5, color: cs.onSurfaceVariant)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _authBadge(s),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(formatAgo(s.lastConnectedAt),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
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

  // ---------------- 分页 ----------------

  List<int> _pageItems(int page, int pages) {
    if (pages <= 7) return List.generate(pages, (i) => i);
    final set = <int>{0, pages - 1, page, page - 1, page + 1};
    if (page <= 2) set.addAll([1, 2, 3]);
    if (page >= pages - 3) set.addAll([pages - 4, pages - 3, pages - 2]);
    final sorted = set.where((p) => p >= 0 && p < pages).toList()..sort();
    final out = <int>[];
    for (var i = 0; i < sorted.length; i++) {
      if (i > 0 && sorted[i] - sorted[i - 1] > 1) out.add(-1);
      out.add(sorted[i]);
    }
    return out;
  }

  Widget _pager(int start, int end, int total, int page, int pages) {
    final cs = Theme.of(context).colorScheme;
    Widget box({
      required Widget child,
      bool selected = false,
      VoidCallback? onTap,
    }) =>
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Material(
            color: selected
                ? cs.primary.withValues(alpha: 0.13)
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                  color: selected ? cs.primary : cs.outlineVariant),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: SizedBox(width: 34, height: 34, child: Center(child: child)),
            ),
          ),
        );
    return Row(
      children: [
        Text('显示 ${start + 1}-$end 条，共 $total 条',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
        const Spacer(),
        box(
          onTap: page > 0 ? () => setState(() => _page = page - 1) : null,
          child: Icon(Icons.chevron_left,
              size: 18,
              color: page > 0
                  ? cs.onSurface
                  : cs.onSurfaceVariant.withValues(alpha: 0.4)),
        ),
        for (final p in _pageItems(page, pages))
          p < 0
              ? const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: SizedBox(width: 22, child: Center(child: Text('…'))),
                )
              : box(
                  selected: p == page,
                  onTap: () => setState(() => _page = p),
                  child: Text('${p + 1}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              p == page ? FontWeight.w600 : FontWeight.normal,
                          color: p == page ? cs.primary : cs.onSurface)),
                ),
        box(
          onTap: page < pages - 1
              ? () => setState(() => _page = page + 1)
              : null,
          child: Icon(Icons.chevron_right,
              size: 18,
              color: page < pages - 1
                  ? cs.onSurface
                  : cs.onSurfaceVariant.withValues(alpha: 0.4)),
        ),
      ],
    );
  }
}
