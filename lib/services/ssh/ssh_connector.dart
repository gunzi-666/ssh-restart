import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../models/session_config.dart';
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

class SSHConnector {
  static HostKeyPrompt? hostKeyPrompt;
  static InteractivePrompt? interactivePrompt;

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
      SSHCipherType.aes256gcm,
      SSHCipherType.aes128gcm,
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes192ctr,
      SSHCipherType.aes128ctr,
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

  static Future<SSHSocket> _openSocket(
    SessionConfig s,
    AppStore store,
    List<SSHClient> jumps,
    int depth,
  ) async {
    final jump = store.sessionById(s.jumpSessionId);
    if (jump != null && jump.id != s.id) {
      if (depth > 5) throw StateError('跳板机层级过深，请检查是否存在循环引用');
      final jr = await _connect(jump, store, jumps, depth + 1);
      jumps.add(jr);
      return jr.forwardLocal(s.host, s.port);
    }
    if (s.proxy.type != ProxyType.none && s.proxy.host.isNotEmpty) {
      return ProxiedSocket.connect(s.proxy, s.host, s.port);
    }
    return SSHSocket.connect(s.host, s.port,
        timeout: const Duration(seconds: 15));
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
    AppStore store,
    List<SSHClient> jumps,
    int depth,
  ) async {
    final socket = await _openSocket(s, store, jumps, depth);
    final hostKey = '${s.host}:${s.port}';
    final client = SSHClient(
      socket,
      username: s.username,
      algorithms: s.legacyAlgorithms ? _legacy : const SSHAlgorithms(),
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
        final cb = interactivePrompt;
        if (cb == null) return req.prompts.map((_) => s.password).toList();
        return cb(
          req.name.isEmpty ? '${s.displayName} 需要额外验证' : req.name,
          req.prompts.map((p) => p.promptText).toList(),
        );
      },
      onVerifyHostKey: (type, fpBytes) async {
        final fp = utf8.decode(fpBytes);
        final known = store.knownHosts[hostKey];
        if (known == fp) return true;
        final cb = hostKeyPrompt;
        final ok = cb == null ? true : await cb(hostKey, type, fp, known);
        if (ok) store.setKnownHost(hostKey, fp);
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
      client.close();
      rethrow;
    }
    return client;
  }

  static Future<SSHConnectResult> connect(
      SessionConfig s, AppStore store) async {
    final jumps = <SSHClient>[];
    try {
      final c = await _connect(s, store, jumps, 0);
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
