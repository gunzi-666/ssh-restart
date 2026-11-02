import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import '../services/connection_text.dart';
import 'session_picker.dart';
import 'widgets/common.dart';

Future<SessionConfig?> showSessionEditor(BuildContext context, SessionConfig s,
    {bool isNew = false}) {
  final page = SessionEditor(config: s, isNew: isNew);
  if (isWide(context)) {
    final screen = MediaQuery.sizeOf(context);
    final width = isNew ? 940.0 : 640.0;
    return showDialog<SessionConfig>(
      context: context,
      builder: (_) => AppDialogShell(
        child: SizedBox(
          width: width.clamp(360.0, screen.width - 48),
          height: 760.0.clamp(360.0, screen.height - 48),
          child: page,
        ),
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
  final _quick = TextEditingController();
  bool _showPassword = false;

  /// 宽弹窗中快速填写放在右侧，否则放在常规页顶部。
  bool _quickAside = false;

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

  Future<void> _pasteQuick() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    if (text.trim().isEmpty) {
      showToast(context, '剪贴板里没有文本');
      return;
    }
    _quick.text = text;
    _applyQuick();
  }

  void _applyQuick() {
    final list = parseConnectionText(_quick.text);
    if (list.isEmpty) {
      showToast(context, '没有识别到主机地址，请检查粘贴的内容');
      return;
    }
    final c = list.first;
    setState(() {
      _host.text = c.host;
      if (c.port != null) _port.text = '${c.port}';
      if (c.username.isNotEmpty) _user.text = c.username;
      if (c.password.isNotEmpty) _password.text = c.password;
      if (c.name.isNotEmpty && _name.text.trim().isEmpty) _name.text = c.name;
      if (!isVnc) {
        s.authType = c.keyAuth && c.password.isEmpty
            ? AuthType.key
            : AuthType.password;
      }
    });
    final tip = '已识别：${c.fields.join('、')}';
    showToast(
      context,
      list.length > 1
          ? '$tip。共识别到 ${list.length} 台，仅填入第一台，批量导入请用首页「新建连接 → 从文本批量导入」'
          : tip,
    );
  }

  String get _title => widget.isNew
      ? (isVnc ? '新建 VNC 远程桌面' : '新建 SSH 连接')
      : '编辑会话';

  String get _description => widget.isNew
      ? '填写服务器的连接信息，保存后可在列表中一键连接。'
      : '修改“${s.displayName}”的连接设置，保存后对新打开的连接生效。';

  @override
  Widget build(BuildContext context) {
    final tabs = isVnc
        ? const ['常规', 'SSH 隧道']
        : const ['常规', '高级', '代理', '跳板机', '隧道'];
    Widget body() => Form(
          key: _form,
          child: TabBarView(
            children: isVnc
                ? [_general(), _jump()]
                : [_general(), _advanced(), _proxy(), _jump(), _forwards()],
          ),
        );

    if (!isWide(context)) {
      _quickAside = false;
      return DefaultTabController(
        length: tabs.length,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_title),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(onPressed: _save, child: const Text('保存')),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: AppTabBar(tabs: tabs, scrollable: true),
              ),
              Expanded(child: body()),
            ],
          ),
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;
    Widget form() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
              child: AppTabBar(tabs: tabs),
            ),
            Expanded(child: body()),
          ],
        );
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 20, 0),
            child: AppDialogHeader(title: _title, description: _description),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                _quickAside = widget.isNew && c.maxWidth >= 820;
                if (!_quickAside) return form();
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: form()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 18, 24, 20),
                      child: SizedBox(width: 290, child: _quickPanel()),
                    ),
                  ],
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: cs.outlineVariant)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton(
                    label: '取消', onPressed: () => Navigator.pop(context)),
                const SizedBox(width: 8),
                AppButton(label: '保存', primary: true, onPressed: _save),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pad(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        children: [
          for (final c in children)
            Padding(padding: const EdgeInsets.only(bottom: 16), child: c),
        ],
      );

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool obscure = false,
    Widget? suffix,
    int maxLines = 1,
    int? minLines,
    TextStyle? style,
    bool digits = false,
    String? Function(String?)? validator,
  }) {
    return LabeledField(
      label: label,
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        minLines: minLines,
        style: style ?? const TextStyle(fontSize: 14),
        keyboardType: digits ? TextInputType.number : null,
        inputFormatters:
            digits ? [FilteringTextInputFormatter.digitsOnly] : null,
        validator: validator,
        decoration: InputDecoration(hintText: hint, suffixIcon: suffix),
      ),
    );
  }

  Widget _note(String text) => Text(text,
      style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant));

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

  Widget _two(Widget a, Widget b, {int flexA = 1, int flexB = 1}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: flexA, child: a),
          const SizedBox(width: 12),
          Expanded(flex: flexB, child: b),
        ],
      );

  Widget _section(String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: cs.onSurfaceVariant)),
          const SizedBox(width: 10),
          Expanded(child: Divider(height: 1, color: cs.outlineVariant)),
        ],
      ),
    );
  }

  Widget _quickFill() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Text('快速填写',
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('粘贴连接信息，自动识别主机、端口、用户名和密码',
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _quick,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'IP：1.2.3.4  端口：22  用户名：root  密码：******\n'
                  '也支持 ssh root@1.2.3.4 -p 22、root@1.2.3.4:22',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AppButton(
                label: '从剪贴板粘贴',
                icon: Icons.content_paste_rounded,
                onPressed: _pasteQuick,
              ),
              const SizedBox(width: 8),
              AppButton(
                label: '识别并填入',
                icon: Icons.auto_fix_high_rounded,
                primary: true,
                onPressed: _applyQuick,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickPanel() {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12.5, height: 1.5, color: cs.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Text('快速填写',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ],
          ),
          const SizedBox(height: 6),
          Text('粘贴连接信息，自动填入左侧的主机、端口、用户名和密码。', style: muted),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _quick,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 13, height: 1.5),
              decoration: const InputDecoration(
                hintText: 'IP：1.2.3.4\n端口：22\n用户名：root\n密码：******',
              ),
            ),
          ),
          const SizedBox(height: 10),
          AppButton(
            label: '从剪贴板粘贴并识别',
            icon: Icons.content_paste_rounded,
            onPressed: _pasteQuick,
          ),
          const SizedBox(height: 8),
          AppButton(
            label: '识别并填入',
            icon: Icons.auto_fix_high_rounded,
            primary: true,
            onPressed: _applyQuick,
          ),
          const SizedBox(height: 12),
          Text('也支持：\nssh root@1.2.3.4 -p 22\nroot@1.2.3.4:22\nHost / User / Password 等英文字段',
              style: muted),
        ],
      ),
    );
  }

  Widget _passwordField(String label) => _field(
        label,
        _password,
        obscure: !_showPassword,
        suffix: IconButton(
          iconSize: 18,
          icon: Icon(_showPassword
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined),
          onPressed: () => setState(() => _showPassword = !_showPassword),
        ),
      );

  Widget _general() {
    final keyAuth = !isVnc && s.authType == AuthType.key;
    return _pad([
      if (widget.isNew && !_quickAside) _quickFill(),
      _section('服务器'),
      _two(
        _field('主机', _host,
            hint: 'IP 或域名',
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? '请输入主机地址' : null),
        _field('端口', _port, digits: true),
        flexA: 3,
      ),
      _two(
        _field('名称', _name, hint: '留空则显示主机地址'),
        _groupPicker(),
      ),
      _section(isVnc ? '认证' : '登录'),
      if (isVnc)
        _passwordField('VNC 密码')
      else ...[
        AppSegmented<AuthType>(
          value: s.authType,
          options: const [
            (value: AuthType.password, label: '密码登录', icon: Icons.password),
            (value: AuthType.key, label: '公钥登录', icon: Icons.vpn_key_outlined),
          ],
          onChanged: (v) => setState(() => s.authType = v),
        ),
        _two(
          _field('用户名', _user, hint: '例如：root'),
          keyAuth
              ? _field('私钥密码（可选）', _passphrase, obscure: true)
              : _passwordField('密码'),
        ),
        if (keyAuth) ...[
          _field(
            '私钥（OpenSSH / PEM 格式）',
            _key,
            maxLines: 6,
            minLines: 4,
            hint: '-----BEGIN OPENSSH PRIVATE KEY-----',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            suffix: IconButton(
              tooltip: '从文件导入',
              iconSize: 18,
              icon: const Icon(Icons.file_open_outlined),
              onPressed: _importKey,
            ),
          ),
          _field('登录密码（可选，公钥失败时尝试）', _password, obscure: true),
        ],
      ],
      _section('其他'),
      _field('备注', _desc, hint: '可选，会显示在服务器列表中', maxLines: 3, minLines: 1),
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
      _field('登录后自动执行的命令', _init,
          maxLines: 3, minLines: 1, hint: '例如：cd /var/www && ls'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('兼容旧服务器算法', style: TextStyle(fontSize: 14)),
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
      LabeledField(
        label: '代理类型',
        child: AppSegmented<ProxyType>(
          value: p.type,
          options: const [
            (value: ProxyType.none, label: '不使用', icon: null),
            (value: ProxyType.http, label: 'HTTP', icon: null),
            (value: ProxyType.socks5, label: 'SOCKS5', icon: null),
          ],
          onChanged: (v) => setState(() => p.type = v),
        ),
      ),
      if (p.type != ProxyType.none) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: _field('代理主机', _pHost,
                  validator: (v) => p.type != ProxyType.none &&
                          (v == null || v.trim().isEmpty)
                      ? '请输入代理主机'
                      : null),
            ),
            const SizedBox(width: 12),
            Expanded(child: _field('端口', _pPort, digits: true)),
          ],
        ),
        _field('用户名（可选）', _pUser),
        _field('密码（可选）', _pPass, obscure: true),
      ],
      _note('使用跳板机时将忽略代理设置。'),
    ]);
  }

  Widget _jump() {
    final store = context.watch<AppStore>();
    return _pad([
      SessionPickerField(
        label: isVnc ? 'SSH 隧道会话' : '跳板机',
        title: isVnc ? '选择 SSH 隧道会话' : '选择跳板机',
        value: store.sessionById(s.jumpSessionId)?.id,
        excludeId: s.id,
        onChanged: (v) => setState(() => s.jumpSessionId = v),
      ),
      _note(isVnc
          ? '通过一个已保存的 SSH 会话建立隧道，再连接上面填写的 VNC 地址（地址相对于 SSH 服务器）。'
          : '先登录跳板机，再经由跳板机连接目标主机（相当于 ssh -J）。目标主机地址相对于跳板机。'),
    ]);
  }

  Widget _forwards() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              Expanded(child: _note('连接成功后自动启动以下转发规则')),
              AppButton(
                label: '添加',
                icon: Icons.add,
                onPressed: () async {
                  final f = await showForwardEditor(context, PortForward());
                  if (f != null) setState(() => s.forwards.add(f));
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: s.forwards.isEmpty
              ? Center(child: _note('暂无转发规则'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  children: [
                    for (final f in s.forwards)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: cs.outlineVariant),
                        ),
                        child: ListTile(
                          leading: Checkbox(
                            value: f.enabled,
                            onChanged: (v) =>
                                setState(() => f.enabled = v ?? true),
                          ),
                          title: Text(f.label,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: f.note.isEmpty ? null : Text(f.note),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                iconSize: 18,
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () async {
                                  final r = await showForwardEditor(
                                      context, f.copy());
                                  if (r != null) {
                                    setState(() {
                                      final i = s.forwards
                                          .indexWhere((x) => x.id == f.id);
                                      s.forwards[i] = r;
                                    });
                                  }
                                },
                              ),
                              IconButton(
                                iconSize: 18,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    setState(() => s.forwards.remove(f)),
                              ),
                            ],
                          ),
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

  Widget field(String label, TextEditingController c, {bool digits = false}) =>
      LabeledField(
        label: label,
        child: TextField(
          controller: c,
          style: const TextStyle(fontSize: 14),
          keyboardType: digits ? TextInputType.number : null,
          inputFormatters:
              digits ? [FilteringTextInputFormatter.digitsOnly] : null,
        ),
      );

  return showDialog<PortForward>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final isRemote = f.type == ForwardType.remote;
        return AppDialog(
          title: '端口转发',
          description: switch (f.type) {
            ForwardType.local => '本机监听端口，连接会经 SSH 转发到远程可访问的目标地址。',
            ForwardType.remote => '服务器上监听端口，连接会经 SSH 转发到本机可访问的目标地址。',
            ForwardType.dynamic => '本机启动 SOCKS5 代理，所有流量经由 SSH 服务器发出。',
          },
          width: 480,
          actions: [
            AppButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
            AppButton(
              label: '确定',
              primary: true,
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
            ),
          ],
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSegmented<ForwardType>(
                  value: f.type,
                  options: const [
                    (value: ForwardType.local, label: '本地 (-L)', icon: null),
                    (value: ForwardType.remote, label: '远程 (-R)', icon: null),
                    (value: ForwardType.dynamic, label: '动态 (-D)', icon: null),
                  ],
                  onChanged: (v) => setState(() => f.type = v),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: field(
                          isRemote ? '服务器监听地址' : '本机监听地址', bindHost),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        flex: 2,
                        child: field('监听端口', bindPort, digits: true)),
                  ],
                ),
                if (f.type != ForwardType.dynamic) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(flex: 3, child: field('目标地址', destHost)),
                      const SizedBox(width: 12),
                      Expanded(
                          flex: 2,
                          child: field('目标端口', destPort, digits: true)),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                field('备注（可选）', note),
              ],
            ),
          ),
        );
      },
    ),
  );
}
