import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// 系统托盘：首次最小化到托盘时才创建图标，退出前移除。
class AppTray with TrayListener {
  AppTray._();

  static final instance = AppTray._();

  /// 托盘菜单中的“退出”。
  Future<void> Function()? onQuit;

  bool _ready = false;

  Future<void> _ensure() async {
    if (_ready) return;
    _ready = true;
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/tray_icon.ico'
          : 'assets/tray/tray_icon.png',
    );
    if (!Platform.isLinux) await trayManager.setToolTip('SSH Restart');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示主窗口'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出'),
        ],
      ),
    );
  }

  Future<void> hideToTray() async {
    await _ensure();
    await windowManager.hide();
  }

  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> dispose() async {
    if (!_ready) return;
    _ready = false;
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  @override
  void onTrayIconMouseDown() {
    // macOS 菜单栏图标习惯单击弹出菜单。
    if (Platform.isMacOS) {
      trayManager.popUpContextMenu();
    } else {
      showWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'quit':
        onQuit?.call();
    }
  }
}
