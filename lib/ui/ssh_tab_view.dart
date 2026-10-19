import 'package:flutter/material.dart';

import '../state/app_tab.dart';
import '../state/editor_file.dart';
import '../state/ssh_tab.dart';
import 'command_panels.dart';
import 'editor_tab_view.dart';
import 'forward_panel.dart';
import 'monitor_panel.dart';
import 'sftp_panel.dart';
import 'terminal_pane.dart';
import 'transfer_panel.dart';
import 'widgets/common.dart';

/// 桌面端布局与 FinalShell 一致：左侧状态监控，右侧上方终端，下方文件/命令/隧道/传输面板。
class SshTabView extends StatefulWidget {
  const SshTabView({super.key, required this.tab});
  final SshTab tab;

  @override
  State<SshTabView> createState() => _SshTabViewState();
}

class _SshTabViewState extends State<SshTabView> {
  static double _leftW = 250;
  static double _rightW = 340;
  static double _bottomH = 220;
  static bool _showLeft = true;
  static bool _showRight = true;
  static bool _showBottom = true;
  int _bottomIndex = 0;
  int _mobileIndex = 0;

  SshTab get tab => widget.tab;

  @override
  Widget build(BuildContext context) {
    // 工作区（终端/监控/SFTP）作为 child 只构建一次，tab 通知（如标题变化）
    // 时不会重建这些重面板，避免输入卡顿；仅副标签栏随 tab 变化重建。
    final workspace = isWide(context) ? _desktop(context) : _mobile(context);
    return ListenableBuilder(
      listenable: tab,
      builder: (context, child) {
        if (tab.editors.isEmpty) return child!;
        return Column(
          children: [
            _subTabBar(context),
            Expanded(
              child: IndexedStack(
                index: tab.subTab.clamp(0, tab.editors.length),
                children: [
                  child!,
                  for (final f in tab.editors)
                    EditorTabView(key: ValueKey(f.path), file: f),
                ],
              ),
            ),
          ],
        );
      },
      child: workspace,
    );
  }

  /// 会话内副标签栏：第一个是「终端」主工作区，之后是打开的各个文件。
  Widget _subTabBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          _subChip(context,
              index: 0,
              icon: Icons.terminal,
              label: '终端',
              closable: false),
          Container(width: 1, height: 20, color: cs.outlineVariant),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tab.editors.length,
              itemBuilder: (context, i) {
                final f = tab.editors[i];
                return ListenableBuilder(
                  listenable: f,
                  builder: (context, _) => _subChip(
                    context,
                    index: i + 1,
                    icon: Icons.description_outlined,
                    label: f.name,
                    closable: true,
                    dirty: f.dirty,
                    onClose: () => _closeEditor(f),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _subChip(
    BuildContext context, {
    required int index,
    required IconData icon,
    required String label,
    required bool closable,
    bool dirty = false,
    VoidCallback? onClose,
  }) {
    final cs = Theme.of(context).colorScheme;
    final activeTab = tab.subTab == index;
    return InkWell(
      onTap: () => tab.activateSubTab(index),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: EdgeInsets.only(left: 12, right: closable ? 4 : 12),
        decoration: BoxDecoration(
          color: activeTab ? cs.surface : Colors.transparent,
          border: Border(
            bottom: BorderSide(
                color: activeTab ? cs.primary : Colors.transparent, width: 2),
            right: BorderSide(color: cs.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: activeTab ? cs.onSurface : cs.onSurfaceVariant),
            const SizedBox(width: 6),
            if (dirty)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(Icons.circle, size: 7, color: cs.primary),
              ),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: activeTab ? cs.onSurface : cs.onSurfaceVariant,
                      fontWeight:
                          activeTab ? FontWeight.w600 : FontWeight.normal)),
            ),
            if (closable) ...[
              const SizedBox(width: 2),
              InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 13, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _closeEditor(EditorFile f) async {
    if (f.dirty) {
      final ok = await confirm(context,
          title: '关闭未保存的文件',
          message: '“${f.name}”有未保存的修改，确定关闭吗？',
          danger: true,
          okText: '关闭');
      if (!ok) return;
    }
    tab.closeEditor(f);
  }

  Widget _statusBanner() {
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        if (tab.status == TabStatus.connecting) {
          return const LinearProgressIndicator(minHeight: 2);
        }
        if (tab.status == TabStatus.error ||
            tab.status == TabStatus.disconnected) {
          return Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.link_off, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tab.status == TabStatus.error
                          ? '连接失败：${tab.errorMessage ?? ''}'
                          : '连接已断开',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                      onPressed: tab.reconnect, child: const Text('重新连接')),
                ],
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _desktop(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomTabs = ['命令历史', '快速命令', '隧道', '传输'];
    final bottomViews = [
      HistoryList(
        onPick: (c) {
          tab.sendText(c);
          tab.focusTerminal();
        },
        onRun: (c) {
          tab.sendText('$c\r', recordHistory: true);
          tab.focusTerminal();
        },
      ),
      QuickCommandPanel(onSend: (c) => sendQuickCommand(tab, c)),
      ForwardPanel(tab: tab),
      TransferPanel(tab: tab),
    ];
    return LayoutBuilder(builder: (context, c) {
      final maxBottom = (c.maxHeight - 160).clamp(120.0, 2000.0);
      final bottomH = _bottomH.clamp(120.0, maxBottom);
      return Row(
        children: [
          if (_showLeft) ...[
            Container(
              width: _leftW,
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                border: Border(right: BorderSide(color: cs.outlineVariant)),
              ),
              child: ListenableBuilder(
                listenable: tab,
                builder: (context, _) => MonitorPanel(tab: tab),
              ),
            ),
            DragDivider(
              onDrag: (d) => setState(() => _leftW = (_leftW + d).clamp(180, 480)),
            ),
          ],
          Expanded(
            child: Column(
              children: [
                _statusBanner(),
                Expanded(child: TerminalPane(tab: tab)),
                CommandInputBar(tab: tab),
                if (_showBottom)
                  DragDivider(
                    vertical: false,
                    onDrag: (d) => setState(() => _bottomH = (_bottomH - d).clamp(120, maxBottom)),
                  ),
                Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    border: Border(top: BorderSide(color: cs.outlineVariant)),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: _showLeft ? '隐藏状态面板' : '显示状态面板',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(_showLeft ? Icons.chevron_left : Icons.chevron_right),
                        onPressed: () => setState(() => _showLeft = !_showLeft),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var i = 0; i < bottomTabs.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 2),
                                  child: TextButton(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: _showBottom &&
                                              _bottomIndex == i
                                          ? Theme.of(context)
                                              .colorScheme
                                              .secondaryContainer
                                          : null,
                                    ),
                                    onPressed: () => setState(() {
                                      if (_showBottom && _bottomIndex == i) {
                                        _showBottom = false;
                                      } else {
                                        _bottomIndex = i;
                                        _showBottom = true;
                                      }
                                    }),
                                    child: Text(bottomTabs[i],
                                        style: const TextStyle(fontSize: 12.5)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: _showBottom ? '收起面板' : '展开面板',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(_showBottom ? Icons.expand_more : Icons.expand_less),
                        onPressed: () => setState(() => _showBottom = !_showBottom),
                      ),
                      IconButton(
                        tooltip: _showRight ? '隐藏文件面板' : '显示文件面板',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                            _showRight ? Icons.chevron_right : Icons.chevron_left),
                        onPressed: () => setState(() => _showRight = !_showRight),
                      ),
                    ],
                  ),
                ),
                if (_showBottom)
                  Container(
                    height: bottomH,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      border: Border(top: BorderSide(color: cs.outlineVariant)),
                    ),
                    child: IndexedStack(index: _bottomIndex, children: bottomViews),
                  ),
              ],
            ),
          ),
          if (_showRight) ...[
            DragDivider(
              onDrag: (d) =>
                  setState(() => _rightW = (_rightW - d).clamp(240, 640)),
            ),
            Container(
              width: _rightW,
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                border: Border(left: BorderSide(color: cs.outlineVariant)),
              ),
              child: Column(
                children: [
                  Container(
                    height: 34,
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    decoration: BoxDecoration(
                      border:
                          Border(bottom: BorderSide(color: cs.outlineVariant)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.folder_outlined, size: 15),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text('文件',
                              style: TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          tooltip: '隐藏文件面板',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () => setState(() => _showRight = false),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: tab,
                      builder: (context, _) => SftpPanel(
                          key: ValueKey('sftp-${tab.id}-${tab.sftp.hashCode}'),
                          tab: tab),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    });
  }

  Widget _mobile(BuildContext context) {
    final pages = [
      TerminalPane(tab: tab, showKeyBar: true),
      ListenableBuilder(
        listenable: tab,
        builder: (context, _) => SftpPanel(
            key: ValueKey('sftp-${tab.id}-${tab.sftp.hashCode}'), tab: tab),
      ),
      ListenableBuilder(
        listenable: tab,
        builder: (context, _) => MonitorPanel(tab: tab),
      ),
      Column(
        children: [
          CommandInputBar(tab: tab),
          SizedBox(
            height: 160,
            child: QuickCommandPanel(onSend: (c) => sendQuickCommand(tab, c)),
          ),
          const Divider(),
          Expanded(
            child: HistoryList(
              onPick: (c) => tab.sendText(c),
              onRun: (c) => tab.sendText('$c\r', recordHistory: true),
            ),
          ),
        ],
      ),
      DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(tabs: [Tab(text: '隧道'), Tab(text: '传输')]),
            Expanded(
              child: TabBarView(
                children: [ForwardPanel(tab: tab), TransferPanel(tab: tab)],
              ),
            ),
          ],
        ),
      ),
    ];
    return Column(
      children: [
        _statusBanner(),
        Expanded(child: IndexedStack(index: _mobileIndex, children: pages)),
        NavigationBar(
          height: 60,
          selectedIndex: _mobileIndex,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => setState(() => _mobileIndex = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.terminal), label: '终端'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), label: '文件'),
            NavigationDestination(icon: Icon(Icons.monitor_heart_outlined), label: '监控'),
            NavigationDestination(icon: Icon(Icons.bolt), label: '命令'),
            NavigationDestination(icon: Icon(Icons.more_horiz), label: '更多'),
          ],
        ),
      ],
    );
  }
}
