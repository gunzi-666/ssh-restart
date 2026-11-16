import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import '../state/ssh_tab.dart';
import 'session_editor.dart';
import 'widgets/shad.dart';

/// 当前连接的端口转发（隧道）管理：临时添加、启停，或保存到会话配置。
class ForwardPanel extends StatelessWidget {
  const ForwardPanel({super.key, required this.tab});
  final SshTab tab;

  @override
  Widget build(BuildContext context) {
    final m = tab.forwards;
    if (m == null) return const Center(child: Text('未连接'));
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Text('隧道（端口转发）', style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    final f = await showForwardEditor(context, PortForward());
                    if (f == null) return;
                    await m.start(f);
                    if (!context.mounted) return;
                    final save = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AppDialog(
                        title: '保存转发规则',
                        description: '是否把该转发规则保存到会话配置中，下次连接时自动启动？',
                        actions: [
                          AppButton(label: '仅本次', onPressed: () => Navigator.pop(ctx, false)),
                          AppButton(
                              label: '保存',
                              primary: true,
                              onPressed: () => Navigator.pop(ctx, true)),
                        ],
                      ),
                    );
                    if (save == true && context.mounted) {
                      final store = context.read<AppStore>();
                      final s = store.sessionById(tab.config.id);
                      if (s != null) {
                        s.forwards.add(f.copy());
                        store.upsertSession(s);
                      }
                    }
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                ),
              ],
            ),
          ),
          Expanded(
            child: m.items.isEmpty
                ? const Center(child: Text('暂无转发规则', style: TextStyle(fontSize: 12)))
                : ListView(
                    children: [
                      for (final e in m.items)
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.swap_horiz,
                              color: e.running ? Colors.green : Colors.grey),
                          title: Text(e.config.label),
                          subtitle: Text(
                              '${e.status}${e.running ? '    活动连接 ${e.connections}' : ''}'
                              '${e.config.note.isEmpty ? '' : '    ${e.config.note}'}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: e.running,
                                onChanged: (v) =>
                                    v ? m.start(e.config) : m.stop(e.config.id),
                              ),
                              IconButton(
                                tooltip: '移除',
                                icon: const Icon(Icons.delete_outline, size: 18),
                                onPressed: () => m.remove(e.config.id),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
