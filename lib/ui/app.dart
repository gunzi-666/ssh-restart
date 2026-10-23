import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../services/app_store.dart';
import '../services/ssh/ssh_connector.dart';
import 'app_style.dart';
import 'home_page.dart';
import 'unlock_page.dart';
import 'widgets/shad.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class _LockGate extends StatelessWidget {
  const _LockGate();

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AppStore, bool>((s) => s.locked);
    return locked ? const UnlockPage() : const HomePage();
  }
}

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
    String host,
    String type,
    String fp,
    String? known,
  ) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return true;
    final changed = known != null;
    final r = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AppDialog(
        title: changed ? '主机指纹已变化' : '首次连接该主机',
        description: changed
            ? '主机指纹与之前记录的不一致，可能存在中间人攻击，也可能是服务器重装过系统。确认无误后再继续。'
            : '请核对指纹后确认是否信任。信任后会记住该指纹，下次不再询问。',
        width: 520,
        actions: [
          AppButton(label: '取消', onPressed: () => Navigator.pop(c, false)),
          AppButton(
            label: changed ? '仍然连接' : '信任并连接',
            primary: !changed,
            danger: changed,
            onPressed: () => Navigator.pop(c, true),
          ),
        ],
        child: SelectableText(
          changed
              ? '主机：$host\n类型：$type\n之前记录：$known\n当前指纹：$fp'
              : '主机：$host\n类型：$type\n指纹：$fp',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: ['Consolas', 'Menlo', 'Cascadia Mono'],
            fontSize: 12.5,
            height: 1.6,
          ),
        ),
      ),
    );
    return r ?? false;
  }

  Future<List<String>?> _interactivePrompt(
    String title,
    List<String> prompts,
  ) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return null;
    final ctrls = prompts.map((_) => TextEditingController()).toList();
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AppDialog(
        title: title,
        width: 420,
        actions: [
          AppButton(label: '取消', onPressed: () => Navigator.pop(c, false)),
          AppButton(
            label: '确定',
            primary: true,
            onPressed: () => Navigator.pop(c, true),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < prompts.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                child: LabeledField(
                  label: prompts[i].trim(),
                  child: TextField(
                    controller: ctrls[i],
                    autofocus: i == 0,
                    obscureText:
                        prompts[i].toLowerCase().contains('password') ||
                        prompts[i].contains('密码'),
                    onSubmitted: (_) => Navigator.pop(c, true),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (ok != true) return null;
    return ctrls.map((c) => c.text).toList();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.select<AppStore, (AppThemeMode, int, String)>(
      (s) => (s.settings.themeMode, s.settings.accentColor, s.settings.uiStyle),
    );
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
      home: const _LockGate(),
    );
  }
}
