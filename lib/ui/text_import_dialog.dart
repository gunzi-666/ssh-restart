import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import '../services/connection_text.dart';
import 'widgets/common.dart';

/// 从粘贴的文本批量导入服务器，返回新建的会话（已写入存储）。
Future<List<SessionConfig>> showTextImportDialog(
  BuildContext context, {
  String? groupId,
}) async {
  final r = await showDialog<List<SessionConfig>>(
    context: context,
    builder: (_) => _TextImportDialog(groupId: groupId),
  );
  return r ?? const [];
}

class _TextImportDialog extends StatefulWidget {
  const _TextImportDialog({this.groupId});
  final String? groupId;

  @override
  State<_TextImportDialog> createState() => _TextImportDialogState();
}

class _TextImportDialogState extends State<_TextImportDialog> {
  final _text = TextEditingController();
  List<ParsedConnection> _parsed = const [];

  AppStore get store => context.read<AppStore>();

  bool _exists(ParsedConnection c) => store.sessions.any(
    (s) =>
        s.type == SessionType.ssh &&
        s.host == c.host &&
        s.port == (c.port ?? 22) &&
        (c.username.isEmpty || s.username == c.username),
  );

  void _reparse() => setState(() => _parsed = parseConnectionText(_text.text));

  Future<void> _paste() async {
    final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    if (t.trim().isEmpty) {
      showToast(context, '剪贴板里没有文本');
      return;
    }
    _text.text = t;
    _reparse();
  }

  void _import() {
    final fresh = _parsed.where((c) => !_exists(c)).toList();
    final created = <SessionConfig>[];
    for (final c in fresh) {
      final s = SessionConfig(
        name: c.name,
        groupId: widget.groupId,
        host: c.host,
        port: c.port ?? 22,
        username: c.username.isEmpty ? 'root' : c.username,
        password: c.password,
        authType: c.keyAuth && c.password.isEmpty
            ? AuthType.key
            : AuthType.password,
      );
      store.upsertSession(s);
      created.add(s);
    }
    Navigator.pop(context, created);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fresh = _parsed.where((c) => !_exists(c)).length;
    final dup = _parsed.length - fresh;
    return AppDialog(
      title: '从文本批量导入',
      description:
          '粘贴本软件「复制连接信息」的内容，或任意包含 IP、端口、用户名、密码的文本。'
          '多台服务器用空行或【名称】分隔。',
      width: 640,
      actions: [
        AppButton(
          label: '从剪贴板粘贴',
          icon: Icons.content_paste_rounded,
          onPressed: _paste,
        ),
        const Spacer(),
        AppButton(label: '取消', onPressed: () => Navigator.pop(context)),
        AppButton(
          label: fresh > 0 ? '导入 $fresh 台' : '导入',
          primary: true,
          onPressed: fresh > 0 ? _import : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 6,
            maxLines: 10,
            onChanged: (_) => _reparse(),
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: '【香港】\nIP：1.2.3.4\n端口：22\n用户名：root\n密码：******\n\n'
                  'ssh -p 2222 admin@example.com',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                _parsed.isEmpty
                    ? '尚未识别到服务器'
                    : '识别到 ${_parsed.length} 台'
                          '${dup > 0 ? '，其中 $dup 台已存在将跳过' : ''}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (_parsed.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _parsed.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: cs.outlineVariant),
                  itemBuilder: (_, i) => _row(_parsed[i]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(ParsedConnection c) {
    final cs = Theme.of(context).colorScheme;
    final exists = _exists(c);
    final user = c.username.isEmpty ? 'root' : c.username;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Icon(
            exists ? Icons.remove_circle_outline : Icons.add_circle_outline,
            size: 16,
            color: exists ? cs.onSurfaceVariant : cs.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (c.name.isNotEmpty)
                    TextSpan(
                      text: '${c.name}  ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  TextSpan(text: '$user@${c.host}:${c.port ?? 22}'),
                ],
              ),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            exists
                ? '已存在'
                : c.password.isNotEmpty
                ? '含密码'
                : c.keyAuth
                ? '密钥（需补充私钥）'
                : '无密码',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
