import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/app_settings.dart';
import '../models/session_config.dart';
import '../services/app_store.dart';
import '../state/app_tab.dart';
import '../state/ssh_tab.dart';
import '../state/tabs_controller.dart';
import '../state/vnc_tab.dart';
import 'session_manager.dart';
import 'settings_page.dart';
import 'ssh_tab_view.dart';
import 'vnc_view.dart';
import 'widgets/common.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _mobileShowSessions = true;

  bool get _desktopPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  // macOS 下保留系统原生的红绿灯窗口按钮（位于左上角），
  // 因此不渲染自绘的窗口按钮，并给标题栏左侧留出红绿灯的空间。
  bool get _isMacDesktop => !kIsWeb && Platform.isMacOS;

  TabsController get tabs => context.read<TabsController>();

  void _connect(SessionConfig s) {
    tabs.open(s);
    setState(() => _mobileShowSessions = false);
  }

  Future<void> _closeTab(AppTab t) async {
    final store = context.read<AppStore>();
    if (store.settings.confirmOnCloseTab && t.status == TabStatus.connected) {
      final ok = await confirm(context,
          title: '关闭标签', message: '“${t.title}”仍处于连接状态，确定关闭吗？');
      if (!ok) return;
    }
    await tabs.close(t);
    if (tabs.tabs.isEmpty) setState(() => _mobileShowSessions = true);
  }

  void _openSettings({int tab = 0}) {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => SettingsPage(initialTab: tab)));
  }

  void _toggleTheme() {
    final store = context.read<AppStore>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    store.updateSettings(
        (s) => s.themeMode = dark ? AppThemeMode.light : AppThemeMode.dark);
  }

  Future<void> _tabMenu(AppTab t, Offset pos) async {
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'reconnect', child: Text('重新连接')),
        PopupMenuItem(value: 'dup', child: Text('复制标签')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'close', child: Text('关闭')),
        PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
        PopupMenuItem(value: 'all', child: Text('关闭全部标签')),
      ],
    );
    switch (r) {
      case 'reconnect':
        t.reconnect();
      case 'dup':
        tabs.duplicate(t);
      case 'close':
        _closeTab(t);
      case 'others':
        tabs.closeOthers(t);
      case 'all':
        await tabs.closeAll();
        setState(() => _mobileShowSessions = true);
    }
  }

  /// 桌面端把标题区包成可拖动窗口的区域（双击最大化/还原）。
  Widget _maybeDrag(Widget child) {
    if (!_desktopPlatform) return child;
    return DragToMoveArea(child: child);
  }

  Widget _tabView(AppTab t) {
    if (t is SshTab) return SshTabView(key: ValueKey(t.id), tab: t);
    if (t is VncTab) return VncTabView(key: ValueKey(t.id), tab: t);
    return const SizedBox();
  }

  @override
  Widget build(BuildContext context) {
    final tc = context.watch<TabsController>();
    return isWide(context) ? _desktop(tc) : _mobile(tc);
  }

  // ---------------- 桌面端 ----------------
  Widget _desktop(TabsController tc) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          Container(
            height: 46,
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(bottom: BorderSide(color: cs.outlineVariant)),
            ),
            child: Row(
              children: [
                _maybeDrag(Padding(
                  padding: EdgeInsets.only(
                      left: _isMacDesktop ? 78 : 12, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terminal_rounded, size: 18, color: cs.primary),
                      const SizedBox(width: 6),
                      Text('SSH Restart',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface)),
                      const SizedBox(width: 8),
                    ],
                  ),
                )),
                _TopBarButton(
                  icon: Icons.folder_open_outlined,
                  tooltip: '会话管理器',
                  onPressed: () => showSessionManagerDialog(context, _connect),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    itemCount: tc.tabs.length,
                    onReorder: tc.move,
                    itemBuilder: (context, i) {
                      final t = tc.tabs[i];
                      return ReorderableDragStartListener(
                        key: ValueKey(t.id),
                        index: i,
                        child: _DesktopTabChip(
                          tab: t,
                          active: i == tc.activeIndex,
                          onTap: () => tc.activate(i),
                          onClose: () => _closeTab(t),
                          onMenu: (pos) => _tabMenu(t, pos),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 6),
                _TopBarButton(
                  icon: Icons.add,
                  tooltip: '新建连接',
                  onPressed: () => showSessionManagerDialog(context, _connect),
                ),
                Container(
                  width: 1,
                  height: 20,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: cs.outlineVariant,
                ),
                _TopBarButton(
                  icon: Theme.of(context).brightness == Brightness.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  tooltip: '切换亮/暗主题',
                  onPressed: _toggleTheme,
                ),
                _TopBarButton(
                  icon: Icons.cloud_sync_outlined,
                  tooltip: '备份与同步',
                  onPressed: () => _openSettings(tab: 2),
                ),
                _TopBarButton(
                  icon: Icons.settings_outlined,
                  tooltip: '设置',
                  onPressed: _openSettings,
                ),
                if (_desktopPlatform && !_isMacDesktop) ...[
                  const SizedBox(width: 4),
                  const _WindowButtons(),
                ] else
                  const SizedBox(width: 8),
              ],
            ),
          ),
          Expanded(
            child: tc.tabs.isEmpty
                ? _welcome()
                : IndexedStack(
                    index: tc.activeIndex.clamp(0, tc.tabs.length - 1),
                    children: [for (final t in tc.tabs) _tabView(t)],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _welcome() {
    // 没有打开任何标签时，让会话管理视图占满整个工作区，
    // 不再保留右侧的空白占位格子。
    return SessionManagerView(onConnect: _connect);
  }

  // ---------------- 移动端 ----------------
  Widget _mobile(TabsController tc) {
    if (_mobileShowSessions || tc.tabs.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('SSH Restart'),
          actions: [
            IconButton(
              tooltip: '备份与同步',
              icon: const Icon(Icons.cloud_sync_outlined),
              onPressed: () => _openSettings(tab: 2),
            ),
            IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openSettings,
            ),
          ],
        ),
        body: SessionManagerView(onConnect: _connect),
        bottomNavigationBar: tc.tabs.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: FilledButton.icon(
                    onPressed: () => setState(() => _mobileShowSessions = false),
                    icon: const Icon(Icons.terminal),
                    label: Text('返回已打开的会话（${tc.tabs.length}）'),
                  ),
                ),
              ),
      );
    }
    final active = tc.active!;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _mobileShowSessions = true);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '会话列表',
            icon: const Icon(Icons.list),
            onPressed: () => setState(() => _mobileShowSessions = true),
          ),
          titleSpacing: 0,
          title: PopupMenuButton<int>(
            tooltip: '切换标签',
            onSelected: tc.activate,
            itemBuilder: (_) => [
              for (var i = 0; i < tc.tabs.length; i++)
                PopupMenuItem(
                  value: i,
                  child: Row(
                    children: [
                      _StatusDot(tab: tc.tabs[i]),
                      const SizedBox(width: 8),
                      Expanded(child: Text(tc.tabs[i].title)),
                    ],
                  ),
                ),
            ],
            child: ListenableBuilder(
              listenable: active,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusDot(tab: active),
                  const SizedBox(width: 8),
                  Flexible(child: Text(active.title, overflow: TextOverflow.ellipsis)),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: '重新连接',
              icon: const Icon(Icons.refresh),
              onPressed: active.reconnect,
            ),
            IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close),
              onPressed: () => _closeTab(active),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: IndexedStack(
            index: tc.activeIndex.clamp(0, tc.tabs.length - 1),
            children: [for (final t in tc.tabs) _tabView(t)],
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.tab});
  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) => Icon(
        Icons.circle,
        size: 9,
        color: switch (tab.status) {
          TabStatus.connected => Colors.green,
          TabStatus.connecting => Colors.orange,
          _ => Colors.red,
        },
      ),
    );
  }
}

class _DesktopTabChip extends StatelessWidget {
  const _DesktopTabChip({
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
  });

  final AppTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(Offset) onMenu;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      onTertiaryTapUp: (_) => onClose(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(3, 7, 0, 7),
        child: Material(
          color: active ? cs.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: active ? cs.outlineVariant : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusDot(tab: tab),
                  const SizedBox(width: 6),
                  Icon(
                      tab is VncTab
                          ? Icons.desktop_windows_outlined
                          : Icons.terminal,
                      size: 14,
                      color: active ? cs.onSurface : cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(tab.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            color:
                                active ? cs.onSurface : cs.onSurfaceVariant,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.normal)),
                  ),
                  const SizedBox(width: 2),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.close,
                          size: 13, color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘标题栏的窗口控制按钮：最小化 / 最大化还原 / 关闭。
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, VoidCallback onTap,
        {bool danger = false}) {
      return Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: danger
              ? const Color(0xFFE5484D).withValues(alpha: 0.9)
              : cs.onSurface.withValues(alpha: 0.08),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 17, color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.remove, '最小化', () => windowManager.minimize()),
        btn(
          _maximized ? Icons.filter_none : Icons.crop_square,
          _maximized ? '还原' : '最大化',
          () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        btn(Icons.close, '关闭', () => windowManager.close(), danger: true),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// 顶部工具条上的统一图标按钮：悬停高亮、圆角、紧凑。
class _TopBarButton extends StatelessWidget {
  const _TopBarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 19, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}
