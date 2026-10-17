import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import 'widgets/common.dart';

Future<SessionConfig?> showSessionEditor(BuildContext context, SessionConfig s,
    {bool isNew = false}) {
  final page = SessionEditor(config: s, isNew: isNew);
  if (isWide(context)) {
    return showDialog<SessionConfig>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(width: 640, height: 620, child: page),
      ),
    );
  }
  return Navigator.push<SessionConfig>(
      context, MaterialPageRoute(builder: (_) => page));
}

class SessionEditor extends StatefulWidget {
  const SessionEditor({super.key, required this.config, this.isNew = false});
  final SessionConfig config;
  final bool isNew;

  @override
  State<SessionEditor> createState() => _SessionEditorState();
}

class _SessionEditorState extends State<SessionEditor> {
  late final SessionConfig s = widget.config;
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: s.name);
  late final _host = TextEditingController(text: s.host);
  late final _port = TextEditingController(text: '${s.port}');
  late final _user = TextEditingController(text: s.username);
  late final _password = TextEditingController(text: s.password);
  late final _key = TextEditingController(text: s.privateKey);
  late final _passphrase = TextEditingController(text: s.passphrase);
  late final _desc = TextEditingController(text: s.description);
  late final _init = TextEditingController(text: s.initCommand);
  late final _pHost = TextEditingController(text: s.proxy.host);
  late final _pPort = TextEditingController(text: '${s.proxy.port}');
  late final _pUser = TextEditingController(text: s.proxy.username);
  late final _pPass = TextEditingController(text: s.proxy.password);
  bool _showPassword = false;

  bool get isVnc => s.type == SessionType.vnc;

  void _save() {
    if (!(_form.currentState?.validate() ?? true)) return;
    s
      ..name = _name.text.trim()
      ..host = _host.text.trim()
      ..port = int.tryParse(_port.text.trim()) ?? (isVnc ? 5900 : 22)
      ..username = _user.text.trim()
      ..password = _password.text
      ..privateKey = _key.text
      ..passphrase = _passphrase.text
      ..description = _desc.text.trim()
      ..initCommand = _init.text;
    s.proxy
      ..host = _pHost.text.trim()
      ..port = int.tryParse(_pPort.text.trim()) ?? 1080
      ..username = _pUser.text
      ..password = _pPass.text;
    Navigator.pop(context, s);
  }

  Future<void> _importKey() async {
    final r = await FilePicker.pickFiles(dialogTitle: '选择私钥文件', withData: true);
    final f = r?.files.firstOrNull;
    if (f == null) return;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return;
    setState(() => _key.text = utf8.decode(bytes, allowMalformed: true));
  }

  @override
  Widget build(BuildContext context) {
    final tabs = isVnc
        ? const [Tab(text: '常规'), Tab(text: 'SSH 隧道')]
        : const [
            Tab(text: '常规'),
            Tab(text: '高级'),
            Tab(text: '代理'),
            Tab(text: '跳板机'),
            Tab(text: '隧道'),
          ];
    final views = isVnc
        ? [_general(), _jump()]
        : [_general(), _advanced(), _proxy(), _jump(), _forwards()];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.isNew
              ? (isVnc ? '新建 VNC 远程桌面' : '新建 SSH 连接')
              : '编辑会话'),
          automaticallyImplyLeading: !isWide(context),
          actions: [
            if (isWide(context))
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(onPressed: _save, child: const Text('保存')),
            ),
          ],
          bottom: TabBar(tabs: tabs, isScrollable: !isWide(context)),
        ),
        body: Form(
          key: _form,
          child: TabBarView(children: views),
        ),
      ),
    );
  }

  Widget _pad(List<Widget> children) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final c in children)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
        ],
      );

  Widget _groupPicker() {
    final store = context.watch<AppStore>();
    return AppDropdown<String?>(
      label: '分组',
      value: store.groupById(s.groupId)?.id,
      options: [
        (value: null, label: '（根目录）'),
        for (final g in store.groups) (value: g.id, label: g.name),
      ],
      onChanged: (v) => setState(() => s.groupId = v),
    );
  }

  Widget _general() {
    return _pad([
      TextFormField(
        controller: _name,
        decoration: const InputDecoration(labelText: '名称', hintText: '留空则显示主机地址'),
      ),
      Row(
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: _host,
              decoration: const InputDecoration(labelText: '主机'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入主机地址' : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _port,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '端口'),
            ),
          ),
        ],
      ),
      if (!isVnc) ...[
        TextFormField(
          controller: _user,
          decoration: const InputDecoration(labelText: '用户名'),
        ),
        SegmentedButton<AuthType>(
          segments: const [
            ButtonSegment(value: AuthType.password, label: Text('密码'), icon: Icon(Icons.password)),
            ButtonSegment(value: AuthType.key, label: Text('公钥'), icon: Icon(Icons.vpn_key)),
          ],
          selected: {s.authType},
          onSelectionChanged: (v) => setState(() => s.authType = v.first),
        ),
      ],
      if (isVnc || s.authType == AuthType.password)
        TextFormField(
          controller: _password,
          obscureText: !_showPassword,
          decoration: InputDecoration(
            labelText: isVnc ? 'VNC 密码' : '密码',
            suffixIcon: IconButton(
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
      if (!isVnc && s.authType == AuthType.key) ...[
        TextFormField(
          controller: _key,
          maxLines: 6,
          minLines: 4,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(
            labelText: '私钥（OpenSSH / PEM 格式）',
            alignLabelWithHint: true,
            suffixIcon: IconButton(
              tooltip: '从文件导入',
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _importKey,
            ),
          ),
        ),
        TextFormField(
          controller: _passphrase,
          obscureText: true,
          decoration: const InputDecoration(labelText: '私钥密码（可选）'),
        ),
        TextFormField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: '登录密码（可选，公钥失败时尝试）'),
        ),
      ],
      _groupPicker(),
      TextFormField(
        controller: _desc,
        decoration: const InputDecoration(labelText: '备注'),
      ),
    ]);
  }

  Widget _advanced() {
    return _pad([
      AppDropdown<String>(
        label: '终端编码',
        value: s.charset.toUpperCase() == 'GBK' ? 'GBK' : 'UTF-8',
        options: const [
          (value: 'UTF-8', label: 'UTF-8'),
          (value: 'GBK', label: 'GBK'),
        ],
        onChanged: (v) => setState(() => s.charset = v),
      ),
      TextFormField(
        controller: _init,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(
          labelText: '登录后自动执行的命令',
          hintText: '例如：cd /var/www && ls',
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('兼容旧服务器算法'),
        subtitle: const Text(
            '启用 ssh-rsa(SHA1)、diffie-hellman-group1/14-sha1、CBC 等旧算法，仅在老旧设备连接失败时开启'),
        value: s.legacyAlgorithms,
        onChanged: (v) => setState(() => s.legacyAlgorithms = v),
      ),
    ]);
  }

  Widget _proxy() {
    final p = s.proxy;
    return _pad([
      SegmentedButton<ProxyType>(
        segments: const [
          ButtonSegment(value: ProxyType.none, label: Text('不使用')),
          ButtonSegment(value: ProxyType.http, label: Text('HTTP')),
          ButtonSegment(value: ProxyType.socks5, label: Text('SOCKS5')),
        ],
        selected: {p.type},
        onSelectionChanged: (v) => setState(() => p.type = v.first),
      ),
      if (p.type != ProxyType.none) ...[
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _pHost,
                decoration: const InputDecoration(labelText: '代理主机'),
                validator: (v) => p.type != ProxyType.none &&
                        (v == null || v.trim().isEmpty)
                    ? '请输入代理主机'
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _pPort,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: '端口'),
              ),
            ),
          ],
        ),
        TextFormField(
          controller: _pUser,
          decoration: const InputDecoration(labelText: '用户名（可选）'),
        ),
        TextFormField(
          controller: _pPass,
          obscureText: true,
          decoration: const InputDecoration(labelText: '密码（可选）'),
        ),
      ],
      const Text('使用跳板机时将忽略代理设置。', style: TextStyle(fontSize: 12)),
    ]);
  }

  Widget _jump() {
    final store = context.watch<AppStore>();
    final candidates = store.sessions
        .where((x) => x.id != s.id && x.type == SessionType.ssh)
        .toList();
    return _pad([
      Text(isVnc
          ? '通过一个已保存的 SSH 会话建立隧道，再连接上面填写的 VNC 地址（地址相对于 SSH 服务器）。'
          : '先登录跳板机，再经由跳板机连接目标主机（相当于 ssh -J）。目标主机地址相对于跳板机。'),
      AppDropdown<String?>(
        label: isVnc ? 'SSH 隧道会话' : '跳板机',
        value: store.sessionById(s.jumpSessionId)?.id,
        options: [
          (value: null, label: '不使用'),
          for (final c in candidates)
            (value: c.id, label: '${c.displayName}  (${c.username}@${c.host})'),
        ],
        onChanged: (v) => setState(() => s.jumpSessionId = v),
      ),
    ]);
  }

  Widget _forwards() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              const Expanded(child: Text('连接成功后自动启动以下转发规则')),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final f = await showForwardEditor(context, PortForward());
                  if (f != null) setState(() => s.forwards.add(f));
                },
                icon: const Icon(Icons.add),
                label: const Text('添加'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final f in s.forwards)
                ListTile(
                  leading: Checkbox(
                    value: f.enabled,
                    onChanged: (v) => setState(() => f.enabled = v ?? true),
                  ),
                  title: Text(f.label),
                  subtitle: f.note.isEmpty ? null : Text(f.note),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final r = await showForwardEditor(context, f.copy());
                          if (r != null) {
                            setState(() {
                              final i = s.forwards.indexWhere((x) => x.id == f.id);
                              s.forwards[i] = r;
                            });
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => s.forwards.remove(f)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<PortForward?> showForwardEditor(BuildContext context, PortForward f) {
  final bindHost = TextEditingController(text: f.bindHost);
  final bindPort = TextEditingController(text: f.bindPort == 0 ? '' : '${f.bindPort}');
  final destHost = TextEditingController(text: f.destHost);
  final destPort = TextEditingController(text: f.destPort == 0 ? '' : '${f.destPort}');
  final note = TextEditingController(text: f.note);
  return showDialog<PortForward>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final isRemote = f.type == ForwardType.remote;
        return AlertDialog(
          title: const Text('端口转发'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<ForwardType>(
                  segments: const [
                    ButtonSegment(value: ForwardType.local, label: Text('本地(-L)')),
                    ButtonSegment(value: ForwardType.remote, label: Text('远程(-R)')),
                    ButtonSegment(value: ForwardType.dynamic, label: Text('动态(-D)')),
                  ],
                  selected: {f.type},
                  onSelectionChanged: (v) => setState(() => f.type = v.first),
                ),
                const SizedBox(height: 8),
                Text(
                  switch (f.type) {
                    ForwardType.local => '本机监听端口，连接会经 SSH 转发到远程可访问的目标地址。',
                    ForwardType.remote => '服务器上监听端口，连接会经 SSH 转发到本机可访问的目标地址。',
                    ForwardType.dynamic => '本机启动 SOCKS5 代理，所有流量经由 SSH 服务器发出。',
                  },
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: bindHost,
                        decoration: InputDecoration(
                            labelText: isRemote ? '服务器监听地址' : '本机监听地址'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: bindPort,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(labelText: '监听端口'),
                      ),
                    ),
                  ],
                ),
                if (f.type != ForwardType.dynamic) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: destHost,
                          decoration: const InputDecoration(labelText: '目标地址'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: destPort,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(labelText: '目标端口'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: '备注（可选）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final bp = int.tryParse(bindPort.text) ?? 0;
                final dp = int.tryParse(destPort.text) ?? 0;
                if (bp <= 0 || (f.type != ForwardType.dynamic && dp <= 0)) {
                  showToast(ctx, '请填写有效的端口');
                  return;
                }
                f
                  ..bindHost = bindHost.text.trim()
                  ..bindPort = bp
                  ..destHost = destHost.text.trim()
                  ..destPort = dp
                  ..note = note.text.trim();
                Navigator.pop(ctx, f);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    ),
  );
}
