import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../services/app_store.dart';
import '../services/ssh/ssh_connector.dart';
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

  ThemeData _theme(Brightness b, Color seed) {
    final dark = b == Brightness.dark;
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    // macOS 风格配色：柔和的窗口底、略浅的侧边栏、带细边框的白/深灰卡片。
    if (dark) {
      scheme = scheme.copyWith(
        surface: const Color(0xFF1E1E22),
        surfaceContainerLowest: const Color(0xFF191A1D),
        surfaceContainerLow: const Color(0xFF242428),
        surfaceContainer: const Color(0xFF2A2A2F),
        surfaceContainerHigh: const Color(0xFF313137),
        surfaceContainerHighest: const Color(0xFF3A3A41),
        outlineVariant: const Color(0xFF3A3A41),
      );
    } else {
      scheme = scheme.copyWith(
        surface: const Color(0xFFFFFFFF),
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF2F3F5),
        surfaceContainer: const Color(0xFFFFFFFF),
        surfaceContainerHigh: const Color(0xFFEDEEF1),
        surfaceContainerHighest: const Color(0xFFE4E6EA),
      );
    }
    final radius = BorderRadius.circular(10);
    final border = dark ? scheme.outlineVariant : const Color(0xFFD9DCE1);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(outlineVariant: border),
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.compact,
      fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC'],
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: dark ? scheme.surfaceContainerHigh : Colors.white,
        border: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
        side: BorderSide(color: border),
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primary,
        showCheckmark: false,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        elevation: 0,
        height: 64,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        useIndicator: true,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? const Color(0xFF34C759) : null),
        trackOutlineColor:
            const WidgetStatePropertyAll(Colors.transparent),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(8),
        thumbColor: WidgetStatePropertyAll(
            scheme.onSurface.withValues(alpha: dark ? 0.22 : 0.26)),
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.select<AppStore, (AppThemeMode, int)>(
        (s) => (s.settings.themeMode, s.settings.accentColor));
    final mode = switch (settings.$1) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
      AppThemeMode.system => ThemeMode.system,
    };
    final seed = Color(settings.$2);
    return MaterialApp(
      title: 'SSH Restart',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light, seed),
      darkTheme: _theme(Brightness.dark, seed),
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
