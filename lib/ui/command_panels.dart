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

/// 快速命令：按分组显示按钮，点击发送到当前终端。
class QuickCommandPanel extends StatefulWidget {
  const QuickCommandPanel({super.key, required this.onSend});
  final void Function(QuickCommand c) onSend;

  @override
  State<QuickCommandPanel> createState() => _QuickCommandPanelState();
}

class _QuickCommandPanelState extends State<QuickCommandPanel> {
  String? _group;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final all = store.quickCommands;
    final groups = all.map((c) => c.group).toSet().toList()..sort();
    final current = _group != null && groups.contains(_group) ? _group : null;
    final list = all.where((c) => current == null || c.group == current).toList();
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: const Text('全部'),
                        selected: current == null,
                        onSelected: (_) => setState(() => _group = null),
                      ),
                    ),
                    for (final g in groups)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: ChoiceChip(
                          label: Text(g),
                          selected: current == g,
                          onSelected: (_) => setState(() => _group = g),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '添加快速命令',
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final c = await showQuickCommandEditor(
                      context, QuickCommand(group: current ?? '默认'));
                  if (c != null) store.upsertQuickCommand(c);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text('点击右上角 + 添加常用命令', style: TextStyle(fontSize: 12)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in list)
                        GestureDetector(
                          onSecondaryTapUp: (d) => _menu(c, d.globalPosition),
                          onLongPressStart: (d) => _menu(c, d.globalPosition),
                          child: Tooltip(
                            message: c.command,
                            child: ActionChip(
                              avatar: const Icon(Icons.bolt, size: 16),
                              label: Text(c.name.isEmpty ? c.command : c.name),
                              onPressed: () => widget.onSend(c),
                            ),
                          ),
                        ),
                    ],
                  ),
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
  final name = TextEditingController(text: c.name);
  final group = TextEditingController(text: c.group);
  final cmd = TextEditingController(text: c.command);
  var enter = c.appendEnter;
  return showDialog<QuickCommand>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('快速命令'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称')),
              const SizedBox(height: 10),
              TextField(controller: group, decoration: const InputDecoration(labelText: '分组')),
              const SizedBox(height: 10),
              TextField(
                controller: cmd,
                minLines: 2,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace',
                    fontFamilyFallback: ['Consolas', 'Menlo']),
                decoration: const InputDecoration(
                    labelText: '命令（多行将依次执行）', alignLabelWithHint: true),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('发送后自动回车执行'),
                value: enter,
                onChanged: (v) => setState(() => enter = v ?? true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (cmd.text.trim().isEmpty) return;
              c
                ..name = name.text.trim()
                ..group = group.text.trim().isEmpty ? '默认' : group.text.trim()
                ..command = cmd.text
                ..appendEnter = enter;
              Navigator.pop(ctx, c);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

void sendQuickCommand(SshTab tab, QuickCommand c) {
  final body = c.command.replaceAll('\r\n', '\n').replaceAll('\n', '\r');
  tab.sendText(c.appendEnter ? '$body\r' : body, recordHistory: true);
}
