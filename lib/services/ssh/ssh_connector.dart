import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../models/session_config.dart';
import '../../state/connect_progress.dart';
import '../app_store.dart';
import 'proxy_socket.dart';

/// 主机指纹确认回调：[known] 为之前记录的指纹（首次连接时为 null）。返回 true 表示信任并继续连接。
typedef HostKeyPrompt = Future<bool> Function(
    String hostKey, String type, String fingerprint, String? known);

/// 键盘交互认证中服务器提出的额外问题（例如二次验证码）。
typedef InteractivePrompt = Future<List<String>?> Function(
    String title, List<String> prompts);

class SSHConnectResult {
  final SSHClient client;

  /// 跳板机连接，主连接关闭时需要一并关闭。
  final List<SSHClient> jumpClients;
  SSHConnectResult(this.client, this.jumpClients);

  void closeAll() {
    client.close();
    for (final j in jumpClients.reversed) {
      j.close();
    }
  }
}

/// 连接所需的外部数据：查找跳板机会话、已信任的主机指纹。
class _Ctx {
  _Ctx({
    required this.lookup,
    required this.knownHost,
    this.trust,
    this.interactive = true,
  });

  final SessionConfig? Function(String? id) lookup;
  final String? Function(String hostKey) knownHost;
  final void Function(String hostKey, String fingerprint)? trust;

  /// 为 false 时不弹任何确认框：未信任的指纹直接拒绝，需要额外验证码时放弃认证。
  final bool interactive;
}

class SSHConnector {
  static HostKeyPrompt? hostKeyPrompt;
  static InteractivePrompt? interactivePrompt;

  /// dartssh2 的 AES-GCM 每个数据包都重新初始化加密器，比 AES-CTR / ChaCha20 慢约 20 倍；
  /// 加解密又和界面在同一线程执行，传输大文件时会让窗口卡死，所以 GCM 只作为最后的选择。
  /// AES-CTR 是该库使用最久、最成熟的实现，排在 ChaCha20（3.2.0 才加入）之前。
  static const _modern = SSHAlgorithms(
    cipher: [
      SSHCipherType.aes128ctr,
      SSHCipherType.aes256ctr,
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes128gcm,
      SSHCipherType.aes256gcm,
    ],
  );

  static const _legacy = SSHAlgorithms(
    kex: [
      SSHKexType.x25519Rfc,
      SSHKexType.x25519,
      SSHKexType.nistp521,
      SSHKexType.nistp384,
      SSHKexType.nistp256,
      SSHKexType.dhGexSha256,
      SSHKexType.dh14Sha256,
      SSHKexType.dhGexSha1,
      SSHKexType.dh14Sha1,
      SSHKexType.dh1Sha1,
    ],
    hostkey: [
      SSHHostkeyType.ed25519,
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ecdsa256,
      SSHHostkeyType.rsaSha1,
    ],
    cipher: [
      SSHCipherType.aes128ctr,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes192ctr,
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes128gcm,
      SSHCipherType.aes256gcm,
      SSHCipherType.aes256cbc,
      SSHCipherType.aes192cbc,
      SSHCipherType.aes128cbc,
    ],
    mac: [
      SSHMacType.hmacSha256Etm,
      SSHMacType.hmacSha512Etm,
      SSHMacType.hmacSha256,
      SSHMacType.hmacSha512,
      SSHMacType.hmacSha1,
      SSHMacType.hmacMd5,
    ],
  );

  /// 跳板机层数（不含目标服务器本身）。
  static int _jumpCount(SessionConfig s, _Ctx ctx) {
    var n = 0;
    var cur = s;
    final seen = <String>{s.id};
    while (n <= 6) {
      final j = ctx.lookup(cur.jumpSessionId);
      if (j == null || !seen.add(j.id)) break;
      n++;
      cur = j;
    }
    return n;
  }

  /// 第 depth 层对应的显示名：目标服务器为空，跳板机按连接顺序编号。
  static String _hopName(int depth, int total) =>
      depth == 0 ? '' : '第 ${total - depth + 1} 跳板机';

  static Future<SSHSocket> _openSocket(
    SessionConfig s,
    _Ctx ctx,
    List<SSHClient> jumps,
    int depth,
    int total,
    ConnectProgress? p,
  ) async {
    final name = _hopName(depth, total);
    final jump = ctx.lookup(s.jumpSessionId);
    if (jump != null && jump.id != s.id) {
      if (depth > 5) throw StateError('跳板机层级过深，请检查是否存在循环引用');
      final jr = await _connect(jump, ctx, jumps, depth + 1, total, p);
      jumps.add(jr);
      p?.begin(depth == 0 ? '连接到服务器' : '连接到$name');
      p?.log('通过${_hopName(depth + 1, total)}转发到 ${s.host}:${s.port}');
      return jr.forwardLocal(s.host, s.port);
    }
    p?.begin(depth == 0 ? '连接到服务器' : '连接到$name');
    if (s.proxy.type != ProxyType.none && s.proxy.host.isNotEmpty) {
      p?.log('通过 ${s.proxy.type.name.toUpperCase()} 代理 '
          '${s.proxy.host}:${s.proxy.port} 连接 ${s.host}:${s.port}');
      return ProxiedSocket.connect(s.proxy, s.host, s.port);
    }
    p?.log('正在建立 TCP 连接 ${s.host}:${s.port}');
    return SSHSocket.connect(s.host, s.port,
        timeout: const Duration(seconds: 15));
  }

  static final _noisy = RegExp(
      r'_processPackets|_consumeClearTextPacket|_consumeEncryptedPacket|'
      r'_processVersionExchange|_handleMessageExtInfo|_strictKex|'
      r'_tryNextAuthenticationMethod|_startAuthentication');

  /// 把 dartssh2 的调试输出转成易读的中文日志；返回 null 表示忽略。
  static String? _describeDebug(String m) {
    if (_noisy.hasMatch(m)) return null;
    String after(String prefix) => m.substring(m.indexOf(prefix) + prefix.length);
    if (m.contains('_remoteVersion = ')) {
      return '服务器版本：${after('_remoteVersion = ').replaceAll('"', '')}';
    }
    if (m.contains('_kexType: ')) return '密钥交换算法：${after('_kexType: ')}';
    if (m.contains('_hostkeyType: ')) return '主机密钥类型：${after('_hostkeyType: ')}';
    if (m.contains('_clientCipherType: ')) {
      return '加密算法 C→S：${after('_clientCipherType: ')}';
    }
    if (m.contains('_serverCipherType: ')) {
      return '加密算法 S→C：${after('_serverCipherType: ')}';
    }
    if (m.contains('_clientMacType: ')) return 'MAC C→S：${after('_clientMacType: ')}';
    if (m.contains('_serverMacType: ')) return 'MAC S→C：${after('_serverMacType: ')}';
    if (m.contains('_currentAuthMethod = ')) {
      return '尝试认证方式：${after('_currentAuthMethod = ')}';
    }
    if (m.contains('onVerifyHostKey = ')) {
      return m.endsWith('true') ? '主机指纹已信任' : '主机指纹未被信任';
    }
    if (m.startsWith('Remote: ')) return '服务器消息：${after('Remote: ')}';
    const map = {
      'SSHTransport._sendKexInit': '发送 KEXINIT，协商算法',
      'SSHTransport._handleMessageKexInit': '收到服务器 KEXINIT',
      'SSHTransport._sendKexDHInit': '发送 KEXDH_INIT',
      'SSHTransport._sendKexDHGexRequest': '发送 KEX_DH_GEX_REQUEST',
      'SSHTransport._sendKexDHGexInit': '发送 KEX_DH_GEX_INIT',
      'SSHTransport._handleMessageKexReply': '收到 DH 回复',
      'SSHTransport._handleMessageKexGexReply': '收到 DH GEX 回复',
      'SSHTransport._verifyHostkey': '校验主机密钥签名',
      'SSHTransport.onVerifyHostKey': '校验主机指纹',
      'SSHTransport._sendNewKeys': '发送 NEWKEYS',
      'SSHTransport._handleMessageNewKeys': '收到 NEWKEYS，握手完成',
      'SSHClient._onTransportReady': '加密通道已建立',
      'SSHClient._requestAuthentication': '请求 ssh-userauth 服务',
      'SSHClient._authWithNone': '尝试 none 认证',
      'SSHClient._authWithPassword': '发送密码认证',
      'SSHClient._authWithPublicKey': '发送公钥认证',
      'SSHClient._authWithKeyboardInteractive': '发送键盘交互认证',
      'SSHClient._handleUserauthFailure': '服务器拒绝了当前认证方式',
      'SSHClient._handleUserauthSuccess': '认证成功',
      'SSHClient._handleUserauthInfoRequest': '服务器要求键盘交互验证',
      'SSHClient._handleUserauthPKOk': '服务器接受该公钥',
      'SSHTransport._onSocketDone': '服务器关闭了连接',
      'SSHClient._onTransportClosed': '连接已关闭',
    };
    final hit = map[m];
    if (hit != null) return hit;
    if (m.contains('closeWithError ')) return '连接错误：${after('closeWithError ')}';
    if (m.contains('_onSocketError(')) return '网络错误：${after('_onSocketError(')}';
    if (m == 'SSHTransport.close') return null;
    return m;
  }

  static List<SSHKeyPair>? _identities(SessionConfig s) {
    if (s.authType != AuthType.key || s.privateKey.trim().isEmpty) return null;
    try {
      return SSHKeyPair.fromPem(
          s.privateKey, s.passphrase.isEmpty ? null : s.passphrase);
    } catch (e) {
      throw StateError('私钥解析失败：$e');
    }
  }

  static Future<SSHClient> _connect(
    SessionConfig s,
    _Ctx ctx,
    List<SSHClient> jumps,
    int depth,
    int total,
    ConnectProgress? p,
  ) async {
    final name = _hopName(depth, total);
    final socket = await _openSocket(s, ctx, jumps, depth, total, p);
    p?.log('TCP 连接已建立');
    p?.begin('配置$name连接协议');
    var logging = p != null;
    var authStarted = false;
    final hostKey = '${s.host}:${s.port}';
    final client = SSHClient(
      printDebug: p == null
          ? null
          : (m) {
              if (!logging || m == null) return;
              if (!authStarted && m == 'SSHClient._onTransportReady') {
                authStarted = true;
                p.log('加密通道已建立');
                p.begin('认证$name用户信息');
                p.log('用户名：${s.username}，认证方式：'
                    '${s.authType == AuthType.key ? '密钥' : '密码'}');
                return;
              }
              final text = _describeDebug(m);
              if (text != null) p.log(text);
            },
      socket,
      username: s.username,
      algorithms: s.legacyAlgorithms ? _legacy : _modern,
      identities: _identities(s),
      onPasswordRequest:
          s.password.isEmpty && s.authType == AuthType.key ? null : () => s.password,
      onUserInfoRequest: (req) async {
        if (req.prompts.isEmpty) return [];
        final allPassword = req.prompts.length == 1 &&
            !req.prompts.first.echo &&
            req.prompts.first.promptText.toLowerCase().contains('password') &&
            s.password.isNotEmpty;
        if (allPassword) return [s.password];
        if (!ctx.interactive) return null;
        final cb = interactivePrompt;
        if (cb == null) return req.prompts.map((_) => s.password).toList();
        Future<List<String>?> ask() => cb(
              req.name.isEmpty ? '${s.displayName} 需要额外验证' : req.name,
              req.prompts.map((p) => p.promptText).toList(),
            );
        return p == null ? ask() : p.waitForUser(ask);
      },
      onVerifyHostKey: (type, fpBytes) async {
        final fp = utf8.decode(fpBytes);
        final known = ctx.knownHost(hostKey);
        if (known == fp) return true;
        if (!ctx.interactive) return false;
        final cb = hostKeyPrompt;
        Future<bool> ask() => cb!(hostKey, type, fp, known);
        final bool ok;
        if (p != null && p.hasViewer()) {
          ok = await p.askHostKey(hostKey, type, fp, known);
        } else {
          ok = cb == null
              ? true
              : await (p == null ? ask() : p.waitForUser(ask));
        }
        if (ok) ctx.trust?.call(hostKey, fp);
        return ok;
      },
      // 服务器拒绝 env 等非必需请求时不中断会话，与 OpenSSH 行为一致。
      pipelineChannelRequests: true,
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 20),
      authTimeout: const Duration(seconds: 60),
    );
    try {
      await client.authenticated;
    } catch (e) {
      logging = false;
      client.close();
      rethrow;
    }
    logging = false;
    if (depth > 0) p?.begin('$name连接成功');
    return client;
  }

  static Future<SSHConnectResult> connect(SessionConfig s, AppStore store,
          {ConnectProgress? progress}) =>
      _run(
        s,
        _Ctx(
          lookup: store.sessionById,
          knownHost: (k) => store.knownHosts[k],
          trust: store.setKnownHost,
        ),
        progress,
      );

  /// 不弹任何确认框的连接，供后台 isolate 使用：[sessions] 提供跳板机配置，
  /// 主机指纹必须已在 [knownHosts] 中，需要额外验证码的服务器会认证失败。
  static Future<SSHConnectResult> connectDetached(
    SessionConfig s,
    Map<String, SessionConfig> sessions,
    Map<String, String> knownHosts,
  ) =>
      _run(
        s,
        _Ctx(
          lookup: (id) => id == null ? null : sessions[id],
          knownHost: (k) => knownHosts[k],
          interactive: false,
        ),
        null,
      );

  static Future<SSHConnectResult> _run(
      SessionConfig s, _Ctx ctx, ConnectProgress? progress) async {
    final jumps = <SSHClient>[];
    try {
      final c = await _connect(s, ctx, jumps, 0, _jumpCount(s, ctx), progress);
      return SSHConnectResult(c, jumps);
    } catch (e) {
      for (final j in jumps) {
        j.close();
      }
      rethrow;
    }
  }

  static String describeError(Object e) {
    final s = e.toString();
    if (e is SSHAuthFailError || s.contains('SSHAuthFail')) {
      return '认证失败：用户名、密码或密钥错误';
    }
    if (s.contains('SocketException') || s.contains('Connection refused')) {
      return '网络连接失败：$s';
    }
    if (e is TimeoutException) return '连接超时';
    if (e is SSHHostkeyError) return '主机指纹未被信任，已取消连接';
    return s;
  }
}
