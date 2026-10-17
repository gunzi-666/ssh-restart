import 'package:flutter/material.dart';

import '../services/ssh/sftp_service.dart';
import '../state/ssh_tab.dart';
import 'widgets/common.dart';

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
    final (label, color) = switch (t.state) {
      TransferState.queued => ('等待中', Colors.grey),
      TransferState.running => ('${(t.progress * 100).toStringAsFixed(0)}%  ${formatSpeed(t.speed)}', Colors.blue),
      TransferState.done => ('已完成', Colors.green),
      TransferState.failed => ('失败', Colors.red),
      TransferState.cancelled => ('已取消', Colors.orange),
    };
    return ListTile(
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
          if (t.state == TransferState.running || t.state == TransferState.queued)
            IconButton(
              tooltip: '取消',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => s.cancel(t),
            ),
          if (t.state == TransferState.failed || t.state == TransferState.cancelled)
            IconButton(
              tooltip: '重试',
              icon: const Icon(Icons.refresh, size: 16),
              onPressed: () => s.retry(t),
            ),
        ],
      ),
    );
  }
}
