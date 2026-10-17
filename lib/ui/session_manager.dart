import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import 'session_editor.dart';
import 'widgets/common.dart';

/// 会话管理器：分组树、搜索、新建/编辑/复制/删除/移动会话，双击或点击连接。
class SessionManagerView extends StatefulWidget {
  const SessionManagerView({super.key, required this.onConnect});
  final void Function(SessionConfig s) onConnect;

  @override
  State<SessionManagerView> createState() => _SessionManagerViewState();
}

class _SessionManagerViewState extends State<SessionManagerView> {
  final _search = TextEditingController();
  final Set<String> _collapsed = {};
  String? _selectedId;

  AppStore get store => context.read<AppStore>();

  Future<void> _newSession(SessionType type, {String? groupId}) async {
    final s = SessionConfig(type: type, groupId: groupId);
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
        title: '删除会话', message: '确定删除“${s.displayName}”吗？', danger: true)) {
      store.deleteSession(s.id);
    }
  }

  Future<void> _newGroup({String? parentId}) async {
    final name = await promptText(context, title: '新建分组', label: '分组名称');
    if (name == null || name.trim().isEmpty) return;
    store.upsertGroup(SessionGroup(name: name.trim(), parentId: parentId));
  }

  Future<void> _renameGroup(SessionGroup g) async {
    final name =
        await promptText(context, title: '重命名分组', initial: g.name, label: '分组名称');
    if (name == null || name.trim().isEmpty) return;
    g.name = name.trim();
    store.upsertGroup(g);
  }

  Future<void> _deleteGroup(SessionGroup g) async {
    if (await confirm(context,
        title: '删除分组',
        message: '删除分组“${g.name}”后，其中的会话会移动到上级分组。',
        danger: true)) {
      store.deleteGroup(g.id);
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
            child: const Text('（根目录）'),
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

  void _showSessionMenu(SessionConfig s, Offset pos) async {
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'connect', child: Text('连接')),
        PopupMenuItem(value: 'edit', child: Text('编辑')),
        PopupMenuItem(value: 'dup', child: Text('复制会话')),
        PopupMenuItem(value: 'move', child: Text('移动到分组')),
        PopupMenuItem(value: 'copyHost', child: Text('复制地址')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (!mounted) return;
    switch (r) {
      case 'connect':
        widget.onConnect(s);
        break;
      case 'edit':
        _edit(s);
        break;
      case 'dup':
        _duplicate(s);
        break;
      case 'move':
        _moveTo(s);
        break;
      case 'copyHost':
        copyText(context, s.host);
        break;
      case 'delete':
        _delete(s);
        break;
    }
  }

  void _showGroupMenu(SessionGroup g, Offset pos) async {
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'ssh', child: Text('在此新建 SSH 会话')),
        PopupMenuItem(value: 'vnc', child: Text('在此新建 VNC 会话')),
        PopupMenuItem(value: 'sub', child: Text('新建子分组')),
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: Text('删除分组')),
      ],
    );
    if (!mounted) return;
    switch (r) {
      case 'ssh':
        _newSession(SessionType.ssh, groupId: g.id);
        break;
      case 'vnc':
        _newSession(SessionType.vnc, groupId: g.id);
        break;
      case 'sub':
        _newGroup(parentId: g.id);
        break;
      case 'rename':
        _renameGroup(g);
        break;
      case 'delete':
        _deleteGroup(g);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final q = _search.text.trim().toLowerCase();
    final sessions = store.sessions;
    final groups = store.groups;

    final rows = <Widget>[];
    if (q.isNotEmpty) {
      final matched = sessions.where((s) =>
          s.displayName.toLowerCase().contains(q) ||
          s.host.toLowerCase().contains(q) ||
          s.username.toLowerCase().contains(q) ||
          s.description.toLowerCase().contains(q));
      for (final s in matched) {
        rows.add(_sessionTile(s, 0));
      }
    } else {
      void addLevel(String? parentId, int depth) {
        final gs = groups.where((g) => g.parentId == parentId).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        for (final g in gs) {
          rows.add(_groupTile(g, depth));
          if (!_collapsed.contains(g.id)) addLevel(g.id, depth + 1);
        }
        final ss = sessions
            .where((s) =>
                s.groupId == parentId ||
                (parentId == null && store.groupById(s.groupId) == null))
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
        for (final s in ss) {
          rows.add(_sessionTile(s, depth));
        }
      }

      addLevel(null, 0);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '搜索名称 / 主机 / 用户 / 备注',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                tooltip: '新建',
                icon: const Icon(Icons.add_box_outlined),
                onSelected: (v) {
                  if (v == 'ssh') _newSession(SessionType.ssh);
                  if (v == 'vnc') _newSession(SessionType.vnc);
                  if (v == 'group') _newGroup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'ssh', child: Text('新建 SSH 连接')),
                  PopupMenuItem(value: 'vnc', child: Text('新建 VNC 远程桌面')),
                  PopupMenuItem(value: 'group', child: Text('新建分组')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.dns_outlined,
                          size: 48, color: Theme.of(context).hintColor),
                      const SizedBox(height: 8),
                      Text(q.isEmpty ? '还没有会话' : '没有匹配的会话'),
                      if (q.isEmpty) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => _newSession(SessionType.ssh),
                          icon: const Icon(Icons.add),
                          label: const Text('新建 SSH 连接'),
                        ),
                      ],
                    ],
                  ),
                )
              : DragTarget<SessionConfig>(
                  onAcceptWithDetails: (d) {
                    d.data.groupId = null;
                    store.upsertSession(d.data);
                  },
                  builder: (context, _, _) => ListView(children: rows),
                ),
        ),
      ],
    );
  }

  Widget _groupTile(SessionGroup g, int depth) {
    final collapsed = _collapsed.contains(g.id);
    return DragTarget<SessionConfig>(
      onAcceptWithDetails: (d) {
        d.data.groupId = g.id;
        store.upsertSession(d.data);
      },
      builder: (context, cand, _) => GestureDetector(
        onSecondaryTapUp: (d) => _showGroupMenu(g, d.globalPosition),
        onLongPressStart: (d) => _showGroupMenu(g, d.globalPosition),
        child: Container(
          color: cand.isNotEmpty
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
            leading: Icon(collapsed ? Icons.folder : Icons.folder_open,
                color: Colors.amber.shade700, size: 20),
            title: Text(g.name),
            onTap: () => setState(() {
              collapsed ? _collapsed.remove(g.id) : _collapsed.add(g.id);
            }),
          ),
        ),
      ),
    );
  }

  Widget _sessionTile(SessionConfig s, int depth) {
    final selected = _selectedId == s.id;
    final subtitle = s.type == SessionType.vnc
        ? 'VNC  ${s.host}:${s.port}'
        : '${s.username}@${s.host}:${s.port}';
    final tile = GestureDetector(
      onSecondaryTapUp: (d) => _showSessionMenu(s, d.globalPosition),
      onLongPressStart: (d) => _showSessionMenu(s, d.globalPosition),
      onDoubleTap: () => widget.onConnect(s),
      child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: EdgeInsets.only(left: 8.0 + depth * 16, right: 4),
        leading: Icon(
          s.type == SessionType.vnc ? Icons.desktop_windows_outlined : Icons.terminal,
          size: 20,
        ),
        title: Text(s.displayName, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          s.description.isEmpty ? subtitle : '$subtitle  ·  ${s.description}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        onTap: () {
          if (isWide(context)) {
            setState(() => _selectedId = s.id);
          } else {
            widget.onConnect(s);
          }
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _edit(s),
            ),
            IconButton(
              tooltip: '连接',
              icon: const Icon(Icons.play_arrow, size: 20),
              onPressed: () => widget.onConnect(s),
            ),
          ],
        ),
      ),
    );
    if (!isWide(context)) return tile;
    return Draggable<SessionConfig>(
      data: s,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(s.displayName),
        ),
      ),
      child: tile,
    );
  }
}

Future<void> showSessionManagerDialog(
    BuildContext context, void Function(SessionConfig) onConnect) {
  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Text('会话管理器', style: Theme.of(ctx).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SessionManagerView(
                onConnect: (s) {
                  Navigator.pop(ctx);
                  onConnect(s);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
