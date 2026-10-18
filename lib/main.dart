import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_store.dart';
import 'services/backup_manager.dart';
import 'state/tabs_controller.dart';
import 'ui/app.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端：Windows/Linux 隐藏系统标题栏改用自绘标题栏；
  // macOS 保留系统原生标题栏（红绿灯），应用工具栏位于其下方。
  if (_isDesktop) {
    await windowManager.ensureInitialized();
    final options = WindowOptions(
      size: const Size(1280, 820),
      minimumSize: const Size(900, 560),
      center: true,
      backgroundColor: Colors.transparent,
      title: 'SSH Restart',
      titleBarStyle:
          Platform.isMacOS ? TitleBarStyle.normal : TitleBarStyle.hidden,
    );
    unawaited(windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    }));
  }
  final store = AppStore();
  await store.load();
  final backup = BackupManager(store)..start();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: backup),
        ChangeNotifierProvider(create: (_) => TabsController(store)),
      ],
      child: const SshRestartApp(),
    ),
  );
}
