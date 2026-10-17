import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

int nowMs() => DateTime.now().millisecondsSinceEpoch;

enum SessionType { ssh, vnc }

enum AuthType { password, key }

enum ProxyType { none, http, socks5 }

enum ForwardType { local, remote, dynamic }

class PortForward {
  String id;
  ForwardType type;
  String bindHost;
  int bindPort;
  String destHost;
  int destPort;
  bool enabled;
  String note;

  PortForward({
    String? id,
    this.type = ForwardType.local,
    this.bindHost = '127.0.0.1',
    this.bindPort = 0,
    this.destHost = '127.0.0.1',
    this.destPort = 0,
    this.enabled = true,
    this.note = '',
  }) : id = id ?? newId();

  String get label {
    switch (type) {
      case ForwardType.local:
        return '本地 $bindHost:$bindPort → 远程 $destHost:$destPort';
      case ForwardType.remote:
        return '远程 $bindHost:$bindPort → 本地 $destHost:$destPort';
      case ForwardType.dynamic:
        return '动态 SOCKS5 $bindHost:$bindPort';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'bindHost': bindHost,
        'bindPort': bindPort,
        'destHost': destHost,
        'destPort': destPort,
        'enabled': enabled,
        'note': note,
      };

  factory PortForward.fromJson(Map<String, dynamic> j) => PortForward(
        id: j['id'] as String?,
        type: ForwardType.values.firstWhere((e) => e.name == j['type'],
            orElse: () => ForwardType.local),
        bindHost: j['bindHost'] as String? ?? '127.0.0.1',
        bindPort: j['bindPort'] as int? ?? 0,
        destHost: j['destHost'] as String? ?? '127.0.0.1',
        destPort: j['destPort'] as int? ?? 0,
        enabled: j['enabled'] as bool? ?? true,
        note: j['note'] as String? ?? '',
      );

  PortForward copy() => PortForward.fromJson(toJson());
}

class ProxyConfig {
  ProxyType type;
  String host;
  int port;
  String username;
  String password;

  ProxyConfig({
    this.type = ProxyType.none,
    this.host = '',
    this.port = 1080,
    this.username = '',
    this.password = '',
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return ProxyConfig();
    return ProxyConfig(
      type: ProxyType.values.firstWhere((e) => e.name == j['type'],
          orElse: () => ProxyType.none),
      host: j['host'] as String? ?? '',
      port: j['port'] as int? ?? 1080,
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
    );
  }
}

class SessionConfig {
  String id;
  String name;
  String? groupId;
  SessionType type;
  String host;
  int port;
  String username;
  AuthType authType;
  String password;
  String privateKey;
  String passphrase;
  String description;
  String charset;
  String initCommand;
  String? jumpSessionId;
  bool legacyAlgorithms;
  ProxyConfig proxy;
  List<PortForward> forwards;
  int createdAt;
  int updatedAt;
  int lastConnectedAt;
  bool deleted;

  SessionConfig({
    String? id,
    this.name = '',
    this.groupId,
    this.type = SessionType.ssh,
    this.host = '',
    this.port = 22,
    this.username = 'root',
    this.authType = AuthType.password,
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
    this.description = '',
    this.charset = 'UTF-8',
    this.initCommand = '',
    this.jumpSessionId,
    this.legacyAlgorithms = false,
    ProxyConfig? proxy,
    List<PortForward>? forwards,
    int? createdAt,
    int? updatedAt,
    this.lastConnectedAt = 0,
    this.deleted = false,
  })  : id = id ?? newId(),
        proxy = proxy ?? ProxyConfig(),
        forwards = forwards ?? [],
        createdAt = createdAt ?? nowMs(),
        updatedAt = updatedAt ?? nowMs();

  String get displayName => name.isEmpty ? host : name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'groupId': groupId,
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType.name,
        'password': password,
        'privateKey': privateKey,
        'passphrase': passphrase,
        'description': description,
        'charset': charset,
        'initCommand': initCommand,
        'jumpSessionId': jumpSessionId,
        'legacyAlgorithms': legacyAlgorithms,
        'proxy': proxy.toJson(),
        'forwards': forwards.map((e) => e.toJson()).toList(),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'lastConnectedAt': lastConnectedAt,
        'deleted': deleted,
      };

  factory SessionConfig.fromJson(Map<String, dynamic> j) => SessionConfig(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        groupId: j['groupId'] as String?,
        type: SessionType.values.firstWhere((e) => e.name == j['type'],
            orElse: () => SessionType.ssh),
        host: j['host'] as String? ?? '',
        port: j['port'] as int? ?? 22,
        username: j['username'] as String? ?? '',
        authType: AuthType.values.firstWhere((e) => e.name == j['authType'],
            orElse: () => AuthType.password),
        password: j['password'] as String? ?? '',
        privateKey: j['privateKey'] as String? ?? '',
        passphrase: j['passphrase'] as String? ?? '',
        description: j['description'] as String? ?? '',
        charset: j['charset'] as String? ?? 'UTF-8',
        initCommand: j['initCommand'] as String? ?? '',
        jumpSessionId: j['jumpSessionId'] as String?,
        legacyAlgorithms: j['legacyAlgorithms'] as bool? ?? false,
        proxy: ProxyConfig.fromJson(j['proxy'] as Map<String, dynamic>?),
        forwards: ((j['forwards'] as List?) ?? [])
            .map((e) => PortForward.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        createdAt: j['createdAt'] as int?,
        updatedAt: j['updatedAt'] as int?,
        lastConnectedAt: j['lastConnectedAt'] as int? ?? 0,
        deleted: j['deleted'] as bool? ?? false,
      );

  SessionConfig copy() => SessionConfig.fromJson(toJson());
}

class SessionGroup {
  String id;
  String name;
  String? parentId;
  int updatedAt;
  bool deleted;

  SessionGroup({
    String? id,
    this.name = '',
    this.parentId,
    int? updatedAt,
    this.deleted = false,
  })  : id = id ?? newId(),
        updatedAt = updatedAt ?? nowMs();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'updatedAt': updatedAt,
        'deleted': deleted,
      };

  factory SessionGroup.fromJson(Map<String, dynamic> j) => SessionGroup(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        parentId: j['parentId'] as String?,
        updatedAt: j['updatedAt'] as int?,
        deleted: j['deleted'] as bool? ?? false,
      );
}

class QuickCommand {
  String id;
  String group;
  String name;
  String command;
  bool appendEnter;
  int updatedAt;
  bool deleted;

  QuickCommand({
    String? id,
    this.group = '默认',
    this.name = '',
    this.command = '',
    this.appendEnter = true,
    int? updatedAt,
    this.deleted = false,
  })  : id = id ?? newId(),
        updatedAt = updatedAt ?? nowMs();

  Map<String, dynamic> toJson() => {
        'id': id,
        'group': group,
        'name': name,
        'command': command,
        'appendEnter': appendEnter,
        'updatedAt': updatedAt,
        'deleted': deleted,
      };

  factory QuickCommand.fromJson(Map<String, dynamic> j) => QuickCommand(
        id: j['id'] as String?,
        group: j['group'] as String? ?? '默认',
        name: j['name'] as String? ?? '',
        command: j['command'] as String? ?? '',
        appendEnter: j['appendEnter'] as bool? ?? true,
        updatedAt: j['updatedAt'] as int?,
        deleted: j['deleted'] as bool? ?? false,
      );
}
