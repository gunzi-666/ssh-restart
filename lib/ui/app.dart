import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../services/app_store.dart';
import '../services/ssh/ssh_connector.dart';
import 'app_style.dart';
import 'home_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class SshRestartApp extends StatefulWidget {
  const SshRestartApp({super.key});

  @override
  State<SshRestartApp> createState() => _SshRestartAppState();
}

class _SshRestartAppState extends State<SshRestartApp> {
  @override
  void initState() {
    super.initState();
    SSHConnector.hostKeyPrompt = _hostKeyPrompt;
    SSHConnector.interactivePrompt = _interactivePrompt;
  }

  Future<bool> _hostKeyPrompt(
      String host, String type, String fp, String? known) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return true;
    final changed = known != null;
    final r = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        icon: Icon(changed ? Icons.warning_amber : Icons.vpn_key,
            color: changed ? Colors.red : null),
        title: Text(changed ? '主机指纹已变化！' : '首次连接该主机'),
        content: SizedBox(
          width: 480,
          child: SelectableText(
            changed
                ? '主机 $host 的指纹与之前记录的不一致，可能存在中间人攻击，也可能是服务器重装过系统。\n\n'
                    '之前记录：$known\n当前指纹：$fp\n类型：$type\n\n确定继续连接并更新记录吗？'
                : '主机：$host\n类型：$type\n指纹：$fp\n\n是否信任该主机并继续连接？',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            style: changed
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(changed ? '仍然连接' : '信任并连接'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<List<String>?> _interactivePrompt(
      String title, List<String> prompts) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return null;
    final ctrls = prompts.map((_) => TextEditingController()).toList();
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < prompts.length; i++)
                TextField(
                  controller: ctrls[i],
                  autofocus: i == 0,
                  obscureText: prompts[i].toLowerCase().contains('password') ||
                      prompts[i].contains('密码'),
                  decoration: InputDecoration(labelText: prompts[i].trim()),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return null;
    return ctrls.map((c) => c.text).toList();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.select<AppStore, (AppThemeMode, int, String)>(
        (s) => (s.settings.themeMode, s.settings.accentColor, s.settings.uiStyle));
    final mode = switch (settings.$1) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
      AppThemeMode.system => ThemeMode.system,
    };
    final accent = Color(settings.$2);
    final style = UiStyle.parse(settings.$3);
    return MaterialApp(
      title: 'SSH Restart',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light, accent, style),
      darkTheme: buildAppTheme(Brightness.dark, accent, style),
      themeMode: mode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomePage(),
    );
  }
}
