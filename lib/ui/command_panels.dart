import 'dart:io';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import '../state/ssh_tab.dart';
import '../state/tabs_controller.dart';
import 'widgets/common.dart';

/// 终端下方的命令输入框：回车发送，Shift+回车换行，↑↓ 翻历史，可同时发送到所有会话。
class CommandInputBar extends StatefulWidget {
  const CommandInputBar({super.key, required this.tab});
  final SshTab tab;

  @override
  State<CommandInputBar> createState() => _CommandInputBarState();
}

class _CommandInputBarState extends State<CommandInputBar> {
  final _ctrl = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  bool _toAll = false;
  int _histIndex = -1;

  void _send() {
    final text = _ctrl.text;
    if (text.trim().isEmpty) return;
    final store = context.read<AppStore>();
    for (final line in text.split('\n')) {
      store.addHistory(line);
    }
    final payload = '${text.replaceAll('\n', '\r')}\r';
    if (_toAll) {
      context.read<TabsController>().broadcast(payload);
    } else {
      widget.tab.sendText(payload);
    }
    _ctrl.clear();
    _histIndex = -1;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final hist = context.read<AppStore>().history;
    if (e.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp && !_ctrl.text.contains('\n')) {
      if (hist.isEmpty) return KeyEventResult.handled;
      _histIndex = (_histIndex + 1).clamp(0, hist.length - 1);
      _setText(hist[_histIndex]);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown && !_ctrl.text.contains('\n')) {
      if (_histIndex <= 0) {
        _histIndex = -1;
        _setText('');
      } else {
        _histIndex--;
        _setText(hist[_histIndex]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _setText(String t) {
    _ctrl.text = t;
    _ctrl.selection = TextSelection.collapsed(offset: t.length);
  }

  Future<void> _pickHistory() async {
    if (context.read<AppStore>().history.isEmpty) {
      showToast(context, '暂无历史命令');
      return;
    }
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: HistoryList(onPick: (c) => Navigator.pop(ctx, c)),
        ),
      ),
    );
    if (r != null) {
      _setText(r);
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace',
                  fontFamilyFallback: ['Consolas', 'Menlo']),
              decoration: InputDecoration(
                hintText: _toAll ? '命令将发送到所有已连接的会话' : '输入命令，回车发送（Shift+回车换行，↑↓ 历史）',
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
          ),
          IconButton(
            tooltip: '历史命令',
            icon: const Icon(Icons.history, size: 20),
            onPressed: _pickHistory,
          ),
          Tooltip(
            message: '发送到所有会话',
            child: FilterChip(
              label: const Text('全部'),
              selected: _toAll,
              onSelected: (v) => setState(() => _toAll = v),
              visualDensity: VisualDensity.compact,
            ),
          ),
          IconButton(
            tooltip: '发送',
            icon: const Icon(Icons.send, size: 20),
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}

/// 历史命令列表：单击回填，双击（或点击执行按钮）直接执行。
class HistoryList extends StatefulWidget {
  const HistoryList({super.key, required this.onPick, this.onRun});
  final void Function(String cmd) onPick;
  final void Function(String cmd)? onRun;

  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final list = store.history
        .where((h) => _filter.isEmpty || h.toLowerCase().contains(_filter))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '搜索历史命令',
                  ),
                  onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
                ),
              ),
              IconButton(
                tooltip: '清空历史',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  if (await confirm(context, title: '清空历史命令', danger: true)) {
                    store.clearHistory();
                  }
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('暂无历史命令', style: TextStyle(fontSize: 12)))
              : ListView.builder(
                  itemCount: list.length,
                  itemExtent: 32,
                  itemBuilder: (context, i) {
                    final c = list[i];
                    return InkWell(
                      onTap: () => widget.onPick(c),
                      onDoubleTap: widget.onRun == null ? null : () => widget.onRun!(c),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(c,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace',
                                      fontFamilyFallback: ['Consolas', 'Menlo'])),
                            ),
                            if (widget.onRun != null)
                              IconButton(
                                tooltip: '执行',
                                visualDensity: VisualDensity.compact,
                                iconSize: 16,
                                icon: const Icon(Icons.play_arrow),
                                onPressed: () => widget.onRun!(c),
                              ),
                            IconButton(
                              tooltip: '复制',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              icon: const Icon(Icons.copy),
                              onPressed: () => copyText(context, c),
                            ),
                            IconButton(
                              tooltip: '删除',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              icon: const Icon(Icons.close),
                              onPressed: () => store.removeHistory(c),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}


/// 快速命令：按分组以树状显示，双击发送到当前终端，可拖拽调整命令与分组顺序。
class QuickCommandPanel extends StatefulWidget {
  const QuickCommandPanel({super.key, required this.onSend});
  final void Function(QuickCommand c) onSend;

  @override
  State<QuickCommandPanel> createState() => _QuickCommandPanelState();
}

typedef _Row = ({String group, QuickCommand? cmd});

class _QuickCommandPanelState extends State<QuickCommandPanel> {
  /// 已收起的分组，所有会话标签共用。
  static final Set<String> _collapsed = {};
  String? _selected;
  String? _lastTapId;
  DateTime? _lastTapAt;

  static bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  List<_Row> _rows(List<String> groups, Map<String, List<QuickCommand>> byGroup) => [
        for (final g in groups) ...[
          (group: g, cmd: null),
          if (!_collapsed.contains(g))
            for (final c in byGroup[g]!) (group: g, cmd: c),
        ],
      ];

  void _toggle(String g) => setState(
      () => _collapsed.contains(g) ? _collapsed.remove(g) : _collapsed.add(g));

  void _onTapCommand(QuickCommand c) {
    final now = DateTime.now();
    final last = _lastTapAt;
    final dbl = _lastTapId == c.id &&
        last != null &&
        now.difference(last) < kDoubleTapTimeout;
    _lastTapId = c.id;
    _lastTapAt = dbl ? null : now;
    if (dbl) {
      widget.onSend(c);
    } else {
      setState(() => _selected = c.id);
    }
  }

  void _onReorder(
    AppStore store,
    List<_Row> rows,
    List<String> groups,
    Map<String, List<QuickCommand>> byGroup,
    int oldIndex,
    int newIndex,
  ) {
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final next = [...rows];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);

    final movedCmd = moved.cmd;
    if (movedCmd == null) {
      final order = [for (final r in next) if (r.cmd == null) r.group];
      store.applyQuickLayout(order, [
        for (final g in order)
          for (final c in byGroup[g]!) (c.id, g),
      ]);
      return;
    }
    // 命令落在哪个分组标题之下就归入该分组；收起的分组在标题处展开其隐藏的命令。
    final items = <(String, String)>[];
    String? current;
    for (final r in next) {
      final c = r.cmd;
      if (c == null) {
        current = r.group;
        if (_collapsed.contains(r.group)) {
          for (final h in byGroup[r.group]!) {
            if (h.id != movedCmd.id) items.add((h.id, r.group));
          }
        }
      } else {
        items.add((c.id, current ?? groups.first));
      }
    }
    store.applyQuickLayout(groups, items);
  }

  Future<void> _newCommand(AppStore store, String group) async {
    final c = await showQuickCommandEditor(context, QuickCommand(group: group));
    if (c == null) return;
    store.upsertQuickCommand(c);
    setState(() {
      _collapsed.remove(c.group);
      _selected = c.id;
    });
  }

  Future<void> _groupMenu(AppStore store, String g, Offset pos) async {
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'new', child: Text('在此分组新建命令')),
        PopupMenuItem(value: 'rename', child: Text('重命名分组')),
        PopupMenuItem(value: 'delete', child: Text('删除分组')),
      ],
    );
    if (!mounted || r == null) return;
    switch (r) {
      case 'new':
        await _newCommand(store, g);
      case 'rename':
        final name = (await promptText(context, title: '重命名分组', initial: g))?.trim();
        if (name == null || name.isEmpty || name == g) return;
        store.renameQuickGroup(g, name);
        if (_collapsed.remove(g)) _collapsed.add(name);
      case 'delete':
        final n = store.quickCommands.where((c) => c.group == g).length;
        if (!mounted) return;
        if (await confirm(context,
            title: '删除分组',
            message: '确定删除分组“$g”及其中的 $n 条命令吗？',
            danger: true)) {
          store.deleteQuickGroup(g);
        }
    }
  }

  Widget _dragWrap(int index, Widget child) => _desktop
      ? ReorderableDragStartListener(index: index, child: child)
      : ReorderableDelayedDragStartListener(index: index, child: child);

  Widget _groupRow(AppStore store, String g, int count, int index) {
    final cs = Theme.of(context).colorScheme;
    final open = !_collapsed.contains(g);
    return _dragWrap(
      index,
      InkWell(
        onTap: () => _toggle(g),
        onSecondaryTapUp: (d) => _groupMenu(store, g, d.globalPosition),
        onLongPress: _desktop ? null : () => _groupMenu(store, g, Offset.zero),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Icon(open ? Icons.expand_more : Icons.chevron_right,
                  size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 2),
              Icon(open ? Icons.folder_open_outlined : Icons.folder_outlined,
                  size: 16, color: Colors.amber.shade600),
              const SizedBox(width: 6),
              Expanded(
                child: Text(g,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Text('$count',
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commandRow(QuickCommand c, int index) {
    final cs = Theme.of(context).colorScheme;
    final selected = _selected == c.id;
    return _dragWrap(
      index,
      Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        child: InkWell(
          onTap: () => _onTapCommand(c),
          onSecondaryTapUp: (d) {
            setState(() => _selected = c.id);
            _menu(c, d.globalPosition);
          },
          onLongPress: _desktop ? null : () => _menu(c, Offset.zero),
          child: Padding(
              padding: const EdgeInsets.only(left: 30, right: 4),
              child: Row(
                children: [
                  Icon(Icons.bolt, size: 15, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: c.name.isEmpty ? c.command : c.name,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        if (c.name.isNotEmpty)
                          TextSpan(
                            text: '   ${c.command.replaceAll(RegExp(r'\s*\n\s*'), ' ⏎ ')}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                              fontFamily: 'monospace',
                              fontFamilyFallback: const ['Consolas', 'Menlo'],
                            ),
                          ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selected)
                    IconButton(
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                      icon: const Icon(Icons.send_rounded),
                      onPressed: () => widget.onSend(c),
                    ),
                ],
              ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final cs = Theme.of(context).colorScheme;
    final groups = store.quickCommandGroups;
    final byGroup = <String, List<QuickCommand>>{for (final g in groups) g: []};
    for (final c in store.quickCommands) {
      byGroup[c.group]!.add(c);
    }
    final rows = _rows(groups, byGroup);
    final allCollapsed = groups.isNotEmpty && groups.every(_collapsed.contains);

    return Column(
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _desktop ? '双击发送，拖动调整顺序' : '点按选中，长按拖动排序',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                ),
              ),
              IconButton(
                tooltip: allCollapsed ? '全部展开' : '全部收起',
                iconSize: 17,
                visualDensity: VisualDensity.compact,
                icon: Icon(allCollapsed ? Icons.unfold_more : Icons.unfold_less),
                onPressed: () => setState(() =>
                    allCollapsed ? _collapsed.clear() : _collapsed.addAll(groups)),
              ),
              IconButton(
                tooltip: '添加快速命令',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add),
                onPressed: () {
                  final sel = store.quickCommands
                      .where((c) => c.id == _selected)
                      .firstOrNull;
                  _newCommand(store, sel?.group ?? groups.firstOrNull ?? '默认');
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text('点击右上角 + 添加常用命令', style: TextStyle(fontSize: 12)))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemExtent: 30,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: rows.length,
                  proxyDecorator: (child, _, _) => Material(
                    elevation: 3,
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(6),
                    child: child,
                  ),
                  onReorder: (o, n) => _onReorder(store, rows, groups, byGroup, o, n),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final c = r.cmd;
                    return KeyedSubtree(
                      key: ValueKey(c == null ? 'g:${r.group}' : 'c:${c.id}'),
                      child: c == null
                          ? _groupRow(store, r.group, byGroup[r.group]!.length, i)
                          : _commandRow(c, i),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _menu(QuickCommand c, Offset pos) async {
    final store = context.read<AppStore>();
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'send', child: Text('发送')),
        PopupMenuItem(value: 'edit', child: Text('编辑')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (!mounted) return;
    if (r == 'send') widget.onSend(c);
    if (r == 'edit') {
      final e = await showQuickCommandEditor(context, QuickCommand.fromJson(c.toJson()));
      if (e != null) store.upsertQuickCommand(e);
    }
    if (r == 'delete') store.deleteQuickCommand(c.id);
  }
}

Future<QuickCommand?> showQuickCommandEditor(BuildContext context, QuickCommand c) {
  final store = context.read<AppStore>();
  final isNew = !store.quickCommands.any((e) => e.id == c.id);
  final groups = store.quickCommandGroups;
  final name = TextEditingController(text: c.name);
  final group = TextEditingController(text: c.group);
  final cmd = TextEditingController(text: c.command);
  var enter = c.appendEnter;
  String? cmdError;

  return showDialog<QuickCommand>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final cs = Theme.of(ctx).colorScheme;
      void save() {
        if (cmd.text.trim().isEmpty) {
          setState(() => cmdError = '请输入要发送的命令');
          return;
        }
        c
          ..name = name.text.trim()
          ..group = group.text.trim().isEmpty ? '默认' : group.text.trim()
          ..command = cmd.text
          ..appendEnter = enter;
        Navigator.pop(ctx, c);
      }

      return AppDialog(
        title: isNew ? '新建快速命令' : '编辑快速命令',
        description: '在右侧「快速命令」中双击即可发送到当前终端。',
        width: 540,
        actions: [
          AppButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
          AppButton(label: '保存', primary: true, onPressed: save),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: LabeledField(
                    label: '名称',
                    child: TextField(
                      controller: name,
                      autofocus: isNew,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(hintText: '可选，留空时显示命令本身'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 190,
                  child: LabeledField(
                    label: '分组',
                    child: TextField(
                      controller: group,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '默认',
                        suffixIcon: groups.isEmpty
                            ? null
                            : PopupMenuButton<String>(
                                tooltip: '选择已有分组',
                                icon: const Icon(Icons.expand_more, size: 18),
                                onSelected: (g) => setState(() => group.text = g),
                                itemBuilder: (_) => [
                                  for (final g in groups)
                                    PopupMenuItem(value: g, height: 36, child: Text(g)),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            LabeledField(
              label: '命令',
              child: TextField(
                controller: cmd,
                autofocus: !isNew,
                minLines: 5,
                maxLines: 12,
                onChanged: (_) {
                  if (cmdError != null) setState(() => cmdError = null);
                },
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Consolas', 'Menlo'],
                ),
                decoration: InputDecoration(
                  hintText: '例如：df -h\n多行命令会按行依次发送',
                  errorText: cmdError,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('发送后自动回车执行', style: TextStyle(fontSize: 14)),
              subtitle: Text('关闭后只把命令填入终端，确认后再手动回车',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              value: enter,
              onChanged: (v) => setState(() => enter = v),
            ),
          ],
        ),
      );
    }),
  );
}

void sendQuickCommand(SshTab tab, QuickCommand c) {
  final body = c.command.replaceAll('\r\n', '\n').replaceAll('\n', '\r');
  tab.sendText(c.appendEnter ? '$body\r' : body, recordHistory: true);
  tab.focusTerminal();
}
