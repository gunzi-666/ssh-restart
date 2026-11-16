import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../services/ssh/sftp_service.dart';
import '../state/ssh_tab.dart';
import 'widgets/common.dart';

bool get _isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 用系统默认程序打开本地文件。
Future<void> openLocalFile(BuildContext context, String path) async {
  if (!File(path).existsSync()) {
    showToast(context, '文件已不存在：$path');
    return;
  }
  try {
    if (!await launchUrl(Uri.file(path)) && context.mounted) {
      showToast(context, '无法打开文件：没有关联的程序');
    }
  } catch (e) {
    if (context.mounted) showToast(context, '打开失败：$e');
  }
}

/// 在系统文件管理器中显示并选中文件（Linux 只能打开所在目录）。
Future<void> revealLocalFile(BuildContext context, String path) async {
  final exists = File(path).existsSync() || Directory(path).existsSync();
  if (!exists) {
    showToast(context, '文件已不存在：$path');
    return;
  }
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', p.normalize(path)]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', path]);
    } else {
      await Process.start('xdg-open', [p.dirname(path)]);
    }
  } catch (e) {
    if (context.mounted) showToast(context, '打开文件夹失败：$e');
  }
}

class TransferPanel extends StatelessWidget {
  const TransferPanel({super.key, required this.tab});
  final SshTab tab;

  @override
  Widget build(BuildContext context) {
    final s = tab.sftp;
    if (s == null) return const Center(child: Text('未连接'));
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final list = s.transfers;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
              child: Row(
                children: [
                  Text('传输列表（${list.length}）',
                      style: Theme.of(context).textTheme.labelLarge),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: s.clearFinished,
                    icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                    label: const Text('清除已完成'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('暂无传输任务', style: TextStyle(fontSize: 12)))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) => _item(context, s, list[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _item(BuildContext context, SftpService s, TransferTask t) {
    final up = t.kind == TransferKind.upload;
    final done = t.state == TransferState.done;
    final canOpen = _isDesktop && done && !up;
    final (label, color) = switch (t.state) {
      TransferState.queued => ('等待中', Colors.grey),
      TransferState.running => ('${(t.progress * 100).toStringAsFixed(0)}%  ${formatSpeed(t.speed)}', Colors.blue),
      TransferState.done => ('已完成', Colors.green),
      TransferState.failed => ('失败', Colors.red),
      TransferState.cancelled => ('已取消', Colors.orange),
    };
    Widget action(String tip, IconData icon, VoidCallback onPressed) => IconButton(
          tooltip: tip,
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon),
          onPressed: onPressed,
        );
    return GestureDetector(
      onDoubleTap: canOpen ? () => openLocalFile(context, t.localPath) : null,
      child: ListTile(
        dense: true,
        leading: Icon(up ? Icons.upload : Icons.download,
            color: up ? Colors.orange : Colors.green),
        title: Text(t.name, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              up ? '${t.localPath}  →  ${t.remotePath}' : '${t.remotePath}  →  ${t.localPath}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            if (t.state == TransferState.running)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: LinearProgressIndicator(value: t.total > 0 ? t.progress : null, minHeight: 3),
              ),
            if (t.error != null)
              Text(t.error!, style: const TextStyle(fontSize: 11, color: Colors.red),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${formatBytes(t.transferred)}/${formatBytes(t.total)}  ',
                style: const TextStyle(fontSize: 11)),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
            if (canOpen)
              action('打开文件', Icons.open_in_new_rounded,
                  () => openLocalFile(context, t.localPath)),
            if (_isDesktop && done)
              action(Platform.isMacOS ? '在访达中显示' : '在文件夹中显示',
                  Icons.folder_open_outlined, () => revealLocalFile(context, t.localPath)),
            if (t.state == TransferState.running || t.state == TransferState.queued)
              action('取消', Icons.close, () => s.cancel(t)),
            if (t.state == TransferState.failed || t.state == TransferState.cancelled)
              action('重试', Icons.refresh, () => s.retry(t)),
          ],
        ),
      ),
    );
  }
}
