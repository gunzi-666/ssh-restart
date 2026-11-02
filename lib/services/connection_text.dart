/// 从粘贴的文本中识别服务器连接信息。
///
/// 支持本软件「复制连接信息」的格式（`IP：… 端口：… 用户名：… 密码：…`，批量时每段以
/// `【名称】` 开头），以及常见写法：同一行的 `IP: x 端口: y`、`ssh root@host -p 22`、
/// `root@host:22`、`host:22`。
class ParsedConnection {
  String name = '';
  String host = '';
  int? port;
  String username = '';
  String password = '';
  bool keyAuth = false;

  bool get isEmpty => host.isEmpty;

  /// 识别到的字段，用于提示用户。
  List<String> get fields => [
    if (host.isNotEmpty) '主机',
    if (port != null) '端口',
    if (username.isNotEmpty) '用户名',
    if (password.isNotEmpty) '密码',
    if (name.isNotEmpty) '名称',
  ];
}

enum _Key { name, host, port, user, password, auth }

const _keyWords = <_Key, List<String>>{
  _Key.name: ['名称', '服务器名称', '备注名', 'name'],
  _Key.host: [
    'ip地址',
    '服务器地址',
    '主机地址',
    '公网ip',
    'ip',
    '主机',
    '地址',
    '服务器',
    'hostname',
    'host',
    'server',
    'address',
  ],
  _Key.port: ['ssh端口', '端口号', '端口', 'port'],
  _Key.user: ['用户名', '登录用户', '用户', '账号', '账户', 'username', 'user', 'login'],
  _Key.password: ['登录密码', '密码', '口令', 'password', 'passwd', 'pass', 'pwd'],
  _Key.auth: ['认证方式'],
};

final _keyPattern = () {
  final words = [
    for (final e in _keyWords.entries)
      for (final w in e.value) w,
  ]..sort((a, b) => b.length.compareTo(a.length));
  final alt = words.map(RegExp.escape).join('|');
  return RegExp('(?<![A-Za-z0-9])($alt)\\s*[:：=]\\s*', caseSensitive: false);
}();

_Key? _keyOf(String word) {
  final w = word.toLowerCase();
  for (final e in _keyWords.entries) {
    if (e.value.contains(w)) return e.key;
  }
  return null;
}

final _header = RegExp(r'^\s*[【\[]([^】\]]+)[】\]]\s*$');
final _sshCmd = RegExp(
  r'\bssh\s+(?:(?:-p\s*(\d+)|-\S+)\s+)*([^\s@]+)@([\w.\-:\[\]]+)(?:\s+-p\s*(\d+))?',
);
final _userAtHost = RegExp(r'(?<![\w.])([\w.\-]+)@([\w.\-]+)(?::(\d{1,5}))?\b');
final _hostPort = RegExp(
  r'(?<![\w.:])((?:\d{1,3}\.){3}\d{1,3}|(?:[a-zA-Z0-9\-]+\.)+[a-zA-Z]{2,})(?::(\d{1,5}))?(?![\w.])',
);

/// 识别 [text] 中的全部连接；没有识别到主机的段落会被忽略。
List<ParsedConnection> parseConnectionText(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');

  // 1. 有【名称】标题时按标题分段。
  if (lines.any(_header.hasMatch)) {
    final out = <ParsedConnection>[];
    String? name;
    var buf = <String>[];
    void flush() {
      final c = _parseBlock(buf.join('\n'));
      if (!c.isEmpty) {
        final n = name;
        if (n != null && c.name.isEmpty) c.name = n;
        out.add(c);
      }
      buf = [];
    }

    for (final l in lines) {
      final m = _header.firstMatch(l);
      if (m != null) {
        flush();
        name = m.group(1)!.trim();
      } else {
        buf.add(l);
      }
    }
    flush();
    return out;
  }

  // 2. 按空行分段；只有每段都带主机时才视为多台，否则当作一台。
  final blocks = <String>[];
  var cur = <String>[];
  for (final l in lines) {
    if (l.trim().isEmpty) {
      if (cur.isNotEmpty) blocks.add(cur.join('\n'));
      cur = [];
    } else {
      cur.add(l);
    }
  }
  if (cur.isNotEmpty) blocks.add(cur.join('\n'));
  if (blocks.length > 1) {
    final parsed = blocks.map(_parseBlock).toList();
    if (parsed.every((c) => !c.isEmpty)) return parsed;
  }
  final one = _parseBlock(text);
  return one.isEmpty ? const [] : [one];
}

ParsedConnection _parseBlock(String block) {
  final c = ParsedConnection();
  final rest = StringBuffer();

  for (final line in block.split('\n')) {
    final matches = _keyPattern.allMatches(line).toList();
    if (matches.isEmpty) {
      rest.writeln(line);
      continue;
    }
    rest.writeln(line.substring(0, matches.first.start));
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final end = i + 1 < matches.length ? matches[i + 1].start : line.length;
      var value = line.substring(m.end, end).trim();
      final key = _keyOf(m.group(1)!);
      if (key == null || value.isEmpty) continue;
      // 同一行多个字段时，值里不会包含空格（密码除外，它通常放在最后）。
      if (key != _Key.password && i + 1 < matches.length) {
        value = value.split(RegExp(r'\s+')).first;
      }
      _apply(c, key, value);
    }
  }

  final other = rest.toString();
  if (c.host.isEmpty) {
    final ssh = _sshCmd.firstMatch(other);
    final at = _userAtHost.firstMatch(other);
    final hp = _hostPort.firstMatch(other);
    if (ssh != null) {
      if (c.username.isEmpty) c.username = ssh.group(2)!;
      _setHost(c, ssh.group(3)!);
      final p = ssh.group(1) ?? ssh.group(4);
      if (p != null) c.port ??= int.tryParse(p);
    } else if (at != null) {
      if (c.username.isEmpty) c.username = at.group(1)!;
      c.host = at.group(2)!;
      if (at.group(3) != null) c.port ??= int.tryParse(at.group(3)!);
    } else if (hp != null) {
      c.host = hp.group(1)!;
      if (hp.group(2) != null) c.port ??= int.tryParse(hp.group(2)!);
    }
  }
  if (c.port != null && (c.port! <= 0 || c.port! > 65535)) c.port = null;
  return c;
}

void _apply(ParsedConnection c, _Key key, String value) {
  switch (key) {
    case _Key.name:
      if (c.name.isEmpty) c.name = value;
    case _Key.host:
      if (c.host.isEmpty) _setHost(c, value);
    case _Key.port:
      c.port ??= int.tryParse(RegExp(r'\d+').firstMatch(value)?.group(0) ?? '');
    case _Key.user:
      if (c.username.isEmpty) c.username = value.split(RegExp(r'\s+')).first;
    case _Key.password:
      if (c.password.isEmpty) c.password = value;
    case _Key.auth:
      if (value.contains('密钥') || value.contains('公钥')) c.keyAuth = true;
  }
}

/// 主机值可能带端口（`1.2.3.4:2222`）或 `user@host`。
void _setHost(ParsedConnection c, String value) {
  var v = value.trim();
  final at = v.lastIndexOf('@');
  if (at > 0) {
    if (c.username.isEmpty) c.username = v.substring(0, at);
    v = v.substring(at + 1);
  }
  final m = RegExp(r'^(.+?):(\d{1,5})$').firstMatch(v);
  if (m != null && !m.group(1)!.contains(':')) {
    v = m.group(1)!;
    c.port ??= int.tryParse(m.group(2)!);
  }
  c.host = v.replaceAll(RegExp(r'^\[|\]$'), '');
}
