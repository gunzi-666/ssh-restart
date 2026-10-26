import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_store.dart';
import 'services/backup_manager.dart';
import 'services/updater.dart';
import 'services/window_state.dart';
import 'state/tabs_controller.dart';
import 'ui/app.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main(List<String> args) async {
  if (await Updater.runApplyIfRequested(args)) return;
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(Updater.cleanupLeftovers());
  final store = AppStore();
  await store.load();
  // 桌面端：Windows/Linux 隐藏系统标题栏改用自绘标题栏；
  // macOS 保留系统原生标题栏（红绿灯），应用工具栏位于其下方。
  if (_isDesktop) {
    await windowManager.ensureInitialized();
    final saved = await WindowStateKeeper.savedBounds(store);
    final options = WindowOptions(
      size: saved?.size ?? const Size(1280, 820),
      minimumSize: WindowStateKeeper.minSize,
      center: saved == null,
      backgroundColor: Colors.transparent,
      title: 'SSH Restart',
      titleBarStyle: Platform.isMacOS
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
    );
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        if (saved != null) await windowManager.setBounds(saved);
        if (store.settings.windowMaximized) await windowManager.maximize();
        await windowManager.show();
        await windowManager.focus();
        WindowStateKeeper(
        store,
        restoreBounds: store.settings.windowMaximized ? saved : null,
      ).start();
      }),
    );
  }
  final backup = BackupManager(store);
  unawaited(store.whenUnlocked.then((_) => backup.start()));
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
