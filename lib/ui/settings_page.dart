import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../models/session_config.dart';
import '../services/app_store.dart';
import '../services/backup_crypto.dart';
import '../services/backup_manager.dart';
import '../services/finalshell_import.dart';
import '../services/gdrive_service.dart';
import 'app_style.dart';
import 'terminal_themes.dart';
import 'widgets/common.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('设置'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '常规'),
              Tab(text: '终端'),
              Tab(text: '备份与同步'),
              Tab(text: '关于'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _GeneralSettings(),
            _TerminalSettings(),
            BackupSettings(),
            _About(),
          ],
        ),
      ),
    );
  }
}

/// 设置页内容的统一滚动容器：限制最大宽度并水平居中，
/// 让宽窗口下的设置项不至于横向铺满、显得空旷。
class _SettingsScroll extends StatelessWidget {
  const _SettingsScroll({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: children,
        ),
      ),
    );
  }
}

/// 界面风格卡片：用该风格的真实主题渲染一个缩略预览。
class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.style,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final UiStyle style;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final preview = buildAppTheme(cs.brightness, accent, style);
    return SizedBox(
      width: 208,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Theme(
                  data: preview,
                  child: const _StylePreview(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(style.label,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                      ),
                      if (selected)
                        Icon(Icons.check_circle_rounded,
                            size: 16, color: cs.primary),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: Text(style.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.4,
                          color: cs.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StylePreview extends StatelessWidget {
  const _StylePreview();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    Widget bar(double w, Color c) => Container(
          width: w,
          height: 6,
          decoration: BoxDecoration(
              color: c, borderRadius: BorderRadius.circular(3)),
        );
    final r = BorderRadius.circular(st.controlRadius * 0.6);
    return Container(
      height: 92,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Container(
            width: 44,
            color: cs.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(7, 10, 7, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.2),
                    borderRadius: r,
                  ),
                ),
                const SizedBox(height: 6),
                bar(24, cs.onSurfaceVariant.withValues(alpha: 0.4)),
                const SizedBox(height: 6),
                bar(28, cs.onSurfaceVariant.withValues(alpha: 0.4)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      bar(46, cs.onSurface.withValues(alpha: 0.7)),
                      const Spacer(),
                      Container(
                        width: 32,
                        height: 14,
                        decoration: BoxDecoration(
                            color: cs.primary, borderRadius: r),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius:
                            BorderRadius.circular(st.cardRadius * 0.5),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      padding: const EdgeInsets.all(7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 14,
                            decoration: BoxDecoration(
                              color: st.inputFill,
                              borderRadius: r,
                              border: Border.all(color: cs.outlineVariant),
                            ),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              bar(30, cs.onSurfaceVariant.withValues(alpha: 0.45)),
                              const Spacer(),
                              Container(
                                width: 22,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: st.secondaryFill,
                                  borderRadius: r,
                                  border: Border.all(color: cs.outlineVariant),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GeneralSettings extends StatelessWidget {
  const _GeneralSettings();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final s = store.settings;
    const colors = [
      0xFF1E88E5, 0xFF00897B, 0xFF43A047, 0xFFF4511E,
      0xFF8E24AA, 0xFFE53935, 0xFF6D4C41, 0xFF546E7A,
    ];
    return _SettingsScroll(
      children: [
        const SectionTitle('外观'),
        ListTile(
          title: const Text('界面风格'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final st in UiStyle.values)
                  _StyleCard(
                    style: st,
                    accent: Color(s.accentColor),
                    selected: UiStyle.parse(s.uiStyle) == st,
                    onTap: () => store.updateSettings((x) => x.uiStyle = st.id),
                  ),
              ],
            ),
          ),
        ),
        ListTile(
          title: const Text('明暗模式'),
          trailing: SegmentedButton<AppThemeMode>(
            segments: const [
              ButtonSegment(value: AppThemeMode.system, label: Text('跟随系统')),
              ButtonSegment(value: AppThemeMode.light, label: Text('亮色')),
              ButtonSegment(value: AppThemeMode.dark, label: Text('暗色')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => store.updateSettings((x) => x.themeMode = v.first),
          ),
        ),
        ListTile(
          title: const Text('主题色'),
          subtitle: Wrap(
            spacing: 8,
            children: [
              for (final c in colors)
                InkWell(
                  onTap: () => store.updateSettings((x) => x.accentColor = c),
                  child: CircleAvatar(
                    radius: 13,
                    backgroundColor: Color(c),
                    child: s.accentColor == c
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
        ),
        const SectionTitle('行为'),
        SwitchListTile(
          title: const Text('关闭已连接的标签前确认'),
          value: s.confirmOnCloseTab,
          onChanged: (v) => store.updateSettings((x) => x.confirmOnCloseTab = v),
        ),
        ListTile(
          title: const Text('状态监控刷新间隔'),
          trailing: AppSelect<int>(
            value: s.monitorIntervalSeconds,
            options: [
              for (final v in [1, 2, 3, 5, 10, 30]) (value: v, label: '$v 秒'),
            ],
            onChanged: (v) =>
                store.updateSettings((x) => x.monitorIntervalSeconds = v),
          ),
        ),
        const SectionTitle('文件管理'),
        SwitchListTile(
          title: const Text('默认跟随终端目录'),
          subtitle: const Text('终端 cd 后，文件列表自动切换到相同目录'),
          value: s.sftpFollowTerminal,
          onChanged: (v) => store.updateSettings((x) => x.sftpFollowTerminal = v),
        ),
        SwitchListTile(
          title: const Text('默认显示隐藏文件'),
          value: s.sftpShowHidden,
          onChanged: (v) => store.updateSettings((x) => x.sftpShowHidden = v),
        ),
        ListTile(
          title: const Text('下载保存目录'),
          subtitle: Text(s.downloadDir.isEmpty
              ? (Platform.isAndroid || Platform.isIOS
                  ? '默认：应用下载目录/SSH-Restart'
                  : '每次下载时选择')
              : s.downloadDir),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.downloadDir.isNotEmpty)
                TextButton(
                  onPressed: () => store.updateSettings((x) => x.downloadDir = ''),
                  child: const Text('恢复默认'),
                ),
              FilledButton.tonal(
                onPressed: () async {
                  final d = await FilePicker.getDirectoryPath(dialogTitle: '选择下载目录');
                  if (d != null) store.updateSettings((x) => x.downloadDir = d);
                },
                child: const Text('选择'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TerminalSettings extends StatelessWidget {
  const _TerminalSettings();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final s = store.settings;
    final theme = terminalThemeByName(s.terminalTheme);
    return _SettingsScroll(
      children: [
        const SectionTitle('字体'),
        ListTile(
          title: const Text('字体名称'),
          subtitle: Text(s.terminalFontFamily.isEmpty ? '系统默认等宽字体' : s.terminalFontFamily),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () async {
            final v = await promptText(context,
                title: '终端字体',
                initial: s.terminalFontFamily,
                hint: '例如 Consolas、JetBrains Mono，留空使用默认');
            if (v != null) store.updateSettings((x) => x.terminalFontFamily = v.trim());
          },
        ),
        ListTile(
          title: Text('字号：${s.terminalFontSize.toStringAsFixed(0)}'),
          subtitle: Slider(
            min: 8,
            max: 32,
            divisions: 24,
            value: s.terminalFontSize.clamp(8, 32),
            onChanged: (v) => store.updateSettings((x) => x.terminalFontSize = v),
          ),
        ),
        const SectionTitle('配色'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in terminalThemes.entries)
                ChoiceChip(
                  label: Text(e.key),
                  selected: s.terminalTheme == e.key,
                  onSelected: (_) => store.updateSettings((x) => x.terminalTheme = e.key),
                ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.background,
            borderRadius: BorderRadius.circular(6),
          ),
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Consolas', 'Menlo'],
                  fontSize: s.terminalFontSize,
                  color: theme.foreground),
              children: [
                TextSpan(text: 'root@server', style: TextStyle(color: theme.green)),
                const TextSpan(text: ':'),
                TextSpan(text: '~/www', style: TextStyle(color: theme.blue)),
                const TextSpan(text: '# ls -l\n'),
                TextSpan(text: 'drwxr-xr-x ', style: TextStyle(color: theme.foreground)),
                TextSpan(text: 'nginx  ', style: TextStyle(color: theme.cyan)),
                TextSpan(text: 'error.log  ', style: TextStyle(color: theme.red)),
                TextSpan(text: 'run.sh', style: TextStyle(color: theme.yellow)),
              ],
            ),
          ),
        ),
        const SectionTitle('行为'),
        ListTile(
          title: const Text('光标样式'),
          trailing: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'block', label: Text('方块')),
              ButtonSegment(value: 'underline', label: Text('下划线')),
              ButtonSegment(value: 'bar', label: Text('竖线')),
            ],
            selected: {s.cursorStyle},
            onSelectionChanged: (v) => store.updateSettings((x) => x.cursorStyle = v.first),
          ),
        ),
        ListTile(
          title: const Text('回滚行数'),
          subtitle: const Text('对新打开的标签生效'),
          trailing: AppSelect<int>(
            value: s.scrollback,
            options: [
              for (final v in [1000, 3000, 5000, 10000, 20000, 50000])
                (value: v, label: '$v'),
            ],
            onChanged: (v) => store.updateSettings((x) => x.scrollback = v),
          ),
        ),
        SwitchListTile(
          title: const Text('选中即复制'),
          value: s.copyOnSelect,
          onChanged: (v) => store.updateSettings((x) => x.copyOnSelect = v),
        ),
        SwitchListTile(
          title: const Text('右键直接粘贴'),
          subtitle: const Text('关闭后右键弹出菜单；有选中内容时始终弹出菜单'),
          value: s.rightClickPaste,
          onChanged: (v) => store.updateSettings((x) => x.rightClickPaste = v),
        ),
        SwitchListTile(
          title: const Text('连接后自动启用彩色输出'),
          subtitle: const Text('为 ls、grep 等命令设置彩色别名，解决部分服务器命令输出无颜色的问题'),
          value: s.terminalColorHelper,
          onChanged: (v) => store.updateSettings((x) => x.terminalColorHelper = v),
        ),
      ],
    );
  }
}

/// 备份与同步：加密密钥、本地导入导出、谷歌云盘上传与导入。
class BackupSettings extends StatefulWidget {
  const BackupSettings({super.key});

  @override
  State<BackupSettings> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends State<BackupSettings> {
  late final AppStore store = context.read<AppStore>();
  late final _key = TextEditingController(text: store.settings.backupKey);
  late final _clientId = TextEditingController(text: store.settings.gdriveClientId);
  late final _clientSecret = TextEditingController(text: store.settings.gdriveClientSecret);
  bool _showKey = false;
  bool _working = false;

  BackupManager get bm => context.read<BackupManager>();

  void _saveKey() {
    store.updateSettings((s) => s.backupKey = _key.text);
    showToast(context, '加密密钥已保存');
  }

  Future<String?> _ensureKey() async {
    if (_key.text.isNotEmpty) {
      if (store.settings.backupKey != _key.text) _saveKey();
      return _key.text;
    }
    showToast(context, '请先设置加密密钥');
    return null;
  }

  Future<void> _busy(Future<void> Function() fn) async {
    setState(() => _working = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
    if (mounted) setState(() => _working = false);
  }

  Future<void> _exportLocal() async {
    final key = await _ensureKey();
    if (key == null) return;
    await _busy(() async {
      final text = await bm.exportEncrypted(key);
      final bytes = bm.encodeFile(text);
      final path = await FilePicker.saveFile(
        dialogTitle: '保存加密备份',
        fileName: bm.fileName(),
        bytes: bytes,
      );
      if (path == null) return;
      if (!(Platform.isAndroid || Platform.isIOS)) {
        final f = File(path);
        if (!f.existsSync() || f.lengthSync() == 0) await f.writeAsBytes(bytes);
      }
      if (mounted) showToast(context, '已导出：$path');
    });
  }

  Future<bool?> _askReplace() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入方式'),
          content: const Text('合并：保留本机数据，按更新时间合并同一会话。\n覆盖：用备份完全替换本机的会话、分组和快捷命令。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('覆盖')),
            FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('合并')),
          ],
        ),
      );

  Future<void> _importLocal() async {
    final r = await FilePicker.pickFiles(dialogTitle: '选择备份文件', withData: true);
    final f = r?.files.firstOrNull;
    if (f == null) return;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!BackupCrypto.looksLikeBackup(text)) {
      if (mounted) showToast(context, '所选文件不是本软件的备份文件');
      return;
    }
    if (!mounted) return;
    var key = _key.text;
    if (key.isEmpty) {
      key = await promptText(context, title: '输入备份的加密密钥', obscure: true) ?? '';
      if (key.isEmpty) return;
    }
    final replace = await _askReplace();
    if (replace == null) return;
    await _busy(() async {
      final res = await bm.importEncrypted(text, key: key, replace: replace);
      if (mounted) showToast(context, '导入成功：$res');
    });
  }

  Future<void> _importFinalShell() async {
    final detected = FinalShellImporter.detectDefaultDir();
    final src = await showDialog<String>(
      context: context,
      builder: (ctx) => AppDialog(
        title: '从 FinalShell 导入',
        description: '选择 FinalShell 的数据目录（包含 conn 文件夹）、conn 文件夹本身，'
            '或包含连接配置的 zip / json 文件。',
        width: 480,
        actions: [AppButton(label: '取消', onPressed: () => Navigator.pop(ctx))],
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(ctx).colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (detected != null)
                AppMenuItem(
                  height: 40,
                  icon: Icons.auto_awesome_outlined,
                  label: '使用检测到的目录：$detected',
                  onTap: () => Navigator.pop(ctx, 'auto'),
                ),
              AppMenuItem(
                height: 40,
                icon: Icons.folder_open_outlined,
                label: '选择文件夹…',
                onTap: () => Navigator.pop(ctx, 'dir'),
              ),
              AppMenuItem(
                height: 40,
                icon: Icons.insert_drive_file_outlined,
                label: '选择文件（.zip / .json，可多选）…',
                onTap: () => Navigator.pop(ctx, 'file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (src == null) return;

    FinalShellImportResult? res;
    await _busy(() async {
      switch (src) {
        case 'auto':
          res = await FinalShellImporter.fromDirectory(detected!);
        case 'dir':
          final p = await FilePicker.getDirectoryPath(
              dialogTitle: '选择 FinalShell 目录或 conn 文件夹');
          if (p == null) return;
          res = await FinalShellImporter.fromDirectory(p);
        case 'file':
          final r = await FilePicker.pickFiles(
            dialogTitle: '选择 FinalShell 配置文件',
            allowMultiple: true,
            withData: true,
            type: FileType.custom,
            allowedExtensions: const ['zip', 'json'],
          );
          if (r == null) return;
          final files = <String, Uint8List>{};
          for (final f in r.files) {
            final bytes = f.bytes ??
                (f.path != null ? await File(f.path!).readAsBytes() : null);
            if (bytes != null) files[f.name] = bytes;
          }
          res = FinalShellImporter.fromFiles(files);
      }
    });
    final result = res;
    if (result == null || !mounted) return;
    if (result.sessions.isEmpty) {
      showToast(context, result.skippedOther > 0
          ? '只找到 ${result.skippedOther} 个非 SSH 连接，已跳过'
          : '没有找到 FinalShell 连接配置，请确认选择的是 conn 目录或其上级目录');
      return;
    }

    String keyOf(SessionConfig s) => '${s.host}:${s.port}:${s.username}';
    final existing = {for (final s in store.sessions) keyOf(s)};
    final fresh =
        result.sessions.where((s) => !existing.contains(keyOf(s))).toList();
    final dup = result.sessions.length - fresh.length;

    final byId = {for (final g in result.groups) g.id: g};
    final used = <String>{};
    for (final s in fresh) {
      var id = s.groupId;
      while (id != null && used.add(id)) {
        id = byId[id]?.parentId;
      }
    }
    final groups = result.groups.where((g) => used.contains(g.id)).toList();

    final cs = Theme.of(context).colorScheme;
    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(
                  child: Text(label,
                      style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant))),
              Text(value,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: color ?? cs.onSurface)),
            ],
          ),
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: '确认导入',
        description: '以合并方式导入，不会修改或删除本机已有的服务器。',
        width: 440,
        actions: [
          AppButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
          AppButton(
            label: fresh.isEmpty ? '无可导入项' : '导入 ${fresh.length} 台服务器',
            primary: true,
            onPressed: fresh.isEmpty ? null : () => Navigator.pop(ctx, true),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row('识别到的 SSH 服务器', '${result.sessions.length} 台'),
              row('将导入', '${fresh.length} 台', color: cs.primary),
              if (dup > 0) row('本机已存在（跳过）', '$dup 台'),
              row('分组', '${groups.length} 个'),
              row('密码解密成功', '${result.passwordOk} 个'),
              if (result.passwordFailed > 0)
                row('密码解密失败（需手动填写）', '${result.passwordFailed} 个',
                    color: cs.error),
              if (result.keyMatched > 0) row('私钥', '${result.keyMatched} 个'),
              if (result.keyMissing > 0)
                row('未找到私钥（需手动导入）', '${result.keyMissing} 个',
                    color: cs.error),
              if (result.skippedOther > 0)
                row('非 SSH 连接（跳过）', '${result.skippedOther} 个'),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    store.mergeBackup(sessions: fresh, groups: groups, quickCommands: const []);
    if (mounted) showToast(context, '已从 FinalShell 导入 ${fresh.length} 台服务器');
  }

  Future<void> _authorize() async {
    store.updateSettings((s) {
      s.gdriveClientId = _clientId.text.trim();
      s.gdriveClientSecret = _clientSecret.text.trim();
    });
    if (_clientId.text.trim().isEmpty) {
      showToast(context, '请先填写 OAuth 客户端 ID');
      return;
    }
    await _busy(() async {
      showToast(context, '已在浏览器中打开谷歌授权页面，请完成授权');
      final hint = await bm.drive.authorize();
      if (mounted) showToast(context, '授权成功：$hint');
    });
  }

  Future<void> _upload() async {
    if (await _ensureKey() == null) return;
    await _busy(() async {
      final ok = await bm.uploadToDrive();
      if (mounted) showToast(context, ok ? '上传成功' : bm.status);
    });
  }

  Future<void> _browseRemote() async {
    if (await _ensureKey() == null) return;
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => _RemoteBackupsDialog(manager: bm, askReplace: _askReplace),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final bm = context.watch<BackupManager>();
    final s = store.settings;
    final authorized = bm.drive.authorized;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: AbsorbPointer(
          absorbing: _working || bm.busy,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
          if (_working || bm.busy) const LinearProgressIndicator(minHeight: 2),
          const SectionTitle('加密密钥'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '所有备份（包括会话密码和私钥）都会先用此密钥以 AES-256-GCM 加密后再保存或上传。'
                  '其他设备安装本软件后设置相同的密钥，即可解密导入。密钥丢失后备份无法恢复，请妥善保管。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _key,
                        obscureText: !_showKey,
                        decoration: InputDecoration(
                          labelText: '加密密钥',
                          suffixIcon: IconButton(
                            icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _showKey = !_showKey),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _saveKey, child: const Text('保存')),
                  ],
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('在本机记住加密密钥'),
            subtitle: const Text('关闭后重启软件需要重新输入，定时上传和自动导入将无法在重启后自动进行'),
            value: s.rememberBackupKey,
            onChanged: (v) => store.updateSettings((x) => x.rememberBackupKey = v),
          ),
          const SectionTitle('本地备份文件'),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('导出加密备份文件'),
            subtitle: const Text('保存到本地，可通过任意方式传到其他设备'),
            onTap: _exportLocal,
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('导入备份文件'),
            subtitle: const Text('选择备份文件并用加密密钥解密导入'),
            onTap: _importLocal,
          ),
          const SectionTitle('从其他软件导入'),
          ListTile(
            leading: const Icon(Icons.move_down_rounded),
            title: const Text('从 FinalShell 导入'),
            subtitle: const Text('读取 FinalShell 的连接配置（目录、zip 或 json），自动解密密码并还原分组'),
            onTap: _importFinalShell,
          ),
          const SectionTitle('谷歌云盘'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '本软件不需要注册账号。请在 Google Cloud Console 中启用 Google Drive API，'
                  '创建类型为“桌面应用”的 OAuth 客户端，把客户端 ID 和密钥填到下面，然后授权一次即可。'
                  '所有设备填写同一个客户端 ID 并授权同一个谷歌账号，就能看到彼此上传的备份。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _clientId,
                  decoration: const InputDecoration(labelText: 'OAuth 客户端 ID'),
                  onChanged: (v) => store.updateSettings((x) => x.gdriveClientId = v.trim()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _clientSecret,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'OAuth 客户端密钥'),
                  onChanged: (v) => store.updateSettings((x) => x.gdriveClientSecret = v.trim()),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(authorized ? Icons.check_circle : Icons.cancel,
                        size: 18, color: authorized ? Colors.green : Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(authorized
                          ? '已授权：${s.gdriveAccountHint}'
                          : '未授权'),
                    ),
                    if (authorized)
                      TextButton(
                          onPressed: () => bm.drive.signOut(), child: const Text('取消授权')),
                    FilledButton.tonal(
                      onPressed: _authorize,
                      child: Text(authorized ? '重新授权' : '授权'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            enabled: authorized,
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('立即上传备份'),
            subtitle: Text(s.lastUploadAt == 0
                ? '尚未上传过'
                : '上次上传：${formatDateTime(DateTime.fromMillisecondsSinceEpoch(s.lastUploadAt))}'),
            onTap: _upload,
          ),
          ListTile(
            enabled: authorized,
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('从云盘导入备份'),
            subtitle: const Text('查看云盘上的备份列表，选择一份导入'),
            onTap: _browseRemote,
          ),
          SwitchListTile(
            title: const Text('定时上传'),
            subtitle: Text('每隔 ${s.gdriveAutoUploadHours} 小时自动上传一次（软件运行期间）'),
            value: s.gdriveAutoUpload,
            onChanged: authorized
                ? (v) => store.updateSettings((x) => x.gdriveAutoUpload = v)
                : null,
          ),
          if (s.gdriveAutoUpload)
            ListTile(
              title: const Text('上传间隔'),
              trailing: AppSelect<int>(
                value: s.gdriveAutoUploadHours,
                options: [
                  for (final h in [1, 3, 6, 12, 24, 72, 168])
                    (value: h, label: h < 24 ? '$h 小时' : '${h ~/ 24} 天'),
                ],
                onChanged: (v) =>
                    store.updateSettings((x) => x.gdriveAutoUploadHours = v),
              ),
            ),
          SwitchListTile(
            title: const Text('数据变化后自动上传'),
            subtitle: const Text('新增、修改或删除会话后 30 秒自动上传'),
            value: s.gdriveUploadOnChange,
            onChanged: authorized
                ? (v) => store.updateSettings((x) => x.gdriveUploadOnChange = v)
                : null,
          ),
          SwitchListTile(
            title: const Text('启动时自动导入'),
            subtitle: const Text('云盘上有更新的备份时，以合并方式自动导入'),
            value: s.gdriveAutoImport,
            onChanged: authorized
                ? (v) => store.updateSettings((x) => x.gdriveAutoImport = v)
                : null,
          ),
          ListTile(
            title: const Text('云盘保留备份份数'),
            trailing: AppSelect<int>(
              value: s.gdriveKeepCount,
              options: [
                for (final n in [3, 5, 10, 20, 50]) (value: n, label: '$n 份'),
              ],
              onChanged: (v) =>
                  store.updateSettings((x) => x.gdriveKeepCount = v),
            ),
          ),
            if (bm.status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('状态：${bm.status}', style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    ),
  );
  }
}

class _RemoteBackupsDialog extends StatefulWidget {
  const _RemoteBackupsDialog({required this.manager, required this.askReplace});
  final BackupManager manager;
  final Future<bool?> Function() askReplace;

  @override
  State<_RemoteBackupsDialog> createState() => _RemoteBackupsDialogState();
}

class _RemoteBackupsDialogState extends State<_RemoteBackupsDialog> {
  List<GDriveBackupFile>? _files;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _files = null;
      _error = null;
    });
    try {
      final f = await widget.manager.drive.list();
      if (mounted) setState(() => _files = f);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _import(GDriveBackupFile f) async {
    final replace = await widget.askReplace();
    if (replace == null) return;
    setState(() => _busy = true);
    try {
      final r = await widget.manager
          .importFromDrive(f.id, replace: replace, modified: f.modified);
      if (mounted) {
        Navigator.pop(context);
        showToast(context, '导入成功：$r');
      }
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(GDriveBackupFile f) async {
    if (!await confirm(context, title: '删除云端备份', message: f.name, danger: true)) return;
    try {
      await widget.manager.drive.delete(f.id);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('云盘备份')),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 400,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : _files == null
                    ? const Center(child: CircularProgressIndicator())
                    : _files!.isEmpty
                        ? const Center(child: Text('云盘上还没有备份'))
                        : ListView(
                            children: [
                              for (final f in _files!)
                                ListTile(
                                  leading: const Icon(Icons.lock_outline),
                                  title: Text(f.name, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                      '${formatDateTime(f.modified.toLocal())}  ${formatBytes(f.size)}'),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(onPressed: () => _import(f), child: const Text('导入')),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () => _delete(f),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}

class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                Icon(Icons.terminal,
                    size: 48, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SSH Restart',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const Text('版本 1.0.0'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              '开源的 SSH 客户端，参照 FinalShell 的功能设计：多标签终端、服务器状态监控、'
              'SFTP 文件管理、命令历史与快速命令、端口转发、代理与跳板机、VNC 远程桌面，'
              '以及加密的谷歌云盘备份。全部功能免费，无任何付费项。',
            ),
            const SizedBox(height: 16),
            const Text('数据保存在本机，会话密码仅在本机和你自己的加密备份中出现。'),
          ],
        ),
      ),
    );
  }
}
